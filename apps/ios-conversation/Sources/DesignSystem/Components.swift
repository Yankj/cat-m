import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// R5 semantic roles, mapped from mobile-conversation-reference-r5.json.
/// Reading, temporary surfaces, sending and exact approval are independent roles:
/// changing an action tint cannot recolor a message or grant an approval emphasis.
enum catColors {
    // Surfaces — brand Background #FFFCF8
    static let background = adaptive(light: catBrandTokens.background, dark: catBrandTokens.canvasDark)
    static let panel = adaptive(light: catBrandTokens.panelLight, dark: catBrandTokens.panelDark)
    static let input = adaptive(light: catBrandTokens.panelLight, dark: 0x141414)
    static let drawer = adaptive(light: 0xF5F5F5, dark: 0x141414)
    /// Brand Ink #292622 — primary text
    static let ink = adaptive(light: catBrandTokens.ink, dark: catBrandTokens.inkDark)
    static let onInk = adaptive(light: 0xFFFFFF, dark: 0x151515)
    /// Brand Grey #929298 — secondary text / captions
    static let secondary = adaptive(light: catBrandTokens.secondaryLight, dark: catBrandTokens.greyDark)
    static let tertiary = adaptive(light: catBrandTokens.grey, dark: 0x6B6662)  // sheet Grey (muted)
    static let groupedBackground = adaptive(light: catBrandTokens.background, dark: 0x121110)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1C1B19)
    static let fillSelected = adaptive(light: 0xEAE6E1, dark: 0x2E2B28)
    static let hairline = adaptiveAlpha(light: catBrandTokens.ink, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let destructive = adaptive(light: 0xD9402B, dark: 0xFF6B57)
    /// Brand Primary #FF702A — fills / icons / non-text only (never body copy).
    static let action = adaptive(light: catBrandTokens.fillLight, dark: catBrandTokens.primaryDark)
    /// Semantic alias for brand fill (same as `action`).
    static let fill = action
    /// Brand Deep #C64A0B — orange text only when unavoidable (≥4.5:1). Prefer `ink`.
    static let actionText = adaptive(light: catBrandTokens.deep, dark: catBrandTokens.deepDark)
    static let send = adaptive(light: 0x3567EE, dark: 0x3567EE)
    static let sendIcon = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// Composer voice / stop circle: black in both appearances (device-0728). `ink` flips to near-white in dark mode,
    /// which put the white glyph on a light circle and read as a disabled button.
    static let voiceFill = adaptive(light: catBrandTokens.ink, dark: 0x000000)
    /// Hairline so the black circle still separates from the dark composer surface (dark only).
    static let voiceRing = adaptiveAlpha(light: 0xFFFFFF, lightAlpha: 0, dark: 0xFFFFFF, darkAlpha: 0.22)
    static let userMessageBackground = adaptive(light: 0xF2EFEB, dark: 0x262422)
    static let userMessageInk = adaptive(light: catBrandTokens.ink, dark: catBrandTokens.inkDark)
    static let controlEdge = adaptive(light: 0x858585, dark: 0x777777)
    static let separator = adaptive(light: 0xDEDEDE, dark: 0x383838)
    static let success = adaptive(light: 0x267146, dark: 0x9BD4AF)
    static let attention = adaptive(light: 0x895700, dark: 0xE9BC69)
    static let failure = adaptive(light: 0xB3261E, dark: 0xFFB4AB)
    // Calm launch / onboarding / voice (warm page + orb)
    // first-run-polish (Grok Bot 12:33): the calm tokens get real dark values — launch screen, splash and chat share one
    // canvas per mode, so nothing inverts and the system-coloured status bar stays legible.
    static let calmPage = adaptive(light: catBrandTokens.background, dark: catBrandTokens.canvasDark)
    /// Splash secondary text: 6.7:1 light / 8.8:1 dark on the canvas (≥4.5 on the ring wash tail).
    static let calmSecondary = adaptive(light: 0x5F5A55, dark: 0xB3ADA6)
    /// Auxiliary icons only (#929298 in both modes; ≥3:1 on calmSurface white / #1F1B18).
    static let calmIcon = adaptive(light: catBrandTokens.grey, dark: catBrandTokens.grey)
    /// SPEC-E §1 landing chip icon (icon only, never text): 4.79:1 / 7.36:1 on calmSurface.
    static let calmChipIcon = adaptive(light: 0xC64A0B, dark: 0xFF8A5C)
    /// SPEC-E §1 static warm wash / cat glow and the cat's ground shadow (decorative).
    static let calmGlow = adaptiveAlpha(light: 0xFF9A5C, lightAlpha: 0.30, dark: 0xFF702A, darkAlpha: 0.20)
    static let calmGround = adaptiveAlpha(light: 0x8A3A12, lightAlpha: 0.22, dark: 0x000000, darkAlpha: 0.55)
    /// 「开始使用」gradient (fill only); white label 4.5–5.4:1 at both ends.
    static let calmCTATop = adaptive(light: 0xC9501A, dark: 0xC9501A)
    static let calmCTABottom = adaptive(light: 0xB8440A, dark: 0xB8440A)
    static let calmPeach = adaptive(light: catBrandTokens.peach, dark: catBrandTokens.peach)
    static let calmLavender = adaptive(light: catBrandTokens.lavender, dark: catBrandTokens.lavender)
    static let orbLight = adaptive(light: catBrandTokens.orbLight, dark: catBrandTokens.orbLight)
    static let orbDeep = adaptive(light: catBrandTokens.primary, dark: catBrandTokens.primary)
    static let calmSurface = adaptive(light: 0xFFFFFF, dark: 0x1F1B18)
    static let calmGlyph = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let calmShadow = adaptive(light: 0x000000, dark: 0x000000)
    // Compatibility aliases — never a second palette.
    static let accent = action
    static let green = success
    static let primary = action

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

enum catLayout {
    static let pageInset: CGFloat = 20
    static let sectionGap: CGFloat = 28
    static let rowGap: CGFloat = 12
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 14
    static let readableWidth: CGFloat = 680
}

enum catTone {
    case neutral, active, success, attention, failure
    var color: Color {
        switch self {
        case .neutral: catColors.secondary
        case .active: catColors.accent
        case .success: catColors.success
        case .attention: catColors.attention
        case .failure: catColors.failure
        }
    }
}

/// SF Symbols keep their optical alignment and scale with the adjoining body text.
struct catSymbol: View {
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
    var tone: catTone = .neutral
    @ScaledMetric(relativeTo: .caption) private var dotSize = 6.0
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(symbol == "circle.fill" ? .system(size: dotSize, weight: .semibold) : .caption.weight(.semibold)).accessibilityHidden(true)
            Text(text).font(catTypography.Role.caption.font.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(tone.color).accessibilityElement(children: .combine)
    }
}

@MainActor struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .foregroundStyle(catColors.ink).padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(catColors.panel, in: RoundedRectangle(cornerRadius: catLayout.cardRadius, style: .continuous))
    }
}

