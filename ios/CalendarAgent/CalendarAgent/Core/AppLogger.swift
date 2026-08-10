import Foundation
import OSLog

enum AppLogger {
  private static let subsystem = Bundle.main.bundleIdentifier
    ?? "com.calendaragent.ios"

  static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
  static let calendar = Logger(subsystem: subsystem, category: "calendar")
  static let completion = Logger(subsystem: subsystem, category: "completion")
  static let scheduling = Logger(subsystem: subsystem, category: "scheduling")
  static let network = Logger(subsystem: subsystem, category: "network")
  static let coach = Logger(subsystem: subsystem, category: "coach")
  static let persistence = Logger(subsystem: subsystem, category: "persistence")
  static let notifications = Logger(
    subsystem: subsystem,
    category: "notifications"
  )
}
