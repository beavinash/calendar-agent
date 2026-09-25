import SwiftData
import XCTest
@testable import CalendarAgent

private final class ViewModelSecureStore: SecureStore {
  var values: [String: String] = [:]

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

private final class FakeTurnClient: HTTPClient {
  typealias ResponseFactory = (AgentTurnRequest) throws -> AgentTurnResponse

  private let responseFactory: ResponseFactory
  private(set) var requests: [AgentTurnRequest] = []
  private(set) var appSecrets: [String?] = []

  init(response: AgentTurnResponse) {
    responseFactory = { _ in response }
  }

  init(responseFactory: @escaping ResponseFactory) {
    self.responseFactory = responseFactory
  }

  init(error: any Error) {
    responseFactory = { _ in throw error }
  }

  var callCount: Int { requests.count }
  var lastRequest: AgentTurnRequest? { requests.last }
  var lastAppSecret: String? { appSecrets.last ?? nil }

  func sendTurn(
    _ turn: AgentTurnRequest,
    appSecret: String?
  ) async throws -> AgentTurnResponse {
    requests.append(turn)
    appSecrets.append(appSecret)
    return try responseFactory(turn)
  }

  func checkStatus(appSecret: String?) async throws -> BackendStatus {
    BackendStatus(
      status: "ok",
      service: "calendar-agent",
      provider: "openai",
      model: "server-model",
      byokEnabled: false,
      auditPersistenceEnabled: false
    )
  }
}

@MainActor
private final class FakeCalendarStore: CalendarStore {
  struct SnapshotCall {
    let start: Date
    let end: Date
    let includeTitles: Bool
    let includeFreeEvents: Bool
    let calendarCount: Int
  }

  var accessState: CalendarAccessState = .fullAccess
  var calendars: [CalendarDescriptor] = [
    CalendarDescriptor(
      id: "icloud-calendar",
      title: "Personal",
      accountTitle: "iCloud",
      isLikelyICloud: true,
      allowsModifications: true
    )
  ]
  var writableCalendars: [CalendarDescriptor] {
    calendars.filter(\.allowsModifications)
  }
  var defaultWritableCalendar: CalendarDescriptor? {
    writableCalendars.first
  }
  var todayEvents: [CalendarDisplayEvent] = []
  var appliedProposals: [CalendarProposal] = []
  var appliedValidationModes: [ScheduleValidationMode] = []
  var failOnApplyNumber: Int?
  var reviewSnapshotResult = CalendarSnapshotResult(
    events: [],
    isTruncated: false
  )
  var availabilitySnapshotResult = CalendarSnapshotResult(
    events: [],
    isTruncated: false
  )
  private(set) var snapshotCalls: [SnapshotCall] = []
  private(set) var refreshFromSystemCount = 0

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
    todayEvents.filter { event in
      event.startAt < end && event.endAt > start
    }
  }

  func snapshot(
    from start: Date,
    to end: Date,
    includeTitles: Bool,
    includeFreeEvents: Bool
  ) throws -> CalendarSnapshotResult {
    snapshotCalls.append(
      SnapshotCall(
        start: start,
        end: end,
        includeTitles: includeTitles,
        includeFreeEvents: includeFreeEvents,
        calendarCount: calendars.count
      )
    )
    return includeTitles ? reviewSnapshotResult : availabilitySnapshotResult
  }

