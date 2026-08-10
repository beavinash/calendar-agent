import Foundation
import UserNotifications

enum NotificationConfigurationError: LocalizedError {
  case denied

  var errorDescription: String? {
    "Notifications are disabled. Enable them in iOS Settings to use reminders."
  }
}

protocol NotificationScheduling: AnyObject {
  func currentAuthorizationStatus() async -> UNAuthorizationStatus
  func requestAuthorization(
    options: UNAuthorizationOptions
  ) async throws -> Bool
  func add(_ request: UNNotificationRequest) async throws
  func pendingNotificationIdentifiers() async -> Set<String>
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationScheduling {
  func currentAuthorizationStatus() async -> UNAuthorizationStatus {
    await notificationSettings().authorizationStatus
  }

  func pendingNotificationIdentifiers() async -> Set<String> {
    let requests = await pendingNotificationRequests()
    return Set(requests.map(\.identifier))
  }
}

struct ReflectionNotificationMessage: Hashable {
  let title: String
  let body: String
}

struct ReflectionNotificationPlan: Equatable {
  let identifier: String
  let year: Int
  let month: Int
  let day: Int
  let minutesAfterMidnight: Int
  let message: ReflectionNotificationMessage

  var hour: Int { minutesAfterMidnight / 60 }
  var minute: Int { minutesAfterMidnight % 60 }
}

enum ReflectionNotificationPlanner {
  static let promptsPerDay = 3
  static let horizonDays = 20
  private static let firstPromptMinutes = 19 * 60 + 30
  private static let messages = [
    ReflectionNotificationMessage(
      title: "Was it done—or only scheduled?",
      body: "Open \(AppBrand.name) and mark Complete or Incomplete while today's evidence is fresh."
    ),
    ReflectionNotificationMessage(
      title: "Your seven-day pattern is changing",
      body: "One honest status can reveal what you repeat, finish, or quietly avoid."
    ),
    ReflectionNotificationMessage(
      title: "Unmarked is not neutral",
      body: "Ended unmarked events count as 70% likely missed. Confirm what happened."
    ),
    ReflectionNotificationMessage(
      title: "Close one loop before bed",
      body: "A 30-second calendar check gives tomorrow's plan better evidence."
    ),
    ReflectionNotificationMessage(
      title: "Find tonight's honest answer",
      body: "Which scheduled block moved a goal—and which one needs another attempt?"
    ),
    ReflectionNotificationMessage(
      title: "Give tomorrow cleaner data",
      body: "Mark today's events so \(AppBrand.name) can recommend a more realistic next step."
    ),
    ReflectionNotificationMessage(
      title: "What are you repeatedly avoiding?",
      body: "Review today's outcomes and sharpen the pattern behind your missed blocks."
    ),
    ReflectionNotificationMessage(
      title: "Your calendar records intent",
      body: "Complete or Incomplete records follow-through. Add the missing truth."
    ),
    ReflectionNotificationMessage(
      title: "Small reflection, sharper plan",
      body: "Confirm today's events and improve the next seven-day analysis."
    ),
    ReflectionNotificationMessage(
      title: "Did the hard block happen?",
      body: "Capture it now—completed work and honest misses both improve the plan."
    ),
    ReflectionNotificationMessage(
      title: "Don't let silence choose the result",
      body: "Unmarked ended events become likely misses. Confirm them before the day fades."
    ),
    ReflectionNotificationMessage(
      title: "Turn today into useful evidence",
      body: "A few taps separate real progress from plans that only looked good."
    )
  ]

  static func plans(
    seed: UUID,
    now: Date = .now,
    calendar: Calendar = .current
  ) -> [ReflectionNotificationPlan] {
    let installationSeed = stableHash(seed.uuidString)
    let firstDay = calendar.startOfDay(for: now)
    return (0..<horizonDays).flatMap {
      dayOffset -> [ReflectionNotificationPlan] in
      guard let localDay = calendar.date(
        byAdding: .day,
        value: dayOffset,
        to: firstDay
      ) else { return [] }
      let dayComponents = calendar.dateComponents(
        [.year, .month, .day],
        from: localDay
      )
      guard let year = dayComponents.year,
            let month = dayComponents.month,
            let day = dayComponents.day else { return [] }
      let dayIdentity = String(format: "%04d-%02d-%02d", year, month, day)
      let daySeed = mix(
        installationSeed ^ stableHash(dayIdentity)
      )
      let firstGap = gapMinutes(for: daySeed)
      let secondGap = gapMinutes(for: mix(daySeed))
      let times = [
        firstPromptMinutes,
        firstPromptMinutes + firstGap,
        firstPromptMinutes + firstGap + secondGap
      ]
      let firstMessage = Int(
        mix(daySeed ^ 0xD1B54A32D192ED03) % UInt64(messages.count)
      )

      return times.enumerated().compactMap { index, time in
        guard let fireDate = calendar.date(
          bySettingHour: time / 60,
          minute: time % 60,
          second: 0,
          of: localDay
        ), fireDate > now else { return nil }
        let messageIndex = (firstMessage + index * 4) % messages.count
        return ReflectionNotificationPlan(
          identifier: "calendar-agent-reflection-v3-\(dayIdentity)-\(index)",
          year: year,
          month: month,
          day: day,
          minutesAfterMidnight: time,
          message: messages[messageIndex]
        )
      }
    }
  }

