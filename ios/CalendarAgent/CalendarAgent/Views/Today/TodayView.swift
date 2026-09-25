import SwiftData
import SwiftUI
import UIKit

struct TodayView: View {
  var body: some View {
    ScrollView {
      TodayDashboard()
        .padding(16)
    }
    .background(Color.CalendarAgent.background)
    .navigationTitle("Today")
  }
}

struct TodayDashboard: View {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var calendarService: CalendarService
  @EnvironmentObject private var settings: AppSettings
  @Query(sort: \CheckInRecord.createdAt, order: .reverse)
  private var checkIns: [CheckInRecord]
  @Query(sort: \CalendarEventCompletionRecord.updatedAt, order: .reverse)
  private var completions: [CalendarEventCompletionRecord]
  @Query(sort: \IncompleteEventRescheduleRecord.createdAt, order: .reverse)
  private var reschedules: [IncompleteEventRescheduleRecord]
  @State private var showingCheckIn = false
  @State private var errorMessage: String?
  let showsHero: Bool
  let showsCalendarConnectionPrompt: Bool

  init(
    showsHero: Bool = true,
    showsCalendarConnectionPrompt: Bool = true
  ) {
    self.showsHero = showsHero
    self.showsCalendarConnectionPrompt = showsCalendarConnectionPrompt
  }

