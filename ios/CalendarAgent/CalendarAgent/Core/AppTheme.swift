import SwiftUI

extension Color {
  enum CalendarAgent {
    static let background = Color(
      light: Color(red: 0.965, green: 0.95, blue: 0.91),
      dark: Color(red: 0.08, green: 0.075, blue: 0.065)
    )
    static let surface = Color(
      light: Color(red: 0.99, green: 0.985, blue: 0.965),
      dark: Color(red: 0.14, green: 0.13, blue: 0.115)
    )
    static let ink = Color(
      light: Color(red: 0.12, green: 0.105, blue: 0.08),
      dark: Color(red: 0.94, green: 0.92, blue: 0.86)
    )
    static let accent = Color(
      light: Color(red: 0.32, green: 0.25, blue: 0.12),
      dark: Color(red: 0.878, green: 0.749, blue: 0.42)
    )
    static let accentFill = Color(
      light: Color(red: 0.32, green: 0.25, blue: 0.12),
      dark: Color(red: 0.702, green: 0.525, blue: 0.188)
    )
    static let onAccentFill = Color(
      light: .white,
      dark: Color(red: 0.078, green: 0.071, blue: 0.059)
    )
    static let controlOutline = Color(
      light: Color(red: 0.467, green: 0.443, blue: 0.373),
      dark: Color(red: 0.514, green: 0.49, blue: 0.42)
    )
    static let cardOutline = Color(
      light: Color(red: 0.78, green: 0.75, blue: 0.67),
      dark: Color(red: 0.32, green: 0.30, blue: 0.26)
    )
    static let completeFill = Color(
      light: Color(red: 0.09, green: 0.478, blue: 0.243),
      dark: Color(red: 0.467, green: 0.851, blue: 0.604)
    )
    static let onCompleteFill = Color(
      light: .white,
      dark: Color(red: 0.063, green: 0.129, blue: 0.086)
    )
    static let incompleteFill = Color(
      light: Color(red: 0.612, green: 0.294, blue: 0),
      dark: Color(red: 1, green: 0.69, blue: 0.392)
    )
    static let onIncompleteFill = Color(
      light: .white,
      dark: Color(red: 0.141, green: 0.075, blue: 0.012)
    )
    static let success = completeFill
    static let warning = incompleteFill
    static let focusWork = Color(
      light: Color(red: 0.25, green: 0.20, blue: 0.55),
      dark: Color(red: 0.72, green: 0.68, blue: 1)
    )
    static let focusStudy = Color(
      light: Color(red: 0, green: 0.32, blue: 0.58),
      dark: Color(red: 0.48, green: 0.77, blue: 1)
    )
    static let focusExercise = success
    static let focusAppointments = warning
    static let focusErrands = Color(
      light: Color(red: 0.42, green: 0.16, blue: 0.56),
      dark: Color(red: 0.82, green: 0.64, blue: 1)
    )
  }

  init(light: Color, dark: Color) {
    self.init(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(dark)
        : UIColor(light)
    })
  }
}

struct SurfaceCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.CalendarAgent.surface)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.CalendarAgent.cardOutline, lineWidth: 1)
      }
  }
}

struct CalendarAgentFilledButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  let fill: Color
  let foreground: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        isEnabled ? foreground : Color.CalendarAgent.ink
      )
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(minHeight: 36)
      .background(
        isEnabled ? fill : Color.CalendarAgent.surface
      )
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(
            isEnabled ? Color.clear : Color.CalendarAgent.controlOutline,
            lineWidth: 1
          )
      }
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.88 : 1)
      .animation(
        .easeOut(duration: 0.12),
        value: configuration.isPressed
      )
  }
}

extension View {
  func calendarAgentProminentActionStyle() -> some View {
    buttonStyle(
      CalendarAgentFilledButtonStyle(
        fill: Color.CalendarAgent.accentFill,
        foreground: Color.CalendarAgent.onAccentFill
      )
    )
  }
}
