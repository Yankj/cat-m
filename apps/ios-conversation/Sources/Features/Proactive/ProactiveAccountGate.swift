import Foundation

// Codex PR90 · AccountEpoch (b): every proactive notification (local or APNs) is bound to the account it was made for,
// re-checked at presentation/response time, and deduped by one delivery id (the server event_id when there is one).
enum ProactiveAccountGate {
    static let accountKey = "catpaw_account", epochKey = "catpaw_epoch", eventKey = "catpaw_event_id", levelKey = "catpaw_level"

    static func stamp(_ info: inout [AnyHashable: Any], _ token: AccountToken, deliveryID: String, level: ProactiveLevel) {
        info[accountKey] = token.account; info[epochKey] = NSNumber(value: token.epoch); info[eventKey] = deliveryID; info[levelKey] = level.name
    }
    static func token(_ info: [AnyHashable: Any]) -> AccountToken? {
        guard let a = info[accountKey] as? String, let e = (info[epochKey] as? String).flatMap(UInt64.init) ?? (info[epochKey] as? NSNumber)?.uint64Value ?? (info[epochKey] as? UInt64) else { return nil }
        return AccountToken(account: a, epoch: e)
    }
    private static func remote(_ info: [AnyHashable: Any]) -> [String: Any]? { info["catpaw"] as? [String: Any] }
    /// One delivery id across APNs and local: server event_id, else the local suggestion id.
    static func deliveryID(_ info: [AnyHashable: Any]) -> String? {
        (remote(info)?["event_id"] as? String) ?? (info[eventKey] as? String) ?? (info["catpaw_proactive_id"] as? String)
    }
    static func isProactive(_ info: [AnyHashable: Any]) -> Bool {
        info["catpaw_proactive_id"] is String || info["catpaw_proactive_event"] is String || remote(info)?["kind"] as? String == "proactive_decision"
    }

    /// didReceive: act only on a notification that still belongs to the signed-in account (no quota side effects).
    static func belongsToCurrent(_ info: [AnyHashable: Any], epoch: AccountEpoch) -> Bool {
        if info[accountKey] != nil || info[epochKey] != nil { return epoch.isValid(token(info)) }
        if let account = remote(info)?["account"] as? String { return epoch.currentAccount.map { account.caseInsensitiveCompare($0) == .orderedSame } ?? false }
        // Codex PR90d #3: a proactive payload without an owner (pre-ownership build) never resumes into whoever is signed in.
        return !(isProactive(info) || remote(info) != nil)
    }

    enum Verdict: Equatable { case drop(String), inboxOnly, present(ProactiveLevel) }
    /// willPresent / didReceive. `quota` is the shared on-device ledger: a remote push is counted (and deduped) here.
    static func verdict(_ info: [AnyHashable: Any], epoch: AccountEpoch, now: Date, quota: inout ProactiveQuotaLedger, calendar: Calendar = .current) -> Verdict {
        if info[accountKey] != nil || info[epochKey] != nil {   // local: posted under a token
            guard epoch.isValid(token(info)) else { return .drop("stale_account") }
            let level = ProactiveLevel(server: info[levelKey] as? String)
            // Codex PR90c P2: the stamped level is re-checked against quiet hours at the instant it actually comes up.
            if level >= .notify, ProactiveRules.isQuiet(now, calendar: calendar) { return .inboxOnly }
            return .present(level)
        }
        if let r = remote(info), let account = r["account"] as? String {  // APNs: server has no epoch → compare the account
            guard let cur = epoch.currentAccount, account.caseInsensitiveCompare(cur) == .orderedSame else { return .drop("other_account") }
            guard r["kind"] as? String == "proactive_decision" else { return .present(.interrupt) }  // user-scheduled reminder
            let requested = ProactiveLevel(server: r["decision"] as? String)
            let plan = ProactiveRules.delivery(level: requested, now: now, deliveredToday: quota.count(on: now, calendar: calendar), calendar: calendar)
            guard plan.systemNotification else { return .inboxOnly }
            guard let id = deliveryID(info), quota.recordDelivery(id, at: now, calendar: calendar) else { return .drop("duplicate") }
            return .present(plan.level)
        }
        if isProactive(info) || remote(info) != nil { return .drop("untagged") }  // Codex PR90d #3: no owner → rejected
        return .present(.notify)
    }
}