  func apply(
    proposal: CalendarProposal,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent {
    let applyNumber = appliedProposals.count + 1
    if failOnApplyNumber == applyNumber {
      throw AppError.calendarConflict
    }
    appliedProposals.append(proposal)
    appliedValidationModes.append(validationMode)
    return AppliedCalendarEvent(
      eventIdentifier: "event-\(applyNumber)",
      proposal: proposal
    )
  }

  func applyAutomatically(
    proposal: CalendarProposal,
    authorizedCalendarIdentifier: String,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent {
    guard defaultWritableCalendar?.id == authorizedCalendarIdentifier else {
      throw AppError.automaticCalendarAuthorizationRequired
    }
    return try apply(
      proposal: proposal,
      constraints: constraints,
      validationMode: validationMode
    )
  }

  func undoAgentEvent(identifier: String) throws {}

  func agentEventExists(identifier: String) -> Bool {
    true
  }
}

@MainActor
final class CoachViewModelTests: XCTestCase {
  func testHostedClientExposesOnlyOpenAIProvider() {
    XCTAssertEqual(AIProvider.allCases, [.openai])
  }

  func testSimulatorLoopbackAllowsLocalBackendWithoutDeploymentSecret()
    async throws {
    let client = FakeTurnClient(response: makePlanningResponse(proposalCount: 0))
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings(includeAppSecret: false)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "Local simulator request",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertEqual(client.callCount, 1)
    XCTAssertNil(client.lastAppSecret)
  }

  func testHostedTurnUsesOpenAIServerModelAndOnlyAppCredential() async throws {
    let client = FakeTurnClient(response: makePlanningResponse(proposalCount: 0))
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "Help me stay disciplined",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertEqual(client.lastRequest?.provider, .openai)
    XCTAssertNil(client.lastRequest?.model)
    XCTAssertEqual(client.lastAppSecret, "test-deployment-secret")
    XCTAssertTrue(calendarStore.snapshotCalls.isEmpty)
    XCTAssertTrue(client.lastRequest?.reviewCalendar.isEmpty == true)
    XCTAssertNil(client.lastRequest?.missedPatternContext)
  }

  func testServerFailurePresentsOneErrorAndStopsLoading() async throws {
    let client = FakeTurnClient(
      error: HTTPClientError.server(
        status: 502,
        requestID: "review-regression-request"
      )
    )
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "Help me stay disciplined",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertFalse(viewModel.isLoading)
    XCTAssertTrue(viewModel.pendingProposals.isEmpty)
    XCTAssertNil(viewModel.focusReview)
    let error = try XCTUnwrap(viewModel.presentedError)
    XCTAssertTrue(error.message.contains("temporarily unavailable"))
    XCTAssertTrue(error.message.contains("review-regression-request"))

    viewModel.presentedError = nil
    XCTAssertNil(viewModel.errorMessage)
  }

  func testCalendarRequestCreatesDraftsWithoutAutomaticWrites() async throws {
    let response = makePlanningResponse(proposalCount: 5)
    let client = FakeTurnClient(response: response)
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    settings.authorizeAutomaticScheduling(
      calendarIdentifier: "icloud-calendar"
    )
    let context = try makeModelContext()
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "Plan five focus blocks",
      history: [],
      notes: [],
      modelContext: context,
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertEqual(client.callCount, 1)
    XCTAssertTrue(client.lastRequest?.calendarActionRequested == true)
    XCTAssertTrue(client.lastRequest?.focusReviewRequested == false)
    XCTAssertNil(client.lastRequest?.missedPatternContext)
    XCTAssertEqual(viewModel.pendingProposals.count, 5)
    XCTAssertTrue(calendarStore.appliedProposals.isEmpty)
    XCTAssertNil(viewModel.calendarActionMessage)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<PendingCalendarProposalRecord>())
        .count,
      5
    )
    XCTAssertTrue(
      try context.fetch(FetchDescriptor<CalendarAuditRecord>()).isEmpty
    )
  }

  func testReviewSuggestionsRequireConfirmationThenAddExactSevenWithoutSecondTurn()
    async throws {
    let client = FakeTurnClient { request in
      makeReviewResponse(for: request)
    }
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings(
      trackingStartedAt: Date().addingTimeInterval(-90 * 86_400)
    )
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let context = try makeModelContext()
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review week",
      history: [],
      notes: [],
      modelContext: context,
      settings: settings,
      calendarService: calendarStore
    )

    let suggestions = try XCTUnwrap(viewModel.focusReview?.suggestedEvents)
    XCTAssertEqual(suggestions.count, 7)
    XCTAssertTrue(calendarStore.appliedProposals.isEmpty)
    XCTAssertTrue(viewModel.pendingProposals.isEmpty)
    XCTAssertEqual(client.callCount, 1)

