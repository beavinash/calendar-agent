import SwiftData
import XCTest
@testable import CalendarAgent

private final class ResetTestSecureStore: SecureStore {
  private var values: [String: String] = [:]

  func save(_ value: String, for key: String) throws {
    values[key] = value
  }

  func read(_ key: String) throws -> String? {
    values[key]
  }

  func delete(_ key: String) throws {
    values.removeValue(forKey: key)
  }
}

@MainActor
private final class ResetCalendarStoreSpy: CalendarStore {
  var accessState: CalendarAccessState = .fullAccess
  var calendars: [CalendarDescriptor] = []
  var writableCalendars: [CalendarDescriptor] = []
  var defaultWritableCalendar: CalendarDescriptor?
  var todayEvents: [CalendarDisplayEvent] = []
  var eventsToReturn: [CalendarDisplayEvent] = []
  private(set) var refreshFromSystemCount = 0
  private(set) var eventReadCount = 0
  private(set) var applyCount = 0
  private(set) var automaticApplyCount = 0
  private(set) var undoCount = 0

  func requestFullAccess() async throws {}
  func refreshCalendars() {}

  func refreshFromSystem() throws {
    refreshFromSystemCount += 1
  }

  func refreshToday() throws {}

  func events(
    from start: Date,
    to end: Date
  ) throws -> [CalendarDisplayEvent] {
    eventReadCount += 1
    return eventsToReturn
  }

  func snapshot(
    from start: Date,
    to end: Date,
    includeTitles: Bool,
    includeFreeEvents: Bool
  ) throws -> CalendarSnapshotResult {
    CalendarSnapshotResult(events: [], isTruncated: false)
  }

