import Foundation

// Codex PR90 review regressions, counted as real effects (ledger entries / posts), not rule return values.
nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ msg: String, line: Int = #line) { if !ok { failures += 1; print("FAIL L\(line): \(msg)") } }
let shanghai: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }()
func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

func pr90_3_prescheduleSharesDecisionAndQuota() {
    // 14:00 CST fire, meeting 15 min later, lead 10 → notify (same as in-app).
    let fire = at("2026-10-15T06:00:00Z")
    check(ProactiveRules.prescheduleLevel(minutesUntilAtFire: 15, leadMinutes: 10, travelMinutes: nil, fire: fire, deliveredOnFireDay: 0, calendar: shanghai) == .notify, "preschedule notify")
    // Night fire → nothing scheduled; too early → nothing.
    check(ProactiveRules.prescheduleLevel(minutesUntilAtFire: 15, leadMinutes: 10, travelMinutes: nil, fire: at("2026-10-15T15:30:00Z"), deliveredOnFireDay: 0, calendar: shanghai) == nil, "quiet at fire time")
    check(ProactiveRules.prescheduleLevel(minutesUntilAtFire: 90, leadMinutes: 10, travelMinutes: nil, fire: fire, deliveredOnFireDay: 0, calendar: shanghai) == nil, "too early is silent")
    // Quota: reservation persists; shown-but-not-tapped counts; in-app delivery of the same id converts, never double.
    var q = ProactiveQuotaLedger(), posts = 0
    for i in 0..<ProactiveRules.dailyNotifyCap { if q.reserve("pre-\(i)", fire: fire, calendar: shanghai) { posts += 1 } }
    check(!q.reserve("pre-extra", fire: fire, calendar: shanghai), "cap reached by reservations")
    check(q.reserve("pre-0", fire: fire, calendar: shanghai), "same identity is idempotent")
    if q.recordDelivery("pre-0", at: fire, calendar: shanghai) { posts += 0 }  // fired: converted, not added
    check(q.count(on: fire, calendar: shanghai) == ProactiveRules.dailyNotifyCap, "conversion does not double count")
    check(!q.recordDelivery("pre-0", at: fire, calendar: shanghai), "second path for one identity must not post")
    check(posts == ProactiveRules.dailyNotifyCap, "real posts == cap (\(posts))")
    // Released (superseded, unfired) reservation frees the slot; a fired one never does.
    q.release("pre-1", now: at("2026-10-15T05:00:00Z")); check(q.count(on: fire, calendar: shanghai) == ProactiveRules.dailyNotifyCap - 1, "release unfired")
    q.release("pre-2", now: at("2026-10-15T07:00:00Z")); check(q.count(on: fire, calendar: shanghai) == ProactiveRules.dailyNotifyCap - 1, "fired = shown-but-not-tapped stays counted")
    // Persisted round trip.
    let back = try! JSONDecoder().decode(ProactiveQuotaLedger.self, from: JSONEncoder().encode(q)); check(back == q, "codable")
}

