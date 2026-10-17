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

// MARK: - v1.1 voice conversation (pure, portable: no AVFoundation / UIKit; driven by `VoiceChatController`)

/// Where the hands-free voice loop is. `waiting` = the turn was sent and the assistant is thinking / streaming.
public enum VoiceChatPhase: Equatable, Sendable {
    case idle, listening, sending, waiting, speaking
    case paused(VoiceChatPauseReason)
    case ended
}
public enum VoiceChatPauseReason: Equatable, Sendable {
    /// A card / approval needs the user on screen (requires_approval or a catpaw.ui card): the loop never acts for them.
    case needsConfirmation
    /// Audio interruption (call, Siri) or the output route went away.
    case interrupted
    /// The recognizer or the turn failed; the user can resume.
    case failed
}
public enum VoiceChatHaptic: Equatable, Sendable { case listen, turnSent, reply, pause }
/// Side effects the controller performs, in order. The machine itself never touches audio.
public enum VoiceChatEffect: Equatable, Sendable {
    case startListening, stopListening
    case send(String)
    case speak(String)
    case stopSpeaking
    /// Say (or, text-only, show) that something needs on-screen confirmation.
    case announceConfirmation
    case haptic(VoiceChatHaptic)
    case deactivateAudio
    /// Every pause: give the audio session back (setActive(false, .notifyOthersOnDeactivation)) once the line being
    /// spoken (the confirmation line) has finished, so other apps are not left ducked while the user looks at the screen.
    case releaseAudio
}
/// What came back for the sent turn, already reduced to speech (`VoiceSpeechText`).
public struct VoiceChatReply: Equatable, Sendable {
    public var speech: String
    /// false → text-only (TTS not allowed by policy, or nothing speakable): the loop goes straight back to listening.
    public var speakable: Bool
    /// The reply carries a card the user must confirm on screen: after its line is read the loop pauses instead of listening.
    public var needsConfirmation: Bool
    public init(speech: String, speakable: Bool, needsConfirmation: Bool = false) { self.speech = speech; self.speakable = speakable; self.needsConfirmation = needsConfirmation }
}
public enum VoiceChatEvent: Equatable, Sendable {
    case start
    /// Live partial transcript of the current utterance.
    case transcript(String)
    /// ~1.2 s without new recognized text (`VoiceChatLoop.silenceInterval`).
    case silenceElapsed
    /// The recognizer delivered its final text (or stopped on its own; "" = nothing heard).
    case listeningEnded(String)
    case replyFinished(VoiceChatReply)
    case approvalRequired
    case speechFinished
    /// The user spoke (or tapped the orb) while the reply was being read: stop speaking and listen.
    /// `alreadyListening`: the barge-in recognizer is running and simply continues as the next utterance.
    case bargeIn(alreadyListening: Bool)
    case resume
    case interruption
    case failed
    /// App went to the background (never on .inactive).
    case background
    case exit
}

/// The hands-free loop: listening → sending → waiting → speaking → listening, with barge-in, card pause and exit.
/// Pure value type: `handle` returns the effects for the controller to run (unit-tested without audio).
public struct VoiceChatLoop: Equatable, Sendable {
    public static let silenceInterval: TimeInterval = 1.2
    public private(set) var phase: VoiceChatPhase = .idle
    public private(set) var transcript = ""
    /// Texts handed to `send`, in order (each one is a normal chat turn in the current conversation).
    public private(set) var sent: [String] = []
    private var pauseAfterSpeech = false
    public init() {}

    public var isActive: Bool { phase != .idle && phase != .ended }

