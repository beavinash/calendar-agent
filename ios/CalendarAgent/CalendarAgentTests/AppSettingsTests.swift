import XCTest
@testable import CalendarAgent

private final class FakeSecureStore: SecureStore {
  var values: [String: String] = [:]
  private(set) var readKeys: [String] = []

  func save(_ value: String, for key: String) throws {
    values[key] = value
  }

  func read(_ key: String) throws -> String? {
    readKeys.append(key)
    return values[key]
  }

  func delete(_ key: String) throws {
    values.removeValue(forKey: key)
  }
}

@MainActor
final class AppSettingsTests: XCTestCase {
  func testTrackingStartDateIsRegisteredOnce() {
    let suite = "AppSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstStart = Date(timeIntervalSince1970: 1_750_000_000)
    let laterStart = firstStart.addingTimeInterval(86_400)

    let firstSettings = AppSettings(
      defaults: defaults,
      secureStore: FakeSecureStore(),
      now: { firstStart }
    )
    let reloadedSettings = AppSettings(
      defaults: defaults,
      secureStore: FakeSecureStore(),
      now: { laterStart }
    )

    XCTAssertEqual(firstSettings.trackingStartedAt, firstStart)
    XCTAssertEqual(reloadedSettings.trackingStartedAt, firstStart)
  }

  func testHostedSettingsNeverReadLegacyProviderKeyAndPersistAppCredential()
    throws {
    let suite = "AppSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let secureStore = FakeSecureStore()
    secureStore.values["providerAPIKey.openai"] = "legacy-openai-secret"
    let settings = AppSettings(
      defaults: defaults,
      secureStore: secureStore
    )

    XCTAssertFalse(secureStore.readKeys.contains("providerAPIKey.openai"))
    XCTAssertNil(secureStore.values["providerAPIKey.openai"])
    try settings.saveAppSecret("deployment-secret")
    XCTAssertEqual(try settings.appSecret(), "deployment-secret")
    XCTAssertTrue(settings.hasAppSecret)
    settings.includeRecentNotes = true
    settings.toggleFocusArea(.work)
    XCTAssertFalse(settings.selectedFocusAreas.contains(.work))

    let reloaded = AppSettings(
      defaults: defaults,
      secureStore: secureStore
    )
    XCTAssertFalse(reloaded.selectedFocusAreas.contains(.work))
    XCTAssertTrue(reloaded.includeRecentNotes)
    XCTAssertEqual(reloaded.deviceID, settings.deviceID)
    XCTAssertEqual(reloaded.maxDailyBlocks, 5)
    XCTAssertFalse(reloaded.autoScheduleEnabled)
  }

  func testLastFocusAreaCannotBeDisabled() {
    let suite = "AppSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set([FocusArea.work.rawValue], forKey: "focusAreas")
    let settings = AppSettings(
      defaults: defaults,
      secureStore: FakeSecureStore()
    )

    settings.toggleFocusArea(.work)

    XCTAssertEqual(settings.selectedFocusAreas, [.work])
  }

  func testServerURLNormalizesToAPIV1AndRejectsInsecureRemoteHosts() {
    let suite = "AppSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(10, forKey: "dayStart")
    defaults.set(24, forKey: "dayEnd")
    let settings = AppSettings(
      defaults: defaults,
      secureStore: FakeSecureStore()
    )

    settings.apiBaseURLString = "http://192.168.1.20:8000/api/v1"
    XCTAssertNil(settings.apiBaseURL)
    settings.apiBaseURLString = "https://planner.example.com/old/path?debug=true"
    XCTAssertEqual(
      settings.apiBaseURL?.absoluteString,
      "https://planner.example.com/api/v1"
    )
    XCTAssertEqual(settings.dayStartHour, 7)
    XCTAssertEqual(settings.dayEndHour, 23)
  }

  func testPhysicalDeviceRejectsLoopbackWhileSimulatorDevelopmentAllowsIt() {
    let rawValue = "http://127.0.0.1:8000"

    XCTAssertNil(
      AppConfiguration.normalizedAPIBaseURL(
        from: rawValue,
        allowInsecureLoopback: false
      )
    )
    XCTAssertEqual(
      AppConfiguration.normalizedAPIBaseURL(
        from: rawValue,
        allowInsecureLoopback: true
      )?.absoluteString,
      "http://127.0.0.1:8000/api/v1"
    )
  }

  func testDeploymentCredentialIsRequiredExceptForSimulatorLoopback() throws {
    let localURL = try XCTUnwrap(
      AppConfiguration.normalizedAPIBaseURL(
        from: "http://localhost:8000",
        allowInsecureLoopback: true
      )
    )
    let hostedURL = try XCTUnwrap(URL(string: "https://planner.example/api/v1"))

    XCTAssertFalse(
      AppConfiguration.requiresDeploymentCredential(for: localURL)
    )
    XCTAssertTrue(
      AppConfiguration.requiresDeploymentCredential(for: hostedURL)
    )
  }

  func testPlaceholderDeploymentURLIsTreatedAsUnconfigured() {
    XCTAssertEqual(
      AppConfiguration.configuredAPIBaseURLString(
        from: "https://api.example.com/api/v1",
        allowInsecureLoopback: false
      ),
      ""
    )
  }

  func testInvalidServerMessageExplainsPhysicalDeviceLoopback() {
    let message = AppError.invalidServerURL.localizedDescription

    XCTAssertTrue(message.contains("HTTPS backend"))
    XCTAssertTrue(message.contains("iPhone"))
    XCTAssertTrue(message.contains("Simulator"))
  }

  func testPlanningDefaultsUseSplitWindowsAndPersistAutoSchedule() {
    let suite = "AppSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let secureStore = FakeSecureStore()
    let settings = AppSettings(
      defaults: defaults,
      secureStore: secureStore
    )

    XCTAssertEqual(settings.dayStartHour, 6)
    XCTAssertEqual(settings.morningEndMinutes, 8 * 60)
    XCTAssertEqual(settings.eveningStartMinutes, 17 * 60 + 30)
    XCTAssertEqual(settings.dayEndHour, 23)
    XCTAssertEqual(settings.maxDailyBlocks, 5)

    settings.authorizeAutomaticScheduling(
      calendarIdentifier: "icloud-calendar"
    )
    let reloaded = AppSettings(
      defaults: defaults,
      secureStore: secureStore
    )
    XCTAssertTrue(reloaded.autoScheduleEnabled)
    XCTAssertEqual(
      reloaded.autoScheduleCalendarIdentifier,
      "icloud-calendar"
    )
    reloaded.revokeAutomaticScheduling()
    XCTAssertFalse(reloaded.autoScheduleEnabled)
    XCTAssertNil(reloaded.autoScheduleCalendarIdentifier)
  }

  func testDoesNotMigrateAnUnverifiedLegacyCalendar() {
    let suite = "AppSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("arbitrary-selection", forKey: "selectedCalendar")
    defaults.set("managed-calendar", forKey: "managedAgentCalendar")

    let settings = AppSettings(
      defaults: defaults,
      secureStore: FakeSecureStore()
    )

    XCTAssertFalse(settings.autoScheduleEnabled)
  }
}
