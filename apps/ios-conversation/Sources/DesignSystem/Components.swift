import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Semantic palette. Accent denotes an action; signal colors only denote state.
enum CatpawColors {
    static let background = adaptive(light: 0xF7F8FA, dark: 0x111214)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x1B1D21)
    static let input = adaptive(light: 0xECEEF2, dark: 0x24272D)
    static let ink = adaptive(light: 0x202329, dark: 0xF1F2F4)
    static let onInk = adaptive(light: 0xFFFFFF, dark: 0x15171A)
    static let secondary = adaptive(light: 0x606570, dark: 0xA7ADB8)
    static let accent = adaptive(light: 0x2855B6, dark: 0xADC5FF)
    static let separator = adaptive(light: 0xDADDE3, dark: 0x393E48)
    static let success = adaptive(light: 0x267146, dark: 0x9BD4AF)
    static let attention = adaptive(light: 0x895700, dark: 0xE9BC69)
    static let failure = adaptive(light: 0xB23840, dark: 0xF6A4A7)
    // Kept as a compatibility alias for existing non-core views.
    static let green = success

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        func value(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? value(dark) : value(light) })
        #else
        func value(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? value(dark) : value(light) })
        #endif
    }
}

enum CatpawLayout {
    static let pageInset: CGFloat = 20
    static let sectionGap: CGFloat = 28
    static let rowGap: CGFloat = 12
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 14
    static let readableWidth: CGFloat = 680
}

enum CatpawTone {
    case neutral, active, success, attention, failure
    var color: Color {
        switch self {
        case .neutral: CatpawColors.secondary
        case .active: CatpawColors.accent
        case .success: CatpawColors.success
        case .attention: CatpawColors.attention
        case .failure: CatpawColors.failure
        }
    }
}

/// SF Symbols keep their optical alignment and scale with the adjoining body text.
struct CatpawSymbol: View {
    let name: String
    @ScaledMetric(relativeTo: .body) private var size = 19.0
    var body: some View {
        Image(systemName: name).font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.monochrome).imageScale(.medium)
            .frame(minWidth: 24).accessibilityHidden(true)
    }
}

@MainActor struct StatusLabel: View {
    var text: String
    var symbol = "circle.fill"
    var tone: CatpawTone = .neutral
    @ScaledMetric(relativeTo: .caption) private var dotSize = 6.0
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(symbol == "circle.fill" ? .system(size: dotSize, weight: .semibold) : .caption.weight(.semibold)).accessibilityHidden(true)
            Text(text).font(CatpawTypography.Role.caption.font.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(tone.color).accessibilityElement(children: .combine)
    }
}

@MainActor struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .foregroundStyle(CatpawColors.ink).padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: CatpawLayout.cardRadius, style: .continuous))
    }
}

@MainActor struct EmptyState: View {
    var title: String
    var detail: String
    var symbol = "tray"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(.title, design: .default).weight(.regular))
                .symbolRenderingMode(.monochrome).foregroundStyle(CatpawColors.secondary).accessibilityHidden(true)
            Text(title).font(CatpawTypography.Role.heading.font).foregroundStyle(CatpawColors.ink)
            Text(detail).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 28).padding(.horizontal, 20).frame(maxWidth: .infinity)
    }
}

@MainActor struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CatpawLayout.sectionGap) { content }
                .padding(CatpawLayout.pageInset).frame(maxWidth: CatpawLayout.readableWidth)
                .frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity).background(CatpawColors.background)
    }
}

struct SectionHeading: View {
    var title: String
    var detail: String? = nil
    var body: some View {
        CatpawAdaptiveHeader(title:title,detail:detail,detailRole:.secondary).foregroundStyle(CatpawColors.ink).accessibilityAddTraits(.isHeader)
    }
}

struct ActionRow: View {
    var title: String
    var detail: String? = nil
    var symbol: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CatpawSymbol(name:symbol).foregroundStyle(CatpawColors.secondary)
            CatpawAdaptiveHeader(title:title,detail:detail,titleRole:.body,weight:.medium).foregroundStyle(CatpawColors.ink)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(CatpawColors.secondary).accessibilityHidden(true)
        }.padding(.vertical, 10).frame(minHeight: 52).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

struct CatpawPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(CatpawTypography.Role.body.font.weight(.semibold))
            .frame(minHeight: 24).padding(.horizontal, 20).padding(.vertical, 14)
            .foregroundStyle(isEnabled ? CatpawColors.onInk : CatpawColors.secondary)
            .background(isEnabled ? CatpawColors.ink : CatpawColors.input,
                        in: RoundedRectangle(cornerRadius: CatpawLayout.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
            // Press-down is immediate. Only release may ease back to rest.
            .animation(reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// For custom controls; system toolbar and list controls retain native feedback.
struct CatpawPressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.55)
            .animation(reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func primaryAction() -> some View { self.buttonStyle(CatpawPrimaryButtonStyle()) }
    func touchTarget() -> some View { self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
    @ViewBuilder func compactNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
