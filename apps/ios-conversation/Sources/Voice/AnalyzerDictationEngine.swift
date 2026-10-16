#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// Converts tap buffers to the analyzer's format and yields them (render thread). The converter is rebuilt when the
/// input format changes (route change), so the stream survives AirPods in/out.
@available(iOS 26.0, *)
final class AnalyzerFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) { self.format = format; self.continuation = continuation }
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if buffer.format == format { continuation.yield(AnalyzerInput(buffer: buffer)); return }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / max(buffer.format.sampleRate, 1) + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }
}

/// iOS 26 dictation tier: SpeechAnalyzer + SpeechTranscriber, else DictationTranscriber. One continuous analyzer session
/// (no per-request minute cap). Volatile results replace the tail; finalized text accumulates. `start` returns nil when
/// neither module supports the locale on this device (or its asset can't be installed): the caller falls back to
/// SFSpeechRecognizer.
@available(iOS 26.0, *)
@MainActor final class AnalyzerDictationEngine {
    let tier: DictationEngineTier
    let feeder: AnalyzerFeeder
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, Never>?

    private init(tier: DictationEngineTier, analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, feeder: AnalyzerFeeder) {
        self.tier = tier; self.analyzer = analyzer; self.continuation = continuation; self.feeder = feeder
    }

    /// `onText(full text of this session)`; `onEnd(failed)` once when the results stream ends.
    static func start(localeID: String, onText: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (Bool) -> Void) async -> AnalyzerDictationEngine? {
        let wanted = Locale(identifier: localeID)
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            if let engine = await prepare(module: module, tier: .speechTranscriber) {
                engine.results = Task { @MainActor in
                    var done = "", failed = false
                    do { for try await r in module.results { let t = String(r.text.characters); if r.isFinal { done += t; onText(done) } else { onText(done + t) } } }
                    catch { failed = true }
                    onEnd(failed)
                }
                return engine
            }
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            if let engine = await prepare(module: module, tier: .dictationTranscriber) {
                engine.results = Task { @MainActor in
                    var done = "", failed = false
                    do { for try await r in module.results { let t = String(r.text.characters); if r.isFinal { done += t; onText(done) } else { onText(done + t) } } }
                    catch { failed = true }
                    onEnd(failed)
                }
                return engine
            }
        }
        return nil
    }

    private static func prepare(module: any SpeechModule, tier: DictationEngineTier) async -> AnalyzerDictationEngine? {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await request.downloadAndInstall() }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return nil }
            let analyzer = SpeechAnalyzer(modules: [module])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: stream)
            return AnalyzerDictationEngine(tier: tier, analyzer: analyzer, continuation: continuation, feeder: AnalyzerFeeder(format: format, continuation: continuation))
        } catch { return nil }
    }

    /// User stop: no more audio; finalize what was said (results end → onEnd).
    func finish() {
        continuation.finish()
        let analyzer = analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }
    func cancel() {
        continuation.finish(); results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
#endif
