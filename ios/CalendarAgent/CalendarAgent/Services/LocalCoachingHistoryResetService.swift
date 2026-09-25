import Foundation
import SwiftData

struct LocalCoachingHistoryResetSummary: Equatable {
  let deletedChatMessages: Int
  let deletedCheckIns: Int
  let deletedCompletions: Int
  let deletedPendingProposals: Int
  let deletedClearedIntervals: Int
}

@MainActor
enum LocalCoachingHistoryResetService {
  @discardableResult
  static func reset(
    scope: ClearHistoryScope,
    at timestamp: Date,
    calendar: Calendar,
    legacyCompletionKeys: Set<String>,
    modelContext: ModelContext,
    settings: AppSettings
  ) throws -> LocalCoachingHistoryResetSummary {
    AppLogger.persistence.info(
      "Local coaching history reset started; scope=\(scope.rawValue, privacy: .public)"
    )

    do {
      let summary: LocalCoachingHistoryResetSummary
      switch scope {
      case .all:
        summary = try deleteAllAnalysisHistory(modelContext: modelContext)
      case .week, .month:
        guard let interval = scope.analysisInterval(
          at: timestamp,
          calendar: calendar
        ) else {
          preconditionFailure("A scoped reset must resolve an interval")
        }
        summary = try deleteScopedAnalysisHistory(
          scope: scope,
          interval: interval,
          clearedAt: timestamp,
          legacyCompletionKeys: legacyCompletionKeys,
          modelContext: modelContext
        )
      }

      try modelContext.save()
      if scope == .all {
        settings.restartTracking(at: timestamp)
      }
      AppLogger.persistence.info(
        "Local coaching history reset succeeded; scope=\(scope.rawValue, privacy: .public) chat=\(summary.deletedChatMessages, privacy: .public) check_ins=\(summary.deletedCheckIns, privacy: .public) completions=\(summary.deletedCompletions, privacy: .public) proposals=\(summary.deletedPendingProposals, privacy: .public) intervals=\(summary.deletedClearedIntervals, privacy: .public)"
      )
      return summary
    } catch {
      modelContext.rollback()
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Local coaching history reset failed; scope=\(scope.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw error
    }
  }

  private static func deleteAllAnalysisHistory(
    modelContext: ModelContext
  ) throws -> LocalCoachingHistoryResetSummary {
    let chatCount = try deleteAll(
      ChatMessageRecord.self,
      modelContext: modelContext
    )
    let checkInCount = try deleteAll(
      CheckInRecord.self,
      modelContext: modelContext
    )
    let completionCount = try deleteAll(
      CalendarEventCompletionRecord.self,
      modelContext: modelContext
    )
    let proposalCount = try deleteAll(
      PendingCalendarProposalRecord.self,
      modelContext: modelContext
    )
    let intervalCount = try deleteAll(
      ClearedAnalysisIntervalRecord.self,
      modelContext: modelContext
    )
    return LocalCoachingHistoryResetSummary(
      deletedChatMessages: chatCount,
      deletedCheckIns: checkInCount,
      deletedCompletions: completionCount,
      deletedPendingProposals: proposalCount,
      deletedClearedIntervals: intervalCount
    )
  }

  private static func deleteScopedAnalysisHistory(
    scope: ClearHistoryScope,
    interval: DateInterval,
    clearedAt: Date,
    legacyCompletionKeys: Set<String>,
    modelContext: ModelContext
  ) throws -> LocalCoachingHistoryResetSummary {
    let chatCount = try deleteMatching(
      ChatMessageRecord.self,
      modelContext: modelContext
    ) { interval.containsHalfOpen($0.createdAt) }
    let checkInCount = try deleteMatching(
      CheckInRecord.self,
      modelContext: modelContext
    ) { interval.containsHalfOpen($0.createdAt) }
    let completionCount = try deleteMatching(
      CalendarEventCompletionRecord.self,
      modelContext: modelContext
    ) { record in
      if let occurrence = record.eventOccurrenceAt {
        return interval.containsHalfOpen(occurrence)
      }
      return legacyCompletionKeys.contains(record.completionKey)
    }
    let proposalCount = try deleteAll(
      PendingCalendarProposalRecord.self,
      modelContext: modelContext
    )

    let existingIntervals = try modelContext.fetch(
      FetchDescriptor<ClearedAnalysisIntervalRecord>()
    )
    if !existingIntervals.contains(where: {
      $0.startAt == interval.start && $0.endAt == interval.end
    }) {
      modelContext.insert(
        ClearedAnalysisIntervalRecord(
          scope: scope,
          interval: interval,
          clearedAt: clearedAt
        )
      )
    }

    return LocalCoachingHistoryResetSummary(
      deletedChatMessages: chatCount,
      deletedCheckIns: checkInCount,
      deletedCompletions: completionCount,
      deletedPendingProposals: proposalCount,
      deletedClearedIntervals: 0
    )
  }

  private static func deleteAll<Record: PersistentModel>(
    _ type: Record.Type,
    modelContext: ModelContext
  ) throws -> Int {
    let records = try modelContext.fetch(FetchDescriptor<Record>())
    records.forEach(modelContext.delete)
    return records.count
  }

  private static func deleteMatching<Record: PersistentModel>(
    _ type: Record.Type,
    modelContext: ModelContext,
    matches: (Record) -> Bool
  ) throws -> Int {
    let records = try modelContext.fetch(FetchDescriptor<Record>())
      .filter(matches)
    records.forEach(modelContext.delete)
    return records.count
  }
}

private extension DateInterval {
  func containsHalfOpen(_ date: Date) -> Bool {
    date >= start && date < end
  }
}
