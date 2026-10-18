import Foundation

/// chat-ux #4: tappable follow-up questions after an answer. The model ends its reply with
/// ```catpaw-card:followups (one question per line); the server asks for it only when the client advertises
/// `followups` in X-Catpaw-UI-Kinds. Pure parser, portable-tested.
public enum FollowUpSuggestions {
    public static let kind = "followups"
    public static let maxCount = 3, maxCharacters = 30
    public static let tapNotification = Notification.Name("catpaw.followUp.tap")

    /// 2–3 clean questions, or [] (a single suggestion or an unclosed fence renders nothing).
    public static func parse(_ payload: Data, closed: Bool) -> [String] {
        guard closed, let text = String(data: payload, encoding: .utf8) else { return [] }
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: #"^([-*•]|\d+[.、)])\s*"#, options: .regularExpression) { line.removeSubrange(r) }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”「」"))
            guard !line.isEmpty, line.count <= maxCharacters, !line.contains("```"), !out.contains(line) else { continue }
            out.append(line)
            if out.count == maxCount { break }
        }
        return out.count >= 2 ? out : []
    }

    /// chat-context-1522 #1: chips belong to the latest assistant answer only, and disappear once the user has sent
    /// something after it. `rows` is the visible transcript in order (answer = assistant prose, not a tool row).
    public static func hostMessageID<ID: Equatable>(_ rows: [(id: ID, answer: Bool, user: Bool)]) -> ID? {
        for row in rows.reversed() {
            if row.user { return nil }
            if row.answer { return row.id }
        }
        return nil
    }
}
