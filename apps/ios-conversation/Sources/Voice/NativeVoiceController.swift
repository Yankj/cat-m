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
    var onDeviceSupported: Bool { SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition == true }
    var messageText: String? { message.map { language.ui($0) } }
    var stateText: String { language.ui(["idle": "空闲", "recording": "录音中", "transcribing": "转写中", "preview": "检查转写", "sample": "示例转写 · 模拟", "starting": "准备播放", "playing": "正在播放", "paused": "已暂停", "stopped": "已停止", "finished": "已完成", "failed": "播放未完成", "unverified": "未验证 iOS 音频"][state] ?? state) }
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
        guard speech == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { message = "本地识别不可用，未创建网络识别请求。"; return }
        stopPlayback(); abortCapture()
        let epoch = guardState.startCapture(); rawRevision = 0; transcript = ""; capturing = true; message = nil
        do {
            audioNotifications.begin()
            let audio = AVAudioSession.sharedInstance(); try audio.setCategory(.record, mode: .measurement, options: []); try audio.setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest(); req.requiresOnDeviceRecognition = true; req.shouldReportPartialResults = true; request = req
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
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }; tapInstalled = true
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
    private func stopEngine() { engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false } }
    func editTranscript(_ text: String) { guardState.edit(text); transcript = text }
    func useSample() { abortCapture(); _ = guardState.startCapture(); _ = guardState.receive("本周持续跟进 AI 助理的工作机制，先整理一份私有短稿。", epoch: guardState.captureEpoch, revision: 1); guardState.finish(); transcript = guardState.text; state = "sample" }
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
    func interrupt() { audioNotifications.end(); consentEpoch += 1; abortCapture(); stopPlayback() }
    func endForegroundSession() { interrupt(); guardState.endSession() }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { let token = ObjectIdentifier(utterance); Task { @MainActor [weak self] in guard let self, let item = self.tokens[token], item.epoch == self.guardState.playbackEpoch else { return }; self.paragraphIndex = item.paragraph; self.playbackTimeout?.cancel(); self.state = "playing" } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { let token = ObjectIdentifier(utterance); Task { @MainActor [weak self] in guard let self, self.tokens[token]?.epoch == self.guardState.playbackEpoch else { return }; self.tokens.removeValue(forKey: token); if self.tokens.isEmpty { self.audioNotifications.end(); self.state = "finished"; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { let token = ObjectIdentifier(utterance); Task { @MainActor [weak self] in guard let self, self.tokens[token]?.epoch == self.guardState.playbackEpoch else { return }; self.tokens.removeValue(forKey: token); if self.tokens.isEmpty { self.audioNotifications.end() }; self.state = "stopped" } }
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
    var stateText: String { language.ui(["idle": "空闲", "recording": "录音中", "transcribing": "转写中", "preview": "检查转写", "sample": "示例转写 · 模拟", "starting": "准备播放", "playing": "正在播放", "paused": "已暂停", "stopped": "已停止", "finished": "已完成", "failed": "播放未完成", "unverified": "未验证 iOS 音频"][state] ?? state) }
    var permissionDescription: String { permissionDescription(language: language) }
    func permissionDescription(language: AppLanguage) -> String { language.ui("当前 macOS 类型检查环境不提供 iOS 权限结果") }
    func startFromUserAction() async { message = "请在 iOS 设备上验证本地识别与权限。" }
    func finishInput() {}
    func editTranscript(_ text: String) { guardState.edit(text); transcript = text }
    func useSample() { _ = guardState.startCapture(); _ = guardState.receive("本周持续跟进 AI 助理的工作机制。", epoch: guardState.captureEpoch, revision: 1); guardState.finish(); transcript = guardState.text; state = "sample" }
    func freezeSubmission() throws -> FrozenTranscriptSubmission { guardState.edit(transcript); return try guardState.freeze() }
    func freezeTranscript() throws -> String { try freezeSubmission().submittedText }
    func play(text: String, reference: DocumentReference, sourceKind: String) { message = PublicReadoutSample.allows(reference: reference, sourceKind: sourceKind, text: text) ? "iOS 系统朗读尚未运行验证。" : PublicReadoutSample.restriction }
    func play(plan: ReadoutPlan) { message = plan.allowsPublicTTS ? "iOS 系统朗读尚未运行验证。" : PublicReadoutSample.restriction }
    func changeRateMultiplier(_ multiplier: Double) {}
    func pause() {}; func resume() {}; func stopPlayback() { guardState.stopPlayback() }
    func abortCapture() { guardState.abort(); transcript = "" }
    func interrupt() { abortCapture(); stopPlayback() }
    func endForegroundSession() { interrupt(); guardState.endSession() }
}
#endif
