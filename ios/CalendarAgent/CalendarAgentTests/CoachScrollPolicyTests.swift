import XCTest
@testable import CalendarAgent

final class CoachScrollPolicyTests: XCTestCase {
  func testOpeningCoachTargetsTopContent() {
    XCTAssertEqual(
      CoachScrollPolicy.target(for: .initialAppearance),
      .top
    )
    XCTAssertEqual(
      CoachScrollPolicy.target(for: .sessionReset),
      .top
    )
    XCTAssertEqual(
      CoachScrollPolicy.target(for: .foregroundActivation),
      .top
    )
  }

  func testSelectingReviewPeriodTargetsTopContent() {
    XCTAssertEqual(
      CoachScrollPolicy.target(for: .reviewPeriodChanged),
      .top
    )
  }

  func testOnlyAppendedMessagesTargetBottom() {
    XCTAssertEqual(
      CoachScrollPolicy.target(
        for: .messageCountChanged(previous: 2, current: 3)
      ),
      .bottom
    )
    XCTAssertNil(
      CoachScrollPolicy.target(
        for: .messageCountChanged(previous: 3, current: 2)
      )
    )
    XCTAssertNil(
      CoachScrollPolicy.target(
        for: .messageCountChanged(previous: 2, current: 2)
      )
    )
  }

  func testInitialMessageHydrationDoesNotOverrideTopPosition() {
    XCTAssertNil(
      CoachScrollPolicy.target(
        for: .messageCountChanged(previous: 0, current: 4),
        isFollowingGeneratedContent: false
      )
    )
  }

  func testOnlyNewGeneratedContentTargetsBottom() {
    XCTAssertEqual(
      CoachScrollPolicy.target(
        for: .proposalCountChanged(previous: 0, current: 1)
      ),
      .bottom
    )
    XCTAssertEqual(
      CoachScrollPolicy.target(for: .reviewBecameAvailable),
      .bottom
    )
    XCTAssertEqual(
      CoachScrollPolicy.target(for: .loadingStarted),
      .bottom
    )
    XCTAssertEqual(
      CoachScrollPolicy.target(
        for: .warningCountChanged(previous: 0, current: 1)
      ),
      .bottom
    )
  }

  func testRemovedGeneratedContentDoesNotTargetBottom() {
    XCTAssertNil(
      CoachScrollPolicy.target(
        for: .proposalCountChanged(previous: 1, current: 0)
      )
    )
    XCTAssertNil(
      CoachScrollPolicy.target(
        for: .warningCountChanged(previous: 1, current: 0)
      )
    )
    XCTAssertNil(
      CoachScrollPolicy.target(for: .loadingFinished)
    )
  }
}