/// Codex PR90d #1 / PR90e: the persisted proactive data (inbox, reminders, attendees, ledgers, quota, outbox, server ids)
/// has one owner account, stored next to it. One decision per write / account change:
/// - `.keep`  — same account (cold restore, any case), or signed out and already clean;
/// - `.quarantine` — no owner recorded (first run after the upgrade): moved into `ProactiveQuarantine`, released only
///   on evidence or expired (PR90f #1). `.adopt` is no longer produced (kept for source compatibility).
/// - `.wipe`  — anything else (switch, logout, "" → a new account). Adopt and wipe both register the new owner, so the
///   owner can never stay "" while an account writes.
enum ProactiveDataOwner {
    static let key = "catpaw.proactive.owner.v1"
    enum Plan: Equatable { case keep, adopt, wipe, quarantine }
    static func plan(owner: String?, current: String?) -> Plan {
        guard let owner else { return .quarantine }   // PR90f #1: unknown owner → isolated, never claimed or dropped
        guard let current else { return owner.isEmpty ? .keep : .wipe }
        return owner.caseInsensitiveCompare(current) == .orderedSame ? .keep : .wipe
    }
    /// The account a proactive notification belongs to — the same resolution as the receive gate: the local stamp
    /// (`catpaw_account`), else the APNs payload's `catpaw.account`; nil = untagged.
    static func owner(of info: [AnyHashable: Any]) -> String? {
        ProactiveAccountGate.token(info)?.account ?? ((info["catpaw"] as? [String: Any])?["account"] as? String)
    }
    /// Removed on an account change only if it is not the current account's (other account or untagged); the current
    /// account's requests — local or APNs, any epoch — are left alone.
    static func removeOnChange(_ info: [AnyHashable: Any], current: String?) -> Bool {
        guard ProactiveAccountGate.isProactive(info) else { return false }
        guard let current, let a = owner(of: info) else { return true }
        return a.caseInsensitiveCompare(current) != .orderedSame
    }
}

/// Codex PR90f #1: data whose owner is unknown (written by a build that recorded none) is neither wiped nor handed to
/// whoever is signed in. It is moved into an isolated store (not shown, not sent, not synced) and released only on
/// evidence — every stamped queued write-back names the current account, or the cloud confirms one of its server ids
/// under the current account's bearer (`GET suggestions/<id>`, owner-scoped by RLS) — else it expires after `ttl`.
enum ProactiveQuarantine {
    static let key = "catpaw.proactive.quarantine.v1"
    /// p90i P1-b: no longer a deletion bound (kept for the reconcile age log only).
    static let ttl: TimeInterval = 7 * 24 * 3600
    enum Verdict: Equatable { case hold, release, expire }
    static func decide(quarantinedAt: Date, stampedAccounts: [String], current: String?, serverConfirmed: Bool, now: Date) -> Verdict {
        if let current {
            if serverConfirmed { return .release }
            if !stampedAccounts.isEmpty, stampedAccounts.allSatisfy({ $0.caseInsensitiveCompare(current) == .orderedSame }) { return .release }
        }
        return .hold   // p90i P1-b: never expired by age — kept until evidence or the user's own decision
    }
    /// Codex PR90g #1: ownership is proven per record. `stamps[id]`: the accounts stamped on that record's own queued
    /// write-backs (nil = unstamped); `confirmed`: records whose own server id the cloud returned for the current
    /// account. A record is released only on its own evidence; everything else stays quarantined.
    /// p90i (09:01): which queued items a release moves where. A released record's live ops go back to pending, its dead
    /// letters back to the dead letters (flagged, never retried); unreleased records keep both, still apart.
    static func partition<T>(live: [T], dead: [T], released: Set<String>, record: (T) -> String) -> (live: [T], dead: [T], restLive: [T], restDead: [T]) {
        (live.filter { released.contains(record($0)) }, dead.filter { released.contains(record($0)) },
         live.filter { !released.contains(record($0)) }, dead.filter { !released.contains(record($0)) })
    }
    static func releasable(ids: [String], stamps: [String: [String?]], confirmed: Set<String>, current: String?) -> Set<String> {
        guard let current else { return [] }
        return Set(ids.filter { id in
            if confirmed.contains(id) { return true }
            let own = (stamps[id] ?? []).compactMap { $0 }
            // Every write-back of this record names the current account (an unstamped one is no proof either way).
            return !own.isEmpty && own.count == (stamps[id] ?? []).count && own.allSatisfy { $0.caseInsensitiveCompare(current) == .orderedSame }
        })
    }
}

