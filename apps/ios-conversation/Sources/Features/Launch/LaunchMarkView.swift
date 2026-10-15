import SwiftUI
import UIKit

/// Launch (user-approved jelly paw): brand-orange jelly paw (~25% of screen width) centred on `LaunchCanvas`.
/// Frame 0 matches the static launch screen (plain `LaunchCanvas`), the paw is on screen from the first frame.
/// In-place only, ~1 s, always completes:
/// 0–0.14 pop-in · 0.14–0.34 soft press-squash + bounce · 0.36/0.45/0.54/0.63 toe beans tap in sequence (light haptic)
/// · 0.30–0.80 glossy highlight sweep · 0.55–0.80 "Catpaw" wordmark rises in · 0.86–1.0 crossfade into the app.
/// Reduce Motion: static mark + wordmark, short fade.
@MainActor struct LaunchMarkView: View {
    var restoring: Bool = false
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set on the first rendered frame, so a slow cold start never skips the beats.
    @State private var start: Date?
    @State private var finished = false
    @State private var taps = 0

    static let total: Double = 1.0
    static let toeTimes: [Double] = [0.36, 0.45, 0.54, 0.63]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: finished)) { context in
                let t = reduceMotion ? 0.9 : min(Self.total, start.map { context.date.timeIntervalSince($0) } ?? 0)
                content(t: t, width: geo.size.width)
                    .onChange(of: Self.beat(t)) { _, b in taps = b; if t >= Self.total { finish() } }
                    .onChange(of: t >= Self.total) { _, done in if done { finish() } }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: taps)
        .onAppear { if start == nil { start = Date() } }
        .task {
            try? await Task.sleep(nanoseconds: UInt64((reduceMotion ? 0.5 : Self.total + 0.3) * 1_000_000_000))
            finish()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            finish()
        }
    }

    static func beat(_ t: Double) -> Int { toeTimes.filter { t >= $0 }.count }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    private static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return 1 - pow(1 - c, 3) }
    private static func window(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }

    private func content(t: Double, width: CGFloat) -> some View {
        let size = max(88, width * 0.25)
        // pop-in
        let pop = 0.92 + 0.08 * Self.ease(Self.window(t, 0, 0.14))
        // press-squash with a damped bounce
        let p = Self.window(t, 0.14, 0.34)
        let squash = p < 0.4 ? -0.10 * (p / 0.4) : -0.10 * cos((p - 0.4) / 0.6 * .pi * 1.5) * (1 - (p - 0.4) / 0.6)
        let sx = 1 - squash * 0.6, sy = 1 + squash
        let pressed: [Bool] = (0..<4).map { i in t >= Self.toeTimes[i] && t < Self.toeTimes[i] + 0.08 } + [p > 0.05 && p < 0.4]
        let sweep = CGFloat(Self.ease(Self.window(t, 0.30, 0.80)))
        let word = Self.ease(Self.window(t, 0.55, 0.80))
        let fade = 1 - Self.window(t, 0.86, 1.0)
        return ZStack {
            Color("LaunchCanvas")
            VStack(spacing: size * 0.18) {
                PawMark(size: size, color: CatpawColors.action, pressed: pressed, sweep: sweep)
                    .scaleEffect(x: pop * sx, y: pop * sy, anchor: .bottom)
                Text(verbatim: "Catpaw")
                    .font(.title.weight(.bold)).fontDesign(.rounded)
                    .foregroundStyle(CatpawColors.ink)
                    .opacity(word).offset(y: (1 - word) * 8)
            }
            .offset(y: size * 0.12)
        }
        .opacity(fade)
    }
}

/// Decide once per process whether to play.
@MainActor enum LaunchMarkGate {
    /// Decided once per process (App/RootView structs can be initialised more than once; every caller gets the same answer).
    private static let decision: Bool = !UIAccessibility.isVoiceOverRunning
    static func shouldPlay(openedFromURLOrNotification: Bool) -> Bool { decision && !openedFromURLOrNotification }
}
