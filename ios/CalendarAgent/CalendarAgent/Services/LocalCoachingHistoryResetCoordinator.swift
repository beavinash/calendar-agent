import Foundation
import SwiftData

@MainActor
enum LocalCoachingHistoryResetCoordinator {
  @discardableResult
  static func reset(
    scope: ClearHistoryScope,
    at timestamp: Date,
    calendar: Calendar,
    modelContext: ModelContext,
    settings: AppSettings,
    calendarStore: any CalendarStore
  ) throws -> LocalCoachingHistoryResetSummary {
    var legacyCompletionKeys: Set<String> = []

    if let interval = scope.analysisInterval(
      at: timestamp,
      calendar: calendar
    ) {
      guard calendarStore.accessState.canRead else {
        throw AppError.calendarAccessRequired
      }
      try calendarStore.refreshFromSystem()
      legacyCompletionKeys = Set(
        try calendarStore.events(
          from: interval.start,
          to: interval.end
        ).map(\.completionKey)
      )
    }

    return try LocalCoachingHistoryResetService.reset(
      scope: scope,
      at: timestamp,
      calendar: calendar,
      legacyCompletionKeys: legacyCompletionKeys,
      modelContext: modelContext,
      settings: settings
    )
  }
}
