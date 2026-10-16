import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// R5 semantic roles, mapped from mobile-conversation-reference-r5.json.
/// Reading, temporary surfaces, sending and exact approval are independent roles:
/// changing an action tint cannot recolor a message or grant an approval emphasis.
enum CatpawColors {
    static let background = adaptive(light: 0xFFFFFF, dark: 0x050505)
    static let panel = adaptive(light: 0xF7F7F7, dark: 0x181818)
    static let input = adaptive(light: 0xF7F7F7, dark: 0x141414)
    static let drawer = adaptive(light: 0xF5F5F5, dark: 0x141414)
    static let ink = adaptive(light: 0x1C1B1A, dark: 0xF2F0ED)
    static let onInk = adaptive(light: 0xFFFFFF, dark: 0x151515)
    static let secondary = adaptive(light: 0x6E6A66, dark: 0xA39E98)
    static let tertiary = adaptive(light: 0xA8A39E, dark: 0x6B6662)
    // r9: settings / drawer grouped surfaces.
    static let groupedBackground = adaptive(light: 0xF7F5F2, dark: 0x121110)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1C1B19)
    static let fillSelected = adaptive(light: 0xEAE6E1, dark: 0x2E2B28)
    static let hairline = adaptiveAlpha(light: 0x1C1B1A, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let destructive = adaptive(light: 0xD9402B, dark: 0xFF6B57)
    // r9: brand paw orange replaces the former blue action role.
    static let action = adaptive(light: 0xEA5F2C, dark: 0xFF8A5C)   // fills/icons/non-text only (≥3:1)
    /// Orange text where unavoidable (≥4.5:1 on white). Prefer ink for text.
    static let actionText = adaptive(light: 0xC4511F, dark: 0xFF9E78)
    static let send = adaptive(light: 0x3567EE, dark: 0x3567EE)
    static let sendIcon = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let userMessageBackground = adaptive(light: 0xF2EFEB, dark: 0x262422)
    static let userMessageInk = adaptive(light: 0x1C1B1A, dark: 0xF2F0ED)
    static let controlEdge = adaptive(light: 0x858585, dark: 0x777777)
    // Decorative separators do not carry a control's affordance or state.
    static let separator = adaptive(light: 0xDEDEDE, dark: 0x383838)
    static let success = adaptive(light: 0x267146, dark: 0x9BD4AF)
    static let attention = adaptive(light: 0x895700, dark: 0xE9BC69)
    static let failure = adaptive(light: 0xB3261E, dark: 0xFFB4AB)
    // Calm launch/onboarding/voice surface (warm page, peach + lavender glow, orange orb).
    static let calmPage = adaptive(light: 0xFBF7F3, dark: 0xFBF7F3)
    static let calmPeach = adaptive(light: 0xFFC79E, dark: 0xFFC79E)
    static let calmLavender = adaptive(light: 0xD6CCFA, dark: 0xD6CCFA)
    static let orbLight = adaptive(light: 0xFFBD85, dark: 0xFFBD85)
    static let orbDeep = adaptive(light: 0xF57333, dark: 0xF57333)
    static let calmSurface = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let calmGlyph = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let calmShadow = adaptive(light: 0x000000, dark: 0x000000)
    // Compatibility names inherit the shared semantic role, never a second palette.
    static let accent = action
    static let green = success

    private static func adaptiveAlpha(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> Color {
        #if os(iOS)
        func value(_ hex: UInt32, _ a: CGFloat) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? value(dark, darkAlpha) : value(light, lightAlpha) })
        #else
        return Color(NSColor(srgbRed: CGFloat((light >> 16) & 255) / 255, green: CGFloat((light >> 8) & 255) / 255, blue: CGFloat(light & 255) / 255, alpha: lightAlpha))
        #endif
    }

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
            .fixedSize(horizontal:false,vertical:true)
            .frame(minHeight: 24).padding(.horizontal, 20).padding(.vertical, 14)
            .foregroundStyle(isEnabled ? CatpawColors.onInk : CatpawColors.secondary)
            .background(isEnabled ? CatpawColors.ink : CatpawColors.input,
                        in: RoundedRectangle(cornerRadius: CatpawLayout.controlRadius, style: .continuous))
            // Press-down answers in the touch frame with scale + soft haptic; release springs back.
            .modifier(CatpawPressEffect(pressed: configuration.isPressed && isEnabled, scale: CatpawInteractionMotion.primaryPressScale, dimmed: 0.86))
    }
}

/// For custom controls; system toolbar and list controls retain native feedback.
struct CatpawPressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.55)
            .modifier(CatpawPressEffect(pressed: configuration.isPressed && isEnabled, dimmed: 0.7))
    }
}

/// Consent checkboxes expose the entire readable row as one 44pt action.
/// The check mark is visual; the label and selection are one accessibility item.
struct CatpawConfirmationCheckbox:View {
    let title:String
    @Binding var isOn:Bool
    @Environment(\.locale) private var locale
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    var body:some View {
        Button {isOn.toggle()} label:{
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Image(systemName:isOn ? "checkmark.square.fill":"square")
                    .font(CatpawTypography.Role.body.font).symbolRenderingMode(.monochrome)
                    .foregroundStyle(CatpawColors.ink).accessibilityHidden(true)
                Text(verbatim:title).font(CatpawTypography.Role.body.font).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(title)
            .accessibilityValue(isOn ? ui("已选中"):ui("未选中"))
            .accessibilityAddTraits(isOn ? [.isSelected]:[])
    }
}

extension View {
    func primaryAction() -> some View { self.buttonStyle(CatpawPrimaryButtonStyle()) }
    /// r9 Grok-style answer actions: small thin line glyphs, compact but forgiving hit area.
    func answerActionIcon() -> some View {
        // CircleIcon idle pair: light circle + ink glyph (monochrome; brand orange is reserved for the paw).
        self.font(CatpawTypography.Role.caption.font.weight(.medium)).imageScale(.medium).foregroundStyle(CatpawColors.ink)
            .frame(width: 30, height: 30).background(CatpawColors.card, in: Circle())
            .overlay(Circle().strokeBorder(CatpawColors.hairline, lineWidth: 0.5)).contentShape(Circle().inset(by: -6))
    }
    func touchTarget(minimum:CGFloat = 44) -> some View { self.frame(minWidth: max(44,minimum), minHeight: max(44,minimum)).contentShape(Rectangle()) }
    @ViewBuilder func compactNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}


/// r9 §1 sheet footer: stacked full-width ink capsule (52pt) over a quiet text action (44pt).
struct CatpawSheetActions<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary
    var body: some View {
        VStack(spacing: 4) {
            primary()
            secondary()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: CatpawLayout.readableWidth).frame(maxWidth: .infinity)
        .background(CatpawColors.background)
        .overlay(alignment: .top) { CatpawColors.hairline.frame(height: 0.5) }
    }
}

struct CatpawSheetPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isEnabled ? CatpawColors.onInk : CatpawColors.secondary)
            .background(isEnabled ? CatpawColors.ink : CatpawColors.input, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct CatpawSheetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium))
            .foregroundStyle(CatpawColors.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