    public mutating func handle(_ event: VoiceChatEvent) -> [VoiceChatEffect] {
        if phase == .ended { return [] }
        switch (event, phase) {
        case (.exit, _), (.background, _):
            let wasSpeaking = phase == .speaking
            phase = .ended; transcript = ""
            return [.stopListening] + (wasSpeaking ? [.stopSpeaking] : []) + [.deactivateAudio]
        case (.start, .idle), (.resume, .paused):
            return listen()
        case (.transcript(let t), .listening):
            transcript = t; return []
        case (.transcript(let t), .sending):
            transcript = t; return []
        case (.silenceElapsed, .listening):
            guard Self.isMeaningful(transcript) else { return [] }   // silence before any speech / only filler: keep listening
            phase = .sending
            return [.stopListening]
        case (.listeningEnded(let final), .listening), (.listeningEnded(let final), .sending):
            let text = Self.trimmed(final).isEmpty ? Self.trimmed(transcript) : Self.trimmed(final)
            guard Self.isMeaningful(text) else { return listen() }   // nothing heard / filler only (嗯, uh): listen again
            phase = .waiting; transcript = ""; sent.append(text)
            return [.send(text), .haptic(.turnSent)]
        case (.replyFinished(let reply), .waiting):
            guard reply.speakable, !Self.trimmed(reply.speech).isEmpty else {   // text-only fallback
                if reply.needsConfirmation { phase = .paused(.needsConfirmation); return [.haptic(.pause), .announceConfirmation, .releaseAudio] }
                return listen()
            }
            phase = .speaking; pauseAfterSpeech = reply.needsConfirmation
            return [.haptic(.reply), .speak(reply.speech)]
        case (.approvalRequired, .waiting), (.approvalRequired, .speaking), (.approvalRequired, .listening), (.approvalRequired, .sending):
            let effects: [VoiceChatEffect] = phase == .speaking ? [.stopSpeaking] : (phase == .listening || phase == .sending) ? [.stopListening] : []
            phase = .paused(.needsConfirmation); transcript = ""
            return effects + [.haptic(.pause), .announceConfirmation, .releaseAudio]
        case (.speechFinished, .speaking):
            if pauseAfterSpeech { pauseAfterSpeech = false; phase = .paused(.needsConfirmation); return [.haptic(.pause), .releaseAudio] }   // the card line already asked
            return listen()
        case (.bargeIn(let already), .speaking):
            phase = .listening; transcript = ""; pauseAfterSpeech = false
            return [.stopSpeaking, .haptic(.listen)] + (already ? [] : [.startListening])
        case (.interruption, .listening), (.interruption, .sending), (.interruption, .waiting), (.interruption, .speaking):
            let effects: [VoiceChatEffect] = phase == .speaking ? [.stopSpeaking] : phase == .waiting ? [] : [.stopListening]
            phase = .paused(.interrupted); transcript = ""
            return effects + [.haptic(.pause), .releaseAudio]
        case (.failed, .listening), (.failed, .sending), (.failed, .waiting), (.failed, .speaking):
            let effects: [VoiceChatEffect] = phase == .speaking ? [.stopSpeaking] : phase == .waiting ? [] : [.stopListening]
            phase = .paused(.failed); transcript = ""
            return effects + [.haptic(.pause), .releaseAudio]
        default:
            return []   // stale / out-of-order events are ignored (e.g. a late transcript after the turn was sent)
        }
    }
    private mutating func listen() -> [VoiceChatEffect] {
        phase = .listening; transcript = ""
        return [.startListening, .haptic(.listen)]
    }
    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Filler that alone never makes a turn (a cough or "嗯" picked up between sentences must not be sent).
    static let fillerWords: Set<String> = ["uh", "um", "umm", "uhm", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "mhm", "oh", "huh"]
    static let fillerCharacters: Set<Character> = ["嗯", "啊", "呃", "额", "哦", "噢", "喔", "唔", "哈", "呀", "诶", "欸", "哎", "呢", "吧", "嘛"]
    /// One-character (or doubled) yes/no answers that ARE a reply, e.g. to "要我帮你订吗？". Sent even though short;
    /// pure filler (嗯 / 啊 / uh) stays dropped.
    static let shortReplies: Set<String> = ["好", "行", "对", "不", "是", "嗯嗯", "好好", "对对", "不不", "yes", "no"]
    /// At least 2 letters/digits left after dropping punctuation and filler (嗯/啊/uh…), or a short yes/no reply.
    public static func isMeaningful(_ text: String) -> Bool {
        let bare = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        if shortReplies.contains(bare) { return true }
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        var count = 0
        for word in words where !fillerWords.contains(String(word)) {
            count += word.filter { !fillerCharacters.contains($0) }.count
        }
        return count >= 2
    }
}

/// Turns an assistant reply into what is read aloud: no code blocks, no card JSON, no URLs, no markdown symbols.
/// A card becomes one short line asking the user to confirm on screen. Capped so a long answer is summarised by
/// "the rest is on screen" instead of minutes of speech.
public enum VoiceSpeechText {
    public static let maxCharacters = 600
    public struct Result: Equatable, Sendable {
        public var text: String
        public var hadCard: Bool
        public var hadCode: Bool
    }
    public static func cardLine(kind: String?, english: Bool) -> String {
        switch kind {
        case "calendar": return english ? "I've prepared a calendar card. Please confirm it on screen." : "我准备了一张日程卡片，请在屏幕上确认。"
        case "reminder": return english ? "I've prepared a reminder card. Please confirm it on screen." : "我准备了一张提醒卡片，请在屏幕上确认。"
        default: return english ? "I've prepared a card. Please confirm it on screen." : "我准备了一张卡片，请在屏幕上确认。"
        }
    }
    public static func confirmationLine(english: Bool) -> String {
        english ? "This needs your confirmation on screen. I'll wait." : "这一步需要你在屏幕上确认，我先暂停。"
    }
    static func codeLine(english: Bool) -> String { english ? "The code is on screen." : "代码放在屏幕上了。" }
    static func moreLine(english: Bool) -> String { english ? "The rest is on screen." : "其余内容请看屏幕。" }

