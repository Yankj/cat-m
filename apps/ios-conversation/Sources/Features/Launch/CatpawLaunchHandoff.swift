import SwiftUI

/// B2 hand-off for the second and later launches: LaunchScreen.storyboard (static logo on LaunchCanvas) → this overlay's
/// first frame (same canvas, same logo, same place) → when `ready` the logo scales down and fades while the chat beneath
/// fades in (one 0.28 s cross-fade; Reduce Motion: fade only). A chat that is ready within the first frames still gets
/// the same cross-fade, so there is never a flash or a half-built frame. The chat underneath is the account chat, or —
/// only if it is not ready within `maxHold` — the storage-free launch shell (real chrome) with its 300 ms status capsule.
@MainActor struct CatpawLaunchHandoff: View {
    var ready: Bool
    var onGone: () -> Void
    static let maxHold: TimeInterval = 1.5
    static let fade: TimeInterval = 0.28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var leaving = false
    var body: some View {
        ZStack {
            Color("LaunchCanvas")
            CatpawLaunchMark().scaleEffect(leaving && !reduceMotion ? 0.86 : 1)
        }
        .ignoresSafeArea()
        .opacity(leaving ? 0 : 1)
        .allowsHitTesting(!leaving)
        .accessibilityHidden(true)
        .onAppear { LaunchTrace.mark("launch.logo", "", once: true) }
        .onChange(of: ready, initial: true) { _, now in if now { leave() } }
    }
    private func leave() {
        guard !leaving else { return }
        LaunchTrace.mark("launch.handoff", "", once: true)
        withAnimation(.easeOut(duration: Self.fade)) { leaving = true } completion: {
            LaunchTrace.mark("launch.loaderGone", "", once: true); onGone()
        }
    }
}
