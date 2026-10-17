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
/// The waveform button opens the v1.1 voice conversation (`VoiceChatController` / `VoiceChatOverlay`).
@MainActor struct ComposerDictationControls: View {
    @ObservedObject var model: ConversationFirstModel
    let responding: Bool
    let canSend: Bool
    let size: CGFloat
    let send: () -> Void
    let stop: () -> Void
    @ObservedObject private var dictation = ComposerDictation.shared
    @ObservedObject private var voiceChat = ComposerDictationControls.voiceChatController
    @State private var voiceChatPresented = false
    @State private var voiceChatNotice: String?
    static let voiceChatController = VoiceChatController()
    @State private var comingSoon = false
    @Environment(\.scenePhase) private var scene
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    var body: some View {
        ComposerTrailingControls(responding: responding, draftEmpty: model.draft.isEmpty, canSend: canSend, size: size,
                                 send: { dictation.stopNow(); send() }, stop: stop,
                                 dictate: { dictation.toggle() }, voice: { openVoiceChat() },
                                 dictating: dictation.dictating,
                                 micOverride: AnyView(HoldToTalkMic(dictation: dictation, size: size)))
            .onAppear { dictation.attach(model); dictation.onSend = { send() }; dictation.voice.language = AppLanguage(locale: locale) }
            .onChange(of: locale.identifier) { _, _ in dictation.voice.language = AppLanguage(locale: locale) }
            .onDisappear { dictation.stopNow(); voiceChat.exit(.hostGone); voiceChatPresented = false }
            // P1-3: never carry the conversation across a conversation switch (sign-out / account change: AccountChangeObservers).
            .onChange(of: model.conversationID) { _, _ in voiceChat.exit(.conversationChanged); voiceChatPresented = false }
            // Only a real background stops: the mic/speech permission alerts make the scene .inactive, and stopping there
            // tore the session down mid-start (overlay flashed in and out, voice mode never entered).
            .onChange(of: scene) { _, value in if value == .background { dictation.stopNow(); voiceChat.enteredBackground(); voiceChatPresented = false } }
            // v1.1 voice conversation: full screen while talking; a card / approval collapses it to a small capsule so the
            // card is visible and confirmed on screen (the loop stays paused until 继续).
            .fullScreenCover(isPresented: $voiceChatPresented, onDismiss: {
                if voiceChat.loop.phase != .paused(.needsConfirmation) { voiceChat.exit() }
            }) {
                VoiceChatOverlay(controller: voiceChat, voice: voiceChat.voice, onClose: { voiceChat.exit(); voiceChatPresented = false })
                    .environment(\.locale, locale)
            }
            .onChange(of: voiceChat.loop.phase) { _, phase in
                if phase == .paused(.needsConfirmation) { voiceChatPresented = false }
                if phase == .ended { voiceChatPresented = false }
            }
            .overlay(alignment: .topTrailing) {
                if !voiceChatPresented, voiceChat.loop.phase == .paused(.needsConfirmation) {
                    HStack(spacing: 10) {
                        Text(ui("语音对话已暂停，请先在屏幕上确认")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink).lineLimit(2)
                        Button(ui("继续")) { voiceChatPresented = true; voiceChat.orbTapped() }
                            .font(CatpawTypography.Role.caption.font.weight(.semibold)).accessibilityIdentifier("chat.voiceChat.resume")
                        Button { voiceChat.exit() } label: { Image(systemName: "xmark").font(CatpawTypography.Role.caption.font) }
                            .accessibilityLabel(ui("结束语音对话")).accessibilityIdentifier("chat.voiceChat.capsule.close")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial, in: Capsule())
                    .fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .trailing).offset(y: -56)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("chat.voiceChat.capsule")
                }
            }
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
            .overlay(alignment: .topTrailing) {
                if let voiceChatNotice {
                    Text(voiceChatNotice).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true).frame(width: 280, alignment: .trailing).offset(y: -56)
                        .onTapGesture { self.voiceChatNotice = nil }
                        .task(id: voiceChatNotice) { try? await Task.sleep(nanoseconds: 4_000_000_000); withAnimation { self.voiceChatNotice = nil } }
                        .accessibilityIdentifier("chat.voiceChat.unsupported")
                }
            }
            .animation(.snappy, value: dictation.notice)
    }

    private func openVoiceChat() {
        dictation.stopNow()
        // Known-terminal permission states answer inline (same hint as dictation) instead of opening a dead overlay.
        if AVAudioSession.sharedInstance().recordPermission == .denied || [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus()) {
            dictation.notice = .permissionDenied; return
        }
        guard voiceChat.begin(host: model, language: AppLanguage(locale: locale), send: { _ in send() }) else {
            voiceChatNotice = voiceChat.notice; return   // e.g. 此设备不支持离线语音对话: inline, nothing starts
        }
        voiceChatPresented = true
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

// MARK: - v1.1 voice conversation (waveform button)

#if os(iOS)
/// Spoken replies policy. The document readout gate (`ReadoutPlan.allowsPublicTTS` / `PublicReadoutSample.restriction`)
/// covers file and artifact readout; voice conversation reads only the assistant's reply to what the user just said,
/// reduced by `VoiceSpeechText`. One switch: when it is off the loop is text-only (shows the reply, listens again).
enum VoiceChatSpeechPolicy {
    static let defaultsKey = "catpaw.voiceChat.spokenReplies"
    static var spokenRepliesAllowed: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
}

/// What the voice conversation needs from the conversation screen (seam for controller tests).
@MainActor protocol VoiceChatHost: AnyObject {
    var session: ConversationSession? { get }
    var draft: String { get }
    var conversationID: UUID? { get }
    /// An image / file staged in the composer. A voice turn never carries it.
    var hasStagedAttachments: Bool { get }
    func editDraft(_ text: String)
}
extension ConversationFirstModel: VoiceChatHost {
    var hasStagedAttachments: Bool { imageDraft.phase != .empty }
}

/// Microphone, speech, audio session and haptics (seam for controller tests; `SystemVoiceChatIO` is the device one).
@MainActor protocol VoiceChatIO: AnyObject {
    /// On-device recognition only (P1-4). Callbacks are already on the main actor.
    func startRecognizer(onText: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (NativeVoiceController.DictationEnd) -> Void) -> Bool
    func stopRecognizer()
    func cancelRecognizer()
    func supportsOnDeviceRecognition(_ language: AppLanguage) -> Bool
    /// `onFinish` runs once when the utterance ends by itself (never after `stopSpeaking`).
    func speak(_ text: String, english: Bool, onFinish: @escaping @MainActor () -> Void)
    func stopSpeaking()
    var isSpeaking: Bool { get }
    func activateAudio()
    /// setActive(false, .notifyOthersOnDeactivation).
    func deactivateAudio()
    func haptic(_ haptic: VoiceChatHaptic)
    /// Interruption began / route lost → `onInterruption`; media services reset → `onReset`.
    func observeSession(onInterruption: @escaping @MainActor () -> Void, onReset: @escaping @MainActor () -> Void)
    func stopObserving()
}

@MainActor final class SystemVoiceChatIO: NSObject, VoiceChatIO, AVSpeechSynthesizerDelegate {
    let voice: NativeVoiceController
    private var synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var finish: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()
    init(voice: NativeVoiceController = .shared) { self.voice = voice; super.init(); synthesizer.delegate = self }

    func startRecognizer(onText: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (NativeVoiceController.DictationEnd) -> Void) -> Bool {
        if voice.dictationPhase != .idle { voice.cancelDictation() }
        voice.voiceChatMode = true
        return voice.startDictation(onText: onText, onEnd: { [weak self] end in self?.voice.voiceChatMode = false; onEnd(end) })
    }
    func stopRecognizer() { if voice.dictationPhase != .idle { voice.stopDictation() } }
    func cancelRecognizer() { if voice.dictationPhase != .idle { voice.cancelDictation() }; voice.voiceChatMode = false }
    func supportsOnDeviceRecognition(_ language: AppLanguage) -> Bool { voice.language = language; return voice.voiceChatSupportedOnDevice() }
    func speak(_ text: String, english: Bool, onFinish: @escaping @MainActor () -> Void) {
        activateAudio()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: english ? "en-US" : "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        current = u; finish = onFinish
        synthesizer.speak(u)
    }
    func stopSpeaking() { current = nil; finish = nil; synthesizer.stopSpeaking(at: .immediate) }
    var isSpeaking: Bool { current != nil }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let current = self.current, ObjectIdentifier(current) == token else { return }
            let done = self.finish; self.current = nil; self.finish = nil
            done?()
        }
    }
    func activateAudio() {
        let audio = AVAudioSession.sharedInstance()
        // .voiceChat: echo cancellation, so the reply leaking into the mic is not heard as the user (barge-in).
        try? audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try? audio.setActive(true, options: .notifyOthersOnDeactivation)
    }
    func deactivateAudio() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    func haptic(_ haptic: VoiceChatHaptic) {
        switch haptic {
        case .listen: light.impactOccurred()
        case .turnSent: medium.impactOccurred()
        case .reply: light.impactOccurred(intensity: 0.6)
        case .pause: notify.notificationOccurred(.warning)
        }
    }
    func observeSession(onInterruption: @escaping @MainActor () -> Void, onReset: @escaping @MainActor () -> Void) {
        stopObserving()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in onInterruption() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            // Headphones unplugged / no route: pause (never keep talking out of the speaker unexpectedly). Category changes are ours.
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || reason == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue else { return }
            Task { @MainActor in onInterruption() }
        })
        // Media services reset: every audio object is dead. Rebuild the synthesizer and end the conversation cleanly.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.current = nil; self.finish = nil
                self.synthesizer = AVSpeechSynthesizer(); self.synthesizer.delegate = self
                onReset()
            }
        })
    }
    func stopObserving() { for o in observers { NotificationCenter.default.removeObserver(o) }; observers = [] }
}