  func apply(
    proposal: CalendarProposal,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent {
    applyCount += 1
    return AppliedCalendarEvent(
      eventIdentifier: "unexpected-apply",
      proposal: proposal
    )
  }

  func applyAutomatically(
    proposal: CalendarProposal,
    authorizedCalendarIdentifier: String,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent {
    automaticApplyCount += 1
    return AppliedCalendarEvent(
      eventIdentifier: "unexpected-automatic-apply",
      proposal: proposal
    )
  }

  func undoAgentEvent(identifier: String) throws {
    undoCount += 1
  }

  func agentEventExists(identifier: String) -> Bool {
    false
  }
}

@MainActor
final class LocalCoachingHistoryResetServiceTests: XCTestCase {
  func testScopedCoordinatorReadsCalendarButNeverMutatesIt() throws {
    let context = try makeModelContext()
    let calendar = try makeCalendar()
    let now = try makeDate("2026-09-25T12:00:00-07:00")
    let bounds = try XCTUnwrap(
      ClearHistoryScope.week.analysisInterval(at: now, calendar: calendar)
    )
    let occurrence = bounds.start.addingTimeInterval(3_600)
    let (settings, suite) = makeSettings(
      startedAt: bounds.start.addingTimeInterval(-86_400)
    )
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let calendarStore = ResetCalendarStoreSpy()
    calendarStore.eventsToReturn = [
      CalendarDisplayEvent(
        completionKey: "legacy-completion",
        title: "Private title",
        startAt: occurrence,
        endAt: occurrence.addingTimeInterval(3_600),
        isAllDay: false,
        calendarTitle: "Private calendar"
      )
    ]
    context.insert(
      makeCompletion(key: "legacy-completion", occurrence: nil)
    )
    try context.save()

    try LocalCoachingHistoryResetCoordinator.reset(
      scope: .week,
      at: now,
      calendar: calendar,
      modelContext: context,
      settings: settings,
      calendarStore: calendarStore
    )

    XCTAssertTrue(
      try context.fetch(FetchDescriptor<CalendarEventCompletionRecord>()).isEmpty
    )
    XCTAssertEqual(calendarStore.refreshFromSystemCount, 1)
    XCTAssertEqual(calendarStore.eventReadCount, 1)
    XCTAssertEqual(calendarStore.applyCount, 0)
    XCTAssertEqual(calendarStore.automaticApplyCount, 0)
    XCTAssertEqual(calendarStore.undoCount, 0)
  }

  func testCancellingConfirmationPreservesPersistentState() throws {
    let context = try makeModelContext()
    let startedAt = try makeDate("2026-08-01T08:00:00-07:00")
    let (settings, suite) = makeSettings(startedAt: startedAt)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let session = CoachSessionController(
      defaults: UserDefaults(suiteName: suite)!
    )
    let sessionId = session.activeSessionId
    context.insert(ChatMessageRecord(role: .user, content: "preserved"))
    context.insert(makeCheckIn(createdAt: startedAt))
    context.insert(makeCompletion(key: "preserved", occurrence: startedAt))
    context.insert(
      PendingCalendarProposalRecord(proposal: makeProposal(at: startedAt))
    )
    context.insert(
      ClearedAnalysisIntervalRecord(
        scope: .week,
        interval: DateInterval(
          start: startedAt,
          end: startedAt.addingTimeInterval(3_600)
        )
      )
    )
    try context.save()
    var confirmation = ClearHistoryConfirmationState()
    confirmation.request(.all)

    confirmation.cancel()

    XCTAssertNil(confirmation.consumeConfirmedScope())
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<ChatMessageRecord>()).map(\.content),
      ["preserved"]
    )
    XCTAssertEqual(settings.trackingStartedAt, startedAt)
    XCTAssertEqual(session.activeSessionId, sessionId)
    XCTAssertEqual(try context.fetch(FetchDescriptor<CheckInRecord>()).count, 1)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<CalendarEventCompletionRecord>()).count,
      1
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<PendingCalendarProposalRecord>()).count,
      1
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<ClearedAnalysisIntervalRecord>()).count,
      1
    )
  }

  func testScopedResetDeletesOnlyTargetEvidenceAndPreservesSafetyData()
    throws {
    let context = try makeModelContext()
    let calendar = try makeCalendar()
    let now = try makeDate("2026-09-25T12:00:00-07:00")
    let bounds = try XCTUnwrap(
      ClearHistoryScope.week.analysisInterval(at: now, calendar: calendar)
    )
    let before = bounds.start.addingTimeInterval(-60)
    let inside = bounds.start.addingTimeInterval(3_600)
    let after = bounds.end.addingTimeInterval(60)
    let (settings, suite) = makeSettings(startedAt: before)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    context.insert(ChatMessageRecord(role: .user, content: "before", createdAt: before))
    context.insert(ChatMessageRecord(role: .user, content: "start", createdAt: bounds.start))
    context.insert(ChatMessageRecord(role: .user, content: "inside", createdAt: inside))
    context.insert(ChatMessageRecord(role: .user, content: "end", createdAt: bounds.end))
    context.insert(ChatMessageRecord(role: .user, content: "after", createdAt: after))
    context.insert(makeCheckIn(createdAt: before))
    context.insert(makeCheckIn(createdAt: inside))
    context.insert(makeCheckIn(createdAt: after))
    context.insert(makeCompletion(key: "timed-inside", occurrence: inside))
    context.insert(makeCompletion(key: "timed-outside", occurrence: after))
    context.insert(makeCompletion(key: "legacy-inside", occurrence: nil))
    context.insert(makeCompletion(key: "legacy-outside", occurrence: nil))
    context.insert(PendingCalendarProposalRecord(proposal: makeProposal(at: after)))
    context.insert(
      ClearedAnalysisIntervalRecord(
        scope: .month,
        interval: DateInterval(start: before, end: inside)
      )
    )
    context.insert(NoteRecord(text: "preserved note", createdAt: inside))
    context.insert(CalendarAuditRecord(appliedEvent: makeAppliedEvent(at: inside)))
    context.insert(makeReschedule(at: inside))
    try context.save()

    try LocalCoachingHistoryResetService.reset(
      scope: .week,
      at: now,
      calendar: calendar,
      legacyCompletionKeys: ["legacy-inside"],
      modelContext: context,
      settings: settings
    )
    try LocalCoachingHistoryResetService.reset(
      scope: .week,
      at: now,
      calendar: calendar,
      legacyCompletionKeys: ["legacy-inside"],
      modelContext: context,
      settings: settings
    )

    XCTAssertEqual(
      Set(try context.fetch(FetchDescriptor<ChatMessageRecord>()).map(\.content)),
      ["before", "end", "after"]
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<CheckInRecord>()).map(\.createdAt).sorted(),
      [before, after]
    )
    XCTAssertEqual(
      Set(
        try context.fetch(FetchDescriptor<CalendarEventCompletionRecord>())
          .map(\.completionKey)
      ),
      ["timed-outside", "legacy-outside"]
    )
    XCTAssertTrue(
      try context.fetch(FetchDescriptor<PendingCalendarProposalRecord>()).isEmpty
    )
    let intervals = try context.fetch(
      FetchDescriptor<ClearedAnalysisIntervalRecord>()
    )
    XCTAssertEqual(intervals.count, 2)
    XCTAssertEqual(intervals.filter { $0.interval == bounds }.count, 1)
    XCTAssertEqual(settings.trackingStartedAt, before)
    XCTAssertEqual(try context.fetch(FetchDescriptor<NoteRecord>()).count, 1)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<CalendarAuditRecord>()).count,
      1
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<IncompleteEventRescheduleRecord>()).count,
      1
    )
  }

  func testMonthResetUsesThePreviousCompletedCalendarMonth() throws {
    let context = try makeModelContext()
    let calendar = try makeCalendar()
    let now = try makeDate("2026-09-25T12:00:00-07:00")
    let bounds = try XCTUnwrap(
      ClearHistoryScope.month.analysisInterval(at: now, calendar: calendar)
    )
    let startedAt = bounds.start.addingTimeInterval(-86_400)
    let (settings, suite) = makeSettings(startedAt: startedAt)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    context.insert(
      ChatMessageRecord(
        role: .user,
        content: "previous month",
        createdAt: bounds.start.addingTimeInterval(86_400)
      )
    )
    context.insert(
      ChatMessageRecord(
        role: .user,
        content: "current month",
        createdAt: bounds.end.addingTimeInterval(86_400)
      )
    )
    try context.save()

    try LocalCoachingHistoryResetService.reset(
      scope: .month,
      at: now,
      calendar: calendar,
      legacyCompletionKeys: [],
      modelContext: context,
      settings: settings
    )

    XCTAssertEqual(
      try context.fetch(FetchDescriptor<ChatMessageRecord>()).map(\.content),
      ["current month"]
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<ClearedAnalysisIntervalRecord>())
        .map(\.interval),
      [bounds]
    )
  }

  func testAllHistoryResetDeletesAnalysisDataAndRestartsTracking() throws {
    let context = try makeModelContext()
    let calendar = try makeCalendar()
    let startedAt = try makeDate("2026-08-01T08:00:00-07:00")
    let resetAt = try makeDate("2026-09-25T12:00:00-07:00")
    let (settings, suite) = makeSettings(startedAt: startedAt)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    context.insert(ChatMessageRecord(role: .assistant, content: "history"))
    context.insert(makeCheckIn(createdAt: startedAt))
    context.insert(makeCompletion(key: "completion", occurrence: startedAt))
    context.insert(PendingCalendarProposalRecord(proposal: makeProposal(at: resetAt)))
    context.insert(
      ClearedAnalysisIntervalRecord(
        scope: .week,
        interval: DateInterval(start: startedAt, end: resetAt)
      )
    )
    context.insert(NoteRecord(text: "preserved note"))
    context.insert(CalendarAuditRecord(appliedEvent: makeAppliedEvent(at: resetAt)))
    context.insert(makeReschedule(at: resetAt))
    try context.save()

    try LocalCoachingHistoryResetService.reset(
      scope: .all,
      at: resetAt,
      calendar: calendar,
      legacyCompletionKeys: [],
      modelContext: context,
      settings: settings
    )

    XCTAssertTrue(try context.fetch(FetchDescriptor<ChatMessageRecord>()).isEmpty)
    XCTAssertTrue(try context.fetch(FetchDescriptor<CheckInRecord>()).isEmpty)
    XCTAssertTrue(
      try context.fetch(FetchDescriptor<CalendarEventCompletionRecord>()).isEmpty
    )
    XCTAssertTrue(
      try context.fetch(FetchDescriptor<PendingCalendarProposalRecord>()).isEmpty
    )
    XCTAssertTrue(
      try context.fetch(FetchDescriptor<ClearedAnalysisIntervalRecord>()).isEmpty
    )
    XCTAssertEqual(settings.trackingStartedAt, resetAt)
    XCTAssertEqual(try context.fetch(FetchDescriptor<NoteRecord>()).count, 1)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<CalendarAuditRecord>()).count,
      1
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<IncompleteEventRescheduleRecord>()).count,
      1
    )
  }

  private func makeModelContext() throws -> ModelContext {
    let schema = Schema([
      NoteRecord.self,
      ChatMessageRecord.self,
      CheckInRecord.self,
      CalendarAuditRecord.self,
      CalendarEventCompletionRecord.self,
      IncompleteEventRescheduleRecord.self,
      PendingCalendarProposalRecord.self,
      ClearedAnalysisIntervalRecord.self
    ])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    return ModelContext(container)
  }

  private func makeSettings(
    startedAt: Date
  ) -> (AppSettings, String) {
    let suite = "LocalCoachingHistoryResetServiceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(startedAt, forKey: "trackingStartedAt")
    return (
      AppSettings(defaults: defaults, secureStore: ResetTestSecureStore()),
      suite
    )
  }

  private func makeCalendar() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(
      TimeZone(identifier: "America/Los_Angeles")
    )
    calendar.firstWeekday = 2
    return calendar
  }

  private func makeDate(_ value: String) throws -> Date {
    try XCTUnwrap(ISO8601DateFormatter().date(from: value))
  }

  private func makeCheckIn(createdAt: Date) -> CheckInRecord {
    CheckInRecord(
      createdAt: createdAt,
      energy: 3,
      focusLevel: 3,
      commitmentCompleted: false,
      reflection: "fixture"
    )
  }

  private func makeCompletion(
    key: String,
    occurrence: Date?
  ) -> CalendarEventCompletionRecord {
    CalendarEventCompletionRecord(
      completionKey: key,
      status: .incomplete,
      eventOccurrenceAt: occurrence
    )
  }

  private func makeProposal(at date: Date) -> CalendarProposal {
    CalendarProposal(
      proposalId: UUID(),
      title: "Generic focus block",
      startAt: date,
      endAt: date.addingTimeInterval(3_600),
      focusArea: .work,
      rationale: "fixture",
      notes: "fixture",
      reminderMinutes: 10
    )
  }

  private func makeAppliedEvent(at date: Date) -> AppliedCalendarEvent {
    AppliedCalendarEvent(
      eventIdentifier: "audit-event",
      proposal: makeProposal(at: date)
    )
  }

  private func makeReschedule(at date: Date) -> IncompleteEventRescheduleRecord {
    IncompleteEventRescheduleRecord(
      sourceCompletionKey: "source-key",
      proposalId: UUID(),
      eventIdentifier: "rescheduled-event",
      scheduledStartAt: date,
      scheduledEndAt: date.addingTimeInterval(3_600)
    )
  }
}