    viewModel.applySuggestedEvents(
      suggestions,
      modelContext: context,
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertEqual(client.callCount, 1)
    XCTAssertEqual(calendarStore.appliedProposals.count, 7)
    XCTAssertEqual(
      calendarStore.appliedValidationModes,
      Array(repeating: .reviewSuggestion, count: 7)
    )
    XCTAssertEqual(
      calendarStore.appliedProposals.map(\.title),
      suggestions.map(\.title)
    )
    XCTAssertTrue(viewModel.pendingProposals.isEmpty)
    XCTAssertNil(viewModel.focusReview)
    XCTAssertEqual(
      viewModel.calendarActionMessage,
      "Added 7 events to Apple Calendar."
    )
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<CalendarAuditRecord>()).count,
      7
    )
    XCTAssertTrue(
      try context.fetch(
        FetchDescriptor<PendingCalendarProposalRecord>()
      ).isEmpty
    )
  }

  func testReviewSendsSeparateHistoricalAndFutureCalendarSnapshots()
    async throws {
    let historyEvent = CalendarEventSnapshot(
      eventId: "history-key",
      calendarId: "history-calendar",
      startAt: Date().addingTimeInterval(-86_400),
      endAt: Date().addingTimeInterval(-82_800),
      isAllDay: false,
      title: "Study review",
      focusArea: nil,
      completionStatus: nil
    )
    let futureEvent = CalendarEventSnapshot(
      eventId: "future-key",
      calendarId: "future-calendar",
      startAt: Date().addingTimeInterval(7_200),
      endAt: Date().addingTimeInterval(10_800),
      isAllDay: false,
      title: nil,
      focusArea: nil,
      completionStatus: nil
    )
    let completion = CalendarEventCompletionRecord(
      completionKey: historyEvent.eventId,
      status: .complete
    )
    let client = FakeTurnClient { request in
      makeReviewResponse(for: request)
    }
    let calendarStore = FakeCalendarStore()
    calendarStore.reviewSnapshotResult = CalendarSnapshotResult(
      events: [historyEvent],
      isTruncated: false
    )
    calendarStore.availabilitySnapshotResult = CalendarSnapshotResult(
      events: [futureEvent],
      isTruncated: false
    )
    let (settings, suite) = makeSettings(
      trackingStartedAt: Date().addingTimeInterval(-90 * 86_400)
    )
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review month",
      history: [],
      notes: [],
      completions: [completion],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    let request = try XCTUnwrap(client.lastRequest)
    XCTAssertEqual(calendarStore.snapshotCalls.count, 2)
    let reviewCall = calendarStore.snapshotCalls[0]
    XCTAssertEqual(reviewCall.start, request.focusReviewStart)
    XCTAssertEqual(reviewCall.end, request.focusReviewEnd)
    XCTAssertTrue(reviewCall.includeTitles)
    XCTAssertTrue(reviewCall.includeFreeEvents)
    let availabilityCall = calendarStore.snapshotCalls[1]
    XCTAssertEqual(availabilityCall.start, request.planningStart)
    XCTAssertEqual(availabilityCall.end, request.planningEnd)
    XCTAssertFalse(availabilityCall.includeTitles)
    XCTAssertFalse(availabilityCall.includeFreeEvents)

    XCTAssertEqual(request.reviewCalendar.count, 1)
    XCTAssertEqual(request.reviewCalendar.first?.title, "Study review")
    XCTAssertEqual(request.reviewCalendar.first?.completionStatus, .complete)
    XCTAssertEqual(request.calendar.count, 1)
    XCTAssertNil(request.calendar.first?.title)
    XCTAssertNil(request.calendar.first?.completionStatus)
    XCTAssertEqual(viewModel.focusReview?.completionEvidence, .userInput)
    XCTAssertEqual(request.trackingStartedAt, settings.trackingStartedAt)
  }

  func testReviewSendsFreshRankedMissedContextAndPlansNextSevenDays()
    async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let reviewNow = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 6,
          hour: 12
        )
      )
    )
    let unmarked = CalendarDisplayEvent(
      completionKey: "unmarked",
      title: "Study session",
      startAt: reviewNow.addingTimeInterval(-3_600),
      endAt: reviewNow.addingTimeInterval(-1_800),
      isAllDay: false,
      calendarTitle: "Private Calendar"
    )
    let explicit = CalendarDisplayEvent(
      completionKey: "explicit",
      title: "Grocery pickup",
      startAt: reviewNow.addingTimeInterval(-7_200),
      endAt: reviewNow.addingTimeInterval(-5_400),
      isAllDay: false,
      calendarTitle: "Private Calendar"
    )
    let completion = CalendarEventCompletionRecord(
      completionKey: explicit.completionKey,
      status: .incomplete
    )
    let client = FakeTurnClient { request in
      makeReviewResponse(for: request)
    }
    let calendarStore = FakeCalendarStore()
    calendarStore.todayEvents = [unmarked, explicit]
    let (settings, suite) = makeSettings(
      trackingStartedAt: reviewNow.addingTimeInterval(-30 * 86_400)
    )
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(
      clientFactory: { _ in client },
      now: { reviewNow }
    )

    await viewModel.send(
      message: "/review day",
      history: [],
      notes: [],
      completions: [completion],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    let request = try XCTUnwrap(client.lastRequest)
    let context = try XCTUnwrap(request.missedPatternContext)
    let expectedWindow = MissedEventInsightQuery.analysisBounds(
      for: .day,
      at: reviewNow,
      calendar: calendar
    )
    let tomorrow = try XCTUnwrap(
      calendar.date(
        byAdding: .day,
        value: 1,
        to: calendar.startOfDay(for: reviewNow)
      )
    )
    let weekEnd = try XCTUnwrap(
      calendar.date(byAdding: .day, value: 7, to: tomorrow)
    )

    XCTAssertEqual(context.sourceReviewPeriod, .day)
    XCTAssertEqual(
      context.windowStartAt.timeIntervalSince(expectedWindow.start),
      0,
      accuracy: 1
    )
    XCTAssertEqual(
      context.windowEndAt.timeIntervalSince(expectedWindow.end),
      0,
      accuracy: 1
    )
    XCTAssertEqual(context.groups.map(\.displayTitle), [
      "Study session",
      "Grocery pickup"
    ])
    XCTAssertEqual(context.inferredUnmarkedCount, 1)
    XCTAssertEqual(context.explicitIncompleteCount, 1)
    XCTAssertEqual(request.reviewSuggestionCount, 7)
    XCTAssertEqual(request.planningStart, tomorrow)
    XCTAssertEqual(request.planningEnd, weekEnd)
    XCTAssertEqual(calendarStore.refreshFromSystemCount, 1)
  }

  func testReviewExcludesClearedEventsFromAllOutboundEvidence()
    async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    calendar.firstWeekday = Calendar.current.firstWeekday
    let reviewNow = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 8,
          day: 6,
          hour: 12
        )
      )
    )
    let reviewBounds = FocusReviewPeriod.week.analysisBounds(
      at: reviewNow,
      calendar: calendar
    )
    let clearedStart = reviewBounds.start.addingTimeInterval(9 * 3_600)
    let retainedStart = reviewBounds.start.addingTimeInterval(33 * 3_600)
    let clearedDisplayEvent = CalendarDisplayEvent(
      completionKey: "cleared-event",
      title: "Cleared task",
      startAt: clearedStart,
      endAt: clearedStart.addingTimeInterval(3_600),
      isAllDay: false,
      calendarTitle: "Private Calendar"
    )
    let retainedDisplayEvent = CalendarDisplayEvent(
      completionKey: "retained-event",
      title: "Retained task",
      startAt: retainedStart,
      endAt: retainedStart.addingTimeInterval(3_600),
      isAllDay: false,
      calendarTitle: "Private Calendar"
    )
    let snapshotEvents = [clearedDisplayEvent, retainedDisplayEvent].map {
      event in
      CalendarEventSnapshot(
        eventId: event.completionKey,
        calendarId: "private-calendar",
        startAt: event.startAt,
        endAt: event.endAt,
        isAllDay: event.isAllDay,
        title: event.title,
        focusArea: nil,
        completionStatus: nil
      )
    }
    let clearedInterval = DateInterval(
      start: reviewBounds.start,
      end: retainedStart
    )
    let client = FakeTurnClient { request in
      makeReviewResponse(for: request)
    }
    let calendarStore = FakeCalendarStore()
    calendarStore.todayEvents = [clearedDisplayEvent, retainedDisplayEvent]
    calendarStore.reviewSnapshotResult = CalendarSnapshotResult(
      events: snapshotEvents,
      isTruncated: false
    )
    let (settings, suite) = makeSettings(
      trackingStartedAt: reviewNow.addingTimeInterval(-90 * 86_400)
    )
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(
      clientFactory: { _ in client },
      now: { reviewNow }
    )

    await viewModel.send(
      message: "/review week",
      history: [],
      notes: [],
      clearedIntervals: [clearedInterval],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    let request = try XCTUnwrap(client.lastRequest)
    XCTAssertEqual(request.reviewCalendar.map(\.eventId), ["retained-event"])
    XCTAssertEqual(
      request.missedPatternContext?.groups.map(\.displayTitle),
      ["Retained task"]
    )
    XCTAssertEqual(request.missedPatternContext?.missedEventCount, 1)
  }

  func testPlanningOnlyKeepsMissedPatternTitlesOnDevice() async throws {
    let now = Date()
    let client = FakeTurnClient(response: makePlanningResponse(proposalCount: 0))
    let calendarStore = FakeCalendarStore()
    calendarStore.todayEvents = [
      CalendarDisplayEvent(
        completionKey: "missed",
        title: "Grocery pickup",
        startAt: now.addingTimeInterval(-3_600),
        endAt: now.addingTimeInterval(-1_800),
        isAllDay: false,
        calendarTitle: "Private Calendar"
      )
    ]
    let (settings, suite) = makeSettings(
      trackingStartedAt: now.addingTimeInterval(-30 * 86_400)
    )
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(
      clientFactory: { _ in client },
      now: { now }
    )

    await viewModel.send(
      message: "Plan tomorrow using what I missed",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertTrue(client.lastRequest?.calendarActionRequested == true)
    XCTAssertNil(client.lastRequest?.missedPatternContext)
    XCTAssertTrue(client.lastRequest?.reviewCalendar.isEmpty == true)
    XCTAssertTrue(
      client.lastRequest?.calendar.allSatisfy { $0.title == nil } == true
    )
  }

  func testTodayLastWeekAndLastMonthUseTheirAnalysisBounds() async throws {
    for period in FocusReviewPeriod.allCases {
      let client = FakeTurnClient { request in
        makeReviewResponse(for: request)
      }
      let calendarStore = FakeCalendarStore()
      let (settings, suite) = makeSettings(
        trackingStartedAt: Date().addingTimeInterval(-90 * 86_400)
      )
      defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
      settings.aiDataConsent = true
      let viewModel = CoachViewModel(clientFactory: { _ in client })

      await viewModel.send(
        message: "/review \(period.rawValue)",
        history: [],
        notes: [],
        modelContext: try makeModelContext(),
        settings: settings,
        calendarService: calendarStore
      )

      let request = try XCTUnwrap(client.lastRequest)
      let expected = period.analysisBounds(
        at: request.currentTime,
        calendar: .current
      )
      XCTAssertEqual(request.focusReviewPeriod, period)
      XCTAssertEqual(
        try XCTUnwrap(request.focusReviewStart)
          .timeIntervalSince(expected.start),
        0,
        accuracy: 1
      )
      XCTAssertEqual(
        try XCTUnwrap(request.focusReviewEnd)
          .timeIntervalSince(expected.end),
        0,
        accuracy: 1
      )
      XCTAssertEqual(viewModel.focusReview?.period, period)
      XCTAssertEqual(viewModel.focusReview?.historyCoverage, .full)
      XCTAssertTrue(calendarStore.appliedProposals.isEmpty)
    }
  }

  func testNewUserHistoryBeforeTrackingIsNotTreatedAsMissingWork()
    async throws {
    let client = FakeTurnClient { request in
      makeReviewResponse(for: request)
    }
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review month",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertEqual(viewModel.focusReview?.historyCoverage, .beforeTracking)
    XCTAssertEqual(
      viewModel.focusReview?.trackingStartedAt,
      settings.trackingStartedAt
    )
    XCTAssertEqual(viewModel.focusReview?.suggestedEvents.count, 7)
  }

  func testTodayReviewWithPartialFirstUseHistoryIsAccepted() async throws {
    let calendar = Calendar.current
    let reviewNow = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 7,
          day: 18,
          hour: 16
        )
      )
    )
    let trackingStart = reviewNow.addingTimeInterval(-3_600)
    let client = FakeTurnClient { request in
      makeReviewResponse(
        for: request,
        warnings: [
          "This review period is not fully covered by the app's tracking history.",
          "Another useful warning."
        ]
      )
    }
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings(trackingStartedAt: trackingStart)
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(
      clientFactory: { _ in client },
      now: { reviewNow }
    )

    await viewModel.send(
      message: "/review day",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertEqual(viewModel.focusReview?.period, .day)
    XCTAssertEqual(viewModel.focusReview?.historyCoverage, .partial)
    XCTAssertFalse(
      viewModel.warnings.contains { $0.contains("evidence contract") }
    )
    XCTAssertFalse(
      viewModel.warnings.contains {
        $0 == "This review period is not fully covered by the app's tracking history."
      }
    )
    XCTAssertTrue(viewModel.warnings.contains("Another useful warning."))
  }

  func testReviewAcceptsRepeatSuggestionsForVisibleOrUnclearAreas()
    async throws {
    for visibility in [ScheduleVisibility.visible, .unclear] {
      let client = FakeTurnClient { request in
        let review = makeFocusReview(for: request)
        let suggestedArea = review.suggestedEvents[0].focusArea
        let areas = review.areas.map { area in
          guard area.focusArea == suggestedArea else { return area }
          return FocusAreaReview(
            focusArea: area.focusArea,
            recentVisibility: area.recentVisibility,
            upcomingVisibility: visibility,
            scheduledEvidence: area.scheduledEvidence,
            likelyImpact: area.likelyImpact,
            confidence: area.confidence
          )
        }
        return makeReviewResponse(
          for: request,
          review: replacingAreas(areas, in: review)
        )
      }
      let calendarStore = FakeCalendarStore()
      let (settings, suite) = makeSettings(
        trackingStartedAt: Date().addingTimeInterval(-90 * 86_400)
      )
      defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
      settings.aiDataConsent = true
      let viewModel = CoachViewModel(clientFactory: { _ in client })

      await viewModel.send(
        message: "/review week",
        history: [],
        notes: [],
        modelContext: try makeModelContext(),
        settings: settings,
        calendarService: calendarStore
      )

      XCTAssertEqual(
        viewModel.focusReview?.suggestedEvents.count,
        7,
        "Expected repeat suggestions for \(visibility.rawValue) areas"
      )
      XCTAssertFalse(
        viewModel.warnings.contains { $0.contains("evidence contract") }
      )
    }
  }

  func testUnsafeSuggestionBatchPreservesReviewWithoutSuggestions()
    async throws {
    let client = FakeTurnClient { request in
      let review = makeFocusReview(for: request)
      var suggestions = review.suggestedEvents
      let original = suggestions[0]
      suggestions[0] = FocusEventSuggestion(
        focusArea: original.focusArea,
        title: original.title,
        suggestedStartAt: request.currentTime.addingTimeInterval(-3_600),
        suggestedEndAt: request.currentTime.addingTimeInterval(-1_800),
        rationale: original.rationale,
        confidence: original.confidence,
        action: original.action
      )
      return makeReviewResponse(
        for: request,
        review: replacingSuggestions(suggestions, in: review)
      )
    }
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings(
      trackingStartedAt: Date().addingTimeInterval(-90 * 86_400)
    )
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review week",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertNotNil(viewModel.focusReview)
    XCTAssertTrue(viewModel.focusReview?.suggestedEvents.isEmpty == true)
    XCTAssertTrue(
      viewModel.warnings.contains {
        $0.contains("suggestions were withheld")
          && $0.contains("past")
      }
    )
    XCTAssertFalse(
      viewModel.warnings.contains { $0.contains("evidence contract") }
    )
  }

  func testReviewTruncationUsesHistoricalFlagAndSuppressesSuggestions()
    async throws {
    let client = FakeTurnClient { request in
      let review = makeFocusReview(for: request)
      return makeReviewResponse(
        for: request,
        review: replacingSuggestions(
          makeSevenSuggestions(for: request),
          in: review
        )
      )
    }
    let calendarStore = FakeCalendarStore()
    calendarStore.reviewSnapshotResult = CalendarSnapshotResult(
      events: [],
      isTruncated: true
    )
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review month",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertTrue(client.lastRequest?.reviewCalendarContextTruncated == true)
    XCTAssertTrue(client.lastRequest?.calendarContextTruncated == false)
    XCTAssertTrue(viewModel.focusReview?.contextTruncated == true)
    XCTAssertTrue(viewModel.focusReview?.suggestedEvents.isEmpty == true)
    XCTAssertTrue(
      viewModel.warnings.contains {
        $0.contains("suggestions were withheld")
          && $0.contains("calendar context was incomplete")
      }
    )
    XCTAssertFalse(
      viewModel.warnings.contains { $0.contains("evidence contract") }
    )
    XCTAssertTrue(
      viewModel.focusReview?.areas.allSatisfy {
        $0.recentVisibility == .unclear
      } == true
    )
  }

  func testReviewWorksWithNoCalendarEvents() async throws {
    let client = FakeTurnClient { request in
      makeReviewResponse(for: request)
    }
    let calendarStore = FakeCalendarStore()
    calendarStore.calendars = []
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review week",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertNotNil(client.lastRequest)
    XCTAssertEqual(calendarStore.snapshotCalls.first?.calendarCount, 0)
    XCTAssertNotNil(viewModel.focusReview)
    XCTAssertTrue(calendarStore.appliedProposals.isEmpty)
  }

  func testReviewRequiresCalendarPermission() async throws {
    let client = FakeTurnClient { request in
      makeReviewResponse(for: request)
    }
    let calendarStore = FakeCalendarStore()
    calendarStore.accessState = .denied
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review month",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertEqual(client.callCount, 0)
    XCTAssertNotNil(viewModel.errorMessage)
    XCTAssertNil(viewModel.focusReview)
  }

  func testHistoryIsLimitedToTheActiveCoachSession() async throws {
    let client = FakeTurnClient(
      response: makePlanningResponse(proposalCount: 0)
    )
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let context = try makeModelContext()
    let viewModel = CoachViewModel(clientFactory: { _ in client })
    let activeSession = UUID()
    let otherSession = UUID()
    let history = [
      ChatMessageRecord(
        role: .user,
        content: "Active session context",
        createdAt: Date().addingTimeInterval(-120),
        sessionId: activeSession
      ),
      ChatMessageRecord(
        role: .user,
        content: "Old session context",
        createdAt: Date().addingTimeInterval(-60),
        sessionId: otherSession
      )
    ]

    await viewModel.send(
      message: "Help me reset",
      history: history,
      notes: [NoteRecord(text: "Kept locally")],
      sessionId: activeSession,
      modelContext: context,
      settings: settings,
      calendarService: calendarStore
    )

    let request = try XCTUnwrap(client.lastRequest)
    XCTAssertEqual(request.history.map(\.content), ["Active session context"])
    XCTAssertTrue(request.notes.isEmpty)
    XCTAssertEqual(request.trackingStartedAt, settings.trackingStartedAt)
    let savedMessages = try context.fetch(
      FetchDescriptor<ChatMessageRecord>()
    )
    XCTAssertEqual(savedMessages.count, 2)
    XCTAssertTrue(savedMessages.allSatisfy { $0.sessionId == activeSession })
  }

  func testReviewWithholdsSuggestionBatchThatIsNotExactlySeven()
    async throws {
    let client = FakeTurnClient { request in
      let valid = makeFocusReview(for: request)
      let invalid = FocusReviewResult(
        areas: valid.areas,
        nextAdjustment: valid.nextAdjustment,
        suggestedEvents: Array(valid.suggestedEvents.prefix(1)),
        period: valid.period,
        recentStartAt: valid.recentStartAt,
        periodEndAt: valid.periodEndAt,
        currentTime: valid.currentTime,
        upcomingEndAt: valid.upcomingEndAt,
        trackingStartedAt: valid.trackingStartedAt,
        historyCoverage: valid.historyCoverage,
        completionEvidence: valid.completionEvidence,
        contextTruncated: valid.contextTruncated
      )
      return makeReviewResponse(for: request, review: invalid)
    }
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review month",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertNotNil(viewModel.focusReview)
    XCTAssertTrue(viewModel.focusReview?.suggestedEvents.isEmpty == true)
    XCTAssertTrue(
      viewModel.warnings.contains {
        $0.contains("suggestions were withheld")
          && $0.contains("exactly seven")
      }
    )
    XCTAssertFalse(
      viewModel.warnings.contains { $0.contains("evidence contract") }
    )
    XCTAssertTrue(calendarStore.appliedProposals.isEmpty)
  }

  func testReviewRejectsTrueCompletionEvidenceMismatch() async throws {
    let client = FakeTurnClient { request in
      let valid = makeFocusReview(for: request)
      let invalid = FocusReviewResult(
        areas: valid.areas,
        nextAdjustment: valid.nextAdjustment,
        suggestedEvents: valid.suggestedEvents,
        period: valid.period,
        recentStartAt: valid.recentStartAt,
        periodEndAt: valid.periodEndAt,
        currentTime: valid.currentTime,
        upcomingEndAt: valid.upcomingEndAt,
        trackingStartedAt: valid.trackingStartedAt,
        historyCoverage: valid.historyCoverage,
        completionEvidence: .userInput,
        contextTruncated: valid.contextTruncated
      )
      return makeReviewResponse(for: request, review: invalid)
    }
    let calendarStore = FakeCalendarStore()
    let (settings, suite) = makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    settings.aiDataConsent = true
    let viewModel = CoachViewModel(clientFactory: { _ in client })

    await viewModel.send(
      message: "/review month",
      history: [],
      notes: [],
      modelContext: try makeModelContext(),
      settings: settings,
      calendarService: calendarStore
    )

    XCTAssertNil(viewModel.focusReview)
    XCTAssertTrue(
      viewModel.warnings.contains { $0.contains("evidence contract") }
    )
  }

  private func makeSettings(
    trackingStartedAt: Date? = nil,
    includeAppSecret: Bool = true
  ) -> (AppSettings, String) {
    let suite = "CoachViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AppSettings(
      defaults: defaults,
      secureStore: ViewModelSecureStore(),
      now: { trackingStartedAt ?? Date() }
    )
    settings.apiBaseURLString = "http://localhost:8000/api/v1"
    if includeAppSecret {
      try! settings.saveAppSecret("test-deployment-secret")
    }
    return (settings, suite)
  }

  private func makeModelContext() throws -> ModelContext {
    let schema = Schema([
      NoteRecord.self,
      ChatMessageRecord.self,
      CheckInRecord.self,
      CalendarAuditRecord.self,
      PendingCalendarProposalRecord.self,
      CalendarEventCompletionRecord.self
    ])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    return ModelContext(container)
  }
}

