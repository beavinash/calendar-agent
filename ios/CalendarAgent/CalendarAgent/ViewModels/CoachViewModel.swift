import Foundation
import SwiftData

struct CoachErrorPresentation: Identifiable, Equatable {
  let id: UUID
  let message: String

  init(id: UUID = UUID(), message: String) {
    self.id = id
    self.message = message
  }
}

@MainActor
final class CoachViewModel: ObservableObject {
  typealias ClientFactory = (URL) -> any HTTPClient

  private static let legacyTrackingCoverageWarning =
    "This review period is not fully covered by the app's tracking history."

  @Published private(set) var pendingProposals: [CalendarProposal] = []
  @Published private(set) var warnings: [String] = []
  @Published private(set) var checkInQuestion: String?
  @Published private(set) var focusReview: FocusReviewResult?
  @Published private(set) var calendarActionMessage: String?
  @Published var isLoading = false
  @Published var isApplyingSuggestions = false
  @Published var presentedError: CoachErrorPresentation?
  @Published var showingConsent = false

  var errorMessage: String? {
    get { presentedError?.message }
    set {
      presentedError = newValue.map {
        CoachErrorPresentation(message: $0)
      }
    }
  }

  private let clientFactory: ClientFactory
  private let nowProvider: () -> Date
  private var lastPlanningStart = Date()
  private var lastPlanningEnd = Date()

  init(
    clientFactory: @escaping ClientFactory = {
      URLSessionHTTPClient(baseURL: $0)
    },
    now: @escaping () -> Date = Date.init
  ) {
    self.clientFactory = clientFactory
    nowProvider = now
  }

