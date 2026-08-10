import Foundation
import SwiftData

@Model
final class NoteRecord {
  @Attribute(.unique) var id: UUID
  var text: String
  var focusAreaRaw: String?
  var createdAt: Date
  var sourceMessageId: UUID?

  init(
    id: UUID = UUID(),
    text: String,
    focusArea: FocusArea? = nil,
    createdAt: Date = Date(),
    sourceMessageId: UUID? = nil
  ) {
    self.id = id
    self.text = text
    self.focusAreaRaw = focusArea?.rawValue
    self.createdAt = createdAt
    self.sourceMessageId = sourceMessageId
  }

  var focusArea: FocusArea? {
    get { focusAreaRaw.flatMap(FocusArea.init(rawValue:)) }
    set { focusAreaRaw = newValue?.rawValue }
  }
}

@Model
final class ChatMessageRecord {
  @Attribute(.unique) var id: UUID
  var roleRaw: String
  var content: String
  var createdAt: Date
  var sessionId: UUID?

  init(
    id: UUID = UUID(),
    role: ChatRole,
    content: String,
    createdAt: Date = Date(),
    sessionId: UUID? = nil
  ) {
    self.id = id
    self.roleRaw = role.rawValue
    self.content = content
    self.createdAt = createdAt
    self.sessionId = sessionId
  }

  var role: ChatRole {
    ChatRole(rawValue: roleRaw) ?? .assistant
  }
}

enum ChatRole: String, Codable {
  case user
  case assistant
}

@Model
final class CheckInRecord {
  @Attribute(.unique) var id: UUID
  var createdAt: Date
  var energy: Int
  var focusLevel: Int
  var commitmentCompleted: Bool
  var reflection: String

  init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    energy: Int,
    focusLevel: Int,
    commitmentCompleted: Bool,
    reflection: String
  ) {
    self.id = id
    self.createdAt = createdAt
    self.energy = energy
    self.focusLevel = focusLevel
    self.commitmentCompleted = commitmentCompleted
    self.reflection = reflection
  }
}

@Model
final class CalendarAuditRecord {
  @Attribute(.unique) var id: UUID
  var proposalId: UUID
  var eventIdentifier: String
  var title: String
  var startAt: Date
  var endAt: Date
  var focusAreaRaw: String
  var appliedAt: Date
  var undoneAt: Date?

  init(
    id: UUID = UUID(),
    appliedEvent: AppliedCalendarEvent,
    appliedAt: Date = Date()
  ) {
    self.id = id
    self.proposalId = appliedEvent.proposal.proposalId
    self.eventIdentifier = appliedEvent.eventIdentifier
    self.title = appliedEvent.title
    self.startAt = appliedEvent.startAt
    self.endAt = appliedEvent.endAt
    self.focusAreaRaw = appliedEvent.proposal.focusArea.rawValue
    self.appliedAt = appliedAt
  }

  var focusArea: FocusArea {
    FocusArea(rawValue: focusAreaRaw) ?? .work
  }
}

@Model
final class PendingCalendarProposalRecord {
  @Attribute(.unique) var proposalId: UUID
  var title: String
  var startAt: Date
  var endAt: Date
  var focusAreaRaw: String
  var rationale: String
  var notes: String
  var reminderMinutes: Int
  var createdAt: Date

  init(
    proposal: CalendarProposal,
    createdAt: Date = Date()
  ) {
    proposalId = proposal.proposalId
    title = proposal.title
    startAt = proposal.startAt
    endAt = proposal.endAt
    focusAreaRaw = proposal.focusArea.rawValue
    rationale = proposal.rationale
    notes = proposal.notes
    reminderMinutes = proposal.reminderMinutes
    self.createdAt = createdAt
  }

  var proposal: CalendarProposal {
    CalendarProposal(
      proposalId: proposalId,
      title: title,
      startAt: startAt,
      endAt: endAt,
      focusArea: FocusArea(rawValue: focusAreaRaw) ?? .work,
      rationale: rationale,
      notes: notes,
      reminderMinutes: reminderMinutes
    )
  }
}
