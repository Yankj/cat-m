import Foundation

/// Chat-UX #6: undo of a device_call receipt (calendar_create / reminder_create / alarm_set).
/// The phone deletes the EventKit item it created for that call_id, then reports the outcome to the turn
/// (`POST …/turns/{t}/device-undo`) so the model's next reply knows. Already-gone counts as a successful undo,
/// the same rule the proactive card's 撤销 and 任务's 本机 rows use.
public enum DeviceUndoOutcome: String, Sendable, Equatable, CaseIterable, Codable {
    case undone, alreadyGone = "already_gone", failed
    /// Item is no longer on the phone.
    public var removed: Bool { self != .failed }
}

public enum DeviceUndoRules {
    public static let undoableTools: Set<String> = ["calendar_create", "reminder_create", "alarm_set"]
    /// Only a successful write that created an item can be undone, and only once.
    public static func canUndo(tool: String, status: String, alreadyUndone: Bool) -> Bool {
        undoableTools.contains(tool) && status == "ok" && !alreadyUndone
    }
    /// `found`: the item still existed; `deleted`: the remove succeeded.
    public static func outcome(found: Bool, deleted: Bool) -> DeviceUndoOutcome {
        !found ? .alreadyGone : deleted ? .undone : .failed
    }
    /// `{call_id, operation_id, status}`; operation_id is stable per call so a retry replays.
    public static func body(callID: String, outcome: DeviceUndoOutcome, operationID: UUID) -> [String: String] {
        ["call_id": callID, "operation_id": operationID.uuidString.lowercased(), "status": outcome.rawValue]
    }
}

/// Undo reports not yet acknowledged by the server. Persisted, and drained by `retryPendingReports` (launch + foreground),
/// so an undo done offline or after an app restart still reaches the model. The server replays per call_id.
public struct DeviceUndoQueue: Codable, Equatable, Sendable {
    public private(set) var pending: [String: DeviceUndoOutcome] = [:]
    public init() {}
    public var isEmpty: Bool { pending.isEmpty }
    public mutating func enqueue(_ callID: String, _ outcome: DeviceUndoOutcome) { pending[callID] = outcome }
    public mutating func acknowledge(_ callID: String) { pending[callID] = nil }
    /// Sends every pending report in call_id order; keeps the ones that failed.
    public func drained(_ send: (String, DeviceUndoOutcome) async throws -> Void) async -> DeviceUndoQueue {
        var left = self
        for (id, outcome) in pending.sorted(by: { $0.key < $1.key }) {
            do { try await send(id, outcome); left.acknowledge(id) } catch {}
        }
        return left
    }
}

/// call_id → (conversation, turn), persisted so a device-undo report can find its turn after an app restart
/// (the session service's in-memory index is empty then). Newest `capacity` entries are kept.
public struct DeviceCallTurnIndex: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable { public let conversationID: UUID; public let turnID: UUID; public let at: Date }
    public private(set) var entries: [String: Entry] = [:]
    public static let capacity = 300
    public init() {}
    public func turn(for callID: String) -> (UUID, UUID)? { entries[callID].map { ($0.conversationID, $0.turnID) } }
    public mutating func set(_ callID: String, conversationID: UUID, turnID: UUID, at: Date = Date()) {
        entries[callID] = .init(conversationID: conversationID, turnID: turnID, at: at)
        if entries.count > Self.capacity {
            for (id, _) in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - Self.capacity) { entries[id] = nil }
        }
    }
    public static let storageKey = "catpaw.devicecall.turns.v1"
    public static func load(_ defaults: UserDefaults) -> DeviceCallTurnIndex {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(DeviceCallTurnIndex.self, from: $0) } ?? .init()
    }
    public func save(_ defaults: UserDefaults) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) } }
}
