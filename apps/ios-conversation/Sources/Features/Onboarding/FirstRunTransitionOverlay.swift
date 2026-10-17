import SwiftUI

// SPEC-E §2.2 / §5.3: start → chat handoff "E" (D plush leads · B CTA → composer · C chat rises).
// Timings: FirstRunAppearance.handoff(reduceMotion:). Rects are measured globals (`.firstRunAnchor`), never guessed when
// the chat has reported them.
//
// Two hosting modes:
// - Hosted (robust, the spec's form): the gate wraps its landing/chat branch in `FirstRunTransitionHost`. Chat is mounted
//   underneath during the transition, and this overlay flies the cat and morphs the CTA between the real rects.
//   ≤1.15 s after the tap.
// - Unhosted (today's root, which this branch doesn't edit): NativeLoginView draws the overlay itself, plays it to
//   the landed state on chat's chrome geometry, and only then calls completeOnboarding(). The chat-side modifiers
//   pick up from there. See NOTES.md "gate hook".

enum FirstRunAnchorID: Hashable { case hero, cta, headerAvatar, composer }

@MainActor final class FirstRunTransition: ObservableObject {
    static let shared = FirstRunTransition()
    enum Phase: Equatable { case idle, leaving, done }
    @Published private(set) var phase: Phase = .idle
    /// Chat-side pieces the overlay has handed to the real views (header avatar, composer).
    @Published private(set) var handedOff: Set<FirstRunAnchorID> = []
    private(set) var tapAt: Date?
    private(set) var reduceMotion = false
    /// Set by FirstRunTransitionHost on appear.
    var isHosted = false
    /// Global rects. Hero/CTA are frozen once the tap starts; chat rects publish once they first become known mid-transition.
    private(set) var rects: [FirstRunAnchorID: CGRect] = [:]

    func report(_ id: FirstRunAnchorID, _ rect: CGRect) {
        guard rect.width > 0, rects[id] != rect else { return }
        if phase == .leaving, id == .hero || id == .cta { return }
        let wasUnknown = rects[id] == nil
        rects[id] = rect
        if phase == .leaving, wasUnknown, id == .headerAvatar || id == .composer { objectWillChange.send() }
    }
    var elapsed: Double { tapAt.map { Date().timeIntervalSince($0) } ?? .infinity }
    /// The chat entrance applies while a tap is recent (the unhosted path mounts chat after the landing has landed).
    var entranceActive: Bool { tapAt != nil && elapsed < 3 }

    func begin(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        tapAt = Date(); handedOff = []; phase = .leaving
        if reduceMotion { handedOff = [.headerAvatar, .composer] }   // chat fades in on its own 0.25–0.45 s track
    }
    func handOff(_ id: FirstRunAnchorID) { if phase == .leaving { handedOff.insert(id) } }
    func handOffAll() { handedOff.formUnion([.headerAvatar, .composer]) }
    func finish() { phase = .done; handedOff = [.headerAvatar, .composer] }
    /// Sidebar 17:24 (B-a): the flying cat / CTA morph are drawn only during the handoff. The cat's hand-off can fire after
    /// the host's settle has already called finish() (it waits up to 600 ms for the header rect), and its `phase == .leaving`
    /// guard then never removed it: the cat stayed drawn at the root over the header's old rect, outside the sliding chat.
    var drawsFlight: Bool { phase == .leaving }
    /// Entry failed: the landing comes back.
    func cancel() { phase = .idle; tapAt = nil; handedOff = [] }

    // Chat-side geometry fallbacks for the unhosted path, used only while chat hasn't laid out yet.
    // ConversationFirstView.conversationTitleMenu: centred title capsule (≈200 pt), leading 4, 32 pt slot, 28 pt cat. Nav bar 44 pt.
    func headerAvatarTarget(screen: CGRect, safeTop: CGFloat) -> CGRect {
        if let r = rects[.headerAvatar] { return r.insetBy(dx: (r.width - 28) / 2, dy: (r.height - 28) / 2) }
        let c = CGPoint(x: screen.midX - 100 + 4 + 16, y: screen.minY + safeTop + 22)
        return CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)
    }
    /// ComposerChrome pill: outer padding 12, bottom 8, 48 pt single line (6 pt inner padding around 36 pt controls).
    func composerTarget(screen: CGRect, safeBottom: CGFloat) -> CGRect {
        if let r = rects[.composer] { return r }
        return CGRect(x: screen.minX + 12, y: screen.maxY - safeBottom - 8 - 48, width: screen.width - 24, height: 48)
    }
}

