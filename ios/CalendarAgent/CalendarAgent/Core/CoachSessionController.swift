import Foundation

@MainActor
final class CoachSessionController: ObservableObject {
  private enum Key {
    static let activeSessionId = "coachSession.activeSessionId"
    static let backgroundedAt = "coachSession.backgroundedAt"
  }

  nonisolated static let backgroundTimeout: TimeInterval = 5 * 60

  @Published private(set) var activeSessionId: UUID

  private let defaults: UserDefaults
  private let timeout: TimeInterval
  private let now: () -> Date

  init(
    defaults: UserDefaults = .standard,
    timeout: TimeInterval = CoachSessionController.backgroundTimeout,
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.timeout = timeout
    self.now = now
    if let storedId = defaults.string(forKey: Key.activeSessionId),
       let parsedId = UUID(uuidString: storedId) {
      activeSessionId = parsedId
      AppLogger.coach.debug("Restored the existing coach session")
    } else {
      let sessionId = UUID()
      activeSessionId = sessionId
      defaults.set(sessionId.uuidString, forKey: Key.activeSessionId)
      AppLogger.coach.info("Created a new coach session during initialization")
    }
  }

  func recordBackgroundTransition() {
    defaults.set(now(), forKey: Key.backgroundedAt)
    AppLogger.coach.debug("Recorded coach background transition")
  }

  @discardableResult
  func recordActiveTransition() -> Bool {
    guard let backgroundedAt = defaults.object(
      forKey: Key.backgroundedAt
    ) as? Date else {
      AppLogger.coach.debug(
        "Processed active transition without a stored background transition"
      )
      return false
    }
    defaults.removeObject(forKey: Key.backgroundedAt)
    let elapsed = max(0, now().timeIntervalSince(backgroundedAt))
    guard elapsed >= timeout else {
      AppLogger.coach.debug(
        "Kept coach session after a short background interval"
      )
      return false
    }
    AppLogger.coach.info("Rotating coach session after background timeout")
    rotateSession()
    return true
  }

  private func rotateSession() {
    let sessionId = UUID()
    activeSessionId = sessionId
    defaults.set(sessionId.uuidString, forKey: Key.activeSessionId)
    AppLogger.coach.info("Coach session rotation completed")
  }
}
