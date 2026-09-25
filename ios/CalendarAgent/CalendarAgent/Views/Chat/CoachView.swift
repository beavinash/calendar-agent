import Combine
import Foundation
import SwiftData
import SwiftUI

enum CoachHeaderContent {
  static let title = AppBrand.name

  static func analyzeTitle(for period: FocusReviewPeriod) -> String {
    "Analyze \(period.title)"
  }
}

enum FocusReviewCompletionDisclosure {
  static func text(
    for evidence: FocusReviewCompletionEvidence
  ) -> String {
    switch evidence {
    case .notProvided:
      "Eligible ended unmarked events since tracking began count as 70% "
        + "likely incomplete for this coaching estimate."
    case .userInput:
      "Saved Complete/Incomplete choices stay explicit; eligible ended "
        + "unmarked events since tracking began count as 70% likely incomplete."
    }
  }
}

private enum MissedEventInsightLoadState {
  case loading
  case available
  case calendarUnavailable
  case failed
}

private struct MissedEventInsightPresentation: Identifiable {
  let id = UUID()
  let insight: MissedEventInsight
}

struct CoachView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var calendarService: CalendarService
  @EnvironmentObject private var coachSession: CoachSessionController
  @Query(sort: \ChatMessageRecord.createdAt) private var messages: [ChatMessageRecord]
  @Query(sort: \CalendarEventCompletionRecord.updatedAt, order: .reverse)
  private var completions: [CalendarEventCompletionRecord]
  @Query(sort: \ClearedAnalysisIntervalRecord.startAt)
  private var clearedAnalysisIntervals: [ClearedAnalysisIntervalRecord]
  @StateObject private var viewModel = CoachViewModel()
  @State private var input = ""
  @State private var selectedReviewPeriod: FocusReviewPeriod = .day
  @State private var isFollowingGeneratedContent = false
  @State private var missedInsightEvents: [CalendarDisplayEvent] = []
  @State private var missedInsightLoadState: MissedEventInsightLoadState =
    .loading
  @State private var presentedMissedInsight: MissedEventInsightPresentation?
  @State private var clearConfirmation = ClearHistoryConfirmationState()
  @State private var clearHistoryFeedback: ClearHistoryFeedback?
  @FocusState private var inputFocused: Bool

  private var visibleMessages: [ChatMessageRecord] {
    messages.filter { $0.sessionId == coachSession.activeSessionId }
  }

  var body: some View {
    VStack(spacing: 0) {
      reviewControls

      if !calendarService.accessState.canRead {
        calendarBanner
      }

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 12) {
            Group {
              if calendarService.accessState.canRead {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                  missedEventInsightCard(at: context.date)
                    .padding(.horizontal)
                }
              } else {
                Color.clear.frame(height: 0)
              }
            }
            .id(CoachScrollTarget.top)
            .accessibilityIdentifier("coach-missed-event-insight")

            Group {
              if selectedReviewPeriod == .day {
                TodayDashboard(
                  showsHero: false,
                  showsCalendarConnectionPrompt: false
                )
                .padding(.horizontal)
              } else {
                reviewPeriodIntroduction
                  .padding(.horizontal)
              }
            }
            .accessibilityIdentifier("coach-top-content")

            if visibleMessages.isEmpty {
              welcome
            }

            ForEach(visibleMessages) { message in
              ChatBubble(message: message)
              .id(message.id)
            }

            if viewModel.isLoading {
              HStack(spacing: 8) {
                ProgressView()
                Text("Building a realistic plan…")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                Spacer()
              }
              .padding(.horizontal)
              .id("loading")
            }

            if let message = viewModel.calendarActionMessage {
              Label(message, systemImage: "calendar.badge.checkmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.CalendarAgent.success)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            if let review = viewModel.focusReview {
              FocusReviewCard(
                review: review,
                isApplying: viewModel.isApplyingSuggestions
              ) {
                viewModel.applySuggestedEvents(
                  review.suggestedEvents,
                  modelContext: modelContext,
                  settings: settings,
                  calendarService: calendarService
                )
              }
                .padding(.horizontal)
                .id("focus-review")
            }

            if !viewModel.pendingProposals.isEmpty {
              proposalSection
                .id("proposals")
            }

            if let question = viewModel.checkInQuestion {
              SurfaceCard {
                Label(question, systemImage: "questionmark.bubble")
                  .font(.subheadline.weight(.medium))
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.horizontal)
            }

            ForEach(viewModel.warnings, id: \.self) { warning in
              Label(warning, systemImage: "exclamationmark.shield")
                .font(.footnote)
                .foregroundStyle(Color.CalendarAgent.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            Color.clear
              .frame(height: 1)
              .id(CoachScrollTarget.bottom)
          }
          .padding(.vertical, 12)
        }
        .accessibilityIdentifier("coach-scroll-region")
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: visibleMessages.count) { previous, current in
          scroll(
            proxy,
            for: .messageCountChanged(
              previous: previous,
              current: current
            )
          )
        }
        .onChange(of: viewModel.pendingProposals.count) { previous, current in
          scroll(
            proxy,
            for: .proposalCountChanged(
              previous: previous,
              current: current
            )
          )
        }
        .onChange(of: viewModel.focusReview) { _, review in
          guard review != nil else { return }
          scroll(proxy, for: .reviewBecameAvailable)
        }
        .onChange(of: viewModel.isLoading) { _, isLoading in
          scroll(
            proxy,
            for: isLoading ? .loadingStarted : .loadingFinished
          )
        }
        .onChange(of: viewModel.warnings.count) { previous, current in
          scroll(
            proxy,
            for: .warningCountChanged(
              previous: previous,
              current: current
            )
          )
        }
        .onChange(of: selectedReviewPeriod) { _, _ in
          isFollowingGeneratedContent = false
          refreshMissedEventInsight()
          scroll(proxy, for: .reviewPeriodChanged, animated: false)
        }
        .onChange(of: calendarService.accessState) { _, accessState in
          if !accessState.canRead {
            presentedMissedInsight = nil
          }
          refreshMissedEventInsight()
        }
        .onChange(of: calendarService.todayEvents) { _, _ in
          guard selectedReviewPeriod == .day else { return }
          refreshMissedEventInsight()
        }
        .onReceive(
          NotificationCenter.default.publisher(
            for: .NSCalendarDayChanged
          )
        ) { _ in
          refreshForCalendarDayChange()
          scroll(proxy, for: .foregroundActivation, animated: false)
        }
        .onChange(of: coachSession.activeSessionId) { _, _ in
          isFollowingGeneratedContent = false
          scroll(proxy, for: .sessionReset, animated: false)
        }
        .onChange(of: scenePhase) { _, phase in
          guard phase == .active else { return }
          isFollowingGeneratedContent = false
          refreshMissedEventInsight()
          scroll(proxy, for: .foregroundActivation, animated: false)
        }
        .task {
          isFollowingGeneratedContent = false
          refreshMissedEventInsight()
          await Task.yield()
          scroll(proxy, for: .initialAppearance, animated: false)
        }
      }

      Divider()
      ChatComposer(
        text: $input,
        isLoading: viewModel.isLoading,
        focused: $inputFocused
      ) {
        send()
      }
    }
    .background(Color.CalendarAgent.background)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: coachSession.activeSessionId) { _, _ in
      input = ""
      isFollowingGeneratedContent = false
      viewModel.resetVisibleSessionState()
    }
    .sheet(isPresented: $viewModel.showingConsent) {
      AIConsentView {
        settings.aiDataConsent = true
        viewModel.showingConsent = false
      }
    }
    .sheet(item: $presentedMissedInsight) { presentation in
      MissedEventInsightDetailsView(insight: presentation.insight)
    }
    .confirmationDialog(
      clearConfirmation.pendingScope.map(
        ClearHistoryPresentation.confirmationTitle(for:)
      ) ?? "Clear local coaching history?",
      isPresented: Binding(
        get: { clearConfirmation.isPresented },
        set: { isPresented in
          if !isPresented {
            clearConfirmation.cancel()
          }
        }
      ),
      titleVisibility: .visible
    ) {
      if let scope = clearConfirmation.pendingScope {
        Button(
          ClearHistoryPresentation.confirmationButtonTitle(for: scope),
          role: .destructive
        ) {
          confirmPendingClear()
        }
        .accessibilityIdentifier("coach-clear-confirm-button")
      }
      Button("Cancel", role: .cancel) {
        clearConfirmation.cancel()
      }
      .accessibilityIdentifier("coach-clear-cancel-button")
    } message: {
      if let scope = clearConfirmation.pendingScope {
        Text(ClearHistoryPresentation.confirmationMessage(for: scope))
      }
    }
    .alert(
      clearHistoryFeedback?.title ?? AppBrand.name,
      isPresented: Binding(
        get: { clearHistoryFeedback != nil },
        set: { isPresented in
          if !isPresented {
            clearHistoryFeedback = nil
          }
        }
      ),
      presenting: clearHistoryFeedback
    ) { _ in
      Button("OK") {
        clearHistoryFeedback = nil
      }
      .accessibilityIdentifier("coach-clear-feedback-ok")
    } message: { feedback in
      Text(feedback.message)
    }
    .alert(item: $viewModel.presentedError) { error in
      Alert(
        title: Text(AppBrand.name),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
  }

  private var welcome: some View {
    VStack(spacing: 16) {
      Image(systemName: "scope")
        .font(.system(size: 46, weight: .medium))
        .foregroundStyle(Color.CalendarAgent.accent)
      Text("Choose the next honest action")
        .font(.title3.weight(.semibold))
      Text(
        "Review your Apple Calendar against your calendar categories, plan the next blocks, or talk through what is getting in the way."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 24)
      HStack {
        quickPrompt("Plan tomorrow", message: "Plan tomorrow")
      }
    }
    .padding(.vertical, 36)
  }

  private func quickPrompt(_ title: String, message: String) -> some View {
    Button(title) {
      input = message
      send()
    }
    .buttonStyle(.bordered)
  }

  private var calendarBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "calendar.badge.exclamationmark")
      Text("Calendar is disconnected. Chat works, but calendar review and scheduling need access.")
        .font(.caption)
      Spacer()
      Button("Connect") {
        Task {
          do {
            try await calendarService.requestFullAccess()
          } catch {
            viewModel.errorMessage = error.localizedDescription
          }
        }
      }
      .font(.caption.weight(.semibold))
    }
    .padding(10)
    .background(Color.CalendarAgent.warning.opacity(0.12))
  }

  private var reviewControls: some View {
    VStack(spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        Text(CoachHeaderContent.title)
          .font(.title2.bold())
        Spacer(minLength: 4)
        Button(CoachHeaderContent.analyzeTitle(for: selectedReviewPeriod)) {
          input = "/review \(selectedReviewPeriod.rawValue)"
          send()
        }
        .font(.subheadline.weight(.semibold))
        .calendarAgentProminentActionStyle()
        .disabled(
          viewModel.isLoading || !calendarService.accessState.canRead
        )
      }
      Picker("Review period", selection: $selectedReviewPeriod) {
        ForEach(FocusReviewPeriod.allCases) { period in
          Text(period.title).tag(period)
        }
      }
      .pickerStyle(.segmented)
    }
    .padding(12)
    .background(Color.CalendarAgent.surface)
  }

  private var reviewPeriodIntroduction: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        Label(selectedReviewPeriod.title, systemImage: "calendar.badge.clock")
          .font(.headline)
        Text(
          selectedReviewPeriod == .week
            ? "Review the previous completed calendar week, then build the next seven realistic options."
            : "Review the previous completed calendar month, then build the next seven realistic options."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func missedEventInsightCard(at now: Date) -> some View {
    SurfaceCard {
      switch missedInsightLoadState {
      case .loading:
        Text("Reading the latest Apple Calendar events…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      case .calendarUnavailable:
        Text("Connect Apple Calendar to see missed-event counts.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      case .failed:
        Text("Couldn’t refresh missed-event counts.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      case .available:
        let insight = buildMissedEventInsight(at: now)
        if let emptyMessage = insight.emptyMessage {
          Text(emptyMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(4)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text(insight.heading)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.75)

            ForEach(
              Array(insight.displayedGroups.enumerated()),
              id: \.element.id
            ) { index, group in
              missedEventGroupRow(
                group,
                showsMore: index == insight.displayedGroups.indices.last
                  && insight.hasMoreGroups,
                insight: insight
              )
            }
          }
        }
      }
    }
  }

  private var completionStatusByKey:
    [String: CalendarEventCompletionStatus] {
    var result: [String: CalendarEventCompletionStatus] = [:]
    for completion in completions
      where result[completion.completionKey] == nil {
      result[completion.completionKey] = completion.status
    }
    return result
  }

  @ViewBuilder
  private func missedEventGroupRow(
    _ group: MissedEventGroup,
    showsMore: Bool,
    insight: MissedEventInsight
  ) -> some View {
    if showsMore,
       let moreTitle = insight.moreButtonTitle,
       let accessibilityLabel = insight.moreButtonAccessibilityLabel {
      Button {
        presentedMissedInsight = MissedEventInsightPresentation(
          insight: insight
        )
      } label: {
        missedEventGroupRowContent(
          group,
          moreTitle: moreTitle
        )
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
      .accessibilityLabel(
        "\(group.displayTitle), \(group.missedCountText). "
          + accessibilityLabel
      )
      .accessibilityHint(
        "Opens all missed event types and their count breakdowns"
      )
      .accessibilityIdentifier("coach-missed-event-more-button")
    } else {
      missedEventGroupRowContent(group)
    }
  }

  private func missedEventGroupRowContent(
    _ group: MissedEventGroup,
    moreTitle: String? = nil
  ) -> some View {
    HStack(spacing: 6) {
      Text(group.displayTitle)
        .font(.subheadline)
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(group.missedCountText)
        .font(.subheadline.monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
      if let moreTitle {
        Text("·")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(moreTitle)
          .font(.subheadline.monospacedDigit().weight(.semibold))
          .foregroundStyle(Color.CalendarAgent.accent)
          .underline()
          .lineLimit(1)
          .fixedSize()
          .layoutPriority(1)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.CalendarAgent.accent)
      }
    }
  }

  private func buildMissedEventInsight(
    at now: Date
  ) -> MissedEventInsight {
    MissedEventInsightBuilder.build(
      events: missedInsightEvents,
      completionStatuses: completionStatusByKey,
      period: selectedReviewPeriod,
      now: now,
      trackingStartedAt: settings.trackingStartedAt,
      calendar: .current,
      clearedIntervals: clearedAnalysisIntervals.map(\.interval)
    )
  }

  private func refreshMissedEventInsight() {
    guard calendarService.accessState.canRead else {
      missedInsightEvents = []
      missedInsightLoadState = .calendarUnavailable
      AppLogger.calendar.debug(
        "Coach missed-event insight refresh skipped; calendar_read=false"
      )
      return
    }

    let now = Date()
    let calendar = Calendar.current
    let fetchBounds = MissedEventInsightQuery.fetchBounds(
      for: selectedReviewPeriod,
      at: now,
      calendar: calendar
    )

    missedInsightLoadState = .loading
    AppLogger.calendar.debug(
      "Coach missed-event insight refresh started; period=\(selectedReviewPeriod.rawValue, privacy: .public)"
    )
    do {
      missedInsightEvents = try calendarService.events(
        from: fetchBounds.start,
        to: fetchBounds.end
      )
      missedInsightLoadState = .available
      AppLogger.calendar.info(
        "Coach missed-event insight refresh succeeded; period=\(selectedReviewPeriod.rawValue, privacy: .public) visible_count=\(missedInsightEvents.count, privacy: .public)"
      )
    } catch {
      missedInsightEvents = []
      missedInsightLoadState = .failed
      let nsError = error as NSError
      AppLogger.calendar.error(
        "Coach missed-event insight refresh failed; period=\(selectedReviewPeriod.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
    }
  }

  private func refreshForCalendarDayChange() {
    AppLogger.calendar.debug("Coach local calendar-day refresh started")
    do {
      try calendarService.refreshToday()
      AppLogger.calendar.info(
        "Coach local calendar-day refresh succeeded; today_events=\(calendarService.todayEvents.count, privacy: .public)"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.calendar.error(
        "Coach local calendar-day refresh failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
    }
    refreshMissedEventInsight()
  }

  private var proposalSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(
          settings.autoScheduleEnabled
            ? "Calendar drafts needing review"
            : "Calendar drafts",
          systemImage: "calendar.badge.plus"
        )
          .font(.headline)
        Spacer()
        Button("Dismiss") {
          viewModel.clearProposals(modelContext: modelContext)
        }
        .font(.caption)
      }
      .padding(.horizontal)

      ForEach(viewModel.pendingProposals) { proposal in
        ProposalCard(
          proposal: proposal,
          calendarLabel: selectedCalendarLabel
        ) {
          viewModel.apply(
            proposal,
            modelContext: modelContext,
            settings: settings,
            calendarService: calendarService
          )
        }
      }
    }
  }

  private var selectedCalendarLabel: String {
    guard let calendar = calendarService.defaultWritableCalendar else {
      return "No writable default Apple Calendar"
    }
    return "\(calendar.title) — \(calendar.accountTitle)"
  }

  private func send() {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    CoachSubmissionHandler.handle(
      value,
      requestLocalClear: { scope in
        input = ""
        inputFocused = false
        clearConfirmation.request(scope)
      },
      rejectInvalidCommand: {
        input = ""
        inputFocused = false
        clearHistoryFeedback = .invalidCommand
      },
      sendProviderMessage: {
        sendProviderMessage(value)
      }
    )
  }

  private func sendProviderMessage(_ value: String) {
    guard settings.aiDataConsent else {
      viewModel.showingConsent = true
      return
    }
    isFollowingGeneratedContent = true
    input = ""
    inputFocused = false
    Task {
      await viewModel.send(
        message: value,
        history: visibleMessages,
        notes: [],
        completions: completions,
        clearedIntervals: clearedAnalysisIntervals.map(\.interval),
        sessionId: coachSession.activeSessionId,
        modelContext: modelContext,
        settings: settings,
        calendarService: calendarService
      )
    }
  }

  private func confirmPendingClear() {
    guard let scope = clearConfirmation.consumeConfirmedScope() else {
      return
    }
    confirmClear(scope)
  }

  private func confirmClear(_ scope: ClearHistoryScope) {
    let timestamp = Date()
    let calendar = Calendar.current

    do {
      try LocalCoachingHistoryResetCoordinator.reset(
        scope: scope,
        at: timestamp,
        calendar: calendar,
        modelContext: modelContext,
        settings: settings,
        calendarStore: calendarService
      )
      viewModel.resetAfterHistoryClear()
      presentedMissedInsight = nil
      isFollowingGeneratedContent = false
      coachSession.startFreshSession()
      refreshMissedEventInsight()
      clearHistoryFeedback = .success(scope)
    } catch {
      clearHistoryFeedback = .failure(scope)
    }
  }

  private func scroll(
    _ proxy: ScrollViewProxy,
    for trigger: CoachScrollTrigger,
    animated: Bool = true
  ) {
    guard let target = CoachScrollPolicy.target(
      for: trigger,
      isFollowingGeneratedContent: isFollowingGeneratedContent
    ) else {
      return
    }
    let anchor: UnitPoint = target == .top ? .top : .bottom
    AppLogger.coach.debug(
      "Coach scroll requested; target=\(target == .top ? "top" : "bottom", privacy: .public)"
    )
    if animated {
      withAnimation {
        proxy.scrollTo(target, anchor: anchor)
      }
    } else {
      proxy.scrollTo(target, anchor: anchor)
    }
  }

}

private struct FocusReviewCard: View {
  let review: FocusReviewResult
  let isApplying: Bool
  let onScheduleSuggestions: () -> Void

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Label("\(review.period.title) Review", systemImage: "scope")
              .font(.headline)
            Text(review.historyCoverage.label)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(review.historyCoverage.color)
          }
          Spacer()
          Text(review.contextTruncated ? "Incomplete" : "Calendar evidence")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12))
            .clipShape(Capsule())
        }

        Text(
          "Evidence "
            + review.recentStartAt.formatted(date: .abbreviated, time: .omitted)
            + "–"
            + review.periodEndAt.formatted(date: .abbreviated, time: .omitted)
            + " · Options through "
            + review.upcomingEndAt.formatted(date: .abbreviated, time: .omitted)
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Text(
          FocusReviewCompletionDisclosure.text(
            for: review.completionEvidence
          )
        )
        .font(.footnote)
        .foregroundStyle(.secondary)

        ForEach(review.areas) { area in
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Label(area.focusArea.title, systemImage: area.focusArea.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(area.focusArea.color)
              Spacer()
              Text("\(area.confidence.label) confidence")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
              visibilityPill("Period", area.recentVisibility)
              visibilityPill("Upcoming", area.upcomingVisibility)
            }

            Text(area.scheduledEvidence)
              .font(.footnote)
            Label(area.likelyImpact, systemImage: "arrow.triangle.branch")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Divider()
        Label(review.nextAdjustment, systemImage: "smallcircle.filled.circle")
          .font(.subheadline.weight(.medium))

        if !review.suggestedEvents.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Label("Suggested events", systemImage: "calendar.badge.plus")
              .font(.headline)
            Text(
              "These are suggestions only. This review has not added anything to Apple Calendar."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(review.suggestedEvents) { suggestion in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(suggestion.title)
                    .font(.subheadline.weight(.semibold))
                  Spacer()
                  Text(suggestion.confidence.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Text(
                  suggestion.suggestedStartAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                  )
                    + " – "
                    + suggestion.suggestedEndAt.formatted(
                      date: .omitted,
                      time: .shortened
                    )
                )
                .font(.caption.monospacedDigit())
                Text(suggestion.rationale)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Button(isApplying ? "Adding…" : "Add 7 to Apple Calendar") {
              onScheduleSuggestions()
            }
            .calendarAgentProminentActionStyle()
            .disabled(
              isApplying
                || review.suggestedEvents.count
                  != FocusReviewSuggestionContract.requiredCount
            )
          }
        }
      }
    }
  }

  private func visibilityPill(
    _ period: String,
    _ visibility: ScheduleVisibility
  ) -> some View {
    HStack(spacing: 4) {
      Image(systemName: visibility.icon)
      Text("\(period): \(visibility.label)")
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(visibility.color)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(visibility.color.opacity(0.1))
    .clipShape(Capsule())
  }
}