// MARK: - Anchors and chat-side modifiers (all no-ops outside a first-run transition)

@MainActor private struct FirstRunAnchorReporter: ViewModifier {
    let id: FirstRunAnchorID
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { FirstRunTransition.shared.report(id, g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global)) { _, f in FirstRunTransition.shared.report(id, f) }
        })
    }
}

/// Header avatar / composer: hidden until the overlay hands the piece over, then a 100 ms fade (Reduce Motion: chat.fade).
@MainActor private struct FirstRunHandedOff: ViewModifier {
    let id: FirstRunAnchorID
    @ObservedObject private var t = FirstRunTransition.shared
    func body(content: Content) -> some View {
        let hidden = t.phase == .leaving && !t.handedOff.contains(id)
        let rm = FirstRunAppearance.handoffTrack("chat.fade", reduceMotion: true)
        content
            .opacity(hidden ? 0 : 1)
            .animation(t.reduceMotion ? .easeOut(duration: rm.end - rm.start).delay(max(0, rm.start - min(t.elapsed, 9))) : .easeOut(duration: 0.1), value: hidden)
    }
}

/// C-style rise for a chat element on the track `id` (chat.buttons −6 pt, chat.row0/row1/backdrop +8 pt).
@MainActor private struct FirstRunChatEntrance: ViewModifier {
    let id: String
    let rise: CGFloat
    var targetOpacity: Double = 1
    @State private var pending = FirstRunTransition.shared.entranceActive
    func body(content: Content) -> some View {
        let t = FirstRunTransition.shared
        content
            .opacity(pending ? 0 : targetOpacity)
            .offset(y: pending && !t.reduceMotion ? rise : 0)
            .onAppear {
                guard pending else { return }
                let track = FirstRunAppearance.handoffTrack(t.reduceMotion ? "chat.fade" : id, reduceMotion: t.reduceMotion)
                let delay = max(0, track.start - t.elapsed)
                withAnimation(t.reduceMotion ? .easeOut(duration: track.end - track.start).delay(delay) : .spring(response: 0.50, dampingFraction: 0.90).delay(delay)) { pending = false }
            }
    }
}

/// Title pill: unfolds from the avatar (≈30 pt → full width) at chat.title, text fading in. Reduce Motion: fade only.
@MainActor private struct FirstRunTitleUnfold: ViewModifier {
    @State private var folded = FirstRunTransition.shared.entranceActive
    func body(content: Content) -> some View {
        let t = FirstRunTransition.shared
        content
            .mask(alignment: .leading) {
                GeometryReader { g in
                    Capsule().frame(width: folded && !t.reduceMotion ? min(30, g.size.width) : g.size.width)
                }
            }
            .opacity(folded && t.reduceMotion ? 0 : 1)
            .onAppear {
                guard folded else { return }
                let track = FirstRunAppearance.handoffTrack(t.reduceMotion ? "chat.fade" : "chat.title", reduceMotion: t.reduceMotion)
                let delay = max(0, track.start - t.elapsed)
                withAnimation(t.reduceMotion ? .easeOut(duration: track.end - track.start).delay(delay) : .spring(response: 0.42, dampingFraction: 0.88).delay(delay)) { folded = false }
            }
    }
}

extension View {
    /// Report this view's global rect to the first-run transition.
    func firstRunAnchor(_ id: FirstRunAnchorID) -> some View { modifier(FirstRunAnchorReporter(id: id)) }
    /// Chat header avatar / composer: stay hidden until the flying cat / morphing CTA hands over.
    func firstRunHandedOff(_ id: FirstRunAnchorID) -> some View { modifier(FirstRunHandedOff(id: id)) }
    /// Chat empty-state rows / top buttons: SPEC-E §2.2 staggered rise.
    func firstRunChatEntrance(_ track: String, rise: CGFloat = 8) -> some View { modifier(FirstRunChatEntrance(id: track, rise: rise)) }
    func firstRunTitleUnfold() -> some View { modifier(FirstRunTitleUnfold()) }
}

// MARK: - Overlay