  private static func gapMinutes(for value: UInt64) -> Int {
    value & 1 == 0 ? 40 : 60
  }

  private static func stableHash(_ value: String) -> UInt64 {
    value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }

  private static func mix(_ input: UInt64) -> UInt64 {
    var value = input &+ 0x9E3779B97F4A7C15
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
    return value ^ (value >> 31)
  }
}

@MainActor
final class NotificationService: ObservableObject {
  static let legacyIdentifier = "calendar-agent-evening-review"
  static let managedIdentifierPrefix = "calendar-agent-reflection-"

  @Published private(set) var authorizationStatus: UNAuthorizationStatus =
    .notDetermined

  private let center: any NotificationScheduling
  private let now: () -> Date
  private let calendar: Calendar

  init(
    center: (any NotificationScheduling)? = nil,
    now: @escaping () -> Date = { Date() },
    calendar: Calendar = .current
  ) {
    self.center = center ?? UNUserNotificationCenter.current()
    self.now = now
    self.calendar = calendar
  }

  func refreshStatus() async {
    authorizationStatus = await center.currentAuthorizationStatus()
  }

  func configureDailyReview(enabled: Bool, seed: UUID) async throws {
    let plans = ReflectionNotificationPlanner.plans(
      seed: seed,
      now: now(),
      calendar: calendar
    )
    let pending = await center.pendingNotificationIdentifiers()
    let identifiers = pending.filter(Self.isManagedIdentifier)
    if !enabled {
      center.removePendingNotificationRequests(
        withIdentifiers: Array(identifiers)
      )
      await refreshStatus()
      AppLogger.notifications.info(
        "Accountability notification schedule disabled"
      )
      return
    }

    let granted = try await center.requestAuthorization(
      options: [.alert, .sound]
    )
    guard granted else {
      await refreshStatus()
      throw NotificationConfigurationError.denied
    }

    center.removePendingNotificationRequests(
      withIdentifiers: Array(identifiers)
    )
    do {
      for plan in plans {
        try await center.add(Self.request(for: plan))
      }
    } catch {
      center.removePendingNotificationRequests(
        withIdentifiers: plans.map(\.identifier)
      )
      AppLogger.notifications.error(
        "Accountability notification scheduling failed; planned_count=\(plans.count, privacy: .public)"
      )
      throw error
    }
    await refreshStatus()
    AppLogger.notifications.info(
      "Accountability notification schedule configured; request_count=\(plans.count, privacy: .public) max_per_day=\(ReflectionNotificationPlanner.promptsPerDay, privacy: .public)"
    )
  }

  func ensureDailyReview(enabled: Bool, seed: UUID) async throws {
    let plans = ReflectionNotificationPlanner.plans(
      seed: seed,
      now: now(),
      calendar: calendar
    )
    let pending = await center.pendingNotificationIdentifiers()
    let managedPending = pending.filter(Self.isManagedIdentifier)
    guard enabled else {
      center.removePendingNotificationRequests(
        withIdentifiers: Array(managedPending)
      )
      return
    }

    let status = await center.currentAuthorizationStatus()
    authorizationStatus = status
    guard Self.canSchedule(status) else {
      if status == .notDetermined {
        try await configureDailyReview(enabled: true, seed: seed)
        return
      }
      throw NotificationConfigurationError.denied
    }

    let expected = Set(plans.map(\.identifier))
    guard expected == managedPending else {
      try await configureDailyReview(enabled: true, seed: seed)
      return
    }
    AppLogger.notifications.debug(
      "Accountability notification schedule already complete; request_count=\(expected.count, privacy: .public)"
    )
  }

  private static func isManagedIdentifier(_ identifier: String) -> Bool {
    identifier == legacyIdentifier
      || identifier.hasPrefix(managedIdentifierPrefix)
  }

  private static func request(
    for plan: ReflectionNotificationPlan
  ) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = plan.message.title
    content.body = plan.message.body
    content.sound = .default
    content.threadIdentifier = "calendar-agent-reflection"

    var components = DateComponents()
    components.year = plan.year
    components.month = plan.month
    components.day = plan.day
    components.hour = plan.hour
    components.minute = plan.minute
    let trigger = UNCalendarNotificationTrigger(
      dateMatching: components,
      repeats: false
    )
    return UNNotificationRequest(
      identifier: plan.identifier,
      content: content,
      trigger: trigger
    )
  }

  private static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .provisional, .ephemeral:
      true
    case .notDetermined, .denied:
      false
    @unknown default:
      false
    }
  }
}
