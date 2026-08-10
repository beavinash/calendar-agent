import Foundation

enum FocusReviewPeriod: String, Codable, CaseIterable, Identifiable {
  case day
  case week
  case month

  var id: String { rawValue }
  var title: String {
    switch self {
    case .day:
      "Today"
    case .week:
      "Last Week"
    case .month:
      "Last Month"
    }
  }

  func analysisBounds(
    at date: Date,
    calendar: Calendar
  ) -> DateInterval {
    switch self {
    case .day:
      let start = calendar.startOfDay(for: date)
      return DateInterval(start: start, end: max(date, start))
    case .week:
      let currentStart = calendar.dateInterval(
        of: .weekOfYear,
        for: date
      )?.start ?? calendar.startOfDay(for: date)
      let previousStart = calendar.date(
        byAdding: .weekOfYear,
        value: -1,
        to: currentStart
      ) ?? calendar.date(
        byAdding: .day,
        value: -7,
        to: currentStart
      ) ?? currentStart.addingTimeInterval(-7 * 86_400)
      return DateInterval(start: previousStart, end: currentStart)
    case .month:
      let currentStart = calendar.dateInterval(of: .month, for: date)?.start
        ?? calendar.startOfDay(for: date)
      let previousStart = calendar.date(
        byAdding: .month,
        value: -1,
        to: currentStart
      ) ?? currentStart.addingTimeInterval(-30 * 86_400)
      return DateInterval(start: previousStart, end: currentStart)
    }
  }
}

enum FocusReviewIntentDetector {
  static func requestsReview(_ message: String) -> Bool {
    reviewPeriod(message) != nil
  }

  static func reviewPeriod(_ message: String) -> FocusReviewPeriod? {
    let value = message
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if value == "/review" || value.hasPrefix("/review ") {
      return periodMentioned(in: value) ?? .week
    }

    let explicitPatterns = [
      "what am i not doing",
      "what am i doing",
      "where am i falling behind"
    ]
    if explicitPatterns.contains(where: value.contains) {
      return periodMentioned(in: value) ?? .week
    }

    let missingPatterns = [
      "what did i miss",
      "what have i missed",
      "what am i missing",
      "what is missing",
      "show me what i missed",
      "which interests are missing",
      "which goals are missing",
      "what is underrepresented"
    ]
    if missingPatterns.contains(where: value.contains) {
      return periodMentioned(in: value) ?? .week
    }

    if value.contains("show me how"),
       value.contains("goal"),
       let period = periodMentioned(in: value) {
      return period
    }

    let reviewVerbs = ["analyze", "analyse", "review", "audit", "assess"]
    let focusScopes = [
      "focus",
      "calendar",
      "goals",
      "discipline",
      "last month",
      "last week"
    ]
    guard reviewVerbs.contains(where: value.contains),
          focusScopes.contains(where: value.contains) else {
      return nil
    }
    return periodMentioned(in: value) ?? .week
  }

  private static func periodMentioned(
    in value: String
  ) -> FocusReviewPeriod? {
    let words = Set(value.split(whereSeparator: { !$0.isLetter }).map(String.init))
    if !words.isDisjoint(with: ["month", "monthly"]) {
      return .month
    }
    if !words.isDisjoint(with: ["week", "weekly"]) {
      return .week
    }
    if !words.isDisjoint(with: ["today", "day", "daily"]) {
      return .day
    }
    return nil
  }
}
