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
    /// r10 soft-clay logo palette; mirrored in Resources/Assets.xcassets/LaunchPaw.svg.
    static let clayLight = Color(UIColor(rgb: 0xFFB48A))
    static let clayBase = Color(UIColor(rgb: 0xF5843F))
    static let clayRim = Color(UIColor(rgb: 0xE0652A))
    static let clayShadow = Color(UIColor(rgb: 0x8A3A12))
    static let clayHighlight = Color(UIColor(rgb: 0xFFFFFF))
}

/// The single Catpaw logo (r10, "soft clay" 3D style): every pad is its own ellipse with a radial clay gradient
/// (highlight → base → shaded rim) plus a soft contact shadow, so toes can press in sequence.
/// Geometry is in a 24-unit box and mirrors Resources/Assets.xcassets/LaunchPaw.svg exactly (frame-0 identity).
/// `pressed[i]` (0–3 toes, 4 main pad) sinks that pad ~3% and squashes it to 0.9.
struct PawMark: View {
    var size: CGFloat
    var pressed: [Bool] = [false, false, false, false, false]
    var shadow: Bool = true
    /// (cx, cy, rx, ry, padIndex). Main pad = a tall centre lobe over two side lobes, as in the reference sheet.
    static let pads: [(CGFloat, CGFloat, CGFloat, CGFloat, Int)] = [
        (8.3, 16.9, 3.3, 3.9, 4), (15.7, 16.9, 3.3, 3.9, 4), (12, 15.9, 4.7, 5.3, 4),
        (4.9, 9.7, 2.5, 2.7, 0), (9.3, 5.3, 2.6, 2.9, 1), (14.7, 5.3, 2.6, 2.9, 2), (19.1, 9.7, 2.5, 2.7, 3)]
    var body: some View {
        let u = size / 24
        ZStack {
            // contact shadow
            Ellipse().fill(RadialGradient(colors: [CatpawBrand.clayShadow.opacity(shadow ? 0.28 : 0), CatpawBrand.clayShadow.opacity(0)],
                                          center: .center, startRadius: 0, endRadius: 8 * u))
                .frame(width: 16 * u, height: 3.2 * u).position(x: 12 * u, y: 22.2 * u)
            ForEach(Array(Self.pads.enumerated()), id: \.offset) { _, pad in
                let (cx, cy, rx, ry, index) = pad
                let down = index < pressed.count && pressed[index]
                Ellipse()
                    .fill(RadialGradient(stops: [.init(color: CatpawBrand.clayLight, location: 0),
                                                 .init(color: CatpawBrand.clayBase, location: 0.55),
                                                 .init(color: CatpawBrand.clayRim, location: 1)],
                                         center: UnitPoint(x: 0.36, y: 0.3), startRadius: 0, endRadius: max(rx, ry) * 2.1 * u))
                    .frame(width: 2 * rx * u, height: 2 * ry * u)
                    .scaleEffect(x: down ? 1.04 : 1, y: down ? 0.9 : 1, anchor: .bottom)
                    .position(x: cx * u, y: cy * u + (down ? size * 0.03 : 0))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
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
struct BreathingPaw: View {   // r10: the thinking indicator is now CatpawPresence (slow blink while waiting)
    var active: Bool
    @ScaledMetric(relativeTo: .body) private var size = 22.0
    var body: some View { CatpawPresence(state: .waiting, size: size).opacity(active ? 1 : 0.72) }
}

// MARK: r8 tokens (composer + top bar)
extension CatpawColors {
    /// Composer pill fill (#F2F2F4 / #1C1C1E) and its 0.5pt hairline.
    static let composerPill = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x1C1C1E) : UIColor(rgb: 0xF2F2F4) })
    /// ink3 (#A3A7AE): meta line, model label, chevron, offline dot.
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

/// r10 streaming presence: an ultra-abstract soft-clay cat head (~22pt) that replaces the thinking/streaming dots.
/// Each state maps to turn events; all motion uses springs and collapses to static poses under Reduce Motion.
enum CatpawPresenceState: Equatable { case waiting, thinking, streaming, working, done, error }

struct CatpawPresence: View {
    var state: CatpawPresenceState
    var size: CGFloat = 22
    /// Bumped by the host on each revealed chunk while streaming → subtle nod in rhythm with the reveal.
    var revealTick: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false
    @State private var tilt = false
    @State private var twitch = false
    @State private var orbit = false
    @State private var bounce = false
    @State private var nod = false

    var body: some View {
        let u = size / 24
        let clay = RadialGradient(stops: [.init(color: CatpawBrand.clayLight, location: 0), .init(color: CatpawBrand.clayBase, location: 0.55),
                                          .init(color: CatpawBrand.clayRim, location: 1)], center: UnitPoint(x: 0.36, y: 0.28), startRadius: 0, endRadius: 15 * u)
        let earDrop: Double = state == .error ? 38 : (state == .working ? -8 : 0)
        ZStack {
            Ellipse().fill(CatpawBrand.clayShadow.opacity(0.18)).frame(width: 16 * u, height: 2.4 * u).blur(radius: 1.2 * u).offset(y: 11.4 * u)
            ZStack {
                CatEar().fill(clay).frame(width: 7 * u, height: 7 * u)
                    .rotationEffect(.degrees(-14 - earDrop - (twitch ? 10 : 0)), anchor: .bottom).offset(x: -6 * u, y: -7.6 * u)
                CatEar().fill(clay).frame(width: 7 * u, height: 7 * u)
                    .rotationEffect(.degrees(14 + earDrop), anchor: .bottom).offset(x: 6 * u, y: -7.6 * u)
                Ellipse().fill(clay).frame(width: 21 * u, height: 18 * u).offset(y: 1.5 * u)
                Ellipse().fill(CatpawBrand.clayHighlight.opacity(0.35)).frame(width: 5 * u, height: 3 * u).blur(radius: 0.8 * u).offset(x: -4.5 * u, y: -3.2 * u)
                eyes(u).offset(y: (state == .streaming ? 3.4 : 2.2) * u)
            }
            .rotationEffect(.degrees(state == .thinking && tilt ? -9 : 0))
            .offset(y: (bounce ? -3 * u : 0) + (nod ? 0.8 * u : 0))
            if state == .working {
                Circle().fill(CatpawBrand.clayRim).frame(width: 3 * u, height: 3 * u)
                    .offset(x: 11 * u).rotationEffect(.degrees(orbit ? 360 : 0)).offset(y: -12 * u).scaleEffect(x: 1, y: 0.35)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { start() }
        .onChange(of: state) { _, _ in start() }
        .onChange(of: revealTick) { _, _ in
            guard state == .streaming, !reduceMotion else { return }
            withAnimation(.snappy(duration: 0.14)) { nod = true }
            withAnimation(.snappy(duration: 0.22).delay(0.14)) { nod = false }
        }
    }

    @ViewBuilder private func eyes(_ u: CGFloat) -> some View {
        HStack(spacing: 6 * u) {
            ForEach(0..<2, id: \.self) { _ in
                switch state {
                case .done: HappyEye().stroke(CatpawColors.ink, style: StrokeStyle(lineWidth: 1.3 * u, lineCap: .round)).frame(width: 3.4 * u, height: 2 * u)
                case .error: Capsule().fill(CatpawColors.ink).frame(width: 3.4 * u, height: 1.2 * u)
                default: Capsule().fill(CatpawColors.ink).frame(width: 2.3 * u, height: (blink ? 0.4 : 2.6) * u)
                }
            }
        }
    }

    private func start() {
        blink = false; tilt = false; twitch = false; orbit = false; bounce = false; nod = false
        guard !reduceMotion else { return }
        switch state {
        case .waiting:
            withAnimation(.easeInOut(duration: 0.18).delay(1.6).repeatForever(autoreverses: true)) { blink = true }
        case .thinking:
            withAnimation(.smooth(duration: 1.4).repeatForever(autoreverses: true)) { tilt = true }
            withAnimation(.bouncy(duration: 0.3).delay(0.9).repeatForever(autoreverses: true)) { twitch = true }
        case .streaming:
            // r11 writing: steady "typing" nod (revealTick nods still layer on top).
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) { nod = true }
        case .working:
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { orbit = true }
        case .done:
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.2)) { bounce = true }
            withAnimation(.smooth(duration: 0.3).delay(0.32)) { bounce = false }
        case .error: break
        }
    }
}

private struct CatEar: Shape {   // rounded triangle
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.midX - r.width * 0.08, y: r.minY + r.height * 0.1), control: CGPoint(x: r.minX + r.width * 0.15, y: r.minY + r.height * 0.35))
        p.addQuadCurve(to: CGPoint(x: r.midX + r.width * 0.08, y: r.minY + r.height * 0.1), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.05))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - r.width * 0.15, y: r.minY + r.height * 0.35))
        p.closeSubpath(); return p
    }
}

private struct HappyEye: Shape {   // ^
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); return p
    }
}
