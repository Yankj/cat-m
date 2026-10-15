import SwiftUI
import UIKit

/// R7 motion tokens (docs/design/ios26-swift-mapping-r7.md §1). Every call site goes through `resolved` so
/// Reduce Motion collapses springs to a short ease.
enum CatpawMotion {
    static let drawer           = Animation.spring(response: 0.30, dampingFraction: 1.0)
    static let popover          = Animation.spring(response: 0.26, dampingFraction: 0.98)
    static let sendMorph        = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let thinkingCollapse = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let chip             = Animation.spring(response: 0.30, dampingFraction: 0.70)
    static let statusCapsule    = Animation.spring(response: 0.26, dampingFraction: 0.80)
    static let stamp            = Animation.spring(response: 0.45, dampingFraction: 0.60)
    /// Per-batch fade for streamed text (design.md §4: 50ms batch, 160ms fade).
    static let batchFade        = Animation.easeOut(duration: 0.16)
    static let pawBreathe: Double = 1.1
    static func resolved(_ animation: Animation, _ reduceMotion: Bool) -> Animation { reduceMotion ? .easeInOut(duration: 0.15) : animation }
}

/// Brand colour lives outside `CatpawColors` on purpose. It covers Catpaw identity surfaces
/// and the composer send/stop/queue control; generic actions, links and statuses stay semantic.
enum CatpawBrand {
    static let paw = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xF2A985) : UIColor(rgb: 0xE8946A) })
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// Vector paw matching `catpaw.paw.svg` (24pt grid). Parts are individually addressable for the launch animation.
struct PawShape: Shape {
    enum Part: CaseIterable { case toe0, toe1, toe2, toe3, pad }
    var part: Part? = nil
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        func toe(_ cx: CGFloat, _ cy: CGFloat, _ ry: CGFloat, _ deg: CGFloat) -> Path {
            let r = CGRect(x: -2.1 * s, y: -ry * s, width: 4.2 * s, height: 2 * ry * s)
            return Path(ellipseIn: r).applying(CGAffineTransform(rotationAngle: deg * .pi / 180)
                .concatenating(CGAffineTransform(translationX: o.x + cx * s, y: o.y + cy * s)))
        }
        func pad() -> Path {
            var p = Path()
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
            p.move(to: pt(12, 11.2))
            p.addCurve(to: pt(18, 17.4), control1: pt(14.9, 11.2), control2: pt(18, 14.7))
            p.addCurve(to: pt(14.7, 20.4), control1: pt(18, 19.4), control2: pt(16.4, 20.4))
            p.addCurve(to: pt(12, 19.9), control1: pt(13.6, 20.4), control2: pt(12.9, 19.9))
            p.addCurve(to: pt(9.3, 20.4), control1: pt(11.1, 19.9), control2: pt(10.4, 20.4))
            p.addCurve(to: pt(6, 17.4), control1: pt(7.6, 20.4), control2: pt(6, 19.4))
            p.addCurve(to: pt(12, 11.2), control1: pt(6, 14.7), control2: pt(9.1, 11.2))
            p.closeSubpath()
            return p
        }
        let parts: [Part: Path] = [.toe0: toe(5.6, 10, 2.7, -18), .toe1: toe(9.7, 5.6, 2.8, -6),
                                   .toe2: toe(14.3, 5.6, 2.8, 6), .toe3: toe(18.4, 10, 2.7, 18), .pad: pad()]
        if let part { return parts[part]! }
        var all = Path(); Part.allCases.forEach { all.addPath(parts[$0]!) }; return all
    }
}

/// Small breathing paw used by the thinking row. Reduce Motion → static.
struct BreathingPaw: View {
    var active: Bool
    @ScaledMetric(relativeTo: .body) private var size = 16.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        PawShape().fill(CatpawBrand.paw).frame(width: size, height: size)
            .scaleEffect(active && !reduceMotion && phase ? 1.0 : 0.86)
            .opacity(active && !reduceMotion && phase ? 1 : 0.72)
            .animation(active && !reduceMotion ? .easeInOut(duration: CatpawMotion.pawBreathe / 2).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { phase = active }
            .onChange(of: active) { _, value in phase = value }
            .accessibilityHidden(true)
    }
}

// MARK: r8 tokens (composer + top bar)
extension CatpawColors {
    /// Composer pill fill (#F2F2F4 / #1C1C1E) and its 0.5pt hairline.
    static let composerPill = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x1C1C1E) : UIColor(rgb: 0xF2F2F4) })
    static let hairline = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x2A2A2C) : UIColor(rgb: 0xE4E4E6) })
    /// ink3 (#A3A7AE): meta line, model label, chevron, offline dot.
    static let tertiary = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x6B6F76) : UIColor(rgb: 0xA3A7AE) })
}
extension CatpawMotion {
    static let composer = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let morph = Animation.spring(response: 0.28, dampingFraction: 0.8)
}

/// Two-line sidebar glyph (r8, user-approved): long line over short line, 1.5pt round-cap stroke,
/// sized to sit with 19pt regular SF Symbols (≈18×12pt).
struct TwoLineMenuGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0.75, y: 3)); p.addLine(to: CGPoint(x: size.width - 0.75, y: 3))
            p.move(to: CGPoint(x: 0.75, y: size.height - 3)); p.addLine(to: CGPoint(x: size.width * 0.58, y: size.height - 3))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: 18, height: 13)
        .accessibilityHidden(true)
    }
}
