import Foundation

public enum VoiceTarget: Codable, Hashable, Sendable { case conversation(UUID), document(DocumentReference) }
public struct FrozenVoiceTurn: Codable, Sendable {
    public let scope: DataScope
    public let target: VoiceTarget
    public let transcript: FrozenTranscriptSubmission
}
public struct ForegroundVoiceSession: Sendable {
    public private(set) var guardState = VoiceGuard()
    public private(set) var target: VoiceTarget?
    public private(set) var scope: DataScope?
    public private(set) var submittedTurns: [UUID] = []
    public init() {}
    public mutating func begin(scope: DataScope, target: VoiceTarget) -> Int {
        if let previous = self.scope, previous != scope { guardState.endSession() }
        self.scope = scope; self.target = target
        return guardState.startCapture()
    }
    @discardableResult public mutating func receive(_ text: String, epoch: Int, revision: Int) -> Bool { guardState.receive(text, epoch: epoch, revision: revision) }
    public mutating func finish() { guardState.finish() }
    public mutating func edit(_ text: String) { guardState.edit(text) }
    public mutating func submit() throws -> FrozenVoiceTurn {
        guard let scope, let target else { throw CatpawError.invalid("语音话轮尚无目标。") }
        let transcript = try guardState.freeze(); submittedTurns.append(transcript.clientMessageID)
        return FrozenVoiceTurn(scope: scope, target: target, transcript: transcript)
    }
    public mutating func stopPlayback() { guardState.stopPlayback() }
    public mutating func end() { guardState.endSession(); target = nil; scope = nil }
}
public struct VoiceEditReceipt: Codable, Sendable {
    public let turn: FrozenVoiceTurn
    public let result: DocumentReference
    public let draftHash: String
    public let adapterID: String
}
public struct VoiceRevisionDraft: Sendable {
    public let turn: FrozenVoiceTurn
    public let text: String
    public let adapterID: String
    public let reality: ExecutionReality
}
public protocol VoiceRevisionAdapter: Sendable {
    func draft(turn: FrozenVoiceTurn, original: String) async throws -> VoiceRevisionDraft
}
public struct FixtureVoiceRevisionAdapter: VoiceRevisionAdapter {
    public init() {}
    public func draft(turn: FrozenVoiceTurn, original: String) async throws -> VoiceRevisionDraft {
        guard case .document(let reference) = turn.target, textHash(original) == reference.contentHash,
              textHash(turn.transcript.submittedText) == turn.transcript.submittedTextHash else { throw CatpawError.conflict }
        return VoiceRevisionDraft(turn: turn, text: original + "\n\n【口述改稿模拟 · 请检查并编辑】\n本轮要求：\(turn.transcript.submittedText)\n\n此段只是本地流程样例，未执行真实模型改写。", adapterID: "catpaw.fixture.voice-revision.v1", reality: .simulated)
    }
}
public enum ReadoutMode: String, CaseIterable, Codable, Sendable { case full, summary, selection }
public struct ReadoutPlan: Sendable {
    public let document: DocumentReference
    public let sourceKind: String
    public let sourceText: String
    public let mode: ReadoutMode
    public let selectionIndex: Int
    public let segments: [String]
    public let rateMultiplier: Double
    public let startParagraph: Int
    public var speechText: String { segments.dropFirst(startParagraph).joined(separator: "\n\n") }
    public var allowsPublicTTS: Bool {
        guard PublicReadoutSample.allows(reference: document, sourceKind: sourceKind, text: sourceText),
              let checked = try? ReadoutRouter.make(reference: document, text: sourceText, sourceKind: sourceKind, mode: mode, selectionIndex: selectionIndex, rateMultiplier: rateMultiplier, startParagraph: startParagraph) else { return false }
        return checked.segments == segments
    }
}
public enum ReadoutRouter {
    public static let rates = [0.75, 1.0, 1.25, 1.5]
    public static func make(reference: DocumentReference, text: String, sourceKind: String, mode: ReadoutMode, selectionIndex: Int = 0, rateMultiplier: Double = 1, startParagraph: Int = 0) throws -> ReadoutPlan {
        guard textHash(text) == reference.contentHash, rates.contains(rateMultiplier) else { throw CatpawError.conflict }
        let paragraphs = text.components(separatedBy: "\n\n")
        let segments: [String]
        switch mode {
        case .full: segments = paragraphs
        case .summary: segments = [paragraphs.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""]
        case .selection:
            guard paragraphs.indices.contains(selectionIndex), !paragraphs[selectionIndex].isEmpty else { throw CatpawError.invalid("请选择可朗读的段落。") }
            segments = [paragraphs[selectionIndex]]
        }
        guard segments.indices.contains(startParagraph), !segments.joined().isEmpty else { throw CatpawError.invalid("朗读正文或段落不可用。") }
        return ReadoutPlan(document: reference, sourceKind: sourceKind, sourceText: text, mode: mode, selectionIndex: selectionIndex, segments: segments, rateMultiplier: rateMultiplier, startParagraph: startParagraph)
    }
    public static func retime(_ plan: ReadoutPlan, rateMultiplier: Double, paragraph: Int) throws -> ReadoutPlan {
        try make(reference: plan.document, text: plan.sourceText, sourceKind: plan.sourceKind, mode: plan.mode, selectionIndex: plan.selectionIndex, rateMultiplier: rateMultiplier, startParagraph: paragraph)
    }
}
public protocol ReadoutAdapter: Sendable { func play(_ plan: ReadoutPlan) async throws }
public actor RecordingReadoutAdapter: ReadoutAdapter {
    private var plans: [ReadoutPlan] = []
    public init() {}
    public func play(_ plan: ReadoutPlan) async throws {
        guard plan.allowsPublicTTS else { throw CatpawError.unavailable(PublicReadoutSample.restriction) }
        plans.append(plan)
    }
    public func received() -> [ReadoutPlan] { plans }
}
