import Foundation

@MainActor
final class AppSettings: ObservableObject {
  private static let legacyProviderAPIKeys = [
    "providerAPIKey.openai",
    "providerAPIKey.gemini"
  ]

  private enum Key {
    static let apiBaseURL = "apiBaseURL"
    static let includeRecentNotes = "includeRecentNotes"
    static let aiConsent = "aiConsent"
    static let autoSchedule = "autoSchedule"
    static let autoScheduleCalendar = "autoScheduleCalendar"
    static let autoScheduleVersion = "autoScheduleVersion"
    static let dayStart = "dayStart"
    static let dayEnd = "dayEnd"
    static let maxBlocks = "maxBlocks"
    static let breakMinutes = "breakMinutes"
    static let focusAreas = "focusAreas"
    static let notifications = "notifications"
    static let appSecret = "appSharedSecret"
    static let deviceID = "installationDeviceID"
    static let trackingStartedAt = "trackingStartedAt"
  }

  private let defaults: UserDefaults
  private let secureStore: SecureStore

  @Published var apiBaseURLString: String {
    didSet {
      defaults.set(apiBaseURLString, forKey: Key.apiBaseURL)
      AppLogger.persistence.debug("API base URL setting changed")
    }
  }
  @Published var includeRecentNotes: Bool {
    didSet {
      defaults.set(includeRecentNotes, forKey: Key.includeRecentNotes)
    }
  }
  @Published var aiDataConsent: Bool {
    didSet {
      defaults.set(aiDataConsent, forKey: Key.aiConsent)
      AppLogger.persistence.info(
        "AI data consent changed; enabled=\(self.aiDataConsent, privacy: .public)"
      )
    }
  }
  @Published private(set) var autoScheduleEnabled: Bool
  @Published private(set) var autoScheduleCalendarIdentifier: String?
  @Published var dayStartHour: Int {
    didSet { defaults.set(dayStartHour, forKey: Key.dayStart) }
  }
  @Published var dayEndHour: Int {
    didSet { defaults.set(dayEndHour, forKey: Key.dayEnd) }
  }
  @Published var maxDailyBlocks: Int {
    didSet { defaults.set(maxDailyBlocks, forKey: Key.maxBlocks) }
  }
  @Published var minimumBreakMinutes: Int {
    didSet { defaults.set(minimumBreakMinutes, forKey: Key.breakMinutes) }
  }
  @Published var selectedFocusAreas: Set<FocusArea> {
    didSet {
      defaults.set(
        selectedFocusAreas.map(\.rawValue),
        forKey: Key.focusAreas
      )
    }
  }
  @Published var notificationsEnabled: Bool {
    didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
  }
  @Published private(set) var hasAppSecret = false
  @Published private(set) var secureStorageIssue: String?

  let morningEndMinutes = 8 * 60
  let eveningStartMinutes = 17 * 60 + 30
  let deviceID: UUID
  @Published private(set) var trackingStartedAt: Date

  init(
    defaults: UserDefaults = .standard,
    secureStore: SecureStore = KeychainSecureStore(),
    now: () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.secureStore = secureStore

    apiBaseURLString = defaults.string(forKey: Key.apiBaseURL)
      ?? AppConfiguration.defaultAPIBaseURLString
    includeRecentNotes = defaults.bool(forKey: Key.includeRecentNotes)
    aiDataConsent = defaults.bool(forKey: Key.aiConsent)
    let storedAutoScheduleCalendar = defaults.string(
      forKey: Key.autoScheduleCalendar
    )
    let restoredAutoSchedule = defaults.bool(forKey: Key.autoSchedule)
      && storedAutoScheduleCalendar != nil
      && defaults.integer(forKey: Key.autoScheduleVersion) == 2
    autoScheduleCalendarIdentifier = restoredAutoSchedule
      ? storedAutoScheduleCalendar : nil
    autoScheduleEnabled = restoredAutoSchedule
    let storedDayStart = defaults.object(forKey: Key.dayStart) == nil
      ? 6 : defaults.integer(forKey: Key.dayStart)
    dayStartHour = min(max(storedDayStart, 4), 7)
    let storedDayEnd = defaults.object(forKey: Key.dayEnd) == nil
      ? 23 : defaults.integer(forKey: Key.dayEnd)
    dayEndHour = min(max(storedDayEnd, 18), 23)
    maxDailyBlocks = defaults.object(forKey: Key.maxBlocks) == nil
      ? 5 : min(max(defaults.integer(forKey: Key.maxBlocks), 1), 5)
    minimumBreakMinutes = defaults.object(forKey: Key.breakMinutes) == nil
      ? 10 : defaults.integer(forKey: Key.breakMinutes)
    let storedFocus = defaults.stringArray(forKey: Key.focusAreas) ?? []
    let focusAreas = Set(storedFocus.compactMap(FocusArea.init(rawValue:)))
    selectedFocusAreas = focusAreas.isEmpty ? Set(FocusArea.allCases) : focusAreas
    notificationsEnabled = defaults.bool(forKey: Key.notifications)
    if let storedTrackingStart = defaults.object(
      forKey: Key.trackingStartedAt
    ) as? Date {
      trackingStartedAt = storedTrackingStart
      AppLogger.persistence.debug("Restored the calendar tracking start date")
    } else {
      let trackingStart = now()
      trackingStartedAt = trackingStart
      defaults.set(trackingStart, forKey: Key.trackingStartedAt)
      AppLogger.persistence.info("Registered the calendar tracking start date")
    }

    var resolvedDeviceID = UUID()
    var initializationIssue: String?
    do {
      if let stored = try secureStore.read(Key.deviceID),
         let parsed = UUID(uuidString: stored) {
        resolvedDeviceID = parsed
      } else {
        try secureStore.save(
          resolvedDeviceID.uuidString,
          for: Key.deviceID
        )
      }
    } catch {
      initializationIssue = error.localizedDescription
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Installation identity initialization failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
    }
    do {
      for key in Self.legacyProviderAPIKeys {
        try secureStore.delete(key)
      }
      AppLogger.persistence.info(
        "Legacy runtime provider credentials removed for hosted mode"
      )
    } catch {
      if initializationIssue == nil {
        initializationIssue = error.localizedDescription
      }
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Legacy provider credential cleanup failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
    }
    deviceID = resolvedDeviceID
    if !restoredAutoSchedule {
      defaults.set(false, forKey: Key.autoSchedule)
      defaults.removeObject(forKey: Key.autoScheduleCalendar)
    }
    refreshAppSecretState()
    if secureStorageIssue == nil {
      secureStorageIssue = initializationIssue
    }
    AppLogger.persistence.info(
      "Settings initialized; consent=\(self.aiDataConsent, privacy: .public) automatic_scheduling=\(self.autoScheduleEnabled, privacy: .public)"
    )
  }

