import Foundation

enum MissedEventTrackingCoverage: String, Codable, Hashable {
  case full
  case partial
  case none
}

struct MissedEventGroup: Identifiable, Equatable {
  let familyKey: String
  let displayTitle: String
  let missedCount: Int
  let inferredUnmarkedCount: Int
  let explicitIncompleteCount: Int
  let latestOccurrenceAt: Date

  var id: String { familyKey }

  var missedCountText: String {
    missedCount == 1 ? "1 time" : "\(missedCount) times"
  }

  var evidenceSummary: String {
    var parts: [String] = []
    if inferredUnmarkedCount > 0 {
      parts.append("\(inferredUnmarkedCount) ended without a choice")
    }
    if explicitIncompleteCount > 0 {
      parts.append("\(explicitIncompleteCount) marked Incomplete")
    }
    return parts.joined(separator: " · ")
  }
}

struct MissedEventInsight: Equatable {
  let period: FocusReviewPeriod
  let groups: [MissedEventGroup]
  let evaluatedEventCount: Int
  let coveredEvaluatedEventCount: Int
  let missedEventCount: Int
  let inferredUnmarkedCount: Int
  let explicitIncompleteCount: Int
  let trackingCoverage: MissedEventTrackingCoverage

  var displayedGroups: [MissedEventGroup] {
    Array(groups.prefix(3))
  }

  var remainingGroupCount: Int {
    max(0, groups.count - displayedGroups.count)
  }

  var hiddenGroups: [MissedEventGroup] {
    Array(groups.dropFirst(displayedGroups.count))
  }

  var hasMoreGroups: Bool {
    !hiddenGroups.isEmpty
  }

  var moreButtonTitle: String? {
    guard hasMoreGroups else { return nil }
    return "+\(remainingGroupCount) more"
  }

  var moreButtonAccessibilityLabel: String? {
    guard hasMoreGroups else { return nil }
    let eventType = remainingGroupCount == 1
      ? "missed event type"
      : "missed event types"
    return "Show \(remainingGroupCount) more \(eventType)"
  }

  var heading: String {
    guard !groups.isEmpty else { return "" }
    let prefix = inferredUnmarkedCount > 0 ? "Likely missed" : "Missed"
    let coverage: String
    switch trackingCoverage {
    case .full:
      coverage = inferredUnmarkedCount > 0 ? " · unmarked included" : ""
    case .partial:
      coverage = " · partial tracking"
    case .none:
      coverage = " · explicit records only"
    }
    return "\(prefix) \(period.missedEventHeadingPhrase)\(coverage)"
  }

  var emptyMessage: String? {
    guard groups.isEmpty else { return nil }
    if trackingCoverage == .none {
      if evaluatedEventCount == 0 {
        return "Not enough tracked history for "
          + "\(period.missedEventCoveragePhrase) yet."
      }
      return "No misses in explicit records; tracking had not started "
        + "\(period.missedEventTrackingStartPhrase)."
    }
    if trackingCoverage == .partial, coveredEvaluatedEventCount == 0 {
      return "No tracked ended events to evaluate "
        + "\(period.missedEventHeadingPhrase) yet."
    }
    if trackingCoverage == .partial {
      return "No likely missed events in the tracked part of "
        + "\(period.missedEventCoveragePhrase)."
    }
    if evaluatedEventCount == 0 {
      return "No ended calendar events to evaluate "
        + "\(period.missedEventHeadingPhrase)."
    }
    return "No likely missed events found "
      + "\(period.missedEventHeadingPhrase)."
  }
}

extension MissedEventInsight {
  static let transmittedGroupLimit = 25

