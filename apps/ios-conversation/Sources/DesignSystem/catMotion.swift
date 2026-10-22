import SwiftUI
import UIKit

/// R7 motion tokens (docs/design/ios26-swift-mapping-r7.md §1). Every call site goes through `resolved` so
/// Reduce Motion collapses springs to a short ease.
enum catMotion {
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

/// Identity colours and the cat-head mark. Hex lives in `catBrandTokens`;
/// `paw` / clay roles alias semantic `catColors` so there is one palette.
/// Composer send/stop chrome may keep using `catBrand.paw` (Mac worker owns morph).
enum catBrand {
    /// Alias of `catColors.fill` (Primary #FF702A). Fills/icons only — never body text.
    static var paw: Color { catColors.fill }
    static var clayLight: Color { catColors.orbLight }
    static var clayBase: Color { catColors.fill }
    static var clayRim: Color { catColors.actionText }
    static var clayShadow: Color { Color(UIColor(rgb: catBrandTokens.clayShadow)) }
    static var clayHighlight: Color { catColors.calmGlyph }
}

/// Cat-head brand mark from `Assets.xcassets/catBrand/`.
/// Prefer this over `PawMark` for identity (splash, landing orb, sidebar header).
/// Category pastel markers may still use `PawMark`.
struct BrandMark: View {
    var size: CGFloat
    var color: Color = catColors.fill
    /// `template` tints with `color`; `fill` = orange silhouette; `onOrange` = white on orange orbs.
    var style: Style = .template
    enum Style { case template, fill, onOrange }
    var body: some View {
        Group {
            switch style {
            case .template:
                Image("BrandMark").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(color)
            case .fill:
                Image("BrandMarkFill").resizable().scaledToFit()
            case .onOrange:
                Image("BrandMarkOnOrange").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Flat pastel category marker (tool cards, proactive inbox, memory library) — NOT a brand/identity mark.
/// The old glossy "jelly" paw (press/sweep/scatter launch animation) was removed; launch uses `BrandMark`.
struct PawMark: View {
    var size: CGFloat
    var color: Color = catColors.fill
    var shadow: Bool = false
    var body: some View {
        PawShape().fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Pastel category palette for small markers (tool cards, proactive inbox, memory chips).
enum catCategory: String, CaseIterable, Sendable {
    case calendar, email, sms, phone, shopping, memory, maps, reminder
    var tint: Color {
        switch self {
        case .calendar, .reminder: catPastel.lavender
        case .email: catPastel.blue
        case .sms: catPastel.mint
        case .phone: catPastel.pink
        case .shopping: catPastel.yellow
        case .memory, .maps: catPastel.warmGray
        }
    }
    static func forTool(_ tool: String) -> catCategory {
        if tool.hasPrefix("calendar") { return .calendar }
        if tool.hasPrefix("reminder") || tool.hasPrefix("alarm") { return .reminder }
        if tool.hasPrefix("mail") { return .email }
        if tool.hasPrefix("sms") { return .sms }
        if tool.hasPrefix("phone") || tool.hasPrefix("contacts") { return .phone }
        if tool.hasPrefix("shop") { return .shopping }
        if tool.hasPrefix("maps") { return .maps }
        return .memory
    }
}
enum catPastel {
    static let lavender = Color(UIColor(rgb: 0xCDB8EC))
    static let pink = Color(UIColor(rgb: 0xF5B3CB))
    static let blue = Color(UIColor(rgb: 0xA9C8F5))
    static let yellow = Color(UIColor(rgb: 0xF6D58E))
    static let mint = Color(UIColor(rgb: 0xA8DEC8))
    static let warmGray = Color(UIColor(rgb: 0xC9C0B8))
}
/// Small pastel paw used as a category marker.
struct CategoryPaw: View {
    var category: catCategory
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    var body: some View { PawMark(size: size, color: category.tint, shadow: false) }
}

/// Grok-style functional icon: line glyph inside a circular base. Idle = light circle + ink glyph; active = ink circle + white glyph.
struct CircleIcon: View {
    var systemName: String
    var active: Bool = false
    var diameter: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(active ? catColors.ink : catColors.card)
                .overlay(Circle().strokeBorder(catColors.hairline.opacity(active ? 0 : 1), lineWidth: 0.5))
            Image(systemName: systemName).imageScale(.medium).fontWeight(.medium)
                .foregroundStyle(active ? catColors.onInk : catColors.ink)
        }
        .frame(width: diameter, height: diameter)
        .animation(.snappy(duration: 0.18), value: active)
    }
}
/// Button style that flips CircleIcon to its active pair while pressed.
struct CircleIconButtonStyle: ButtonStyle {
    var systemName: String
    var selected: Bool = false
    var diameter: CGFloat = 36
    func makeBody(configuration: Configuration) -> some View {
        CircleIcon(systemName: systemName, active: selected || configuration.isPressed, diameter: diameter)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(Circle())
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// Vector 4-pad category marker (24pt grid). Identity surfaces use `BrandMark` / soft-3D `catPresence` — not this shape.
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
struct BreathingPaw: View {   // r10: the thinking indicator is now catPresence (slow blink while waiting)
    var active: Bool
    @ScaledMetric(relativeTo: .body) private var size = 22.0
    var body: some View { catPresence(state: .waiting, size: size).opacity(active ? 1 : 0.72) }
}

// MARK: r8 tokens (composer + top bar)
extension catColors {
    /// Composer pill fill (#F2F2F4 / #1C1C1E) and its 0.5pt hairline.
    static let composerPill = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x1C1C1E) : UIColor(rgb: 0xF2F2F4) })
    /// ink3 (#A3A7AE): meta line, model label, chevron, offline dot.
}
extension catMotion {
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

/// Soft-3D header / presence cat (`docs/refs/header-cat/six-states.png`).
/// Six poses L→R: idle · spin · wobble · orbit-load · happy · ears-down(offline).
/// Clay `#FF702A` body — not flat `BrandMark`. Reduce Motion → static pose.
enum catPresenceState: Equatable {
    case waiting    // 1 idle/calm
    case streaming  // 2 spin
    case error      // 3 wobble
    case thinking   // 4 orbit-load (also used for tool work)
    case working    // 4 orbit-load (alias pose)
    case done       // 5 happy ^_^
    case offline    // 6 ears-down
}

struct catPresence: View {
    var state: catPresenceState
    var size: CGFloat = 22
    /// Bumped by the host on each revealed chunk while streaming → subtle nod.
    var revealTick: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false
    @State private var tilt = false
    @State private var twitch = false
    @State private var orbit = false
    @State private var bounce = false
    @State private var nod = false
    @State private var spin = false
    @State private var wobble = false

    var body: some View {
        let u = size / 24
        // Soft clay #FF702A family — matches brand primary / App Icon, not flat BrandMark.
        let clay = RadialGradient(
            stops: [
                .init(color: catBrand.clayLight, location: 0),
                .init(color: catBrand.clayBase, location: 0.55),
                .init(color: catBrand.clayRim, location: 1),
            ],
            center: UnitPoint(x: 0.36, y: 0.28),
            startRadius: 0,
            endRadius: 15 * u
        )
        let earsDown = state == .offline
        let earDrop: Double = earsDown ? 52 : (state == .error ? 10 : (state == .working || state == .thinking ? -6 : 0))
        ZStack {
            Ellipse()
                .fill(catBrand.clayShadow.opacity(0.20))
                .frame(width: 16 * u, height: 2.6 * u)
                .blur(radius: 1.2 * u)
                .offset(y: 11.6 * u)

            ZStack {
                CatEar().fill(clay).frame(width: 7 * u, height: 7 * u)
                    .rotationEffect(.degrees((-14 - earDrop) - (twitch ? 10 : 0)), anchor: .bottom)
                    .offset(x: -6 * u, y: earsDown ? -4.2 * u : -7.6 * u)
                CatEar().fill(clay).frame(width: 7 * u, height: 7 * u)
                    .rotationEffect(.degrees(14 + earDrop), anchor: .bottom)
                    .offset(x: 6 * u, y: earsDown ? -4.2 * u : -7.6 * u)

                Ellipse().fill(clay).frame(width: 21 * u, height: 18 * u).offset(y: 1.5 * u)
                Ellipse().fill(catBrand.clayHighlight.opacity(0.35))
                    .frame(width: 5 * u, height: 3 * u).blur(radius: 0.8 * u)
                    .offset(x: -4.5 * u, y: -3.2 * u)

                eyes(u).offset(y: (state == .streaming ? 3.4 : 2.2) * u)

                if state == .error {
                    wobbleTicks(u, side: -1)
                    wobbleTicks(u, side: 1)
                }
                if state == .done {
                    happyTicks(u, side: -1)
                    happyTicks(u, side: 1)
                }
            }
            .rotationEffect(.degrees(headTiltDegrees))
            .offset(y: (bounce ? -3 * u : 0) + (nod ? 0.8 * u : 0))

            if state == .streaming {
                spinArrows(u)
                    .rotationEffect(.degrees(spin ? 360 : 0))
            }

            if state == .thinking || state == .working {
                Circle()
                    .stroke(catBrand.clayBase.opacity(0.55), lineWidth: 1.2 * u)
                    .frame(width: 26 * u, height: 26 * u)
                    .offset(y: -1 * u)
                Circle()
                    .fill(catBrand.clayRim)
                    .frame(width: 3.2 * u, height: 3.2 * u)
                    .offset(y: -14 * u)
                    .rotationEffect(.degrees(orbit ? 360 : 0))
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

    private var headTiltDegrees: Double {
        switch state {
        case .streaming: return spin ? 12 : -8
        case .error: return wobble ? 14 : -14
        case .thinking: return tilt ? -9 : 0
        default: return 0
        }
    }

    @ViewBuilder private func eyes(_ u: CGFloat) -> some View {
        HStack(spacing: 6 * u) {
            ForEach(0..<2, id: \.self) { _ in
                switch state {
                case .done:
                    HappyEye().stroke(catColors.ink, style: StrokeStyle(lineWidth: 1.3 * u, lineCap: .round))
                        .frame(width: 3.4 * u, height: 2 * u)
                case .offline, .error:
                    Capsule().fill(catColors.ink).frame(width: 3.6 * u, height: 1.15 * u)
                default:
                    Capsule().fill(catColors.ink)
                        .frame(width: 2.3 * u, height: (blink ? 0.4 : 2.6) * u)
                }
            }
        }
    }

    private func wobbleTicks(_ u: CGFloat, side: CGFloat) -> some View {
        VStack(spacing: 1.2 * u) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(catBrand.clayRim.opacity(0.55))
                    .frame(width: (2.2 + CGFloat(i) * 0.4) * u, height: 0.7 * u)
                    .rotationEffect(.degrees(Double(side) * -25))
            }
        }
        .offset(x: side * 14 * u, y: 1 * u)
    }

    private func happyTicks(_ u: CGFloat, side: CGFloat) -> some View {
        VStack(spacing: 1.1 * u) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule().fill(catBrand.clayRim.opacity(0.5))
                    .frame(width: 2.4 * u, height: 0.65 * u)
            }
        }
        .offset(x: side * 13.5 * u, y: 0.5 * u)
    }

    private func spinArrows(_ u: CGFloat) -> some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(catBrand.clayRim.opacity(0.7), style: StrokeStyle(lineWidth: 1.4 * u, lineCap: .round))
                    .frame(width: 28 * u, height: 28 * u)
                    .rotationEffect(.degrees(Double(i) * 180))
            }
        }
    }

