import Foundation
import SwiftUI
#if os(iOS)
import AVFoundation
import Speech

// The forwarding closure is registered per session; queued delivery retains that registration.
@MainActor private final class SystemAudioNotificationSource: AudioNotificationSource {
    private var tokens: [UUID: [NSObjectProtocol]] = [:]
    func observe(_ receive: @escaping @MainActor (AudioNotificationEvent) -> Void) -> UUID {
        let id = UUID()
        tokens[id] = [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: AVAudioSession.sharedInstance(), queue: .main) { notification in
                let event: AudioNotificationEvent
                if name == AVAudioSession.interruptionNotification {
                    let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                    event = .interruption(began: type == AVAudioSession.InterruptionType.began.rawValue)
                } else {
                    event = .routeChanged(reason: (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0)
                }
                Task { @MainActor in receive(event) }
            }
        }
        return id
    }
    func remove(_ observation: UUID) { for token in tokens.removeValue(forKey: observation) ?? [] { NotificationCenter.default.removeObserver(token) } }
}

/// Runs on the audio render thread: computes RMS of channel 0 and posts at most ~20 Hz to the main actor.
private final class DictationLevelMeter: @unchecked Sendable {
    private let deliver: @MainActor (Float) -> Void
    private var lastPost: UInt64 = 0   // touched only from the single tap thread
    init(deliver: @escaping @MainActor (Float) -> Void) { self.deliver = deliver }
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastPost >= 50_000_000, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lastPost = now
        let n = Int(buffer.frameLength); var sum: Float = 0
        for i in 0..<n { let v = channel[i]; sum += v * v }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        let level = min(1, max(0, (db + 50) / 50))
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(level) } }
    }
}

