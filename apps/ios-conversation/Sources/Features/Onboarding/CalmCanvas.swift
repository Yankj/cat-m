import SwiftUI

/// Calm, professional visual language shared by launch → onboarding → voice mode.
/// Warm off-white page, slow-drifting peach glow (bottom) + faint lavender (top). No emoji / cartoon.
enum CalmPalette {
    static let page = Color(red: 0xFB/255, green: 0xF7/255, blue: 0xF3/255)
    static let peach = Color(red: 1.0, green: 0.78, blue: 0.62)
    static let lavender = Color(red: 0.84, green: 0.80, blue: 0.98)
    static let orbLight = Color(red: 1.0, green: 0.74, blue: 0.52)
    static let orbDeep = Color(red: 0.96, green: 0.45, blue: 0.20)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            let b = 0.5 - 0.5 * cos(t * 2 * .pi / 3.6) + level
            ZStack {
                Circle().fill(CalmPalette.orbLight.opacity(0.28 + 0.14 * b))
                    .frame(width: size * (1.9 + 0.25 * b)).blur(radius: size * 0.32)
                Circle().fill(RadialGradient(colors: [CalmPalette.orbLight, CalmPalette.orbDeep], center: UnitPoint(x: 0.38, y: 0.32), startRadius: 2, endRadius: size * 0.62))
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)).padding(size * 0.08))
                    .frame(width: size, height: size)
                    .shadow(color: CalmPalette.orbDeep.opacity(0.35), radius: 16, y: 8)
                    .scaleEffect(1 + 0.025 * b)
                Image(systemName: glyph).font(.system(size: size * 0.24, weight: .regular)).foregroundStyle(.white.opacity(0.95))
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
                    Text(String(chars[i])).font(.system(size: fontSize, weight: .medium))
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
                Capsule().fill(.white).shadow(color: .black.opacity(0.06), radius: 14, y: 6)
                HStack(spacing: 10) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(CatpawColors.ink.opacity(0.78))
                    TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 1) {
                            ForEach(0..<3) { i in
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .foregroundStyle(CatpawColors.actionText.opacity(0.25 + 0.6 * max(0, sin(t * 3 - Double(i) * 0.7))))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity).padding(.leading, knob * 0.6)
                .opacity(1 - Double(drag / max(maxX, 1)))
                ZStack {
                    Circle().fill(LinearGradient(colors: [CalmPalette.orbLight, CalmPalette.orbDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if busy { ProgressView().tint(.white) } else { Image(systemName: "pawprint.fill").font(.system(size: 17)).foregroundStyle(.white) }
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
                Text(ui("你")).font(.caption).foregroundStyle(CatpawColors.secondary).padding(.bottom, 6)
                Text(voice.transcript.isEmpty ? (UserDefaults.standard.bool(forKey: "CatpawVoiceModePreview") ? ui("voice.preview.transcript") : ui("正在聆听…")) : voice.transcript)
                    .font(.system(size: 20, weight: .regular)).foregroundStyle(CatpawColors.ink.opacity(0.55))
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
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(CatpawColors.ink.opacity(0.7))
                .frame(width: 48, height: 48).background(.white, in: Circle())
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
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
    @Published private(set) var ready = UIFont(name: EditorialSerif.postScriptName, size: 12) != nil
    private var requested = false
    func font(size: CGFloat) -> Font {
        ready ? .custom(Self.postScriptName, fixedSize: size) : .system(size: size, weight: .semibold, design: .serif)
    }
    func ensure() {
        guard !ready, !requested else { return }
        requested = true
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: Self.postScriptName] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([desc] as CFArray, nil) { state, _ in
            if state == .didFinish {
                Task { @MainActor in
                    let ok = UIFont(name: EditorialSerif.postScriptName, size: 12) != nil
                    withAnimation(.easeOut(duration: 0.3)) { EditorialSerif.shared.ready = ok }
                }
            }
            return true
        }
    }
}