func pr90_accountEpoch() {
    let epoch = AccountEpoch(account: "USER-A"); var q = ProactiveQuotaLedger(); let noon = at("2026-10-15T04:00:00Z")
    // Local: token captured before the await; sign-out while suspended → the notification is dropped at presentation.
    let t = epoch.capture()!; var info: [AnyHashable: Any] = ["catpaw_proactive_id": "evt-1"]
    ProactiveAccountGate.stamp(&info, t, deliveryID: "evt-1", level: .notify)
    check(ProactiveAccountGate.verdict(info, epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .present(.notify), "valid token presents")
    epoch.signOut(); check(ProactiveAccountGate.verdict(info, epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .drop("stale_account"), "signed out drops")
    epoch.activate(account: "USER-B"); check(ProactiveAccountGate.verdict(info, epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .drop("stale_account"), "switched drops")
    check(epoch.commit(t) { true } == nil, "write under A's token refused after switch")
    // Remote: account compared, then the same device gate; one delivery id dedupes APNs vs local.
    let push: (String, String) -> [AnyHashable: Any] = { acct, d in ["catpaw": ["account": acct, "kind": "proactive_decision", "decision": d, "event_id": "E1"]] }
    check(ProactiveAccountGate.verdict(push("USER-A", "notify"), epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .drop("other_account"), "A's push on B")
    check(ProactiveAccountGate.verdict(push("USER-B", "card"), epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .inboxOnly, "card never banners")
    check(ProactiveAccountGate.verdict(push("USER-B", "interrupt"), epoch: epoch, now: at("2026-10-15T15:30:00Z"), quota: &q, calendar: shanghai) == .inboxOnly, "quiet hours downgrade the push")
    check(ProactiveAccountGate.verdict(push("USER-B", "notify"), epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .present(.notify), "push presents once")
    check(ProactiveAccountGate.verdict(push("USER-B", "notify"), epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .drop("duplicate"), "same event_id twice")
    check(q.count(on: noon, calendar: shanghai) == 1, "real deliveries counted: 1")
    check(ProactiveAccountGate.verdict(push("user-b", "card"), epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .inboxOnly, "server lower-case uuid == client uuidString")
    var local: [AnyHashable: Any] = [:]; ProactiveAccountGate.stamp(&local, epoch.capture()!, deliveryID: "E1", level: .notify)
    var q2 = ProactiveQuotaLedger(); q2.recordDelivery("evt-9", at: noon, calendar: shanghai); q2.alias("E9", to: "evt-9")
    check(ProactiveAccountGate.verdict(["catpaw": ["account": "USER-B", "kind": "proactive_decision", "decision": "notify", "event_id": "E9"]], epoch: epoch, now: noon, quota: &q2, calendar: shanghai) == .drop("duplicate"), "APNs after local post of the same event dedupes")
    check(!ProactiveAccountGate.belongsToCurrent(info, epoch: epoch) && ProactiveAccountGate.belongsToCurrent(local, epoch: epoch), "didReceive ownership")
    check(ProactiveAccountGate.deliveryID(local) == "E1" && ProactiveAccountGate.deliveryID(push("USER-B", "notify")) == "E1", "shared delivery id")
}

func pr90_4_serverActionStates() {
    // Cloud says the SMS was sent (another device / before restart); local has no record → never offered or re-run.
    let local: [String: ProactiveActionState] = ["create_reminder": .succeeded]
    let merged = ProactiveActionStates.merge(local: local, server: ["notify_attendees": "done"])
    check(merged["notify_attendees"] == .succeeded && merged["create_reminder"] == .succeeded, "server success merged")
    check(!ProactiveActionStates.shouldExecute("notify_attendees", merged), "persisted success blocks re-execution")
    check(ProactiveActionStates.shouldExecute("snooze", merged), "non-effects always run")
    check(ProactiveActionStates.remaining(["create_reminder", "notify_attendees", "snooze", "dismiss"], merged).isEmpty, "card has nothing left")
    // A local cancel never overrides a cloud success; an unknown server value is ignored.
    check(ProactiveActionStates.merge(local: ["notify_attendees": .cancelled], server: ["notify_attendees": "done", "x": "weird"])["notify_attendees"] == .succeeded, "cloud success wins")
    struct Wire: Decodable { let action_states: [String: String]? }
    let w = try! JSONDecoder().decode(Wire.self, from: Data(#"{"action_states":{"notify_attendees":"done"}}"#.utf8))
    check(w.action_states?["notify_attendees"] == "done", "wire shape")
}

final class MemKV: CatpawKeyValueStore { var d: [String: Data] = [:]
    func data(forKey k: String) -> Data? { d[k] }
    func set(_ v: Any?, forKey k: String) { d[k] = v as? Data } }
struct SyncOp: Codable, Sendable, Equatable { var local: String; var action: String }

@MainActor func pr90_5_persistentQueue() async {
    let kv = MemKV(); var t = at("2026-10-15T04:00:00Z")
    var q = CatpawPersistentQueue<SyncOp>(name: "t", store: kv, maxAttempts: 3, baseDelay: 30)
    check(q.enqueue(SyncOp(local: "s1", action: "create_reminder"), key: "op-1", account: "A", now: t), "enqueue")
    check(!q.enqueue(SyncOp(local: "s1", action: "create_reminder"), key: "op-1", account: "A", now: t), "same key dedupes")
    _ = q.enqueue(SyncOp(local: "s2", action: "dismiss"), key: "op-2", account: "A", now: t)
    var sends: [String] = []
    // Offline: both fail → retried with backoff, nothing lost.
    var r = await q.drain(now: t, account: "A") { op in sends.append(op.local); return .retry }
    check(r.retried == 2 && q.items.count == 2, "failures kept")
    // Restart: a new instance on the same store sees the pending ops.
    q = CatpawPersistentQueue<SyncOp>(name: "t", store: kv, maxAttempts: 3, baseDelay: 30)
    check(q.items.count == 2, "survives restart")
    r = await q.drain(now: t.addingTimeInterval(10), account: "A") { _ in sends.append("early"); return .done }
    check(r.sent == 0 && !sends.contains("early"), "backoff respected")
    t = t.addingTimeInterval(120)
    r = await q.drain(now: t, account: "B") { _ in sends.append("wrong-account"); return .done }
    check(!sends.contains("wrong-account"), "never sent under another account")
    r = await q.drain(now: t, account: "A") { op in op.local == "s1" ? .done : .retry }
    check(r.sent == 1 && q.items.map(\.key) == ["op-2"], "success removed exactly once")
    t = t.addingTimeInterval(7200); _ = await q.drain(now: t, account: "A") { _ in .retry }
    check(q.items.isEmpty && q.deadLetters.map(\.key) == ["op-2"], "max attempts → dead letter")
    _ = q.enqueue(SyncOp(local: "s3", action: "x"), key: "op-3", account: "A", now: t); q.purge(account: "A")
    check(q.items.isEmpty, "purge on sign-out")
}

func pr90_6_undoIdentity() {
    var g = ProactiveActionGenerations()
    let first = ProactiveRules.operationID(suggestion: "evt-1", action: "snooze", generation: g["evt-1"])
    check(first == "op-evt-1-snooze", "generation 0 keeps the legacy id (in-flight ops still dedupe)")
    let undo0 = g.undo("evt-1")
    check(undo0 == "undo-evt-1-g0", "undo identity per generation")
    let after = ProactiveRules.operationID(suggestion: "evt-1", action: "snooze", generation: g["evt-1"])
    check(after != first && after == "op-evt-1-snooze-g1", "fresh identity after undo")
    check(g.undo("evt-1") == "undo-evt-1-g1" && g["evt-1"] == 2 && g["evt-2"] == 0, "per suggestion")
    let back = try! JSONDecoder().decode(ProactiveActionGenerations.self, from: JSONEncoder().encode(g)); check(back == g, "persisted")
}

func pr90_p2() {
    // Quiet hours are checked at the real delivery instant, not when the (slow) evaluation started.
    let started = at("2026-10-15T13:59:00Z")  // 21:59 CST
    let deliver = ProactiveRules.deliveryInstant(evaluatedAt: started, startedWall: Date(timeIntervalSince1970: 1000), wall: Date(timeIntervalSince1970: 1000 + 90))
    check(deliver == started.addingTimeInterval(90), "delivery instant = evaluation time + elapsed")
    check(ProactiveRules.delivery(level: .notify, now: deliver, deliveredToday: 0, calendar: shanghai).level == .card, "22:00:30 delivery is in quiet hours")
    // Cross-time-zone daily quota: a slot keeps the local day it was delivered on; travelling never re-opens the day.
    var honolulu = Calendar(identifier: .gregorian); honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
    var q = ProactiveQuotaLedger(); let t = at("2026-10-15T04:00:00Z")  // 12:00 CST Oct 15
    for i in 0..<ProactiveRules.dailyNotifyCap { q.recordDelivery("d\(i)", at: t, calendar: shanghai) }
    // Fly to Honolulu: 2026-10-15T20:00Z = 10:00 HST Oct 15 → same local date, cap still reached.
    check(q.count(on: at("2026-10-15T20:00:00Z"), calendar: honolulu) == ProactiveRules.dailyNotifyCap, "same local date after travel stays capped")
    check(q.count(on: at("2026-10-16T20:00:00Z"), calendar: honolulu) == 0, "next local day is fresh")
    // Real sends: offline matrix counts posts recorded in the ledger (the only path that posts), not verdicts.
    var posts = ProactiveQuotaLedger(); var n = 0
    for (i, (level, when)) in [(ProactiveLevel.notify, t), (.interrupt, at("2026-10-15T15:30:00Z")), (.card, t), (.silent, t), (.notify, t)].enumerated() {
        let plan = ProactiveRules.delivery(level: level, now: when, deliveredToday: posts.count(on: when, calendar: shanghai), calendar: shanghai)
        if plan.systemNotification, posts.recordDelivery("m\(i % 4)", at: when, calendar: shanghai) { n += 1 }
    }
    check(n == 1, "notify posts, night interrupt/card/silent don't, same identity m0 again doesn't (\(n))")
}

func nobug_gateAndTrigger() {
    // Learned feedback gates the offline (local rules) decision too, keyed by the local trigger.
    var seen: (String, Double, String)?
    let down = ProactiveRules.applyFeedbackGate(.notify) { d, c, t in seen = (d, c, t); return "card" }
    check(down == .card && seen?.0 == "notify" && seen?.2 == ProactiveRules.localTrigger, "gate downgrades local notify → card")
    check(ProactiveRules.applyFeedbackGate(.notify) { _, _, _ in "interrupt" } == .notify, "gate can never raise a level")
    check(ProactiveRules.applyFeedbackGate(.silent) { _, _, _ in "notify" } == .silent, "silent stays silent")
    check(ProactiveRules.applyFeedbackGate(.notify, gate: nil) == .notify, "no gate installed → unchanged")
}

// MARK: Codex PR90c — the delivery pipeline ProactiveEngine.intervene / prescheduleNextEvent / resume delegate to.
// FakePoster stands in for UNUserNotificationCenter only; adds/removes are the real system calls the engine makes.
@MainActor final class FakePoster: ProactiveNotificationPoster {
    var adds: [ProactiveNotificationRequest] = [], removed: [String] = [], authorized = true
    var duringAuthorization: (() -> Void)?; var completeLater = false; var pendingCompletions: [(Bool) -> Void] = []
    func requestAuthorization() async -> Bool { duringAuthorization?(); return authorized }
    func add(_ r: ProactiveNotificationRequest, completion: @escaping @MainActor (Bool) -> Void) {
        adds.append(r); if completeLater { pendingCompletions.append(completion) } else { completion(true) }
    }
    func remove(ids: [String]) { removed += ids }
}
@MainActor func makePipeline(_ epoch: AccountEpoch, _ poster: FakePoster, clock: @escaping () -> Date) -> (ProactiveDeliveryPipeline, () -> ProactiveQuotaLedger) {
    var q = ProactiveQuotaLedger()
    let p = ProactiveDeliveryPipeline(epoch: epoch, poster: poster, clock: clock, calendar: shanghai, loadQuota: { q }, saveQuota: { q = $0 })
    return (p, { q })
}
@MainActor func pr90c_pipeline() async {
    let noon = at("2026-10-15T04:00:00Z")
    // 1. Sign-out while awaiting notification authorization → nothing is added.
    do {
        let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, _) = makePipeline(e, poster, clock: { noon })
        poster.duringAuthorization = { e.signOut() }
        let out = await p.deliverNow(id: "evt-1", requestID: "evt-1", title: "t", body: "b", category: "c", info: [:], requested: .notify, token: e.capture()!)
        check(out == .refused("stale_account") && poster.adds.isEmpty, "token re-validated after the authorization await (\(out))")
    }
    // 2. Quiet hours re-checked after the await and at the real fire instant (+2 s): 21:59:59 decision, 22:00:01 fire.
    do {
        var t = at("2026-10-15T13:59:59Z"); let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, _) = makePipeline(e, poster, clock: { t })
        let out = await p.deliverNow(id: "evt-2", requestID: "evt-2", title: "t", body: "b", category: "c", info: [:], requested: .notify, token: e.capture()!)
        check(out == .cardOnly("quiet_hours") && poster.adds.isEmpty, "fire instant crosses 22:00 → no ring (\(out))")
        t = noon; _ = t
    }
    // 3. Late completion after sign-out → the request is removed again.
    do {
        let e = AccountEpoch(account: "A"), poster = FakePoster(); poster.completeLater = true; let (p, _) = makePipeline(e, poster, clock: { noon })
        let out = await p.deliverNow(id: "evt-3", requestID: "evt-3", title: "t", body: "b", category: "c", info: [:], requested: .notify, token: e.capture()!)
        check(out == .posted("evt-3") && poster.adds.count == 1, "posted")
        check(poster.adds.first?.info[ProactiveAccountGate.accountKey] == "A" && poster.adds.first?.info[ProactiveAccountGate.epochKey] != nil, "payload carries account + epoch")
        e.signOut(); poster.pendingCompletions.forEach { $0(true) }
        check(poster.removed.contains("evt-3"), "late completion after commit → removed")
    }
    // 4. A fired pre-scheduled reservation is delivered: the instant path must not push again.
    do {
        var t = at("2026-10-15T03:00:00Z"); let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, q) = makePipeline(e, poster, clock: { t })
        let pre = await p.preschedule(identity: "evt-4", requestID: "pre-E4", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T03:30:00Z"), level: .notify, token: e.capture()!)
        check(pre == .posted("pre-E4"), "prescheduled (\(pre))")
        t = at("2026-10-15T03:31:00Z")  // fired; user never tapped
        let now = await p.deliverNow(id: "evt-4", requestID: "evt-4", title: "t", body: "b", category: "c", info: [:], requested: .notify, token: e.capture()!)
        check(now == .cardOnly("already_delivered") && poster.adds.count == 1, "no second ring for a shown-not-tapped reservation (\(now))")
        check(q().entries["evt-4"]?.state == .delivered && q().count(on: t, calendar: shanghai) == 1, "reservation settled as delivered, counted once")
    }
    // 5. Unfired reservation + in-app delivery → converted, pending request removed, counted once.
    do {
        let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, q) = makePipeline(e, poster, clock: { noon })
        _ = await p.preschedule(identity: "evt-5", requestID: "pre-E5", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T05:00:00Z"), level: .notify, token: e.capture()!)
        let out = await p.deliverNow(id: "evt-5", requestID: "evt-5", title: "t", body: "b", category: "c", info: [:], requested: .notify, token: e.capture()!, supersedes: ["pre-E5"])
        check(out == .posted("evt-5") && poster.removed.contains("pre-E5") && q().count(on: noon, calendar: shanghai) == 1, "in-app supersedes the unfired one")
    }
    // 6. Full quota: re-scanning never cancels a pre-scheduled notification that already holds a slot.
    do {
        let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, q) = makePipeline(e, poster, clock: { noon })
        let fire = at("2026-10-15T06:00:00Z")
        for i in 0..<ProactiveRules.dailyNotifyCap { _ = await p.preschedule(identity: "evt-6-\(i)", requestID: "pre-6-\(i)", title: "t", body: "b", category: "c", info: [:], fire: fire, level: .notify, token: e.capture()!) }
        let again = await p.preschedule(identity: "evt-6-0", requestID: "pre-6-0", title: "t", body: "b", category: "c", info: [:], fire: fire, level: .notify, token: e.capture()!)
        check(again != .cardOnly("daily_cap") && !poster.removed.contains("pre-6-0") && q().count(on: fire, calendar: shanghai) == ProactiveRules.dailyNotifyCap, "own slot kept (\(again))")
        let extra = await p.preschedule(identity: "evt-6-x", requestID: "pre-6-x", title: "t", body: "b", category: "c", info: [:], fire: fire, level: .notify, token: e.capture()!)
        check(extra == .cardOnly("daily_cap"), "a new one is refused at the cap")
    }
    // 7. Preschedule: signed out before commit → nothing added; late completion → removed + slot released.
    do {
        let e = AccountEpoch(account: "A"), poster = FakePoster(); poster.completeLater = true; let (p, q) = makePipeline(e, poster, clock: { noon })
        let tok = e.capture()!; e.signOut()
        let out = await p.preschedule(identity: "evt-7", requestID: "pre-7", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T06:00:00Z"), level: .notify, token: tok)
        check(out == .refused("stale_account") && poster.adds.isEmpty && q().entries["evt-7"] == nil, "stale token: no add, no slot")
        e.activate(account: "A")
        _ = await p.preschedule(identity: "evt-8", requestID: "pre-8", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T06:00:00Z"), level: .notify, token: e.capture()!)
        e.signOut(); poster.pendingCompletions.forEach { $0(true) }
        check(poster.removed.contains("pre-8") && q().entries["evt-8"] == nil, "late completion → removed, slot released")
    }
    // 8. Resume (tap) only for the account/epoch that scheduled it.
    do {
        let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, _) = makePipeline(e, poster, clock: { noon })
        _ = await p.preschedule(identity: "evt-9", requestID: "pre-9", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T06:00:00Z"), level: .notify, token: e.capture()!)
        let info: [AnyHashable: Any] = poster.adds[0].info.reduce(into: [:]) { $0[$1.key] = $1.value }
        check(p.resumeToken(info) != nil, "same account resumes")
        e.activate(account: "B"); check(p.resumeToken(info) == nil, "other account: dropped, nothing written")
    }
}
func pr90c_confidences() {
    let c = ProactiveRules.localConfidence
    check(c("meeting_upcoming", 8, nil) == 0.7 && c("meeting_upcoming", 30, nil) == 0.6, "meeting")
    check(c("travel_conflict", nil, nil) == 0.85 && c("meeting_conflict", nil, nil) == 0.75 && c("traffic", nil, nil) == 0.65 && c("whatever", nil, nil) == 0.6, "triggers")
    check(c("flight_status", nil, "cancelled") == 0.9 && c("flight_status", nil, "delay_60") == 0.8 && c("flight_status", nil, "delay_30") == 0.75 && c("flight_status", nil, "gate") == 0.7, "flight")
    // Pre-scheduling: cloud silent → nothing; feedback gate applied with the trigger's confidence; no fixed lead+5.
    var seen: Double?
    check(ProactiveRules.prescheduleDecision(cloud: .silent, leadMinutes: 10, gate: nil) == nil, "cloud silent → no preschedule")
    check(ProactiveRules.prescheduleDecision(cloud: nil, leadMinutes: 10, gate: { _, conf, _ in seen = conf; return "card" }) == nil && seen == 0.7, "feedback gate → card → nothing scheduled")
    check(ProactiveRules.prescheduleDecision(cloud: .interrupt, leadMinutes: 25, gate: nil) == .interrupt, "cloud level kept")
    check(ProactiveRules.prescheduleFire(start: at("2026-10-15T06:00:00Z"), leadMinutes: 25) == at("2026-10-15T05:35:00Z"), "fire = start − lead")
}

func pr90c_undoContract() {
    struct V: Decodable { let name: String; let offered: [String]; let taken: [String]; let status: String; let removed: String?; let after: [String]; let after_status: String }
    struct F: Decodable { let vectors: [V] }
    let url = URL(fileURLWithPath: "../../services/edge/test/fixtures/proactive/undo-vectors.json")
    guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(F.self, from: data) else { check(false, "undo vectors readable"); return }
    for v in f.vectors {
        let plan = ProactiveUndo.plan(offered: v.offered, taken: v.taken, status: v.status)
        check(plan.removed == v.removed && plan.after == v.after && plan.status == v.after_status, "undo \(v.name): \(plan)")
    }
}

@MainActor func pr90c_queueOrdering() async {
    let kv = MemKV(); let t = at("2026-10-15T04:00:00Z")
    let q = CatpawPersistentQueue<SyncOp>(name: "o", store: kv, maxAttempts: 5, baseDelay: 30)
    q.enqueue(SyncOp(local: "s1", action: "snooze"), key: "op-snooze", account: "A", group: "s1", now: t)
    q.enqueue(SyncOp(local: "s2", action: "create_reminder"), key: "op-other", account: "A", group: "s2", now: t)
    var server: [String] = []
    // snooze fails → the later dismiss of the SAME suggestion must wait; other suggestions still flow.
    _ = await q.drain(now: t, account: "A") { op in op.action == "snooze" ? .retry : { server.append(op.local + ":" + op.action); return .done }() }
    q.enqueue(SyncOp(local: "s1", action: "dismiss"), key: "op-dismiss", account: "A", group: "s1", now: t)
    _ = await q.drain(now: t.addingTimeInterval(1), account: "A") { op in server.append(op.local + ":" + op.action); return .done }
    check(server == ["s2:create_reminder"], "dismiss never overtakes the failed snooze (\(server))")
    _ = await q.drain(now: t.addingTimeInterval(120), account: "A") { op in server.append(op.local + ":" + op.action); return .done }
    check(server == ["s2:create_reminder", "s1:snooze", "s1:dismiss"], "per-suggestion FIFO: final state = dismissed (\(server))")
    // Supersede: a dismiss queued behind an unsent snooze replaces it (the snooze would only be undone by it).
    q.enqueue(SyncOp(local: "s3", action: "snooze"), key: "op-s3-snooze", account: "A", group: "s3", now: t)
    q.enqueue(SyncOp(local: "s3", action: "dismiss"), key: "op-s3-dismiss", account: "A", group: "s3", supersedes: { $0.action == "snooze" }, now: t)
    check(q.items.map(\.key) == ["op-s3-dismiss"], "superseded snooze dropped")
    // Restart keeps groups.
    let q2 = CatpawPersistentQueue<SyncOp>(name: "o", store: kv); check(q2.items.first?.group == "s3", "group persisted")
}
func pr90c_cardMerge() {
    // An existing pending card receives the cloud's later success states (SMS sent elsewhere) and stops offering them.
    let merged = ProactiveActionStates.mergeServer(existing: ["create_reminder": "done"], incoming: ["notify_attendees": "done"])
    check(merged == ["create_reminder": "done", "notify_attendees": "done"], "success states union (\(merged))")
    check(ProactiveActionStates.mergeServer(existing: ["notify_attendees": "done"], incoming: [:]) == ["notify_attendees": "done"], "a success is never lost by a stale update")
}

func pr90c_presentQuiet() {
    // A local notification stamped "notify" that comes up after 22:00 (late trigger) is shown in the inbox only.
    let epoch = AccountEpoch(account: "A"); var q = ProactiveQuotaLedger(); var info: [AnyHashable: Any] = [:]
    ProactiveAccountGate.stamp(&info, epoch.capture()!, deliveryID: "evt-q", level: .notify)
    check(ProactiveAccountGate.verdict(info, epoch: epoch, now: at("2026-10-15T14:00:01Z"), quota: &q, calendar: shanghai) == .inboxOnly, "presentation re-checks quiet hours")
    check(ProactiveAccountGate.verdict(info, epoch: epoch, now: at("2026-10-15T04:00:00Z"), quota: &q, calendar: shanghai) == .present(.notify), "daytime presents")
}

@main enum ProactivePR90Runner {
    static func main() async {
        pr90_3_prescheduleSharesDecisionAndQuota()
        pr90_accountEpoch()
        pr90_4_serverActionStates()
        await pr90_5_persistentQueue()
        pr90_6_undoIdentity()
        pr90_p2()
        nobug_gateAndTrigger()
        await pr90c_pipeline()
        pr90c_confidences()
        pr90c_undoContract()
        await pr90c_queueOrdering()
        pr90c_cardMerge()
        pr90c_presentQuiet()
        print(failures == 0 ? "PR90 proactive: all passed" : "PR90 proactive: \(failures) failed"); exit(failures == 0 ? 0 : 1)
    }
}
