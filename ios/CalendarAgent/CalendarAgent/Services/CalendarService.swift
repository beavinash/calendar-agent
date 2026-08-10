import CryptoKit
import EventKit
import Foundation

enum CalendarAccessState: String {
  case notDetermined
  case restricted
  case denied
  case writeOnly
  case fullAccess

  var canRead: Bool { self == .fullAccess }
}

struct CalendarSystemEvent {
  let eventIdentifier: String?
  let calendarItemIdentifier: String
  let calendarIdentifier: String
  let occurrenceDate: Date?
  let title: String?
  let startAt: Date
  let endAt: Date
  let isAllDay: Bool
  let isCanceled: Bool
  let isFree: Bool
  let calendarTitle: String
}

@MainActor
protocol CalendarStore: AnyObject {
  var accessState: CalendarAccessState { get }
  var calendars: [CalendarDescriptor] { get }
  var writableCalendars: [CalendarDescriptor] { get }
  var defaultWritableCalendar: CalendarDescriptor? { get }
  var todayEvents: [CalendarDisplayEvent] { get }

  func requestFullAccess() async throws
  func refreshCalendars()
  func refreshFromSystem() throws
  func refreshToday() throws
  func events(
    from start: Date,
    to end: Date
  ) throws -> [CalendarDisplayEvent]
  func snapshot(
    from start: Date,
    to end: Date,
    includeTitles: Bool,
    includeFreeEvents: Bool
  ) throws -> CalendarSnapshotResult
  func apply(
    proposal: CalendarProposal,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent
  func applyAutomatically(
    proposal: CalendarProposal,
    authorizedCalendarIdentifier: String,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent
  func undoAgentEvent(identifier: String) throws
  func agentEventExists(identifier: String) -> Bool
}

@MainActor
final class CalendarService: ObservableObject, CalendarStore {
  private static let ownershipMarker = "[CalendarAgent:"
  private static let focusMarker = "[CalendarAgentFocus:"
  private static let rescheduleMarker = "[CalendarAgentReschedule:"

  @Published private(set) var accessState: CalendarAccessState
  @Published private(set) var calendars: [CalendarDescriptor] = []
  @Published private(set) var todayEvents: [CalendarDisplayEvent] = []

  var writableCalendars: [CalendarDescriptor] {
    calendars.filter(\.allowsModifications)
  }

  var defaultWritableCalendar: CalendarDescriptor? {
    writableDefaultCalendar().map(Self.descriptor)
  }

  private let eventStore: EKEventStore

  init(eventStore: EKEventStore = EKEventStore()) {
    self.eventStore = eventStore
    accessState = Self.mapAuthorization(
      EKEventStore.authorizationStatus(for: .event)
    )
    AppLogger.calendar.info(
      "Calendar service initialized; access=\(self.accessState.rawValue, privacy: .public)"
    )
  }

  func requestFullAccess() async throws {
    AppLogger.calendar.info("Requesting full Apple Calendar access")
    do {
      let granted = try await eventStore.requestFullAccessToEvents()
      AppLogger.calendar.info(
        "Calendar access request completed; granted=\(granted, privacy: .public)"
      )
      try refreshFromSystem()
    } catch {
      logCalendarError("Calendar access request failed", error: error)
      throw error
    }
  }

  func refreshCalendars() {
    accessState = Self.mapAuthorization(
      EKEventStore.authorizationStatus(for: .event)
    )
    guard accessState.canRead else {
      calendars = []
      todayEvents = []
      AppLogger.calendar.info(
        "Calendar list cleared because full read access is unavailable; access=\(self.accessState.rawValue, privacy: .public)"
      )
      return
    }
    let defaultIdentifier = eventStore.defaultCalendarForNewEvents?
      .calendarIdentifier
    calendars = eventStore.calendars(for: .event)
      .map(Self.descriptor)
      .sorted { left, right in
        if left.id == defaultIdentifier { return true }
        if right.id == defaultIdentifier { return false }
        if left.isLikelyICloud != right.isLikelyICloud {
          return left.isLikelyICloud
        }
        if left.allowsModifications != right.allowsModifications {
          return left.allowsModifications
        }
        return left.title.localizedCaseInsensitiveCompare(right.title)
          == .orderedAscending
      }
    AppLogger.calendar.info(
      "Calendar list refreshed; total=\(self.calendars.count, privacy: .public) writable=\(self.writableCalendars.count, privacy: .public) has_default=\(self.defaultWritableCalendar != nil, privacy: .public)"
    )
  }

  func refreshFromSystem() throws {
    AppLogger.calendar.debug("Starting complete calendar refresh")
    refreshCalendars()
    try refreshToday()
    AppLogger.calendar.info(
      "Complete calendar refresh succeeded; today_events=\(self.todayEvents.count, privacy: .public)"
    )
  }

  func refreshToday() throws {
    accessState = Self.mapAuthorization(
      EKEventStore.authorizationStatus(for: .event)
    )
    guard accessState.canRead else {
      todayEvents = []
      AppLogger.calendar.info(
        "Today's event list cleared because full read access is unavailable"
      )
      return
    }
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: Date())
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    todayEvents = try events(from: start, to: end)
    AppLogger.calendar.info(
      "Today's visible event list refreshed; count=\(self.todayEvents.count, privacy: .public)"
    )
  }

  func events(
    from start: Date,
    to end: Date
  ) throws -> [CalendarDisplayEvent] {
    let currentAccess = Self.mapAuthorization(
      EKEventStore.authorizationStatus(for: .event)
    )
    guard currentAccess.canRead else {
      AppLogger.calendar.error(
        "Calendar event fetch rejected because full read access is unavailable"
      )
      throw AppError.calendarAccessRequired
    }
    guard end > start else {
      AppLogger.calendar.error("Calendar event fetch rejected for invalid range")
      return []
    }

    let predicate = eventStore.predicateForEvents(
      withStart: start,
      end: end,
      calendars: nil
    )
    let systemEvents = eventStore.events(matching: predicate)
      .map(Self.systemEvent)
    let visibleEvents = Self.displayEvents(from: systemEvents)
    AppLogger.calendar.debug(
      "Calendar event fetch completed; system_count=\(systemEvents.count, privacy: .public) visible_count=\(visibleEvents.count, privacy: .public) filtered_count=\(systemEvents.count - visibleEvents.count, privacy: .public)"
    )
    return visibleEvents
  }

  func snapshot(
    from start: Date,
    to end: Date,
    includeTitles: Bool,
    includeFreeEvents: Bool
  ) throws -> CalendarSnapshotResult {
    guard accessState.canRead else {
      AppLogger.calendar.error(
        "Calendar snapshot rejected because full read access is unavailable"
      )
      throw AppError.calendarAccessRequired
    }
    let events = fetchEvents(
      from: start,
      to: end,
      includeFreeEvents: includeFreeEvents
    )
    let snapshots = events.prefix(300).map { event in
      CalendarEventSnapshot(
        eventId: Self.completionKey(
          eventIdentifier: event.eventIdentifier,
          calendarItemIdentifier: event.calendarItemIdentifier,
          calendarIdentifier: event.calendar.calendarIdentifier,
          occurrenceDate: event.occurrenceDate
        ),
        calendarId: opaqueIdentifier(event.calendar.calendarIdentifier),
        startAt: event.startDate,
        endAt: event.endDate,
        isAllDay: event.isAllDay,
        title: includeTitles
          ? event.title.map { String($0.prefix(120)) }
          : nil,
        focusArea: Self.agentFocusArea(event),
        completionStatus: nil
      )
    }
    let result = CalendarSnapshotResult(
      events: Array(snapshots),
      isTruncated: events.count > 300
    )
    AppLogger.calendar.info(
      "Calendar snapshot completed; fetched=\(events.count, privacy: .public) included=\(result.events.count, privacy: .public) truncated=\(result.isTruncated, privacy: .public) titles_included=\(includeTitles, privacy: .public) free_events_included=\(includeFreeEvents, privacy: .public)"
    )
    return result
  }

  func apply(
    proposal: CalendarProposal,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent {
    AppLogger.scheduling.info(
      "Starting confirmed calendar proposal write; mode=\(String(describing: validationMode), privacy: .public)"
    )
    guard accessState.canRead else {
      AppLogger.scheduling.error(
        "Confirmed calendar proposal rejected because full read access is unavailable"
      )
      throw AppError.calendarAccessRequired
    }
    guard let calendar = writableDefaultCalendar() else {
      AppLogger.scheduling.error(
        "Confirmed calendar proposal rejected because no writable default calendar exists"
      )
      throw AppError.noWritableCalendar
    }
    if let existing = existingAgentEvent(
      proposal: proposal,
      calendar: calendar
    ) {
      AppLogger.scheduling.info(
        "Returning an existing agent event for an idempotent confirmed write"
      )
      return existing
    }
    try validate(
      proposal: proposal,
      constraints: constraints,
      mode: validationMode
    )
    let applied = try save(proposal: proposal, calendar: calendar)
    AppLogger.scheduling.info("Confirmed calendar proposal write succeeded")
    return applied
  }

  func applyAutomatically(
    proposal: CalendarProposal,
    authorizedCalendarIdentifier: String,
    constraints: LocalScheduleConstraints,
    validationMode: ScheduleValidationMode
  ) throws -> AppliedCalendarEvent {
    AppLogger.scheduling.info(
      "Starting authorized automatic calendar proposal write; mode=\(String(describing: validationMode), privacy: .public)"
    )
    guard accessState.canRead else {
      AppLogger.scheduling.error(
        "Automatic calendar proposal rejected because full read access is unavailable"
      )
      throw AppError.calendarAccessRequired
    }
    guard let calendar = writableDefaultCalendar(),
          calendar.calendarIdentifier == authorizedCalendarIdentifier else {
      AppLogger.scheduling.error(
        "Automatic calendar proposal rejected because calendar authorization is stale"
      )
      throw AppError.automaticCalendarAuthorizationRequired
    }
    if let existing = existingAgentEvent(
      proposal: proposal,
      calendar: calendar
    ) {
      AppLogger.scheduling.info(
        "Returning an existing agent event for an idempotent automatic write"
      )
      return existing
    }
    try validate(
      proposal: proposal,
      constraints: constraints,
      mode: validationMode
    )
    let applied = try save(proposal: proposal, calendar: calendar)
    AppLogger.scheduling.info("Automatic calendar proposal write succeeded")
    return applied
  }

  private func save(
    proposal: CalendarProposal,
    calendar: EKCalendar
  ) throws -> AppliedCalendarEvent {
    let event = makeEvent(proposal: proposal, calendar: calendar)
    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
    } catch {
      logCalendarError("EventKit proposal save failed", error: error)
      throw error
    }
    guard let eventIdentifier = event.eventIdentifier else {
      AppLogger.scheduling.error(
        "EventKit proposal save returned without an event identifier"
      )
      throw AppError.unsafeCalendarEvent
    }
    AppLogger.scheduling.debug(
      "EventKit proposal save completed; duration_minutes=\(Int(event.endDate.timeIntervalSince(event.startDate) / 60), privacy: .public)"
    )
    return AppliedCalendarEvent(
      eventIdentifier: eventIdentifier,
      proposal: proposal
    )
  }

  func scheduleIncompleteEvent(
    _ source: CalendarDisplayEvent,
    constraints: LocalScheduleConstraints
  ) throws -> AppliedIncompleteEventReschedule {
    AppLogger.scheduling.info(
      "Starting incomplete-event carryover; all_day=\(source.isAllDay, privacy: .public)"
    )
    accessState = Self.mapAuthorization(
      EKEventStore.authorizationStatus(for: .event)
    )
    guard accessState.canRead else {
      AppLogger.scheduling.error(
        "Incomplete-event carryover rejected because full read access is unavailable"
      )
      throw AppError.calendarAccessRequired
    }
    guard !source.isAllDay else {
      AppLogger.scheduling.error(
        "Incomplete-event carryover rejected for an all-day source event"
      )
      throw IncompleteEventRescheduleError.allDay
    }
    let duration = source.endAt.timeIntervalSince(source.startAt)
    guard duration > 0,
          duration < 86_400,
          constraints.calendar.isDate(
            source.startAt,
            inSameDayAs: source.endAt
          ) else {
      AppLogger.scheduling.error(
        "Incomplete-event carryover rejected for an invalid timed duration"
      )
      throw IncompleteEventRescheduleError.invalidDuration
    }
    guard let writableCalendar = writableDefaultCalendar() else {
      AppLogger.scheduling.error(
        "Incomplete-event carryover rejected because no writable default calendar exists"
      )
      throw AppError.noWritableCalendar
    }

    let marker = Self.rescheduleOwnershipMarker(
      sourceCompletionKey: source.completionKey
    )
    if let existing = existingIncompleteReschedule(
      marker: marker,
      source: source,
      constraints: constraints
    ) {
      AppLogger.scheduling.info(
        "Returning an existing incomplete-event carryover"
      )
      return existing
    }

    let searchBounds = try incompleteRescheduleSearchBounds(
      constraints: constraints
    )
    let firstBusy = busyIntervals(
      from: searchBounds.start,
      to: searchBounds.end
    )
    guard IncompleteReschedulePlanner.nextSlot(
      sourceStartAt: source.startAt,
      sourceEndAt: source.endAt,
      sourceIsAllDay: source.isAllDay,
      busyIntervals: firstBusy,
      constraints: constraints
    ) != nil else {
      AppLogger.scheduling.info(
        "No incomplete-event carryover slot is available today or tomorrow; busy_count=\(firstBusy.count, privacy: .public)"
      )
      throw IncompleteEventRescheduleError.noAvailableSlot
    }

    // Fetch again immediately before writing so a recent Calendar change is
    // considered and the final slot is selected from the latest device state.
    let latestBusy = busyIntervals(
      from: searchBounds.start,
      to: searchBounds.end
    )
    guard let finalSlot = IncompleteReschedulePlanner.nextSlot(
      sourceStartAt: source.startAt,
      sourceEndAt: source.endAt,
      sourceIsAllDay: source.isAllDay,
      busyIntervals: latestBusy,
      constraints: constraints
    ) else {
      AppLogger.scheduling.info(
        "Incomplete-event carryover lost its slot after the final live conflict refresh"
      )
      throw IncompleteEventRescheduleError.noAvailableSlot
    }

    let proposal = IncompleteEventRescheduleProposal(
      proposalId: UUID(),
      sourceCompletionKey: source.completionKey,
      title: source.title,
      startAt: finalSlot.start,
      endAt: finalSlot.end,
      reminderMinutes: 10
    )
    let event = EKEvent(eventStore: eventStore)
    event.calendar = writableCalendar
    event.title = proposal.title
    event.startDate = proposal.startAt
    event.endDate = proposal.endAt
    event.notes = [
      "Carried forward from an event marked Incomplete in \(AppBrand.name).",
      "\(Self.ownershipMarker)\(proposal.proposalId.uuidString)]",
      marker
    ].joined(separator: "\n\n")
    event.addAlarm(
      EKAlarm(
        relativeOffset: -TimeInterval(proposal.reminderMinutes * 60)
      )
    )
    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
    } catch {
      logCalendarError("Incomplete-event EventKit save failed", error: error)
      throw error
    }
    guard let eventIdentifier = event.eventIdentifier else {
      AppLogger.scheduling.error(
        "Incomplete-event EventKit save returned without an event identifier"
      )
      throw AppError.calendarWriteUntracked
    }
    let scheduledDayOffset = constraints.calendar.isDate(
      finalSlot.start,
      inSameDayAs: constraints.now
    ) ? 0 : 1
    AppLogger.scheduling.info(
      "Incomplete-event carryover saved; day_offset=\(scheduledDayOffset, privacy: .public) duration_minutes=\(Int(duration / 60), privacy: .public) busy_count=\(latestBusy.count, privacy: .public)"
    )
    do {
      try refreshToday()
    } catch {
      logCalendarError(
        "Today's event refresh failed after incomplete-event carryover save",
        error: error
      )
    }
    return AppliedIncompleteEventReschedule(
      eventIdentifier: eventIdentifier,
      proposal: proposal,
      wasCreated: true
    )
  }

