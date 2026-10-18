import SwiftUI

/// SPEC-E §5.1: the landing hero. The plush cat (`MascotFront`, 120 pt) sits over a static warm glow and a ground shadow, and
/// replaces the orange `CalmOrb`. Entrance follows §2.1 and the idle loop §2.3: breathing, a blink (the derived
/// `MascotFrontBlink` frame) and a small decaying head tilt standing in for an ear twitch. Nothing bounces. The idle loop is
/// the landing's only ticking clock. It runs at 30 Hz, transforms only, and pauses under Reduce Motion, when the scene is
/// not active, and from the tap onward. The glow is a RadialGradient in a fixed frame (no blur).
struct FirstRunPlushHero: View {
    enum Phase: Equatable {
        case hidden      // before the landing is visible
        case shown       // entrance (§2.1); the idle loop joins at entrance("idle")
        case leaving     // tap: anticipation squash, glow fades; image still here
        case flown       // the overlay's flying cat has taken over: image + shadow hidden, no animation
    }
    var phase: Phase
    var size: CGFloat = CGFloat(FirstRunAppearance.heroSize)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    @State private var idleReady = false
    @State private var idleStart = Date()
    @State private var squash = false

    private typealias Idle = FirstRunAppearance.Idle

    var body: some View {
        let visible = phase != .hidden
        let flown = phase == .flown
        let leaving = phase == .leaving || flown
        let s = { (id: String) in FirstRunAppearance.entranceStart(id, reduceMotion: reduceMotion) }
        let fadeIn = Animation.easeOut(duration: 0.2)
        ZStack {
            // Static glow (§1 calmGlow), fixed frame; only its opacity ever animates.
            Circle()
                .fill(RadialGradient(colors: [CatpawColors.calmGlow, CatpawColors.calmGlow.opacity(0)], center: .center, startRadius: 0, endRadius: size * 0.95))
                .frame(width: size * 1.9, height: size * 1.9)
                .opacity(visible && !leaving ? 1 : 0)
                .animation(leaving ? .linear(duration: 0.40).delay(0.05)
                           : (reduceMotion ? fadeIn.delay(s("glow")) : .spring(response: 0.6, dampingFraction: 0.95).delay(s("glow"))), value: visible && !leaving)
            idleLayer(visible: visible, flown: flown)
        }
        .frame(width: size, height: size)
        .onChange(of: phase) { _, p in
            if p == .shown { scheduleIdle() }
            if p == .leaving, !reduceMotion { anticipate() }
            if p == .hidden { idleReady = false }
        }
        .onAppear { if phase == .shown { scheduleIdle() } }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func idleLayer(visible: Bool, flown: Bool) -> some View {
        let ticking = !reduceMotion && idleReady && phase == .shown && scene == .active
        TimelineView(.animation(minimumInterval: 1 / Idle.fps, paused: !ticking)) { ctx in
            let pose = ticking ? Self.pose(at: ctx.date.timeIntervalSince(idleStart)) : .rest
            cat(pose: pose, visible: visible, flown: flown)
        }
    }

    private func cat(pose: Pose, visible: Bool, flown: Bool) -> some View {
        let s = { (id: String) in FirstRunAppearance.entranceStart(id, reduceMotion: reduceMotion) }
        let pop: Animation = reduceMotion ? .easeOut(duration: 0.2).delay(s("hero")) : .spring(response: 0.50, dampingFraction: 0.72).delay(s("hero"))
        return ZStack {
            Ellipse()
                .fill(CatpawColors.calmGround)
                .frame(width: 90, height: 16)
                .scaleEffect(pose.shadow)
                .scaleEffect(visible || reduceMotion ? 1 : 0.6)
                .offset(y: size / 2 - 8)
            ZStack {
                // Both frames stay mounted (decoded once); the blink only toggles opacity.
                Image("MascotFront").resizable().interpolation(.high).scaledToFit()
                Image("MascotFrontBlink").resizable().interpolation(.high).scaledToFit().opacity(pose.blink ? 1 : 0)
            }
            .frame(width: size, height: size)
            .firstRunAnchor(.hero)   // untransformed layout rect
            .scaleEffect(x: pose.scaleX, y: pose.scaleY * (squash ? 0.94 : 1), anchor: .bottom)
            .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
            .scaleEffect(visible || reduceMotion ? 1 : 0.70, anchor: .bottom)
            .offset(y: visible || reduceMotion ? 0 : 24)
        }
        .opacity(visible && !flown ? 1 : 0)
        .animation(flown ? nil : pop, value: visible)
        .transaction { if flown { $0.animation = nil } }
    }

    struct Pose: Equatable {
        var scaleX = 1.0, scaleY = 1.0, shadow = 1.0, tilt = 0.0, blink = false
        static let rest = Pose()
    }
    /// §2.3 as a pure function of the idle clock.
    static func pose(at t: Double) -> Pose {
        let b = (1 - cos(t / Idle.breathPeriod * 2 * .pi)) / 2
        let u = t.truncatingRemainder(dividingBy: Idle.tiltEvery)
        let tilt = u < Idle.tiltDuration ? Idle.tiltDegrees * sin(u / Idle.tiltDuration * 4 * .pi) * (1 - u / Idle.tiltDuration) : 0
        let blink = t.truncatingRemainder(dividingBy: Idle.blinkEvery) > Idle.blinkEvery - Idle.blinkDuration
        return Pose(scaleX: 1 - (1 - Idle.breathScaleX) * b, scaleY: 1 + (Idle.breathScaleY - 1) * b,
                    shadow: 1 - (1 - Idle.shadowBreathScale) * b, tilt: tilt, blink: blink)
    }

    private func scheduleIdle() {
        guard !reduceMotion else { return }
        let start = FirstRunAppearance.entranceStart("idle", reduceMotion: false)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(start * 1_000_000_000))
            idleStart = Date(); idleReady = true
        }
    }
    /// §2.2 anticipation: scaleY 1 → 0.94 → 1 (anchor bottom), sine, 80 ms starting at +0.06 s.
    private func anticipate() {
        let squashTrack = FirstRunAppearance.handoffTrack("cat.squash")
        let half = (squashTrack.end - squashTrack.start) / 2
        Task {
            try? await Task.sleep(nanoseconds: UInt64(squashTrack.start * 1_000_000_000))
            withAnimation(.easeInOut(duration: half)) { squash = true }
            try? await Task.sleep(nanoseconds: UInt64(half * 1_000_000_000))
            withAnimation(.easeInOut(duration: half)) { squash = false }
        }
    }
}