/// Drives `VoiceChatLoop` with real audio: on-device recognition through `NativeVoiceController` (voice-chat mode: never
/// the server tier), end of turn after `VoiceChatLoop.silenceInterval` without new text, the turn sent through the normal
/// composer send (so it lands in the current conversation's history), the reply read with AVSpeechSynthesizer.
@MainActor final class VoiceChatController: ObservableObject {
    enum ExitReason { case user, accountChanged, conversationChanged, hostGone, mediaReset }
    @Published private(set) var loop = VoiceChatLoop()
    @Published private(set) var transcript = ""
    /// The assistant's text for the current turn (streaming, then final) — shown under the status.
    @Published private(set) var reply = ""
    @Published private(set) var streaming = false
    @Published private(set) var textOnly = false
    @Published private(set) var notice: String?

    let io: VoiceChatIO
    let voice: NativeVoiceController
    let epoch: AccountEpoch
    var language: AppLanguage = .chinese
    private weak var host: VoiceChatHost?
    private var sendTurn: ((String) -> Void)?
    private var spoken = ""
    private var listening = false
    private var silenceTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var knownTurns: Set<UUID> = []
    private var sentTurnID: UUID?
    private var restoreDraft = ""
    private var owner: (token: AccountToken?, conversation: UUID?) = (nil, nil)
    private var quietRestarts = 0
    /// A pause asked for the audio session back while the confirmation line was still being spoken.
    private var releaseWhenSilent = false
    /// True when the last release really ran (tests).
    private(set) var audioReleased = false
    static let replyTimeout: UInt64 = 120_000_000_000
    var pollInterval: UInt64 = 250_000_000

