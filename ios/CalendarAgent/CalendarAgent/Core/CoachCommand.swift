import Foundation

enum ClearHistoryScope: String, Hashable {
  case all
  case week
  case month

  func analysisInterval(
    at date: Date,
    calendar: Calendar
  ) -> DateInterval? {
    switch self {
    case .all:
      nil
    case .week:
      FocusReviewPeriod.week.analysisBounds(at: date, calendar: calendar)
    case .month:
      FocusReviewPeriod.month.analysisBounds(at: date, calendar: calendar)
    }
  }
}

enum CoachCommand: Equatable {
  case clear(ClearHistoryScope)
}

enum CoachCommandParseResult: Equatable {
  case command(CoachCommand)
  case invalidClearSyntax
  case notACommand
}

enum CoachCommandParser {
  static func parse(_ message: String) -> CoachCommandParseResult {
    let value = message
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")

    switch value {
    case "/clear":
      return .command(.clear(.all))
    case "/clear week":
      return .command(.clear(.week))
    case "/clear month":
      return .command(.clear(.month))
    default:
      if value.hasPrefix("/clear") {
        return .invalidClearSyntax
      }
      return .notACommand
    }
  }
}
