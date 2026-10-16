import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Pure rules behind ProactiveEngine (NoBug P0-5: unit-testable without EventKit/MapKit/UIKit).
enum ProactiveRules {
    /// Trigger window for an upcoming meeting, in minutes from now (exclusive 0, inclusive 180).
    static let windowMinutes = 180.0
    /// Travel estimates above this are treated as invalid (→ 「未用到 ETA」).
    static let maxTravelMinutes = 180
    static let maxLeadMinutes = 180

    static func inWindow(start: Date, now: Date) -> Bool {
        let minutes = start.timeIntervalSince(now) / 60
        return minutes > 0 && minutes <= windowMinutes
    }
    /// Stable per (event, start): the same meeting never triggers twice.
    static func signalHash(eventID: String, start: Date) -> String {
        let raw = "\(eventID)|\(Int(start.timeIntervalSince1970))"
        return SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    /// Dedupe ledger: returns true (and records `now`) only the first time `hash` is seen.
    static func admit(_ hash: String, ledger: inout [String: Double], now: Date) -> Bool {
        guard ledger[hash] == nil else { return false }
        ledger[hash] = now.timeIntervalSince1970; return true
    }
    /// leave_at = start − lead − travel (travel only when the ETA was actually used).
    static func leaveAt(start: Date, leadMinutes: Int, travelMinutes: Int?, usedETA: Bool) -> Date {
        let buffer = leadMinutes + (usedETA ? (travelMinutes ?? 0) : 0)
        return start.addingTimeInterval(TimeInterval(-buffer * 60))
    }
    /// ETA sanity: nil / non-positive / > 180 min → unused.
    static func validTravel(_ minutes: Int?) -> Int? {
        guard let minutes, minutes >= 0, minutes <= maxTravelMinutes else { return nil }
        return minutes
    }
    /// "提前 N 分钟" / "N minutes early" in a memory → N (1…180), else nil.
    static func leadMinutes(in text: String) -> Int? {
        guard let r = text.range(of: #"提前\s*(\d{1,3})\s*分钟"#, options: .regularExpression)
                ?? text.range(of: #"(\d{1,3})\s*min(ute)?s? (early|ahead)"#, options: .regularExpression),
              let n = Int(text[r].filter(\.isNumber)), n > 0, n <= maxLeadMinutes else { return nil }
        return n
    }
    /// First lead memory across snapshots (in order: cloud backend, then local), honouring each 「使用记忆」 toggle.
    static func lead(in snapshots: [MemoryLibrarySnapshot]) -> (minutes: Int, item: MemoryLibraryItem)? {
        for snap in snapshots where snap.useMemory {
            for item in snap.items { if let n = leadMinutes(in: item.content) { return (n, item) } }
        }
        return nil
    }
    static func isLeadMemory(_ text: String) -> Bool {
        text.range(of: #"提前\s*\d{1,3}\s*分钟"#, options: .regularExpression) != nil
    }

    // MARK: Codex P0-3 — delivery per level, with on-device quiet hours and daily cap (same defaults as the server).
    static let dailyNotifyCap = 5
    static let quietStartHour = 22, quietEndHour = 8
    static func isQuiet(_ now: Date, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: now); return h >= quietStartHour || h < quietEndHour
    }
    struct Delivery: Equatable {
        var level: ProactiveLevel; var inAppCard: Bool; var systemNotification: Bool; var sound: Bool; var timeSensitive: Bool; var liveActivity: Bool
    }
    /// The final, on-device gate: applies even when the server already decided (offline rules use it too).
    static func delivery(level requested: ProactiveLevel, now: Date, deliveredToday: Int, calendar: Calendar = .current) -> Delivery {
        var level = requested
        if level >= .notify, isQuiet(now, calendar: calendar) { level = .card }
        if level >= .notify, deliveredToday >= dailyNotifyCap { level = .card }
        switch level {
        case .silent: return .init(level: level, inAppCard: false, systemNotification: false, sound: false, timeSensitive: false, liveActivity: false)
        case .card: return .init(level: level, inAppCard: true, systemNotification: false, sound: false, timeSensitive: false, liveActivity: false)
        case .notify: return .init(level: level, inAppCard: true, systemNotification: true, sound: true, timeSensitive: false, liveActivity: false)
        case .interrupt: return .init(level: level, inAppCard: true, systemNotification: true, sound: true, timeSensitive: true, liveActivity: true)
        }
    }
    /// The pre-scheduled notification fires while the app may be killed/offline: same gate, evaluated at fire time.
    static func prescheduleAllowed(fire: Date, deliveredToday: Int, calendar: Calendar = .current) -> Bool {
        delivery(level: .notify, now: fire, deliveredToday: deliveredToday, calendar: calendar).systemNotification
    }
}

/// catpaw.proactive.decision.v1 LEVELS, ordered.
enum ProactiveLevel: Int, Comparable, Equatable, Sendable {
    case silent, card, notify, interrupt
    init(server raw: String?) { self = ["silent": .silent, "card": .card, "notify": .notify, "interrupt": .interrupt][raw ?? ""] ?? .card }
    var name: String { ["silent", "card", "notify", "interrupt"][rawValue] }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: Codex P0-5 — "evaluated" is not "delivered"; per-action state.

/// An early silent verdict is only *evaluated*: the same meeting is re-evaluated as it nears.
/// Only an actual delivery (card / notification) closes the hash for good.
struct ProactiveSignalLedger: Codable, Sendable, Equatable {
    static let reevaluateAfter: TimeInterval = 10 * 60
    var evaluated: [String: Double] = [:]
    var delivered: [String: String] = [:]
    init() {}
    /// v1 ledger entries were written for delivered and silent alike; treat them as delivered (never re-notify after upgrade).
    init(legacy: [String: Double]) { delivered = legacy.mapValues { _ in "legacy" } }
    func shouldEvaluate(_ hash: String, now: Date) -> Bool {
        guard delivered[hash] == nil else { return false }
        guard let at = evaluated[hash] else { return true }
        return now.timeIntervalSince1970 - at >= Self.reevaluateAfter
    }
    mutating func markEvaluated(_ hash: String, now: Date) { evaluated[hash] = now.timeIntervalSince1970 }
    mutating func markDelivered(_ hash: String, level: ProactiveLevel, now: Date) {
        delivered[hash] = level.name; evaluated[hash] = now.timeIntervalSince1970
    }
}

extension ProactiveRules {
    /// Offline rules: too late → silent; too early (well before lead + travel) → silent for now (re-evaluated later); else notify.
    static func localLevel(minutesUntil: Int, leadMinutes: Int, travelMinutes: Int?) -> ProactiveLevel {
        if minutesUntil < 3 { return .silent }
        if minutesUntil > leadMinutes + (travelMinutes ?? 0) + 15 { return .silent }
        return .notify
    }
}

enum ProactiveActionState: String, Codable, Sendable, Equatable { case pending, succeeded, cancelled, unavailable, failed }

/// Per-action state on one suggestion: creating the reminder must not hide 「告诉参会人」, and only a real success syncs.
enum ProactiveActionStates {
    static let effects: Set<String> = ["create_reminder", "notify_attendees"]
    static func allEffectsDone(_ all: [String], _ st: [String: ProactiveActionState]) -> Bool {
        let e = all.filter(effects.contains); return !e.isEmpty && e.allSatisfy { st[$0] == .succeeded }
    }
    static func remaining(_ all: [String], _ st: [String: ProactiveActionState]) -> [String] {
        allEffectsDone(all, st) ? [] : all.filter { st[$0] != .succeeded }
    }
    static func shouldSync(_ s: ProactiveActionState) -> Bool { s == .succeeded }
    static func from(serverStates: [String: String]) -> [String: ProactiveActionState] {
        serverStates.compactMapValues { $0 == "done" ? .succeeded : nil }
    }
    /// Codex PR90 #4: the cloud's `action_states` (decoded on every suggestion) merged with local outcomes; a cloud success wins.
    static func merge(local: [String: ProactiveActionState], server: [String: String]?) -> [String: ProactiveActionState] {
        local.merging(from(serverStates: server ?? [:])) { l, r in r == .succeeded ? r : l }
    }
    /// Execution entry: an effect already succeeded (locally or in the cloud) is never run again.
    static func shouldExecute(_ action: String, _ st: [String: ProactiveActionState]) -> Bool {
        !effects.contains(action) || st[action] != .succeeded
    }
}