    init(io: VoiceChatIO? = nil, voice: NativeVoiceController = .shared, epoch: AccountEpoch = .shared, observeAccounts: Bool = true) {
        self.voice = voice; self.io = io ?? SystemVoiceChatIO(voice: voice); self.epoch = epoch
        // Sign-out, account switch and a remote revoke (passive invalidation) all go through AccountChangeObservers.
        if observeAccounts { AccountChangeObservers.register("voiceChat") { [weak self] _, _ in self?.exit(.accountChanged) } }
    }

    var english: Bool { language == .english }

    // MARK: Lifecycle

    /// Returns false (with `notice` set) when voice chat cannot start here.
    @discardableResult
    func begin(host: VoiceChatHost, language: AppLanguage, send: @escaping (String) -> Void) -> Bool {
        guard !loop.isActive else { return true }
        self.language = language
        notice = nil
        // P1-4: voice conversation is on-device only.
        guard io.supportsOnDeviceRecognition(language) else {
            notice = english ? "Offline voice conversation isn't supported on this device." : "此设备不支持离线语音对话"
            return false
        }
        self.host = host; self.sendTurn = send
        loop = VoiceChatLoop(); transcript = ""; reply = ""; quietRestarts = 0; sentTurnID = nil; releaseWhenSilent = false; audioReleased = false
        textOnly = !VoiceChatSpeechPolicy.spokenRepliesAllowed
        owner = (epoch.capture(), host.conversationID)
        restoreDraft = host.draft   // a typed draft is kept aside and put back on exit (same account and conversation only)
        io.observeSession(onInterruption: { [weak self] in self?.run(.interruption) }, onReset: { [weak self] in self?.exit(.mediaReset) })
        run(.start)
        return true
    }
    /// Close button / swipe down (`.user`), sign-out / account change, conversation switch, host disappeared.
    func exit(_ reason: ExitReason = .user) {
        if reason != .user && reason != .hostGone { restoreDraft = "" }   // never carry a draft across accounts / conversations
        if reason == .mediaReset { notice = english ? "Audio was reset. Voice conversation ended." : "音频服务已重置，语音对话已结束。" }
        if !loop.isActive { restoreDraft = ""; return }
        run(.exit)
    }
    /// Real background only (permission alerts make the scene .inactive; that must not end the session).
    func enteredBackground() { run(.background) }
    /// Orb tap: finish the utterance now / interrupt the reply / resume after a pause.
    func orbTapped() {
        switch loop.phase {
        case .listening: if VoiceChatLoop.isMeaningful(transcript) { run(.silenceElapsed) }
        case .speaking: run(.bargeIn(alreadyListening: false))
        case .paused: guard ownerStillValid() else { return exit(.accountChanged) }; releaseWhenSilent = false; run(.resume)
        default: break
        }
    }
    private func ownerStillValid() -> Bool {
        guard epoch.isValid(owner.token) else { return false }
        return host?.conversationID == owner.conversation
    }

