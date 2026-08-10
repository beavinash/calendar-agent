import XCTest
@testable import CalendarAgent

final class ScheduleValidatorTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }

  private func date(
    _ hour: Int,
    minute: Int = 0,
    day: Int = 16
  ) -> Date {
    DateComponents(
      calendar: calendar,
      timeZone: TimeZone(secondsFromGMT: 0),
      year: 2026,
      month: 7,
      day: day,
      hour: hour,
      minute: minute
    ).date!
  }

  private func proposal(
    startHour: Int = 18,
    startMinute: Int = 0,
    endHour: Int = 19,
    endMinute: Int = 0,
    day: Int = 16,
    focusArea: FocusArea = .work
  ) -> CalendarProposal {
    CalendarProposal(
      proposalId: UUID(),
      title: "Project planning",
      startAt: date(startHour, minute: startMinute, day: day),
      endAt: date(endHour, minute: endMinute, day: day),
      focusArea: focusArea,
      rationale: "Move one result forward.",
      notes: "Define the outcome.",
      reminderMinutes: 10
    )
  }

  private func constraints() -> LocalScheduleConstraints {
    LocalScheduleConstraints(
      now: date(5),
      planningStart: date(5, minute: 30),
      planningEnd: date(23, day: 19),
      dayStartMinutes: 6 * 60,
      morningEndMinutes: 8 * 60,
      eveningStartMinutes: 17 * 60 + 30,
      dayEndMinutes: 23 * 60,
      maxBlockMinutes: 240,
      maxDailyBlocks: 5,
      minimumBreakMinutes: 10,
      selectedFocusAreas: Set(FocusArea.allCases),
      calendar: calendar
    )
  }

  func testAcceptsMorningAndEveningBoundaries() throws {
    XCTAssertNoThrow(
      try ScheduleValidator.validate(
        proposal(
          startHour: 6,
          startMinute: 30,
          endHour: 7,
          endMinute: 30
        ),
        busyIntervals: [],
        constraints: constraints(),
        mode: .standard
      )
    )
    XCTAssertNoThrow(
      try ScheduleValidator.validate(
        proposal(
          startHour: 17,
          startMinute: 30,
          endHour: 18,
          endMinute: 30
        ),
        busyIntervals: [],
        constraints: constraints(),
        mode: .standard
      )
    )
  }

  func testStandardWeekendProposalAllowsFortyFiveMinutes() throws {
    XCTAssertNoThrow(
      try ScheduleValidator.validate(
        proposal(
          startHour: 13,
          endHour: 13,
          endMinute: 45,
          day: 18
        ),
        busyIntervals: [],
        constraints: constraints(),
        mode: .standard
      )
    )
  }

  func testReviewWeekendSuggestionsRequireOneToTwoHours() throws {
    XCTAssertNoThrow(
      try ScheduleValidator.validate(
        proposal(startHour: 6, endHour: 7, day: 18),
        busyIntervals: [],
        constraints: constraints(),
        mode: .reviewSuggestion
      )
    )
    XCTAssertNoThrow(
      try ScheduleValidator.validate(
        proposal(startHour: 13, endHour: 15, day: 18),
        busyIntervals: [],
        constraints: constraints(),
        mode: .reviewSuggestion
      )
    )
    XCTAssertNoThrow(
      try ScheduleValidator.validate(
        proposal(startHour: 21, endHour: 23, day: 18),
        busyIntervals: [],
        constraints: constraints(),
        mode: .reviewSuggestion
      )
    )

    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        proposal(
          startHour: 6,
          endHour: 6,
          endMinute: 45,
          day: 18
        ),
        busyIntervals: [],
        constraints: constraints(),
        mode: .reviewSuggestion
      )
    ) { error in
      XCTAssertEqual(
        error as? ScheduleValidationError,
        .weekendReviewDuration
      )
    }
    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        proposal(
          startHour: 20,
          endHour: 22,
          endMinute: 1,
          day: 18
        ),
        busyIntervals: [],
        constraints: constraints(),
        mode: .reviewSuggestion
      )
    ) { error in
      XCTAssertEqual(
        error as? ScheduleValidationError,
        .weekendReviewDuration
      )
    }
  }

  func testMealWindowsAreProtectedEveryDay() {
    let mealConflicts = [
      proposal(startHour: 7, endHour: 8, day: 18),
      proposal(startHour: 11, endHour: 12, day: 18),
      proposal(startHour: 18, endHour: 20, day: 18)
    ]

    for value in mealConflicts {
      XCTAssertThrowsError(
        try ScheduleValidator.validate(
          value,
          busyIntervals: [],
          constraints: constraints(),
          mode: .standard
        )
      ) { error in
        XCTAssertEqual(
          error as? ScheduleValidationError,
          .protectedTime
        )
      }
    }
  }

  func testRejectsCoreHoursAndWindowCrossings() {
    let invalidProposals = [
      proposal(startHour: 10, endHour: 11),
      proposal(
        startHour: 7,
        startMinute: 30,
        endHour: 8,
        endMinute: 30
      ),
      proposal(startHour: 17, endHour: 18)
    ]

    for value in invalidProposals {
      XCTAssertThrowsError(
        try ScheduleValidator.validate(
          value,
          busyIntervals: [],
          constraints: constraints(),
          mode: .standard
        )
      ) { error in
        XCTAssertEqual(
          error as? ScheduleValidationError,
          .outsideActiveHours
        )
      }
    }
  }

  func testRejectsConflictIncludingTransitionBuffer() {
    let busy = CalendarEventSnapshot(
      eventId: "opaque",
      calendarId: "calendar",
      startAt: date(19, minute: 5),
      endAt: date(20),
      isAllDay: false,
      title: nil,
      focusArea: nil,
      completionStatus: nil
    )

    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        proposal(),
        busyIntervals: [busy],
        constraints: constraints(),
        mode: .standard
      )
    ) { error in
      XCTAssertEqual(error as? ScheduleValidationError, .conflict)
    }
  }

  func testRejectsPastLongAndDisabledFocus() {
    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        proposal(startHour: 4, endHour: 5),
        busyIntervals: [],
        constraints: constraints(),
        mode: .standard
      )
    ) { error in
      XCTAssertEqual(error as? ScheduleValidationError, .past)
    }

    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        proposal(startHour: 18, endHour: 23),
        busyIntervals: [],
        constraints: constraints(),
        mode: .standard
      )
    ) { error in
      XCTAssertEqual(error as? ScheduleValidationError, .tooLong)
    }

    let limited = LocalScheduleConstraints(
      now: constraints().now,
      planningStart: constraints().planningStart,
      planningEnd: constraints().planningEnd,
      dayStartMinutes: constraints().dayStartMinutes,
      morningEndMinutes: constraints().morningEndMinutes,
      eveningStartMinutes: constraints().eveningStartMinutes,
      dayEndMinutes: constraints().dayEndMinutes,
      maxBlockMinutes: constraints().maxBlockMinutes,
      maxDailyBlocks: constraints().maxDailyBlocks,
      minimumBreakMinutes: constraints().minimumBreakMinutes,
      selectedFocusAreas: [.work],
      calendar: constraints().calendar
    )
    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        proposal(focusArea: .exercise),
        busyIntervals: [],
        constraints: limited,
        mode: .standard
      )
    ) { error in
      XCTAssertEqual(error as? ScheduleValidationError, .disabledFocusArea)
    }
  }

  func testRejectsUnsafeContentAndReminderBeforeCalendarWrite() {
    let emptyTitle = CalendarProposal(
      proposalId: UUID(),
      title: "   ",
      startAt: date(18),
      endAt: date(19),
      focusArea: .work,
      rationale: "Reason",
      notes: "",
      reminderMinutes: 10
    )
    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        emptyTitle,
        busyIntervals: [],
        constraints: constraints(),
        mode: .standard
      )
    ) { error in
      XCTAssertEqual(error as? ScheduleValidationError, .invalidContent)
    }

    let invalidReminder = CalendarProposal(
      proposalId: UUID(),
      title: "Project planning",
      startAt: date(18),
      endAt: date(19),
      focusArea: .work,
      rationale: "Reason",
      notes: "",
      reminderMinutes: Int.max
    )
    XCTAssertThrowsError(
      try ScheduleValidator.validate(
        invalidReminder,
        busyIntervals: [],
        constraints: constraints(),
        mode: .standard
      )
    ) { error in
      XCTAssertEqual(error as? ScheduleValidationError, .invalidReminder)
    }
  }
}
