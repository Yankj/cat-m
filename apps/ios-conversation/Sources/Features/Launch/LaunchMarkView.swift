import SwiftUI
import UIKit

/// Launch splash matching docs/refs/launch-splash-keyframes.png.
/// Soft beige canvas; four keyframes (~1.3 s), always completes:
/// 0.0s 浮现 — warm-orange cat-head mark visible immediately (matches static launch)
/// 0.3s 轻触 — solid cat-head mark forms
/// 0.7s 呼吸 — slight scale-up + soft outer glow
/// 1.1s 衔接 — merges into solid orange circle (white cat-head mark) with glow, then enters landing/main
/// Soft spring-like eased windows. Reduce Motion: short fade of the final circle only.
/// `toOrb`: next screen is onboarding — leave the circle in place for a seamless handoff to NativeLoginView.
@MainActor struct LaunchMarkView: View {
    var restoring: Bool = false
    /// true → next screen is onboarding: keep the merged circle; false → chat: fade the whole splash out.
    var toOrb: Bool = false
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var finished = false

    /// End of merge hold before calling `onFinished`.
    static let total: Double = 1.45

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: finished)) { context in
                let t = reduceMotion ? Self.total : min(Self.total, start.map { context.date.timeIntervalSince($0) } ?? 0)
                content(t: t, width: geo.size.width, height: geo.size.height)
                    .onChange(of: t >= Self.total) { _, done in if done { finish() } }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { if start == nil { start = Date() } }
        .task {
            try? await Task.sleep(nanoseconds: UInt64((reduceMotion ? 0.45 : Self.total + 0.25) * 1_000_000_000))
            finish()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeOut(duration: reduceMotion ? 0.28 : 0.22)) { onFinished() }
    }

    private static func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        // Soft ease-out-cubic (spring-like settle without oscillation).
        return 1 - pow(1 - c, 3)
    }
    private static func window(_ t: Double, _ a: Double, _ b: Double) -> Double {
        guard b > a else { return t >= b ? 1 : 0 }
        return min(1, max(0, (t - a) / (b - a)))
    }

    private func content(t: Double, width: CGFloat, height: CGFloat) -> some View {
        let size = max(96, width * 0.28)
        // 0.0 → 0.3 浮现：opacity + slight scale
        let emerge = 1.0 // visible from frame 0: continues the static launch cat-head, no blank first second
        // 0.3 → 0.55 轻触：reach full solid
        let form = Self.ease(Self.window(t, 0.22, 0.45))
        // 0.7 → 1.0 呼吸：scale + glow
        let breathe = Self.ease(Self.window(t, 0.55, 0.85))
        let breathPulse = 1 + 0.06 * breathe
        // 1.1 → 1.35 衔接：circle blooms; mark turns white inside
        let merge = Self.ease(Self.window(t, 1.05, 1.32))
        // Chat exit: fade splash after merge. Onboarding: keep circle, fade only the pre-merge mark layer.
        let exitFade = toOrb ? 1.0 : 1 - Self.ease(Self.window(t, 1.32, Self.total))
        let markOpacity = (1 - merge) * exitFade
        let circleOpacity = merge * exitFade
        let glowStrength = (0.15 + 0.55 * breathe + 0.35 * merge) * emerge * exitFade
        let markScale = (0.96 + 0.04 * form) * breathPulse * (1 - 0.08 * merge)
        let circleScale = 0.72 + 0.28 * merge

        return ZStack {
            ZStack {
                Color("LaunchCanvas")
                // Soft radial warm wash (matches cream/beige keyframes).
                RadialGradient(
                    colors: [
                        CatpawColors.orbLight.opacity(0.22 * glowStrength),
                        CatpawColors.calmPage.opacity(0),
                    ],
                    center: .center,
                    startRadius: 4,
                    endRadius: max(width, height) * 0.55
                )
            }
            .opacity(toOrb ? 1 : exitFade)

            // Soft outer glow behind mark / circle.
            Circle()
                .fill(CatpawColors.orbLight.opacity(0.35 * glowStrength))
                .frame(width: size * (1.6 + 0.35 * breathe + 0.25 * merge))
                .blur(radius: size * 0.28)
                .opacity(emerge * exitFade)

            // Merged brand circle (final keyframe + onboarding handoff).
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [CatpawColors.orbLight, CatpawColors.orbDeep],
                            center: UnitPoint(x: 0.38, y: 0.32),
                            startRadius: 2,
                            endRadius: size * 0.55
                        )
                    )
                    .overlay(
                        Circle()
                            .fill(LinearGradient(colors: [CatpawColors.calmGlyph.opacity(0.32), .clear], startPoint: .top, endPoint: .center))
                            .padding(size * 0.08)
                    )
                    .shadow(color: CatpawColors.orbDeep.opacity(0.38 * merge), radius: 18, y: 8)
                BrandMark(size: size * 0.42, style: .onOrange)
            }
            .frame(width: size, height: size)
            .scaleEffect(circleScale)
            .opacity(circleOpacity)

            // Pre-merge warm-orange cat-head mark (keyframes 1–3).
            BrandMark(size: size, style: .fill)
                .scaleEffect(markScale)
                .opacity(markOpacity)
        }
    }
}

/// Decide once per process whether to play.
@MainActor enum LaunchMarkGate {
    /// Decided once per process (App/RootView structs can be initialised more than once; every caller gets the same answer).
    private static let decision: Bool = !UIAccessibility.isVoiceOverRunning
    static func shouldPlay(openedFromURLOrNotification: Bool) -> Bool { decision && !openedFromURLOrNotification }
}
