import Foundation

/// first-run-polish: the appearance + motion contract of the first-install splash (NativeLoginView), the launch mark
/// (LaunchMarkView) and the「开始使用」→ chat handoff. Pure Foundation so Tests/FirstRunAppearanceRunner.swift can check it
/// against the real tokens (contrast in light AND dark) without SwiftUI.
///
/// Appearance strategy: the splash follows the system color scheme exactly like chat does (chat has no forced scheme and
/// paints `CatpawColors.background`), so the page background is the same token in both — no light→dark jump. 792587e
/// painted the splash on `calmPage` (light in both schemes) while its text used adaptive ink → light-gray-on-cream in
/// dark mode (1.1:1).
enum FirstRunAppearance {
    enum Scheme: CaseIterable { case light, dark }
    /// `color` = adaptive `CatpawColors.<name>`; `brand` = fixed `CatpawBrandTokens.<name>`.
    enum Token: Equatable { case color(String), brand(String), hex(UInt32) }
    struct Text {
        let id: String; let fg: Token; var fgAlpha: Double = 1; let bg: Token
        /// Worst case of what is painted between the text and its background (wash / sheen), as (token, alpha).
        var overlay: (Token, Double)? = nil
        /// WCAG large text (≥18pt, or ≥14pt bold) → 3:1, else 4.5:1.
        var large = false
    }
    static let pageBackground: Token = .color("calmPage")
    /// Warm wash behind the capability ring; it is confined to the ring, so copy above/below sees at most its tail.
    static let washPeak = 0.22, washTailAtCopy = 0.10
    /// CTA sheen peak (white). 0 = off: any white sweep under the label drops it below 4.5:1 on #C9501A.
    static let ctaSheenPeak = 0.0
    private static let wash: (Token, Double) = (.color("orbLight"), washTailAtCopy)
    static let texts: [Text] = [
        .init(id: "brand Catpaw-m", fg: .color("ink"), bg: pageBackground, overlay: wash),
        .init(id: "brand subtitle 你的个人 AI 助手", fg: .color("calmSecondary"), bg: pageBackground, overlay: wash),
        .init(id: "headline 解放双手…", fg: .color("ink"), bg: pageBackground, overlay: wash, large: true),
        .init(id: "subcopy 从一句话开始…", fg: .color("calmSecondary"), bg: pageBackground, overlay: wash),
        .init(id: "capability chip label ×8", fg: .color("ink"), bg: .color("calmSurface")),
        .init(id: "CTA 开始使用 (gradient top)", fg: .color("calmGlyph"), bg: .color("calmCTATop")),
        .init(id: "CTA 开始使用 (gradient bottom)", fg: .color("calmGlyph"), bg: .color("calmCTABottom")),
        .init(id: "footer 无需注册，即刻开始", fg: .color("calmSecondary"), bg: pageBackground, overlay: wash),
        .init(id: "restoring 正在复核登录…", fg: .color("calmSecondary"), bg: pageBackground, overlay: wash),
        .init(id: "error toast (capsule)", fg: .color("ink"), bg: .color("calmSurface")),
        .init(id: "text buttons 重新开始/取消登录", fg: .color("ink"), bg: pageBackground, overlay: wash),
    ]

    enum Transition: Equatable { case spring(response: Double, damping: Double), crossfade(duration: Double) }
    /// 「开始使用」→ chat. Motion: quick, non-bouncy spring (splash lifts 10pt + fades + 0.98 scale; chat rises 12pt + fades).
    /// Reduce Motion: plain 0.2 s crossfade, no movement.
    static func transition(reduceMotion: Bool) -> Transition { reduceMotion ? .crossfade(duration: 0.2) : .spring(response: 0.42, damping: 0.9) }

    enum Launch: Equatable { case skip, fade(duration: Double), full(total: Double) }
    /// VoiceOver → no animation at all; Reduce Motion → the final mark shown still, then a 0.25 s fade; else ≤ 1.1 s.
    static func launch(reduceMotion: Bool, voiceOver: Bool) -> Launch {
        if voiceOver { return .skip }
        return reduceMotion ? .fade(duration: 0.25) : .full(total: launchKeyframes.last!)
    }
    /// 0 mark springs in · 0.35 settle/breathe · 0.65 morph into the orb · 0.9 hand off (overlay fades, done at 1.1).
    static let launchKeyframes: [Double] = [0.35, 0.65, 0.9, 1.1]

    // MARK: start → chat handoff "E" (stub; red)
    struct Track: Equatable { enum Kind: Equatable { case fade, move }; let id: String; let start: Double; let end: Double; let kind: Kind }
    static let completeOnboardingAt = 0.0
    static func handoff(reduceMotion: Bool) -> [Track] { [] }

    static func composite(_ fg: UInt32, alpha: Double, over bg: UInt32) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 255) }
        func mix(_ s: UInt32) -> UInt32 { UInt32((ch(fg, s) * alpha + ch(bg, s) * (1 - alpha)).rounded()) << s }
        return mix(16) | mix(8) | mix(0)
    }
    static func luminance(_ c: UInt32) -> Double {
        func lin(_ s: UInt32) -> Double { let v = Double((c >> s) & 255) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(16) + 0.7152 * lin(8) + 0.0722 * lin(0)
    }
    /// WCAG 2.x contrast ratio.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double { let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
}
