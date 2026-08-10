import SwiftData
import SwiftUI

enum CompletionHistoryWindow {
  static func bounds(
    at date: Date,
    calendar: Calendar
  ) -> DateInterval {
    let today = calendar.startOfDay(for: date)
    let start = calendar.date(byAdding: .day, value: -6, to: today)
      ?? today.addingTimeInterval(-6 * 86_400)
    let end = calendar.date(byAdding: .day, value: 1, to: today)
      ?? today.addingTimeInterval(86_400)
    return DateInterval(start: start, end: end)
  }
}

struct ProgressViewScreen: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var calendarService: CalendarService
  @EnvironmentObject private var settings: AppSettings
  @Query(sort: \CheckInRecord.createdAt, order: .reverse)
  private var checkIns: [CheckInRecord]
  @Query(sort: \CalendarEventCompletionRecord.updatedAt, order: .reverse)
  private var completions: [CalendarEventCompletionRecord]
  @Query(sort: \IncompleteEventRescheduleRecord.createdAt, order: .reverse)
  private var reschedules: [IncompleteEventRescheduleRecord]
  @State private var liveEvents: [CalendarDisplayEvent] = []
  @State private var errorMessage: String?

  private var completionByKey: [String: CalendarEventCompletionStatus] {
    completions.reduce(into: [:]) { result, completion in
      if result[completion.completionKey] == nil {
        result[completion.completionKey] = completion.status
      }
    }
  }

  private var ratedVisibleEvents: [CalendarDisplayEvent] {
    liveEvents.filter { completionByKey[$0.completionKey] != nil }
  }

  private var completedCount: Int {
    ratedVisibleEvents.filter {
      completionByKey[$0.completionKey] == .complete
    }.count
  }

  private var completionRate: Int {
    guard !ratedVisibleEvents.isEmpty else { return 0 }
    return Int(
      (Double(completedCount) / Double(ratedVisibleEvents.count) * 100)
        .rounded()
    )
  }

  private var dailyCheckIns: [CheckInRecord] {
    let calendar = Calendar.current
    var seenDays: Set<Date> = []
    return checkIns.filter { record in
      let day = calendar.startOfDay(for: record.createdAt)
      return seenDays.insert(day).inserted
    }
  }

  private var groupedEvents: [(day: Date, events: [CalendarDisplayEvent])] {
    let calendar = Calendar.current
    let groups = Dictionary(grouping: liveEvents) {
      calendar.startOfDay(for: $0.startAt)
    }
    return groups
      .map { (day: $0.key, events: $0.value.sorted { $0.startAt < $1.startAt }) }
      .sorted { $0.day > $1.day }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          metric(
            title: "Current streak",
            value: "\(currentStreak())",
            suffix: "days"
          )
          metric(
            title: "Events complete",
            value: "\(completionRate)",
            suffix: "%"
          )
        }

        calendarProgress
        recentCheckIns
      }
      .padding(16)
    }
    .background(Color.CalendarAgent.background)
    .navigationTitle("Progress")
    .task { refreshLiveEvents() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        refreshLiveEvents()
      }
    }
    .refreshable { refreshLiveEvents() }
    .alert(
      "Progress",
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

  private var calendarProgress: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Apple Calendar follow-through", systemImage: "calendar")
            .font(.headline)
          Spacer()
          Button {
            refreshLiveEvents()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Refresh Apple Calendar")
        }
        Text(
          "Showing today and the previous six days. Titles and times are read fresh from Apple Calendar; your Complete/Incomplete input stays only in this app."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if liveEvents.isEmpty {
          Text("No non-holiday calendar events are visible in the last 7 days.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          ForEach(groupedEvents, id: \.day) { group in
            Divider()
            Text(
              group.day.formatted(
                .dateTime.weekday(.wide).month().day()
              )
            )
            .font(.subheadline.weight(.bold))
            ForEach(group.events) { event in
              EventCompletionRow(
                event: event,
                status: completionByKey[event.completionKey],
                existingRescheduleStartAt: existingRescheduleStartAt(
                  for: event
                ),
                onAddIncomplete: {
                  await addIncomplete(event)
                }
              ) { status in
                mark(event, status: status)
              }
            }
          }
        }
      }
    }
  }

  private var recentCheckIns: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 12) {
        Label("Recent reflections", systemImage: "checklist")
          .font(.headline)
        if dailyCheckIns.isEmpty {
          Text("Your reflections will appear after the first daily check-in.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          ForEach(dailyCheckIns.prefix(7)) { record in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(
                  record.createdAt.formatted(
                    .dateTime.weekday(.abbreviated).month().day()
                  )
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                Label(
                  record.commitmentCompleted ? "Kept" : "Missed",
                  systemImage: record.commitmentCompleted
                    ? "checkmark.circle.fill"
                    : "arrow.counterclockwise.circle"
                )
                .font(.caption)
                .foregroundStyle(
                  record.commitmentCompleted
                    ? Color.CalendarAgent.success
                    : Color.CalendarAgent.warning
                )
              }
              Text(
                "Energy \(record.energy)/5 · Focus \(record.focusLevel)/5"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              if !record.reflection.isEmpty {
                Text(record.reflection)
                  .font(.subheadline)
              }
            }
          }
        }
      }
    }
  }

  private func metric(
    title: String,
    value: String,
    suffix: String
  ) -> some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(value)
            .font(.title.bold())
          Text(suffix)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func refreshLiveEvents() {
    AppLogger.calendar.debug(
      "Progress seven-day live calendar refresh started"
    )
    let calendar = Calendar.current
    let window = CompletionHistoryWindow.bounds(
      at: Date(),
      calendar: calendar
    )
    do {
      try calendarService.refreshFromSystem()
      guard calendarService.accessState.canRead else {
        liveEvents = []
        errorMessage = nil
        AppLogger.calendar.info(
          "Progress calendar refresh completed without read access; visible_count=0"
        )
        return
      }
      liveEvents = try calendarService.events(
        from: window.start,
        to: window.end
      )
      errorMessage = nil
      AppLogger.calendar.info(
        "Progress seven-day calendar refresh succeeded; visible_count=\(liveEvents.count, privacy: .public)"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.calendar.error(
        "Progress seven-day calendar refresh failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
    }
  }

  private func mark(
    _ event: CalendarDisplayEvent,
    status: CalendarEventCompletionStatus
  ) -> Bool {
    AppLogger.completion.debug(
      "Progress event status selection started; status=\(status.rawValue, privacy: .public) key=\(event.completionKey, privacy: .private(mask: .hash))"
    )
    do {
      try CalendarEventCompletionStore.upsert(
        completionKey: event.completionKey,
        status: status,
        modelContext: modelContext
      )
      AppLogger.completion.info(
        "Progress event status selection succeeded; status=\(status.rawValue, privacy: .public) key=\(event.completionKey, privacy: .private(mask: .hash))"
      )
      return true
    } catch {
      let nsError = error as NSError
      AppLogger.completion.error(
        "Progress event status selection failed; key=\(event.completionKey, privacy: .private(mask: .hash)) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
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
      "Progress incomplete-event Add tapped; key=\(event.completionKey, privacy: .private(mask: .hash))"
    )
    do {
      let outcome = try IncompleteEventRescheduleCoordinator.schedule(
        event: event,
        settings: settings,
        calendarService: calendarService,
        modelContext: modelContext
      )
      refreshLiveEvents()
      AppLogger.scheduling.info(
        "Progress incomplete-event Add succeeded; destination=\(outcome.destinationTitle, privacy: .public)"
      )
      return outcome
    } catch {
      let nsError = error as NSError
      AppLogger.scheduling.error(
        "Progress incomplete-event Add failed; key=\(event.completionKey, privacy: .private(mask: .hash)) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func currentStreak() -> Int {
    let calendar = Calendar.current
    let completedDays = Set(
      dailyCheckIns
        .filter(\.commitmentCompleted)
        .map { calendar.startOfDay(for: $0.createdAt) }
    )
    var cursor = calendar.startOfDay(for: Date())
    if !completedDays.contains(cursor) {
      cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
    }
    var result = 0
    while completedDays.contains(cursor) {
      result += 1
      guard let previous = calendar.date(
        byAdding: .day,
        value: -1,
        to: cursor
      ) else { break }
      cursor = previous
    }
    return result
  }
}