private extension ScheduleVisibility {
  var label: String {
    switch self {
    case .visible: "Visible"
    case .notVisible: "Not visible"
    case .unclear: "Unclear"
    }
  }

  var icon: String {
    switch self {
    case .visible: "checkmark.circle.fill"
    case .notVisible: "minus.circle"
    case .unclear: "questionmark.circle"
    }
  }

  var color: Color {
    switch self {
    case .visible: Color.CalendarAgent.success
    case .notVisible: Color.CalendarAgent.warning
    case .unclear: .secondary
    }
  }
}

private extension EvidenceConfidence {
  var label: String {
    rawValue.capitalized
  }
}

private extension FocusReviewHistoryCoverage {
  var label: String {
    switch self {
    case .full:
      "Full tracked period"
    case .partial:
      "Partial history since first use"
    case .beforeTracking:
      "Before tracking started"
    }
  }

  var color: Color {
    switch self {
    case .full:
      Color.CalendarAgent.success
    case .partial, .beforeTracking:
      Color.CalendarAgent.warning
    }
  }
}

private struct ChatBubble: View {
  let message: ChatMessageRecord

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 44) }
      Text(message.content)
        .font(.body)
        .textSelection(.enabled)
        .padding(12)
        .foregroundStyle(
          message.role == .user
            ? Color.CalendarAgent.onAccentFill
            : Color.CalendarAgent.ink
        )
        .background(
          message.role == .user
            ? Color.CalendarAgent.accentFill
            : Color.CalendarAgent.surface
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      if message.role == .assistant { Spacer(minLength: 44) }
    }
    .padding(.horizontal)
  }
}