/// Draws the flying cat and the CTA → composer morph over everything, in screen coordinates.
struct FirstRunTransitionOverlay: View {
    /// Title of the CTA at the tap (「开始使用」/「再试一次」) and the real composer placeholder.
    var ctaTitle: String
    var placeholder: String
    @ObservedObject private var t = FirstRunTransition.shared
    @State private var flight = 0.0
    @State private var morph = 0.0
    @State private var fill = 1.0
    @State private var label = 1.0
    @State private var placeholderOn = false
    @State private var icons = [false, false, false]
    @State private var catGone = false
    @State private var morphGone = false
    @State private var started = false

    var body: some View {
        GeometryReader { g in
            let screen = g.frame(in: .global)
            let from = t.rects[.hero] ?? .zero
            let to = t.headerAvatarTarget(screen: screen, safeTop: g.safeAreaInsets.top)
            let ctaFrom = t.rects[.cta] ?? .zero
            let ctaTo = t.composerTarget(screen: screen, safeBottom: g.safeAreaInsets.bottom)
            let local = { (r: CGRect) in r.offsetBy(dx: -screen.minX, dy: -screen.minY) }
            ZStack {
                if t.drawsFlight, started, !morphGone, ctaFrom != .zero {
                    ComposerMorph(p: morph, from: local(ctaFrom), to: local(ctaTo), fill: fill, label: label, title: ctaTitle,
                                  placeholder: placeholder, placeholderOn: placeholderOn, icons: icons)
                }
                if t.drawsFlight, started, !catGone, from != .zero {
                    CatFlight(p: flight, from: local(from), to: local(to))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: t.phase) { _, p in if p == .leaving { run() } }
        .onAppear { if t.phase == .leaving { run() } }
    }

    private func at(_ s: Double, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)); body() }
    }
    private func run() {
        guard !t.reduceMotion, !started else { return }
        started = true; flight = 0; morph = 0; fill = 1; label = 1; placeholderOn = false; icons = [false, false, false]; catGone = false; morphGone = false
        let tr = { (id: String) in FirstRunAppearance.handoffTrack(id) }
        // B: CTA → composer.
        withAnimation(.spring(response: 0.50, dampingFraction: 0.86).delay(tr("cta.morph").start)) { morph = 1 }
        withAnimation(.linear(duration: tr("cta.fill").end - tr("cta.fill").start).delay(tr("cta.fill").start)) { fill = 0 }
        withAnimation(.easeOut(duration: tr("cta.label").end - tr("cta.label").start).delay(tr("cta.label").start)) { label = 0 }
        withAnimation(.easeOut(duration: 0.2).delay(tr("composer.placeholder").start)) { placeholderOn = true }
        for (i, id) in ["composer.add", "composer.mic", "composer.send"].enumerated() {
            withAnimation(.spring(response: 0.40, dampingFraction: 0.90).delay(tr(id).start)) { icons[i] = true }
        }
        at(tr("composer.handoff").start) {
            guard t.isHosted, t.phase == .leaving else { return }   // unhosted: keep the landed bar until the gate swaps
            t.handOff(.composer); withAnimation(.easeOut(duration: 0.04)) { morphGone = true }
        }
        // D: the cat hops. If chat hasn't reported its header yet (hosted path), hold at the end of the anticipation for up
        // to 600 ms (§5.6), then fly to the measured or estimated slot.
        let flightStart = tr("cat.flight").start
        Task { @MainActor in
            var hold = 0.0
            try? await Task.sleep(nanoseconds: UInt64(flightStart * 1_000_000_000))
            while t.isHosted, t.rects[.headerAvatar] == nil, hold < 0.6 { try? await Task.sleep(nanoseconds: 50_000_000); hold += 0.05 }
            withAnimation(.spring(response: 0.50, dampingFraction: 0.86)) { flight = 1 }
            at(tr("cat.handoff").start - flightStart) {
                guard t.isHosted, t.phase == .leaving else { return }
                t.handOff(.headerAvatar)
                withAnimation(.easeOut(duration: tr("cat.handoff").end - tr("cat.handoff").start)) { catGone = true }
            }
        }
    }
}

