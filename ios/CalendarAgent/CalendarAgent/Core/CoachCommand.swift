import Foundation

enum ClearHistoryScope: String, CaseIterable, Hashable {
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

enum CoachSubmissionRoute: Equatable {
  case confirmLocalClear(ClearHistoryScope)
  case invalidLocalCommand
  case providerMessage
}

enum CoachSubmissionRouter {
  static func route(_ message: String) -> CoachSubmissionRoute {
    switch CoachCommandParser.parse(message) {
    case let .command(.clear(scope)):
      .confirmLocalClear(scope)
    case .invalidClearSyntax:
      .invalidLocalCommand
    case .notACommand:
      .providerMessage
    }
  }
}

enum CoachSubmissionHandler {
  static func handle(
    _ message: String,
    requestLocalClear: (ClearHistoryScope) -> Void,
    rejectInvalidCommand: () -> Void,
    sendProviderMessage: () -> Void
  ) {
    switch CoachSubmissionRouter.route(message) {
    case let .confirmLocalClear(scope):
      requestLocalClear(scope)
    case .invalidLocalCommand:
      rejectInvalidCommand()
    case .providerMessage:
      sendProviderMessage()
    }
  }
}

struct ClearHistoryConfirmationState: Equatable {
  private(set) var pendingScope: ClearHistoryScope?

  var isPresented: Bool {
    pendingScope != nil
  }

  mutating func request(_ scope: ClearHistoryScope) {
    pendingScope = scope
  }

  mutating func cancel() {
    pendingScope = nil
  }

  mutating func consumeConfirmedScope() -> ClearHistoryScope? {
    defer { pendingScope = nil }
    return pendingScope
  }
}

enum ClearHistoryPresentation {
  static let invalidCommandMessage =
    "Use /clear, /clear week, or /clear month."

  static func confirmationMessage(for scope: ClearHistoryScope) -> String {
    let preservation =
      " Saved notes, calendar-write audits, reschedule safety links, app and notification "
        + "settings, installation identity, credentials, and Apple Calendar events stay unchanged."
        + " Previously sent AI data is not deleted."

    switch scope {
    case .all:
      return
        "This deletes all local Mark-1 coach messages, check-ins, Complete/Incomplete "
        + "choices, every pending calendar draft, and earlier cleared-period exclusions. "
        + "Analysis tracking restarts today."
        + preservation
    case .week:
      return
        "This deletes local Mark-1 coach messages, check-ins, and Complete/Incomplete choices "
        + "from the previous completed week, clears every pending calendar draft, "
        + "and excludes that week from future analysis."
        + preservation
    case .month:
      return
        "This deletes local Mark-1 coach messages, check-ins, and Complete/Incomplete choices "
        + "from the previous completed month, clears every pending calendar draft, "
        + "and excludes that month from future analysis."
        + preservation
    }
  }

  static func confirmationTitle(for scope: ClearHistoryScope) -> String {
    switch scope {
    case .all:
      "Clear all local coaching history?"
    case .week:
      "Clear last week's local coaching history?"
    case .month:
      "Clear last month's local coaching history?"
    }
  }

  static func confirmationButtonTitle(
    for scope: ClearHistoryScope
  ) -> String {
    switch scope {
    case .all:
      "Clear All History"
    case .week:
      "Clear Last Week"
    case .month:
      "Clear Last Month"
    }
  }

  static func successMessage(for scope: ClearHistoryScope) -> String {
    let clearedDescription: String
    switch scope {
    case .all:
      clearedDescription = "All local coaching history was cleared."
    case .week:
      clearedDescription = "Last week's local analysis history was cleared."
    case .month:
      clearedDescription = "Last month's local analysis history was cleared."
    }
    return clearedDescription
      + " Apple Calendar events were not changed."
  }

  static func failureMessage(for scope: ClearHistoryScope) -> String {
    let scopeDescription: String
    switch scope {
    case .all:
      scopeDescription = "Local coaching history could not be cleared."
    case .week:
      scopeDescription = "Last week's local history could not be cleared."
    case .month:
      scopeDescription = "Last month's local history could not be cleared."
    }
    return scopeDescription + " Nothing was deleted. Please try again."
  }
}

struct ClearHistoryFeedback: Identifiable, Equatable {
  let id: UUID
  let title: String
  let message: String

  static func success(_ scope: ClearHistoryScope) -> Self {
    Self(
      id: UUID(),
      title: "History Cleared",
      message: ClearHistoryPresentation.successMessage(for: scope)
    )
  }

  static func failure(_ scope: ClearHistoryScope) -> Self {
    Self(
      id: UUID(),
      title: "History Not Cleared",
      message: ClearHistoryPresentation.failureMessage(for: scope)
    )
  }

  static var invalidCommand: Self {
    Self(
      id: UUID(),
      title: "Unknown Command",
      message: ClearHistoryPresentation.invalidCommandMessage
    )
  }
}
