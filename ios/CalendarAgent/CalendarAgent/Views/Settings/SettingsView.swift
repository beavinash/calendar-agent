import SwiftUI
import UIKit

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var calendarService: CalendarService
  @EnvironmentObject private var notificationService: NotificationService
  @State private var appSecretInput = ""
  @State private var statusMessage: String?
  @State private var backendStatus: BackendStatus?
  @State private var backendConnectionMessage: String?
  @State private var backendConnectionFailed = false
  @State private var isCheckingBackend = false

  var body: some View {
    Form {
      calendarSection
      focusSection
      planningSection
      advancedSection
    }
    .navigationTitle("Settings")
    .task {
      calendarService.refreshCalendars()
      if !calendarService.accessState.canRead {
        settings.revokeAutomaticScheduling()
      } else if let authorized =
                  settings.autoScheduleCalendarIdentifier,
                calendarService.defaultWritableCalendar?.id != authorized {
        settings.revokeAutomaticScheduling()
      }
      await notificationService.refreshStatus()
    }
    .alert(
      "Settings",
      isPresented: Binding(
        get: { statusMessage != nil },
        set: { if !$0 { statusMessage = nil } }
      )
    ) {
      Button("OK") { statusMessage = nil }
    } message: {
      Text(statusMessage ?? "")
    }
  }

  private var aiSection: some View {
    Section("Hosted AI Backend") {
      LabeledContent("Provider", value: "OpenAI · server managed")
      LabeledContent(
        "Model",
        value: backendStatus?.model ?? "Configured by backend"
      )
      TextField("Backend HTTPS URL", text: $settings.apiBaseURLString)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onChange(of: settings.apiBaseURLString) {
          resetBackendConnectionStatus()
        }

      SecureField(
        settings.hasAppSecret
          ? "Deployment app secret is stored"
          : "Deployment app secret",
        text: $appSecretInput
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      HStack {
        Button("Save app secret") { saveAppSecret() }
          .disabled(appSecretInput.isEmpty)
        if settings.hasAppSecret {
          Button("Remove", role: .destructive) { removeAppSecret() }
        }
      }

      Button {
        Task { await verifyBackendConnection() }
      } label: {
        if isCheckingBackend {
          HStack {
            ProgressView()
            Text("Verifying secure connection")
          }
        } else {
          Label("Verify secure connection", systemImage: "checkmark.shield")
        }
      }
      .disabled(
        isCheckingBackend
          || settings.apiBaseURL == nil
          || (!settings.hasAppSecret && backendCredentialRequired)
      )

      if let backendConnectionMessage {
        Label(
          backendConnectionMessage,
          systemImage: backendConnectionFailed
            ? "exclamationmark.triangle" : "checkmark.circle"
        )
        .font(.caption)
        .foregroundStyle(
          backendConnectionFailed
            ? Color.CalendarAgent.warning
            : Color.CalendarAgent.success
        )
      }

      if let backendStatus {
        LabeledContent(
          "Audit storage",
          value: backendStatus.auditPersistenceEnabled
            ? "Enabled" : "Stateless"
        )
      }

      Text(
        "The OpenAI API key and model stay on the backend. This iPhone sends only its deployment app secret. The connection check sends no calendar or chat content."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if !settings.apiBaseURLString.isEmpty && settings.apiBaseURL == nil {
        Text(
          "A physical iPhone requires an HTTPS backend. Simulator development may use localhost."
        )
        .font(.caption)
        .foregroundStyle(Color.CalendarAgent.warning)
      }

      if let issue = settings.secureStorageIssue {
        Label(issue, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(Color.CalendarAgent.warning)
      }
    }
  }

  private var privacySection: some View {
    Section("AI Data Sharing") {
      Toggle("I consent to sending selected context", isOn: $settings.aiDataConsent)
      Text(
        "An explicit analysis sends event titles, times, your Complete/Incomplete input, and the ranked missed-pattern counts shown on \(AppBrand.name). Planning-only requests send future busy times without titles. Locations, attendees, event notes, calendar account names, iCloud credentials, and Keychain values are never sent."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var calendarSection: some View {
    Section("Apple Calendar") {
      HStack {
        Label("Access", systemImage: "calendar")
        Spacer()
        Text(accessLabel)
          .foregroundStyle(
            calendarService.accessState.canRead
              ? Color.CalendarAgent.success
              : Color.secondary
          )
      }
      if !calendarService.accessState.canRead {
        if calendarService.accessState == .denied
          || calendarService.accessState == .restricted {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open iOS Settings", destination: url)
          }
        } else {
          Button("Grant full Calendar access") {
            Task { await requestCalendarAccess() }
          }
        }
      } else {
        LabeledContent(
          "Analysis scope",
          value: "All non-holiday calendars"
        )
        if let destination = calendarService.defaultWritableCalendar {
          LabeledContent(
            "New events go to",
            value: "\(destination.title) · \(destination.accountTitle)"
          )
        } else {
          Label(
            "No writable default calendar is available",
            systemImage: "calendar.badge.exclamationmark"
          )
          .foregroundStyle(.secondary)
        }

        Text(
          "The coach shows a confirmation button before adding a suggested batch to your normal default Apple Calendar."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Text(
        "Reviews read events across every accessible Apple Calendar except holiday calendars, then compare them with the calendar categories selected below. No separate calendar is created."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var focusSection: some View {
    Section("Calendar Categories") {
      ForEach(FocusArea.allCases) { area in
        Button {
          settings.toggleFocusArea(area)
        } label: {
          HStack {
            Label(area.title, systemImage: area.icon)
              .foregroundStyle(area.color)
            Spacer()
            Image(
              systemName: settings.selectedFocusAreas.contains(area)
                ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(
              settings.selectedFocusAreas.contains(area)
                ? area.color : Color.secondary
            )
          }
        }
        .buttonStyle(.plain)
      }
      Text("At least one calendar category must remain enabled.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var planningSection: some View {
    Section("Planning Boundaries") {
      Stepper(
        "Morning starts at \(settings.dayStartHour):00",
        value: $settings.dayStartHour,
        in: 4...7
      )
      LabeledContent("Morning ends", value: "8:00 AM")
      LabeledContent("Evening starts", value: "5:30 PM")
      Stepper(
        "Evening ends at \(settings.dayEndHour):00",
        value: $settings.dayEndHour,
        in: 18...23
      )
      Stepper(
        "\(settings.minimumBreakMinutes)-minute transition buffer",
        value: $settings.minimumBreakMinutes,
        in: 0...60,
        step: 5
      )
      Text(
        "Weekdays use the morning window before 8:00 AM and the evening window from 5:30 PM. Weekends allow 6:00 AM–11:00 PM with 1–2 hour focus blocks."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(
        "Protected meals: breakfast 7:45–8:15 AM, lunch 11:30 AM–12:00 PM, and dinner 7:00–7:30 PM."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var reminderSection: some View {
    Section("Accountability") {
      Toggle(
        "Evening accountability prompts",
        isOn: $settings.notificationsEnabled
      )
        .onChange(of: settings.notificationsEnabled) { _, enabled in
          Task {
            do {
              try await notificationService.configureDailyReview(
                enabled: enabled,
                seed: settings.deviceID
              )
            } catch {
              settings.notificationsEnabled = false
              statusMessage = error.localizedDescription
            }
          }
        }
      Text(
        "Up to three prompts each evening, beginning at 7:30 PM. Later prompts vary by 40 or 60 minutes and continue when the app is closed."
      )
        .font(.caption)
        .foregroundStyle(.secondary)
      if notificationService.authorizationStatus == .denied {
        Text(
          "Notifications are disabled for \(AppBrand.name). Re-enable them in the iPhone Settings app to receive accountability prompts."
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
  }

  private var advancedICloudSection: some View {
    Section("Do I need a second iCloud account?") {
      Text(
        "No. Authorized blocks are written to your normal default Apple Calendar, so they appear without invitations or a separate account."
      )
      Text(
        "A separate account is only for a future always-on organizer that must send real invitations while this app is not running. EventKit cannot add attendees programmatically."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var advancedSection: some View {
    Section {
      NavigationLink("Advanced settings") {
        Form {
          aiSection
          privacySection
          reminderSection
          advancedICloudSection
        }
        .navigationTitle("Advanced")
      }
    }
  }

  private var accessLabel: String {
    switch calendarService.accessState {
    case .notDetermined:
      "Not requested"
    case .restricted:
      "Restricted"
    case .denied:
      "Denied"
    case .writeOnly:
      "Write only"
    case .fullAccess:
      "Full access"
    }
  }

  private var backendCredentialRequired: Bool {
    guard let baseURL = settings.apiBaseURL else { return true }
    return AppConfiguration.requiresDeploymentCredential(for: baseURL)
  }

  private func saveAppSecret() {
    do {
      try settings.saveAppSecret(appSecretInput)
      appSecretInput = ""
      resetBackendConnectionStatus()
      statusMessage = "The app secret is stored in device-only Keychain."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  private func removeAppSecret() {
    do {
      try settings.saveAppSecret("")
      appSecretInput = ""
      resetBackendConnectionStatus()
      statusMessage = "The app secret was removed."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  private func requestCalendarAccess() async {
    do {
      try await calendarService.requestFullAccess()
      statusMessage = "Apple Calendar access is connected."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  private func verifyBackendConnection() async {
    guard let baseURL = settings.apiBaseURL else {
      backendStatus = nil
      backendConnectionFailed = true
      backendConnectionMessage = AppError.invalidServerURL.localizedDescription
      return
    }

    let appSecret: String?
    do {
      let storedSecret = try settings.appSecret()
      if (storedSecret == nil || storedSecret?.isEmpty == true)
        && AppConfiguration.requiresDeploymentCredential(for: baseURL) {
        backendStatus = nil
        backendConnectionFailed = true
        backendConnectionMessage =
          AppError.backendCredentialRequired.localizedDescription
        return
      }
      appSecret = storedSecret
    } catch {
      backendStatus = nil
      backendConnectionFailed = true
      backendConnectionMessage = error.localizedDescription
      return
    }

    isCheckingBackend = true
    backendStatus = nil
    backendConnectionMessage = nil
    backendConnectionFailed = false
    defer { isCheckingBackend = false }

    do {
      let status = try await URLSessionHTTPClient(
        baseURL: baseURL
      ).checkStatus(appSecret: appSecret)
      backendStatus = status
      backendConnectionMessage = "Connected securely to the OpenAI backend."
      AppLogger.network.info(
        "Settings backend verification succeeded; provider=openai byok_enabled=false"
      )
    } catch {
      backendStatus = nil
      backendConnectionFailed = true
      backendConnectionMessage = error.localizedDescription
      let nsError = error as NSError
      AppLogger.network.error(
        "Settings backend verification failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
    }
  }

  private func resetBackendConnectionStatus() {
    backendStatus = nil
    backendConnectionMessage = nil
    backendConnectionFailed = false
  }

}
