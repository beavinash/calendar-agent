import SwiftData
import XCTest
@testable import CalendarAgent

@MainActor
final class ClearedAnalysisIntervalTests: XCTestCase {
  func testScopedClearBoundsUsePreviousCompletedLocalPeriods() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(
      TimeZone(identifier: "America/Los_Angeles")
    )
    calendar.firstWeekday = 2
    let now = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-11-05T12:00:00-08:00")
    )

    let week = try XCTUnwrap(
      ClearHistoryScope.week.analysisInterval(at: now, calendar: calendar)
    )
    let month = try XCTUnwrap(
      ClearHistoryScope.month.analysisInterval(at: now, calendar: calendar)
    )

    XCTAssertEqual(
      week,
      FocusReviewPeriod.week.analysisBounds(at: now, calendar: calendar)
    )
    XCTAssertEqual(
      calendar.dateComponents([.day], from: week.start, to: week.end).day,
      7
    )
    XCTAssertEqual(
      month,
      FocusReviewPeriod.month.analysisBounds(at: now, calendar: calendar)
    )
    XCTAssertNil(
      ClearHistoryScope.all.analysisInterval(at: now, calendar: calendar)
    )
  }

  func testClearedIntervalsSurviveAFreshModelContext() throws {
    let schema = Schema([ClearedAnalysisIntervalRecord.self])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    let firstContext = ModelContext(container)
    let week = DateInterval(
      start: Date(timeIntervalSince1970: 1_790_000_000),
      duration: 7 * 86_400
    )
    let month = DateInterval(
      start: Date(timeIntervalSince1970: 1_780_000_000),
      duration: 30 * 86_400
    )
    firstContext.insert(
      ClearedAnalysisIntervalRecord(scope: .week, interval: week)
    )
    firstContext.insert(
      ClearedAnalysisIntervalRecord(scope: .month, interval: month)
    )
    try firstContext.save()

    let relaunchedContext = ModelContext(container)
    let records = try relaunchedContext.fetch(
      FetchDescriptor<ClearedAnalysisIntervalRecord>()
    )

    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(Set(records.map(\.scope)), [.week, .month])
    XCTAssertEqual(Set(records.map(\.interval)), [week, month])
  }
}
