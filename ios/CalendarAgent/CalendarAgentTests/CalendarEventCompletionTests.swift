import SwiftData
import XCTest
@testable import CalendarAgent

@MainActor
final class CalendarEventCompletionTests: XCTestCase {
  func testUpsertCreatesAppLocalCompletionWithoutCalendarDetails() throws {
    let context = try makeModelContext()
    let markedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let record = try CalendarEventCompletionStore.upsert(
      completionKey: "private-completion-key",
      status: .complete,
      at: markedAt,
      modelContext: context
    )

    XCTAssertEqual(record.completionKey, "private-completion-key")
    XCTAssertEqual(record.status, .complete)
    XCTAssertEqual(record.createdAt, markedAt)
    XCTAssertEqual(record.updatedAt, markedAt)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<CalendarEventCompletionRecord>()).count,
      1
    )
  }

  func testUpsertChangesStatusWithoutDuplicatingEventRecord() throws {
    let context = try makeModelContext()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let updatedAt = createdAt.addingTimeInterval(3_600)

    _ = try CalendarEventCompletionStore.upsert(
      completionKey: "same-event",
      status: .incomplete,
      at: createdAt,
      modelContext: context
    )
    let updated = try CalendarEventCompletionStore.upsert(
      completionKey: "same-event",
      status: .complete,
      at: updatedAt,
      modelContext: context
    )

    let records = try context.fetch(
      FetchDescriptor<CalendarEventCompletionRecord>()
    )
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(updated.status, .complete)
    XCTAssertEqual(updated.createdAt, createdAt)
    XCTAssertEqual(updated.updatedAt, updatedAt)
  }

  func testIncompleteSelectionIsImmediatelyFetchableAfterSave() throws {
    let context = try makeModelContext()

    _ = try CalendarEventCompletionStore.upsert(
      completionKey: "visible-event",
      status: .incomplete,
      modelContext: context
    )

    let descriptor = FetchDescriptor<CalendarEventCompletionRecord>(
      predicate: #Predicate { record in
        record.completionKey == "visible-event"
      }
    )
    let persisted = try XCTUnwrap(context.fetch(descriptor).first)
    XCTAssertEqual(persisted.status, .incomplete)
  }

  func testDifferentOccurrencesKeepIndependentStatuses() throws {
    let context = try makeModelContext()

    _ = try CalendarEventCompletionStore.upsert(
      completionKey: "occurrence-one",
      status: .complete,
      modelContext: context
    )
    _ = try CalendarEventCompletionStore.upsert(
      completionKey: "occurrence-two",
      status: .incomplete,
      modelContext: context
    )

    let records = try context.fetch(
      FetchDescriptor<CalendarEventCompletionRecord>()
    )
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(Set(records.map(\.status)), [.complete, .incomplete])
  }

  private func makeModelContext() throws -> ModelContext {
    let schema = Schema([CalendarEventCompletionRecord.self])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    return ModelContext(container)
  }
}
