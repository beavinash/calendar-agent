import SwiftData
import XCTest
@testable import CalendarAgent

@MainActor
final class IncompleteEventRescheduleTests: XCTestCase {
  private let startAt = Date(timeIntervalSince1970: 1_721_340_000)

  func testProposalAndAppliedResultKeepTypedWriteDetails() {
    let proposal = makeProposal()
    let applied = AppliedIncompleteEventReschedule(
      eventIdentifier: "agent-event",
      proposal: proposal,
      wasCreated: true
    )

    XCTAssertEqual(proposal.id, proposal.proposalId)
    XCTAssertEqual(applied.eventIdentifier, "agent-event")
    XCTAssertEqual(applied.proposal, proposal)
    XCTAssertTrue(applied.wasCreated)
  }

  func testRecordPersistsOnlyRescheduleLinkAndTiming() throws {
    let context = try makeModelContext()
    let proposal = makeProposal()
    let applied = AppliedIncompleteEventReschedule(
      eventIdentifier: "agent-event",
      proposal: proposal,
      wasCreated: true
    )
    let createdAt = startAt.addingTimeInterval(-60)
    let record = IncompleteEventRescheduleRecord(
      appliedEvent: applied,
      createdAt: createdAt
    )

    context.insert(record)
    try context.save()

    let persisted = try XCTUnwrap(
      context.fetch(FetchDescriptor<IncompleteEventRescheduleRecord>()).first
    )
    XCTAssertEqual(persisted.sourceCompletionKey, "opaque-source-key")
    XCTAssertEqual(persisted.proposalId, proposal.proposalId)
    XCTAssertEqual(persisted.eventIdentifier, "agent-event")
    XCTAssertEqual(persisted.scheduledStartAt, proposal.startAt)
    XCTAssertEqual(persisted.scheduledEndAt, proposal.endAt)
    XCTAssertEqual(persisted.createdAt, createdAt)
  }

  func testOutcomeDistinguishesTodayFromTomorrow() {
    let today = IncompleteEventRescheduleOutcome.today(startAt)
    let tomorrow = IncompleteEventRescheduleOutcome.tomorrow(startAt)

    XCTAssertEqual(today.scheduledStartAt, startAt)
    XCTAssertEqual(today.destinationTitle, "Today")
    XCTAssertTrue(today.confirmationMessage.hasPrefix("Added for today at "))
    XCTAssertEqual(tomorrow.scheduledStartAt, startAt)
    XCTAssertEqual(tomorrow.destinationTitle, "Tomorrow")
    XCTAssertTrue(
      tomorrow.confirmationMessage.hasPrefix("Added for tomorrow at ")
    )
  }

  func testErrorsGiveSpecificRecoveryMessages() {
    XCTAssertEqual(
      IncompleteEventRescheduleError.notIncomplete.errorDescription,
      "Mark this event Incomplete before adding it again."
    )
    XCTAssertEqual(
      IncompleteEventRescheduleError.allDay.errorDescription,
      "All-day events must be rescheduled in Apple Calendar."
    )
    XCTAssertEqual(
      IncompleteEventRescheduleError.invalidDuration.errorDescription,
      "This event's duration cannot be safely rescheduled."
    )
    XCTAssertEqual(
      IncompleteEventRescheduleError.noAvailableSlot.errorDescription,
      "No conflict-free time is available later today or tomorrow."
    )
  }

  private func makeProposal() -> IncompleteEventRescheduleProposal {
    IncompleteEventRescheduleProposal(
      proposalId: UUID(uuidString: "2523EC3A-BBB0-4D0D-938E-8D6F8A54BD37")!,
      sourceCompletionKey: "opaque-source-key",
      title: "Private event title",
      startAt: startAt,
      endAt: startAt.addingTimeInterval(3_600),
      reminderMinutes: 10
    )
  }

  private func makeModelContext() throws -> ModelContext {
    let schema = Schema([IncompleteEventRescheduleRecord.self])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      configurations: [configuration]
    )
    return ModelContext(container)
  }
}
