import Foundation

struct CalendarEventSnapshot: Codable, Identifiable, Hashable {
  let eventId: String
  let calendarId: String
  let startAt: Date
  let endAt: Date
  let isAllDay: Bool
  let title: String?
  let focusArea: FocusArea?
  let completionStatus: CalendarEventCompletionStatus?

  var id: String { eventId }
}

struct CalendarSnapshotResult {
  let events: [CalendarEventSnapshot]
  let isTruncated: Bool
}

struct NoteContextPayload: Codable {
  let id: UUID
  let text: String
  let focusArea: FocusArea?
  let createdAt: Date
}

struct ConversationMessagePayload: Codable {
  let role: String
  let content: String
}

struct CalendarPreferencesPayload: Codable {
  let timezone: String
  let weekStartsOn: Int
  let dayStart: String
  let morningEnd: String
  let eveningStart: String
  let dayEnd: String
  let weekendStart: String
  let weekendEnd: String
  let breakfastStart: String
  let breakfastEnd: String
  let lunchStart: String
  let lunchEnd: String
  let dinnerStart: String
  let dinnerEnd: String
  let minimumBreakMinutes: Int
  let maxDailyBlocks: Int
  let selectedFocusAreas: [FocusArea]
}

enum FocusReviewSuggestionContract {
  static let requiredCount = 7
}

struct MissedPatternGroupPayload: Codable, Hashable {
  let rank: Int
  let displayTitle: String
  let missedCount: Int
  let inferredUnmarkedCount: Int
  let explicitIncompleteCount: Int
}

struct MissedPatternContextPayload: Codable, Hashable {
  let sourceReviewPeriod: FocusReviewPeriod
  let windowStartAt: Date
  let windowEndAt: Date
  let trackingCoverage: MissedEventTrackingCoverage
  let evaluatedEventCount: Int
  let coveredEvaluatedEventCount: Int
  let missedEventCount: Int
  let inferredUnmarkedCount: Int
  let explicitIncompleteCount: Int
  let omittedGroupCount: Int
  let groups: [MissedPatternGroupPayload]
}

struct AgentTurnRequest: Codable {
  let deviceId: UUID
  let message: String
  let calendarActionRequested: Bool
  let focusReviewRequested: Bool
  let focusReviewPeriod: FocusReviewPeriod?
  let focusReviewStart: Date?
  let focusReviewEnd: Date?
  let calendarContextTruncated: Bool
  let reviewCalendarContextTruncated: Bool
  let reviewSuggestionCount: Int
  let missedPatternContext: MissedPatternContextPayload?
  let provider: AIProvider
  let model: String?
  let currentTime: Date
  let planningStart: Date
  let planningEnd: Date
  let trackingStartedAt: Date
  let preferences: CalendarPreferencesPayload
  let calendar: [CalendarEventSnapshot]
  let reviewCalendar: [CalendarEventSnapshot]
  let notes: [NoteContextPayload]
  let history: [ConversationMessagePayload]

  init(
    deviceId: UUID,
    message: String,
    calendarActionRequested: Bool,
    focusReviewRequested: Bool,
    focusReviewPeriod: FocusReviewPeriod?,
    focusReviewStart: Date?,
    focusReviewEnd: Date?,
    calendarContextTruncated: Bool,
    reviewCalendarContextTruncated: Bool,
    reviewSuggestionCount: Int = FocusReviewSuggestionContract.requiredCount,
    missedPatternContext: MissedPatternContextPayload? = nil,
    provider: AIProvider,
    model: String?,
    currentTime: Date,
    planningStart: Date,
    planningEnd: Date,
    trackingStartedAt: Date,
    preferences: CalendarPreferencesPayload,
    calendar: [CalendarEventSnapshot],
    reviewCalendar: [CalendarEventSnapshot],
    notes: [NoteContextPayload],
    history: [ConversationMessagePayload]
  ) {
    self.deviceId = deviceId
    self.message = message
    self.calendarActionRequested = calendarActionRequested
    self.focusReviewRequested = focusReviewRequested
    self.focusReviewPeriod = focusReviewPeriod
    self.focusReviewStart = focusReviewStart
    self.focusReviewEnd = focusReviewEnd
    self.calendarContextTruncated = calendarContextTruncated
    self.reviewCalendarContextTruncated = reviewCalendarContextTruncated
    self.reviewSuggestionCount = reviewSuggestionCount
    self.missedPatternContext = missedPatternContext
    self.provider = provider
    self.model = model
    self.currentTime = currentTime
    self.planningStart = planningStart
    self.planningEnd = planningEnd
    self.trackingStartedAt = trackingStartedAt
    self.preferences = preferences
    self.calendar = calendar
    self.reviewCalendar = reviewCalendar
    self.notes = notes
    self.history = history
  }
}

