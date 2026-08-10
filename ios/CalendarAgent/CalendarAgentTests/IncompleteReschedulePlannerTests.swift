import XCTest
@testable import CalendarAgent

final class IncompleteReschedulePlannerTests: XCTestCase {
  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(
    year: Int = 2026,
    month: Int = 7,
    day: Int,
    hour: Int,
    minute: Int = 0,
    calendar: Calendar? = nil
  ) -> Date {
    let calendar = calendar ?? utcCalendar
    return calendar.date(
      from: DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
      )
    )!
  }

  private func constraints(
    now: Date,
    calendar: Calendar? = nil,
    minimumBreakMinutes: Int = 10,
    maxBlockMinutes: Int = 240
  ) -> LocalScheduleConstraints {
    let calendar = calendar ?? utcCalendar
    let startOfToday = calendar.startOfDay(for: now)
    return LocalScheduleConstraints(
      now: now,
      planningStart: now,
      planningEnd: calendar.date(
        byAdding: .day,
        value: 2,
        to: startOfToday
      )!,
      dayStartMinutes: 6 * 60,
      morningEndMinutes: 8 * 60,
      eveningStartMinutes: 17 * 60 + 30,
      dayEndMinutes: 23 * 60,
      maxBlockMinutes: maxBlockMinutes,
      maxDailyBlocks: 5,
      minimumBreakMinutes: minimumBreakMinutes,
      selectedFocusAreas: [],
      calendar: calendar
    )
  }

  private func nextSlot(
    now: Date,
    durationMinutes: Int,
    busyIntervals: [DateInterval] = [],
    sourceIsAllDay: Bool = false,
    constraints customConstraints: LocalScheduleConstraints? = nil
  ) -> DateInterval? {
    IncompleteReschedulePlanner.nextSlot(
      sourceStartAt: date(day: 15, hour: 9),
      sourceEndAt: date(day: 15, hour: 9).addingTimeInterval(
        TimeInterval(durationMinutes * 60)
      ),
      sourceIsAllDay: sourceIsAllDay,
      busyIntervals: busyIntervals,
      constraints: customConstraints ?? constraints(now: now)
    )
  }

  func testChoosesEarliestQuarterHourLaterToday() throws {
    let now = date(day: 16, hour: 17, minute: 32)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 45)
    )

    XCTAssertEqual(slot.start, date(day: 16, hour: 17, minute: 45))
    XCTAssertEqual(slot.end, date(day: 16, hour: 18, minute: 30))
  }

  func testPreservesNonGridSourceDurationExactly() throws {
    let now = date(day: 16, hour: 17, minute: 31)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 37)
    )

    XCTAssertEqual(slot.start, date(day: 16, hour: 17, minute: 45))
    XCTAssertEqual(slot.duration, 37 * 60, accuracy: 0.001)
    XCTAssertEqual(slot.end, date(day: 16, hour: 18, minute: 22))
  }

  func testUsesMinimumBreakOnBothSidesOfBusyEvents() throws {
    let now = date(day: 16, hour: 17, minute: 31)
    let busy = DateInterval(
      start: date(day: 16, hour: 17, minute: 45),
      end: date(day: 16, hour: 18)
    )

    let slot = try XCTUnwrap(
      nextSlot(
        now: now,
        durationMinutes: 30,
        busyIntervals: [busy]
      )
    )

    XCTAssertEqual(slot.start, date(day: 16, hour: 18, minute: 15))
  }

  func testBoundaryTouchIsAllowedWhenBreakIsZero() throws {
    let now = date(day: 16, hour: 17, minute: 31)
    let busy = DateInterval(
      start: date(day: 16, hour: 17),
      end: date(day: 16, hour: 17, minute: 45)
    )
    let customConstraints = constraints(
      now: now,
      minimumBreakMinutes: 0
    )

    let slot = try XCTUnwrap(
      nextSlot(
        now: now,
        durationMinutes: 30,
        busyIntervals: [busy],
        constraints: customConstraints
      )
    )

    XCTAssertEqual(slot.start, date(day: 16, hour: 17, minute: 45))
  }

  func testUsesTomorrowOnlyWhenNoSlotRemainsToday() throws {
    let now = date(day: 16, hour: 22, minute: 30)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 60)
    )

    XCTAssertEqual(slot.start, date(day: 17, hour: 6))
    XCTAssertEqual(slot.end, date(day: 17, hour: 7))
  }

  func testWeekdayCoreHoursAreSkipped() throws {
    let now = date(day: 16, hour: 10)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 45)
    )

    XCTAssertEqual(slot.start, date(day: 16, hour: 17, minute: 30))
  }

  func testWeekendUsesSixToTwentyThreeWindow() throws {
    let now = date(day: 18, hour: 5, minute: 20)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 45)
    )

    XCTAssertEqual(slot.start, date(day: 18, hour: 6))
    XCTAssertEqual(slot.end, date(day: 18, hour: 6, minute: 45))
  }

  func testWeekendCutoffMovesSearchToTomorrow() throws {
    let now = date(day: 18, hour: 22, minute: 30)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 45)
    )

    XCTAssertEqual(slot.start, date(day: 19, hour: 6))
  }

  func testProtectedMealWindowsAreSkipped() throws {
    let now = date(day: 18, hour: 11, minute: 20)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 30)
    )

    XCTAssertEqual(slot.start, date(day: 18, hour: 12))
  }

  func testMealBoundariesDoNotCreateFalseConflicts() throws {
    let now = date(day: 18, hour: 7, minute: 15)

    let slot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 30)
    )

    XCTAssertEqual(slot.start, date(day: 18, hour: 7, minute: 15))
    XCTAssertEqual(slot.end, date(day: 18, hour: 7, minute: 45))
  }

  func testAllDaySourceIsRejected() {
    let now = date(day: 16, hour: 17, minute: 31)

    XCTAssertNil(
      nextSlot(
        now: now,
        durationMinutes: 60,
        sourceIsAllDay: true
      )
    )
  }

  func testAnyPositiveTimedDurationIsPreserved() throws {
    let now = date(day: 16, hour: 17, minute: 31)

    let shortSlot = try XCTUnwrap(
      nextSlot(now: now, durationMinutes: 5)
    )
    let longSlot = try XCTUnwrap(
      nextSlot(
        now: date(day: 18, hour: 6),
        durationMinutes: 241
      )
    )

    XCTAssertEqual(shortSlot.duration, 5 * 60, accuracy: 0.001)
    XCTAssertEqual(longSlot.duration, 241 * 60, accuracy: 0.001)
  }

  func testNonPositiveAndCrossDayDurationsAreRejected() {
    let now = date(day: 16, hour: 17, minute: 31)

    XCTAssertNil(nextSlot(now: now, durationMinutes: 0))
    XCTAssertNil(nextSlot(now: now, durationMinutes: -1))
    XCTAssertNil(
      IncompleteReschedulePlanner.nextSlot(
        sourceStartAt: date(day: 15, hour: 23, minute: 30),
        sourceEndAt: date(day: 16, hour: 0, minute: 30),
        sourceIsAllDay: false,
        busyIntervals: [],
        constraints: constraints(now: now)
      )
    )
  }

  func testReturnsNilWhenTodayAndTomorrowAreBusy() {
    let now = date(day: 18, hour: 6)
    let busy = DateInterval(
      start: date(day: 18, hour: 5),
      end: date(day: 20, hour: 0)
    )

    XCTAssertNil(
      nextSlot(
        now: now,
        durationMinutes: 60,
        busyIntervals: [busy]
      )
    )
  }

  func testTomorrowCalculationIsDSTSafe() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = date(
      year: 2026,
      month: 3,
      day: 7,
      hour: 22,
      minute: 50,
      calendar: calendar
    )
    let customConstraints = constraints(
      now: now,
      calendar: calendar
    )

    let slot = try XCTUnwrap(
      IncompleteReschedulePlanner.nextSlot(
        sourceStartAt: now.addingTimeInterval(-3_600),
        sourceEndAt: now.addingTimeInterval(-1_800),
        sourceIsAllDay: false,
        busyIntervals: [],
        constraints: customConstraints
      )
    )
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: slot.start
    )

    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 3)
    XCTAssertEqual(components.day, 8)
    XCTAssertEqual(components.hour, 6)
    XCTAssertEqual(components.minute, 0)
    XCTAssertEqual(slot.duration, 30 * 60, accuracy: 0.001)
  }
}
