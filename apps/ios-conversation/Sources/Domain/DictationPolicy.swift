import Foundation

/// Dictation rules that need no audio (portable-tested in NoBugP0Runner).
public enum DictationPolicy {
    /// Recognition locale follows the app language (Settings › 语言), not a hardcoded zh-CN.
    public static func localeIdentifier(for language: AppLanguage) -> String { language == .english ? "en-US" : "zh-CN" }

    /// Joins dictated text onto what was already in the draft (or onto earlier segments). No space is inserted
    /// between CJK text (Chinese never uses one), nor after a newline / space / CJK punctuation; Latin words get one.
    public static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        if last.isWhitespace || first.isWhitespace { return head + tail }
        if isCJK(last) || isCJK(first) { return head + tail }
        if first.isPunctuation { return head + tail }
        return head + " " + tail
    }
    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x3000...0x303F).contains(s.value)
                || (0xFF00...0xFFEF).contains(s.value) || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
        }
    }
}

/// Text of one dictation session across recognition segments. A segment ends on a pause (final result), a recognizer
/// error or the per-request time limit; its text is committed and a new segment starts, so nothing said is lost.
public struct DictationTranscript: Equatable, Sendable {
    public private(set) var committed = ""
    public private(set) var current = ""
    public init() {}
    public var text: String { DictationPolicy.join(committed, current) }
    public mutating func update(_ partial: String) { current = partial }
    public mutating func commit() { committed = text; current = "" }
}

public enum DictationRestart {
    /// Consecutive segments that ended in an error without any text before we give up (mic broken, recognizer down).
    public static let maxEmptyFailures = 3
    public enum Decision: Equatable { case restart, finish, fail }
    /// Called when a segment ends while the user is still dictating (not after they tapped stop / released).
    public static func decide(failed: Bool, segmentHadText: Bool, emptyFailures: Int, sessionHasText: Bool) -> Decision {
        if !failed { return .restart }                                  // pause → keep listening
        if segmentHadText || emptyFailures + 1 < maxEmptyFailures { return .restart }
        return sessionHasText ? .finish : .fail
    }
}

/// Root cause 1: which recognizer runs, best first. iOS 26: SpeechAnalyzer with SpeechTranscriber (model asset via
/// AssetInventory), else DictationTranscriber. Older iOS or no analyzer support: SFSpeechRecognizer on-device when the
/// device supports it for the locale, otherwise Apple's server recognition (instead of refusing to start).
public enum DictationEngineTier: String, Sendable, CaseIterable {
    case speechTranscriber, dictationTranscriber, onDeviceRecognizer, serverRecognizer, unavailable
    /// SFSpeechRecognizer requests are capped (~1 min for server recognition); rotate before that and keep going.
    public static let recognizerSegmentLimit: TimeInterval = 55
    public var segmentLimit: TimeInterval? { self == .onDeviceRecognizer || self == .serverRecognizer ? Self.recognizerSegmentLimit : nil }
    public var usesNetwork: Bool { self == .serverRecognizer }
    public static func choose(analyzerOS: Bool, speechTranscriberReady: Bool, dictationTranscriberReady: Bool,
                              recognizerAvailable: Bool, recognizerOnDevice: Bool) -> DictationEngineTier {
        if analyzerOS && speechTranscriberReady { return .speechTranscriber }
        if analyzerOS && dictationTranscriberReady { return .dictationTranscriber }
        guard recognizerAvailable else { return .unavailable }
        return recognizerOnDevice ? .onDeviceRecognizer : .serverRecognizer
    }
}
