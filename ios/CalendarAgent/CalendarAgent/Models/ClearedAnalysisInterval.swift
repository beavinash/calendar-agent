import Foundation
import SwiftData

@Model
final class ClearedAnalysisIntervalRecord {
  @Attribute(.unique) var id: UUID
  var scopeRaw: String
  var startAt: Date
  var endAt: Date
  var clearedAt: Date

  init(
    id: UUID = UUID(),
    scope: ClearHistoryScope,
    interval: DateInterval,
    clearedAt: Date = Date()
  ) {
    self.id = id
    scopeRaw = scope.rawValue
    startAt = interval.start
    endAt = interval.end
    self.clearedAt = clearedAt
  }

  var scope: ClearHistoryScope {
    ClearHistoryScope(rawValue: scopeRaw) ?? .all
  }

  var interval: DateInterval {
    DateInterval(start: startAt, end: endAt)
  }
}
