import Foundation
import OSLog

enum IncompleteReschedulePlanner {
  private static let gridMinutes = 15
  private static let weekendStartMinutes = 6 * 60
  private static let weekendEndMinutes = 23 * 60
  private static let protectedMealWindows = [
    (start: 7 * 60 + 45, end: 8 * 60 + 15),
    (start: 11 * 60 + 30, end: 12 * 60),
    (start: 19 * 60, end: 19 * 60 + 30)
  ]

  static func nextSlot(
    sourceStartAt: Date,
    sourceEndAt: Date,
    sourceIsAllDay: Bool,
    busyIntervals: [DateInterval],
    constraints: LocalScheduleConstraints
  ) -> DateInterval? {
    guard !sourceIsAllDay else {
      AppLogger.scheduling.info(
        "Incomplete reschedule rejected because the source is all-day"
      )
      return nil
    }

    let duration = sourceEndAt.timeIntervalSince(sourceStartAt)
    let durationMinutes = duration / 60
    guard duration.isFinite,
          duration > 0,
          constraints.calendar.isDate(
            sourceStartAt,
            inSameDayAs: sourceEndAt
          ) else {
      AppLogger.scheduling.info(
        "Incomplete reschedule rejected because duration is invalid"
      )
      return nil
    }
    guard constraints.minimumBreakMinutes >= 0 else {
      AppLogger.scheduling.error(
        "Incomplete reschedule rejected because break constraints are invalid"
      )
      return nil
    }

    AppLogger.scheduling.debug(
      "Starting incomplete reschedule search; durationMinutes=\(durationMinutes, privacy: .public), busyCount=\(busyIntervals.count, privacy: .public), breakMinutes=\(constraints.minimumBreakMinutes, privacy: .public)"
    )

    let calendar = constraints.calendar
    let today = calendar.startOfDay(for: constraints.now)
    for dayOffset in 0...1 {
      guard let day = calendar.date(
        byAdding: .day,
        value: dayOffset,
        to: today
      ) else {
        AppLogger.scheduling.error(
          "Incomplete reschedule could not calculate a search day"
        )
        continue
      }

      let windows = activeWindows(
        on: day,
        constraints: constraints
      )
      AppLogger.scheduling.debug(
        "Searching incomplete reschedule dayOffset=\(dayOffset, privacy: .public), windowCount=\(windows.count, privacy: .public)"
      )

      for (windowIndex, window) in windows.enumerated() {
        guard let slot = firstSlot(
          on: day,
          in: window,
          duration: duration,
          busyIntervals: busyIntervals,
          constraints: constraints
        ) else {
          AppLogger.scheduling.debug(
            "No incomplete reschedule slot in dayOffset=\(dayOffset, privacy: .public), windowIndex=\(windowIndex, privacy: .public)"
          )
          continue
        }

        AppLogger.scheduling.info(
          "Found incomplete reschedule slot; dayOffset=\(dayOffset, privacy: .public), windowIndex=\(windowIndex, privacy: .public), durationMinutes=\(durationMinutes, privacy: .public)"
        )
        return slot
      }

      if dayOffset == 0 {
        AppLogger.scheduling.debug(
          "No slot remains today; continuing incomplete reschedule search tomorrow"
        )
      }
    }

    AppLogger.scheduling.info(
      "No conflict-free incomplete reschedule slot exists today or tomorrow"
    )
    return nil
  }

  private static func activeWindows(
    on day: Date,
    constraints: LocalScheduleConstraints
  ) -> [(start: Int, end: Int)] {
    let weekday = constraints.calendar.component(.weekday, from: day)
    if weekday == 1 || weekday == 7 {
      return [(weekendStartMinutes, weekendEndMinutes)]
    }
    return [
      (constraints.dayStartMinutes, constraints.morningEndMinutes),
      (constraints.eveningStartMinutes, constraints.dayEndMinutes)
    ].filter { window in
      window.start >= 0
        && window.end <= 24 * 60
        && window.start < window.end
    }
  }