    // MARK: Loop plumbing

    func run(_ event: VoiceChatEvent) {
        var next = loop
        let effects = next.handle(event)
        loop = next
        if case .transcript(let t) = event { transcript = t }
        for effect in effects { perform(effect) }
        announcePhase()
    }

    private func perform(_ effect: VoiceChatEffect) {
        switch effect {
        case .startListening: startListening()
        case .stopListening: silenceTask?.cancel(); if listening { io.stopRecognizer() }
        case .send(let text): send(text)
        case .speak(let text): speak(text)
        case .stopSpeaking: io.stopSpeaking()
        case .announceConfirmation:
            let line = VoiceSpeechText.confirmationLine(english: english)
            notice = line
            if !textOnly { io.speak(line, english: english) { [weak self] in self?.confirmationFinished() } }
        case .haptic(let h): io.haptic(h)
        case .releaseAudio: releaseAudio()
        case .deactivateAudio: teardown()
        }
    }

    // MARK: Pausing (P1-2)

    private func releaseAudio() {
        if io.isSpeaking { releaseWhenSilent = true; return }   // the confirmation line finishes first
        silenceTask?.cancel(); generation += 1
        if listening { io.cancelRecognizer(); listening = false }
        io.deactivateAudio(); audioReleased = true; releaseWhenSilent = false
    }
    private func confirmationFinished() {
        guard releaseWhenSilent, case .paused = loop.phase else { return }
        releaseAudio()
    }

