import SwiftUI

/// Calm, professional visual language shared by launch → onboarding → voice mode.
/// Warm off-white page, slow-drifting peach glow (bottom) + faint lavender (top). No emoji / cartoon.
enum CalmPalette {
    static let page = CatpawColors.calmPage
    static let peach = CatpawColors.calmPeach
    static let lavender = CatpawColors.calmLavender
    static let orbLight = CatpawColors.orbLight
    static let orbDeep = CatpawColors.orbDeep
}

struct CalmGlowBackground: View {
    var intensity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    CalmPalette.page
                    Circle().fill(CalmPalette.lavender.opacity(0.55 * intensity))
                        .frame(width: w * 1.1).blur(radius: 90)
                        .position(x: w * (0.30 + 0.06 * sin(t / 7)), y: -h * 0.04 + 14 * cos(t / 9))
                    Circle().fill(CalmPalette.peach.opacity((0.55 + 0.12 * sin(t / 3.2)) * intensity))
                        .frame(width: w * (1.35 + 0.06 * sin(t / 4)))
                        .blur(radius: 110)
                        .position(x: w * (0.62 + 0.08 * sin(t / 8)), y: h * 1.02 + 18 * sin(t / 6))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Glowing orange gradient orb with breathing halo and a tiny white paw glyph.
struct CalmOrb: View {
    var size: CGFloat = 96
    var glyph: String = "pawprint.fill"
    var level: Double = 0
    /// first-run-polish: false → still (the splash pauses it until the launch mark has handed off).
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animated)) { tl in
            let t = reduceMotion || !animated ? 0 : tl.date.timeIntervalSinceReferenceDate
            let b = 0.5 - 0.5 * cos(t * 2 * .pi / 3.6) + level
            ZStack {
                Circle().fill(CalmPalette.orbLight.opacity(0.28 + 0.14 * b))
                    .frame(width: size * (1.9 + 0.25 * b)).blur(radius: size * 0.32)
                Circle().fill(RadialGradient(colors: [CalmPalette.orbLight, CalmPalette.orbDeep], center: UnitPoint(x: 0.38, y: 0.32), startRadius: 2, endRadius: size * 0.62))
                    .overlay(Circle().fill(LinearGradient(colors: [CatpawColors.calmGlyph.opacity(0.35), .clear], startPoint: .top, endPoint: .center)).padding(size * 0.08))
                    .frame(width: size, height: size)
                    .shadow(color: CalmPalette.orbDeep.opacity(0.35), radius: 16, y: 8)
                    .scaleEffect(1 + 0.025 * b)
                if glyph == "pawprint.fill" {
                    BrandMark(size: size * 0.42, style: .onOrange)
                } else {
                    Image(systemName: glyph).resizable().scaledToFit().frame(width: size * 0.26, height: size * 0.26).foregroundStyle(CatpawColors.calmGlyph.opacity(0.95))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Small text set on a circle; rotates slowly (direction via `speed` sign).
struct OrbitText: View {
    let text: String
    let radius: CGFloat
    var speed: Double = 1
    var fontSize: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let chars = Array(text)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let angle = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate * 6 * speed
            ZStack {
                ForEach(chars.indices, id: \.self) { i in
                    Text(String(chars[i])).font(CatpawTypography.Role.caption.font)
                        .foregroundStyle(CatpawColors.actionText.opacity(0.62))
                        .offset(y: -radius)
                        .rotationEffect(.degrees(Double(i) / Double(chars.count) * 360))
                }
            }
            .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: radius * 2 + 24, height: radius * 2 + 24)
        .accessibilityHidden(true)
    }
}

/// White pill: orange knob with paw, drag right to start; chevrons shimmer. VoiceOver/tap also activates.
struct SwipeToStart: View {
    let title: String
    var busy = false
    let action: () -> Void
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            let knob: CGFloat = 52, maxX = g.size.width - knob - 8
            ZStack(alignment: .leading) {
                Capsule().fill(CatpawColors.calmSurface).shadow(color: CatpawColors.calmShadow.opacity(0.06), radius: 14, y: 6)
                HStack(spacing: 10) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(CatpawColors.ink.opacity(0.78))
                    TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 1) {
                            ForEach(0..<3) { i in
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                    .foregroundStyle(CatpawColors.actionText.opacity(0.25 + 0.6 * max(0, sin(t * 3 - Double(i) * 0.7))))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity).padding(.leading, knob * 0.6)
                .opacity(1 - Double(drag / max(maxX, 1)))
                ZStack {
                    Circle().fill(LinearGradient(colors: [CalmPalette.orbLight, CalmPalette.orbDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if busy { ProgressView().tint(CatpawColors.calmGlyph) } else { Image(systemName: "pawprint.fill").font(.body).foregroundStyle(CatpawColors.calmGlyph) }
                }
                .frame(width: knob, height: knob).padding(.leading, 4).offset(x: drag)
                .gesture(DragGesture().onChanged { v in drag = min(max(0, v.translation.width), maxX) }
                    .onEnded { _ in
                        if drag > maxX * 0.75 { withAnimation(.easeOut(duration: 0.15)) { drag = maxX }; action()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { withAnimation(.spring) { drag = 0 } }
                        } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 } }
                    })
            }
        }
        .frame(height: 60)
        .contentShape(Capsule())
        .onTapGesture { if !busy { action() } }
        .disabled(busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}


/// Large gradient CTA matching the landing hub reference: tap only (no swipe).
/// Soft glow + press scale. VoiceOver / Reduce Motion friendly. Action hooks to
/// `NativeLoginView.start` → `auth.completeOnboarding()` / `startExperience()`.
struct StartUsingCTA: View {
    let title: String
    var busy = false
    /// first-run-polish: false → no breath (paused until the launch mark has handed off).
    var animated = true
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Sheen sweeps every `sheenPeriod`s; breathing cycles every `breathPeriod`s.
    private static let sheenPeriod: Double = 3.6
    private static let sheenDuration: Double = 1.1
    private static let breathPeriod: Double = 2.8
    var body: some View {
        Button(action: { if !busy { action() } }) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || busy || !animated)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let animate = !reduceMotion && !busy && animated
                let breath = animate ? (1 - cos(t / Self.breathPeriod * 2 * .pi)) / 2 : 0
                let cycle = t.truncatingRemainder(dividingBy: Self.sheenPeriod)
                let sheen: Double? = animate && FirstRunAppearance.ctaSheenPeak > 0 && cycle < Self.sheenDuration ? cycle / Self.sheenDuration : nil
                content(sheen: sheen)
                    .shadow(color: CatpawColors.orbDeep.opacity(0.30 + 0.12 * breath), radius: 16 + 6 * breath, y: 7 + 2 * breath)
                    .scaleEffect(1 + 0.02 * breath)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(CatpawPressButtonStyle())
        .disabled(busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !busy { action() } }
    }

    private func content(sheen: Double?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return ZStack {
            // first-run-polish: #C9501A → #B8440A (white label 4.5–5.4:1; the old orbLight→Primary gradient gave 2.76:1).
            shape.fill(LinearGradient(colors: [CatpawColors.calmCTATop, CatpawColors.calmCTABottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let sheen {
                GeometryReader { geo in
                    let w = geo.size.width * 0.32
                    LinearGradient(
                        colors: [CatpawColors.calmGlyph.opacity(0), CatpawColors.calmGlyph.opacity(FirstRunAppearance.ctaSheenPeak), CatpawColors.calmGlyph.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w)
                    .rotationEffect(.degrees(18))
                    .offset(x: -w + (geo.size.width + 2 * w) * sheen)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if busy {
                ProgressView().tint(CatpawColors.calmGlyph)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(CatpawTypography.Role.body.font.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(CatpawTypography.Role.heading.font.weight(.semibold))
                }
                .foregroundStyle(CatpawColors.calmGlyph)
            }
        }
    }
}

/// first-run-polish: SwiftUI side of `FirstRunAppearance.transition` for the「开始使用」→ chat handoff.
/// The splash plays its own exit (`NativeLoginView`), so no root change is required. For a fully continuous handoff the
/// root gate (CatpawApp.primaryView) can additionally host it with two modifiers + one animation (see NOTES.md):
///   NativeLoginView(...).firstRunHandoff(.splash)
///   ConversationFirstView(...).firstRunHandoff(.chat)
///   .animation(FirstRunMotion.animation(reduceMotion:), value: auth.needsOnboarding) on the container.
enum FirstRunMotion {
    enum Role { case splash, chat }
    static func animation(reduceMotion: Bool) -> Animation {
        switch FirstRunAppearance.transition(reduceMotion: reduceMotion) {
        case .spring(let response, let damping): .spring(response: response, dampingFraction: damping)
        case .crossfade(let duration): .easeInOut(duration: duration)
        }
    }
    static func transition(_ role: Role, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        switch role {
        case .splash: return .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.98)).combined(with: .offset(y: -10)))
        case .chat: return .asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity)
        }
    }
}
private struct FirstRunHandoff: ViewModifier {
    let role: FirstRunMotion.Role
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.transition(FirstRunMotion.transition(role, reduceMotion: reduceMotion)) }
}
extension View {
    /// Attach on the splash / chat branch of the root gate to get the spring (or Reduce Motion crossfade) handoff.
    func firstRunHandoff(_ role: FirstRunMotion.Role) -> some View { modifier(FirstRunHandoff(role: role)) }
}

/// Live waveform: thin orange vertical bars following recent audio levels.
struct ThinWaveform: View {
    let levels: [Float]
    var body: some View {
        Canvas { ctx, size in
            let n = levels.count, step = size.width / CGFloat(max(n, 1))
            for (i, l) in levels.enumerated() {
                let h = max(3, CGFloat(l) * size.height)
                let edge = min(Double(i), Double(n - 1 - i)) / Double(max(n / 5, 1))
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: 1.6, height: h), cornerRadius: 0.8),
                         with: .color(CalmPalette.orbDeep.opacity(min(1, edge) * (0.35 + Double(l) * 0.6))))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Full-screen voice mode shown while tap-dictating in chat.
@MainActor struct VoiceModeOverlay: View {
    @ObservedObject var dictation: ComposerDictation
    @ObservedObject var voice: NativeVoiceController
    @State private var levels: [Float] = Array(repeating: 0, count: 64)
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        ZStack {
            CalmGlowBackground()
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Text(ui("你")).font(.footnote).foregroundStyle(CatpawColors.secondary).padding(.bottom, 6)
                Text(voice.transcript.isEmpty ? (UserDefaults.standard.bool(forKey: "CatpawVoiceModePreview") ? ui("voice.preview.transcript") : ui("正在聆听…")) : voice.transcript)
                    .font(.title3).foregroundStyle(CatpawColors.ink.opacity(0.55))
                    .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.2), value: voice.transcript)
                    .accessibilityIdentifier("chat.voice.transcript")
                ThinWaveform(levels: levels).frame(height: 44).padding(.vertical, 28)
                HStack {
                    circleButton("keyboard", label: ui("取消听写"), id: "chat.composer.dictation.cancel") { dictation.cancel() }
                    Spacer()
                    Button { dictation.stop() } label: {
                        CalmOrb(size: 84, glyph: "mic.fill", level: Double(levels.last ?? 0))
                    }
                    .buttonStyle(CatpawPressButtonStyle())
                    .accessibilityLabel(ui("完成听写")).accessibilityIdentifier("chat.composer.dictation.confirm")
                    Spacer()
                    circleButton("camera", label: ui("相机"), id: "chat.voice.camera") { dictation.stop(); ComposerAttachPopoverState.shared.isPresented = true }
                }
                .frame(height: 150)
            }
            .padding(.horizontal, 28).padding(.bottom, 8)
        }
        .onReceive(voice.$audioLevel) { l in levels.removeFirst(); levels.append(l) }
        .onAppear { if UserDefaults.standard.bool(forKey: "CatpawVoiceModePreview") { levels = (0..<64).map { i in Float(0.15 + 0.6 * abs(sin(Double(i) * 0.55)) * abs(cos(Double(i) * 0.13))) } } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.voice.mode")
    }
    private func circleButton(_ icon: String, label: String, id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.body).foregroundStyle(CatpawColors.ink.opacity(0.7))
                .frame(width: 48, height: 48).background(CatpawColors.calmSurface, in: Circle())
                .shadow(color: CatpawColors.calmShadow.opacity(0.06), radius: 8, y: 3)
        }
        .buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}

import CoreText

/// Editorial Chinese serif for headlines. Songti SC ships as an on-demand system font on iOS, so we
/// request it once (CoreText downloadable asset) and fall back to New York serif until it is ready.
@MainActor final class EditorialSerif: ObservableObject {
    static let shared = EditorialSerif()
    static let postScriptName = "STSongti-SC-Bold"
    @Published private(set) var ready = EditorialSerif.isInstalled()
    private var requested = false
    nonisolated static func isInstalled() -> Bool { UIFont.fontNames(forFamilyName: "Songti SC").contains(postScriptName) }
    /// Semantic largeTitle in the serif design (scales with Dynamic Type). Per the typography gate,
    /// no named/sized font factory: the system serif cascade renders the CJK headline in its Song face.
    var headline: Font { .system(.largeTitle, design: .serif, weight: .semibold) }
    func ensure() {
        guard !ready, !requested else { return }
        requested = true
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: Self.postScriptName] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([desc] as CFArray, nil) { state, _ in
            if state == .didFinish {
                Task { @MainActor in
                    let ok = EditorialSerif.isInstalled()
                    withAnimation(.easeOut(duration: 0.3)) { EditorialSerif.shared.ready = ok }
                }
            }
            return true
        }
    }
}