private struct ProposalCard: View {
  let proposal: CalendarProposal
  let calendarLabel: String
  let onApply: () -> Void

  var body: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          Image(systemName: proposal.focusArea.icon)
            .foregroundStyle(proposal.focusArea.color)
          VStack(alignment: .leading, spacing: 2) {
            Text(proposal.title)
              .font(.headline)
            Text(proposal.focusArea.title)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        Text(
          proposal.startAt.formatted(
            date: .abbreviated,
            time: .shortened
          )
          + " – "
          + proposal.endAt.formatted(date: .omitted, time: .shortened)
        )
        .font(.subheadline.weight(.medium))
        Label(calendarLabel, systemImage: "calendar")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(proposal.rationale)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if !proposal.notes.isEmpty {
          Label(proposal.notes, systemImage: "note.text")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Label(
          proposal.reminderMinutes > 0
            ? "Alert \(proposal.reminderMinutes) minutes before"
            : "No calendar alert",
          systemImage: "bell"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button("Add to Apple Calendar", action: onApply)
          .calendarAgentProminentActionStyle()
      }
    }
    .padding(.horizontal)
  }
}

private struct ChatComposer: View {
  @Binding var text: String
  let isLoading: Bool
  let focused: FocusState<Bool>.Binding
  let onSend: () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Ask your coach…", text: $text, axis: .vertical)
        .lineLimit(1...5)
        .focused(focused)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.CalendarAgent.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.CalendarAgent.controlOutline, lineWidth: 1)
        }
        .onSubmit(onSend)
      Button(action: onSend) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 32))
      }
      .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
      .accessibilityLabel("Send message")
    }
    .padding(12)
    .background(.ultraThinMaterial)
  }
}

