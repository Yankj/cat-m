import Foundation

public struct VoiceGuard: Sendable {
    public var sessionID = UUID()
    public var captureEpoch = 0
    public var playbackEpoch = 0
    public var transcriptRevision = 0
    public var editRevision = 0
    public var text = ""
    public var capturing = false
    public var submitted = false
    public init() {}
    public mutating func startCapture() -> Int { captureEpoch += 1; transcriptRevision = 0; editRevision = 0; text = ""; capturing = true; submitted = false; return captureEpoch }
    @discardableResult public mutating func receive(_ value: String, epoch: Int, revision: Int) -> Bool {
        guard capturing, epoch == captureEpoch, revision > transcriptRevision, editRevision == 0, !submitted else { return false }
        transcriptRevision = revision; text = value; return true
    }
    public mutating func edit(_ value: String) { editRevision += 1; text = value }
    public mutating func finish() { capturing = false }
    public mutating func abort() { captureEpoch += 1; capturing = false; text = ""; submitted = false }
    public mutating func freeze() throws -> FrozenTranscriptSubmission {
        guard !capturing, !submitted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatpawError.invalid("请结束本句，检查转写后再放入输入。") }
        submitted = true
        return FrozenTranscriptSubmission(sessionID: sessionID, utteranceID: UUID(), clientMessageID: UUID(), captureEpoch: captureEpoch, transcriptRevision: transcriptRevision, editRevision: editRevision, submittedText: text, submittedTextHash: textHash(text))
    }
    public mutating func stopPlayback() { playbackEpoch += 1 }
    public mutating func endSession() { abort(); stopPlayback(); sessionID = UUID() }
}
