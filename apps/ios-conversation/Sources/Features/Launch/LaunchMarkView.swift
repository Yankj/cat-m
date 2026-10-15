import SwiftUI
import UIKit

/// r11b launch: one cute centred jelly paw, animated in place (≤1.0s, motion from frame 0, always completes).
/// Frame 0 is pixel-identical to the static launch screen (Info.plist UILaunchScreen = `LaunchCanvas` colour +
/// `LaunchPaw` image, screen-centred, native point size). `LaunchPaw` = `LaunchGlow` + `LaunchPawMark`, and
/// `LaunchPawMark` is itself the composite of `LaunchPawPad` + `LaunchPawToe0…3` (design/brand/render_brand.py),
/// so this view draws exactly the same pixels at the same place. The paw never leaves its position, so the system
/// launch snapshot cross-fading out underneath never shows as a ghost.
/// Timeline (s): 0–0.36 soft squash → stretch → settle bounce · 0.18–0.60 toes spread and curl in sequence (a tiny wave)
/// · 0.28–0.68 highlight shimmer sweeps across the pads · 0.52–0.72 "Catpaw" wordmark fades up · 0.80–1.00 crossfade.
/// Reduce Motion: static paw, wordmark fades in, short crossfade.
@MainActor struct LaunchMarkView: View {
    /// Kept for call-site compatibility; the animation never waits on restore.
    var restoring: Bool = false
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = LaunchClock()
    @State private var beat = 0
    @State private var finished = false

    static let total: Double = 1.0
    static let pawPoints: CGFloat = 160
    static let wordY: CGFloat = 128
    /// Toe centres in the paw's 24-unit grid (PawMark.pads indices 3…6).
    static let toes: [(CGFloat, CGFloat)] = [(4.9, 9.7), (9.3, 5.3), (14.7, 5.3), (19.1, 9.7)]

    var body: some View {
        TimelineView(.animation(paused: finished)) { context in
            // Startup can stall the main thread; the clock advances at most 1/30s per rendered frame so every beat is seen.
            let t = clock.advance(to: context.date)
            frame(LaunchFrame(t: t, reduceMotion: reduceMotion))
                .onChange(of: clock.beat(reduceMotion: reduceMotion)) { _, value in
                    if value == 1 { beat += 1 }
                    if value == 2 { finish() }
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: beat)
        .task {
            // Hard ceiling: even if frames never arrive, the overlay always goes away.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    private func frame(_ f: LaunchFrame) -> some View {
        ZStack {
            Color("LaunchCanvas")
            Image("LaunchGlow")
            Text(verbatim: "Catpaw")
                .font(CatpawTypography.Role.appTitle.font.weight(.bold))
                .fontDesign(.rounded)
                .fixedSize()   // semantic role → follows Dynamic Type; short brand word never wraps
                .kerning(0.4)
                .foregroundStyle(LaunchPalette.wordInk)
                .offset(y: Self.wordY + f.wordRise)
                .opacity(f.wordOpacity)
            paw(f)
                .scaleEffect(x: f.squashX, y: f.squashY, anchor: UnitPoint(x: 0.5, y: 0.9))
                .offset(y: f.lift)
        }
        .opacity(f.overlayOpacity)
    }

    private func paw(_ f: LaunchFrame) -> some View {
        ZStack {
            Image("LaunchPawPad")
            ForEach(0..<4, id: \.self) { i in
                let (cx, cy) = Self.toes[i]
                Image("LaunchPawToe\(i)")
                    .scaleEffect(f.toeScale[i], anchor: UnitPoint(x: cx / 24, y: cy / 24))
                    .offset(f.toeOffset[i])
            }
            // Gentle highlight shimmer, clipped to the paw's own pixels.
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 56, height: Self.pawPoints * 1.4)
                .rotationEffect(.degrees(20))
                .offset(x: f.shimmerX)
                .opacity(f.shimmerOpacity)
                .blendMode(.plusLighter)
                .mask(Image("LaunchPawMark"))
        }
        .frame(width: Self.pawPoints, height: Self.pawPoints)
    }
}

/// Frame-clamped animation clock (reference type so the TimelineView body can advance it without a state write).
final class LaunchClock {
    private(set) var t: Double = 0
    private var last: Date?
    func advance(to date: Date) -> Double {
        if let last { t += min(max(0, date.timeIntervalSince(last)), 1.0 / 30) }
        last = date
        return t
    }
    /// 0 → 1 at the squash (haptic) → 2 once the timeline is done.
    func beat(reduceMotion: Bool) -> Int {
        if reduceMotion { return t >= LaunchFrame.reducedTotal ? 2 : 0 }
        if t >= LaunchMarkView.total { return 2 }
        return t >= 0.08 ? 1 : 0
    }
}

enum LaunchPalette {
    static let wordInk = Color(UIColor(rgb: 0x3A1E0E))
}

/// Pure function of time → every animated value (deterministic, no state machine to stall).
struct LaunchFrame {
    static let reducedTotal = 0.45
    var squashX: CGFloat = 1
    var squashY: CGFloat = 1
    var lift: CGFloat = 0
    var toeScale = [CGFloat](repeating: 1, count: 4)
    var toeOffset = [CGSize](repeating: .zero, count: 4)
    var shimmerX: CGFloat = -120
    var shimmerOpacity: Double = 0
    var wordOpacity: Double = 0
    var wordRise: CGFloat = 8
    var overlayOpacity: Double = 1