  private static func firstSlot(
    on day: Date,
    in window: (start: Int, end: Int),
    duration: TimeInterval,
    busyIntervals: [DateInterval],
    constraints: LocalScheduleConstraints
  ) -> DateInterval? {
    let calendar = constraints.calendar
    let firstMinute = roundedUpToGrid(window.start)
    var consideredCount = 0
    var rejectedBeforeNowCount = 0
    var rejectedPlanningRangeCount = 0
    var rejectedMealCount = 0
    var rejectedConflictCount = 0

    for minute in stride(
      from: firstMinute,
      through: window.end,
      by: gridMinutes
    ) {
      guard let start = localDate(
        on: day,
        minuteOfDay: minute,
        calendar: calendar
      ) else {
        continue
      }
      let end = start.addingTimeInterval(duration)
      guard let windowEnd = localDate(
        on: day,
        minuteOfDay: window.end,
        calendar: calendar
      ), end <= windowEnd,
      calendar.isDate(start, inSameDayAs: end) else {
        break
      }

      consideredCount += 1
      guard start >= constraints.now else {
        rejectedBeforeNowCount += 1
        continue
      }
      guard start >= constraints.planningStart,
            end <= constraints.planningEnd else {
        rejectedPlanningRangeCount += 1
        continue
      }
      let candidate = DateInterval(start: start, end: end)
      guard !overlapsProtectedMeal(
        candidate,
        on: day,
        calendar: calendar
      ) else {
        rejectedMealCount += 1
        continue
      }
      guard !hasConflict(
        candidate,
        busyIntervals: busyIntervals,
        minimumBreakMinutes: constraints.minimumBreakMinutes
      ) else {
        rejectedConflictCount += 1
        continue
      }

      AppLogger.scheduling.debug(
        "Incomplete reschedule window accepted a candidate after considering=\(consideredCount, privacy: .public)"
      )
      return candidate
    }

    AppLogger.scheduling.debug(
      "Incomplete reschedule window exhausted; considered=\(consideredCount, privacy: .public), beforeNow=\(rejectedBeforeNowCount, privacy: .public), planningRange=\(rejectedPlanningRangeCount, privacy: .public), meal=\(rejectedMealCount, privacy: .public), conflict=\(rejectedConflictCount, privacy: .public)"
    )
    return nil
  }

  private static func roundedUpToGrid(_ minute: Int) -> Int {
    let remainder = minute % gridMinutes
    return remainder == 0 ? minute : minute + gridMinutes - remainder
  }

  private static func localDate(
    on day: Date,
    minuteOfDay: Int,
    calendar: Calendar
  ) -> Date? {
    guard (0...(24 * 60)).contains(minuteOfDay) else {
      return nil
    }
    if minuteOfDay == 24 * 60 {
      return calendar.date(byAdding: .day, value: 1, to: day)
    }
    return calendar.date(
      bySettingHour: minuteOfDay / 60,
      minute: minuteOfDay % 60,
      second: 0,
      of: day
    )
  }

  private static func overlapsProtectedMeal(
    _ candidate: DateInterval,
    on day: Date,
    calendar: Calendar
  ) -> Bool {
    protectedMealWindows.contains { window in
      guard let start = localDate(
        on: day,
        minuteOfDay: window.start,
        calendar: calendar
      ), let end = localDate(
        on: day,
        minuteOfDay: window.end,
        calendar: calendar
      ) else {
        return true
      }
      return candidate.start < end && candidate.end > start
    }
  }

  private static func hasConflict(
    _ candidate: DateInterval,
    busyIntervals: [DateInterval],
    minimumBreakMinutes: Int
  ) -> Bool {
    let buffer = TimeInterval(minimumBreakMinutes * 60)
    let bufferedStart = candidate.start.addingTimeInterval(-buffer)
    let bufferedEnd = candidate.end.addingTimeInterval(buffer)
    return busyIntervals.contains { busy in
      bufferedStart < busy.end && bufferedEnd > busy.start
    }
  }
}
