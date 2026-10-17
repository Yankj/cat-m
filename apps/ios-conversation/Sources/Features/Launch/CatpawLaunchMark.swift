import SwiftUI

/// Second-and-later launch logo (B2, user direction 14:48). SWAPPABLE: 方块's CatpawLaunchMark.swift replaces this file
/// wholesale. Contract the root relies on: `CatpawLaunchMark()` draws the logo at `CatpawLaunchMark.side` points, centred
/// in the FULL screen, and its first frame is pixel-identical to the static LaunchScreen.storyboard image (same asset,
/// same size, scale 1, opacity 1) — so the hand-off from the system launch image is invisible. Temporary logo: the
/// app-icon cat silhouette `BrandMarkFill` (also used by the first-run splash).
@MainActor struct CatpawLaunchMark: View {
    /// = LaunchScreen.storyboard image view (112 × 112 pt, centred on the full view, not the safe area).
    static let side: CGFloat = 112
    static let imageName = "BrandMarkFill"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    var body: some View {
        Image(Self.imageName).resizable().scaledToFit()
            .frame(width: Self.side, height: Self.side)
            // Subtle loop: starts exactly at the storyboard frame (1.0 / 1.0), never below it. Reduce Motion: still.
            .scaleEffect(breathe ? 1.035 : 1).opacity(breathe ? 0.9 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
            }
            .accessibilityHidden(true)
    }
}
