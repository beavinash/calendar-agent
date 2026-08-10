import XCTest
@testable import CalendarAgent

final class FocusReviewIntentDetectorTests: XCTestCase {
  func testRecognizesExplicitFocusReviewRequests() {
    let messages = [
      "/review",
      "Review my Apple Calendar by focus interest",
      "Analyze my focus over the last month",
      "What am I not doing for my goals?",
      "Where am I falling behind in my focus areas?",
      "What did I miss this week?",
      "What have I missed today?",
      "Show me how my month supports my goals"
    ]

    for message in messages {
      XCTAssertTrue(
        FocusReviewIntentDetector.requestsReview(message),
        message
      )
    }
  }

  func testParsesTodayLastWeekAndLastMonthReviewPeriods() {
    XCTAssertEqual(
      FocusReviewIntentDetector.reviewPeriod("/review day"),
      .day
    )
    XCTAssertEqual(
      FocusReviewIntentDetector.reviewPeriod("/review week"),
      .week
    )
    XCTAssertEqual(
      FocusReviewIntentDetector.reviewPeriod("/review month"),
      .month
    )
    XCTAssertEqual(
      FocusReviewIntentDetector.reviewPeriod("/review"),
      .week
    )
    XCTAssertEqual(
      FocusReviewIntentDetector.reviewPeriod("What did I miss this week?"),
      .week
    )
    XCTAssertEqual(
      FocusReviewIntentDetector.reviewPeriod("What have I missed today?"),
      .day
    )
  }

  func testReviewPeriodTitlesMatchCoachModes() {
    XCTAssertEqual(FocusReviewPeriod.day.title, "Today")
    XCTAssertEqual(FocusReviewPeriod.week.title, "Last Week")
    XCTAssertEqual(FocusReviewPeriod.month.title, "Last Month")
  }

  func testAnalysisBoundsUseTodayAndPreviousCompletedPeriods() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    calendar.firstWeekday = 2
    let date = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-17T12:00:00-07:00")
    )

    let today = FocusReviewPeriod.day.analysisBounds(
      at: date,
      calendar: calendar
    )
    XCTAssertEqual(today.start, calendar.startOfDay(for: date))
    XCTAssertEqual(today.end, date)

    let lastWeek = FocusReviewPeriod.week.analysisBounds(
      at: date,
      calendar: calendar
    )
    XCTAssertEqual(
      calendar.dateComponents(
        [.day],
        from: lastWeek.start,
        to: lastWeek.end
      ).day,
      7
    )
    XCTAssertEqual(
      lastWeek.end,
      calendar.dateInterval(of: .weekOfYear, for: date)?.start
    )

    let lastMonth = FocusReviewPeriod.month.analysisBounds(
      at: date,
      calendar: calendar
    )
    XCTAssertEqual(
      lastMonth.end,
      calendar.dateInterval(of: .month, for: date)?.start
    )
    XCTAssertEqual(
      calendar.component(.month, from: lastMonth.start),
      6
    )
  }

  func testLastWeekUsesSevenLocalDaysAcrossDaylightSavingTime() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    calendar.firstWeekday = 2
    let date = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-11-05T12:00:00-08:00")
    )

    let bounds = FocusReviewPeriod.week.analysisBounds(
      at: date,
      calendar: calendar
    )

    XCTAssertEqual(
      calendar.dateComponents([.day], from: bounds.start, to: bounds.end).day,
      7
    )
  }

  func testRejectsSchedulingAndOrdinaryChat() {
    let messages = [
      "Plan tomorrow",
      "Schedule work after 5:30",
      "Review this note for grammar",
      "Help me reset"
    ]

    for message in messages {
      XCTAssertFalse(
        FocusReviewIntentDetector.requestsReview(message),
        message
      )
    }
  }
}