  func undoAgentEvent(identifier: String) throws {
    AppLogger.scheduling.info("Starting ownership-checked agent event removal")
    guard accessState.canRead else {
      AppLogger.scheduling.error(
        "Agent event removal rejected because full read access is unavailable"
      )
      throw AppError.calendarAccessRequired
    }
    guard let event = eventStore.event(withIdentifier: identifier),
          event.notes?.contains(Self.ownershipMarker) == true else {
      AppLogger.scheduling.error(
        "Agent event removal rejected because ownership could not be verified"
      )
      throw AppError.unsafeCalendarEvent
    }
    do {
      try eventStore.remove(event, span: .thisEvent, commit: true)
      AppLogger.scheduling.info("Ownership-checked agent event removal succeeded")
    } catch {
      logCalendarError("Ownership-checked agent event removal failed", error: error)
      throw error
    }
  }

  func agentEventExists(identifier: String) -> Bool {
    guard let event = eventStore.event(withIdentifier: identifier) else {
      AppLogger.scheduling.debug(
        "Agent event existence check found no EventKit item"
      )
      return false
    }
    let isOwned = event.notes?.contains(Self.ownershipMarker) == true
    AppLogger.scheduling.debug(
      "Agent event existence check completed; owned=\(isOwned, privacy: .public)"
    )
    return isOwned
  }