/// Animatable on `p` so the arc, size and image cross-fade are evaluated every frame from one spring.
private struct CatFlight: View, Animatable {
    var p: Double
    let from: CGRect
    let to: CGRect
    var animatableData: Double { get { p } set { p = newValue } }
    var body: some View {
        let q = CGFloat(p)
        let w = from.width + (to.width - from.width) * q
        let x = from.midX + (to.midX - from.midX) * q
        let y = from.midY + (to.midY - from.midY) * q - CGFloat(FirstRunAppearance.flightArc * sin(.pi * min(max(p, 0), 1)))
        let cross = min(max((p - 0.55) / 0.35, 0), 1)   // MascotFront → MascotIdle at p 0.55–0.90
        ZStack {
            Image("MascotFront").resizable().interpolation(.high).scaledToFit().opacity(1 - cross)
            Image("MascotIdle").resizable().interpolation(.high).scaledToFit().opacity(cross)
        }
        .frame(width: max(1, w), height: max(1, w))
        .position(x: x, y: y)
    }
}

private struct ComposerMorph: View, Animatable {
    var p: Double
    let from: CGRect
    let to: CGRect
    let fill: Double
    let label: Double
    let title: String
    let placeholder: String
    let placeholderOn: Bool
    let icons: [Bool]
    var animatableData: Double { get { p } set { p = newValue } }
    var body: some View {
        let q = CGFloat(p)
        let r = CGRect(x: from.minX + (to.minX - from.minX) * q, y: from.minY + (to.minY - from.minY) * q,
                       width: from.width + (to.width - from.width) * q, height: from.height + (to.height - from.height) * q)
        let corner = 28 + (26 - 28) * q   // CTA r28 → ComposerChrome pill r26
        let shape = RoundedRectangle(cornerRadius: max(0, corner), style: .continuous)
        ZStack {
            shape.fill(CatpawColors.composerPill).overlay(shape.strokeBorder(CatpawColors.hairline, lineWidth: 0.5))
            shape.fill(LinearGradient(colors: [CatpawColors.calmCTATop, CatpawColors.calmCTABottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(fill)
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill").font(CatpawTypography.Role.body.font.weight(.semibold))
                Text(title).font(CatpawTypography.Role.heading.font.weight(.semibold))
            }
            .foregroundStyle(CatpawColors.calmGlyph)
            .opacity(label)
            HStack(spacing: 2) {
                icon("plus", on: icons[0])
                Text(placeholder).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                    .opacity(placeholderOn ? 1 : 0)
                icon("mic", on: icons[1])
                icon("arrow.up", on: icons[2])
            }
            .padding(6)
        }
        .shadow(color: CatpawColors.orbDeep.opacity(0.32 * fill), radius: 16, y: 7)
        .frame(width: max(1, r.width), height: max(1, r.height))
        .position(x: r.midX, y: r.midY)
    }
    private func icon(_ name: String, on: Bool) -> some View {
        Image(systemName: name).font(CatpawTypography.Role.body.font.weight(.medium)).foregroundStyle(CatpawColors.ink)
            .frame(width: 36, height: 36)
            .scaleEffect(on ? 1 : 0.7).opacity(on ? 1 : 0)
    }
}

// MARK: - Host (for the gate owner; not wired by this branch)

/// The gate's landing/chat branch wrapped so both trees are mounted during the transition (SPEC-E §5.3):
///     FirstRunTransitionHost(onboarding: auth.needsOnboarding, chat: chatViewOrNil,
///                            ctaTitle: ui("开始使用"), placeholder: ui("问问 Catpaw")) { NativeLoginView(auth: auth) }
/// `chat` is nil while the chat shell is still attaching.
struct FirstRunTransitionHost<Landing: View, Chat: View>: View {
    let onboarding: Bool
    let chat: Chat?
    var ctaTitle: String
    var placeholder: String
    @ViewBuilder var landing: () -> Landing
    @ObservedObject private var t = FirstRunTransition.shared
    var body: some View {
        ZStack {
            if !onboarding, let chat { chat }
            if onboarding || t.phase == .leaving {
                landing().allowsHitTesting(onboarding).zIndex(1)
            }
            FirstRunTransitionOverlay(ctaTitle: ctaTitle, placeholder: placeholder).zIndex(2)
        }
        .onAppear { t.isHosted = true }
        .onDisappear { t.isHosted = false }
        .onChange(of: t.phase) { _, p in
            guard p == .leaving else { return }
            let settle = FirstRunAppearance.handoff(reduceMotion: t.reduceMotion).map(\.end).max() ?? 1.15
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                if t.phase == .leaving { t.finish() }   // landing removed (it stays only while the gate still says onboarding)
            }
        }
    }
}
