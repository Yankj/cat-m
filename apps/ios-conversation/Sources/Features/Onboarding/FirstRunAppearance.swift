import Foundation
// RED stage: describes the 792587e splash as shipped (fixed-light calmPage under adaptive ink; no transition contract).
enum FirstRunAppearance {
    enum Scheme: CaseIterable { case light, dark }
    enum Token: Equatable { case color(String), brand(String), hex(UInt32) }
    struct Text { let id: String; let fg: Token; var fgAlpha: Double = 1; let bg: Token; var overlay: (Token, Double)? = nil; var large = false }
    enum Transition: Equatable { case spring(response: Double, damping: Double), crossfade(duration: Double) }
    enum Launch: Equatable { case skip, fade(duration: Double), full(total: Double) }
    static let pageBackground: Token = .color("calmPage")
    static let texts: [Text] = [
        .init(id: "brand Catpaw-m", fg: .color("ink"), fgAlpha: 0.72, bg: .color("calmPage")),
        .init(id: "brand subtitle", fg: .color("secondary"), bg: .color("calmPage")),
        .init(id: "headline", fg: .color("ink"), bg: .color("calmPage"), large: true),
        .init(id: "chip label", fg: .color("ink"), bg: .color("calmSurface")),
        .init(id: "CTA label", fg: .color("calmGlyph"), bg: .brand("primary"), large: true),
    ]
    static let launchKeyframes: [Double] = [0, 0.3, 0.7, 1.1, 1.45]
    static func transition(reduceMotion: Bool) -> Transition { .crossfade(duration: 0) }
    static func launch(reduceMotion: Bool, voiceOver: Bool) -> Launch { .full(total: 1.45) }
    static func composite(_ fg: UInt32, alpha: Double, over bg: UInt32) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 255) }
        func mix(_ s: UInt32) -> UInt32 { UInt32((ch(fg, s) * alpha + ch(bg, s) * (1 - alpha)).rounded()) << s }
        return mix(16) | mix(8) | mix(0)
    }
    static func luminance(_ c: UInt32) -> Double {
        func lin(_ s: UInt32) -> Double { let v = Double((c >> s) & 255) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(16) + 0.7152 * lin(8) + 0.0722 * lin(0)
    }
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double { let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
}
