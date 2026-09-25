import Foundation

enum AnalysisEvidencePolicy {
  static func assignmentDate(
    startAt: Date,
    endAt: Date,
    isAllDay: Bool,
    calendar: Calendar
  ) -> Date {
    guard isAllDay else { return startAt }
    return calendar.startOfDay(for: endAt.addingTimeInterval(-1))
  }

  static func isCleared(
    startAt: Date,
    endAt: Date,
    isAllDay: Bool,
    intervals: [DateInterval],
    calendar: Calendar
  ) -> Bool {
    let evidenceDate = assignmentDate(
      startAt: startAt,
      endAt: endAt,
      isAllDay: isAllDay,
      calendar: calendar
    )
    return intervals.contains { interval in
      evidenceDate >= interval.start && evidenceDate < interval.end
    }
  }
}
