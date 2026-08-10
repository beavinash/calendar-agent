import Foundation

struct LocalScheduleConstraints {
  let now: Date
  let planningStart: Date
  let planningEnd: Date
  let dayStartMinutes: Int
  let morningEndMinutes: Int
  let eveningStartMinutes: Int
  let dayEndMinutes: Int
  let maxBlockMinutes: Int
  let maxDailyBlocks: Int
  let minimumBreakMinutes: Int
  let selectedFocusAreas: Set<FocusArea>
  let calendar: Calendar
}

enum ScheduleValidationMode: Equatable {
  case standard
  case reviewSuggestion
}

enum ScheduleValidationError: LocalizedError, Equatable {
  case invalidRange
  case past
  case outsidePlanningWindow
  case outsideActiveHours
  case tooShort
  case tooLong
  case weekendReviewDuration
  case protectedTime
  case disabledFocusArea
  case conflict
  case invalidContent
  case invalidReminder

  var errorDescription: String? {
    switch self {
    case .invalidRange:
      "The proposed time range is invalid."
    case .past:
      "The proposed block is in the past."
    case .outsidePlanningWindow:
      "The proposed block is outside the requested planning window."
    case .outsideActiveHours:
      "The proposed block is outside your morning and evening windows."
    case .tooShort:
      "The proposed block is shorter than 15 minutes."
    case .tooLong:
      "The proposed block exceeds your maximum duration."
    case .weekendReviewDuration:
      "Weekend review suggestions must be between 1 and 2 hours."
    case .protectedTime:
      "The proposed block overlaps protected meal time."
    case .disabledFocusArea:
      "The proposal uses a focus area you disabled."
    case .conflict:
      "The proposed block conflicts with your current calendar."
    case .invalidContent:
      "The proposed event content is invalid."
    case .invalidReminder:
      "The proposed reminder is invalid."
    }
  }
}

enum ScheduleValidator {
  private static let weekendStartMinutes = 6 * 60
  private static let weekendEndMinutes = 23 * 60
  private static let weekendMinimumBlockMinutes = 60
  private static let weekendMaximumBlockMinutes = 120
  private static let protectedMealWindows = [
    (start: 7 * 60 + 45, end: 8 * 60 + 15),
    (start: 11 * 60 + 30, end: 12 * 60),
    (start: 19 * 60, end: 19 * 60 + 30)
  ]

  static func validate(
    _ proposal: CalendarProposal,
    busyIntervals: [CalendarEventSnapshot],
    constraints: LocalScheduleConstraints,
    mode: ScheduleValidationMode
  ) throws {
    let title = proposal.title.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let rationale = proposal.rationale.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !title.isEmpty,
          proposal.title.count <= 80,
          !rationale.isEmpty,
          proposal.rationale.count <= 300,
          proposal.notes.count <= 500 else {
      throw ScheduleValidationError.invalidContent
    }
    guard (0...1_440).contains(proposal.reminderMinutes) else {
      throw ScheduleValidationError.invalidReminder
    }
    guard proposal.endAt > proposal.startAt else {
      throw ScheduleValidationError.invalidRange
    }
    guard proposal.startAt >= constraints.now else {
      throw ScheduleValidationError.past
    }
    guard proposal.startAt >= constraints.planningStart,
          proposal.endAt <= constraints.planningEnd else {
      throw ScheduleValidationError.outsidePlanningWindow
    }

    let minutes = proposal.endAt.timeIntervalSince(proposal.startAt) / 60
    guard minutes >= 15 else {
      throw ScheduleValidationError.tooShort
    }
    guard minutes <= Double(constraints.maxBlockMinutes) else {
      throw ScheduleValidationError.tooLong
    }
    guard constraints.selectedFocusAreas.contains(proposal.focusArea) else {
      throw ScheduleValidationError.disabledFocusArea
    }

    let calendar = constraints.calendar
    guard calendar.isDate(proposal.startAt, inSameDayAs: proposal.endAt) else {
      throw ScheduleValidationError.outsideActiveHours
    }
    let startValue = minuteOfDay(proposal.startAt, calendar: calendar)
    let endValue = minuteOfDay(proposal.endAt, calendar: calendar)
    let weekday = calendar.component(.weekday, from: proposal.startAt)
    let isWeekend = weekday == 1 || weekday == 7
    if isWeekend {
      if mode == .reviewSuggestion {
        guard minutes >= Double(weekendMinimumBlockMinutes),
              minutes <= Double(weekendMaximumBlockMinutes) else {
          throw ScheduleValidationError.weekendReviewDuration
        }
      }
      guard startValue >= Double(weekendStartMinutes),
            endValue <= Double(weekendEndMinutes) else {
        throw ScheduleValidationError.outsideActiveHours
      }
    } else {
      let fitsMorning = startValue >= Double(constraints.dayStartMinutes)
        && endValue <= Double(constraints.morningEndMinutes)
      let fitsEvening = startValue >= Double(constraints.eveningStartMinutes)
        && endValue <= Double(constraints.dayEndMinutes)
      guard fitsMorning || fitsEvening else {
        throw ScheduleValidationError.outsideActiveHours
      }
    }

    let overlapsProtectedMeal = protectedMealWindows.contains { window in
      startValue < Double(window.end) && endValue > Double(window.start)
    }
    guard !overlapsProtectedMeal else {
      throw ScheduleValidationError.protectedTime
    }

    guard startValue < endValue else {
      throw ScheduleValidationError.outsideActiveHours
    }

    let buffer = TimeInterval(constraints.minimumBreakMinutes * 60)
    let bufferedStart = proposal.startAt.addingTimeInterval(-buffer)
    let bufferedEnd = proposal.endAt.addingTimeInterval(buffer)
    let hasConflict = busyIntervals.contains { event in
      bufferedStart < event.endAt && bufferedEnd > event.startAt
    }
    guard !hasConflict else {
      throw ScheduleValidationError.conflict
    }
  }

  private static func minuteOfDay(
    _ date: Date,
    calendar: Calendar
  ) -> Double {
    let components = calendar.dateComponents(
      [.hour, .minute, .second, .nanosecond],
      from: date
    )
    return Double(components.hour ?? 0) * 60
      + Double(components.minute ?? 0)
      + Double(components.second ?? 0) / 60
      + Double(components.nanosecond ?? 0) / 60_000_000_000
  }
}
