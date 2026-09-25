import XCTest
@testable import CalendarAgent

final class MissedEventInsightTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_784_808_000)
  private let trackingStartedAt = Date(timeIntervalSince1970: 1_782_864_000)

  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    value.firstWeekday = 2
    return value
  }

  func testCountsExplicitIncompleteAndEndedUnmarkedAsOneEach() {
    let events = [
      event("complete", title: "Completed work", hoursFromNow: -3 ... -2),
      event("incomplete", title: "Grocery pickup", hoursFromNow: -3 ... -2),
      event("unmarked", title: "Project planning", hoursFromNow: -2 ... -1),
      event("ongoing", title: "Ongoing work", hoursFromNow: -1 ... 1),
      event("future", title: "Future work", hoursFromNow: 1 ... 2),
      event("early-stop", title: "Exercise", hoursFromNow: -1 ... 1)
    ]
    let result = build(
      events,
      statuses: [
        "complete": .complete,
        "incomplete": .incomplete,
        "future": .incomplete,
        "early-stop": .incomplete
      ]
    )

    XCTAssertEqual(result.missedEventCount, 3)
    XCTAssertEqual(result.inferredUnmarkedCount, 1)
    XCTAssertEqual(result.explicitIncompleteCount, 2)
    XCTAssertEqual(
      result.groups.map(\.displayTitle),
      ["Exercise", "Project planning", "Grocery pickup"]
    )
    XCTAssertTrue(
      result.heading.contains("Likely missed during the past 7 days")
    )
  }

  func testUnmarkedBecomesEligibleExactlyAtItsEnd() {
    let endedNow = CalendarDisplayEvent(
      completionKey: "ended-now",
      title: "Deep work",
      startAt: now.addingTimeInterval(-3_600),
      endAt: now,
      isAllDay: false,
      calendarTitle: "Personal"
    )

    let result = build([endedNow])

    XCTAssertEqual(result.missedEventCount, 1)
    XCTAssertEqual(result.inferredUnmarkedCount, 1)
  }

  func testPreTrackingUnmarkedIsExcludedButExplicitStatusIsAuthoritative() {
    let oldUnmarked = event(
      "old-unmarked",
      title: "Old unmarked",
      hoursFromNow: -600 ... -599
    )
    let oldIncomplete = event(
      "old-incomplete",
      title: "Old incomplete",
      hoursFromNow: -600 ... -599
    )

    let result = build(
      [oldUnmarked, oldIncomplete],
      statuses: ["old-incomplete": .incomplete],
      period: .month,
      trackingStartedAt: now.addingTimeInterval(-100 * 3_600)
    )

    XCTAssertEqual(result.missedEventCount, 1)
    XCTAssertEqual(result.groups.map(\.displayTitle), ["Old incomplete"])
    XCTAssertEqual(result.inferredUnmarkedCount, 0)
  }

  func testClearedIntervalExcludesExplicitAndInferredMisses() {
    let clearedExplicit = event(
      "cleared-explicit",
      title: "Cleared explicit",
      hoursFromNow: -6 ... -5
    )
    let clearedUnmarked = event(
      "cleared-unmarked",
      title: "Cleared unmarked",
      hoursFromNow: -4 ... -3
    )
    let retainedAtBoundary = event(
      "retained",
      title: "Retained",
      hoursFromNow: -2 ... -1
    )
    let clearedInterval = DateInterval(
      start: clearedExplicit.startAt,
      end: retainedAtBoundary.startAt
    )

    let result = build(
      [clearedExplicit, clearedUnmarked, retainedAtBoundary],
      statuses: ["cleared-explicit": .incomplete],
      clearedIntervals: [clearedInterval]
    )

    XCTAssertEqual(result.groups.map(\.displayTitle), ["Retained"])
    XCTAssertEqual(result.evaluatedEventCount, 1)
    XCTAssertEqual(result.coveredEvaluatedEventCount, 1)
    XCTAssertEqual(result.missedEventCount, 1)
    XCTAssertEqual(result.inferredUnmarkedCount, 1)
    XCTAssertEqual(result.explicitIncompleteCount, 0)
  }

  func testHistoryClearImmediatelyDropsCachedInsightForEveryScope() {
    let staleEvent = event(
      "stale",
      title: "Stale missed event",
      hoursFromNow: -2 ... -1
    )

    for scope in ClearHistoryScope.allCases {
      var cache = CoachMissedInsightCache(
        events: [staleEvent],
        loadState: .loaded
      )

      cache.prepareForHistoryClear(
        scope,
        at: now,
        calendar: calendar
      )

      XCTAssertTrue(cache.events.isEmpty, "Failed scope: \(scope.rawValue)")
      XCTAssertEqual(cache.loadState, .loading)
      XCTAssertEqual(
        cache.effectiveClearedIntervals([]),
        scope.analysisInterval(at: now, calendar: calendar).map { [$0] } ?? []
      )
    }
  }

  func testPreviousWeekAndMonthIntervalsCannotRebuildClearedInsight()
    throws {
    let reference = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T12:00:00Z")
    )

    for (scope, period) in [
      (ClearHistoryScope.week, FocusReviewPeriod.week),
      (ClearHistoryScope.month, FocusReviewPeriod.month)
    ] {
      let interval = try XCTUnwrap(
        scope.analysisInterval(at: reference, calendar: calendar)
      )
      let occurrence = interval.start.addingTimeInterval(3_600)
      let clearedEvent = CalendarDisplayEvent(
        completionKey: "cleared-\(scope.rawValue)",
        title: "Cleared \(scope.rawValue)",
        startAt: occurrence,
        endAt: occurrence.addingTimeInterval(3_600),
        isAllDay: false,
        calendarTitle: "Personal"
      )

      let result = build(
        [clearedEvent],
        period: period,
        now: reference,
        trackingStartedAt: reference.addingTimeInterval(-120 * 86_400),
        clearedIntervals: [interval]
      )

      XCTAssertTrue(result.groups.isEmpty, "Failed scope: \(scope.rawValue)")
      XCTAssertEqual(result.missedEventCount, 0)
    }
  }

  func testGroupsOnlyConservativeNormalizedTitleFamilies() {
    let events = [
      event("one", title: "Project planning", hoursFromNow: -8 ... -7),
      event("two", title: "  project-planning  ", hoursFromNow: -6 ... -5),
      event("three", title: "PRÓJECT PLANNING session-3", hoursFromNow: -4 ... -3),
      event("four", title: "Morning exercise", hoursFromNow: -8 ... -7),
      event("five", title: "Evening exercise", hoursFromNow: -6 ... -5),
      event("six", title: "Read chapter", hoursFromNow: -4 ... -3),
      event("seven", title: "Read manual", hoursFromNow: -2 ... -1)
    ]

    let result = build(events)

    XCTAssertEqual(result.groups.first?.missedCount, 3)
    XCTAssertEqual(result.groups.first?.familyKey, "project planning")
    XCTAssertEqual(result.groups.first?.displayTitle, "PRÓJECT PLANNING")
    XCTAssertEqual(result.groups.count, 5)
    XCTAssertNotEqual(
      MissedEventInsightBuilder.titleFamilyKey("Morning exercise"),
      MissedEventInsightBuilder.titleFamilyKey("Evening exercise")
    )
    XCTAssertNotEqual(
      MissedEventInsightBuilder.titleFamilyKey("Read chapter"),
      MissedEventInsightBuilder.titleFamilyKey("Read manual")
    )
    XCTAssertNotEqual(
      MissedEventInsightBuilder.titleFamilyKey("Writer's block"),
      MissedEventInsightBuilder.titleFamilyKey("Writers")
    )
    XCTAssertNotEqual(
      MissedEventInsightBuilder.titleFamilyKey("Law practice"),
      MissedEventInsightBuilder.titleFamilyKey("Law")
    )
  }

  func testBareNumberedSessionsUseOneNonemptyFamily() {
    let result = build([
      event("one", title: "Session 1", hoursFromNow: -4 ... -3),
      event("two", title: "Session-2", hoursFromNow: -2 ... -1)
    ])

    XCTAssertEqual(result.groups.count, 1)
    XCTAssertEqual(result.groups.first?.familyKey, "session")
    XCTAssertEqual(result.groups.first?.displayTitle, "Session")
    XCTAssertEqual(result.groups.first?.missedCount, 2)
  }

  func testOvernightOccurrenceUsesItsStartForRollingSevenDayWindow()
    throws {
    let reference = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T12:00:00Z")
    )
    let overnight = CalendarDisplayEvent(
      completionKey: "overnight",
      title: "Late study",
      startAt: try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-07-16T23:00:00Z")
      ),
      endAt: try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-07-17T01:00:00Z")
      ),
      isAllDay: false,
      calendarTitle: "Personal"
    )

    let today = build(
      [overnight],
      statuses: ["overnight": .incomplete],
      period: .day,
      now: reference
    )
    let lastWeek = build(
      [overnight],
      statuses: ["overnight": .incomplete],
      period: .week,
      now: reference
    )

    XCTAssertTrue(today.groups.isEmpty)
    XCTAssertEqual(lastWeek.groups.map(\.displayTitle), ["Late study"])
  }

  func testTodayInsightAggregatesRepeatedTitlesAcrossPastSevenDates()
    throws {
    let reference = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T12:00:00Z")
    )
    let events = [
      event(
        "boundary",
        title: "Grocery pickup",
        start: "2026-07-17T00:00:00Z",
        end: "2026-07-17T01:00:00Z"
      ),
      event(
        "middle",
        title: "Grocery pickup",
        start: "2026-07-20T08:00:00Z",
        end: "2026-07-20T09:00:00Z"
      ),
      event(
        "today",
        title: "Grocery pickup",
        start: "2026-07-23T08:00:00Z",
        end: "2026-07-23T09:00:00Z"
      ),
      event(
        "before-boundary",
        title: "Grocery pickup",
        start: "2026-07-16T23:00:00Z",
        end: "2026-07-16T23:30:00Z"
      )
    ]

    let result = build(
      events,
      now: reference,
      trackingStartedAt: try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z")
      )
    )

    XCTAssertEqual(result.groups.map(\.displayTitle), ["Grocery pickup"])
    XCTAssertEqual(result.groups.first?.missedCount, 3)
    XCTAssertEqual(
      result.heading,
      "Likely missed during the past 7 days · unmarked included"
    )
  }

  func testAllDayUnmarkedBecomesEligibleAtElevenPM() throws {
    let start = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T00:00:00Z")
    )
    let end = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z")
    )
    let allDay = CalendarDisplayEvent(
      completionKey: "all-day",
      title: "All-day commitment",
      startAt: start,
      endAt: end,
      isAllDay: true,
      calendarTitle: "Personal"
    )
    let beforeCutoff = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T22:59:00Z")
    )
    let atCutoff = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T23:00:00Z")
    )

    XCTAssertEqual(
      build([allDay], now: beforeCutoff).missedEventCount,
      0
    )
    XCTAssertEqual(build([allDay], now: atCutoff).missedEventCount, 1)
  }

  func testMultiDayAllDayEventBelongsToItsFinalCoveredDay() throws {
    let event = CalendarDisplayEvent(
      completionKey: "multi-day",
      title: "Conference",
      startAt: try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-07-21T00:00:00Z")
      ),
      endAt: try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z")
      ),
      isAllDay: true,
      calendarTitle: "Personal"
    )
    let firstDayCutoff = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-21T23:00:00Z")
    )
    let finalDayCutoff = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T23:00:00Z")
    )

    XCTAssertEqual(
      build([event], now: firstDayCutoff).missedEventCount,
      0
    )
    XCTAssertEqual(
      build([event], now: finalDayCutoff).missedEventCount,
      1
    )
  }

  func testMultiDayAllDayExplicitIncompleteCountsWhileInProgress()
    throws {
    let event = CalendarDisplayEvent(
      completionKey: "multi-day-incomplete",
      title: "Conference",
      startAt: try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-07-21T00:00:00Z")
      ),
      endAt: try XCTUnwrap(
        ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z")
      ),
      isAllDay: true,
      calendarTitle: "Personal"
    )
    let firstDay = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-21T12:00:00Z")
    )

    let result = build(
      [event],
      statuses: ["multi-day-incomplete": .incomplete],
      now: firstDay
    )

    XCTAssertEqual(result.missedEventCount, 1)
    XCTAssertEqual(result.explicitIncompleteCount, 1)
  }

  func testExplicitIncompleteCountsExactlyAtEventStart() {
    let startingNow = CalendarDisplayEvent(
      completionKey: "starting-now",
      title: "Starting now",
      startAt: now,
      endAt: now.addingTimeInterval(3_600),
      isAllDay: false,
      calendarTitle: "Personal"
    )

    let result = build(
      [startingNow],
      statuses: ["starting-now": .incomplete]
    )

    XCTAssertEqual(result.missedEventCount, 1)
  }

  func testSelectedPeriodUsesTodayPreviousWeekAndPreviousMonth() throws {
    let reference = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T12:00:00Z")
    )
    let events = [
      event(
        "today",
        title: "Today event",
        start: "2026-07-23T08:00:00Z",
        end: "2026-07-23T09:00:00Z"
      ),
      event(
        "week",
        title: "Last week event",
        start: "2026-07-15T08:00:00Z",
        end: "2026-07-15T09:00:00Z"
      ),
      event(
        "month",
        title: "Last month event",
        start: "2026-06-15T08:00:00Z",
        end: "2026-06-15T09:00:00Z"
      )
    ]

    let today = build(events, period: .day, now: reference)
    let week = build(events, period: .week, now: reference)
    let month = build(
      events,
      period: .month,
      now: reference,
      trackingStartedAt: ISO8601DateFormatter().date(
        from: "2026-05-01T00:00:00Z"
      )
    )

    XCTAssertEqual(today.groups.map(\.displayTitle), ["Today event"])
    XCTAssertEqual(week.groups.map(\.displayTitle), ["Last week event"])
    XCTAssertEqual(month.groups.map(\.displayTitle), ["Last month event"])
  }

  func testQueryFetchesPastSevenDatesAndExactHistoricalPeriods() throws {
    let reference = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-23T12:00:00Z")
    )
    let today = MissedEventInsightQuery.fetchBounds(
      for: .day,
      at: reference,
      calendar: calendar
    )
    let week = MissedEventInsightQuery.fetchBounds(
      for: .week,
      at: reference,
      calendar: calendar
    )
    let month = MissedEventInsightQuery.fetchBounds(
      for: .month,
      at: reference,
      calendar: calendar
    )

    let todayStart = calendar.startOfDay(for: reference)
    XCTAssertEqual(
      today.start,
      calendar.date(byAdding: .day, value: -6, to: todayStart)
    )
    XCTAssertEqual(
      today.end,
      calendar.date(byAdding: .day, value: 1, to: todayStart)
    )
    XCTAssertEqual(
      week,
      FocusReviewPeriod.week.analysisBounds(
        at: reference,
        calendar: calendar
      )
    )
    XCTAssertEqual(
      month,
      FocusReviewPeriod.month.analysisBounds(
        at: reference,
        calendar: calendar
      )
    )
  }

  func testDeduplicatesCompletionKeyButCountsRecurringOccurrences() {
    let duplicate = event(
      "same-key",
      title: "Grocery pickup",
      hoursFromNow: -5 ... -4
    )
    let events = [
      duplicate,
      duplicate,
      event("occurrence-2", title: "Grocery pickup", hoursFromNow: -3 ... -2)
    ]

    let result = build(events)

    XCTAssertEqual(result.missedEventCount, 2)
    XCTAssertEqual(result.groups.first?.missedCount, 2)
  }

  func testStableOrderingAndTopThreePresentation() {
    let events = [
      event("exercise-1", title: "Exercise", hoursFromNow: -10 ... -9),
      event("exercise-2", title: "Exercise", hoursFromNow: -8 ... -7),
      event("errand-1", title: "Grocery pickup", hoursFromNow: -6 ... -5),
      event("errand-2", title: "Grocery pickup", hoursFromNow: -4 ... -3),
      event("work", title: "Project planning", hoursFromNow: -3 ... -2),
      event("appointment", title: "Scheduled appointment", hoursFromNow: -2 ... -1)
    ]

    let result = build(events)

    XCTAssertEqual(
      result.groups.map(\.displayTitle),
      ["Grocery pickup", "Exercise", "Scheduled appointment", "Project planning"]
    )
    XCTAssertEqual(result.displayedGroups.count, 3)
    XCTAssertEqual(result.remainingGroupCount, 1)
    XCTAssertTrue(result.hasMoreGroups)
    XCTAssertEqual(
      result.hiddenGroups.map(\.displayTitle),
      ["Project planning"]
    )
    XCTAssertEqual(result.moreButtonTitle, "+1 more")
    XCTAssertEqual(
      result.moreButtonAccessibilityLabel,
      "Show 1 more missed event type"
    )
    XCTAssertLessThanOrEqual(1 + result.displayedGroups.count, 4)
  }

  func testDetailBreakdownDistinguishesLikelyAndExplicitMisses() {
    let result = build(
      [
        event("unmarked", title: "Grocery pickup", hoursFromNow: -4 ... -3),
        event("incomplete", title: "Grocery pickup", hoursFromNow: -2 ... -1)
      ],
      statuses: ["incomplete": .incomplete]
    )

    XCTAssertEqual(result.groups.first?.missedCountText, "2 times")
    XCTAssertEqual(
      result.groups.first?.evidenceSummary,
      "1 ended without a choice · 1 marked Incomplete"
    )
  }

  func testTenGroupsExposeSevenMoreWithAccessibleLabel() {
    let events = (1 ... 10).map { index in
      let endHour = -index
      return event(
        "event-\(index)",
        title: "Event \(index)",
        hoursFromNow: (endHour - 1) ... endHour
      )
    }
    let result = build(events)

    XCTAssertEqual(result.displayedGroups.count, 3)
    XCTAssertEqual(result.hiddenGroups.count, 7)
    XCTAssertEqual(result.moreButtonTitle, "+7 more")
    XCTAssertEqual(
      result.moreButtonAccessibilityLabel,
      "Show 7 more missed event types"
    )
  }

  func testThreeGroupsDoNotOfferMoreButton() {
    let result = build([
      event("one", title: "One", hoursFromNow: -6 ... -5),
      event("two", title: "Two", hoursFromNow: -4 ... -3),
      event("three", title: "Three", hoursFromNow: -2 ... -1)
    ])

    XCTAssertFalse(result.hasMoreGroups)
    XCTAssertTrue(result.hiddenGroups.isEmpty)
    XCTAssertNil(result.moreButtonTitle)
    XCTAssertNil(result.moreButtonAccessibilityLabel)
  }

  func testEmptyAndAllCompleteStatesAreHonest() {
    let empty = build([])
    let allComplete = build(
      [event("complete", title: "Exercise", hoursFromNow: -2 ... -1)],
      statuses: ["complete": .complete]
    )

    XCTAssertEqual(
      empty.emptyMessage,
      "No ended calendar events to evaluate during the past 7 days."
    )
    XCTAssertEqual(
      allComplete.emptyMessage,
      "No likely missed events found during the past 7 days."
    )
  }

  func testPartialAndUnavailableTrackingCoverageAreReported() {
    let partial = build(
      [event("missed", title: "Exercise", hoursFromNow: -2 ... -1)],
      trackingStartedAt: calendar.startOfDay(for: now)
        .addingTimeInterval(3_600)
    )
    let noHistory = build(
      [],
      period: .month,
      trackingStartedAt: now
    )

    XCTAssertEqual(partial.trackingCoverage, .partial)
    XCTAssertTrue(partial.heading.contains("partial tracking"))
    XCTAssertEqual(noHistory.trackingCoverage, .none)
    XCTAssertEqual(
      noHistory.emptyMessage,
      "Not enough tracked history for last month yet."
    )
  }

  func testPartialTrackingEmptyMessagesDescribeCoveredHistory() {
    let trackingStart = now.addingTimeInterval(-2 * 3_600)
    let onlyPreTracking = build(
      [event("old", title: "Old event", hoursFromNow: -4 ... -3)],
      trackingStartedAt: trackingStart
    )
    let onlyComplete = build(
      [event("done", title: "Done", hoursFromNow: -1 ... 0)],
      statuses: ["done": .complete],
      trackingStartedAt: trackingStart
    )

    XCTAssertEqual(
      onlyPreTracking.emptyMessage,
      "No tracked ended events to evaluate during the past 7 days yet."
    )
    XCTAssertEqual(
      onlyComplete.emptyMessage,
      "No likely missed events in the tracked part of the past 7 days."
    )
  }

  func testUnavailableAndPartialCoverageDisclosePreTrackingCompleteOnly() {
    let oldComplete = event(
      "old-complete",
      title: "Old complete",
      hoursFromNow: -1_000 ... -999
    )
    let partial = build(
      [oldComplete],
      statuses: ["old-complete": .complete],
      period: .month,
      trackingStartedAt: now.addingTimeInterval(-900 * 3_600)
    )
    let unavailable = build(
      [oldComplete],
      statuses: ["old-complete": .complete],
      period: .month,
      trackingStartedAt: now
    )

    XCTAssertEqual(
      partial.emptyMessage,
      "No tracked ended events to evaluate last month yet."
    )
    XCTAssertEqual(
      unavailable.emptyMessage,
      "No misses in explicit records; tracking had not started last month."
    )
  }

  func testContextPayloadPreservesRankedBreakdownAndReportsOmittedGroups() {
    let events = (1 ... 30).map { index in
      event(
        "event-\(index)",
        title: "Pattern \(index)",
        hoursFromNow: (-index - 1) ... -index
      )
    }
    let result = build(events)
    let bounds = MissedEventInsightQuery.analysisBounds(
      for: .day,
      at: now,
      calendar: calendar
    )

    let payload = result.contextPayload(window: bounds)

    XCTAssertEqual(payload.sourceReviewPeriod, .day)
    XCTAssertEqual(payload.windowStartAt, bounds.start)
    XCTAssertEqual(payload.windowEndAt, bounds.end)
    XCTAssertEqual(payload.groups.count, 25)
    XCTAssertEqual(payload.groups.map(\.rank), Array(1 ... 25))
    XCTAssertEqual(payload.omittedGroupCount, 5)
    XCTAssertEqual(payload.missedEventCount, 30)
    XCTAssertEqual(payload.inferredUnmarkedCount, 30)
    XCTAssertEqual(payload.explicitIncompleteCount, 0)
    XCTAssertEqual(
      payload.groups.first?.missedCount,
      (payload.groups.first?.inferredUnmarkedCount ?? 0)
        + (payload.groups.first?.explicitIncompleteCount ?? 0)
    )
  }

  private func build(
    _ events: [CalendarDisplayEvent],
    statuses: [String: CalendarEventCompletionStatus] = [:],
    period: FocusReviewPeriod = .day,
    now: Date? = nil,
    trackingStartedAt: Date? = nil,
    clearedIntervals: [DateInterval] = []
  ) -> MissedEventInsight {
    MissedEventInsightBuilder.build(
      events: events,
      completionStatuses: statuses,
      period: period,
      now: now ?? self.now,
      trackingStartedAt: trackingStartedAt ?? self.trackingStartedAt,
      calendar: calendar,
      clearedIntervals: clearedIntervals
    )
  }

  private func event(
    _ key: String,
    title: String,
    hoursFromNow: ClosedRange<Int>
  ) -> CalendarDisplayEvent {
    CalendarDisplayEvent(
      completionKey: key,
      title: title,
      startAt: now.addingTimeInterval(
        TimeInterval(hoursFromNow.lowerBound * 3_600)
      ),
      endAt: now.addingTimeInterval(
        TimeInterval(hoursFromNow.upperBound * 3_600)
      ),
      isAllDay: false,
      calendarTitle: "Personal"
    )
  }

  private func event(
    _ key: String,
    title: String,
    start: String,
    end: String
  ) -> CalendarDisplayEvent {
    CalendarDisplayEvent(
      completionKey: key,
      title: title,
      startAt: ISO8601DateFormatter().date(from: start)!,
      endAt: ISO8601DateFormatter().date(from: end)!,
      isAllDay: false,
      calendarTitle: "Personal"
    )
  }
}
