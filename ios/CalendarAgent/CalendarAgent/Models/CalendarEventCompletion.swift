import Foundation
import SwiftData

enum CalendarEventCompletionStatus: String, Codable, CaseIterable, Hashable {
  case complete
  case incomplete
}

@Model
final class CalendarEventCompletionRecord {
  @Attribute(.unique) var completionKey: String
  var statusRaw: String
  var createdAt: Date
  var updatedAt: Date

  init(
    completionKey: String,
    status: CalendarEventCompletionStatus,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.completionKey = completionKey
    statusRaw = status.rawValue
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  var status: CalendarEventCompletionStatus {
    CalendarEventCompletionStatus(rawValue: statusRaw) ?? .incomplete
  }
}

enum CalendarEventCompletionStoreError: LocalizedError {
  case emptyCompletionKey

  var errorDescription: String? {
    "The calendar event identity is missing."
  }
}

@MainActor
enum CalendarEventCompletionStore {
  @discardableResult
  static func upsert(
    completionKey: String,
    status: CalendarEventCompletionStatus,
    at timestamp: Date = Date(),
    modelContext: ModelContext
  ) throws -> CalendarEventCompletionRecord {
    let key = completionKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      AppLogger.completion.error(
        "Rejected completion upsert because the completion key is empty"
      )
      throw CalendarEventCompletionStoreError.emptyCompletionKey
    }
    AppLogger.completion.debug(
      "Starting completion upsert; status=\(status.rawValue, privacy: .public) key=\(key, privacy: .private(mask: .hash))"
    )

    let descriptor = FetchDescriptor<CalendarEventCompletionRecord>(
      predicate: #Predicate { record in
        record.completionKey == key
      }
    )
    let record: CalendarEventCompletionRecord
    let existing: CalendarEventCompletionRecord?
    do {
      existing = try modelContext.fetch(descriptor).first
    } catch {
      let nsError = error as NSError
      AppLogger.completion.error(
        "Completion lookup failed; key=\(key, privacy: .private(mask: .hash)) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw error
    }
    let operation: String
    if let existing {
      existing.statusRaw = status.rawValue
      existing.updatedAt = timestamp
      record = existing
      operation = "update"
    } else {
      let created = CalendarEventCompletionRecord(
        completionKey: key,
        status: status,
        createdAt: timestamp
      )
      modelContext.insert(created)
      record = created
      operation = "insert"
    }

    do {
      try modelContext.save()
      AppLogger.completion.info(
        "Completion upsert succeeded; operation=\(operation, privacy: .public) status=\(status.rawValue, privacy: .public) key=\(key, privacy: .private(mask: .hash))"
      )
      return record
    } catch {
      let nsError = error as NSError
      AppLogger.completion.error(
        "Completion save failed; operation=\(operation, privacy: .public) key=\(key, privacy: .private(mask: .hash)) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      modelContext.rollback()
      throw error
    }
  }
}