  func agentEventInterval(identifier: String) -> DateInterval? {
    guard let event = eventStore.event(withIdentifier: identifier),
          event.notes?.contains(Self.ownershipMarker) == true,
          event.endDate > event.startDate else {
      AppLogger.scheduling.debug(
        "Agent event timing lookup found no owned EventKit item"
      )
      return nil
    }
    AppLogger.scheduling.debug(
      "Agent event timing lookup succeeded; duration_minutes=\(Int(event.endDate.timeIntervalSince(event.startDate) / 60), privacy: .public)"
    )
    return DateInterval(start: event.startDate, end: event.endDate)
  }

  private func fetchEvents(
    from start: Date,
    to end: Date,
    calendars: [EKCalendar]? = nil,
    includeFreeEvents: Bool
  ) -> [EKEvent] {
    let predicate = eventStore.predicateForEvents(
      withStart: start,
      end: end,
      calendars: calendars
    )
    return eventStore.events(matching: predicate)
      .filter {
        $0.status != .canceled
          && !Self.isHolidayCalendarTitle($0.calendar.title)
          && (includeFreeEvents || $0.availability != .free)
      }
      .sorted { $0.startDate < $1.startDate }
  }

  private func busyIntervals(
    from start: Date,
    to end: Date
  ) -> [DateInterval] {
    let events = fetchEvents(
      from: start,
      to: end,
      includeFreeEvents: false
    )
    let intervals = events.compactMap { event -> DateInterval? in
      guard event.endDate > event.startDate else { return nil }
      return DateInterval(start: event.startDate, end: event.endDate)
    }
    AppLogger.calendar.debug(
      "Built live busy intervals for carryover planning; event_count=\(events.count, privacy: .public) interval_count=\(intervals.count, privacy: .public)"
    )
    return intervals
  }