/// p90i (三角 trial S3): every proactive POST names its account. No token → rejected (the account check is never skipped).
enum ProactivePostGate {
    static func admit(_ token: AccountToken?, epoch: AccountEpoch) -> Bool {
        guard let token else { return false }
        return epoch.isValid(token)
    }
}

/// p90i (三角 trial S5): local → server suggestion ids, partitioned by account (keys compared case-insensitively).
/// The pre-p90i global map migrates to the recorded data owner; with no (or a signed-out "") owner it is handed to the
/// quarantine, never to whoever is signed in.
struct ProactiveServerIDMap: Codable, Equatable {
    static let key = "catpaw.proactive.serverIDs.v2", legacyKey = "catpaw.proactive.serverIDs.v1"
    var byAccount: [String: [String: String]] = [:]
    private static func norm(_ a: String) -> String { a.lowercased() }
    func ids(for account: String) -> [String: String] { account.isEmpty ? [:] : byAccount[Self.norm(account)] ?? [:] }
    mutating func set(_ local: String, _ server: String, account: String) { guard !account.isEmpty else { return }; byAccount[Self.norm(account), default: [:]][local] = server }
    mutating func replace(_ ids: [String: String], account: String) { guard !account.isEmpty else { return }; byAccount[Self.norm(account)] = ids.isEmpty ? nil : ids }
    static func migrate(legacy: [String: String], owner: String?) -> (map: ProactiveServerIDMap, quarantine: [String: String]) {
        var m = ProactiveServerIDMap()
        guard let owner, !owner.isEmpty else { return (m, legacy) }
        m.replace(legacy, account: owner); return (m, [:])
    }
}

/// p90i P1-a (user standard 2026-10-17 08:50): app-managed proactive data is bound to its account and managed
/// automatically, without a prompt. When the data owner changes, the old account's inbox, reminder contexts, generations
/// and unsynced write-backs are parked under that account (appended, never overwritten, never dropped); never shown or
/// sent under another account; restored and synced when THAT account signs in again. Only items outside the app
/// (EventKit reminders the app created) are listed for the user's decision (#89's API) and are never touched here.
enum ProactiveParking {
    static let key = "catpaw.proactive.parked.v1"
    static func shouldPark(plan: ProactiveDataOwner.Plan, owner: String?, force: Bool) -> Bool {
        guard !force, plan == .wipe, let owner, !owner.isEmpty else { return false }
        return true
    }
    static let externalKey = "catpaw.proactive.external.v1"
    /// An item outside the app the user decides about (#89's list). Never deleted or edited by #90 on a switch.
    struct ExternalItem: Codable, Equatable, Sendable { var suggestionID: String; var operationID: String; var kind: String }
    /// The EventKit reminders the app created for these cards: a create_reminder that succeeded (nil outcome = older
    /// success record) and still is in the card's taken list, with its operation id marker.
    static func externalItems(inbox: [String: Any], reminderOps: [String: String]) -> [ExternalItem] {
        inbox.keys.sorted().compactMap { id in
            let taken = ((inbox[id] as? [String: Any])?["taken"] as? [[String: Any]]) ?? []
            guard taken.contains(where: { $0["action"] as? String == "create_reminder" && (($0["outcome"] as? String) ?? "succeeded") == "succeeded" }),
                  let op = reminderOps[id] else { return nil }
            return ExternalItem(suggestionID: id, operationID: op, kind: "eventkit_reminder")
        }
    }
    /// account (lower-cased) → parked records, oldest first. Plist-compatible values only.
    struct Lot {
        var slots: [String: [[String: Any]]] = [:]
        var accounts: [String] { Array(slots.keys) }
        /// The first parked record per account (the oldest one waiting for a decision).
        var records: [String: [String: Any]] { slots.compactMapValues(\.first) }
        mutating func park(account: String, record: [String: Any]) { slots[account.lowercased(), default: []].append(record) }
        /// p90i (08:50 standard): the owner signing in again takes its records back, oldest first; the slot is emptied.
        mutating func take(account: String) -> [[String: Any]] { slots.removeValue(forKey: account.lowercased()) ?? [] }
        init(_ raw: [String: Any]? = nil) { slots = (raw ?? [:]).compactMapValues { $0 as? [[String: Any]] } }
        var raw: [String: Any] { slots }
    }
}
