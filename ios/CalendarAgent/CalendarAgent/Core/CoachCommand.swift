import Foundation

enum ClearHistoryScope: String, Equatable {
  case all
  case week
  case month
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