    public static func make(_ content: String, english: Bool) -> Result {
        var hadCard = false, hadCode = false, cardKind: String?
        var out: [String] = []
        var inFence = false, fenceBody: [String] = [], fenceLang = ""
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inFence {
                    let body = fenceBody.joined(separator: "\n")
                    if isCard(lang: fenceLang, body: body) { hadCard = true; cardKind = cardKind ?? kind(of: body) } else { hadCode = true }
                    inFence = false; fenceBody = []
                } else { inFence = true; fenceLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            if inFence { fenceBody.append(raw); continue }
            // A bare JSON card object on its own line(s).
            if (line.hasPrefix("{") || line.hasPrefix("[")) && (line.contains("\"type\"") || line.contains("catpaw.ui") || line.contains("\":")) {
                hadCard = true; cardKind = cardKind ?? kind(of: line); continue
            }
            let spoken = clean(line)
            if !spoken.isEmpty { out.append(spoken) }
        }
        if inFence { let body = fenceBody.joined(separator: "\n"); if isCard(lang: fenceLang, body: body) { hadCard = true; cardKind = cardKind ?? kind(of: body) } else { hadCode = true } }   // unterminated fence (streamed)
        var text = out.joined(separator: english ? " " : "")
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxCharacters { text = cut(text, english: english) }
        if hadCode, text.isEmpty { text = codeLine(english: english) }
        if hadCard { text = text.isEmpty ? cardLine(kind: cardKind, english: english) : text + (english ? " " : "") + cardLine(kind: cardKind, english: english) }
        return Result(text: text, hadCard: hadCard, hadCode: hadCode)
    }
    static func isCard(lang: String, body: String) -> Bool {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return lang.hasPrefix("json") || lang.contains("catpaw") || lang == "card" || b.hasPrefix("{") || b.contains("catpaw.ui")
    }
    static func kind(of body: String) -> String? {
        let b = body.lowercased()
        if b.contains("calendar") || b.contains("event") || b.contains("日程") { return "calendar" }
        if b.contains("reminder") || b.contains("提醒") { return "reminder" }
        return nil
    }
    /// One line of prose: links keep their text, URLs / images / inline code markers / markdown symbols go.
    static func clean(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)            // images
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)         // [text](url) → text
        s = s.replacingOccurrences(of: #"(?i)(?:https?://|www\.)\S+"#, with: "", options: .regularExpression)      // bare URLs
        s = s.replacingOccurrences(of: #"^\s{0,3}(?:#{1,6}\s+|>\s*|[-*+•]\s+|\d{1,3}[.)]\s+)"#, with: "", options: .regularExpression)   // heading / quote / bullet / number
        s = s.replacingOccurrences(of: #"^\s*\|?\s*:?-{3,}.*$"#, with: "", options: .regularExpression)           // table rule
        s = s.replacingOccurrences(of: "|", with: " ")
        s = s.replacingOccurrences(of: #"(\*\*|__|\*|_|`|~~)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)                       // "()" left by a removed URL
        return s.trimmingCharacters(in: .whitespaces)
    }
    /// Cut at the last sentence end before the cap, then say the rest is on screen.
    static func cut(_ text: String, english: Bool) -> String {
        let head = String(text.prefix(maxCharacters))
        let ends: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";"]
        let cutAt = head.lastIndex(where: { ends.contains($0) }).map { head.index(after: $0) } ?? head.endIndex
        return String(head[..<cutAt]).trimmingCharacters(in: .whitespaces) + (english ? " " : "") + moreLine(english: english)
    }
}

/// Barge-in while the reply is read through the speaker: the recognizer can hear the synthesized voice itself.
/// A heard fragment that is (mostly) part of what is being spoken is treated as echo, not as the user.
public enum VoiceBargeIn {
    public static let minimumCharacters = 2
    static func normalized(_ s: String) -> [Character] {
        Array(s.lowercased().precomposedStringWithCompatibilityMapping.filter { $0.isLetter || $0.isNumber })
    }
    public static func isLikelyEcho(heard: String, speaking: String) -> Bool {
        let h = normalized(heard), sp = normalized(speaking)
        guard h.count >= minimumCharacters else { return true }   // a cough / one syllable never interrupts
        guard !sp.isEmpty else { return false }
        if String(sp).contains(String(h)) { return true }
        let pool = Set(sp)
        let shared = h.filter { pool.contains($0) }.count
        return Double(shared) / Double(h.count) >= 0.8
    }
}
