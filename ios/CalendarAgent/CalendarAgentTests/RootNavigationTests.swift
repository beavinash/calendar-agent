import XCTest
@testable import CalendarAgent

final class RootNavigationTests: XCTestCase {
  func testFocusAreasAreNeutralPublicDefaults() {
    XCTAssertEqual(
      FocusArea.allCases.map(\.rawValue),
      ["work", "study", "exercise", "appointments", "errands"]
    )
    XCTAssertEqual(
      FocusArea.allCases.map(\.title),
      ["Work", "Study", "Exercise", "Appointments", "Errands"]
    )
  }

  func testCoachIsFirstAndDefaultRootTab() {
    XCTAssertEqual(RootTab.allCases, [.coach, .progress])
    XCTAssertEqual(RootTab.defaultTab, .coach)
  }

  func testRootTabTitles() {
    XCTAssertEqual(AppBrand.name, "Mark-1")
    XCTAssertEqual(RootTab.coach.title, "Mark-1")
    XCTAssertEqual(RootTab.progress.title, "Progress")
  }

  func testMarkOneHeaderUsesPeriodAwareAnalyzeTitles() {
    XCTAssertEqual(CoachHeaderContent.title, "Mark-1")
    XCTAssertEqual(
      CoachHeaderContent.analyzeTitle(for: .day),
      "Analyze Today"
    )
    XCTAssertEqual(
      CoachHeaderContent.analyzeTitle(for: .week),
      "Analyze Last Week"
    )
    XCTAssertEqual(
      CoachHeaderContent.analyzeTitle(for: .month),
      "Analyze Last Month"
    )
  }

  func testReviewDisclosureDistinguishesEstimateFromExplicitInput() {
    XCTAssertEqual(
      FocusReviewCompletionDisclosure.text(for: .notProvided),
      "Eligible ended unmarked events since tracking began count as 70% "
        + "likely incomplete for this coaching estimate."
    )
    XCTAssertEqual(
      FocusReviewCompletionDisclosure.text(for: .userInput),
      "Saved Complete/Incomplete choices stay explicit; eligible ended "
        + "unmarked events since tracking began count as 70% likely incomplete."
    )
  }
}
