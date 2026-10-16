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
    /// First lead memory across snapshots (in order: cloud backend, then local), honouring each 「使用记忆」 toggle.
    static func lead(in snapshots: [MemoryLibrarySnapshot]) -> (minutes: Int, item: MemoryLibraryItem)? {
        // Codex P0-2: one 「使用记忆」 switch for the user — any source switched off disables memory for every source.
        guard snapshots.allSatisfy(\.useMemory) else { return nil }
        for snap in snapshots {
            for item in snap.items { if let n = leadMinutes(in: item.content) { return (n, item) } }
        }
        return nil
    }
    static func isLeadMemory(_ text: String) -> Bool {
        text.range(of: #"提前\s*\d{1,3}\s*分钟"#, options: .regularExpression) != nil
    }
}