    private func start() {
        blink = false; tilt = false; twitch = false; orbit = false; bounce = false; nod = false; spin = false; wobble = false
        guard !reduceMotion else { return }
        switch state {
        case .waiting:
            withAnimation(.easeInOut(duration: 0.18).delay(1.6).repeatForever(autoreverses: true)) { blink = true }
        case .thinking, .working:
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { orbit = true }
            withAnimation(.smooth(duration: 1.4).repeatForever(autoreverses: true)) { tilt = true }
        case .streaming:
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) { nod = true }
        case .done:
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.2)) { bounce = true }
            withAnimation(.smooth(duration: 0.3).delay(0.32)) { bounce = false }
        case .error:
            withAnimation(.easeInOut(duration: 0.22).repeatForever(autoreverses: true)) { wobble = true }
        case .offline:
            break
        }
    }
}

private struct CatEar: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.midX - r.width * 0.08, y: r.minY + r.height * 0.1), control: CGPoint(x: r.minX + r.width * 0.15, y: r.minY + r.height * 0.35))
        p.addQuadCurve(to: CGPoint(x: r.midX + r.width * 0.08, y: r.minY + r.height * 0.1), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.05))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - r.width * 0.15, y: r.minY + r.height * 0.35))
        p.closeSubpath(); return p
    }
}

private struct HappyEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}