private func makePlanningResponse(
  proposalCount: Int
) -> AgentTurnResponse {
  let start = Date().addingTimeInterval(86_400)
  let proposals = (0..<proposalCount).map { index in
    let proposalStart = start.addingTimeInterval(Double(index) * 3_600)
    return CalendarProposal(
      proposalId: UUID(),
      title: "Block \(index + 1)",
      startAt: proposalStart,
      endAt: proposalStart.addingTimeInterval(1_800),
      focusArea: .work,
      rationale: "Advance one concrete result.",
      notes: "",
      reminderMinutes: 10
    )
  }
  return AgentTurnResponse(
    requestId: UUID(),
    message: "I built a realistic plan.",
    proposals: proposals,
    checkInQuestion: nil,
    warnings: [],
    provider: "openai",
    model: "test-model"
  )
}

private func makeReviewResponse(
  for request: AgentTurnRequest,
  review: FocusReviewResult? = nil,
  warnings: [String] = []
) -> AgentTurnResponse {
  AgentTurnResponse(
    requestId: UUID(),
    message: "Here is your calendar review.",
    proposals: [],
    checkInQuestion: nil,
    warnings: warnings,
    provider: "openai",
    model: "test-model",
    focusReview: review ?? makeFocusReview(for: request)
  )
}