  private func incompleteRescheduleSearchBounds(
    constraints: LocalScheduleConstraints
  ) throws -> DateInterval {
    let calendar = constraints.calendar
    let todayStart = calendar.startOfDay(for: constraints.now)
    guard let end = calendar.date(
      byAdding: .day,
      value: 2,
      to: todayStart
    ) else {
      AppLogger.scheduling.error(
        "Unable to construct today-and-tomorrow carryover search bounds"
      )
      throw IncompleteEventRescheduleError.noAvailableSlot
    }
    return DateInterval(start: todayStart, end: end)
  }

  private func existingIncompleteReschedule(
    marker: String,
    source: CalendarDisplayEvent,
    constraints: LocalScheduleConstraints
  ) -> AppliedIncompleteEventReschedule? {
    guard let bounds = try? incompleteRescheduleSearchBounds(
      constraints: constraints
    ) else {
      return nil
    }
    let predicate = eventStore.predicateForEvents(
      withStart: bounds.start,
      end: bounds.end,
      calendars: nil
    )
    guard let event = eventStore.events(matching: predicate).first(
      where: {
        $0.notes?.contains(Self.ownershipMarker) == true
          && $0.notes?.contains(marker) == true
      }
    ),
    let eventIdentifier = event.eventIdentifier else {
      return nil
    }
    let proposal = IncompleteEventRescheduleProposal(
      proposalId: UUID(),
      sourceCompletionKey: source.completionKey,
      title: event.title ?? source.title,
      startAt: event.startDate,
      endAt: event.endDate,
      reminderMinutes: 10
    )
    return AppliedIncompleteEventReschedule(
      eventIdentifier: eventIdentifier,
      proposal: proposal,
      wasCreated: false
    )
  }

