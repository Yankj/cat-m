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

extension ProactiveUndo {
    /// Codex PR90d #4: a snooze entry records its own until (server: taken[].until), so undo can restore the previous one.
    /// PR90e: plus the intent (its operation id) that names its notification, so undo / dismiss remove exactly it.
    static func snoozeDetail(until: Date, intent: String? = nil) -> String {
        "until=\(Int(until.timeIntervalSince1970))" + (intent.map { ";op=\($0)" } ?? "")
    }
    fileprivate static func field(_ detail: String?, _ name: String) -> Substring? {
        detail?.split(separator: ";").first { $0.hasPrefix(name + "=") }?.dropFirst(name.count + 1)
    }
    static func snoozeUntil(detail: String?, at: Date) -> Date {
        if let t = field(detail, "until").flatMap({ Double($0) }) { return Date(timeIntervalSince1970: t) }
        return at.addingTimeInterval(600)   // legacy entry: the default 10 minutes
    }
    static func snoozeIntent(detail: String?) -> String? { field(detail, "op").map(String.init) }
    /// After undo: back to "snoozed" → the remaining last snooze's until (to re-arm its notification); else nil.
    static func restoredSnooze(taken: [(action: String, at: Date, detail: String?)], status: String) -> Date? {
        guard status == "snoozed", let last = taken.last(where: { $0.action == "snooze" }) else { return nil }
        return snoozeUntil(detail: last.detail, at: last.at)
    }
}

extension ProactiveUndo {
    /// Codex PR90f #2: the outcome of re-arming a restored snooze, recorded on that snooze entry (verifiable after undo).
    static func withRestore(_ detail: String?, _ outcome: String) -> String {
        let kept = (detail ?? "").split(separator: ";").filter { !$0.hasPrefix("restore=") }.map(String.init)
        return (kept + ["restore=" + outcome.replacingOccurrences(of: ";", with: ",")]).joined(separator: ";")
    }
    static func restoreOutcome(detail: String?) -> String? { field(detail, "restore").map(String.init) }
}

/// Codex PR90f #3: the device → cloud wire, one portable definition (the engine's drain and the golden fixture
/// `services/edge/test/fixtures/proactive-sync-golden.json` the Edge suite replays both come from here).
enum ProactiveSyncWire {
    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    static func body(action: String, operationID: String, until: String?) -> [String: Any] {
        if action == "undo" { return ["operation_id": operationID] }
        var b: [String: Any] = ["action": action, "operation_id": operationID]
        if let until { b["until"] = until }
        return b
    }
    static func route(action: String) -> String { action == "undo" ? "undo" : "action" }
    /// PR90f #5: `POST suggestions` — an offline-evaluated suggestion gets its cloud record (idempotent by client id).
    static func createBody(clientID: String, title: String, reason: String, actions: [String], createdAt: Date?) -> [String: Any] {
        var b: [String: Any] = ["client_id": clientID, "title": title, "reason": reason, "actions": actions, "decision": "notify"]
        if let createdAt { b["created_at"] = iso(createdAt) }
        return b
    }
}