private func makeFocusReview(
  for request: AgentTurnRequest
) -> FocusReviewResult {
  let period = request.focusReviewPeriod ?? .week
  let periodStart = request.focusReviewStart ?? request.currentTime
  let periodEnd = request.focusReviewEnd ?? request.currentTime
  let contextTruncated = request.reviewCalendarContextTruncated
    || request.calendarContextTruncated
  let historyCoverage: FocusReviewHistoryCoverage
  if request.trackingStartedAt <= periodStart {
    historyCoverage = .full
  } else if request.trackingStartedAt < periodEnd {
    historyCoverage = .partial
  } else {
    historyCoverage = .beforeTracking
  }
  let completionEvidence: FocusReviewCompletionEvidence =
    request.reviewCalendar.contains { $0.completionStatus != nil }
      ? .userInput : .notProvided
  let selectedAreas = request.preferences.selectedFocusAreas
  let areas = selectedAreas.map { area in
    FocusAreaReview(
      focusArea: area,
      recentVisibility: request.reviewCalendarContextTruncated
        ? .unclear : .notVisible,
      upcomingVisibility: request.calendarContextTruncated
        ? .unclear : .notVisible,
      scheduledEvidence: contextTruncated
        ? "The calendar snapshot is incomplete."
        : "No matching calendar event is visible.",
      likelyImpact: contextTruncated
        ? "Impact cannot be assessed from incomplete evidence."
        : "A protected block may support this goal.",
      confidence: contextTruncated ? .low : .medium
    )
  }

  return FocusReviewResult(
    areas: areas,
    nextAdjustment: "Protect the next seven useful blocks.",
    suggestedEvents: contextTruncated
      ? [] : makeSevenSuggestions(for: request),
    period: period,
    recentStartAt: periodStart,
    periodEndAt: periodEnd,
    currentTime: request.currentTime,
    upcomingEndAt: request.planningEnd,
    trackingStartedAt: request.trackingStartedAt,
    historyCoverage: historyCoverage,
    completionEvidence: completionEvidence,
    contextTruncated: contextTruncated
  )
}