  private static func rescheduleOwnershipMarker(
    sourceCompletionKey: String
  ) -> String {
    "\(rescheduleMarker)\(sourceCompletionKey)]"
  }

  private func writableDefaultCalendar() -> EKCalendar? {
    guard let calendar = eventStore.defaultCalendarForNewEvents,
          calendar.allowsContentModifications else {
      return nil
    }
    return calendar
  }

  private func makeEvent(
    proposal: CalendarProposal,
    calendar: EKCalendar
  ) -> EKEvent {
    let event = EKEvent(eventStore: eventStore)
    event.calendar = calendar
    event.title = proposal.title
    event.startDate = proposal.startAt
    event.endDate = proposal.endAt
    event.notes = [
      proposal.notes,
      "Why: \(proposal.rationale)",
      "\(Self.focusMarker)\(proposal.focusArea.rawValue)]",
      "\(Self.ownershipMarker)\(proposal.proposalId.uuidString)]"
    ]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    if proposal.reminderMinutes > 0 {
      event.addAlarm(
        EKAlarm(
          relativeOffset: -TimeInterval(proposal.reminderMinutes * 60)
        )
      )
    }
    return event
  }

  private func existingAgentEvent(
    proposal: CalendarProposal,
    calendar: EKCalendar
  ) -> AppliedCalendarEvent? {
    let predicate = eventStore.predicateForEvents(
      withStart: proposal.startAt.addingTimeInterval(-1),
      end: proposal.endAt.addingTimeInterval(1),
      calendars: [calendar]
    )
    let marker = "\(Self.ownershipMarker)\(proposal.proposalId.uuidString)]"
    guard let event = eventStore.events(matching: predicate).first(
      where: { $0.notes?.contains(marker) == true }
    ),
    let identifier = event.eventIdentifier else {
      return nil
    }
    return AppliedCalendarEvent(
      eventIdentifier: identifier,
      proposal: proposal,
      title: event.title ?? proposal.title,
      startAt: event.startDate,
      endAt: event.endDate
    )
  }

