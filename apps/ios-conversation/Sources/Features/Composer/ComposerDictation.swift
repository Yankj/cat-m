import SwiftUI
#if os(iOS)
import AVFoundation
import Speech
import UIKit
#endif

/// Composer dictation on top of `NativeVoiceController` (tiered engine: iOS 26 SpeechAnalyzer → SFSpeechRecognizer on-device → server; locale follows the app language).
/// Partial results stream live into the draft after whatever was already typed; the final text stays editable.
/// Permissions are requested only from an explicit mic gesture (inside `NativeVoiceController.startDictation`).
///
/// Two ways in, one session model (documented in PR):
/// - **Tap** the mic → tap-to-dictate (unchanged): the bar shows; tap the waveform / ✓ to finish into the draft, ✕ to discard.
/// - **Press and hold** (≥ 0.3 s) → hold-to-talk: release = text goes into the draft; slide up past the threshold = send
///   right away; slide left past the threshold = cancel and discard. Haptics fire when a threshold is crossed.
/// VoiceOver: the mic is a plain toggle (tap start/stop) with explicit 取消听写 / 发送 actions; holding is never required.
@MainActor final class ComposerDictation: ObservableObject {
    enum Notice: Equatable { case permissionDenied, unsupported, failed }
    enum Mode: Equatable { case tap, hold }
    enum HoldZone: Equatable { case none, cancel, send }
    static let shared = ComposerDictation()
    static let cancelThreshold: CGFloat = 90, sendThreshold: CGFloat = 70, holdDelay: UInt64 = 300_000_000

    /// True from the gesture until the controller reports the end — including starting/finishing.
    @Published private(set) var dictating = false
    @Published private(set) var mode: Mode = .tap
    @Published private(set) var zone: HoldZone = .none
    @Published var notice: Notice?

    let voice: NativeVoiceController
    private weak var model: ConversationFirstModel?
    var onSend: (() -> Void)?
    private var prefix = ""
    private var lastWritten: String?
    private var sendWhenDone = false
    #if os(iOS)
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let soft = UIImpactFeedbackGenerator(style: .light)
    #endif

    init(voice: NativeVoiceController = .shared) { self.voice = voice }

    func attach(_ model: ConversationFirstModel) { self.model = model }

    func toggle() { dictating ? stop() : start(.tap) }

    // MARK: Hold-to-talk

    func beginHold() {
        guard !dictating else { return }
        zone = .none
        start(.hold)
        #if os(iOS)
        if dictating { soft.impactOccurred() }
        #endif
    }
    /// Finger moved while holding. Left beats up (cancel is the safe interpretation).
    func updateHold(_ translation: CGSize) {
        guard dictating, mode == .hold else { return }
        let next: HoldZone = translation.width < -Self.cancelThreshold ? .cancel : translation.height < -Self.sendThreshold ? .send : .none
        guard next != zone else { return }
        zone = next
        #if os(iOS)
        if next == .none { soft.impactOccurred(intensity: 0.5) } else { impact.impactOccurred() }
        #endif
    }
    func endHold() {
        guard dictating, mode == .hold else { return }
        switch zone {
        case .cancel: cancel()
        case .send: confirmAndSend()
        case .none: stop()
        }
        zone = .none
    }

    // MARK: Session

    private func start(_ mode: Mode) {
        guard let model, !dictating else { return }
        // A stale session (e.g. another screen's capture) must never block the mic: clear it first.
        if voice.dictationPhase != .idle { voice.cancelDictation() }
        // Known-terminal states answer inline without flashing a session in and out.
        if AVAudioSession.sharedInstance().recordPermission == .denied || [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus()) {
            notice = .permissionDenied; ConversationTextView.focusComposer(); return
        }
        prefix = model.draft; lastWritten = model.draft; sendWhenDone = false
        self.mode = mode
        dictating = true; userStopped = false; notice = nil
        let accepted = voice.startDictation(onText: { [weak self] text in self?.apply(text) },
                                            onEnd: { [weak self] reason in self?.ended(reason) })
        if !accepted { dictating = false; lastWritten = nil }
    }

    /// ✓ / waveform tap / hold release: finish into the draft (the controller caps the final-result wait).
    /// Set when the user ends the session (2nd tap / ✓ / release / ✕). Errors the recognizer reports
    /// after a user stop ("no speech", end-of-audio timeout) are not failures and must never alert.
    private var userStopped = false
    func stop() {
        guard dictating else { return }
        userStopped = true
        if voice.dictationPhase == .idle { ended(.cancelled) } else { voice.stopDictation() }
    }
    /// Slide up / VoiceOver 发送: finish, then send once the final text has landed.
    func confirmAndSend() {
        guard dictating else { return }
        sendWhenDone = true
        stop()
    }
    /// ✕ / slide left: discard everything dictated in this session and restore the previous draft.
    func cancel() {
        guard dictating, let model else { return }
        let restore = prefix
        sendWhenDone = false
        stopNow()
        model.editDraft(restore)
    }