  private var checkedInToday: Bool {
    checkIns.contains { Calendar.current.isDateInToday($0.createdAt) }
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 16) {
      if showsHero {
        hero
      }

      if !calendarService.accessState.canRead {
        if showsCalendarConnectionPrompt {
          connectCalendarCard
        }
      } else {
        calendarSummary
      }

      checkInCard
    }
    .sheet(isPresented: $showingCheckIn) {
      CheckInSheet { energy, focusLevel, completed, reflection in
        let record = CheckInRecord(
          energy: energy,
          focusLevel: focusLevel,
          commitmentCompleted: completed,
          reflection: reflection
        )
        modelContext.insert(record)
        do {
          try modelContext.save()
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
    .alert(
      "Calendar",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Unknown error")
    }
  }

  private var hero: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text("Today, honestly")
          .font(.title2.weight(.bold))
        Text(
          calendarService.todayEvents.isEmpty
            ? "No Apple Calendar events are scheduled today."
            : "Mark each event Complete or Incomplete so your coach can learn from what actually happened."
        )
        .foregroundStyle(.secondary)
      }
    }
  }

  private var connectCalendarCard: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        Label("Connect Apple Calendar", systemImage: "calendar")
          .font(.headline)
        Text(
          "Grant full access so the coach can read your latest events and add only the batches you confirm."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        if calendarService.accessState == .denied
          || calendarService.accessState == .restricted {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open iOS Settings", destination: url)
              .calendarAgentProminentActionStyle()
          }
        } else {
          Button("Grant Calendar access") {
            Task { await connectCalendar() }
          }
          .calendarAgentProminentActionStyle()
        }
      }
    }
  }

  private var calendarSummary: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("Today's events", systemImage: "calendar")
            .font(.headline)
          Spacer()
          Button {
            refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Refresh Apple Calendar")
        }
        if calendarService.todayEvents.isEmpty {
          Text("No events today.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          ForEach(calendarService.todayEvents) { event in
            EventCompletionRow(
              event: event,
              status: status(for: event),
              existingRescheduleStartAt: existingRescheduleStartAt(
                for: event
              ),
              onAddIncomplete: {
                await addIncomplete(event)
              }
            ) { status in
              mark(event, status: status)
            }
            if event.id != calendarService.todayEvents.last?.id {
              Divider()
            }
          }
        }
      }
    }
  }

  private var checkInCard: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        Label("Daily reflection", systemImage: "checklist")
          .font(.headline)
        Text(
          checkedInToday
            ? "Today's reflection is recorded."
            : "Record energy, focus, and the main factor that affected follow-through."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        Button(checkedInToday ? "Add another reflection" : "Check in") {
          showingCheckIn = true
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func status(
    for event: CalendarDisplayEvent
  ) -> CalendarEventCompletionStatus? {
    completions.first { $0.completionKey == event.completionKey }?.status
  }

  private func mark(
    _ event: CalendarDisplayEvent,
    status: CalendarEventCompletionStatus
  ) -> Bool {
    AppLogger.completion.debug(
      "Today event status selection started; status=\(status.rawValue, privacy: .public) key=\(event.completionKey, privacy: .private(mask: .hash))"
    )
    do {
      try CalendarEventCompletionStore.upsert(
        completionKey: event.completionKey,
        status: status,
        eventOccurrenceAt: event.startAt,
        modelContext: modelContext
      )
      AppLogger.completion.info(
        "Today event status selection succeeded; status=\(status.rawValue, privacy: .public) key=\(event.completionKey, privacy: .private(mask: .hash))"
      )
      return true
    } catch {
      let nsError = error as NSError
      AppLogger.completion.error(
        "Today event status selection failed; key=\(event.completionKey, privacy: .private(mask: .hash)) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func existingRescheduleStartAt(
    for event: CalendarDisplayEvent
  ) -> Date? {
    guard let record = reschedules.first(where: {
      $0.sourceCompletionKey == event.completionKey
    }) else {
      return nil
    }
    return calendarService.agentEventInterval(
      identifier: record.eventIdentifier
    )?.start
  }

  private func addIncomplete(
    _ event: CalendarDisplayEvent
  ) async -> IncompleteEventRescheduleOutcome? {
    AppLogger.scheduling.debug(
      "Today incomplete-event Add tapped; key=\(event.completionKey, privacy: .private(mask: .hash))"
    )
    do {
      let outcome = try IncompleteEventRescheduleCoordinator.schedule(
        event: event,
        settings: settings,
        calendarService: calendarService,
        modelContext: modelContext
      )
      try calendarService.refreshFromSystem()
      AppLogger.scheduling.info(
        "Today incomplete-event Add succeeded; destination=\(outcome.destinationTitle, privacy: .public)"
      )
      return outcome
    } catch {
      let nsError = error as NSError
      AppLogger.scheduling.error(
        "Today incomplete-event Add failed; key=\(event.completionKey, privacy: .private(mask: .hash)) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func connectCalendar() async {
    AppLogger.calendar.info("Today requested Apple Calendar connection")
    do {
      try await calendarService.requestFullAccess()
      AppLogger.calendar.info("Today Apple Calendar connection succeeded")
    } catch {
      let nsError = error as NSError
      AppLogger.calendar.error(
        "Today Apple Calendar connection failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
    }
  }

  private func refresh() {
    AppLogger.calendar.debug("Today manual Apple Calendar refresh started")
    do {
      try calendarService.refreshFromSystem()
      AppLogger.calendar.info(
        "Today manual Apple Calendar refresh succeeded; visible_count=\(calendarService.todayEvents.count, privacy: .public)"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.calendar.error(
        "Today manual Apple Calendar refresh failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
    }
  }
}

struct EventCompletionRow: View {
  let event: CalendarDisplayEvent
  let status: CalendarEventCompletionStatus?
  let existingRescheduleStartAt: Date?
  let onAddIncomplete: (() async -> IncompleteEventRescheduleOutcome?)?
  let onSelect: (CalendarEventCompletionStatus) -> Bool
  @State private var displayedStatus: CalendarEventCompletionStatus?
  @State private var scheduledStartAt: Date?
  @State private var isAddingIncomplete = false

  init(
    event: CalendarDisplayEvent,
    status: CalendarEventCompletionStatus?,
    existingRescheduleStartAt: Date? = nil,
    onAddIncomplete: (() async -> IncompleteEventRescheduleOutcome?)? = nil,
    onSelect: @escaping (CalendarEventCompletionStatus) -> Bool
  ) {
    self.event = event
    self.status = status
    self.existingRescheduleStartAt = existingRescheduleStartAt
    self.onAddIncomplete = onAddIncomplete
    self.onSelect = onSelect
    _displayedStatus = State(initialValue: status)
    _scheduledStartAt = State(initialValue: existingRescheduleStartAt)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Text(
          event.isAllDay
            ? "All day"
            : event.startAt.formatted(date: .omitted, time: .shortened)
        )
        .font(.caption.monospacedDigit())
        .frame(width: 62, alignment: .leading)
        VStack(alignment: .leading, spacing: 2) {
          Text(event.title)
            .font(.subheadline.weight(.semibold))
          Text(event.calendarTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 8) {
        statusButton(.complete, title: "Complete", icon: "checkmark.circle")
        statusButton(
          .incomplete,
          title: "Incomplete",
          icon: "xmark.circle"
        )
      }
      if let displayedStatus {
        Label(
          displayedStatus == .complete
            ? "Saved as Complete" : "Saved as Incomplete",
          systemImage: "checkmark.circle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(
          displayedStatus == .complete
            ? Color.CalendarAgent.success
            : Color.CalendarAgent.warning
        )
      }
      if displayedStatus == .incomplete,
         let onAddIncomplete {
        incompleteAddControl(onAdd: onAddIncomplete)
      }
    }
    .onChange(of: status) { _, newStatus in
      displayedStatus = newStatus
    }
    .onChange(of: existingRescheduleStartAt) { _, newStartAt in
      scheduledStartAt = newStartAt
    }
  }

  @ViewBuilder
  private func incompleteAddControl(
    onAdd: @escaping () async -> IncompleteEventRescheduleOutcome?
  ) -> some View {
    if let scheduledStartAt {
      Label(
        scheduledConfirmation(for: scheduledStartAt),
        systemImage: "calendar.badge.checkmark"
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("incomplete-event-added")
    } else if event.isAllDay {
      Label(
        "Reschedule all-day events in Apple Calendar.",
        systemImage: "calendar"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } else {
      Button {
        Task { @MainActor in
          guard !isAddingIncomplete else { return }
          isAddingIncomplete = true
          defer { isAddingIncomplete = false }
          guard let outcome = await onAdd() else { return }
          scheduledStartAt = outcome.scheduledStartAt
        }
      } label: {
        Label(
          isAddingIncomplete ? "Finding time…" : "Add",
          systemImage: "calendar.badge.plus"
        )
      }
      .font(.caption.weight(.semibold))
      .buttonStyle(.bordered)
      .disabled(isAddingIncomplete)
      .accessibilityIdentifier("add-incomplete-event")
      Text(
        "Adds it at the first conflict-free time later today; if today is full, it uses tomorrow. The original event stays unchanged."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private func scheduledConfirmation(for date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) {
      return "Added for today at \(time)."
    }
    if calendar.isDateInTomorrow(date) {
      return "Added for tomorrow at \(time)."
    }
    return "Already added for \(date.formatted(date: .abbreviated, time: .shortened))."
  }

  @ViewBuilder
  private func statusButton(
    _ value: CalendarEventCompletionStatus,
    title: String,
    icon: String
  ) -> some View {
    if displayedStatus == value {
      Button {
        select(value)
      } label: {
        Label(title, systemImage: "\(icon).fill")
      }
      .font(.caption.weight(.semibold))
      .buttonStyle(
        CalendarAgentFilledButtonStyle(
          fill: value == .complete
            ? Color.CalendarAgent.completeFill
            : Color.CalendarAgent.incompleteFill,
          foreground: value == .complete
            ? Color.CalendarAgent.onCompleteFill
            : Color.CalendarAgent.onIncompleteFill
        )
      )
      .accessibilityValue("Selected")
    } else {
      Button {
        select(value)
      } label: {
        Label(title, systemImage: icon)
      }
      .font(.caption.weight(.semibold))
      .buttonStyle(.bordered)
      .tint(
        value == .complete
          ? Color.CalendarAgent.success
          : Color.CalendarAgent.warning
      )
    }
  }

  private func select(_ value: CalendarEventCompletionStatus) {
    guard onSelect(value) else { return }
    displayedStatus = value
  }
}

private struct CheckInSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var energy = 3
  @State private var focusLevel = 3
  @State private var completed = false
  @State private var reflection = ""
  let onSave: (Int, Int, Bool, String) -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section("State") {
          Stepper("Energy: \(energy) / 5", value: $energy, in: 1...5)
          Stepper(
            "Focus: \(focusLevel) / 5",
            value: $focusLevel,
            in: 1...5
          )
          Toggle("I kept my main commitment", isOn: $completed)
        }
        Section("Reflection") {
          TextField(
            "What helped or got in the way?",
            text: $reflection,
            axis: .vertical
          )
          .lineLimit(3...8)
        }
      }
      .navigationTitle("Daily Check-in")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(
              energy,
              focusLevel,
              completed,
              reflection.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
          }
        }
      }
    }
  }
}