@MainActor struct EmptyState: View {
    var title: String
    var detail: String
    var symbol = "tray"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(.title, design: .default).weight(.regular))
                .symbolRenderingMode(.monochrome).foregroundStyle(catColors.secondary).accessibilityHidden(true)
            Text(title).font(catTypography.Role.heading.font).foregroundStyle(catColors.ink)
            Text(detail).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 28).padding(.horizontal, 20).frame(maxWidth: .infinity)
    }
}

@MainActor struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: catLayout.sectionGap) { content }
                .padding(catLayout.pageInset).frame(maxWidth: catLayout.readableWidth)
                .frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity).background(catColors.background)
    }
}

struct SectionHeading: View {
    var title: String
    var detail: String? = nil
    var body: some View {
        catAdaptiveHeader(title:title,detail:detail,detailRole:.secondary).foregroundStyle(catColors.ink).accessibilityAddTraits(.isHeader)
    }
}

struct ActionRow: View {
    var title: String
    var detail: String? = nil
    var symbol: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            catSymbol(name:symbol).foregroundStyle(catColors.secondary)
            catAdaptiveHeader(title:title,detail:detail,titleRole:.body,weight:.medium).foregroundStyle(catColors.ink)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(catColors.secondary).accessibilityHidden(true)
        }.padding(.vertical, 10).frame(minHeight: 52).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

struct catPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(catTypography.Role.body.font.weight(.semibold))
            .fixedSize(horizontal:false,vertical:true)
            .frame(minHeight: 24).padding(.horizontal, 20).padding(.vertical, 14)
            .foregroundStyle(isEnabled ? catColors.onInk : catColors.secondary)
            .background(isEnabled ? catColors.ink : catColors.input,
                        in: RoundedRectangle(cornerRadius: catLayout.controlRadius, style: .continuous))
            // Press-down answers in the touch frame with scale + soft haptic; release springs back.
            .modifier(catPressEffect(pressed: configuration.isPressed && isEnabled, scale: catInteractionMotion.primaryPressScale, dimmed: 0.86))
    }
}

/// For custom controls; system toolbar and list controls retain native feedback.
struct catPressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.55)
            .modifier(catPressEffect(pressed: configuration.isPressed && isEnabled, dimmed: 0.7))
    }
}

/// Consent checkboxes expose the entire readable row as one 44pt action.
/// The check mark is visual; the label and selection are one accessibility item.
struct catConfirmationCheckbox:View {
    let title:String
    @Binding var isOn:Bool
    @Environment(\.locale) private var locale
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    var body:some View {
        Button {isOn.toggle()} label:{
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Image(systemName:isOn ? "checkmark.square.fill":"square")
                    .font(catTypography.Role.body.font).symbolRenderingMode(.monochrome)
                    .foregroundStyle(catColors.ink).accessibilityHidden(true)
                Text(verbatim:title).font(catTypography.Role.body.font).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(catPressButtonStyle()).accessibilityLabel(title)
            .accessibilityValue(isOn ? ui("已选中"):ui("未选中"))
            .accessibilityAddTraits(isOn ? [.isSelected]:[])
    }
}

extension View {
    func primaryAction() -> some View { self.buttonStyle(catPrimaryButtonStyle()) }
    /// r9 Grok-style answer actions: small thin line glyphs, compact but forgiving hit area.
    func answerActionIcon() -> some View {
        // CircleIcon idle pair: light circle + ink glyph (monochrome; brand orange is reserved for the paw).
        self.font(catTypography.Role.caption.font.weight(.medium)).imageScale(.medium).foregroundStyle(catColors.ink)
            .frame(width: 30, height: 30).background(catColors.card, in: Circle())
            .overlay(Circle().strokeBorder(catColors.hairline, lineWidth: 0.5)).contentShape(Circle().inset(by: -6))
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
struct catSheetActions<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary
    var body: some View {
        VStack(spacing: 4) {
            primary()
            secondary()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: catLayout.readableWidth).frame(maxWidth: .infinity)
        .background(catColors.background)
        .overlay(alignment: .top) { catColors.hairline.frame(height: 0.5) }
    }
}

struct catSheetPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isEnabled ? catColors.onInk : catColors.secondary)
            .background(isEnabled ? catColors.ink : catColors.input, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct catSheetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium))
            .foregroundStyle(catColors.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
