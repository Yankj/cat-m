import SwiftUI

/// launch-v2: the first SwiftUI frame is a pixel copy of LaunchScreen.storyboard, then hands off to the chat
/// (or onboarding on first run) with one 220 ms fade-and-rise. No loop, no loader, no minimum hold.
///
/// Geometry contract (must equal Base.lproj/LaunchScreen.storyboard):
///   full-screen canvas "LaunchCanvas"; a 100 pt group centred horizontally with its centre at 0.61 × the FULL
///   screen height (storyboard: group.centerY = 1.22 × superview.centerY, superview not safe area);
///   glyph "LaunchGlyph" 70 × 56 pt at the group top; gap 20; slogan line 24 pt tall, system 17 regular,
///   colour "LaunchSlogan", 1 line, 24 pt side insets, no tracking, fixed size (no Dynamic Type).
struct CatpawLaunchStatic: View {
    static let groupHeight: CGFloat = 100
    static let centerFraction: CGFloat = 0.61
    static let glyph = CGSize(width: 70, height: 56)
    static let gap: CGFloat = 20
    static let sloganLine: CGFloat = 24
    static let sloganSize: CGFloat = 17

    /// Same language the storyboard resolved (system preferred localization), NOT the in-app language override,
    /// so the first frame matches the launch snapshot word for word.
    static var launchSlogan: String {
        let lang = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        return lang.hasPrefix("en") ? "A step ahead. Things handled." : "先你一步，把事办妥"
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: Self.gap) {
                Image("LaunchGlyph")                      // asset catalog PDF: decoded synchronously, no async load
                    .resizable()
                    .frame(width: Self.glyph.width, height: Self.glyph.height)
                Text(verbatim: Self.launchSlogan)
                    .font(.system(size: Self.sloganSize, weight: .regular))
                    .foregroundStyle(Color("LaunchSlogan"))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: Self.sloganLine, maxHeight: Self.sloganLine)
                    .padding(.horizontal, 24)
            }
            .frame(width: geo.size.width, height: Self.groupHeight)
            .position(x: geo.size.width / 2, y: geo.size.height * Self.centerFraction)
        }
        .dynamicTypeSize(.large)                          // storyboard label does not scale; match it
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Once per process: scene re-creation and foreground returns never replay the hand-off (generic types can't hold statics).
@MainActor enum LaunchHandoffState { static var played = false }

/// Root wrapper: chat (or onboarding) underneath, the static mark on top for exactly one hand-off.
struct LaunchHandoff<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var handedOff = false

    var body: some View {
        ZStack {
            Color("LaunchCanvas").ignoresSafeArea()       // same colour as the window background: never a white frame
            content()
                .opacity(handedOff || LaunchHandoffState.played ? 1 : 0)
            if !(handedOff || LaunchHandoffState.played) {
                CatpawLaunchStatic()
                    .onAppear { LaunchTrace.mark("launch.logo", "static", once: true) }
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .offset(y: -7)))
            }
        }
        .task {
            guard !LaunchHandoffState.played else { return }
            await Task.yield()                            // let the content's first frame commit underneath
            LaunchTrace.mark("launch.handoff", reduceMotion ? "fade200" : "rise220", once: true)
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.22)) { handedOff = true }
            LaunchHandoffState.played = true
        }
    }
}

#if DEBUG
#Preview("Launch static") { CatpawLaunchStatic().background(Color("LaunchCanvas")) }
#endif
