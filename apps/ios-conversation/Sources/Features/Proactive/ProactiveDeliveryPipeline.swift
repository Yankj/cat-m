import Foundation

// Codex PR90c: the one place a proactive system notification is added. ProactiveEngine.intervene (in-app),
// prescheduleNextEvent (out-of-app) and notification resume delegate here, so the account barrier, quiet hours at
// the real fire instant, the shared quota and the late-completion cleanup are one code path (tested with a fake poster).

struct ProactiveNotificationRequest: Sendable, Equatable {
    var id: String; var title: String; var body: String; var category: String
    var info: [String: String]; var level: ProactiveLevel
    /// nil → shown after `ProactiveDeliveryPipeline.postDelay`; else a calendar trigger at this instant.
    var fireAt: Date?
}

/// The system notification centre, narrowed to what the pipeline needs (UNUserNotificationCenter in the app).
@MainActor protocol ProactiveNotificationPoster: AnyObject {
    func requestAuthorization() async -> Bool
    /// Enqueue only (never awaited inside the account barrier); `completion(false)` when the system rejected it.
    func add(_ r: ProactiveNotificationRequest, completion: @escaping @MainActor (Bool) -> Void)
    /// Remove pending and delivered requests with these identifiers.
    func remove(ids: [String])
}

@MainActor final class ProactiveDeliveryPipeline {
    enum Outcome: Equatable { case posted(String), cardOnly(String), refused(String) }
    static let postDelay: TimeInterval = 2

    let epoch: AccountEpoch
    var poster: ProactiveNotificationPoster
    var clock: () -> Date
    var calendar: Calendar
    private let loadQuota: () -> ProactiveQuotaLedger
    private let saveQuota: (ProactiveQuotaLedger) -> Void

    init(epoch: AccountEpoch, poster: ProactiveNotificationPoster, clock: @escaping () -> Date = { .now }, calendar: Calendar = .current,
         loadQuota: @escaping () -> ProactiveQuotaLedger, saveQuota: @escaping (ProactiveQuotaLedger) -> Void) {
        self.epoch = epoch; self.poster = poster; self.clock = clock; self.calendar = calendar; self.loadQuota = loadQuota; self.saveQuota = saveQuota
    }

    /// Codex PR90d #3: every system request id carries the account and epoch it was made under, so cleanup (late
    /// callbacks, removals) can only ever hit that one instance — never another account's request for the same meeting.
    nonisolated static func scoped(_ base: String, _ token: AccountToken) -> String { "\(base)~\(token.account)~\(token.epoch)" }
    /// Removes this token's instance of each base id (plus the legacy unscoped id from older builds).
    func remove(bases: [String], token: AccountToken?) {
        guard !bases.isEmpty else { return }
        poster.remove(ids: bases.flatMap { b in token.map { [Self.scoped(b, $0), b] } ?? [b] })
    }

    /// Quota with fired reservations settled into deliveries ("shown but not tapped").
    func quota() -> ProactiveQuotaLedger { var q = loadQuota(); if q.settle(now: clock()) { saveQuota(q) }; return q }

    private func gate(_ level: ProactiveLevel, at instant: Date, identity: String, q: ProactiveQuotaLedger) -> ProactiveRules.Delivery {
        let own = q.entries[identity]?.day == ProactiveQuotaLedger.day(instant, calendar: calendar) ? 1 : 0  // never count its own slot
        return ProactiveRules.delivery(level: level, now: instant, deliveredToday: q.count(on: instant, calendar: calendar) - own, calendar: calendar)
    }
    private func stamped(_ info: [String: String], _ token: AccountToken, id: String, level: ProactiveLevel) -> [String: String] {
        var i = info; i[ProactiveAccountGate.accountKey] = token.account; i[ProactiveAccountGate.epochKey] = String(token.epoch)
        i[ProactiveAccountGate.eventKey] = id; i[ProactiveAccountGate.levelKey] = level.name; return i
    }
    private func reason(_ plan: ProactiveRules.Delivery, at instant: Date) -> String {
        ProactiveRules.isQuiet(instant, calendar: calendar) ? "quiet_hours" : plan.level == .silent ? "silent" : "daily_cap"
    }

