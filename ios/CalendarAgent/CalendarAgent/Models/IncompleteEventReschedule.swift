import Foundation
import SwiftData

struct IncompleteEventRescheduleProposal: Identifiable, Hashable {
  let proposalId: UUID
  let sourceCompletionKey: String
  let title: String
  let startAt: Date
  let endAt: Date
  let reminderMinutes: Int

  var id: UUID { proposalId }
}

struct AppliedIncompleteEventReschedule: Hashable {
  let eventIdentifier: String
  let proposal: IncompleteEventRescheduleProposal
  let wasCreated: Bool
}

@Model
final class IncompleteEventRescheduleRecord {
  @Attribute(.unique) var sourceCompletionKey: String
  var proposalId: UUID
  var eventIdentifier: String
  var scheduledStartAt: Date
  var scheduledEndAt: Date
  var createdAt: Date

  init(
    sourceCompletionKey: String,
    proposalId: UUID,
    eventIdentifier: String,
    scheduledStartAt: Date,
    scheduledEndAt: Date,
    createdAt: Date = Date()
  ) {
    self.sourceCompletionKey = sourceCompletionKey
    self.proposalId = proposalId
    self.eventIdentifier = eventIdentifier
    self.scheduledStartAt = scheduledStartAt
    self.scheduledEndAt = scheduledEndAt
    self.createdAt = createdAt
  }

  convenience init(
    appliedEvent: AppliedIncompleteEventReschedule,
    createdAt: Date = Date()
  ) {
    self.init(
      sourceCompletionKey: appliedEvent.proposal.sourceCompletionKey,
      proposalId: appliedEvent.proposal.proposalId,
      eventIdentifier: appliedEvent.eventIdentifier,
      scheduledStartAt: appliedEvent.proposal.startAt,
      scheduledEndAt: appliedEvent.proposal.endAt,
      createdAt: createdAt
    )
  }
}

enum IncompleteEventRescheduleOutcome: Hashable {
  case today(Date)
  case tomorrow(Date)

  var scheduledStartAt: Date {
    switch self {
    case .today(let date), .tomorrow(let date):
      date
    }
  }

  var destinationTitle: String {
    switch self {
    case .today:
      "Today"
    case .tomorrow:
      "Tomorrow"
    }
  }

  var confirmationMessage: String {
    let time = scheduledStartAt.formatted(
      date: .omitted,
      time: .shortened
    )
    switch self {
    case .today:
      return "Added for today at \(time)."
    case .tomorrow:
      return "Added for tomorrow at \(time)."
    }
  }
}

enum IncompleteEventRescheduleError: LocalizedError, Equatable {
  case notIncomplete
  case allDay
  case invalidDuration
  case noAvailableSlot

  var errorDescription: String? {
    switch self {
    case .notIncomplete:
      "Mark this event Incomplete before adding it again."
    case .allDay:
      "All-day events must be rescheduled in Apple Calendar."
    case .invalidDuration:
      "This event's duration cannot be safely rescheduled."
    case .noAvailableSlot:
      "No conflict-free time is available later today or tomorrow."
    }
  }
}
