import Foundation
import SwiftData

@MainActor
protocol IncompleteEventRescheduling: AnyObject {
  func scheduleIncompleteEvent(
    _ source: CalendarDisplayEvent,
    constraints: LocalScheduleConstraints
  ) throws -> AppliedIncompleteEventReschedule
  func undoAgentEvent(identifier: String) throws
  func agentEventExists(identifier: String) -> Bool
}

extension CalendarService: IncompleteEventRescheduling {}

@MainActor
enum IncompleteEventRescheduleCoordinator {
  static func schedule(
    event: CalendarDisplayEvent,
    now: Date = Date(),
    settings: AppSettings,
    calendarService: any IncompleteEventRescheduling,
    modelContext: ModelContext,
    calendar: Calendar = .current
  ) throws -> IncompleteEventRescheduleOutcome {
    let key = event.completionKey
    AppLogger.scheduling.info(
      "Starting confirmed incomplete-event add; source_key=\(key, privacy: .private(mask: .hash))"
    )
    guard try completionStatus(
      for: key,
      modelContext: modelContext
    ) == .incomplete else {
      AppLogger.scheduling.error(
        "Incomplete-event add rejected because source is not saved as Incomplete; source_key=\(key, privacy: .private(mask: .hash))"
      )
      throw IncompleteEventRescheduleError.notIncomplete
    }

    let existingRecord = try rescheduleRecord(
      for: key,
      modelContext: modelContext
    )
    if let existingRecord,
       calendarService.agentEventExists(
         identifier: existingRecord.eventIdentifier
       ) {
      AppLogger.scheduling.info(
        "Incomplete-event add resolved to an existing linked EventKit item; source_key=\(key, privacy: .private(mask: .hash))"
      )
      return outcome(
        scheduledStartAt: existingRecord.scheduledStartAt,
        now: now,
        calendar: calendar
      )
    }

    guard let searchEnd = calendar.date(
      byAdding: .day,
      value: 2,
      to: calendar.startOfDay(for: now)
    ) else {
      AppLogger.scheduling.error(
        "Incomplete-event add could not construct its planning boundary"
      )
      throw IncompleteEventRescheduleError.noAvailableSlot
    }
    let durationMinutes = max(
      1,
      Int(ceil(event.endAt.timeIntervalSince(event.startAt) / 60))
    )
    let constraints = LocalScheduleConstraints(
      now: now,
      planningStart: now,
      planningEnd: searchEnd,
      dayStartMinutes: settings.dayStartHour * 60,
      morningEndMinutes: settings.morningEndMinutes,
      eveningStartMinutes: settings.eveningStartMinutes,
      dayEndMinutes: settings.dayEndHour * 60,
      maxBlockMinutes: max(240, durationMinutes),
      maxDailyBlocks: settings.maxDailyBlocks,
      minimumBreakMinutes: settings.minimumBreakMinutes,
      selectedFocusAreas: settings.selectedFocusAreas,
      calendar: calendar
    )
    let applied = try calendarService.scheduleIncompleteEvent(
      event,
      constraints: constraints
    )

    if let existingRecord {
      existingRecord.proposalId = applied.proposal.proposalId
      existingRecord.eventIdentifier = applied.eventIdentifier
      existingRecord.scheduledStartAt = applied.proposal.startAt
      existingRecord.scheduledEndAt = applied.proposal.endAt
      existingRecord.createdAt = Date()
    } else {
      modelContext.insert(
        IncompleteEventRescheduleRecord(appliedEvent: applied)
      )
    }
    do {
      try modelContext.save()
      AppLogger.persistence.info(
        "Incomplete-event link saved; created_event=\(applied.wasCreated, privacy: .public) source_key=\(key, privacy: .private(mask: .hash))"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Incomplete-event link save failed; created_event=\(applied.wasCreated, privacy: .public) source_key=\(key, privacy: .private(mask: .hash)) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      modelContext.rollback()
      guard applied.wasCreated else {
        throw AppError.calendarWriteUntracked
      }
      do {
        try calendarService.undoAgentEvent(
          identifier: applied.eventIdentifier
        )
        AppLogger.scheduling.info(
          "Rolled back incomplete-event EventKit write after link save failure"
        )
        throw AppError.calendarWriteRolledBack
      } catch let appError as AppError
        where appError == .calendarWriteRolledBack {
        throw appError
      } catch {
        let rollbackError = error as NSError
        AppLogger.scheduling.error(
          "Incomplete-event EventKit rollback failed; domain=\(rollbackError.domain, privacy: .private) code=\(rollbackError.code, privacy: .public)"
        )
        throw AppError.calendarWriteUntracked
      }
    }

    let result = outcome(
      scheduledStartAt: applied.proposal.startAt,
      now: now,
      calendar: calendar
    )
    AppLogger.scheduling.info(
      "Confirmed incomplete-event add completed; destination=\(result.destinationTitle, privacy: .public) created_event=\(applied.wasCreated, privacy: .public)"
    )
    return result
  }

  private static func completionStatus(
    for key: String,
    modelContext: ModelContext
  ) throws -> CalendarEventCompletionStatus? {
    let descriptor = FetchDescriptor<CalendarEventCompletionRecord>(
      predicate: #Predicate { record in
        record.completionKey == key
      },
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor).first?.status
  }

  private static func rescheduleRecord(
    for key: String,
    modelContext: ModelContext
  ) throws -> IncompleteEventRescheduleRecord? {
    let descriptor = FetchDescriptor<IncompleteEventRescheduleRecord>(
      predicate: #Predicate { record in
        record.sourceCompletionKey == key
      }
    )
    return try modelContext.fetch(descriptor).first
  }

  private static func outcome(
    scheduledStartAt: Date,
    now: Date,
    calendar: Calendar
  ) -> IncompleteEventRescheduleOutcome {
    if calendar.isDate(scheduledStartAt, inSameDayAs: now) {
      return .today(scheduledStartAt)
    }
    return .tomorrow(scheduledStartAt)
  }
}
