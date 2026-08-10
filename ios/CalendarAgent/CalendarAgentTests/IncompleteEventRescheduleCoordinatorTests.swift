import SwiftData
import XCTest
@testable import CalendarAgent

private final class RescheduleSecureStore: SecureStore {
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
private final class FakeIncompleteEventRescheduler:
  IncompleteEventRescheduling {
  var scheduledResults: [AppliedIncompleteEventReschedule] = []
  var existingEventIdentifiers: Set<String> = []
  private(set) var scheduledEvents: [CalendarDisplayEvent] = []
  private(set) var receivedConstraints: [LocalScheduleConstraints] = []
  private(set) var undoneEventIdentifiers: [String] = []

  func scheduleIncompleteEvent(
    _ source: CalendarDisplayEvent,
    constraints: LocalScheduleConstraints
  ) throws -> AppliedIncompleteEventReschedule {
    scheduledEvents.append(source)
    receivedConstraints.append(constraints)
    let result = scheduledResults.removeFirst()
    existingEventIdentifiers.insert(result.eventIdentifier)
    return result
  }

  func undoAgentEvent(identifier: String) throws {
    undoneEventIdentifiers.append(identifier)
    existingEventIdentifiers.remove(identifier)
  }

  func agentEventExists(identifier: String) -> Bool {
    existingEventIdentifiers.contains(identifier)
  }
}

@MainActor
final class IncompleteEventRescheduleCoordinatorTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }

  func testRejectsWhenPersistedStatusIsMissingOrComplete() throws {
    for status in [nil, CalendarEventCompletionStatus.complete] {
      let context = try makeModelContext()
      let event = makeEvent(key: "status-gate")
      if let status {
        try persistCompletion(status, for: event, in: context)
      }
      let rescheduler = FakeIncompleteEventRescheduler()
      let (settings, suite) = makeSettings()
      defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

      XCTAssertThrowsError(
        try IncompleteEventRescheduleCoordinator.schedule(
          event: event,
          now: date(day: 20, hour: 18),
          settings: settings,
          calendarService: rescheduler,
          modelContext: context,
          calendar: calendar
        )
      ) { error in
        XCTAssertEqual(
          error as? IncompleteEventRescheduleError,
          .notIncomplete
        )
      }
      XCTAssertTrue(rescheduler.scheduledEvents.isEmpty)
    }
  }

  func testSuccessfulWritePersistsOneLinkAndKeepsIncompleteStatus()
    throws {
    let context = try makeModelContext()
    let event = makeEvent(key: "successful-source")
    try persistCompletion(.incomplete, for: event, in: context)
    let scheduledAt = date(day: 20, hour: 19)
    let result = makeApplied(
      source: event,
      identifier: "created-event",
      startAt: scheduledAt
    )
    let rescheduler = FakeIncompleteEventRescheduler()
    rescheduler.scheduledResults = [result]
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let outcome = try IncompleteEventRescheduleCoordinator.schedule(
      event: event,
      now: date(day: 20, hour: 18),
      settings: settings,
      calendarService: rescheduler,
      modelContext: context,
      calendar: calendar
    )

    XCTAssertEqual(outcome, .today(scheduledAt))
    XCTAssertEqual(rescheduler.scheduledEvents.count, 1)
    let links = try context.fetch(
      FetchDescriptor<IncompleteEventRescheduleRecord>()
    )
    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(links.first?.sourceCompletionKey, event.completionKey)
    XCTAssertEqual(links.first?.eventIdentifier, "created-event")
    XCTAssertEqual(try completion(for: event, in: context), .incomplete)
  }

  func testSecondInvocationUsesOwnedLinkedEventWithoutAnotherWrite()
    throws {
    let context = try makeModelContext()
    let event = makeEvent(key: "idempotent-source")
    try persistCompletion(.incomplete, for: event, in: context)
    let scheduledAt = date(day: 20, hour: 19)
    let rescheduler = FakeIncompleteEventRescheduler()
    rescheduler.scheduledResults = [
      makeApplied(
        source: event,
        identifier: "linked-event",
        startAt: scheduledAt
      )
    ]
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let now = date(day: 20, hour: 18)

    let first = try IncompleteEventRescheduleCoordinator.schedule(
      event: event,
      now: now,
      settings: settings,
      calendarService: rescheduler,
      modelContext: context,
      calendar: calendar
    )
    let second = try IncompleteEventRescheduleCoordinator.schedule(
      event: event,
      now: now,
      settings: settings,
      calendarService: rescheduler,
      modelContext: context,
      calendar: calendar
    )

    XCTAssertEqual(first, .today(scheduledAt))
    XCTAssertEqual(second, first)
    XCTAssertEqual(rescheduler.scheduledEvents.count, 1)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<IncompleteEventRescheduleRecord>())
        .count,
      1
    )
  }

  func testStaleLinkedEventIsReplacedAndExistingRecordIsUpdated() throws {
    let context = try makeModelContext()
    let event = makeEvent(key: "stale-source")
    try persistCompletion(.incomplete, for: event, in: context)
    let oldProposalId = UUID()
    let oldRecord = IncompleteEventRescheduleRecord(
      sourceCompletionKey: event.completionKey,
      proposalId: oldProposalId,
      eventIdentifier: "deleted-event",
      scheduledStartAt: date(day: 20, hour: 18),
      scheduledEndAt: date(day: 20, hour: 19)
    )
    context.insert(oldRecord)
    try context.save()
    let replacementStart = date(day: 21, hour: 6)
    let replacement = makeApplied(
      source: event,
      identifier: "replacement-event",
      startAt: replacementStart
    )
    let rescheduler = FakeIncompleteEventRescheduler()
    rescheduler.scheduledResults = [replacement]
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let outcome = try IncompleteEventRescheduleCoordinator.schedule(
      event: event,
      now: date(day: 20, hour: 22),
      settings: settings,
      calendarService: rescheduler,
      modelContext: context,
      calendar: calendar
    )

    XCTAssertEqual(outcome, .tomorrow(replacementStart))
    XCTAssertEqual(rescheduler.scheduledEvents.count, 1)
    let records = try context.fetch(
      FetchDescriptor<IncompleteEventRescheduleRecord>()
    )
    XCTAssertEqual(records.count, 1)
    XCTAssertTrue(records.first === oldRecord)
    XCTAssertNotEqual(records.first?.proposalId, oldProposalId)
    XCTAssertEqual(records.first?.proposalId, replacement.proposal.proposalId)
    XCTAssertEqual(records.first?.eventIdentifier, "replacement-event")
    XCTAssertEqual(records.first?.scheduledStartAt, replacementStart)
  }

  func testOutcomesDistinguishTodayFromTomorrow() throws {
    let context = try makeModelContext()
    let todayEvent = makeEvent(key: "today-source")
    let tomorrowEvent = makeEvent(key: "tomorrow-source")
    try persistCompletion(.incomplete, for: todayEvent, in: context)
    try persistCompletion(.incomplete, for: tomorrowEvent, in: context)
    let now = date(day: 20, hour: 18)
    let todayStart = date(day: 20, hour: 19)
    let tomorrowStart = date(day: 21, hour: 6)
    let rescheduler = FakeIncompleteEventRescheduler()
    rescheduler.scheduledResults = [
      makeApplied(
        source: todayEvent,
        identifier: "today-event",
        startAt: todayStart
      ),
      makeApplied(
        source: tomorrowEvent,
        identifier: "tomorrow-event",
        startAt: tomorrowStart
      )
    ]
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let todayOutcome = try IncompleteEventRescheduleCoordinator.schedule(
      event: todayEvent,
      now: now,
      settings: settings,
      calendarService: rescheduler,
      modelContext: context,
      calendar: calendar
    )
    let tomorrowOutcome = try IncompleteEventRescheduleCoordinator.schedule(
      event: tomorrowEvent,
      now: now,
      settings: settings,
      calendarService: rescheduler,
      modelContext: context,
      calendar: calendar
    )

    XCTAssertEqual(todayOutcome, .today(todayStart))
    XCTAssertEqual(tomorrowOutcome, .tomorrow(tomorrowStart))
  }

  private func makeEvent(key: String) -> CalendarDisplayEvent {
    CalendarDisplayEvent(
      completionKey: key,
      title: "Private title",
      startAt: date(day: 19, hour: 18),
      endAt: date(day: 19, hour: 19),
      isAllDay: false,
      calendarTitle: "Private calendar"
    )
  }

  private func makeApplied(
    source: CalendarDisplayEvent,
    identifier: String,
    startAt: Date
  ) -> AppliedIncompleteEventReschedule {
    let proposal = IncompleteEventRescheduleProposal(
      proposalId: UUID(),
      sourceCompletionKey: source.completionKey,
      title: source.title,
      startAt: startAt,
      endAt: startAt.addingTimeInterval(
        source.endAt.timeIntervalSince(source.startAt)
      ),
      reminderMinutes: 10
    )
    return AppliedIncompleteEventReschedule(
      eventIdentifier: identifier,
      proposal: proposal,
      wasCreated: true
    )
  }

  private func persistCompletion(
    _ status: CalendarEventCompletionStatus,
    for event: CalendarDisplayEvent,
    in context: ModelContext
  ) throws {
    context.insert(
      CalendarEventCompletionRecord(
        completionKey: event.completionKey,
        status: status
      )
    )
    try context.save()
  }

  private func completion(
    for event: CalendarDisplayEvent,
    in context: ModelContext
  ) throws -> CalendarEventCompletionStatus? {
    let key = event.completionKey
    let descriptor = FetchDescriptor<CalendarEventCompletionRecord>(
      predicate: #Predicate { record in
        record.completionKey == key
      }
    )
    return try context.fetch(descriptor).first?.status
  }

  private func date(day: Int, hour: Int) -> Date {
    DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2026,
      month: 7,
      day: day,
      hour: hour
    ).date!
  }

  private func makeSettings() -> (AppSettings, String) {
    let suite = "IncompleteEventRescheduleCoordinatorTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (
      AppSettings(
        defaults: defaults,
        secureStore: RescheduleSecureStore(),
        now: { self.date(day: 1, hour: 0) }
      ),
      suite
    )
  }

  private func makeModelContext() throws -> ModelContext {
    let schema = Schema([
      CalendarEventCompletionRecord.self,
      IncompleteEventRescheduleRecord.self
    ])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    return ModelContext(container)
  }
}
