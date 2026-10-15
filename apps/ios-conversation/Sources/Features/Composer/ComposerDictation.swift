import SwiftUI
import Combine
#if os(iOS)
import AVFoundation
import Speech
import UIKit
#endif

/// Composer dictation on top of `NativeVoiceController` (on-device `SFSpeechRecognizer`, zh-CN).
/// Partial results stream live into the draft after whatever was already typed; the final text stays editable.
/// Permissions are requested only from the explicit mic tap (inside `startFromUserAction`).
@MainActor final class ComposerDictation: ObservableObject {
    enum Notice: Equatable { case permissionDenied, unsupported, failed }
    @Published private(set) var dictating = false
    @Published var notice: Notice?

    private let voice: NativeVoiceController
    private weak var model: ConversationFirstModel?
    private var prefix = ""
    private var lastWritten: String?
    private var applying = false
    private var observers: Set<AnyCancellable> = []

    init(voice: NativeVoiceController = .shared) { self.voice = voice }

    func attach(_ model: ConversationFirstModel) {
        self.model = model
        guard observers.isEmpty else { return }
        voice.$transcript.sink { [weak self] text in Task { @MainActor in self?.apply(text) } }.store(in: &observers)
        voice.$state.sink { [weak self] state in Task { @MainActor in self?.stateChanged(state) } }.store(in: &observers)
    }

    /// Mic button: start, or stop (keeps text; the controller delivers the final result within ~5 s).
    func toggle() {
        if dictating { stop() } else { Task { await start() } }
    }

    private func start() async {
        guard let model, !dictating else { return }
        voice.language = .chinese; voice.message = nil
        prefix = model.draft; lastWritten = model.draft
        applying = true; dictating = true
        await voice.startFromUserAction()
        guard voice.capturing else {
            applying = false; dictating = false; lastWritten = nil
            notice = classifyFailure()
            ConversationTextView.focusComposer()
            return
        }
    }

    func stop() {
        guard dictating else { return }
        if voice.capturing { voice.finishInput() } else { stopNow() }
    }

    /// Send / background: stop immediately and keep exactly what is already in the draft.
    func stopNow() {
        guard dictating else { return }
        applying = false; dictating = false; lastWritten = nil
        voice.abortCapture()   // releases the audio session; the transcript reset is ignored (applying = false)
    }

    private func stateChanged(_ state: String) {
        guard dictating, !voice.capturing, ["preview", "idle"].contains(state) else { return }
        if let message = voice.message, !message.isEmpty, model?.draft == prefix { notice = .failed }
        stopNow()
    }

    private func apply(_ text: String) {
        guard applying, dictating, let model else { return }
        // The user typed during dictation: hand the composer back to them.
        if let lastWritten, model.draft != lastWritten { stop(); return }
        guard !text.isEmpty else { return }
        let joined = prefix.isEmpty ? text : ((prefix.hasSuffix("\n") || prefix.hasSuffix(" ")) ? prefix + text : prefix + " " + text)
        lastWritten = joined
        model.editDraft(joined)
    }

    private func classifyFailure() -> Notice {
        #if os(iOS)
        if AVAudioSession.sharedInstance().recordPermission == .denied || [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus()) { return .permissionDenied }
        #endif
        return voice.onDeviceSupported ? .failed : .unsupported
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
    @StateObject private var dictation = ComposerDictation()
    @State private var comingSoon = false
    @Environment(\.scenePhase) private var scene
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    var body: some View {
        ComposerTrailingControls(responding: responding, draftEmpty: model.draft.isEmpty, canSend: canSend, size: size,
                                 send: { dictation.stopNow(); send() }, stop: stop,
                                 dictate: { dictation.toggle() }, voice: { showComingSoon() },
                                 dictating: dictation.dictating)
            .onAppear { dictation.attach(model) }
            .onDisappear { dictation.stopNow() }
            .onChange(of: scene) { _, value in if value != .active { dictation.stopNow() } }
            .overlay(alignment: .top) {
                if comingSoon {
                    Text(ui("语音对话即将支持")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
                        .fixedSize().offset(y: -44).transition(.opacity).accessibilityIdentifier("chat.composer.voice.comingSoon")
                }
            }
            .alert(noticeTitle, isPresented: Binding(get: { dictation.notice != nil }, set: { if !$0 { dictation.notice = nil } })) {
                if dictation.notice == .permissionDenied { Button(ui("去设置")) { ComposerDictation.openSettings() } }
                Button(ui("好"), role: .cancel) {}
            } message: { Text(noticeMessage) }
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
