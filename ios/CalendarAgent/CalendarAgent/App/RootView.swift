import SwiftUI

enum RootTab: CaseIterable, Hashable {
  case coach
  case progress

  static let defaultTab: RootTab = .coach

  var title: String {
    switch self {
    case .coach:
      AppBrand.name
    case .progress:
      "Progress"
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var coachSession: CoachSessionController
  @State private var selectedTab = RootTab.defaultTab

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack {
        CoachView()
          .id(coachSession.activeSessionId)
          .toolbar {
            settingsToolbarItem
          }
      }
      .tabItem {
        Label(
          RootTab.coach.title,
          systemImage: "bubble.left.and.bubble.right.fill"
        )
      }
      .tag(RootTab.coach)

      NavigationStack {
        ProgressViewScreen()
          .toolbar {
            settingsToolbarItem
          }
      }
      .tabItem {
        Label(
          RootTab.progress.title,
          systemImage: "chart.line.uptrend.xyaxis"
        )
      }
      .tag(RootTab.progress)
    }
  }

  private var settingsToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      NavigationLink {
        SettingsView()
      } label: {
        Image(systemName: "gearshape")
      }
      .accessibilityLabel("Settings")
    }
  }
}
