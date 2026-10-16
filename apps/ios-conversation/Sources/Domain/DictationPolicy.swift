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
