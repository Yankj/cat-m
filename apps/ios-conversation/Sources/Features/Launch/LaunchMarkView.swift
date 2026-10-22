import SwiftUI
import UIKit

/// First-install launch mark (first-run-polish). ≤ 1.1 s, skippable (tap), VoiceOver → skipped, Reduce Motion → still
/// mark + 0.25 s fade (`FirstRunAppearance.launch`).
///
/// Why 792587e stuttered: a full-frame-rate `TimelineView(.animation)` inside a `GeometryReader` rebuilt the whole tree
/// every frame, including a full-screen `RadialGradient` whose opacity changed per frame and a `.blur(radius:)` circle whose
/// FRAME changed per frame (the Gaussian blur is re-rasterised on every size change — the most expensive part), while the
/// splash underneath started its own entrance plus ten 30 fps TimelineViews at the same moment.
/// Now: no TimelineView / GeometryReader; one `keyframeAnimator` drives only scale/opacity of fixed-size layers (cheap to
/// composite), the glow is a pre-sized radial-gradient disc (no blur), the canvas is a static colour, and the splash waits
/// for `LaunchMarkView.didFinish` before starting its entrance.
@MainActor struct LaunchMarkView: View {
    var restoring: Bool = false
    /// Kept for API compatibility with the root gate (both now hand off with the same short fade).
    var toOrb: Bool = false
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var run = false
    @State private var finished = false

    /// True while a launch mark is on screen; the splash defers its entrance until `didFinish` is posted.
    static private(set) var isRunning = false
    static let didFinish = Notification.Name("CatpawLaunchMarkDidFinish")
    static let size: CGFloat = 112

    struct Frame { var mark = 0.82, markOpacity = 0.0, orb = 0.7, orbOpacity = 0.0, glow = 0.0 }

    var body: some View {
        let plan = FirstRunAppearance.launch(reduceMotion: reduceMotion, voiceOver: voiceOver)
        ZStack {
            Color("LaunchCanvas").ignoresSafeArea()
            if case .full = plan {
                Color.clear.keyframeAnimator(initialValue: Frame(), trigger: run) { _, f in mark(f) } keyframes: { _ in
                    KeyframeTrack(\.markOpacity) { CubicKeyframe(1, duration: 0.25); LinearKeyframe(1, duration: 0.40); CubicKeyframe(0, duration: 0.2) }
                    KeyframeTrack(\.mark) { SpringKeyframe(1.0, duration: 0.35, spring: .snappy); CubicKeyframe(1.05, duration: 0.3); CubicKeyframe(0.9, duration: 0.25) }
                    KeyframeTrack(\.orbOpacity) { LinearKeyframe(0, duration: 0.6); CubicKeyframe(1, duration: 0.25) }
                    KeyframeTrack(\.orb) { LinearKeyframe(0.7, duration: 0.6); SpringKeyframe(1.0, duration: 0.3, spring: .snappy) }
                    KeyframeTrack(\.glow) { CubicKeyframe(0.6, duration: 0.35); CubicKeyframe(1, duration: 0.55) }
                }
            } else {
                mark(Frame(mark: 1, markOpacity: 0, orb: 1, orbOpacity: 1, glow: 1))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }          // skippable
        .accessibilityHidden(true)
        .onAppear {
            Self.isRunning = true
            switch plan {
            case .skip: finish(animated: false)
            case .fade, .full: run = true
            }
        }
        .task {
            let hold: Double
            switch plan { case .skip: hold = 0; case .fade: hold = 0.3; case .full: hold = FirstRunAppearance.launchKeyframes[2] }
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            finish()
        }
    }

    private func mark(_ f: Frame) -> some View {
        let s = Self.size
        return ZStack {
            Circle().fill(RadialGradient(colors: [catColors.orbLight.opacity(0.32), catColors.orbLight.opacity(0)], center: .center, startRadius: s * 0.3, endRadius: s * 1.05))
                .frame(width: s * 2.1, height: s * 2.1)
                .opacity(f.glow)
            ZStack {
                Circle().fill(RadialGradient(colors: [catColors.orbLight, catColors.orbDeep], center: UnitPoint(x: 0.38, y: 0.32), startRadius: 2, endRadius: s * 0.55))
                BrandMark(size: s * 0.42, style: .onOrange)
            }
            .frame(width: s, height: s)
            .scaleEffect(f.orb)
            .opacity(f.orbOpacity)
            BrandMark(size: s, style: .fill)
                .scaleEffect(f.mark)
                .opacity(f.markOpacity)
        }
        .compositingGroup()
    }

    private func finish(animated: Bool = true) {
        guard !finished else { return }
        finished = true
        let fade: Double
        switch FirstRunAppearance.launch(reduceMotion: reduceMotion, voiceOver: voiceOver) {
        case .skip: fade = 0; case .fade(let d): fade = d; case .full(let total): fade = total - FirstRunAppearance.launchKeyframes[2]
        }
        if animated && fade > 0 { withAnimation(.easeOut(duration: fade)) { onFinished() } } else { onFinished() }
        Self.isRunning = false
        NotificationCenter.default.post(name: Self.didFinish, object: nil)
    }
}

/// Decide once per process whether to play.
@MainActor enum LaunchMarkGate {
    /// Decided once per process (App/RootView structs can be initialised more than once; every caller gets the same answer).
    /// Launch-loader fix: the splash belongs to the first run only (before 开始使用 completes). Every later launch goes
    /// straight from the static LaunchScreen to the chat's first frame — no animation, no interstitial.
    private static let decision: Bool = !UIAccessibility.isVoiceOverRunning && isFirstRun()
    nonisolated static func isFirstRun(_ defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        !(catOnboarding.isCompleted(defaults) || arguments.contains(catOnboarding.skipArgument))
    }
    static func shouldPlay(openedFromURLOrNotification: Bool) -> Bool { decision && !openedFromURLOrNotification }
}
