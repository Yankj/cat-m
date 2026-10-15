import SwiftUI
import UIKit

/// r11 "Paw frees your hands" launch (pure SwiftUI, ≤1.2s, always completes).
/// Frame 0 is pixel-identical to the static launch screen (Info.plist UILaunchScreen = `LaunchCanvas` colour +
/// `LaunchPaw` image, screen-centred, native point size). `LaunchPaw` is rendered by design/brand/render_brand.py as
/// `LaunchGlow` + `LaunchPawMark`, and this view draws exactly those two layers at the same size/position, so the
/// hand-off from the system launch screen has no gap or flash.
/// Timeline (s): 0–0.14 three task cards rise in · 0.16/0.33/0.50 paw taps card 1/2/3 (each pops into a check, light haptic)
/// · 0.50–0.82 paw lifts back and relaxes with a little bounce · 0.70–0.92 cards fly into the "Catpaw" wordmark
/// · 1.00–1.20 crossfade into the app. Reduce Motion: static mark, wordmark fades in, short crossfade.
@MainActor struct LaunchMarkView: View {
    /// Kept for call-site compatibility; the animation no longer waits on restore (it always completes ≤1.2s).
    var restoring: Bool = false
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = LaunchClock()
    @State private var taps = 0
    @State private var finished = false

    static let total: Double = 1.2
    static let tapTimes: [Double] = [0.16, 0.33, 0.50]
    static let cardX: [CGFloat] = [-78, 0, 78]
    static let cardY: CGFloat = 158
    static let wordY: CGFloat = 150

    var body: some View {
        TimelineView(.animation(paused: finished)) { context in
            // Startup can stall the main thread for a few hundred ms; the clock advances at most 1/30s per rendered
            // frame so every beat (taps, checks, bounce, fly-in) is actually seen instead of being skipped.
            let t = clock.advance(to: context.date)
            frame(LaunchFrame(t: t, reduceMotion: reduceMotion))
                .onChange(of: clock.beat(reduceMotion: reduceMotion)) { _, beat in
                    if beat > 0 && beat <= Self.tapTimes.count { taps = beat }
                    if beat > Self.tapTimes.count { finish() }
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.55), trigger: taps)
        .task {
            // Hard ceiling: even if frames never arrive, the overlay always goes away.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
            ForEach(0..<3, id: \.self) { i in
                LaunchTaskCard(checked: f.cardChecked[i], pop: f.cardPop[i])
                    .scaleEffect(f.cardScale[i])
                    .offset(x: f.cardOffset[i].width, y: f.cardOffset[i].height)
                    .opacity(f.cardOpacity[i])
            }
            Text(verbatim: "Catpaw")
                .font(CatpawTypography.Role.appTitle.font.weight(.bold))
                .fontDesign(.rounded)
                .fixedSize()   // semantic role → follows Dynamic Type; short brand word never wraps
                .kerning(0.4)
                .foregroundStyle(LaunchPalette.wordInk)
                .scaleEffect(f.wordScale)
                .offset(y: Self.wordY)
                .opacity(f.wordOpacity)
            Image("LaunchPawMark")
                .scaleEffect(x: f.pawScale * f.pawSquashX, y: f.pawScale * f.pawSquashY, anchor: .bottom)
                .offset(f.pawOffset)
        }
        .opacity(f.overlayOpacity)
    }

}

/// Frame-clamped animation clock (reference type so the TimelineView body can advance it without a state write).
final class LaunchClock {
    private(set) var t: Double = 0
    private var last: Date?
    private var first: Date?
    /// iOS cross-fades the system launch snapshot out over ~0.2s after the first app frame; hold frame 0 (identical
    /// pixels) for that long so the moving paw never ghosts over the fading static paw.
    static let systemHandoff: Double = 0.2
    func advance(to date: Date) -> Double {
        if first == nil { first = date }
        if let last, date.timeIntervalSince(first!) >= Self.systemHandoff { t += min(max(0, date.timeIntervalSince(last)), 1.0 / 30) }
        last = date
        return t
    }
    /// 0 before the first tap, 1…3 after each tap, 4 once the whole timeline is done.
    func beat(reduceMotion: Bool) -> Int {
        if reduceMotion { return t >= LaunchFrame.reducedTotal ? 4 : 0 }
        if t >= LaunchMarkView.total { return 4 }
        return LaunchMarkView.tapTimes.filter { t >= $0 }.count
    }
}

enum LaunchPalette {
    static let wordInk = Color(UIColor(rgb: 0x3A1E0E))
    static let cardLine = Color(UIColor(rgb: 0xE9C9B4))
    static let check = Color(UIColor(rgb: 0xF5843F))
}

/// Pure function of time → every animated value (deterministic; trivially testable, no state machine to stall).
struct LaunchFrame {
    static let reducedTotal = 0.45
    var cardOpacity = [Double](repeating: 0, count: 3)
    var cardScale = [CGFloat](repeating: 1, count: 3)
    var cardOffset = [CGSize](repeating: .zero, count: 3)
    var cardChecked = [false, false, false]
    var cardPop = [CGFloat](repeating: 0, count: 3)
    var pawOffset = CGSize.zero
    var pawScale: CGFloat = 1
    var pawSquashX: CGFloat = 1
    var pawSquashY: CGFloat = 1
    var wordOpacity: Double = 0
    var wordScale: CGFloat = 1
    var overlayOpacity: Double = 1

