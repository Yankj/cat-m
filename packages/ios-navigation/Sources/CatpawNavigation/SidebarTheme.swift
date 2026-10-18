import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// R5 neutral navigation defaults. Hosts can inject their own semantic colors and fonts.
public struct SidebarTheme {
    public var panel: Color
    public var input: Color
    /// A selected conversation is independent of the search/input surface.
    public var selection: Color
    public var ink: Color
    public var secondary: Color
    public var separator: Color
    public var titleFont:Font = .title2
    public var headingFont:Font = .headline
    public var bodyFont:Font = .body
    public var secondaryFont:Font = .subheadline
    public var captionFont:Font = .footnote
    /// Optional host-supplied brand mark drawn before the "Catpaw" heading (keeps the package free of App types).
    public var brandMark:AnyView? = nil
    public func brand<V:View>(_ mark:V)->SidebarTheme { var result=self; result.brandMark=AnyView(mark); return result }
    /// Host-supplied semantic styles keep this package independent of App types.
    public func typography(title:Font,heading:Font,body:Font,secondary:Font,caption:Font)->SidebarTheme {
        var result=self
        result.titleFont=title;result.headingFont=heading;result.bodyFont=body
        result.secondaryFont=secondary;result.captionFont=caption
        return result
    }
    /// Omitting selection preserves the original input-backed selection for
    /// independent hosts that already supply a custom palette.
    public init(panel: Color, input: Color, ink: Color, secondary: Color, separator: Color, selection: Color? = nil) {
        self.panel = panel; self.input = input; self.selection = selection ?? input; self.ink = ink
        self.secondary = secondary; self.separator = separator
    }
    public static var catpaw: SidebarTheme {
        .init(panel: adaptive(light: 0xF5F5F5, dark: 0x141414),
              input: adaptive(light: 0xF7F7F7, dark: 0x181818),
              ink: adaptive(light: 0x202020, dark: 0xF2F2F2),
              secondary: adaptive(light: 0x626262, dark: 0xA3A3A3),
              separator: adaptive(light: 0xDEDEDE, dark: 0x333333),
              selection: adaptive(light: 0xE8E8E8, dark: 0x202020))
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
/// One SF family, semantic size, weight and optical column for navigation icons.
/// Hit areas belong to the enclosing button and remain at least 44pt.
struct SidebarSymbol: View {
    let name: String
    var font: Font = .body
    @ScaledMetric(relativeTo: .body) private var opticalWidth = 24.0
    var body: some View {
        Image(systemName: name).font(font.weight(.regular))
            .symbolRenderingMode(.monochrome).frame(width: opticalWidth)
            .accessibilityHidden(true)
    }
}

public struct SidebarMenuButton: View {
    let action: () -> Void
    let localize:(String)->String
    var enabled: Bool
    private let font: Font
    public init(enabled: Bool = true,localize:@escaping (String)->String = {$0}, font: Font = .body, action: @escaping () -> Void) { self.enabled = enabled; self.action = action;self.localize=localize;self.font=font }
    public var body: some View {
        Button(action: action) {
            SidebarSymbol(name: "line.3.horizontal", font: font).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(SidebarPressStyle()).disabled(!enabled)
            .accessibilityLabel(localize("打开侧栏")).accessibilityHint(localize("切换对话、待办和记录"))
            .accessibilityIdentifier("sidebar.open")
    }
}