    /// In-app delivery (intervene). `supersedes`: pending request ids (the meeting's pre-scheduled one) replaced by this post.
    func deliverNow(id: String, requestID: String, title: String, body: String, category: String, info: [String: String],
                    requested: ProactiveLevel, token: AccountToken, supersedes: [String] = []) async -> Outcome {
        guard epoch.isValid(token) else { return .refused("stale_account") }
        var q = quota()
        if q.entries[id]?.state == .delivered { return .cardOnly("already_delivered") }
        var plan = gate(requested, at: clock().addingTimeInterval(Self.postDelay), identity: id, q: q)
        guard plan.systemNotification else { return .cardOnly(reason(plan, at: clock().addingTimeInterval(Self.postDelay))) }
        guard await poster.requestAuthorization() else { return .cardOnly("not_authorized") }
        // After the await: same account and sign-in, and quiet hours / cap re-checked at the instant it will ring.
        guard epoch.isValid(token) else { return .refused("stale_account") }
        let fire = clock().addingTimeInterval(Self.postDelay)
        q = quota()
        if q.entries[id]?.state == .delivered { return .cardOnly("already_delivered") }
        plan = gate(requested, at: fire, identity: id, q: q)
        guard plan.systemNotification else { return .cardOnly(reason(plan, at: fire)) }
        let rid = Self.scoped(requestID, token)
        let req = ProactiveNotificationRequest(id: rid, title: title, body: body, category: category,
                                               info: stamped(info, token, id: id, level: plan.level), level: plan.level, fireAt: nil)
        let done: Outcome? = epoch.commit(token) { () -> Outcome in
            var q = quota(); guard q.recordDelivery(id, at: fire, calendar: calendar) else { return .cardOnly("already_delivered") }
            saveQuota(q)
            remove(bases: supersedes, token: token)
            poster.add(req) { [weak self] ok in self?.lateCompletion(ok: ok, token: token, requestID: rid, identity: id, releaseReservation: false) }
            return .posted(rid)
        }
        return done ?? .refused("stale_account")
    }

    /// Out-of-app delivery at `fire`. Holds one quota slot per identity; a re-scan never cancels a slot it already holds.
    func preschedule(identity: String, requestID: String, title: String, body: String, category: String, info: [String: String],
                     fire: Date, level: ProactiveLevel, token: AccountToken) async -> Outcome {
        guard epoch.isValid(token) else { return .refused("stale_account") }
        var q = quota()
        if q.entries[identity]?.state == .delivered { return .cardOnly("already_delivered") }
        let plan = gate(level, at: fire, identity: identity, q: q)
        guard plan.systemNotification else {
            if ProactiveRules.isQuiet(fire, calendar: calendar) || plan.level == .silent {  // never ring at that instant
                q.release(identity, now: clock()); saveQuota(q); remove(bases: [requestID], token: token)
            }
            return .cardOnly(reason(plan, at: fire))
        }
        let rid = Self.scoped(requestID, token)
        let req = ProactiveNotificationRequest(id: rid, title: title, body: body, category: category,
                                               info: stamped(info, token, id: identity, level: plan.level), level: plan.level, fireAt: fire)
        let done: Outcome? = epoch.commit(token) { () -> Outcome in
            var q = quota(); guard q.reserve(identity, fire: fire, owner: rid, calendar: calendar) else { return .cardOnly("daily_cap") }
            saveQuota(q)
            poster.add(req) { [weak self] ok in self?.lateCompletion(ok: ok, token: token, requestID: rid, identity: identity, releaseReservation: true) }
            return .posted(rid)
        }
        return done ?? .refused("stale_account")
    }

    /// The system finished adding after the barrier: if the account changed meanwhile (or the add failed), take it back.
    private func lateCompletion(ok: Bool, token: AccountToken, requestID: String, identity: String, releaseReservation: Bool) {
        guard !ok || !epoch.isValid(token) else { return }
        poster.remove(ids: [requestID])
        if releaseReservation { var q = loadQuota(); q.release(identity, now: clock(), owner: requestID); saveQuota(q) }
    }

    /// Codex PR90d #3: a user snooze is a system notification like any other — stamped, quota/quiet-gated at its fire
    /// instant, scoped id, late-completion cleanup. Request id base: `<id>-snooze`.
    func snooze(id: String, title: String, body: String, category: String, info: [String: String], fire: Date, token: AccountToken) async -> Outcome {
        await preschedule(identity: id + "-snooze", requestID: id + "-snooze", title: title, body: body, category: category, info: info,
                          fire: fire, level: .notify, token: token)
    }

    /// Notification tap / action: the token it was posted under, only if still the signed-in account and epoch.
    func resumeToken(_ info: [AnyHashable: Any]) -> AccountToken? {
        guard let t = ProactiveAccountGate.token(info), epoch.isValid(t) else { return nil }
        return t
    }
}