  var apiBaseURL: URL? {
    AppConfiguration.normalizedAPIBaseURL(
      from: apiBaseURLString,
      allowInsecureLoopback: AppConfiguration.allowsInsecureLoopback
    )
  }

  func restartTracking(at timestamp: Date) {
    trackingStartedAt = timestamp
    defaults.set(timestamp, forKey: Key.trackingStartedAt)
    AppLogger.persistence.info("Calendar tracking baseline restarted")
  }

  func saveAppSecret(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    AppLogger.persistence.debug("Updating app secret in secure storage")
    do {
      if trimmed.isEmpty {
        try secureStore.delete(Key.appSecret)
      } else {
        try secureStore.save(trimmed, for: Key.appSecret)
      }
      refreshAppSecretState()
      AppLogger.persistence.info(
        "App secret state updated; configured=\(self.hasAppSecret, privacy: .public)"
      )
    } catch {
      let nsError = error as NSError
      AppLogger.persistence.error(
        "App secret update failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw error
    }
  }

  func appSecret() throws -> String? {
    try secureStore.read(Key.appSecret)
  }

  func toggleFocusArea(_ area: FocusArea) {
    if selectedFocusAreas.contains(area) {
      guard selectedFocusAreas.count > 1 else { return }
      selectedFocusAreas.remove(area)
    } else {
      selectedFocusAreas.insert(area)
    }
  }

  func authorizeAutomaticScheduling(calendarIdentifier: String) {
    autoScheduleCalendarIdentifier = calendarIdentifier
    autoScheduleEnabled = true
    defaults.set(calendarIdentifier, forKey: Key.autoScheduleCalendar)
    defaults.set(true, forKey: Key.autoSchedule)
    defaults.set(2, forKey: Key.autoScheduleVersion)
    AppLogger.scheduling.info("Automatic scheduling authorization enabled")
  }

  func revokeAutomaticScheduling() {
    autoScheduleEnabled = false
    autoScheduleCalendarIdentifier = nil
    defaults.set(false, forKey: Key.autoSchedule)
    defaults.removeObject(forKey: Key.autoScheduleCalendar)
    defaults.removeObject(forKey: Key.autoScheduleVersion)
    AppLogger.scheduling.info("Automatic scheduling authorization revoked")
  }

  func timeString(hour: Int) -> String {
    timeString(totalMinutes: hour * 60)
  }

  func timeString(totalMinutes: Int) -> String {
    let hour = totalMinutes / 60
    let minute = totalMinutes % 60
    return String(format: "%02d:%02d:00", hour, minute)
  }

  private func refreshAppSecretState() {
    do {
      hasAppSecret = try secureStore.read(Key.appSecret) != nil
      secureStorageIssue = nil
      AppLogger.persistence.debug(
        "Secure app credential state refreshed; configured=\(self.hasAppSecret, privacy: .public)"
      )
    } catch {
      secureStorageIssue = error.localizedDescription
      let nsError = error as NSError
      AppLogger.persistence.error(
        "Secure setting state refresh failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
    }
  }

}