struct CalendarProposal: Codable, Identifiable, Hashable {
  let proposalId: UUID
  let title: String
  let startAt: Date
  let endAt: Date
  let focusArea: FocusArea
  let rationale: String
  let notes: String
  let reminderMinutes: Int

  var id: UUID { proposalId }
}

enum ScheduleVisibility: String, Codable, Hashable {
  case visible
  case notVisible = "not_visible"
  case unclear
}

enum EvidenceConfidence: String, Codable, Hashable {
  case high
  case medium
  case low
}

struct FocusAreaReview: Codable, Identifiable, Hashable {
  let focusArea: FocusArea
  let recentVisibility: ScheduleVisibility
  let upcomingVisibility: ScheduleVisibility
  let scheduledEvidence: String
  let likelyImpact: String
  let confidence: EvidenceConfidence

  var id: FocusArea { focusArea }
}

enum FocusSuggestionAction: String, Codable, Hashable {
  case requiresExplicitScheduling = "requires_explicit_scheduling"
}

struct FocusEventSuggestion: Codable, Identifiable, Hashable {
  let focusArea: FocusArea
  let title: String
  let suggestedStartAt: Date
  let suggestedEndAt: Date
  let rationale: String
  let confidence: EvidenceConfidence
  let action: FocusSuggestionAction

  var id: String {
    "\(focusArea.rawValue)-\(suggestedStartAt.timeIntervalSince1970)-\(title)"
  }
}

struct FocusReviewResult: Codable, Hashable {
  let areas: [FocusAreaReview]
  let nextAdjustment: String
  let suggestedEvents: [FocusEventSuggestion]
  let period: FocusReviewPeriod
  let recentStartAt: Date
  let periodEndAt: Date
  let currentTime: Date
  let upcomingEndAt: Date
  let trackingStartedAt: Date
  let historyCoverage: FocusReviewHistoryCoverage
  let completionEvidence: FocusReviewCompletionEvidence
  let contextTruncated: Bool
}

enum FocusReviewHistoryCoverage: String, Codable, Hashable {
  case full
  case partial
  case beforeTracking = "before_tracking"
}

enum FocusReviewCompletionEvidence: String, Codable, Hashable {
  case notProvided = "not_provided"
  case userInput = "user_input"
}

struct AgentTurnResponse: Codable {
  let requestId: UUID
  let message: String
  let proposals: [CalendarProposal]
  let checkInQuestion: String?
  let warnings: [String]
  let provider: String
  let model: String
  let focusReview: FocusReviewResult?

  init(
    requestId: UUID,
    message: String,
    proposals: [CalendarProposal],
    checkInQuestion: String?,
    warnings: [String],
    provider: String,
    model: String,
    focusReview: FocusReviewResult? = nil
  ) {
    self.requestId = requestId
    self.message = message
    self.proposals = proposals
    self.checkInQuestion = checkInQuestion
    self.warnings = warnings
    self.provider = provider
    self.model = model
    self.focusReview = focusReview
  }
}

struct AppliedCalendarEvent: Hashable {
  let eventIdentifier: String
  let proposal: CalendarProposal
  let title: String
  let startAt: Date
  let endAt: Date

  init(eventIdentifier: String, proposal: CalendarProposal) {
    self.eventIdentifier = eventIdentifier
    self.proposal = proposal
    title = proposal.title
    startAt = proposal.startAt
    endAt = proposal.endAt
  }

  init(
    eventIdentifier: String,
    proposal: CalendarProposal,
    title: String,
    startAt: Date,
    endAt: Date
  ) {
    self.eventIdentifier = eventIdentifier
    self.proposal = proposal
    self.title = title
    self.startAt = startAt
    self.endAt = endAt
  }
}

struct CalendarDescriptor: Identifiable, Hashable {
  let id: String
  let title: String
  let accountTitle: String
  let isLikelyICloud: Bool
  let allowsModifications: Bool
}

struct CalendarDisplayEvent: Identifiable, Hashable {
  let completionKey: String
  let title: String
  let startAt: Date
  let endAt: Date
  let isAllDay: Bool
  let calendarTitle: String

  var id: String { completionKey }
}