  func contextPayload(
    window: DateInterval
  ) -> MissedPatternContextPayload {
    let transmittedGroups = Array(
      groups.prefix(Self.transmittedGroupLimit)
    )
    return MissedPatternContextPayload(
      sourceReviewPeriod: period,
      windowStartAt: window.start,
      windowEndAt: window.end,
      trackingCoverage: trackingCoverage,
      evaluatedEventCount: evaluatedEventCount,
      coveredEvaluatedEventCount: coveredEvaluatedEventCount,
      missedEventCount: missedEventCount,
      inferredUnmarkedCount: inferredUnmarkedCount,
      explicitIncompleteCount: explicitIncompleteCount,
      omittedGroupCount: max(0, groups.count - transmittedGroups.count),
      groups: transmittedGroups.enumerated().map { index, group in
        MissedPatternGroupPayload(
          rank: index + 1,
          displayTitle: String(group.displayTitle.prefix(120)),
          missedCount: group.missedCount,
          inferredUnmarkedCount: group.inferredUnmarkedCount,
          explicitIncompleteCount: group.explicitIncompleteCount
        )
      }
    )
  }
}

enum MissedEventInsightQuery {
  static func analysisBounds(
    for period: FocusReviewPeriod,
    at now: Date,
    calendar: Calendar
  ) -> DateInterval {
    guard period == .day else {
      return period.analysisBounds(at: now, calendar: calendar)
    }

    let todayStart = calendar.startOfDay(for: now)
    let rollingStart = calendar.date(
      byAdding: .day,
      value: -6,
      to: todayStart
    ) ?? todayStart.addingTimeInterval(-6 * 86_400)
    return DateInterval(start: rollingStart, end: max(now, todayStart))
  }

  static func fetchBounds(
    for period: FocusReviewPeriod,
    at now: Date,
    calendar: Calendar
  ) -> DateInterval {
    let analysisBounds = analysisBounds(
      for: period,
      at: now,
      calendar: calendar
    )
    guard period == .day else { return analysisBounds }
    let todayStart = calendar.startOfDay(for: now)
    let fullDayEnd = calendar.date(
      byAdding: .day,
      value: 1,
      to: todayStart
    ) ?? analysisBounds.end
    return DateInterval(start: analysisBounds.start, end: fullDayEnd)
  }
}

enum MissedEventInsightBuilder {
  private static let posixLocale = Locale(identifier: "en_US_POSIX")
  private static let recurrenceSuffixes: Set<String> = [
    "block",
    "blocks",
    "practice",
    "practices",
    "routine",
    "routines",
    "session",
    "sessions"
  ]

  static func build(
    events: [CalendarDisplayEvent],
    completionStatuses: [String: CalendarEventCompletionStatus],
    period: FocusReviewPeriod,
    now: Date,
    trackingStartedAt: Date,
    calendar: Calendar,
    allDayEndHour: Int = 23
  ) -> MissedEventInsight {
    let bounds = MissedEventInsightQuery.analysisBounds(
      for: period,
      at: now,
      calendar: calendar
    )
    let trackingCoverage = trackingCoverage(
      bounds: bounds,
      trackingStartedAt: trackingStartedAt
    )
    let uniqueEvents = deduplicated(events)
    var groups: [String: GroupAccumulator] = [:]
    var evaluatedEventCount = 0
    var coveredEvaluatedEventCount = 0
    var missedEventCount = 0
    var inferredUnmarkedCount = 0
    var explicitIncompleteCount = 0

    for event in uniqueEvents {
      guard event.endAt > event.startAt,
            eventIsInSelectedPeriod(
              event,
              period: period,
              bounds: bounds,
              now: now,
              calendar: calendar
            ) else {
        continue
      }

      let status = completionStatuses[event.completionKey]
      let eligibleEnd = effectiveEnd(
        for: event,
        calendar: calendar,
        allDayEndHour: allDayEndHour
      )
      switch status {
      case .complete:
        evaluatedEventCount += 1
        if eligibleEnd > trackingStartedAt {
          coveredEvaluatedEventCount += 1
        }
      case .incomplete:
        evaluatedEventCount += 1
        if eligibleEnd > trackingStartedAt {
          coveredEvaluatedEventCount += 1
        }
        missedEventCount += 1
        explicitIncompleteCount += 1
        add(
          event,
          isInferred: false,
          to: &groups
        )
      case nil:
        guard eligibleEnd <= now,
              eligibleEnd > trackingStartedAt else {
          continue
        }
        evaluatedEventCount += 1
        coveredEvaluatedEventCount += 1
        missedEventCount += 1
        inferredUnmarkedCount += 1
        add(
          event,
          isInferred: true,
          to: &groups
        )
      }
    }

    let sortedGroups = groups.values
      .map(\.value)
      .sorted {
        if $0.missedCount != $1.missedCount {
          return $0.missedCount > $1.missedCount
        }
        if $0.latestOccurrenceAt != $1.latestOccurrenceAt {
          return $0.latestOccurrenceAt > $1.latestOccurrenceAt
        }
        return $0.familyKey < $1.familyKey
      }

    return MissedEventInsight(
      period: period,
      groups: sortedGroups,
      evaluatedEventCount: evaluatedEventCount,
      coveredEvaluatedEventCount: coveredEvaluatedEventCount,
      missedEventCount: missedEventCount,
      inferredUnmarkedCount: inferredUnmarkedCount,
      explicitIncompleteCount: explicitIncompleteCount,
      trackingCoverage: trackingCoverage
    )
  }

