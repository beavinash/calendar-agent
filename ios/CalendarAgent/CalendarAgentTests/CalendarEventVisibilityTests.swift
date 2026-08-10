import Combine
import XCTest
@testable import CalendarAgent

final class CalendarEventVisibilityTests: XCTestCase {
  @MainActor
  func testEventReadDoesNotPublishObservableCalendarState() {
    let service = CalendarService()
    var publicationCount = 0
    let subscription = service.objectWillChange.sink {
      publicationCount += 1
    }
    defer { subscription.cancel() }

    do {
      _ = try service.events(
        from: Date(),
        to: Date().addingTimeInterval(60)
      )
    } catch {
      // Permission is intentionally environment-dependent in unit tests.
    }

    XCTAssertEqual(publicationCount, 0)
  }

  func testHolidayCalendarClassifierRecognizesCommonCalendarNames() {
    let holidayCalendars = [
      "US Holidays",
      "Holidays in United States",
      "Public Holidays",
      "Jours fériés",
      "Feiertage",
      "Días festivos",
      "祝日"
    ]

    for title in holidayCalendars {
      XCTAssertTrue(
        CalendarService.isHolidayCalendarTitle(title),
        "Expected \(title) to be treated as a holiday calendar"
      )
    }
  }

  func testHolidayCalendarClassifierKeepsOrdinaryCalendars() {
    for title in ["Personal", "Work", "Family", "Birthdays", "Focus areas"] {
      XCTAssertFalse(
        CalendarService.isHolidayCalendarTitle(title),
        "Expected \(title) to remain visible"
      )
    }
  }

  func testTrailingSevenDayWindowContainsExactlySevenLocalDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let date = try XCTUnwrap(
      calendar.date(from: DateComponents(
        year: 2026,
        month: 3,
        day: 10,
        hour: 15
      ))
    )

    let interval = CompletionHistoryWindow.bounds(
      at: date,
      calendar: calendar
    )

    XCTAssertEqual(
      calendar.dateComponents([.year, .month, .day], from: interval.start),
      DateComponents(year: 2026, month: 3, day: 4)
    )
    XCTAssertEqual(
      calendar.dateComponents([.year, .month, .day], from: interval.end),
      DateComponents(year: 2026, month: 3, day: 11)
    )
    XCTAssertEqual(
      calendar.dateComponents([.day], from: interval.start, to: interval.end).day,
      7
    )
  }
}
