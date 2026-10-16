import Foundation
import CryptoKit

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
    /// First lead memory across snapshots (in order: cloud backend, then local). Any 「使用记忆」 off ⇒ none (Codex P0-2).
    static func lead(in snapshots: [MemoryLibrarySnapshot]) -> (minutes: Int, item: MemoryLibraryItem)? {
        for snap in MemoryRecallGate.effective(snapshots) {
            for item in snap.items { if let n = leadMinutes(in: item.content) { return (n, item) } }
        }
        return nil
    }
    static func isLeadMemory(_ text: String) -> Bool {
        text.range(of: #"提前\s*\d{1,3}\s*分钟"#, options: .regularExpression) != nil
    }
}


// MARK: Codex review P0-4 — feedback that measurably changes the next decision, and undo that reports the real outcome.

enum ProactiveFeedback: String, Codable, Sendable, CaseIterable { case helpful, not_helpful, intrusive }
/// Status of a proactive card (shared by the app and the portable rules).
enum ProactiveItemStatus: String, Codable, Sendable { case pending, done, snoozed, dismissed }

struct ProactiveTriggerWeight: Codable, Equatable, Sendable {
    var weight: Double = 1
    var threshold_bump: Double = 0
}

/// Per-account feedback ledger, same math as services/edge/.../proactive/decision.mjs (feedback + evaluate gate):
/// intrusive ×0.7 / +0.1, not_helpful ×0.85 / +0.05, helpful ×1.05 / −0.02; weight 0.3…1.5, bump −0.1…0.3;
/// conf = confidence×weight, threshold = min(0.95, 0.6+bump); below → down 1 level (2 if 0.15 under), never below card.
struct ProactiveFeedbackLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let suggestionID: String
        let trigger: String
        let value: ProactiveFeedback
        var serverID: String?
    }
    static let levels = ["silent", "card", "notify", "interrupt"]
    static let baseThreshold = 0.6

    var weights: [String: ProactiveTriggerWeight] = [:]
    private(set) var entries: [Entry] = []
    private(set) var synced: [String] = []

    /// Feedback not yet accepted by the server (待同步).
    var pendingSync: [Entry] { entries.filter { !synced.contains($0.suggestionID) } }

    /// One feedback per suggestion (server keeps the first too). Returns false when already recorded.
    mutating func record(_ value: ProactiveFeedback, suggestionID: String, trigger: String, serverID: String?) -> Bool {
        guard !entries.contains(where: { $0.suggestionID == suggestionID }) else { return false }
        entries.append(Entry(suggestionID: suggestionID, trigger: trigger, value: value, serverID: serverID))
        let c = weights[trigger] ?? ProactiveTriggerWeight()
        let (mw, db): (Double, Double) = switch value {
        case .helpful: (1.05, -0.02)
        case .not_helpful: (0.85, 0.05)
        case .intrusive: (0.7, 0.1)
        }
        weights[trigger] = ProactiveTriggerWeight(weight: Self.round(min(1.5, max(0.3, c.weight * mw))),
                                                  threshold_bump: Self.round(min(0.3, max(-0.1, c.threshold_bump + db))))
        return true
    }
    mutating func markSynced(_ suggestionID: String) { if !synced.contains(suggestionID) { synced.append(suggestionID) } }
    mutating func attach(serverID: String, to suggestionID: String) {
        if let i = entries.firstIndex(where: { $0.suggestionID == suggestionID }) { entries[i].serverID = serverID }
    }

    /// The level a decision ends at after learned feedback for its trigger.
    func gate(decision: String, confidence: Double, trigger: String) -> String {
        guard let i = Self.levels.firstIndex(of: decision), i > 0 else { return decision }
        let tw = weights[trigger] ?? ProactiveTriggerWeight()
        let conf = max(0, min(1, confidence * tw.weight)), threshold = min(0.95, Self.baseThreshold + tw.threshold_bump)
        guard conf < threshold else { return decision }
        let steps = conf < threshold - 0.15 ? 2 : 1
        return Self.levels[max(1, i - steps)]
    }
    static func round(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

enum ProactiveUndoRules {
    /// Undo only succeeds when what we wrote is gone; a failed delete keeps the current status (nil = no change).
    static func statusAfterUndo(current: ProactiveItemStatus, removal: DeviceUndoOutcome) -> ProactiveItemStatus? {
        removal.removed ? .pending : nil
    }
}
