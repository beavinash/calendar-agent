import SwiftUI

enum FocusArea: String, Codable, CaseIterable, Identifiable, Hashable {
  case work
  case study
  case exercise
  case appointments
  case errands

  var id: String { rawValue }

  var title: String {
    switch self {
    case .work:
      "Work"
    case .study:
      "Study"
    case .exercise:
      "Exercise"
    case .appointments:
      "Appointments"
    case .errands:
      "Errands"
    }
  }

  var icon: String {
    switch self {
    case .work:
      "briefcase.fill"
    case .study:
      "book.closed.fill"
    case .exercise:
      "figure.run"
    case .appointments:
      "calendar.badge.clock"
    case .errands:
      "checklist"
    }
  }

  var color: Color {
    switch self {
    case .work:
      Color.CalendarAgent.focusWork
    case .study:
      Color.CalendarAgent.focusStudy
    case .exercise:
      Color.CalendarAgent.focusExercise
    case .appointments:
      Color.CalendarAgent.focusAppointments
    case .errands:
      Color.CalendarAgent.focusErrands
    }
  }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
  case openai

  var id: String { rawValue }
}
