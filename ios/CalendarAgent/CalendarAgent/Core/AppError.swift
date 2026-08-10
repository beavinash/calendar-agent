import Foundation

enum AppError: LocalizedError, Equatable {
  case invalidServerURL
  case backendCredentialRequired
  case calendarAccessRequired
  case noWritableCalendar
  case calendarConflict
  case dailyBlockLimit
  case unsafeCalendarEvent
  case calendarWriteRolledBack
  case calendarWriteUntracked
  case invalidSuggestionBatch
  case automaticCalendarAuthorizationRequired
  case secureStorage(String)
  case network(String)
  case aiConsentRequired

  var errorDescription: String? {
    switch self {
    case .invalidServerURL:
      "Configure your deployed HTTPS backend in Settings. localhost and 127.0.0.1 refer to this iPhone and work only in the Simulator."
    case .backendCredentialRequired:
      "Save the deployment app secret in Settings before contacting the backend."
    case .calendarAccessRequired:
      "Full Calendar access is required to read and analyze your Apple Calendar events."
    case .noWritableCalendar:
      "No writable default Apple Calendar is available for adding suggested events."
    case .calendarConflict:
      "Your calendar changed and this block now conflicts with another event."
    case .dailyBlockLimit:
      "This day already has your maximum number of agent focus blocks."
    case .unsafeCalendarEvent:
      "This event did not pass the on-device schedule safety checks."
    case .calendarWriteRolledBack:
      "The calendar change was rolled back because its local undo record could not be saved."
    case .calendarWriteUntracked:
      "The event was added, but its local undo record failed. Remove the marked event in Apple Calendar."
    case .invalidSuggestionBatch:
      "This review no longer has the exact seven-event batch you confirmed. Refresh the review before scheduling."
    case .automaticCalendarAuthorizationRequired:
      "Automatic scheduling needs renewed authorization for your writable default Apple Calendar."
    case .secureStorage(let message):
      "Secure storage failed: \(message)"
    case .network(let message):
      message
    case .aiConsentRequired:
      "Review and accept the AI data-sharing consent before sending context."
    }
  }
}
