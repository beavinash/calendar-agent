import XCTest
@testable import CalendarAgent

@MainActor
final class CalendarDisplayEventTests: XCTestCase {
  func testFreshDisplayIncludesEveryCalendarAndFreeAllDayEvents() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let systemEvents = [
      CalendarSystemEvent(
        eventIdentifier: "free-event",
        calendarItemIdentifier: "free-item",
        calendarIdentifier: "shared-calendar",
        occurrenceDate: nil,
        title: "Shared all-day plan",
        startAt: start,
        endAt: start.addingTimeInterval(86_400),
        isAllDay: true,
        isCanceled: false,
        isFree: true,
        calendarTitle: "Shared"
      ),
      CalendarSystemEvent(
        eventIdentifier: "busy-event",
        calendarItemIdentifier: "busy-item",
        calendarIdentifier: "personal-calendar",
        occurrenceDate: nil,
        title: "Personal focus",
        startAt: start.addingTimeInterval(90_000),
        endAt: start.addingTimeInterval(93_600),
        isAllDay: false,
        isCanceled: false,
        isFree: false,
        calendarTitle: "Personal"
      ),
      CalendarSystemEvent(
        eventIdentifier: "cancelled-event",
        calendarItemIdentifier: "cancelled-item",
        calendarIdentifier: "work-calendar",
        occurrenceDate: nil,
        title: "Cancelled meeting",
        startAt: start.addingTimeInterval(3_600),
        endAt: start.addingTimeInterval(7_200),
        isAllDay: false,
        isCanceled: true,
        isFree: false,
        calendarTitle: "Work"
      )
    ]

    let displayed = CalendarService.displayEvents(from: systemEvents)

    XCTAssertEqual(displayed.map(\.calendarTitle), ["Shared", "Personal"])
    XCTAssertEqual(displayed.map(\.title), ["Shared all-day plan", "Personal focus"])
    XCTAssertTrue(displayed[0].isAllDay)
  }

  func testDisplayExcludesHolidayCalendarsButNotHolidayEventTitles() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let systemEvents = [
      CalendarSystemEvent(
        eventIdentifier: "holiday-calendar-event",
        calendarItemIdentifier: "holiday-calendar-item",
        calendarIdentifier: "holiday-calendar",
        occurrenceDate: nil,
        title: "Independence Day",
        startAt: start,
        endAt: start.addingTimeInterval(86_400),
        isAllDay: true,
        isCanceled: false,
        isFree: true,
        calendarTitle: "US Holidays"
      ),
      CalendarSystemEvent(
        eventIdentifier: "personal-event",
        calendarItemIdentifier: "personal-item",
        calendarIdentifier: "personal-calendar",
        occurrenceDate: nil,
        title: "Plan holiday travel",
        startAt: start.addingTimeInterval(3_600),
        endAt: start.addingTimeInterval(7_200),
        isAllDay: false,
        isCanceled: false,
        isFree: false,
        calendarTitle: "Personal"
      )
    ]

    let displayed = CalendarService.displayEvents(from: systemEvents)

    XCTAssertEqual(displayed.count, 1)
    XCTAssertEqual(displayed.first?.title, "Plan holiday travel")
    XCTAssertEqual(displayed.first?.calendarTitle, "Personal")
  }

  func testDisplayDoesNotLimitTheNumberOfVisibleEvents() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let systemEvents = (0..<350).map { index in
      CalendarSystemEvent(
        eventIdentifier: "event-\(index)",
        calendarItemIdentifier: "item-\(index)",
        calendarIdentifier: "calendar-\(index % 4)",
        occurrenceDate: nil,
        title: "Event \(index)",
        startAt: start.addingTimeInterval(TimeInterval(index)),
        endAt: start.addingTimeInterval(TimeInterval(index + 1)),
        isAllDay: false,
        isCanceled: false,
        isFree: false,
        calendarTitle: "Calendar \(index % 4)"
      )
    }

    let displayed = CalendarService.displayEvents(from: systemEvents)

    XCTAssertEqual(displayed.count, 350)
  }

  func testStableEventIdentifierProducesPrivateCompletionKey() {
    let first = CalendarService.completionKey(
      eventIdentifier: "event-identifier",
      calendarItemIdentifier: "first-item",
      calendarIdentifier: "first-calendar",
      occurrenceDate: nil
    )
    let afterAppleCalendarEdit = CalendarService.completionKey(
      eventIdentifier: "event-identifier",
      calendarItemIdentifier: "changed-item",
      calendarIdentifier: "changed-calendar",
      occurrenceDate: nil
    )

    XCTAssertEqual(first, afterAppleCalendarEdit)
    XCTAssertEqual(first.count, 64)
    XCTAssertFalse(first.contains("event-identifier"))
    XCTAssertFalse(first.contains("first-calendar"))
  }

  func testFallbackDistinguishesRecurringOccurrences() {
    let first = CalendarService.completionKey(
      eventIdentifier: nil,
      calendarItemIdentifier: "recurring-item",
      calendarIdentifier: "personal-calendar",
      occurrenceDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let second = CalendarService.completionKey(
      eventIdentifier: nil,
      calendarItemIdentifier: "recurring-item",
      calendarIdentifier: "personal-calendar",
      occurrenceDate: Date(timeIntervalSince1970: 1_700_086_400)
    )

    XCTAssertNotEqual(first, second)
  }

  func testEventIdentifierStillDistinguishesRecurringOccurrences() {
    let first = CalendarService.completionKey(
      eventIdentifier: "recurring-event",
      calendarItemIdentifier: "recurring-item",
      calendarIdentifier: "personal-calendar",
      occurrenceDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let second = CalendarService.completionKey(
      eventIdentifier: "recurring-event",
      calendarItemIdentifier: "recurring-item",
      calendarIdentifier: "personal-calendar",
      occurrenceDate: Date(timeIntervalSince1970: 1_700_086_400)
    )

    XCTAssertNotEqual(first, second)
  }

  func testLiveValuesCanChangeWithoutChangingDisplayIdentity() {
    let key = CalendarService.completionKey(
      eventIdentifier: "stable-event",
      calendarItemIdentifier: "item",
      calendarIdentifier: "calendar",
      occurrenceDate: nil
    )
    let original = CalendarDisplayEvent(
      completionKey: key,
      title: "Original title",
      startAt: Date(timeIntervalSince1970: 1_700_000_000),
      endAt: Date(timeIntervalSince1970: 1_700_003_600),
      isAllDay: false,
      calendarTitle: "Personal"
    )
    let edited = CalendarDisplayEvent(
      completionKey: key,
      title: "Edited in Apple Calendar",
      startAt: Date(timeIntervalSince1970: 1_700_007_200),
      endAt: Date(timeIntervalSince1970: 1_700_010_800),
      isAllDay: false,
      calendarTitle: "Personal"
    )

    XCTAssertEqual(original.id, edited.id)
    XCTAssertNotEqual(original.title, edited.title)
    XCTAssertNotEqual(original.startAt, edited.startAt)
  }

}
