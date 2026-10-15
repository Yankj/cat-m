import SwiftUI
import UIKit

/// r10 "Paw Press" (≤900ms, zero white frame). Frame 0 is pixel-identical to the static launch screen
/// (Info.plist UILaunchScreen: LaunchCanvas color + 72pt LaunchPaw image, screen-centred), so there is no flash.
/// Timeline: press 0–220ms (scale 1→0.94→1) · light haptic 120ms · ripple 180–420ms · settle/exit 420–760ms.
/// Only one logo is ever on screen: no wordmark here, and the paw shrinks away before the destination shows its own.
/// If restore isn't done at ~900ms the paw "breathes" (≤2.5s) instead of ever returning to a blank screen.
@MainActor struct LaunchMarkView: View {
    var restoring: Bool
    var onFinished: () -> Void
    @State private var pressed = false
    @State private var ripple = false
    @State private var breathing = false
    @State private var exiting = false
    @State private var haptic = false
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color("LaunchCanvas").ignoresSafeArea()
            Circle().fill(CatpawBrand.paw.opacity(0.15))
                .frame(width: ripple ? 280 : 72, height: ripple ? 280 : 72)
                .opacity(ripple ? 0 : 0.35)
            Image("LaunchPaw").resizable().frame(width: 72, height: 72)
                .scaleEffect(exiting ? 0.4 : (pressed ? 0.94 : (breathing ? 1.04 : 1)))
                .opacity(exiting ? 0 : 1)
        }
        .ignoresSafeArea()
        .opacity(exiting ? 0 : 1)
        .accessibilityHidden(true)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: haptic)
        .task { await run() }
        .onChange(of: restoring) { _, value in if !value && breathing { Task { await exit() } } }
    }

    private func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private func run() async {
        if reduceMotion { await sleep(100); await exit(); return }
        withAnimation(.easeOut(duration: 0.11)) { pressed = true }
        await sleep(120); haptic.toggle()
        withAnimation(.bouncy(duration: 0.32, extraBounce: 0.15)) { pressed = false }
        await sleep(60)
        withAnimation(.easeOut(duration: 0.24)) { ripple = true }
        await sleep(240)                                                // ≈420ms
        if restoring {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { breathing = true }
            for _ in 0..<21 where restoring { await sleep(100) }        // hold ≤ ~2.5s total
        }
        await exit()
    }

    private func exit() async {
        guard !finished else { return }; finished = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.34)) { exiting = true }
        await sleep(reduceMotion ? 200 : 340)                           // ≈760ms
        onFinished()
    }
}

/// Decide once per process whether to play. Integration in `CatpawApp`/`RootView`:
/// `if LaunchMarkGate.shouldPlay(openedFromURL: …) { overlay LaunchMarkView }`.
@MainActor enum LaunchMarkGate {
    private static var played = false
    static func shouldPlay(openedFromURLOrNotification: Bool) -> Bool {
        defer { played = true }
        return !played && !openedFromURLOrNotification && !UIAccessibility.isVoiceOverRunning
    }
}