  private static func descriptor(_ calendar: EKCalendar) -> CalendarDescriptor {
    CalendarDescriptor(
      id: calendar.calendarIdentifier,
      title: calendar.title,
      accountTitle: calendar.source.title,
      isLikelyICloud: isLikelyICloud(calendar.source),
      allowsModifications: calendar.allowsContentModifications
    )
  }

  private static func systemEvent(_ event: EKEvent) -> CalendarSystemEvent {
    CalendarSystemEvent(
      eventIdentifier: event.eventIdentifier,
      calendarItemIdentifier: event.calendarItemIdentifier,
      calendarIdentifier: event.calendar.calendarIdentifier,
      occurrenceDate: event.occurrenceDate,
      title: event.title,
      startAt: event.startDate,
      endAt: event.endDate,
      isAllDay: event.isAllDay,
      isCanceled: event.status == .canceled,
      isFree: event.availability == .free,
      calendarTitle: event.calendar.title
    )
  }

  static func displayEvents(
    from systemEvents: [CalendarSystemEvent]
  ) -> [CalendarDisplayEvent] {
    systemEvents
      .filter {
        !$0.isCanceled && !isHolidayCalendarTitle($0.calendarTitle)
      }
      .sorted { $0.startAt < $1.startAt }
      .map { event in
        CalendarDisplayEvent(
          completionKey: completionKey(
            eventIdentifier: event.eventIdentifier,
            calendarItemIdentifier: event.calendarItemIdentifier,
            calendarIdentifier: event.calendarIdentifier,
            occurrenceDate: event.occurrenceDate
          ),
          title: event.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Busy",
          startAt: event.startAt,
          endAt: event.endAt,
          isAllDay: event.isAllDay,
          calendarTitle: event.calendarTitle
        )
      }
  }

  nonisolated static func isHolidayCalendarTitle(_ title: String) -> Bool {
    let normalized = title
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
    let holidayTerms = [
      "holiday",
      "holidays",
      "festivo",
      "festivos",
      "feriado",
      "feriados",
      "feiertag",
      "feiertage",
      "jour ferie",
      "jours feries",
      "giorni festivi",
      "festivita",
      "праздник",
      "праздники",
      "祝日",
      "节假日",
      "節假日",
      "공휴일"
    ]
    return holidayTerms.contains { normalized.contains($0) }
  }

  nonisolated static func completionKey(
    eventIdentifier: String?,
    calendarItemIdentifier: String,
    calendarIdentifier: String,
    occurrenceDate: Date?
  ) -> String {
    let occurrence = occurrenceDate.map {
      String($0.timeIntervalSinceReferenceDate.bitPattern)
    } ?? "single"
    let source: String
    if let eventIdentifier,
       !eventIdentifier.isEmpty {
      source = ["event", eventIdentifier, occurrence]
        .joined(separator: "\u{1F}")
    } else {
      source = [
        "fallback",
        calendarIdentifier,
        calendarItemIdentifier,
        occurrence
      ].joined(separator: "\u{1F}")
    }
    return digest(source)
  }