    static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
    static func span(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }
    static func mix(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }
    /// Damped "back" overshoot 0→1 used for the relax bounce and the check pop.
    static func back(_ x: Double) -> Double {
        let c = min(1, max(0, x)); let s = 2.2
        return 1 + (s + 1) * pow(c - 1, 3) + s * pow(c - 1, 2)
    }

    init(t: Double, reduceMotion: Bool) {
        if reduceMotion {
            wordOpacity = Self.span(t, 0.0, 0.2)
            overlayOpacity = 1 - Self.span(t, 0.25, Self.reducedTotal)
            return
        }
        let xs = LaunchMarkView.cardX, cy = LaunchMarkView.cardY, taps = LaunchMarkView.tapTimes
        // Cards rise in
        for i in 0..<3 {
            let k = Self.span(t, 0.0 + Double(i) * 0.03, 0.12 + Double(i) * 0.03)
            cardOpacity[i] = k
            cardOffset[i] = CGSize(width: xs[i], height: cy + CGFloat((1 - k) * 14))
            cardChecked[i] = t >= taps[i] + 0.02
            cardPop[i] = CGFloat(t >= taps[i] ? Self.back((t - taps[i]) / 0.16) : 0)
            cardScale[i] = t >= taps[i] && t < taps[i] + 0.06 ? 0.93 : 1
        }
        // Paw path: centre → each card (small, tap) → back to centre with a relaxed bounce.
        let tapScale: CGFloat = 0.5
        let tapY = cy + 26 - 80 * tapScale   // paw bottom (anchor) rests on the card
        func at(_ i: Int) -> CGSize { CGSize(width: xs[i], height: tapY) }
        if t < taps[0] {
            let k = Self.span(t, 0.04, taps[0])
            pawOffset = CGSize(width: Self.mix(0, xs[0], k), height: Self.mix(0, tapY, k))
            pawScale = Self.mix(1, tapScale, k)
        } else if t < taps[2] {
            let i = t < taps[1] ? 0 : 1
            let k = Self.span(t, taps[i] + 0.05, taps[i + 1])
            let hop = CGFloat(sin(Double.pi * k)) * -18
            pawOffset = CGSize(width: Self.mix(xs[i], xs[i + 1], k), height: tapY + hop)
            pawScale = tapScale
        } else {
            let k = Self.span(t, taps[2] + 0.05, 0.72)
            let lift = CGFloat(sin(Double.pi * k)) * -30
            pawOffset = CGSize(width: Self.mix(xs[2], 0, k), height: Self.mix(tapY, 0, k) + lift)
            pawScale = Self.mix(tapScale, 1, Self.back(min(1, (t - taps[2] - 0.05) / 0.3)))
        }
        // Press squash at each tap, and a soft relax wobble when the paw settles.
        for tap in taps where t >= tap - 0.01 && t < tap + 0.07 {
            let k = sin(Double.pi * (t - tap + 0.01) / 0.08)
            pawSquashX = 1 + CGFloat(k) * 0.08; pawSquashY = 1 - CGFloat(k) * 0.12
        }
        if t >= 0.72 && t < 0.9 {
            let k = (t - 0.72) / 0.18
            let w = sin(k * Double.pi * 2) * (1 - k)
            pawSquashX = 1 + CGFloat(w) * 0.05; pawSquashY = 1 - CGFloat(w) * 0.05
        }
        // Cards fly into the wordmark.
        for i in 0..<3 where t >= 0.70 {
            let k = Self.span(t, 0.70 + Double(i) * 0.03, 0.88 + Double(i) * 0.03)
            cardOffset[i] = CGSize(width: Self.mix(xs[i], 0, k), height: Self.mix(cy, LaunchMarkView.wordY, k) - CGFloat(sin(Double.pi * k)) * 20)
            cardScale[i] = Self.mix(1, 0.2, k)
            cardOpacity[i] = 1 - Self.span(t, 0.82 + Double(i) * 0.03, 0.92 + Double(i) * 0.03)
        }
        wordOpacity = Self.span(t, 0.80, 0.94)
        wordScale = Self.mix(0.86, 1, Self.back((t - 0.80) / 0.2))
        overlayOpacity = 1 - Self.span(t, 1.0, LaunchMarkView.total)
    }
}

/// A tiny to-do card that pops into a check when the paw taps it. Text-free (lines only), so no orange text.
private struct LaunchTaskCard: View {
    var checked: Bool
    var pop: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.94))
            .frame(width: 62, height: 44)
            .shadow(color: Color(UIColor(rgb: 0x8A3A12)).opacity(0.18), radius: 6, y: 3)
            .overlay {
                ZStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(LaunchPalette.cardLine).frame(width: 34, height: 4)
                        Capsule().fill(LaunchPalette.cardLine).frame(width: 22, height: 4)
                    }
                    .opacity(checked ? 0 : 1)
                    Circle().fill(LaunchPalette.check).frame(width: 24, height: 24)
                        .overlay { Image(systemName: "checkmark").font(CatpawTypography.Role.caption.font.weight(.heavy)).foregroundStyle(.white) }
                        .scaleEffect(checked ? max(0.01, pop) : 0.01)
                        .opacity(checked ? 1 : 0)
                }
            }
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
