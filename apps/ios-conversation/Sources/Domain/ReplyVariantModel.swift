import Foundation

/// Pure model behind `ReplyVariantStore`: regenerate (same prompt) and edit-and-resend (new prompt) both add a
/// variant turn to the group of the ORIGINAL turn, so the old answer stays reachable with ‹ 1/2 ›.
/// Portable-tested (Tests/NoBugP0Runner.swift › replyVariants). Persisted JSON stays compatible with v1 groups
/// (`{turns, selected}`): `promptOf` is optional.
public struct ReplyVariantGroup: Codable, Equatable, Sendable {
    public var turns: [UUID]
    public var selected: Int
    /// Variant turn → turn whose user prompt it answers: itself after an edit, inherited on regenerate. Absent = root.
    public var promptOf: [UUID: UUID]?

    public init(root: UUID) { turns = [root]; selected = 0; promptOf = nil }
    public init(turns: [UUID], selected: Int) { self.turns = turns; self.selected = selected; promptOf = nil }

    public var root: UUID { turns[0] }
    public var selectedTurn: UUID { turns[min(max(0, selected), turns.count - 1)] }
    public func promptTurn(of turn: UUID) -> UUID { promptOf?[turn] ?? root }
    /// The user prompt row shown above the selected answer.
    public var visiblePromptTurn: UUID { promptTurn(of: selectedTurn) }
    /// Edited prompts in this group, oldest first (root first).
    public var promptTurns: [UUID] { var seen: [UUID] = []; for t in turns { let p = promptTurn(of: t); if !seen.contains(p) { seen.append(p) } }; return seen }

    /// Regenerate: re-answers the prompt that is visible now (the edited one if the user is on an edited variant).
    public mutating func addRegenerate(_ turn: UUID) {
        guard !turns.contains(turn) else { return }
        let prompt = visiblePromptTurn
        turns.append(turn)
        if prompt != root { promptOf = (promptOf ?? [:]).merging([turn: prompt]) { $1 } }
        selected = turns.count - 1
    }
    /// Edit & resend: the new turn carries its own (edited) prompt; earlier answers stay as switchable versions.
    public mutating func addEdit(_ turn: UUID) {
        guard !turns.contains(turn) else { return }
        turns.append(turn)
        promptOf = (promptOf ?? [:]).merging([turn: turn]) { $1 }
        selected = turns.count - 1
    }
    public mutating func step(_ delta: Int) { selected = min(max(0, selected + delta), turns.count - 1) }
    /// Only the selected variant's answer rows and the prompt it answers are shown.
    public func isVisible(turn: UUID, isUserPrompt: Bool) -> Bool { isUserPrompt ? turn == visiblePromptTurn : turn == selectedTurn }
}

/// Edit & resend input rules (pure).
public enum MessageEditRules {
    public static func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Non-empty and actually changed (an unchanged resend is a regenerate, not an edit).
    public static func canSend(_ text: String, original: String) -> Bool {
        let t = normalized(text); return !t.isEmpty && t != normalized(original) && t.count <= 8000
    }
}
