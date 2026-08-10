import SwiftData
import SwiftUI

@main
struct CalendarAgentApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var settings = AppSettings()
  @StateObject private var calendarService = CalendarService()
  @StateObject private var notificationService = NotificationService()
  @StateObject private var coachSession = CoachSessionController()
  @State private var launchErrorMessage: String?

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(settings)
        .environmentObject(calendarService)
        .environmentObject(notificationService)
        .environmentObject(coachSession)
        .tint(Color.CalendarAgent.accent)
        .onChange(of: scenePhase, initial: true) { _, phase in
          Task { @MainActor in
            await Task.yield()
            guard scenePhase == phase else { return }
            handleScenePhase(phase)
          }
        }
        .alert(
          "Calendar",
          isPresented: Binding(
            get: { launchErrorMessage != nil },
            set: { if !$0 { launchErrorMessage = nil } }
          )
        ) {
          Button("OK") { launchErrorMessage = nil }
        } message: {
          Text(launchErrorMessage ?? "")
        }
    }
    .modelContainer(
      for: [
        NoteRecord.self,
        ChatMessageRecord.self,
        CheckInRecord.self,
        CalendarAuditRecord.self,
        CalendarEventCompletionRecord.self,
        IncompleteEventRescheduleRecord.self,
        PendingCalendarProposalRecord.self
      ]
    )
  }

  private func handleScenePhase(_ phase: ScenePhase) {
    switch phase {
    case .active:
      AppLogger.lifecycle.info("App scene became active")
      let didRotateSession = coachSession.recordActiveTransition()
      AppLogger.coach.debug(
        "Active transition processed; session_rotated=\(didRotateSession, privacy: .public)"
      )
      refreshCalendarFromSystem()
      Task {
        AppLogger.lifecycle.debug("Refreshing notification authorization state")
        await notificationService.refreshStatus()
        do {
          try await notificationService.ensureDailyReview(
            enabled: settings.notificationsEnabled,
            seed: settings.deviceID
          )
        } catch {
          let nsError = error as NSError
          AppLogger.notifications.error(
            "Accountability notification repair failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
          )
          settings.notificationsEnabled = false
        }
        AppLogger.lifecycle.debug("Notification authorization refresh completed")
      }
    case .background:
      AppLogger.lifecycle.info("App scene entered background")
      coachSession.recordBackgroundTransition()
    case .inactive:
      AppLogger.lifecycle.debug("App scene became inactive")
      break
    @unknown default:
      AppLogger.lifecycle.error("App received an unknown scene phase")
      break
    }
  }

  private func refreshCalendarFromSystem() {
    AppLogger.calendar.debug("Starting foreground Apple Calendar refresh")
    do {
      try calendarService.refreshFromSystem()
      launchErrorMessage = nil
      AppLogger.calendar.info(
        "Apple Calendar refresh completed; can_read=\(self.calendarService.accessState.canRead, privacy: .public)"
      )
      if !calendarService.accessState.canRead {
        AppLogger.scheduling.info(
          "Revoking automatic scheduling because calendar read access is unavailable"
        )
        settings.revokeAutomaticScheduling()
      } else if let authorized =
                  settings.autoScheduleCalendarIdentifier,
                calendarService.defaultWritableCalendar?.id != authorized {
        AppLogger.scheduling.info(
          "Revoking automatic scheduling because the writable calendar changed"
        )
        settings.revokeAutomaticScheduling()
      }
    } catch {
      let nsError = error as NSError
      AppLogger.calendar.error(
        "Apple Calendar refresh failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      launchErrorMessage = error.localizedDescription
    }
  }
}
