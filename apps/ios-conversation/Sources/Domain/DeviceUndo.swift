import Foundation

/// Chat-UX #6: undo of a device_call receipt (calendar_create / reminder_create / alarm_set).
/// The phone deletes the EventKit item it created for that call_id, then reports the outcome to the turn
/// (`POST …/turns/{t}/device-undo`) so the model's next reply knows. Already-gone counts as a successful undo,
/// the same rule the proactive card's 撤销 and 任务's 本机 rows use.
public enum DeviceUndoOutcome: String, Sendable, Equatable, CaseIterable {
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
