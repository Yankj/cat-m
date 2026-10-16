import Foundation

/// catpaw.proactive.undo.v1 (Codex PR90c #5) — one undo semantics for the device and the server
/// (services/edge decision.mjs `undo`; shared vectors in services/edge/test/fixtures/proactive/undo-vectors.json):
/// undo reverts the most recent reversible action; a sent SMS (notify_attendees) is irreversible and kept;
/// the status is derived from what remains (last snooze/dismiss wins, else done iff every offered effect is done).
enum ProactiveUndo {
    static let irreversible: Set<String> = ["notify_attendees"]
    struct Plan: Equatable { var removed: String?; var removedIndex: Int?; var after: [String]; var status: String }
    static func plan(offered: [String], taken: [String], status: String) -> Plan {
        guard let i = taken.lastIndex(where: { !irreversible.contains($0) }) else { return Plan(removed: nil, removedIndex: nil, after: taken, status: status) }
        var after = taken; let removed = after.remove(at: i)
        return Plan(removed: removed, removedIndex: i, after: after, status: derive(offered: offered, taken: after))
    }
    static func derive(offered: [String], taken: [String]) -> String {
        if taken.last == "snooze" { return "snoozed" }
        if taken.last == "dismiss" { return "dismissed" }
        let effects = offered.filter(ProactiveActionStates.effects.contains)
        return !effects.isEmpty && effects.allSatisfy(taken.contains) ? "done" : "pending"
    }
}
