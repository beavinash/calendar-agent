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

  func testSubmissionRouterKeepsClearCommandsLocal() {
    XCTAssertEqual(
      CoachSubmissionRouter.route("/clear"),
      .confirmLocalClear(.all)
    )
    XCTAssertEqual(
      CoachSubmissionRouter.route("/clear week"),
      .confirmLocalClear(.week)
    )
    XCTAssertEqual(
      CoachSubmissionRouter.route("/clear month"),
      .confirmLocalClear(.month)
    )
    XCTAssertEqual(
      CoachSubmissionRouter.route("/clear day"),
      .invalidLocalCommand
    )
    XCTAssertEqual(
      CoachSubmissionRouter.route("Help me plan tomorrow"),
      .providerMessage
    )
  }

  func testClearHistoryPresentationCopyIsScopedAndHonest() {
    XCTAssertEqual(
      ClearHistoryPresentation.confirmationTitle(for: .all),
      "Clear all local coaching history?"
    )
    XCTAssertEqual(
      ClearHistoryPresentation.confirmationTitle(for: .week),
      "Clear last week's local coaching history?"
    )
    XCTAssertEqual(
      ClearHistoryPresentation.confirmationTitle(for: .month),
      "Clear last month's local coaching history?"
    )
    XCTAssertTrue(
      ClearHistoryPresentation.confirmationMessage(for: .all).contains(
        "coach messages, check-ins, Complete/Incomplete choices"
      )
    )
    XCTAssertTrue(
      ClearHistoryPresentation.confirmationMessage(for: .week).contains(
        "clears every pending calendar draft"
      )
    )
    XCTAssertTrue(
      ClearHistoryPresentation.confirmationMessage(for: .month).contains(
        "Previously sent AI data is not deleted"
      )
    )
    XCTAssertTrue(
      ClearHistoryPresentation.confirmationMessage(for: .all).contains(
        "Apple Calendar events stay unchanged"
      )
    )

    for scope in ClearHistoryScope.allCases {
      let success = ClearHistoryPresentation.successMessage(for: scope)
      let failure = ClearHistoryPresentation.failureMessage(for: scope)
      XCTAssertTrue(success.contains("Apple Calendar events were not changed"))
      XCTAssertTrue(failure.contains("Nothing was deleted"))
      XCTAssertNotEqual(success, failure)
    }
  }

  func testLocalSubmissionDispatchNeverInvokesProviderPath() {
    var confirmation = ClearHistoryConfirmationState()
    var invalidCount = 0
    var providerCount = 0

    CoachSubmissionHandler.handle(
      "/clear week",
      requestLocalClear: { confirmation.request($0) },
      rejectInvalidCommand: { invalidCount += 1 },
      sendProviderMessage: { providerCount += 1 }
    )

    XCTAssertEqual(confirmation.pendingScope, .week)
    XCTAssertEqual(invalidCount, 0)
    XCTAssertEqual(providerCount, 0)
  }

  func testCancellingClearConfirmationIsANoOp() {
    var confirmation = ClearHistoryConfirmationState()
    confirmation.request(.month)

    confirmation.cancel()

    XCTAssertNil(confirmation.pendingScope)
    XCTAssertFalse(confirmation.isPresented)
    XCTAssertNil(confirmation.consumeConfirmedScope())
  }
}