private struct MissedEventInsightDetailsView: View {
  @Environment(\.dismiss) private var dismiss
  let insight: MissedEventInsight

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            insight.heading.isEmpty
              ? "Missed event details"
              : insight.heading
          )
          .font(.headline)
        }

        if insight.groups.isEmpty {
          Section {
            Text(
              insight.emptyMessage
                ?? "No missed events are available for this period."
            )
            .foregroundStyle(.secondary)
          }
        } else {
          Section("All missed event types") {
            ForEach(
              Array(insight.groups.enumerated()),
              id: \.element.id
            ) { index, group in
              VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Text(group.displayTitle)
                    .font(.body.weight(.semibold))
                  Spacer(minLength: 8)
                  Text(group.missedCountText)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                Text(group.evidenceSummary)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .padding(.vertical, 4)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                "\(group.displayTitle), \(group.missedCountText), "
                  + group.evidenceSummary
              )
              .accessibilityIdentifier(
                "coach-missed-event-detail-row-\(index)"
              )
            }
          }
        }

        Section {
          Text(
            "Completed events are excluded. Ended events without a choice "
              + "are shown as likely missed but remain unmarked."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      .scrollContentBackground(.hidden)
      .background(Color.CalendarAgent.background)
      .navigationTitle("Missed Events")
      .navigationBarTitleDisplayMode(.inline)
      .accessibilityIdentifier("coach-missed-event-details")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier(
              "coach-missed-event-details-done"
            )
        }
      }
    }
    .presentationDetents([.large])
  }
}

private struct AIConsentView: View {
  @Environment(\.dismiss) private var dismiss
  let onAccept: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Label("What leaves your device", systemImage: "hand.raised.fill")
            .font(.title2.weight(.semibold))
          Text(
            "Your message and preferences are sent to your chosen AI provider through your backend. An explicit analysis also sends event titles, times, and the ranked missed-pattern counts shown on \(AppBrand.name)."
          )
          Text(
            "Planning sends busy times without titles. Locations, attendees, calendar notes, calendar account names, iCloud credentials, and Keychain values are never included."
          )
          Text(
            "You can turn this consent off in Settings at any time. The backend stores only aggregate request metadata."
          )
          Button("I understand and consent") {
            onAccept()
            dismiss()
          }
          .calendarAgentProminentActionStyle()
          .frame(maxWidth: .infinity)
        }
        .padding(24)
      }
      .navigationTitle("AI Data Consent")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Not now") { dismiss() }
        }
      }
    }
  }
}