  func send(
    message: String,
    history: [ChatMessageRecord],
    notes: [NoteRecord],
    completions: [CalendarEventCompletionRecord] = [],
    clearedIntervals: [DateInterval] = [],
    sessionId: UUID? = nil,
    modelContext: ModelContext,
    settings: AppSettings,
    calendarService: any CalendarStore
  ) async {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isLoading else {
      AppLogger.coach.debug(
        "Coach send ignored; empty_message=\(trimmed.isEmpty, privacy: .public) already_loading=\(self.isLoading, privacy: .public)"
      )
      return
    }
    guard settings.aiDataConsent else {
      AppLogger.coach.info("Coach send blocked because AI consent is disabled")
      showingConsent = true
      errorMessage = AppError.aiConsentRequired.localizedDescription
      return
    }
    guard let baseURL = settings.apiBaseURL else {
      AppLogger.network.error(
        "Coach send blocked because the configured server URL is invalid"
      )
      errorMessage = AppError.invalidServerURL.localizedDescription
      return
    }
    let appSecret: String?
    do {
      let storedSecret = try settings.appSecret()
      if (storedSecret == nil || storedSecret?.isEmpty == true)
        && AppConfiguration.requiresDeploymentCredential(for: baseURL) {
        AppLogger.network.error(
          "Coach send blocked because the deployment credential is missing"
        )
        errorMessage = AppError.backendCredentialRequired.localizedDescription
        return
      }
      appSecret = storedSecret
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Coach deployment credential lookup failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = AppError.secureStorage(
        error.localizedDescription
      ).localizedDescription
      return
    }

    AppLogger.persistence.debug("Persisting user coach message")
    let userRecord = ChatMessageRecord(
      role: .user,
      content: trimmed,
      sessionId: sessionId
    )
    modelContext.insert(userRecord)
    do {
      try modelContext.save()
      AppLogger.persistence.info("User coach message persisted")
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "User coach message persistence failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      modelContext.rollback()
      errorMessage = error.localizedDescription
      return
    }
    isLoading = true
    errorMessage = nil
    calendarActionMessage = nil
    focusReview = nil
    defer { isLoading = false }

    do {
      let now = nowProvider()
      let calendar = Calendar.current
      let focusReviewPeriod =
        FocusReviewIntentDetector.reviewPeriod(trimmed)
      let focusReviewRequested = focusReviewPeriod != nil
      let calendarActionRequested = !focusReviewRequested
        && CalendarIntentDetector.requestsCalendarAction(trimmed)
      let includesMissedPatternContext = focusReviewRequested
      let todayStart = calendar.startOfDay(for: now)
      let tomorrowStart = calendar.date(
        byAdding: .day,
        value: 1,
        to: todayStart
      ) ?? todayStart.addingTimeInterval(86_400)
      let planningStart = focusReviewRequested ? tomorrowStart : now
      let planningEnd: Date
      if focusReviewRequested {
        planningEnd = calendar.date(
          byAdding: .day,
          value: 7,
          to: tomorrowStart
        ) ?? tomorrowStart.addingTimeInterval(7 * 86_400)
      } else {
        planningEnd = calendar.date(
          byAdding: .day,
          value: 8,
          to: todayStart
        ) ?? now.addingTimeInterval(8 * 86_400)
      }
      let reviewPeriodLabel = focusReviewPeriod?.rawValue ?? "none"
      AppLogger.coach.info(
        "Coach intent classified; review=\(focusReviewRequested, privacy: .public) scheduling=\(calendarActionRequested, privacy: .public) period=\(reviewPeriodLabel, privacy: .public)"
      )
      lastPlanningStart = planningStart
      lastPlanningEnd = planningEnd
      var focusReviewStart: Date?
      var focusReviewEnd: Date?
      var availabilitySnapshot = CalendarSnapshotResult(
        events: [],
        isTruncated: false
      )
      var reviewSnapshot = CalendarSnapshotResult(
        events: [],
        isTruncated: false
      )
      var missedPatternContext: MissedPatternContextPayload?
      let completionByKey: [String: CalendarEventCompletionStatus] =
        completions.reduce(into: [:]) {
          result, completion in
          if result[completion.completionKey] == nil {
            result[completion.completionKey] = completion.status
          }
        }
      if focusReviewRequested || calendarActionRequested {
        guard calendarService.accessState.canRead else {
          AppLogger.calendar.error(
            "Coach calendar operation blocked because read access is unavailable"
          )
          throw AppError.calendarAccessRequired
        }
        AppLogger.calendar.debug("Refreshing Apple Calendar for coach request")
        do {
          try calendarService.refreshFromSystem()
        } catch {
          let nsError = error as NSError
          AppLogger.calendar.error(
            "Apple Calendar refresh for coach request failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
          )
          throw error
        }
        AppLogger.calendar.info("Apple Calendar refresh for coach request completed")
        if includesMissedPatternContext {
          let missedPeriod = focusReviewPeriod ?? .day
          let analysisBounds = MissedEventInsightQuery.analysisBounds(
            for: missedPeriod,
            at: now,
            calendar: calendar
          )
          let fetchBounds = MissedEventInsightQuery.fetchBounds(
            for: missedPeriod,
            at: now,
            calendar: calendar
          )
          let missedEvents = try calendarService.events(
            from: fetchBounds.start,
            to: fetchBounds.end
          )
          let insight = MissedEventInsightBuilder.build(
            events: missedEvents,
            completionStatuses: completionByKey,
            period: missedPeriod,
            now: now,
            trackingStartedAt: settings.trackingStartedAt,
            calendar: calendar,
            clearedIntervals: clearedIntervals
          )
          missedPatternContext = insight.contextPayload(
            window: analysisBounds
          )
          AppLogger.coach.info(
            "Missed-pattern context prepared; period=\(missedPeriod.rawValue, privacy: .public) groups=\(missedPatternContext?.groups.count ?? 0, privacy: .public) omitted_groups=\(missedPatternContext?.omittedGroupCount ?? 0, privacy: .public) missed_events=\(insight.missedEventCount, privacy: .public)"
          )
        }
        if focusReviewRequested, let focusReviewPeriod {
          let reviewBounds = focusReviewPeriod.analysisBounds(
            at: now,
            calendar: calendar
          )
          focusReviewStart = reviewBounds.start
          focusReviewEnd = reviewBounds.end
          do {
            reviewSnapshot = try calendarService.snapshot(
              from: reviewBounds.start,
              to: reviewBounds.end,
              includeTitles: true,
              includeFreeEvents: true
            )
          } catch {
            let nsError = error as NSError
            AppLogger.calendar.error(
              "Review snapshot failed; period=\(focusReviewPeriod.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
            )
            throw error
          }
          AppLogger.calendar.info(
            "Review snapshot captured; period=\(focusReviewPeriod.rawValue, privacy: .public) events=\(reviewSnapshot.events.count, privacy: .public) truncated=\(reviewSnapshot.isTruncated, privacy: .public)"
          )
        }
        do {
          availabilitySnapshot = try calendarService.snapshot(
            from: planningStart,
            to: planningEnd,
            includeTitles: false,
            includeFreeEvents: false
          )
        } catch {
          let nsError = error as NSError
          AppLogger.calendar.error(
            "Availability snapshot failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
          )
          throw error
        }
        AppLogger.calendar.info(
          "Availability snapshot captured; events=\(availabilitySnapshot.events.count, privacy: .public) truncated=\(availabilitySnapshot.isTruncated, privacy: .public)"
        )
      } else {
        AppLogger.calendar.debug(
          "Calendar snapshots skipped because the coach intent does not require them"
        )
      }

      let reviewEvents = reviewSnapshot.events.filter { event in
        !AnalysisEvidencePolicy.isCleared(
          startAt: event.startAt,
          endAt: event.endAt,
          isAllDay: event.isAllDay,
          intervals: clearedIntervals,
          calendar: calendar
        )
      }.map { event in
        CalendarEventSnapshot(
          eventId: event.eventId,
          calendarId: event.calendarId,
          startAt: event.startAt,
          endAt: event.endAt,
          isAllDay: event.isAllDay,
          title: event.title,
          focusArea: event.focusArea,
          completionStatus: completionByKey[event.eventId]
        )
      }
      let reviewedCompletionCount = reviewEvents.filter {
        $0.completionStatus != nil
      }.count
      AppLogger.completion.debug(
        "Merged completion evidence into review snapshot; review_events=\(reviewEvents.count, privacy: .public) matched_completions=\(reviewedCompletionCount, privacy: .public)"
      )

      let request = AgentTurnRequest(
        deviceId: settings.deviceID,
        message: trimmed,
        calendarActionRequested: calendarActionRequested,
        focusReviewRequested: focusReviewRequested,
        focusReviewPeriod: focusReviewPeriod,
        focusReviewStart: focusReviewStart,
        focusReviewEnd: focusReviewEnd,
        calendarContextTruncated: availabilitySnapshot.isTruncated,
        reviewCalendarContextTruncated: reviewSnapshot.isTruncated,
        missedPatternContext: missedPatternContext,
        provider: .openai,
        model: nil,
        currentTime: now,
        planningStart: planningStart,
        planningEnd: planningEnd,
        trackingStartedAt: settings.trackingStartedAt,
        preferences: CalendarPreferencesPayload(
          timezone: TimeZone.current.identifier,
          weekStartsOn: calendar.firstWeekday,
          dayStart: settings.timeString(hour: settings.dayStartHour),
          morningEnd: settings.timeString(
            totalMinutes: settings.morningEndMinutes
          ),
          eveningStart: settings.timeString(
            totalMinutes: settings.eveningStartMinutes
          ),
          dayEnd: settings.timeString(hour: settings.dayEndHour),
          weekendStart: "06:00:00",
          weekendEnd: "23:00:00",
          breakfastStart: "07:45:00",
          breakfastEnd: "08:15:00",
          lunchStart: "11:30:00",
          lunchEnd: "12:00:00",
          dinnerStart: "19:00:00",
          dinnerEnd: "19:30:00",
          minimumBreakMinutes: settings.minimumBreakMinutes,
          maxDailyBlocks: settings.maxDailyBlocks,
          selectedFocusAreas: FocusArea.allCases.filter {
            settings.selectedFocusAreas.contains($0)
          }
        ),
        calendar: availabilitySnapshot.events,
        reviewCalendar: reviewEvents,
        notes: [],
        history: history
          .filter { sessionId == nil || $0.sessionId == sessionId }
          .sorted { $0.createdAt < $1.createdAt }
          .suffix(12)
          .map {
            ConversationMessagePayload(
              role: $0.role.rawValue,
              content: String($0.content.prefix(4_000))
            )
          }
      )

      AppLogger.network.info(
        "Dispatching coach provider request; review=\(focusReviewRequested, privacy: .public) scheduling=\(calendarActionRequested, privacy: .public) availability_events=\(request.calendar.count, privacy: .public) review_events=\(request.reviewCalendar.count, privacy: .public) missed_groups=\(request.missedPatternContext?.groups.count ?? 0, privacy: .public) history_messages=\(request.history.count, privacy: .public)"
      )
      let client = clientFactory(baseURL)
      let response: AgentTurnResponse
      do {
        response = try await client.sendTurn(
          request,
          appSecret: appSecret
        )
      } catch {
        let nsError = error as NSError
        AppLogger.network.error(
          "Coach provider request failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
        throw error
      }
      AppLogger.network.info(
        "Coach provider request completed; proposals=\(response.proposals.count, privacy: .public) has_review=\(response.focusReview != nil, privacy: .public) review_suggestions=\(response.focusReview?.suggestedEvents.count ?? 0, privacy: .public) warnings=\(response.warnings.count, privacy: .public)"
      )
      let assistantRecord = ChatMessageRecord(
        role: .assistant,
        content: response.message,
        sessionId: sessionId
      )
      modelContext.insert(assistantRecord)
      do {
        try modelContext.save()
      } catch {
        let nsError = error as NSError
        AppLogger.persistence.error(
          "Assistant coach message persistence failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
        throw error
      }
      AppLogger.persistence.info("Assistant coach message persisted")
      warnings = response.warnings
      if focusReviewRequested {
        if let review = response.focusReview {
          let validation = validatedFocusReview(
            review,
            expectedPeriod: focusReviewPeriod,
            expectedStart: focusReviewStart,
            expectedPeriodEnd: focusReviewEnd,
            expectedCurrent: now,
            expectedPlanningStart: planningStart,
            expectedPlanningEnd: planningEnd,
            expectedTrackingStart: settings.trackingStartedAt,
            expectedFocusAreas: settings.selectedFocusAreas,
            expectedReviewTruncated: reviewSnapshot.isTruncated,
            expectedAvailabilityTruncated: availabilitySnapshot.isTruncated,
            reviewEvents: reviewEvents,
            availabilityEvents: availabilitySnapshot.events,
            settings: settings
          )
          if let validation {
            focusReview = validation.review
            warnings.removeAll {
              $0 == Self.legacyTrackingCoverageWarning
            }
            if let suggestionWarning = validation.suggestionWarning {
              appendWarning(suggestionWarning)
            }
            AppLogger.coach.info(
              "Coach review accepted; period=\(validation.review.period.rawValue, privacy: .public) suggestions=\(validation.review.suggestedEvents.count, privacy: .public)"
            )
          } else {
            AppLogger.coach.error("Coach review rejected by local validation")
            appendWarning(
              "The calendar review was ignored because its evidence contract was "
                + "invalid."
            )
          }
        } else {
          AppLogger.coach.info(
            "Coach review request completed without structured review data"
          )
        }
      } else if response.focusReview != nil {
        AppLogger.coach.error(
          "Ignoring unexpected structured review for a non-review request"
        )
        appendWarning(
          "Unexpected calendar review data was ignored because this message "
            + "did not request a review."
        )
      }
      if reviewSnapshot.isTruncated || availabilitySnapshot.isTruncated {
        AppLogger.calendar.info(
          "Coach result is based on truncated calendar context"
        )
        appendWarning(
          "Calendar context used the first 300 events in a window; the result is incomplete."
        )
      }
      checkInQuestion = response.checkInQuestion
      if calendarActionRequested {
        AppLogger.scheduling.debug(
          "Replacing pending proposals from provider response; count=\(response.proposals.count, privacy: .public)"
        )
        try replacePendingProposals(
          response.proposals,
          modelContext: modelContext
        )
      } else if !response.proposals.isEmpty {
        AppLogger.scheduling.error(
          "Ignoring unexpected proposals for a non-scheduling request; count=\(response.proposals.count, privacy: .public)"
        )
        appendWarning(
          "Unexpected calendar drafts were ignored because this message "
            + "did not request scheduling."
        )
      }
    } catch {
      let nsError = error as NSError
      AppLogger.coach.error(
        "Coach send failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
    }
  }

  func apply(
    _ proposal: CalendarProposal,
    modelContext: ModelContext,
    settings: AppSettings,
    calendarService: any CalendarStore
  ) {
    AppLogger.scheduling.info("Starting explicit calendar proposal application")
    do {
      try applyValidatedProposal(
        proposal,
        modelContext: modelContext,
        settings: settings,
        calendarService: calendarService,
        validationMode: .standard
      )
      try calendarService.refreshFromSystem()
      calendarActionMessage =
        "Added 1 event to Apple Calendar."
      AppLogger.scheduling.info(
        "Explicit calendar proposal application completed"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.scheduling.error(
        "Explicit calendar proposal application failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
    }
  }

  func applySuggestedEvents(
    _ suggestions: [FocusEventSuggestion],
    modelContext: ModelContext,
    settings: AppSettings,
    calendarService: any CalendarStore
  ) {
    guard suggestions.count == FocusReviewSuggestionContract.requiredCount,
          suggestions == focusReview?.suggestedEvents,
          !isApplyingSuggestions else {
      AppLogger.scheduling.error(
        "Suggestion batch rejected; count=\(suggestions.count, privacy: .public) matches_review=\(suggestions == self.focusReview?.suggestedEvents, privacy: .public) already_applying=\(self.isApplyingSuggestions, privacy: .public)"
      )
      errorMessage = AppError.invalidSuggestionBatch.localizedDescription
      return
    }
    guard let review = focusReview else {
      AppLogger.scheduling.error(
        "Suggestion batch rejected because no accepted review is available"
      )
      errorMessage = AppError.invalidSuggestionBatch.localizedDescription
      return
    }

    AppLogger.scheduling.info(
      "Starting review suggestion batch application; count=\(suggestions.count, privacy: .public) period=\(review.period.rawValue, privacy: .public)"
    )
    isApplyingSuggestions = true
    errorMessage = nil
    calendarActionMessage = nil
    defer { isApplyingSuggestions = false }

    let proposals = suggestions.map { suggestion in
      CalendarProposal(
        proposalId: UUID(),
        title: suggestion.title,
        startAt: suggestion.suggestedStartAt,
        endAt: suggestion.suggestedEndAt,
        focusArea: suggestion.focusArea,
        rationale: suggestion.rationale,
        notes: "Confirmed from the \(review.period.title) review.",
        reminderMinutes: 10
      )
    }
    lastPlanningEnd = review.upcomingEndAt

    do {
      try replacePendingProposals(
        proposals,
        modelContext: modelContext
      )
      AppLogger.scheduling.debug(
        "Review suggestion proposals persisted; count=\(proposals.count, privacy: .public)"
      )
      try calendarService.refreshFromSystem()
      AppLogger.calendar.info(
        "Apple Calendar refreshed before suggestion batch application"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.scheduling.error(
        "Suggestion batch preparation failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
      return
    }

    var appliedCount = 0
    for (index, proposal) in proposals.enumerated() {
      AppLogger.scheduling.debug(
        "Applying suggestion in batch; position=\(index + 1, privacy: .public) total=\(proposals.count, privacy: .public)"
      )
      do {
        try applyValidatedProposal(
          proposal,
          modelContext: modelContext,
          settings: settings,
          calendarService: calendarService,
          validationMode: .reviewSuggestion
        )
        appliedCount += 1
        AppLogger.scheduling.info(
          "Suggestion batch progress; applied=\(appliedCount, privacy: .public) total=\(proposals.count, privacy: .public)"
        )
      } catch {
        let nsError = error as NSError
        AppLogger.scheduling.error(
          "Suggestion batch application stopped; position=\(index + 1, privacy: .public) applied=\(appliedCount, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
        errorMessage = error.localizedDescription
        break
      }
    }

    do {
      try calendarService.refreshFromSystem()
      AppLogger.calendar.info(
        "Apple Calendar refreshed after suggestion batch application"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.calendar.error(
        "Post-batch Apple Calendar refresh failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      appendWarning(
        "Events were added, but Apple Calendar could not refresh: "
          + error.localizedDescription
      )
    }
    focusReview = nil
    let remainingCount = pendingProposals.count
    if appliedCount == FocusReviewSuggestionContract.requiredCount {
      calendarActionMessage = "Added 7 events to Apple Calendar."
    } else if appliedCount > 0 {
      calendarActionMessage =
        "Added \(appliedCount) of 7 events; \(remainingCount) still need review."
    }
    AppLogger.scheduling.info(
      "Suggestion batch finished; requested=\(proposals.count, privacy: .public) applied=\(appliedCount, privacy: .public) remaining=\(remainingCount, privacy: .public)"
    )
  }

  func resetVisibleSessionState() {
    AppLogger.coach.info("Resetting visible coach session state")
    warnings = []
    checkInQuestion = nil
    focusReview = nil
    calendarActionMessage = nil
    errorMessage = nil
    showingConsent = false
  }

  func saveAsNote(
    _ message: ChatMessageRecord,
    modelContext: ModelContext
  ) {
    let note = NoteRecord(
      text: message.content,
      sourceMessageId: message.id
    )
    modelContext.insert(note)
    do {
      try modelContext.save()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func restorePendingProposals(modelContext: ModelContext) {
    AppLogger.persistence.debug("Restoring pending calendar proposals")
    do {
      let descriptor = FetchDescriptor<PendingCalendarProposalRecord>(
        sortBy: [SortDescriptor(\.createdAt)]
      )
      pendingProposals = try modelContext.fetch(descriptor).map(\.proposal)
      AppLogger.persistence.info(
        "Pending calendar proposals restored; count=\(self.pendingProposals.count, privacy: .public)"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Pending proposal restore failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
    }
  }

  func clearProposals(modelContext: ModelContext) {
    AppLogger.persistence.info("Clearing pending calendar proposals")
    do {
      let records = try modelContext.fetch(
        FetchDescriptor<PendingCalendarProposalRecord>()
      )
      for record in records {
        modelContext.delete(record)
      }
      try modelContext.save()
      pendingProposals = []
      warnings = []
      checkInQuestion = nil
      calendarActionMessage = nil
      AppLogger.persistence.info(
        "Pending calendar proposals cleared; deleted=\(records.count, privacy: .public)"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Pending proposal clear failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }

  private func autoSchedulePendingProposals(
    modelContext: ModelContext,
    settings: AppSettings,
    calendarService: any CalendarStore
  ) {
    guard !pendingProposals.isEmpty else {
      AppLogger.scheduling.debug(
        "Automatic scheduling skipped because there are no pending proposals"
      )
      return
    }
    guard calendarService.accessState.canRead else {
      AppLogger.scheduling.info(
        "Automatic scheduling blocked because calendar read access is unavailable"
      )
      appendWarning(
        "Automatic scheduling is waiting for full Apple Calendar access."
      )
      return
    }
    guard let authorizedIdentifier =
            settings.autoScheduleCalendarIdentifier,
          calendarService.defaultWritableCalendar?.id
            == authorizedIdentifier else {
      AppLogger.scheduling.info(
        "Automatic scheduling blocked because authorization no longer matches the writable calendar"
      )
      appendWarning(
        "Automatic scheduling needs an available writable Apple Calendar."
      )
      return
    }

    let proposals = pendingProposals
    AppLogger.scheduling.info(
      "Starting automatic proposal batch; count=\(proposals.count, privacy: .public)"
    )
    var appliedCount = 0
    for (index, proposal) in proposals.enumerated() {
      do {
        try applyValidatedProposal(
          proposal,
          modelContext: modelContext,
          settings: settings,
          calendarService: calendarService,
          validationMode: .standard,
          automaticCalendarIdentifier: authorizedIdentifier
        )
        appliedCount += 1
        AppLogger.scheduling.info(
          "Automatic proposal batch progress; applied=\(appliedCount, privacy: .public) total=\(proposals.count, privacy: .public)"
        )
      } catch {
        let nsError = error as NSError
        AppLogger.scheduling.error(
          "Automatic proposal batch stopped; position=\(index + 1, privacy: .public) applied=\(appliedCount, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
        appendWarning(
          "Automatic scheduling stopped: \(error.localizedDescription)"
        )
        break
      }
    }

    if appliedCount > 0 {
      do {
        try calendarService.refreshToday()
        AppLogger.calendar.info(
          "Today calendar data refreshed after automatic scheduling"
        )
      } catch {
        let nsError = error as NSError
        AppLogger.calendar.error(
          "Today calendar refresh after automatic scheduling failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
        appendWarning(
          "Calendar events were added, but Today could not refresh: "
            + error.localizedDescription
        )
      }
    }
    if appliedCount > 0 {
      calendarActionMessage = automaticScheduleSummary(
        appliedCount: appliedCount,
        remainingCount: pendingProposals.count,
        calendarTitle: calendarService.writableCalendars.first(
          where: { $0.id == authorizedIdentifier }
        )?.title ?? "Apple Calendar"
      )
    }
    AppLogger.scheduling.info(
      "Automatic proposal batch finished; requested=\(proposals.count, privacy: .public) applied=\(appliedCount, privacy: .public) remaining=\(self.pendingProposals.count, privacy: .public)"
    )
  }

  private func validatedFocusReview(
    _ review: FocusReviewResult,
    expectedPeriod: FocusReviewPeriod?,
    expectedStart: Date?,
    expectedPeriodEnd: Date?,
    expectedCurrent: Date,
    expectedPlanningStart: Date,
    expectedPlanningEnd: Date,
    expectedTrackingStart: Date,
    expectedFocusAreas: Set<FocusArea>,
    expectedReviewTruncated: Bool,
    expectedAvailabilityTruncated: Bool,
    reviewEvents: [CalendarEventSnapshot],
    availabilityEvents: [CalendarEventSnapshot],
    settings: AppSettings
  ) -> (review: FocusReviewResult, suggestionWarning: String?)? {
    guard let expectedPeriod,
          let expectedStart,
          let expectedPeriodEnd else {
      AppLogger.coach.error(
        "Review validation failed because expected review bounds are missing"
      )
      return nil
    }
    let areas = review.areas.map(\.focusArea)
    let expectedCompletionEvidence: FocusReviewCompletionEvidence =
      reviewEvents.contains { $0.completionStatus != nil }
        ? .userInput : .notProvided
    let expectedCoverage: FocusReviewHistoryCoverage
    if expectedTrackingStart <= expectedStart {
      expectedCoverage = .full
    } else if expectedTrackingStart < expectedPeriodEnd {
      expectedCoverage = .partial
    } else {
      expectedCoverage = .beforeTracking
    }
    let expectedContextTruncated = expectedReviewTruncated
      || expectedAvailabilityTruncated
    let areasMatch = areas.count == expectedFocusAreas.count
      && Set(areas) == expectedFocusAreas
    let periodMatches = review.period == expectedPeriod
    let evidenceMatches = review.completionEvidence
      == expectedCompletionEvidence
    let coverageMatches = review.historyCoverage == expectedCoverage
    let truncationMatches = review.contextTruncated
      == expectedContextTruncated
    guard areasMatch,
          periodMatches,
          evidenceMatches,
          coverageMatches,
          truncationMatches else {
      AppLogger.coach.error(
        "Review evidence contract mismatch; areas_match=\(areasMatch, privacy: .public) period_match=\(periodMatches, privacy: .public) evidence_match=\(evidenceMatches, privacy: .public) coverage_match=\(coverageMatches, privacy: .public) truncation_match=\(truncationMatches, privacy: .public)"
      )
      return nil
    }
    let boundsOrdered = review.recentStartAt <= review.periodEndAt
      && review.periodEndAt <= review.currentTime
      && review.currentTime < review.upcomingEndAt
    guard boundsOrdered else {
      AppLogger.coach.error("Review validation failed because bounds are unordered")
      return nil
    }
    let recentVisibilityValid = !expectedReviewTruncated
      || review.areas.allSatisfy { $0.recentVisibility != .notVisible }
    let upcomingVisibilityValid = !expectedAvailabilityTruncated
      || review.areas.allSatisfy { $0.upcomingVisibility != .notVisible }
    guard recentVisibilityValid, upcomingVisibilityValid else {
      AppLogger.coach.error(
        "Review truncation visibility mismatch; recent_valid=\(recentVisibilityValid, privacy: .public) upcoming_valid=\(upcomingVisibilityValid, privacy: .public)"
      )
      return nil
    }
    let tolerance: TimeInterval = 2
    guard abs(review.recentStartAt.timeIntervalSince(expectedStart))
            <= tolerance,
          abs(review.periodEndAt.timeIntervalSince(expectedPeriodEnd))
            <= tolerance,
          abs(review.currentTime.timeIntervalSince(expectedCurrent))
            <= tolerance,
          abs(review.upcomingEndAt.timeIntervalSince(expectedPlanningEnd))
            <= tolerance,
          abs(review.trackingStartedAt.timeIntervalSince(
            expectedTrackingStart
          ))
            <= tolerance else {
      AppLogger.coach.error(
        "Review validation failed because response timestamps do not match the request"
      )
      return nil
    }

    if !review.suggestedEvents.isEmpty,
       review.suggestedEvents.count
        != FocusReviewSuggestionContract.requiredCount {
      AppLogger.scheduling.error(
        "Review suggestion count failed the all-or-zero contract; count=\(review.suggestedEvents.count, privacy: .public)"
      )
      return withholdingSuggestions(
        from: review,
        warning: "Calendar suggestions were withheld because the coach must "
          + "provide exactly seven safe suggestions or none."
      )
    }
    if review.contextTruncated, !review.suggestedEvents.isEmpty {
      AppLogger.scheduling.error(
        "Review suggestions were returned with incomplete calendar context"
      )
      return withholdingSuggestions(
        from: review,
        warning: "The seven calendar suggestions were withheld because the "
          + "calendar context was incomplete."
      )
    }

    let constraints = LocalScheduleConstraints(
      now: expectedCurrent,
      planningStart: expectedPlanningStart,
      planningEnd: expectedPlanningEnd,
      dayStartMinutes: settings.dayStartHour * 60,
      morningEndMinutes: settings.morningEndMinutes,
      eveningStartMinutes: settings.eveningStartMinutes,
      dayEndMinutes: settings.dayEndHour * 60,
      maxBlockMinutes: 240,
      maxDailyBlocks: settings.maxDailyBlocks,
      minimumBreakMinutes: settings.minimumBreakMinutes,
      selectedFocusAreas: expectedFocusAreas,
      calendar: Calendar.current
    )
    var busyIntervals = availabilityEvents
    var suggestionCounts: [Date: Int] = [:]
    var existingAgentCounts: [Date: Int] = [:]
    for event in availabilityEvents where event.focusArea != nil {
      let localDay = constraints.calendar.startOfDay(for: event.startAt)
      existingAgentCounts[localDay, default: 0] += 1
    }
    for (index, suggestion) in review.suggestedEvents.enumerated() {
      guard suggestion.action == .requiresExplicitScheduling else {
        AppLogger.scheduling.error(
          "Review suggestion action contract failed; position=\(index + 1, privacy: .public)"
        )
        return withholdingSuggestions(
          from: review,
          warning: "The seven calendar suggestions were withheld because one "
            + "or more did not require explicit confirmation."
        )
      }
      let proposal = CalendarProposal(
        proposalId: UUID(),
        title: suggestion.title,
        startAt: suggestion.suggestedStartAt,
        endAt: suggestion.suggestedEndAt,
        focusArea: suggestion.focusArea,
        rationale: suggestion.rationale,
        notes: "",
        reminderMinutes: 0
      )
      do {
        try ScheduleValidator.validate(
          proposal,
          busyIntervals: busyIntervals,
          constraints: constraints,
          mode: .reviewSuggestion
        )
      } catch {
        let nsError = error as NSError
        AppLogger.scheduling.error(
          "Review suggestion local validation failed; position=\(index + 1, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
        )
        return withholdingSuggestions(
          from: review,
          warning: "The seven calendar suggestions were withheld. "
            + error.localizedDescription
        )
      }
      let localDay = constraints.calendar.startOfDay(
        for: suggestion.suggestedStartAt
      )
      let nextCount = suggestionCounts[localDay, default: 0] + 1
      guard nextCount + existingAgentCounts[localDay, default: 0]
              <= constraints.maxDailyBlocks else {
        AppLogger.scheduling.error(
          "Review suggestion exceeds the daily block limit; position=\(index + 1, privacy: .public) limit=\(constraints.maxDailyBlocks, privacy: .public)"
        )
        return withholdingSuggestions(
          from: review,
          warning: "The seven calendar suggestions were withheld because they "
            + "would exceed your daily block limit."
        )
      }
      suggestionCounts[localDay] = nextCount
      busyIntervals.append(
        CalendarEventSnapshot(
          eventId: "review-suggestion-\(busyIntervals.count)",
          calendarId: "review-suggestion",
          startAt: suggestion.suggestedStartAt,
          endAt: suggestion.suggestedEndAt,
          isAllDay: false,
          title: nil,
          focusArea: suggestion.focusArea,
          completionStatus: nil
        )
      )
    }
    AppLogger.coach.info(
      "Review validation succeeded; period=\(review.period.rawValue, privacy: .public) suggestions=\(review.suggestedEvents.count, privacy: .public)"
    )
    return (review, nil)
  }

  private func withholdingSuggestions(
    from review: FocusReviewResult,
    warning: String
  ) -> (review: FocusReviewResult, suggestionWarning: String?) {
    AppLogger.scheduling.info(
      "Review analysis accepted with its suggestion batch withheld"
    )
    return (
      FocusReviewResult(
        areas: review.areas,
        nextAdjustment: review.nextAdjustment,
        suggestedEvents: [],
        period: review.period,
        recentStartAt: review.recentStartAt,
        periodEndAt: review.periodEndAt,
        currentTime: review.currentTime,
        upcomingEndAt: review.upcomingEndAt,
        trackingStartedAt: review.trackingStartedAt,
        historyCoverage: review.historyCoverage,
        completionEvidence: review.completionEvidence,
        contextTruncated: review.contextTruncated
      ),
      warning
    )
  }

  private func applyValidatedProposal(
    _ proposal: CalendarProposal,
    modelContext: ModelContext,
    settings: AppSettings,
    calendarService: any CalendarStore,
    validationMode: ScheduleValidationMode,
    automaticCalendarIdentifier: String? = nil
  ) throws {
    let constraints = scheduleConstraints(settings: settings)
    let validationModeLabel = validationMode == .reviewSuggestion
      ? "review_suggestion" : "standard"
    AppLogger.scheduling.debug(
      "Starting local proposal validation and application; mode=\(validationModeLabel, privacy: .public) automatic=\(automaticCalendarIdentifier != nil, privacy: .public)"
    )
    let applied: AppliedCalendarEvent
    do {
      if let automaticCalendarIdentifier {
        applied = try calendarService.applyAutomatically(
          proposal: proposal,
          authorizedCalendarIdentifier: automaticCalendarIdentifier,
          constraints: constraints,
          validationMode: validationMode
        )
      } else {
        applied = try calendarService.apply(
          proposal: proposal,
          constraints: constraints,
          validationMode: validationMode
        )
      }
    } catch {
      let nsError = error as NSError
      AppLogger.scheduling.error(
        "Proposal validation or Apple Calendar application failed; mode=\(validationModeLabel, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw error
    }
    AppLogger.calendar.info("Proposal applied to Apple Calendar on device")
    modelContext.insert(CalendarAuditRecord(appliedEvent: applied))
    AppLogger.persistence.debug(
      "Persisting calendar audit and removing the pending proposal"
    )
    do {
      try deletePendingProposal(
        proposal.id,
        modelContext: modelContext
      )
      try modelContext.save()
      AppLogger.persistence.info(
        "Calendar audit persisted and pending proposal removed"
      )
    } catch {
      let persistenceError = error as NSError
      AppLogger.persistence.error(
        "Calendar audit persistence failed; domain=\(persistenceError.domain, privacy: .private) code=\(persistenceError.code, privacy: .public)"
      )
      modelContext.rollback()
      do {
        try calendarService.undoAgentEvent(
          identifier: applied.eventIdentifier
        )
        AppLogger.calendar.info(
          "Apple Calendar write rolled back after audit persistence failure"
        )
      } catch {
        let rollbackError = error as NSError
        AppLogger.calendar.error(
          "Apple Calendar rollback failed after audit persistence failure; domain=\(rollbackError.domain, privacy: .private) code=\(rollbackError.code, privacy: .public)"
        )
        discardUntrackedPendingProposal(
          proposal.id,
          modelContext: modelContext
        )
        throw AppError.calendarWriteUntracked
      }
      throw AppError.calendarWriteRolledBack
    }
    pendingProposals.removeAll { $0.id == proposal.id }
    AppLogger.scheduling.info(
      "Proposal application completed; pending_remaining=\(self.pendingProposals.count, privacy: .public)"
    )
  }

  private func automaticScheduleSummary(
    appliedCount: Int,
    remainingCount: Int,
    calendarTitle: String
  ) -> String {
    if remainingCount == 0 {
      let noun = appliedCount == 1 ? "event" : "events"
      return "Added \(appliedCount) \(noun) to \(calendarTitle) in Apple Calendar."
    }
    let appliedNoun = appliedCount == 1 ? "event" : "events"
    let draftNoun = remainingCount == 1 ? "draft" : "drafts"
    return "Added \(appliedCount) \(appliedNoun); \(remainingCount) \(draftNoun) still need review."
  }

  private func appendWarning(_ value: String) {
    if !warnings.contains(value) {
      warnings.append(value)
    }
  }

  private func replacePendingProposals(
    _ proposals: [CalendarProposal],
    modelContext: ModelContext
  ) throws {
    AppLogger.persistence.debug(
      "Replacing pending proposal records; incoming=\(proposals.count, privacy: .public)"
    )
    let records: [PendingCalendarProposalRecord]
    do {
      records = try modelContext.fetch(
        FetchDescriptor<PendingCalendarProposalRecord>()
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Pending proposal fetch before replacement failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw error
    }
    for record in records {
      modelContext.delete(record)
    }
    for proposal in proposals {
      modelContext.insert(
        PendingCalendarProposalRecord(proposal: proposal)
      )
    }
    do {
      try modelContext.save()
      pendingProposals = proposals
      AppLogger.persistence.info(
        "Pending proposal replacement completed; removed=\(records.count, privacy: .public) stored=\(proposals.count, privacy: .public)"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Pending proposal replacement save failed; incoming=\(proposals.count, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      modelContext.rollback()
      throw error
    }
  }

  private func deletePendingProposal(
    _ proposalId: UUID,
    modelContext: ModelContext
  ) throws {
    let records: [PendingCalendarProposalRecord]
    do {
      records = try modelContext.fetch(
        FetchDescriptor<PendingCalendarProposalRecord>()
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Pending proposal fetch before deletion failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw error
    }
    var deletedCount = 0
    for record in records where record.proposalId == proposalId {
      modelContext.delete(record)
      deletedCount += 1
    }
    AppLogger.persistence.debug(
      "Pending proposal records marked for deletion; count=\(deletedCount, privacy: .public)"
    )
  }

  private func discardUntrackedPendingProposal(
    _ proposalId: UUID,
    modelContext: ModelContext
  ) {
    AppLogger.persistence.info(
      "Discarding pending proposal after an untracked calendar write"
    )
    pendingProposals.removeAll { $0.id == proposalId }
    do {
      try deletePendingProposal(
        proposalId,
        modelContext: modelContext
      )
      try modelContext.save()
      AppLogger.persistence.info(
        "Untracked pending proposal discarded from persistence"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Failed to discard untracked pending proposal; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      modelContext.rollback()
    }
  }

  private func scheduleConstraints(
    settings: AppSettings
  ) -> LocalScheduleConstraints {
    LocalScheduleConstraints(
      now: Date(),
      planningStart: lastPlanningStart,
      planningEnd: lastPlanningEnd,
      dayStartMinutes: settings.dayStartHour * 60,
      morningEndMinutes: settings.morningEndMinutes,
      eveningStartMinutes: settings.eveningStartMinutes,
      dayEndMinutes: settings.dayEndHour * 60,
      maxBlockMinutes: 240,
      maxDailyBlocks: settings.maxDailyBlocks,
      minimumBreakMinutes: settings.minimumBreakMinutes,
      selectedFocusAreas: settings.selectedFocusAreas,
      calendar: Calendar.current
    )
  }
}