    static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
    static func span(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    init(t: Double, reduceMotion: Bool) {
        if reduceMotion {
            wordOpacity = Self.span(t, 0.0, 0.2); wordRise = 0
            overlayOpacity = 1 - Self.span(t, 0.25, Self.reducedTotal)
            return
        }
        // Squash–stretch–settle: a damped spring on the vertical scale, volume roughly preserved.
        if t < 0.36 {
            let k = t / 0.36
            let wave = sin(k * Double.pi * 2.5) * exp(-3.2 * k)        // + = squash, − = stretch
            squashY = 1 - CGFloat(wave) * 0.10
            squashX = 1 + CGFloat(wave) * 0.07
            lift = CGFloat(max(0, -wave)) * -10
        }
        // Toes: spread outward + up, then curl in a little, staggered like a tiny wave (left → right).
        for i in 0..<4 {
            let start = 0.18 + Double(i) * 0.06
            let k = Self.clamp01((t - start) / 0.24)
            guard k > 0 && k < 1 else { continue }
            let (cx, cy) = LaunchMarkView.toes[i]
            let dx = (cx - 12) / 12, dy = (cy - 12) / 12                // outward direction from paw centre
            let spread = sin(k * Double.pi) * (1 - k * 0.35)            // out then back
            let curl = k > 0.55 ? sin((k - 0.55) / 0.45 * Double.pi) : 0 // small inward curl at the end
            let u = LaunchMarkView.pawPoints / 24
            toeOffset[i] = CGSize(width: dx * u * CGFloat(spread) * 1.1, height: (dy * u * 1.1 - 1.5 * u) * CGFloat(spread) + u * 0.6 * CGFloat(curl))
            toeScale[i] = 1 + CGFloat(spread) * 0.10 - CGFloat(curl) * 0.06
        }
        // Highlight shimmer sweep.
        let s = Self.clamp01((t - 0.28) / 0.40)
        shimmerX = -110 + 220 * CGFloat(Self.ease(s))
        shimmerOpacity = s > 0 && s < 1 ? sin(s * Double.pi) : 0
        // Wordmark, then crossfade into the app.
        wordOpacity = Self.span(t, 0.52, 0.72)
        wordRise = 8 * CGFloat(1 - Self.span(t, 0.52, 0.76))
        overlayOpacity = 1 - Self.span(t, 0.80, LaunchMarkView.total)
    }
}

/// Decide once per process whether to play.
@MainActor enum LaunchMarkGate {
    private static var played = false
    static func shouldPlay(openedFromURLOrNotification: Bool) -> Bool {
        defer { played = true }
        return !played && !openedFromURLOrNotification && !UIAccessibility.isVoiceOverRunning
    }
}
