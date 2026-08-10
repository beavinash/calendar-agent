import Foundation

enum CalendarIntentDetector {
  static func requestsCalendarAction(_ message: String) -> Bool {
    var value = message
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return false }

    if value == "/schedule" || value.hasPrefix("/schedule ") {
      return true
    }

    let courtesyPrefixes = [
      "please ",
      "can you ",
      "could you ",
      "would you ",
      "will you ",
      "i want you to ",
      "i need you to ",
      "i need to ",
      "help me "
    ]
    var removedPrefix = true
    while removedPrefix {
      removedPrefix = false
      for prefix in courtesyPrefixes where value.hasPrefix(prefix) {
        value.removeFirst(prefix.count)
        removedPrefix = true
        break
      }
    }

    guard !containsProgrammingContext(value) else { return false }

    let explicitCommands = ["schedule", "reschedule"]
    for command in explicitCommands where value.hasPrefix("\(command) ") {
      let context = value
        .dropFirst(command.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return containsSchedulingContext(context)
    }

    let timeBoundCommands = [
      "plan",
      "block",
      "protect",
      "reserve",
      "book",
      "set aside",
      "make time",
      "remind me"
    ]
    for command in timeBoundCommands where value.hasPrefix("\(command) ") {
      let context = value
        .dropFirst(command.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if command == "plan",
         isExplicitPlanContext(context) {
        return true
      }
      return containsSchedulingContext(context)
    }

    let targetedCommands = ["add", "create", "put", "move"]
    for command in targetedCommands where value.hasPrefix("\(command) ") {
      let context = value
        .dropFirst(command.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return containsTargetedSchedulingContext(context)
    }
    return false
  }

  private static func containsSchedulingContext(_ value: String) -> Bool {
    containsCalendarReference(value)
      || containsDomainBlock(value)
      || containsTemporalContext(value)
  }

  private static func containsTargetedSchedulingContext(
    _ value: String
  ) -> Bool {
    if containsCalendarReference(value) {
      return true
    }
    let hasCalendarObject = matches(
      #"\b(?:events?|appointments?|reminders?)\b"#,
      in: value
    )
    return hasCalendarObject
      && (containsDomainBlock(value) || containsTemporalContext(value))
  }

  private static func containsCalendarReference(_ value: String) -> Bool {
    let patterns = [
      #"\b(?:my|apple|icloud)\s+calendar\b"#,
      #"\b(?:to|on|in|into|from)\s+(?:the\s+)?calendar\b"#
    ]
    return patterns.contains { matches($0, in: value) }
  }

  private static func containsDomainBlock(_ value: String) -> Bool {
    matches(
      #"\b(?:time|focus|work|study|exercise|appointment|errand|project|meeting)\s+blocks?\b"#,
      in: value
    )
  }

  private static func containsTemporalContext(_ value: String) -> Bool {
    let patterns = [
      #"\b\d+(?:\.\d+)?\s*(?:minutes?|mins?|hours?|hrs?)\b"#,
      #"\b(?:[01]?\d|2[0-3]):[0-5]\d\s*(?:am|pm)?\b"#,
      #"\b(?:1[0-2]|0?[1-9])\s*(?:am|pm)\b"#,
      #"\b(?:at|after|before)\s+(?:[01]?\d|2[0-3])(?::[0-5]\d)?\s*(?:am|pm)?\b"#,
      #"\b(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b.*\b(?:morning|afternoon|evening|night)\b"#,
      #"\b(?:morning|afternoon|evening|night)\b.*\b(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#
    ]
    return patterns.contains { matches($0, in: value) }
  }

  private static func containsProgrammingContext(_ value: String) -> Bool {
    let patterns = [
      #"\bevent\s+(?:handler|listener|loop|stream)\b"#,
      #"\bcalendar\s+(?:view|component|api|widget)\b"#,
      #"\b(?:background|cron|batch|training)\s+jobs?\b"#,
      #"\b(?:function|class|struct|method|protocol|thread|queue|timer)\b"#,
      #"\b(?:in|with|using)\s+(?:swiftui?|python|javascript|typescript|kotlin|java|react|code)\b"#
    ]
    return patterns.contains { matches($0, in: value) }
  }

  private static func isExplicitPlanContext(_ value: String) -> Bool {
    let wholeDayRequests = [
      "today",
      "tomorrow",
      "tonight",
      "my day",
      "my morning",
      "my evening",
      "my schedule",
      "the day",
      "the morning",
      "the evening"
    ]
    return wholeDayRequests.contains(value)
      || (
        MissedPatternContextIntentDetector.requestsContext(value)
          && matches(
            #"\b(?:today|tomorrow|this week|next week)\b"#,
            in: value
          )
      )
      || matches(
        #"\b(?:a|one|two|three|four|five|six|seven|[1-7])\s+(?:time\s+|focus\s+)?blocks?\b"#,
        in: value
      )
  }

  private static func matches(_ pattern: String, in value: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }
}