  static func titleFamilyKey(_ title: String) -> String {
    let folded = title
      .folding(
        options: [
          .caseInsensitive,
          .diacriticInsensitive,
          .widthInsensitive
        ],
        locale: posixLocale
      )
      .lowercased(with: posixLocale)
    let alphanumeric = folded.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
    }.joined()
    let originalTokens = alphanumeric
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !originalTokens.isEmpty else {
      let fallback = folded
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
      return fallback.isEmpty ? "untitled event" : fallback
    }

    let tokens = removingNumberedRecurrenceSuffix(from: originalTokens)
    return (tokens.isEmpty ? originalTokens : tokens).joined(separator: " ")
  }

  private static func add(
    _ event: CalendarDisplayEvent,
    isInferred: Bool,
    to groups: inout [String: GroupAccumulator]
  ) {
    let key = titleFamilyKey(event.title)
    let displayTitle = normalizedDisplayTitle(event.title)
    if var existing = groups[key] {
      existing.missedCount += 1
      if isInferred {
        existing.inferredUnmarkedCount += 1
      } else {
        existing.explicitIncompleteCount += 1
      }
      if event.startAt > existing.latestOccurrenceAt
        || (
          event.startAt == existing.latestOccurrenceAt
            && displayTitle < existing.displayTitle
        ) {
        existing.latestOccurrenceAt = event.startAt
        existing.displayTitle = displayTitle
      }
      groups[key] = existing
    } else {
      groups[key] = GroupAccumulator(
        familyKey: key,
        displayTitle: displayTitle,
        missedCount: 1,
        inferredUnmarkedCount: isInferred ? 1 : 0,
        explicitIncompleteCount: isInferred ? 0 : 1,
        latestOccurrenceAt: event.startAt
      )
    }
  }

  private static func deduplicated(
    _ events: [CalendarDisplayEvent]
  ) -> [CalendarDisplayEvent] {
    var byKey: [String: CalendarDisplayEvent] = [:]
    for event in events {
      guard let existing = byKey[event.completionKey] else {
        byKey[event.completionKey] = event
        continue
      }
      if preferred(event, over: existing) {
        byKey[event.completionKey] = event
      }
    }
    return Array(byKey.values)
  }

  private static func preferred(
    _ candidate: CalendarDisplayEvent,
    over existing: CalendarDisplayEvent
  ) -> Bool {
    if candidate.startAt != existing.startAt {
      return candidate.startAt > existing.startAt
    }
    if candidate.endAt != existing.endAt {
      return candidate.endAt > existing.endAt
    }
    return candidate.title < existing.title
  }

  private static func trackingCoverage(
    bounds: DateInterval,
    trackingStartedAt: Date
  ) -> MissedEventTrackingCoverage {
    if trackingStartedAt >= bounds.end {
      return .none
    }
    if trackingStartedAt > bounds.start {
      return .partial
    }
    return .full
  }

  private static func normalizedDisplayTitle(_ title: String) -> String {
    let collapsed = title
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return "Busy" }

    let displayTokens = collapsed
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
    let normalizedTokens = displayTokens.map(normalizedToken)
    let familyTokens = removingNumberedRecurrenceSuffix(
      from: normalizedTokens
    )
    guard familyTokens.count < normalizedTokens.count else {
      return collapsed
    }
    let familyTitle = displayTokens.prefix(familyTokens.count)
      .joined(separator: " ")
    return familyTitle.isEmpty ? collapsed : familyTitle
  }

  private static func eventIsInSelectedPeriod(
    _ event: CalendarDisplayEvent,
    period: FocusReviewPeriod,
    bounds: DateInterval,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard event.startAt <= now else { return false }
    switch period {
    case .day:
      if event.isAllDay {
        let firstWindowDay = calendar.startOfDay(for: bounds.start)
        let currentDay = calendar.startOfDay(for: now)
        let firstCoveredDay = calendar.startOfDay(for: event.startAt)
        let finalCoveredDay = calendar.startOfDay(
          for: event.endAt.addingTimeInterval(-1)
        )
        return finalCoveredDay >= firstWindowDay
          && firstCoveredDay <= currentDay
      }
      return event.startAt >= bounds.start && event.startAt <= now
    case .week, .month:
      let assignmentDate = event.isAllDay
        ? calendar.startOfDay(for: event.endAt.addingTimeInterval(-1))
        : event.startAt
      return assignmentDate >= bounds.start && assignmentDate < bounds.end
    }
  }

  private static func effectiveEnd(
    for event: CalendarDisplayEvent,
    calendar: Calendar,
    allDayEndHour: Int
  ) -> Date {
    guard event.isAllDay else { return event.endAt }
    let lastCoveredMoment = event.endAt.addingTimeInterval(-1)
    let lastCoveredDay = calendar.startOfDay(for: lastCoveredMoment)
    return calendar.date(
      bySettingHour: min(max(allDayEndHour, 0), 23),
      minute: 0,
      second: 0,
      of: lastCoveredDay
    ) ?? event.endAt
  }

  private static func removingNumberedRecurrenceSuffix(
    from tokens: [String]
  ) -> [String] {
    guard tokens.count >= 2,
          isSequenceNumber(tokens[tokens.count - 1]),
          recurrenceSuffixes.contains(tokens[tokens.count - 2]) else {
      return tokens
    }
    if tokens.count == 2 {
      return [tokens[0]]
    }
    return Array(tokens.dropLast(2))
  }

  private static func normalizedToken(_ token: String) -> String {
    token
      .folding(
        options: [
          .caseInsensitive,
          .diacriticInsensitive,
          .widthInsensitive
        ],
        locale: posixLocale
      )
      .lowercased(with: posixLocale)
      .unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
  }

  private static func isSequenceNumber(_ token: String) -> Bool {
    if Int(token) != nil {
      return true
    }
    for suffix in ["st", "nd", "rd", "th"] where token.hasSuffix(suffix) {
      let number = token.dropLast(suffix.count)
      if !number.isEmpty, Int(number) != nil {
        return true
      }
    }
    return false
  }

  private struct GroupAccumulator {
    let familyKey: String
    var displayTitle: String
    var missedCount: Int
    var inferredUnmarkedCount: Int
    var explicitIncompleteCount: Int
    var latestOccurrenceAt: Date

    var value: MissedEventGroup {
      MissedEventGroup(
        familyKey: familyKey,
        displayTitle: displayTitle,
        missedCount: missedCount,
        inferredUnmarkedCount: inferredUnmarkedCount,
        explicitIncompleteCount: explicitIncompleteCount,
        latestOccurrenceAt: latestOccurrenceAt
      )
    }
  }
}

private extension FocusReviewPeriod {
  var missedEventHeadingPhrase: String {
    switch self {
    case .day:
      "during the past 7 days"
    case .week:
      "last week"
    case .month:
      "last month"
    }
  }

  var missedEventCoveragePhrase: String {
    switch self {
    case .day:
      "the past 7 days"
    case .week:
      "last week"
    case .month:
      "last month"
    }
  }

  var missedEventTrackingStartPhrase: String {
    switch self {
    case .day:
      "during the past 7 days"
    case .week:
      "last week"
    case .month:
      "last month"
    }
  }
}
