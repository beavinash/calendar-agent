import SwiftUI
import UIKit
import XCTest
@testable import CalendarAgent

final class AppThemeContrastTests: XCTestCase {
  func testTextColorsMeetContrastInLightAndDarkAppearances() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      assertContrast(
        Color.CalendarAgent.ink,
        Color.CalendarAgent.background,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.ink,
        Color.CalendarAgent.surface,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.accent,
        Color.CalendarAgent.background,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.accent,
        Color.CalendarAgent.surface,
        style: style,
        minimum: 4.5
      )
    }
  }

  func testSemanticFilledControlsMeetContrastInBothAppearances() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      assertContrast(
        Color.CalendarAgent.onAccentFill,
        Color.CalendarAgent.accentFill,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.onCompleteFill,
        Color.CalendarAgent.completeFill,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.onIncompleteFill,
        Color.CalendarAgent.incompleteFill,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.success,
        Color.CalendarAgent.surface,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.warning,
        Color.CalendarAgent.surface,
        style: style,
        minimum: 4.5
      )
      assertContrast(
        Color.CalendarAgent.controlOutline,
        Color.CalendarAgent.surface,
        style: style,
        minimum: 3
      )
      assertContrast(
        Color.CalendarAgent.accentFill,
        Color.CalendarAgent.surface,
        style: style,
        minimum: 3
      )
    }
  }

  func testFocusAreaLabelColorsMeetTextContrast() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      for area in FocusArea.allCases {
        assertContrast(
          area.color,
          Color.CalendarAgent.surface,
          style: style,
          minimum: 4.5
        )
        assertContrast(
          area.color,
          Color.CalendarAgent.background,
          style: style,
          minimum: 4.5
        )
      }
    }
  }

  private func assertContrast(
    _ foreground: Color,
    _ background: Color,
    style: UIUserInterfaceStyle,
    minimum: Double,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let foregroundLuminance = luminance(
      resolved(foreground, style: style)
    )
    let backgroundLuminance = luminance(
      resolved(background, style: style)
    )
    let ratio = (
      max(foregroundLuminance, backgroundLuminance) + 0.05
    ) / (
      min(foregroundLuminance, backgroundLuminance) + 0.05
    )
    XCTAssertGreaterThanOrEqual(
      ratio,
      minimum,
      "Contrast \(ratio) is below \(minimum) for \(style.rawValue)",
      file: file,
      line: line
    )
  }

  private func resolved(
    _ color: Color,
    style: UIUserInterfaceStyle
  ) -> UIColor {
    UIColor(color).resolvedColor(
      with: UITraitCollection(userInterfaceStyle: style)
    )
  }

  private func luminance(_ color: UIColor) -> Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    XCTAssertTrue(
      color.getRed(
        &red,
        green: &green,
        blue: &blue,
        alpha: &alpha
      )
    )
    return 0.2126 * linear(red)
      + 0.7152 * linear(green)
      + 0.0722 * linear(blue)
  }

  private func linear(_ component: CGFloat) -> Double {
    let value = Double(component)
    return value <= 0.04045
      ? value / 12.92
      : pow((value + 0.055) / 1.055, 2.4)
  }
}