  private nonisolated static func digest(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func agentFocusArea(_ event: EKEvent) -> FocusArea? {
    guard let notes = event.notes,
          notes.contains(ownershipMarker),
          let markerRange = notes.range(of: focusMarker) else {
      return nil
    }
    let suffix = notes[markerRange.upperBound...]
    guard let closing = suffix.firstIndex(of: "]") else { return nil }
    return FocusArea(rawValue: String(suffix[..<closing]))
  }

  private func validate(
    proposal: CalendarProposal,
    constraints: LocalScheduleConstraints,
    mode: ScheduleValidationMode
  ) throws {
    AppLogger.scheduling.debug(
      "Starting on-device schedule validation; mode=\(String(describing: mode), privacy: .public)"
    )
    let busy = fetchEvents(
      from: proposal.startAt.addingTimeInterval(-7_200),
      to: proposal.endAt.addingTimeInterval(7_200),
      includeFreeEvents: false
    ).map { event in
      CalendarEventSnapshot(
        eventId: Self.completionKey(
          eventIdentifier: event.eventIdentifier,
          calendarItemIdentifier: event.calendarItemIdentifier,
          calendarIdentifier: event.calendar.calendarIdentifier,
          occurrenceDate: event.occurrenceDate
        ),
        calendarId: opaqueIdentifier(event.calendar.calendarIdentifier),
        startAt: event.startDate,
        endAt: event.endDate,
        isAllDay: event.isAllDay,
        title: nil,
        focusArea: Self.agentFocusArea(event),
        completionStatus: nil
      )
    }
    do {
      try ScheduleValidator.validate(
        proposal,
        busyIntervals: busy,
        constraints: constraints,
        mode: mode
      )
    } catch ScheduleValidationError.conflict {
      AppLogger.scheduling.error(
        "On-device schedule validation failed; reason=conflict busy_count=\(busy.count, privacy: .public)"
      )
      throw AppError.calendarConflict
    } catch let validationError as ScheduleValidationError {
      AppLogger.scheduling.error(
        "On-device schedule validation failed; reason=\(String(describing: validationError), privacy: .public) busy_count=\(busy.count, privacy: .public)"
      )
      throw validationError
    }

    let localCalendar = constraints.calendar
    let dayStart = localCalendar.startOfDay(for: proposal.startAt)
    guard let dayEnd = localCalendar.date(
      byAdding: .day,
      value: 1,
      to: dayStart
    ) else {
      throw AppError.unsafeCalendarEvent
    }
    let agentBlockCount = fetchEvents(
      from: dayStart,
      to: dayEnd,
      includeFreeEvents: true
    ).filter {
      $0.notes?.contains(Self.ownershipMarker) == true
    }.count
    guard agentBlockCount < constraints.maxDailyBlocks else {
      AppLogger.scheduling.error(
        "On-device schedule validation failed; reason=daily_block_limit current_count=\(agentBlockCount, privacy: .public) maximum=\(constraints.maxDailyBlocks, privacy: .public)"
      )
      throw AppError.dailyBlockLimit
    }
    AppLogger.scheduling.info(
      "On-device schedule validation succeeded; busy_count=\(busy.count, privacy: .public) existing_agent_blocks=\(agentBlockCount, privacy: .public)"
    )
  }

  private func logCalendarError(_ operation: String, error: Error) {
    let nsError = error as NSError
    AppLogger.calendar.error(
      "\(operation, privacy: .public); domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
    )
  }

  private static func isLikelyICloud(_ source: EKSource) -> Bool {
    source.sourceType == .calDAV
      && source.title.localizedCaseInsensitiveContains("icloud")
  }

  private static func mapAuthorization(
    _ status: EKAuthorizationStatus
  ) -> CalendarAccessState {
    switch status {
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    case .denied:
      .denied
    case .writeOnly:
      .writeOnly
    case .fullAccess, .authorized:
      .fullAccess
    @unknown default:
      .denied
    }
  }

  private func opaqueIdentifier(_ value: String) -> String {
    Self.digest(value)
  }
}
