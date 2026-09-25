import XCTest
@testable import CalendarAgent

@MainActor
final class CoachSessionControllerTests: XCTestCase {
  func testShortBackgroundKeepsActiveSession() {
    let suite = "CoachSessionControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    let controller = CoachSessionController(
      defaults: defaults,
      now: { now }
    )
    let originalSession = controller.activeSessionId

    controller.recordBackgroundTransition()
    now = now.addingTimeInterval(299)
    let rotated = controller.recordActiveTransition()

    XCTAssertFalse(rotated)
    XCTAssertEqual(controller.activeSessionId, originalSession)
  }

  func testFiveMinuteBackgroundRotatesActiveSession() {
    let suite = "CoachSessionControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    let controller = CoachSessionController(
      defaults: defaults,
      now: { now }
    )
    let originalSession = controller.activeSessionId

    controller.recordBackgroundTransition()
    now = now.addingTimeInterval(300)
    let rotated = controller.recordActiveTransition()

    XCTAssertTrue(rotated)
    XCTAssertNotEqual(controller.activeSessionId, originalSession)
  }

  func testPersistedBackgroundTimeSurvivesControllerRecreation() {
    let suite = "CoachSessionControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    let firstController = CoachSessionController(
      defaults: defaults,
      now: { now }
    )
    let originalSession = firstController.activeSessionId
    firstController.recordBackgroundTransition()

    now = now.addingTimeInterval(301)
    let restoredController = CoachSessionController(
      defaults: defaults,
      now: { now }
    )
    let rotated = restoredController.recordActiveTransition()

    XCTAssertTrue(rotated)
    XCTAssertNotEqual(restoredController.activeSessionId, originalSession)
  }

  func testShortBackgroundKeepsSessionAcrossControllerRecreation() {
    let suite = "CoachSessionControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    let firstController = CoachSessionController(
      defaults: defaults,
      now: { now }
    )
    let originalSession = firstController.activeSessionId
    firstController.recordBackgroundTransition()

    now = now.addingTimeInterval(299)
    let restoredController = CoachSessionController(
      defaults: defaults,
      now: { now }
    )

    XCTAssertFalse(restoredController.recordActiveTransition())
    XCTAssertEqual(restoredController.activeSessionId, originalSession)
  }

  func testChatMessagesCanBeArchivedBySession() {
    let sessionId = UUID()

    let currentMessage = ChatMessageRecord(
      role: .user,
      content: "Current conversation",
      sessionId: sessionId
    )
    let migratedMessage = ChatMessageRecord(
      role: .assistant,
      content: "Older conversation"
    )

    XCTAssertEqual(currentMessage.sessionId, sessionId)
    XCTAssertNil(migratedMessage.sessionId)
  }

  func testActiveTransitionConsumesPersistedBackgroundTime() {
    let suite = "CoachSessionControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    let controller = CoachSessionController(
      defaults: defaults,
      now: { now }
    )
    controller.recordBackgroundTransition()
    now = now.addingTimeInterval(300)

    XCTAssertTrue(controller.recordActiveTransition())
    let rotatedSession = controller.activeSessionId
    now = now.addingTimeInterval(300)

    XCTAssertFalse(controller.recordActiveTransition())
    XCTAssertEqual(controller.activeSessionId, rotatedSession)
  }

  func testFreshSessionRotatesImmediatelyAndClearsBackgroundTransition() {
    let suite = "CoachSessionControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    let controller = CoachSessionController(
      defaults: defaults,
      now: { now }
    )
    let originalSession = controller.activeSessionId
    controller.recordBackgroundTransition()

    controller.startFreshSession()

    let freshSession = controller.activeSessionId
    XCTAssertNotEqual(freshSession, originalSession)
    now = now.addingTimeInterval(600)
    XCTAssertFalse(controller.recordActiveTransition())
    XCTAssertEqual(controller.activeSessionId, freshSession)
    XCTAssertEqual(
      CoachSessionController(defaults: defaults).activeSessionId,
      freshSession
    )
  }
}
