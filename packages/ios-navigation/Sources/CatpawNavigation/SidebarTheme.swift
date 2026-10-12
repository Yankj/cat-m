import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Defaults mirror the app's existing semantic palette; the host can inject its own tokens.
public struct SidebarTheme {
    public var panel: Color
    public var input: Color
    public var ink: Color
    public var secondary: Color
    public var separator: Color
    public init(panel: Color, input: Color, ink: Color, secondary: Color, separator: Color) {
        self.panel = panel; self.input = input; self.ink = ink
        self.secondary = secondary; self.separator = separator
    }
    public static var catpaw: SidebarTheme {
        .init(panel: adaptive(light: 0xFFFFFF, dark: 0x1B1D21),
              input: adaptive(light: 0xECEEF2, dark: 0x24272D),
              ink: adaptive(light: 0x202329, dark: 0xF1F2F4),
              secondary: adaptive(light: 0x606570, dark: 0xA7ADB8),
              separator: adaptive(light: 0xDADDE3, dark: 0x393E48))
    }
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        func value(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? value(dark) : value(light) })
        #elseif os(macOS)
        func value(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? value(dark) : value(light) })
        #else
        return Color(red: Double((light >> 16) & 255) / 255, green: Double((light >> 8) & 255) / 255, blue: Double(light & 255) / 255)
        #endif
    }
}

public struct SidebarPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.55)
            .animation(reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
public struct SidebarMenuButton: View {
    let action: () -> Void
    let localize:(String)->String
    var enabled: Bool
    public init(enabled: Bool = true,localize:@escaping (String)->String = {$0}, action: @escaping () -> Void) { self.enabled = enabled; self.action = action;self.localize=localize }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal").font(.system(size:20)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(SidebarPressStyle()).disabled(!enabled)
            .accessibilityLabel(localize("打开侧栏")).accessibilityHint(localize("切换对话、任务和成果"))
            .accessibilityIdentifier("sidebar.open")
    }
}