    // MARK: Listening

    /// Every recognizer session gets a generation; callbacks of a cancelled / replaced session are ignored, so a
    /// restart can never feed a stale "ended" back into the loop.
    private var generation = 0
    private func startRecognizer() -> Bool {
        guard ownerStillValid() else { exit(.accountChanged); return false }
        generation += 1
        let gen = generation
        audioReleased = false
        let accepted = io.startRecognizer(onText: { [weak self] text in guard let self, self.generation == gen else { return }; self.heard(text) },
                                          onEnd: { [weak self] reason in guard let self, self.generation == gen else { return }; self.listeningEnded(reason) })
        listening = accepted
        return accepted
    }
    private func startListening() {
        transcript = ""
        guard loop.isActive else { return }
        if !startRecognizer(), loop.isActive { notice = english ? "Voice input isn't available right now." : "暂时无法使用语音输入。"; run(.failed) }
    }
    private func heard(_ text: String) {
        guard epoch.isValid(owner.token) else { return exit(.accountChanged) }   // a revoked session never keeps the mic
        if loop.phase == .speaking {
            // Barge-in: only the user's own words count, not the reply leaking from the speaker into the mic. The next
            // utterance starts on a fresh recognizer so no echoed words end up in what is sent.
            guard !VoiceBargeIn.isLikelyEcho(heard: text, speaking: spoken), VoiceChatLoop.isMeaningful(text) else { return }
            run(.bargeIn(alreadyListening: false)); return
        }
        guard loop.phase == .listening || loop.phase == .sending else { return }
        run(.transcript(text))
        armSilence()
    }
    private func armSilence() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VoiceChatLoop.silenceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.run(.silenceElapsed)
        }
    }
    func listeningEnded(_ reason: NativeVoiceController.DictationEnd) {
        listening = false; silenceTask?.cancel()
        switch reason {
        case .interrupted: run(.interruption)
        case .denied:
            notice = english ? "Allow microphone and speech recognition in Settings." : "请在“设置”中允许麦克风和语音识别。"; run(.failed)
        case .unsupported:
            notice = english ? "Offline voice conversation isn't supported on this device." : "此设备不支持离线语音对话"; run(.failed)
        case .finished, .cancelled, .timedOut, .failed:
            guard loop.phase == .listening || loop.phase == .sending else { return }   // e.g. a barge-in monitor that heard nothing
            let hadText = VoiceChatLoop.isMeaningful(transcript)
            if !hadText { quietRestarts += 1 } else { quietRestarts = 0 }
            if quietRestarts > 3 {   // a recognizer that keeps failing must not spin: pause, the user taps to resume
                quietRestarts = 0; notice = english ? "I didn't catch that. Tap to try again." : "没有听清，轻点继续。"; run(.failed); return
            }
            run(.listeningEnded(transcript))
        }
    }

    // MARK: Sending and waiting for the reply

    private func send(_ text: String) {
        guard let host, let sendTurn, ownerStillValid() else { run(.failed); return }
        // P2: a voice turn never carries a staged image / file (the composer send would attach it).
        guard !host.hasStagedAttachments else {
            notice = english ? "Remove the attachment to talk, or send it from the keyboard." : "请先移除附件，或用键盘发送附件。"
            run(.failed); return
        }
        knownTurns = Set(host.session?.turns.map(\.id) ?? []); sentTurnID = nil
        reply = ""; streaming = false; notice = nil
        host.editDraft(text)
        sendTurn(text)   // the normal composer send: same conversation, same history, same queue / consent rules
        watchReply()
    }
    private func watchReply() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var started = DispatchTime.now().uptimeNanoseconds
            var lastSequence = -1
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(nanoseconds: interval)
                guard let self, self.loop.phase == .waiting else { return }
                guard self.ownerStillValid() else { self.exit(.accountChanged); return }
                // A read-only device call keeps the turn moving: the timeout counts from the last change, not the send.
                if let seq = self.sentTurnID.flatMap({ id in self.host?.session?.turns.first(where: { $0.id == id }) })?.lastSequence, seq != lastSequence { lastSequence = seq; started = DispatchTime.now().uptimeNanoseconds }
                if DispatchTime.now().uptimeNanoseconds - started > Self.replyTimeout {
                    self.notice = self.english ? "No reply yet. Check the conversation on screen." : "还没有回复，请在屏幕上查看对话。"
                    self.run(.failed); return
                }
                if self.pollReply() { return }
            }
        }
    }
    /// One look at the conversation. Returns true when the turn reached a terminal state for the loop.
    @discardableResult
    func pollReply() -> Bool {
        guard let session = host?.session else { return false }
        // The first turn created after this send is ours; after that only that exact id is ever read (no fallback to
        // another turn's message).
        if sentTurnID == nil { sentTurnID = session.turns.first(where: { !knownTurns.contains($0.id) })?.id }
        guard let id = sentTurnID, let turn = session.turns.first(where: { $0.id == id }) else { return false }   // queued / not journaled yet
        let message = turn.assistantMessageID.flatMap { mid in session.messages.first(where: { $0.id == mid }) }
        if let message { reply = message.content; streaming = !message.complete }
        // P1-1: only a decision the user must make pauses. Read-only device calls run by themselves.
        if turn.needsUserDecision { run(.approvalRequired); return true }
        switch turn.state {
        case .completed:
            let speech = VoiceSpeechText.make(message?.content ?? "", english: english)
            // P2: phone numbers and e-mail addresses are never read aloud (same masker as the Live Activity title).
            run(.replyFinished(.init(speech: CatpawTaskTitle.redact(speech.text), speakable: !textOnly, needsConfirmation: speech.hadCard)))
            return true
        case .failed, .cancelledBeforeSend, .notSent:
            notice = english ? "That didn't go through. Check the conversation on screen." : "这一轮没有完成，请在屏幕上查看。"
            run(.failed); return true
        case .dispatched, .running, .unknown:
            return false
        }
    }

    // MARK: Speaking

    private func speak(_ text: String) {
        spoken = text
        io.speak(text, english: english) { [weak self] in
            guard let self, self.loop.phase == .speaking else { return }
            self.run(.speechFinished)   // → .startListening: a fresh recognizer replaces the barge-in monitor (no echo carried over)
        }
        // Barge-in: listen while speaking (the recognizer's text is filtered against `spoken`, see VoiceBargeIn).
        if !listening { _ = startRecognizer() }
    }

    // MARK: Teardown

    private func teardown() {
        silenceTask?.cancel(); watchTask?.cancel()
        io.stopSpeaking()
        generation += 1
        io.cancelRecognizer()
        listening = false; releaseWhenSilent = false
        io.stopObserving()
        io.deactivateAudio(); audioReleased = true
        if let host, ownerStillValid(), host.draft.isEmpty, !restoreDraft.isEmpty { host.editDraft(restoreDraft) }
        restoreDraft = ""; sentTurnID = nil; knownTurns = []
    }

    // MARK: Accessibility

    private var lastAnnounced: VoiceChatPhase?
    var statusText: String {
        switch loop.phase {
        case .idle, .listening: return english ? "Listening" : "正在聆听"
        case .sending: return english ? "Got it" : "收到"
        case .waiting: return streaming ? (english ? "Replying" : "正在回复") : (english ? "Thinking" : "正在思考")
        case .speaking: return english ? "Speaking · tap to interrupt" : "正在说 · 轻点打断"
        case .paused(.needsConfirmation): return english ? "Needs your confirmation on screen" : "需要你在屏幕上确认"
        case .paused: return english ? "Paused · tap to continue" : "已暂停 · 轻点继续"
        case .ended: return english ? "Ended" : "已结束"
        }
    }
    private func announcePhase() {
        guard UIAccessibility.isVoiceOverRunning, loop.phase != lastAnnounced else { return }
        lastAnnounced = loop.phase
        if case .paused = loop.phase { UIAccessibility.post(notification: .announcement, argument: statusText) }
    }
}

