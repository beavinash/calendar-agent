import XCTest
@testable import CalendarAgent

final class CoachCommandTests: XCTestCase {
  func testParsesSupportedClearCommandsAfterNormalization() {
    XCTAssertEqual(
      CoachCommandParser.parse("/clear"),
      .command(.clear(.all))
    )
    XCTAssertEqual(
      CoachCommandParser.parse("  /CLEAR   WEEK  "),
      .command(.clear(.week))
    )
    XCTAssertEqual(
      CoachCommandParser.parse("\n/clear\tmonth\n"),
      .command(.clear(.month))
    )
  }

  func testRejectsUnsupportedClearSuffixesAsInvalidSyntax() {
    let messages = [
      "/clear all",
      "/clear day",
      "/clear weekly",
      "/clear month now",
      "/clearance"
    ]

    for message in messages {
      XCTAssertEqual(
        CoachCommandParser.parse(message),
        .invalidClearSyntax,
        message
      )
    }
  }

  func testLeavesOrdinaryMessagesOutsideLocalCommandHandling() {
    let messages = [
      "clear",
      "clear my calendar",
      "please /clear my data",
      "/review week",
      ""
    ]

    for message in messages {
      XCTAssertEqual(
        CoachCommandParser.parse(message),
        .notACommand,
        message
      )
    }
  }
}