    /// Send / background / disappear: stop now and keep exactly what is in the draft.
    func stopNow() {
        guard dictating else { return }
        sendWhenDone = false; userStopped = true
        voice.cancelDictation()
        if dictating { ended(.cancelled) }   // controller was already idle
    }

    private func ended(_ reason: NativeVoiceController.DictationEnd) {
        let hadText = lastWritten != nil && lastWritten != prefix
        let send = sendWhenDone && hadText
        dictating = false; lastWritten = nil; sendWhenDone = false; zone = .none; defer { userStopped = false }
        switch reason {
        case .denied: notice = .permissionDenied; ConversationTextView.focusComposer()
        case .unsupported: notice = .unsupported; ConversationTextView.focusComposer()
        case .failed, .timedOut: if !hadText && !userStopped { notice = .failed; ConversationTextView.focusComposer() }
        case .finished, .cancelled, .interrupted: break
        }
        if send, reason != .interrupted { onSend?() }
    }

    private func apply(_ text: String) {
        guard dictating, let model else { return }
        // The user typed during dictation: hand the composer back to them.
        if let lastWritten, model.draft != lastWritten { stopNow(); return }
        let joined = DictationPolicy.join(prefix, text)   // no extra space before Chinese
        model.editDraft(joined)
        lastWritten = model.draft   // whatever the model actually stored (it may refuse/normalize)
    }

    static func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}

/// Composer trailing controls with live dictation. Owns the dictation lifecycle so the host view only swaps
/// this in for `ComposerTrailingControls`. Stops on send and on leaving the foreground.
/// The voice-conversation button is not wired yet: it shows a short "即将支持" toast.
@MainActor struct ComposerDictationControls: View {
    @ObservedObject var model: ConversationFirstModel
    let responding: Bool
    let canSend: Bool
    let size: CGFloat
    let send: () -> Void
    let stop: () -> Void
    @ObservedObject private var dictation = ComposerDictation.shared
    @State private var comingSoon = false
    @Environment(\.scenePhase) private var scene
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    var body: some View {
        ComposerTrailingControls(responding: responding, draftEmpty: model.draft.isEmpty, canSend: canSend, size: size,
                                 send: { dictation.stopNow(); send() }, stop: stop,
                                 dictate: { dictation.toggle() }, voice: { showComingSoon() },
                                 dictating: dictation.dictating,
                                 micOverride: AnyView(HoldToTalkMic(dictation: dictation, size: size)))
            .onAppear { dictation.attach(model); dictation.onSend = { send() }; dictation.voice.language = AppLanguage(locale: locale) }
            .onChange(of: locale.identifier) { _, _ in dictation.voice.language = AppLanguage(locale: locale) }
            .onDisappear { dictation.stopNow() }
            // Only a real background stops: the mic/speech permission alerts make the scene .inactive, and stopping there
            // tore the session down mid-start (overlay flashed in and out, voice mode never entered).
            .onChange(of: scene) { _, value in if value == .background { dictation.stopNow() } }
            .overlay(alignment: .top) {
                if comingSoon {
                    Text(ui("语音对话即将支持")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
                        .fixedSize().offset(y: -44).transition(.opacity).accessibilityIdentifier("chat.composer.voice.comingSoon")
                }
            }
            .overlay(alignment: .topTrailing) {
                // Real failures only: a small inline hint above the composer, never a modal alert.
                if dictation.notice != nil {
                    HStack(spacing: 8) {
                        Text(noticeMessage).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        if dictation.notice == .permissionDenied { Button(ui("去设置")) { ComposerDictation.openSettings() }.font(CatpawTypography.Role.caption.font.weight(.semibold)) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    // Anchored to the narrow mic button: give the hint its own width so it never truncates.
                    .fixedSize(horizontal: false, vertical: true).frame(width: 280, alignment: .trailing).offset(y: -56)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onTapGesture { dictation.notice = nil }
                    .task(id: dictation.notice) { try? await Task.sleep(nanoseconds: 4_000_000_000); withAnimation { dictation.notice = nil } }
                    .accessibilityIdentifier("chat.composer.dictation.hint")
                }
            }
            .animation(.snappy, value: dictation.notice)
    }

    private func showComingSoon() {
        withAnimation { comingSoon = true }
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); withAnimation { comingSoon = false } }
    }
    private var noticeTitle: String { dictation.notice == .permissionDenied ? ui("需要麦克风和语音识别权限") : ui("暂时无法听写") }
    private var noticeMessage: String {
        switch dictation.notice {
        case .permissionDenied: return ui("请在“设置”中允许 Catpaw 使用麦克风和语音识别，或直接输入文字。")
        case .failed: return ui("听写没有成功，可以直接输入文字。")
        default: return ui("此设备暂不支持本地听写，可以直接输入文字。")
        }
    }
}
