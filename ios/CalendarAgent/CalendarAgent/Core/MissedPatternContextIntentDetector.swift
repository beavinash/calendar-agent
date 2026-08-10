import Foundation

enum MissedPatternContextIntentDetector {
  static func requestsContext(_ message: String) -> Bool {
    let normalized = message
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")

    let explicitPatterns = [
      "what i missed",
      "what i've missed",
      "what i have missed",
      "what am i missing",
      "missed pattern",
      "missing pattern",
      "likely missed",
      "my incomplete",
      "incomplete event",
      "incomplete task",
      "what i avoid",
      "my avoidance",
      "avoidance pattern",
      "my follow through",
      "follow through pattern",
      "follow through history"
    ]
    return explicitPatterns.contains(where: normalized.contains)
  }
}
