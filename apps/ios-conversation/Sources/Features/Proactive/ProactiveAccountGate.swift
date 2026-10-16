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

/// Codex PR90d #1: the persisted proactive data (inbox, reminders, attendees, ledgers, quota, outbox, server ids) has one
/// owner account, stored next to it. Cleanup is by owner, synchronously, at the first write or account change that sees a
/// different account — so a same-account restore keeps everything, and data the new account already wrote survives.
enum ProactiveDataOwner {
    static let key = "catpaw.proactive.owner.v1"
    /// `owner`: nil = never recorded (data from before ownership, owner unknown → fail closed); "" = clean, signed out.
    static func mustWipe(owner: String?, current: String?) -> Bool {
        guard let owner else { return true }
        if owner.isEmpty { return false }
        guard let current else { return true }
        return owner.caseInsensitiveCompare(current) != .orderedSame
    }
    /// A pending / delivered proactive notification is removed on an account change only if it is not the current
    /// account's (other account or untagged); the current account's requests (any epoch) are left alone.
    static func removeOnChange(_ info: [AnyHashable: Any], current: String?) -> Bool {
        guard ProactiveAccountGate.isProactive(info) else { return false }
        guard let current, let a = ProactiveAccountGate.token(info)?.account else { return true }
        return a.caseInsensitiveCompare(current) != .orderedSame
    }
}
