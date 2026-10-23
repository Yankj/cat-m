import SwiftUI

// MARK: - Two-stage launch loader, stage 2 (SwiftUI). Stage 1 = LaunchScreen.storyboard (see STORYBOARD.md).
//
// Geometry contract with the storyboard: a 96x96 pt tile centred in the FULL screen (not the safe area) on
// Color("LaunchBackground"). Shapes come from catLaunchPaths (generated from the same data as LaunchMark.pdf),
// so the first SwiftUI frame is identical to the launch screen.
//
// Timeline:
//   0.00 s  appear, static (identical to stage 1)
//   0.30 s  loop starts unless already ready: breathing 1.00 -> 1.03 -> 1.00 (1.4 s period, ease-in-out)
//           + soft sheen sweep across the tile (1.4 s, linear; visible ~60% of the period)
//   ready   exit: mark scales to 0.86 + fades (0.26 s ease-in); background fades 0.30 s (+0.06 s delay)
//           -> onExitFinished() after 0.36 s. Ready before 0.30 s: the loop never starts; exit at max(ready, 0.25 s).
// Reduce Motion: static mark, exit is opacity only.
// Cost: only scaleEffect / offset / opacity on static vector Shapes (no blur, no TimelineView, no per-frame drawing).

struct catLaunchMark: View {
    /// Flip to true when the conversation page can be shown (auth resolved + first conversation state loaded).
    var isReady: Bool
    /// Called once the exit transition has finished; remove the view then.
    var onExitFinished: () -> Void = {}

    static let side: CGFloat = 96                        // keep in sync with STORYBOARD.md
    static let loopDelay: Double = 0.30
    static let minDisplay: Double = 0.25
    static let breathPeriod: Double = 1.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearedAt: Date?
    @State private var looping = false
    @State private var breathe = false
    @State private var sweep = false
    @State private var markOut = false
    @State private var backgroundOut = false
    @State private var exitScheduled = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .opacity(backgroundOut ? 0 : 1)
            tile
                .frame(width: Self.side, height: Self.side)
                .scaleEffect(breathe ? 1.03 : 1.0)                    // loop
                .scaleEffect(markOut && !reduceMotion ? 0.86 : 1.0)   // exit
                .opacity(markOut ? 0 : 1)
        }
        .ignoresSafeArea()                                            // centre in the full screen, like the storyboard
        .allowsHitTesting(!markOut)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "小咪正在启动"))
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            guard appearedAt == nil else { return }
            appearedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loopDelay) { startLoopIfNeeded() }
            if isReady { scheduleExit() }
        }
        .onChange(of: isReady) { _, ready in if ready { scheduleExit() } }
    }

    /// Square by construction (user report 15:14, "logo STRETCHED"): the sheen band is 2 × side tall, and as a ZStack sibling
    /// it grew the stack to 96 × 192 pt, so the tile and mark shapes were laid out — and drawn — twice as tall as wide. Now
    /// the tile shape is the only thing that sizes the view; the sheen and mark are overlays proposed exactly the tile's
    /// square, the sheen is clipped to the tile, and the whole tile is pinned 1:1 at `side`.
    private var tile: some View {
        LaunchTileShape()
            .fill(LinearGradient(stops: catLaunchColors.orange, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                // Sheen: a soft diagonal band over the orange; only offset is animated. Clipped to the tile.
                LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                       .init(color: .white.opacity(0.22), location: 0.5),
                                       .init(color: .white.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.side * 0.42, height: Self.side * 2)
                    .rotationEffect(.degrees(20))
                    .offset(x: sweep ? Self.side * 1.25 : -Self.side * 1.25)
                    .opacity(looping ? 1 : 0)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(LaunchTileShape())
            }
            .overlay {
                LaunchMarkShape().fill(LinearGradient(stops: catLaunchColors.cream, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(width: Self.side, height: Self.side)
            .compositingGroup()
    }

    private func startLoopIfNeeded() {
        guard !reduceMotion, !exitScheduled, !looping else { return }
        looping = true
        withAnimation(.easeInOut(duration: Self.breathPeriod / 2).repeatForever(autoreverses: true)) { breathe = true }
        withAnimation(.linear(duration: Self.breathPeriod).repeatForever(autoreverses: false)) { sweep = true }
    }

    private func scheduleExit() {
        guard !exitScheduled else { return }
        exitScheduled = true
        let shown = appearedAt.map { Date().timeIntervalSince($0) } ?? 0
        let wait = max(0, Self.minDisplay - shown)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) { markOut = true; backgroundOut = true }
            } else {
                withAnimation(.easeIn(duration: 0.26)) { markOut = true }
                withAnimation(.easeOut(duration: 0.30).delay(0.06)) { backgroundOut = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.27 : 0.38)) { onExitFinished() }
        }
    }
}

enum catLaunchColors {
    static let orange: [Gradient.Stop] = [.init(color: Color(launchHex: 0xFFA647), location: 0), .init(color: Color(launchHex: 0xFD8330), location: 0.5), .init(color: Color(launchHex: 0xFA5E16), location: 1)]
    static let cream: [Gradient.Stop] = [.init(color: Color(launchHex: 0xFFF8EE), location: 0), .init(color: Color(launchHex: 0xF7E2C8), location: 1)]
}

private extension Color {
    init(launchHex hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1) }
}

struct LaunchTileShape: Shape { func path(in rect: CGRect) -> Path { catLaunchPaths.tile(in: rect) } }
/// Whole cream mark (head + tail). For per-layer motion use LaunchHeadShape / LaunchTailShape (they overlap 3 px at the cut).
struct LaunchMarkShape: Shape { func path(in rect: CGRect) -> Path { catLaunchPaths.mark(in: rect) } }
struct LaunchHeadShape: Shape { func path(in rect: CGRect) -> Path { catLaunchPaths.head(in: rect) } }
struct LaunchTailShape: Shape { func path(in rect: CGRect) -> Path { catLaunchPaths.tail(in: rect) } }

#Preview("Launch mark") {
    struct Host: View {
        @State var ready = false; @State var done = false
        var body: some View {
            ZStack {
                Color(.systemBackground).overlay(Text("Conversation").font(.title2))
                if !done { catLaunchMark(isReady: ready) { done = true } }
            }
            .task { try? await Task.sleep(nanoseconds: 3_000_000_000); ready = true }
        }
    }
    return Host()
}