/// Full-screen calm voice conversation (same canvas, orb and waveform as `VoiceModeOverlay`).
@MainActor struct VoiceChatOverlay: View {
    @ObservedObject var controller: VoiceChatController
    @ObservedObject var voice: NativeVoiceController
    let onClose: () -> Void
    @State private var levels: [Float] = Array(repeating: 0, count: 64)
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }

    private var orbGlyph: String {
        switch controller.loop.phase {
        case .speaking: return "speaker.wave.2.fill"
        case .waiting, .sending: return "ellipsis"
        case .paused: return "play.fill"
        default: return "mic.fill"
        }
    }
    private var orbLabel: String {
        switch controller.loop.phase {
        case .speaking: return ui("打断并开始说话")
        case .paused: return ui("继续语音对话")
        case .listening: return ui("说完了")
        default: return controller.statusText
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            CalmGlowBackground(intensity: reduceMotion ? 0 : 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.body).foregroundStyle(CatpawColors.ink.opacity(0.7))
                            .frame(width: 44, height: 44).background(CatpawColors.calmSurface, in: Circle())
                    }
                    .buttonStyle(CatpawPressButtonStyle())
                    .accessibilityLabel(ui("结束语音对话")).accessibilityIdentifier("chat.voiceChat.close")
                }
                .padding(.top, 8)
                Spacer()
                Text(controller.statusText).font(.footnote).foregroundStyle(CatpawColors.secondary).padding(.bottom, 6)
                    .accessibilityIdentifier("chat.voiceChat.status").accessibilityAddTraits(.updatesFrequently)
                Group {
                    if controller.loop.phase == .listening || controller.loop.phase == .sending {
                        Text(controller.transcript.isEmpty ? ui("正在聆听…") : controller.transcript)
                            .foregroundStyle(CatpawColors.ink.opacity(0.55))
                            .accessibilityIdentifier("chat.voiceChat.transcript")
                    } else {
                        Text(VoiceSpeechText.make(controller.reply, english: controller.english).text)
                            .foregroundStyle(CatpawColors.ink.opacity(0.75)).lineLimit(8)
                            .accessibilityIdentifier("chat.voiceChat.reply")
                    }
                }
                .font(.title3).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.transcript)
                if let notice = controller.notice {
                    Text(notice).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).padding(.top, 10)
                        .accessibilityIdentifier("chat.voiceChat.notice")
                }
                if controller.textOnly {
                    Text(ui("当前为文字回复模式，不朗读")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).padding(.top, 6)
                }
                ThinWaveform(levels: reduceMotion ? Array(repeating: 0.08, count: 64) : levels).frame(height: 44).padding(.vertical, 28)
                HStack {
                    Spacer()
                    Button { controller.orbTapped() } label: {
                        CalmOrb(size: 84, glyph: orbGlyph, level: reduceMotion ? 0 : Double(levels.last ?? 0))
                    }
                    .buttonStyle(CatpawPressButtonStyle())
                    .accessibilityLabel(orbLabel).accessibilityValue(controller.statusText)
                    .accessibilityIdentifier("chat.voiceChat.orb")
                    Spacer()
                }
                .frame(height: 150)
            }
            .padding(.horizontal, 28).padding(.bottom, 8)
        }
        .offset(y: max(0, drag))
        .gesture(DragGesture(minimumDistance: 20)
            .onChanged { v in if v.translation.height > 0 { drag = reduceMotion ? 0 : v.translation.height } }
            .onEnded { v in if v.translation.height > 120 { onClose() } else { withAnimation(reduceMotion ? nil : .snappy) { drag = 0 } } })
        .onReceive(voice.$audioLevel) { l in levels.removeFirst(); levels.append(l) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { onClose() }
        .accessibilityIdentifier("chat.voiceChat.mode")
    }
}
#endif