private func replacingAreas(
  _ areas: [FocusAreaReview],
  in review: FocusReviewResult
) -> FocusReviewResult {
  FocusReviewResult(
    areas: areas,
    nextAdjustment: review.nextAdjustment,
    suggestedEvents: review.suggestedEvents,
    period: review.period,
    recentStartAt: review.recentStartAt,
    periodEndAt: review.periodEndAt,
    currentTime: review.currentTime,
    upcomingEndAt: review.upcomingEndAt,
    trackingStartedAt: review.trackingStartedAt,
    historyCoverage: review.historyCoverage,
    completionEvidence: review.completionEvidence,
    contextTruncated: review.contextTruncated
  )
}

private func replacingSuggestions(
  _ suggestions: [FocusEventSuggestion],
  in review: FocusReviewResult
) -> FocusReviewResult {
  FocusReviewResult(
    areas: review.areas,
    nextAdjustment: review.nextAdjustment,
    suggestedEvents: suggestions,
    period: review.period,
    recentStartAt: review.recentStartAt,
    periodEndAt: review.periodEndAt,
    currentTime: review.currentTime,
    upcomingEndAt: review.upcomingEndAt,
    trackingStartedAt: review.trackingStartedAt,
    historyCoverage: review.historyCoverage,
    completionEvidence: review.completionEvidence,
    contextTruncated: review.contextTruncated
  )
}

private func makeSevenSuggestions(
  for request: AgentTurnRequest
) -> [FocusEventSuggestion] {
  let calendar = Calendar.current
  let dayStart = calendar.startOfDay(for: request.currentTime)
  let focusArea = request.preferences.selectedFocusAreas.first
    ?? .work
  return (1...7).compactMap { dayOffset in
    guard let day = calendar.date(
      byAdding: .day,
      value: dayOffset,
      to: dayStart
    ),
    let start = calendar.date(
      bySettingHour: 18,
      minute: 0,
      second: 0,
      of: day
    ) else {
      return nil
    }
    let end = start.addingTimeInterval(3_600)
    guard start >= request.planningStart,
          end <= request.planningEnd else {
      return nil
    }
    return FocusEventSuggestion(
      focusArea: focusArea,
      title: "Focus block \(dayOffset)",
      suggestedStartAt: start,
      suggestedEndAt: end,
      rationale: "Protect one concrete step toward this goal.",
      confidence: .medium,
      action: .requiresExplicitScheduling
    )
  }
}