@MainActor final class NativeVoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = NativeVoiceController()
    @Published var language: AppLanguage = .chinese
    @Published var state = "idle"
    @Published var transcript = ""
    @Published var message: String?
    @Published var capturing = false
    @Published var voiceID = ""
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published var paragraphIndex = 0
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var speechTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var guardState = VoiceGuard()
    private var tokens: [ObjectIdentifier: (epoch: Int, paragraph: Int)] = [:]
    private var activePlan: ReadoutPlan?
    private var playbackTimeout: Task<Void, Never>?
    private var recognitionTimeout: Task<Void, Never>?
    private var captureLimit: Task<Void, Never>?
    private var tapInstalled = false
    private var consentEpoch = 0
    private var rawRevision = 0
    private let notificationSource: any AudioNotificationSource
    private lazy var audioNotifications = AudioSessionNotifications(source: notificationSource) { [weak self] in self?.interrupt() }
    var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") && !$0.voiceTraits.contains(.isPersonalVoice) && $0.identifier.hasPrefix("com.apple.") } }
    var voiceOptions: [(String, String)] { voices.map { ($0.identifier, $0.name + " · " + $0.language) } }
    var onDeviceSupported: Bool { SFSpeechRecognizer(locale: Locale(identifier: DictationPolicy.localeIdentifier(for: language)))?.supportsOnDeviceRecognition == true }
    var messageText: String? { message.map { language.ui($0) } }
    var stateText: String { language.ui(["idle": "空闲", "recording": "录音中", "transcribing": "转写中", "preview": "检查转写", "starting": "准备播放", "playing": "正在播放", "paused": "已暂停", "stopped": "已停止", "finished": "已完成", "failed": "播放未完成", "unverified": "未验证 iOS 音频"][state] ?? state) }
    var permissionDescription: String { permissionDescription(language: language) }
    func permissionDescription(language: AppLanguage) -> String {
        let microphone: String
        switch AVAudioSession.sharedInstance().recordPermission { case .granted: microphone = language.ui("已允许"); case .denied: microphone = language.ui("未允许"); default: microphone = language.ui("未决定") }
        let speech: String
        switch SFSpeechRecognizer.authorizationStatus() { case .authorized: speech = language.ui("已允许"); case .denied: speech = language.ui("未允许"); case .restricted: speech = language.ui("受限"); default: speech = language.ui("未决定") }
        return language.ui("麦克风：{0} · 识别：{1}", arguments: [String(describing: (microphone)), String(describing: (speech))])
    }
    override init() { notificationSource = SystemAudioNotificationSource(); super.init(); synthesizer.delegate = self }
    init(notificationSource: any AudioNotificationSource) { self.notificationSource = notificationSource; super.init(); synthesizer.delegate = self }
    func startFromUserAction() async {
        // Inspect first. Merely opening this object/sheet never requests permissions.
        guard onDeviceSupported else { message = "当前中文 on-device 识别不可用。可使用文字，或明确的示例转写。"; return }
        consentEpoch += 1; let consent = consentEpoch
        let mic = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
        guard consent == consentEpoch else { return }
        guard mic else { message = "麦克风权限未开启，文字输入仍可用。"; return }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard consent == consentEpoch else { return }
        guard speech == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: DictationPolicy.localeIdentifier(for: language))), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { message = "本地识别不可用，未创建网络识别请求。"; return }
        stopPlayback(); abortCapture()
        let epoch = guardState.startCapture(); rawRevision = 0; transcript = ""; capturing = true; message = nil
        do {
            audioNotifications.begin()
            let audio = AVAudioSession.sharedInstance(); try audio.setCategory(.record, mode: .measurement, options: []); try audio.setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest(); req.requiresOnDeviceRecognition = true; req.shouldReportPartialResults = true; req.addsPunctuation = true; request = req
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CatpawError.unavailable("麦克风音频格式不可用。") }
            speechTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString; let final = result?.isFinal ?? false; let failure = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.guardState.captureEpoch == epoch, self.guardState.capturing else { return }
                    self.rawRevision += 1
                    if let text, self.guardState.receive(text, epoch: epoch, revision: self.rawRevision) { self.transcript = self.guardState.text }
                    if final { self.finishRecognition() }
                    if let failure { self.message = failure; self.finishRecognition() }
                }
            }
            input.removeTap(onBus: 0); input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }; tapInstalled = true
            engine.prepare(); try engine.start(); state = "recording"
            captureLimit = Task { try? await Task.sleep(nanoseconds: 45_000_000_000); if !Task.isCancelled, guardState.captureEpoch == epoch { finishInput() } }
        } catch { message = error.localizedDescription; abortCapture() }
    }
    func finishInput() {
        guard capturing else { return }
        stopEngine(); request?.endAudio(); capturing = false; state = "transcribing"
        captureLimit?.cancel()
        let epoch = guardState.captureEpoch
        recognitionTimeout?.cancel(); recognitionTimeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled, guardState.captureEpoch == epoch, guardState.capturing { message = "识别超时，保留已转写文字供检查。"; finishRecognition() } }
    }
    private func finishRecognition() {
        stopEngine(); speechTask?.cancel(); speechTask = nil; request = nil; captureLimit?.cancel(); recognitionTimeout?.cancel()
        audioNotifications.end(); capturing = false; guardState.finish(); state = "preview"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    /// Stop first, then remove the bus-0 tap unconditionally: removeTap is a no-op without a tap, and a tap left
    /// behind by any path (config change, early throw) would make the next installTap assert `nullptr == Tap()`.
    private func stopEngine() { if engine.isRunning { engine.stop() }; engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    func editTranscript(_ text: String) { guardState.edit(text); transcript = text }
    func freezeSubmission() throws -> FrozenTranscriptSubmission { guardState.edit(transcript); return try guardState.freeze() }
    func freezeTranscript() throws -> String { try freezeSubmission().submittedText }
    func abortCapture() {
        let wasCapturing = guardState.capturing || engine.isRunning
        consentEpoch += 1; guardState.abort(); speechTask?.cancel(); speechTask = nil; request = nil; stopEngine(); captureLimit?.cancel(); recognitionTimeout?.cancel(); capturing = false; transcript = ""
        if wasCapturing { audioNotifications.end(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func play(text: String, reference: DocumentReference, sourceKind: String) {
        do { play(plan: try ReadoutRouter.make(reference: reference, text: text, sourceKind: sourceKind, mode: .full)) }
        catch { message = error.localizedDescription }
    }
    func play(plan: ReadoutPlan) {
        guard plan.allowsPublicTTS else { message = PublicReadoutSample.restriction; return }
        guard let voice = voices.first(where: { $0.identifier == voiceID }) else { message = "请主动选择可用的系统中文音色。"; return }
        abortCapture(); stopPlayback(); message = nil
        do { audioNotifications.begin(); try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers]); try AVAudioSession.sharedInstance().setActive(true) }
        catch { audioNotifications.end(); state = "failed"; message = error.localizedDescription; return }
        activePlan = plan; paragraphIndex = plan.startParagraph
        rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(plan.rateMultiplier)))
        let epoch = guardState.playbackEpoch; state = "starting"
        for index in plan.segments.indices where index >= plan.startParagraph && !plan.segments[index].isEmpty {
            let utterance = AVSpeechUtterance(string: plan.segments[index]); utterance.voice = voice; utterance.rate = rate
            tokens[ObjectIdentifier(utterance)] = (epoch, index); synthesizer.speak(utterance)
        }
        playbackTimeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled, guardState.playbackEpoch == epoch, state == "starting" { stopPlayback(); state = "failed"; message = "系统朗读未在时限内开始。" } }
    }
    func pause() { if state == "playing", synthesizer.pauseSpeaking(at: .word) { state = "paused" } }
    func resume() { if state == "paused", synthesizer.continueSpeaking() { state = "playing" }; if state == "stopped", let activePlan { play(plan: activePlan) } }
    func changeRateMultiplier(_ multiplier: Double) {
        guard let plan = activePlan else { return }
        do { let pending = try ReadoutRouter.retime(plan, rateMultiplier: multiplier, paragraph: paragraphIndex); stopPlayback(); activePlan = pending; state = "stopped" }
        catch { message = error.localizedDescription }
    }
    func stopPlayback() {
        let wasPlayback = ["starting", "playing", "paused"].contains(state)
        activePlan = nil
        guardState.stopPlayback(); playbackTimeout?.cancel(); playbackTimeout = nil; tokens.removeAll(); synthesizer.stopSpeaking(at: .immediate)
        if wasPlayback { audioNotifications.end(); state = "stopped"; if !guardState.capturing { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } }
    }
    func interrupt() { cancelDictation(.interrupted); audioNotifications.end(); consentEpoch += 1; abortCapture(); stopPlayback() }
    func endForegroundSession() { interrupt(); guardState.endSession() }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { let token = ObjectIdentifier(utterance); Task { @MainActor [weak self] in guard let self, let item = self.tokens[token], item.epoch == self.guardState.playbackEpoch else { return }; self.paragraphIndex = item.paragraph; self.playbackTimeout?.cancel(); self.state = "playing" } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { let token = ObjectIdentifier(utterance); Task { @MainActor [weak self] in guard let self, self.tokens[token]?.epoch == self.guardState.playbackEpoch else { return }; self.tokens.removeValue(forKey: token); if self.tokens.isEmpty { self.audioNotifications.end(); self.state = "finished"; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { let token = ObjectIdentifier(utterance); Task { @MainActor [weak self] in guard let self, self.tokens[token]?.epoch == self.guardState.playbackEpoch else { return }; self.tokens.removeValue(forKey: token); if self.tokens.isEmpty { self.audioNotifications.end() }; self.state = "stopped" } }

    // MARK: Composer dictation — explicit state machine (idle → starting → recording → finishing → idle).
    // Every exit funnels through endDictation(), which is idempotent and always tears audio down.
    // One owner at a time; a second start while not idle is rejected (.busy).
    enum DictationPhase: Equatable { case idle, starting, recording, finishing }
    enum DictationEnd: Equatable { case finished, cancelled, interrupted, denied, unsupported, failed(String), timedOut }
    @Published private(set) var dictationPhase: DictationPhase = .idle
    /// Live input level 0…1 (RMS of the tap buffer → dBFS, −50…0 dB mapped linearly, lightly smoothed). 0 when idle.
    @Published private(set) var audioLevel: Float = 0
    private var dictationEpoch = 0
    private var dictationTask: SFSpeechRecognitionTask?
    private var dictationRequest: SFSpeechAudioBufferRecognitionRequest?
    private var dictationWatchdog: Task<Void, Never>?
    private var dictationText = ""
    private var dictationOnText: (@MainActor (String) -> Void)?
    private var dictationOnEnd: (@MainActor (DictationEnd) -> Void)?
    private var dictationObservers: [NSObjectProtocol] = []
    /// Hard caps so no failure can leave the mic stuck: start (after permissions), capture length, final-result wait.
    static let dictationStartTimeout: UInt64 = 6_000_000_000, dictationMaxCapture: UInt64 = 60_000_000_000, dictationFinishTimeout: UInt64 = 2_500_000_000

    /// Returns immediately; results arrive through the callbacks on the main actor. `onEnd` fires exactly once per accepted start.
    @discardableResult
    func startDictation(onText: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (DictationEnd) -> Void) -> Bool {
        guard dictationPhase == .idle else { return false }
        dictationEpoch += 1; let epoch = dictationEpoch
        dictationPhase = .starting; dictationText = ""; dictationOnText = onText; dictationOnEnd = onEnd
        Task { @MainActor [weak self] in await self?.runDictationStart(epoch) }
        return true
    }

    private func runDictationStart(_ epoch: Int) async {
        guard SFSpeechRecognizer(locale: Locale(identifier: DictationPolicy.localeIdentifier(for: language)))?.supportsOnDeviceRecognition == true else { return endDictation(epoch, .unsupported) }
        // Permission callbacks arrive on arbitrary queues; the continuation hops back to this actor.
        let mic: Bool
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: mic = true
        case .denied: mic = false
        default: mic = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
        }
        guard epoch == dictationEpoch, dictationPhase == .starting else { return }
        guard mic else { return endDictation(epoch, .denied) }
        let auth: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus() == .notDetermined
            ? await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } } : SFSpeechRecognizer.authorizationStatus()
        guard epoch == dictationEpoch, dictationPhase == .starting else { return }
        guard auth == .authorized else { return endDictation(epoch, .denied) }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: DictationPolicy.localeIdentifier(for: language))), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return endDictation(epoch, .unsupported) }
        armWatchdog(epoch, after: Self.dictationStartTimeout, phase: .starting)
        // Never share the engine with the sheet capture or playback.
        stopPlayback(); abortCapture(); teardownDictationAudio(deactivate: false)
        do {
            audioNotifications.begin()
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest(); req.requiresOnDeviceRecognition = true; req.shouldReportPartialResults = true
            req.addsPunctuation = true   // iOS 16+: 。，？ instead of one unpunctuated run
            dictationRequest = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)   // read after activation so it matches the live hardware route
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CatpawError.unavailable("麦克风音频格式不可用。") }
            input.removeTap(onBus: 0)
            // The tap only appends and measures; it never touches engine state, so the remove-before-install rule stands.
            let meter = DictationLevelMeter { [weak self] level in self?.receiveLevel(level, epoch: epoch) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in req?.append(buffer); meter.ingest(buffer) }
            tapInstalled = true
            dictationTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false, failed = error != nil
                Task { @MainActor [weak self] in self?.dictationResult(epoch, text: text, final: final, failed: failed) }
            }
            observeEngineChanges(epoch)
            engine.prepare(); try engine.start()
            guard epoch == dictationEpoch else { return }
            dictationPhase = .recording
            armWatchdog(epoch, after: Self.dictationMaxCapture, phase: .recording)
        } catch {
            endDictation(epoch, .failed(error.localizedDescription))
        }
    }

    /// One tap stops. While starting it cancels; while recording it ends audio and waits briefly for the final result.
    func stopDictation() {
        let epoch = dictationEpoch
        switch dictationPhase {
        case .idle: return
        case .starting: endDictation(epoch, .cancelled)
        case .recording:
            dictationPhase = .finishing
            stopEngine(); dictationRequest?.endAudio()
            armWatchdog(epoch, after: Self.dictationFinishTimeout, phase: .finishing)
        case .finishing: endDictation(epoch, .finished)   // second tap: don't wait
        }
    }
    /// Immediate stop (send / background / owner gone): keeps text already delivered.
    func cancelDictation(_ reason: DictationEnd = .cancelled) { if dictationPhase != .idle { endDictation(dictationEpoch, reason) } }

    private func dictationResult(_ epoch: Int, text: String?, final: Bool, failed: Bool) {
        guard epoch == dictationEpoch, dictationPhase == .recording || dictationPhase == .finishing else { return }
        if let text, !text.isEmpty, text != dictationText { dictationText = text; dictationOnText?(text) }
        if final { endDictation(epoch, .finished) }
        else if failed { endDictation(epoch, dictationText.isEmpty ? .failed("") : .finished) }
    }

    private func armWatchdog(_ epoch: Int, after nanoseconds: UInt64, phase: DictationPhase) {
        dictationWatchdog?.cancel()
        dictationWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, epoch == self.dictationEpoch, self.dictationPhase == phase else { return }
            if phase == .recording { self.stopDictation() } else { self.endDictation(epoch, phase == .finishing ? .finished : .timedOut) }
        }
    }

    private func observeEngineChanges(_ epoch: Int) {
        removeDictationObservers()
        let center = NotificationCenter.default
        // Route/format change stops the engine behind our back; a later installTap on the stale node would crash.
        dictationObservers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, epoch == self.dictationEpoch else { return }; self.endDictation(epoch, .interrupted) }
        })
        dictationObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, epoch == self.dictationEpoch else { return }; self.endDictation(epoch, .interrupted) }
        })
    }
    private func removeDictationObservers() { for o in dictationObservers { NotificationCenter.default.removeObserver(o) }; dictationObservers = [] }

    private func receiveLevel(_ level: Float, epoch: Int) {
        guard epoch == dictationEpoch, dictationPhase == .recording || dictationPhase == .starting else { return }
        audioLevel = audioLevel * 0.4 + level * 0.6
    }

    private func teardownDictationAudio(deactivate: Bool) {
        audioLevel = 0
        dictationWatchdog?.cancel(); dictationWatchdog = nil
        removeDictationObservers()
        stopEngine()
        dictationRequest?.endAudio(); dictationRequest = nil
        dictationTask?.cancel(); dictationTask = nil
        if deactivate { audioNotifications.end(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// Single exit. Idempotent per epoch; always returns the controller to `.idle` and frees the mic.
    private func endDictation(_ epoch: Int, _ reason: DictationEnd) {
        guard epoch == dictationEpoch, dictationPhase != .idle else { return }
        dictationEpoch += 1   // late callbacks from this session are ignored from here on
        teardownDictationAudio(deactivate: true)
        dictationPhase = .idle
        let onEnd = dictationOnEnd; dictationOnText = nil; dictationOnEnd = nil
        onEnd?(reason)
    }

}
#else
@MainActor final class NativeVoiceController: ObservableObject {
    static let shared = NativeVoiceController()
    @Published var language: AppLanguage = .chinese
    @Published var state = "unverified"; @Published var transcript = ""; @Published var message: String?
    @Published var capturing = false; @Published var voiceID = ""; @Published var rate: Float = 0.5
    @Published var paragraphIndex = 0
    private var guardState = VoiceGuard()
    var voiceOptions: [(String, String)] { [] }; var onDeviceSupported: Bool { false }
    var messageText: String? { message.map { language.ui($0) } }
    var stateText: String { language.ui(["idle": "空闲", "recording": "录音中", "transcribing": "转写中", "preview": "检查转写", "starting": "准备播放", "playing": "正在播放", "paused": "已暂停", "stopped": "已停止", "finished": "已完成", "failed": "播放未完成", "unverified": "未验证 iOS 音频"][state] ?? state) }
    var permissionDescription: String { permissionDescription(language: language) }
    func permissionDescription(language: AppLanguage) -> String { language.ui("当前 macOS 类型检查环境不提供 iOS 权限结果") }
    func startFromUserAction() async { message = "请在 iOS 设备上验证本地识别与权限。" }
    func finishInput() {}
    func editTranscript(_ text: String) { guardState.edit(text); transcript = text }
    func freezeSubmission() throws -> FrozenTranscriptSubmission { guardState.edit(transcript); return try guardState.freeze() }
    func freezeTranscript() throws -> String { try freezeSubmission().submittedText }
    func play(text: String, reference: DocumentReference, sourceKind: String) { message = PublicReadoutSample.allows(reference: reference, sourceKind: sourceKind, text: text) ? "iOS 系统朗读尚未运行验证。" : PublicReadoutSample.restriction }
    func play(plan: ReadoutPlan) { message = plan.allowsPublicTTS ? "iOS 系统朗读尚未运行验证。" : PublicReadoutSample.restriction }
    func changeRateMultiplier(_ multiplier: Double) {}
    func pause() {}; func resume() {}; func stopPlayback() { guardState.stopPlayback() }
    func abortCapture() { guardState.abort(); transcript = "" }
    func interrupt() { abortCapture(); stopPlayback() }
    func endForegroundSession() { interrupt(); guardState.endSession() }
    enum DictationPhase: Equatable { case idle, starting, recording, finishing }
    enum DictationEnd: Equatable { case finished, cancelled, interrupted, denied, unsupported, failed(String), timedOut }
    @Published private(set) var dictationPhase: DictationPhase = .idle
    @Published private(set) var audioLevel: Float = 0
    @discardableResult func startDictation(onText: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (DictationEnd) -> Void) -> Bool { onEnd(.unsupported); return true }
    func stopDictation() {}
    func cancelDictation(_ reason: DictationEnd = .cancelled) {}
}
#endif
