import SwiftUI

/// The mic slot: tap = tap-to-dictate toggle; press and hold ≥ 0.3 s = hold-to-talk with slide-left cancel / slide-up send.
/// The same view stays mounted while dictating (it turns into the paw waveform), so the hold gesture is not lost.
@MainActor struct HoldToTalkMic: View {
    @ObservedObject var dictation: ComposerDictation
    let size: CGFloat
    @State private var pressStart: Date?
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?
    @State private var moved = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    var body: some View {
        ZStack {
            if dictation.dictating {
                Image(systemName: "waveform").font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.sendIcon)
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    .frame(width: size, height: size).background(CatpawBrand.paw, in: Circle())
            } else {
                Image(systemName: "mic").font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                    .frame(width: size, height: size)
            }
        }
        .scaleEffect(holding ? 1.15 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: holding)
        .contentShape(Circle().inset(by: -6))
        .gesture(press)
        // VoiceOver: a plain toggle plus explicit cancel / send while dictating (no holding required).
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(dictation.dictating ? ui("停止听写") : ui("听写"))
        .accessibilityHint(dictation.dictating ? "" : ui("轻点开始听写；按住说话，向上滑动发送，向左滑动取消"))
        .accessibilityAction { dictation.toggle() }
        .accessibilityActions {
            if dictation.dictating {
                Button(ui("取消听写")) { dictation.cancel() }
                Button(ui("发送")) { dictation.confirmAndSend() }
            }
        }
        .accessibilityIdentifier(dictation.dictating ? "chat.composer.dictating" : "chat.composer.mic")
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = .now; moved = false
                    let alreadyDictating = dictation.dictating
                    holdTask?.cancel()
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: ComposerDictation.holdDelay)
                        guard !Task.isCancelled, pressStart != nil, !alreadyDictating, !moved else { return }
                        holding = true; dictation.beginHold()
                    }
                }
                if holding { dictation.updateHold(value.translation) }
                else if abs(value.translation.width) > 12 || abs(value.translation.height) > 12 { moved = true }
            }
            .onEnded { value in
                holdTask?.cancel(); holdTask = nil
                defer { pressStart = nil; holding = false; moved = false }
                if holding { dictation.updateHold(value.translation); dictation.endHold(); return }
                // Short press without drifting off = tap.
                if !moved { dictation.toggle() }
            }
    }
}

/// Hold-to-talk only (tap mode uses the full-screen VoiceModeOverlay): ✕ · hint · live dotted waveform · ✓ (Grok-style).
@MainActor struct ComposerDictationBarHost: View {
    @ObservedObject private var dictation = ComposerDictation.shared
    var body: some View {
        if dictation.dictating && dictation.mode == .hold {
            ComposerDictationBar(dictation: dictation, voice: dictation.voice)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

@MainActor struct ComposerDictationBar: View {
    @ObservedObject var dictation: ComposerDictation
    @ObservedObject var voice: NativeVoiceController
    @State private var levels: [Float] = Array(repeating: 0, count: 48)
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private var hold: Bool { dictation.mode == .hold }

    var body: some View {
        HStack(spacing: 10) {
            Button { dictation.cancel() } label: {
                Image(systemName: "xmark").font(CatpawTypography.Role.body.font.weight(.semibold))
                    .foregroundStyle(dictation.zone == .cancel ? CatpawColors.sendIcon : CatpawColors.ink)
                    .frame(width: 40, height: 40)
                    .background(dictation.zone == .cancel ? CatpawColors.ink : CatpawColors.ink.opacity(0.10), in: Circle())
            }
            .buttonStyle(CatpawPressButtonStyle()).touchTarget()
            .accessibilityLabel(ui("取消听写")).accessibilityIdentifier("chat.composer.dictation.cancel")

            if hold {
                Label(ui("向左滑动取消"), systemImage: "chevron.left")
                    .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(CatpawColors.ink.opacity(0.06), in: Capsule())
                    .fixedSize().accessibilityIdentifier("chat.composer.dictation.cancelHint")
            }
            DottedWaveform(levels: levels).frame(maxWidth: .infinity, minHeight: 24).accessibilityHidden(true)

            Button { dictation.stop() } label: {
                Image(systemName: "checkmark").font(CatpawTypography.Role.body.font.weight(.semibold))
                    .foregroundStyle(dictation.zone == .send ? CatpawColors.sendIcon : CatpawColors.ink)
                    .frame(width: 40, height: 40)
                    .background(dictation.zone == .send ? CatpawBrand.paw : CatpawColors.panel, in: Circle())
                    .overlay(Circle().strokeBorder(CatpawColors.ink.opacity(0.08), lineWidth: 0.5))
            }
            .buttonStyle(CatpawPressButtonStyle()).touchTarget()
            .accessibilityLabel(ui("完成听写")).accessibilityIdentifier("chat.composer.dictation.confirm")
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hold {
                Label(ui("向上滑动发送"), systemImage: "chevron.up")
                    .font(CatpawTypography.Role.caption.font).foregroundStyle(dictation.zone == .send ? CatpawBrand.paw : CatpawColors.secondary)
                    .fixedSize().offset(x: -8, y: -28).accessibilityIdentifier("chat.composer.dictation.sendHint")
            }
        }
        .onReceive(voice.$audioLevel) { level in levels.removeFirst(); levels.append(level) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer.dictation.bar")
    }
}

/// Row of dots; each dot's height follows one recent level sample (newest on the right).
struct DottedWaveform: View {
    let levels: [Float]
    var body: some View {
        Canvas { context, size in
            let count = levels.count, step = size.width / CGFloat(max(count, 1)), dot: CGFloat = 3
            for (i, level) in levels.enumerated() {
                let h = max(dot, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(i) * step + (step - dot) / 2, y: (size.height - h) / 2, width: dot, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: dot / 2), with: .color(CatpawColors.ink.opacity(0.25 + Double(level) * 0.6)))
            }
        }
    }
}

/// Full-screen calm voice mode while tap-dictating.
@MainActor struct VoiceModeHost: View {
    @ObservedObject private var dictation = ComposerDictation.shared
    var body: some View {
        if dictation.dictating && dictation.mode == .tap {
            VoiceModeOverlay(dictation: dictation, voice: dictation.voice)
                .transition(.opacity)
        }
    }
}
