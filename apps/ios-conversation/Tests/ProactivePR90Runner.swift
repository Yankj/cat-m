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
        let tok3 = poster.adds.first.map { _ in e.capture()! }!
        check(out == .posted(ProactiveDeliveryPipeline.scoped("evt-3", tok3)) && poster.adds.count == 1, "posted (scoped id)")
        check(poster.adds.first?.info[ProactiveAccountGate.accountKey] == "A" && poster.adds.first?.info[ProactiveAccountGate.epochKey] != nil, "payload carries account + epoch")
        e.signOut(); poster.pendingCompletions.forEach { $0(true) }
        check(poster.removed.contains(ProactiveDeliveryPipeline.scoped("evt-3", tok3)), "late completion after commit → removed")
    }
    // 4. A fired pre-scheduled reservation is delivered: the instant path must not push again.
    do {
        var t = at("2026-10-15T03:00:00Z"); let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, q) = makePipeline(e, poster, clock: { t })
        let pre = await p.preschedule(identity: "evt-4", requestID: "pre-E4", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T03:30:00Z"), level: .notify, token: e.capture()!)
        check(pre == .posted(ProactiveDeliveryPipeline.scoped("pre-E4", e.capture()!)), "prescheduled (\(pre))")
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
        check(out == .posted(ProactiveDeliveryPipeline.scoped("evt-5", e.capture()!)) && poster.removed.contains(ProactiveDeliveryPipeline.scoped("pre-E5", e.capture()!)) && q().count(on: noon, calendar: shanghai) == 1, "in-app supersedes the unfired one")
    }
    // 6. Full quota: re-scanning never cancels a pre-scheduled notification that already holds a slot.
    do {
        let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, q) = makePipeline(e, poster, clock: { noon })
        let fire = at("2026-10-15T06:00:00Z")
        for i in 0..<ProactiveRules.dailyNotifyCap { _ = await p.preschedule(identity: "evt-6-\(i)", requestID: "pre-6-\(i)", title: "t", body: "b", category: "c", info: [:], fire: fire, level: .notify, token: e.capture()!) }
        let again = await p.preschedule(identity: "evt-6-0", requestID: "pre-6-0", title: "t", body: "b", category: "c", info: [:], fire: fire, level: .notify, token: e.capture()!)
        check(again != .cardOnly("daily_cap") && !poster.removed.contains(ProactiveDeliveryPipeline.scoped("pre-6-0", e.capture()!)) && q().count(on: fire, calendar: shanghai) == ProactiveRules.dailyNotifyCap, "own slot kept (\(again))")
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
        let tok8 = e.capture()!
        _ = await p.preschedule(identity: "evt-8", requestID: "pre-8", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T06:00:00Z"), level: .notify, token: tok8)
        e.signOut(); poster.pendingCompletions.forEach { $0(true) }
        check(poster.removed.contains(ProactiveDeliveryPipeline.scoped("pre-8", tok8)) && q().entries["evt-8"] == nil, "late completion → removed, slot released")
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
    struct V: Decodable { let name: String; let type: String; let data: [String: ProactiveRules.SignalValue]; let confidence: Double }
    struct F: Decodable { let vectors: [V] }
    let url = URL(fileURLWithPath: "../../services/edge/test/fixtures/proactive/confidence-vectors.json")
    guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(F.self, from: d), f.vectors.count >= 15 else { check(false, "confidence vectors readable"); return }
    for v in f.vectors { let got = ProactiveRules.localConfidence(v.type, data: v.data); check(got == v.confidence, "confidence \(v.name): \(got)") }
    check(ProactiveRules.localConfidence("schedule_conflict", data: [:]) == 0.75, "schedule_conflict alias")
    check(ProactiveRules.localConfidence("meeting_upcoming", 8, travelMinutes: nil) == 0.7 && ProactiveRules.localConfidence("meeting_upcoming", 20, travelMinutes: 15) == 0.85, "minutes wrapper")
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

// MARK: Codex PR90d (2484e15)
func pr90d_ownership() {
    // Cold start: epoch nil → same account restored → nothing of that account is touched.
    // Codex PR90e: one decision (keep / adopt / wipe); adopting or wiping always registers the new owner.
    check(ProactiveDataOwner.plan(owner: "USER-A", current: "USER-A") == .keep, "same-account restore keeps data")
    check(ProactiveDataOwner.plan(owner: "user-a", current: "USER-A") == .keep, "case-insensitive owner")
    check(ProactiveDataOwner.plan(owner: "USER-A", current: "USER-B") == .wipe, "switch wipes A's data")
    check(ProactiveDataOwner.plan(owner: "USER-A", current: nil) == .wipe, "logout wipes")
    check(ProactiveDataOwner.plan(owner: "", current: nil) == .keep, "signed out and clean stays clean")
    // Notification cleanup by owner: only other accounts' / untagged proactive requests.
    var a: [AnyHashable: Any] = ["catpaw_proactive_id": "x"]; ProactiveAccountGate.stamp(&a, AccountToken(account: "USER-A", epoch: 1), deliveryID: "x", level: .notify)
    var b: [AnyHashable: Any] = ["catpaw_proactive_id": "y"]; ProactiveAccountGate.stamp(&b, AccountToken(account: "USER-B", epoch: 7), deliveryID: "y", level: .notify)
    check(ProactiveDataOwner.removeOnChange(a, current: "USER-B") && !ProactiveDataOwner.removeOnChange(b, current: "USER-B"), "B's fresh notification survives A's cleanup")
    check(!ProactiveDataOwner.removeOnChange(a, current: "user-a"), "same account (other process epoch) kept")
    check(ProactiveDataOwner.removeOnChange(["catpaw_proactive_id": "z"], current: "USER-B"), "untagged proactive removed")
    check(!ProactiveDataOwner.removeOnChange(["aps": ["alert": "chat"]], current: "USER-B"), "non-proactive untouched")
}

func pr90d_legacyRejected() {
    let epoch = AccountEpoch(account: "A"); var q = ProactiveQuotaLedger(); let noon = at("2026-10-15T04:00:00Z")
    let legacy: [AnyHashable: Any] = ["catpaw_proactive_id": "evt-old"]
    check(ProactiveAccountGate.verdict(legacy, epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .drop("untagged"), "legacy local payload rejected")
    check(!ProactiveAccountGate.belongsToCurrent(legacy, epoch: epoch), "legacy tap never resumes into the current account")
    check(ProactiveAccountGate.verdict(["catpaw": ["kind": "proactive_decision", "decision": "notify", "event_id": "E"]], epoch: epoch, now: noon, quota: &q, calendar: shanghai) == .drop("untagged"), "APNs without account rejected")
    check(ProactiveAccountGate.belongsToCurrent(["aps": ["alert": "x"]], epoch: epoch), "non-proactive payloads unaffected")
}

@MainActor func pr90d_scopedRequests() async {
    let noon = at("2026-10-15T04:00:00Z")
    let e = AccountEpoch(account: "A"), poster = FakePoster(); poster.completeLater = true
    var q = ProactiveQuotaLedger()
    let p = ProactiveDeliveryPipeline(epoch: e, poster: poster, clock: { noon }, calendar: shanghai, loadQuota: { q }, saveQuota: { q = $0 })
    let ta = e.capture()!
    _ = await p.preschedule(identity: "evt-m", requestID: "pre-M", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T06:00:00Z"), level: .notify, token: ta)
    let lateA = poster.pendingCompletions.removeFirst()
    e.activate(account: "B"); q = ProactiveQuotaLedger(); let tb = e.capture()!   // B's data starts clean (owner wipe)
    _ = await p.preschedule(identity: "evt-m", requestID: "pre-M", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T06:00:00Z"), level: .notify, token: tb)
    check(poster.adds.count == 2 && poster.adds[0].id != poster.adds[1].id, "request ids carry account + epoch (\(poster.adds.map(\.id)))")
    lateA(true)
    check(poster.removed == [ProactiveDeliveryPipeline.scoped("pre-M", ta)], "A's late callback removes only A's request (\(poster.removed))")
    check(q.entries["evt-m"]?.state == .reserved, "B's reservation survives A's late callback")
    // Snooze goes through the pipeline: stamped, quota-gated, late-cleaned.
    poster.completeLater = false
    let out = await p.snooze(id: "evt-s", intent: "op-evt-s-snooze", title: "t", body: "b", category: "c", info: ["catpaw_proactive_id": "evt-s"], fire: at("2026-10-15T04:10:00Z"), token: tb)
    let sb = ProactiveDeliveryPipeline.snoozeBase("evt-s", intent: "op-evt-s-snooze")
    check(out == .posted(ProactiveDeliveryPipeline.scoped(sb, tb)) && poster.adds.last?.info[ProactiveAccountGate.accountKey] == "B", "snooze stamped + scoped (\(out))")
    p.remove(bases: [sb], token: tb)
    check(poster.removed.contains(ProactiveDeliveryPipeline.scoped(sb, tb)) && poster.removed.contains(sb), "removal targets the scoped id (and the legacy one)")
    e.signOut()
    let stale = await p.snooze(id: "evt-s2", intent: "op-evt-s2-snooze", title: "t", body: "b", category: "c", info: [:], fire: at("2026-10-15T04:10:00Z"), token: tb)
    check(stale == .refused("stale_account"), "stale snooze refused")
}

@MainActor func pr90d_deadLetterOrdering() async {
    let kv = MemKV(); var t = at("2026-10-15T04:00:00Z")
    let q = CatpawPersistentQueue<SyncOp>(name: "dl", store: kv, maxAttempts: 2, baseDelay: 1)
    q.enqueue(SyncOp(local: "s1", action: "snooze"), key: "a", account: "A", group: "s1", now: t)
    q.enqueue(SyncOp(local: "s1", action: "dismiss"), key: "b", account: "A", group: "s1", now: t)
    q.enqueue(SyncOp(local: "s2", action: "dismiss"), key: "c", account: "A", group: "s2", now: t)
    var server: [String] = []
    for _ in 0..<3 { _ = await q.drain(now: t, account: "A") { op in if op.local == "s1" && op.action == "snooze" { return .retry }; server.append(op.local + ":" + op.action); return .done }; t = t.addingTimeInterval(60) }
    check(!server.contains("s1:dismiss"), "after s1's snooze dead-letters, s1's later dismiss is not sent out of order (\(server))")
    check(server == ["s2:dismiss"] && Set(q.deadLetters.map(\.key)) == ["a", "b"], "group poisoned → later ops parked with it (\(q.deadLetters.map(\.key)))")
}

func pr90d_snoozeRestore() {
    let t0 = at("2026-10-15T04:00:00Z")
    let first = ProactiveUndo.snoozeDetail(until: t0.addingTimeInterval(600))
    check(ProactiveUndo.snoozeUntil(detail: first, at: t0) == t0.addingTimeInterval(600), "until round trip")
    check(ProactiveUndo.snoozeUntil(detail: nil, at: t0) == t0.addingTimeInterval(600), "legacy entry → at + 10 min")
    // snooze(10) → snooze(60) → undo: the remaining snooze's own until.
    let taken: [(String, Date, String?)] = [("snooze", t0, first)]
    check(ProactiveUndo.restoredSnooze(taken: taken, status: "snoozed") == t0.addingTimeInterval(600), "restored snooze_until")
    check(ProactiveUndo.restoredSnooze(taken: taken, status: "pending") == nil, "not snoozed → nothing to restore")
}

func pr90d_localFeedbackGate() {
    var f = ProactiveLocalFeedback()
    check(f.gate("interrupt", trigger: "meeting_upcoming") == "interrupt", "no feedback → unchanged")
    f.record(.intrusive, trigger: "meeting_upcoming")
    check(f.gate("interrupt", trigger: "meeting_upcoming") == "notify", "intrusive → never interrupt")
    f.record(.not_helpful, trigger: "meeting_upcoming")
    check(f.gate("notify", trigger: "meeting_upcoming") == "card", "net negative → card only")
    check(f.gate("notify", trigger: "flight_status") == "notify", "per trigger")
    f.record(.helpful, trigger: "meeting_upcoming"); f.record(.helpful, trigger: "meeting_upcoming")
    check(f.gate("notify", trigger: "meeting_upcoming") == "notify", "helpful feedback recovers (never above the request)")
    check(ProactiveRules.applyFeedbackGate(.notify, gate: { d, _, t in f.gate(d, trigger: t) }) == .notify, "plugs into applyFeedbackGate")
    let back = try! JSONDecoder().decode(ProactiveLocalFeedback.self, from: JSONEncoder().encode(f)); check(back == f, "persisted")
}

// MARK: Codex PR90e (e76f019)
func pr90e_owner() {
    // P1-1: after a logout the owner is "" — the next account must still be registered (and anything left wiped).
    check(ProactiveDataOwner.plan(owner: "", current: "USER-B") == .wipe, "\"\" → B registers B (never stays \"\")")
    // P1-2: first run after upgrade (no owner recorded) adopts the data for the signed-in account — never drops it.
    // PR90f #1: an unknown owner is neither adopted nor wiped — quarantined (pr90f_quarantine).
    // P1-3: cleanup reads ownership exactly like the receive gate (local stamp or APNs catpaw.account).
    let apnsB: [AnyHashable: Any] = ["catpaw": ["kind": "proactive_decision", "account": "USER-B", "event_id": "E1"]]
    let apnsA: [AnyHashable: Any] = ["catpaw": ["kind": "proactive_decision", "account": "USER-A", "event_id": "E2"]]
    check(!ProactiveDataOwner.removeOnChange(apnsB, current: "user-b"), "current account's APNs notification survives cleanup")
    check(ProactiveDataOwner.removeOnChange(apnsA, current: "USER-B"), "other account's APNs notification removed")
    check(ProactiveDataOwner.owner(of: apnsB) == "USER-B", "one owner resolver for gate + cleanup")
}

@MainActor func pr90e_repeatedSnooze() async {
    // P1-4: snooze → it fires → snooze again must schedule a new notification (one identity per snooze intent).
    var t = at("2026-10-15T04:00:00Z"); let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, _) = makePipeline(e, poster, clock: { t })
    let tok = e.capture()!
    let u1 = t.addingTimeInterval(600)
    let o1 = await p.snooze(id: "sug", intent: "op-sug-snooze", title: "t", body: "b", category: "c", info: [:], fire: u1, token: tok)
    t = u1.addingTimeInterval(60)   // first snooze rang
    let u2 = t.addingTimeInterval(600)
    let o2 = await p.snooze(id: "sug", intent: "op-sug-snooze-n2", title: "t", body: "b", category: "c", info: [:], fire: u2, token: tok)
    check(o1 != o2 && { if case .posted = o2 { return true }; return false }(), "second snooze scheduled (\(o1) / \(o2))")
    check(poster.adds.count == 2 && poster.adds[1].fireAt == u2, "second request fires at its own until")
    // Re-reserving a still-pending identity moves its slot to the new fire day.
    var q = ProactiveQuotaLedger(); _ = q.reserve("x", fire: at("2026-10-15T04:00:00Z"), calendar: shanghai)
    _ = q.reserve("x", fire: at("2026-10-16T04:00:00Z"), calendar: shanghai)
    check(q.entries["x"]?.day == "2026-10-16" && q.entries["x"]?.at == at("2026-10-16T04:00:00Z").timeIntervalSince1970, "reservation follows the new fire time")
}

func pr90e_snoozeDetail() {
    let d = ProactiveUndo.snoozeDetail(until: at("2026-10-15T04:10:00Z"), intent: "op-s-snooze-n2")
    check(ProactiveUndo.snoozeUntil(detail: d, at: .distantPast) == at("2026-10-15T04:10:00Z") && ProactiveUndo.snoozeIntent(detail: d) == "op-s-snooze-n2", "snooze entry carries its until and its intent (\(d))")
    check(ProactiveUndo.snoozeUntil(detail: "until=100", at: .distantPast) == Date(timeIntervalSince1970: 100) && ProactiveUndo.snoozeIntent(detail: "until=100") == nil, "older entries still parse")
}

@MainActor func pr90e_resnoozeReleasesSlot() async {
    // Re-snoozing before the first one rang (or dismissing) frees that snooze's quota slot, so snoozes never eat the cap.
    let t = at("2026-10-15T04:00:00Z"); let e = AccountEpoch(account: "A"), poster = FakePoster(); let (p, q) = makePipeline(e, poster, clock: { t })
    let tok = e.capture()!
    _ = await p.snooze(id: "sug", intent: "op-1", title: "t", body: "b", category: "c", info: [:], fire: t.addingTimeInterval(600), token: tok)
    check(q().entries[ProactiveDeliveryPipeline.snoozeBase("sug", intent: "op-1")]?.state == .reserved, "snooze holds a slot")
    p.remove(bases: [ProactiveDeliveryPipeline.snoozeBase("sug", intent: "op-1")], token: tok)
    check(q().entries[ProactiveDeliveryPipeline.snoozeBase("sug", intent: "op-1")] == nil, "removed snooze frees its unfired slot")
}

func pr90e_operationIDs() {
    // P1-5: a new intent gets a new id; a retry of the same queued op reuses its stored id.
    let a = ProactiveRules.operationID(suggestion: "s", action: "snooze", generation: 0, ordinal: 1)
    let b = ProactiveRules.operationID(suggestion: "s", action: "snooze", generation: 0, ordinal: 2)
    check(a != b, "two snoozes → two operation ids (\(a), \(b))")
    check(a == ProactiveRules.operationID(suggestion: "s", action: "snooze", generation: 0), "first intent keeps the old id format")
    check(ProactiveRules.operationID(suggestion: "s", action: "snooze", generation: 1, ordinal: 2) != b, "after undo, fresh generation")
}

@MainActor func pr90e_deadLetterFuture() async {
    let kv = MemKV(); var t = at("2026-10-15T04:00:00Z")
    let q = CatpawPersistentQueue<SyncOp>(name: "dl2", store: kv, maxAttempts: 1, baseDelay: 1)
    q.enqueue(SyncOp(local: "s1", action: "snooze"), key: "a", account: "A", group: "s1", now: t)
    _ = await q.drain(now: t, account: "A") { _ in .retry }
    t = t.addingTimeInterval(60)
    q.enqueue(SyncOp(local: "s1", action: "undo"), key: "u", account: "A", group: "s1", now: t)
    var sent: [String] = []
    _ = await q.drain(now: t, account: "A") { op in sent.append(op.action); return .done }
    check(sent.isEmpty && q.deadLetters.map(\.key).contains("u"), "an op enqueued after its group dead-lettered is parked, not sent (\(sent))")
    let reloaded = CatpawPersistentQueue<SyncOp>(name: "dl2", store: kv, maxAttempts: 1, baseDelay: 1)
    reloaded.enqueue(SyncOp(local: "s1", action: "dismiss"), key: "d", account: "A", group: "s1", now: t)
    check(reloaded.items.isEmpty, "poison survives a restart")
}


// MARK: Codex PR90f (d544ea2)
func pr90f_quarantine() {
    check(ProactiveDataOwner.plan(owner: nil, current: "USER-A") == .quarantine, "unknown owner, signed in → quarantined (not claimed)")
    check(ProactiveDataOwner.plan(owner: nil, current: nil) == .quarantine, "unknown owner, signed out → quarantined (not wiped)")
    let t0 = at("2026-10-15T04:00:00Z"), soon = t0.addingTimeInterval(3600), late = t0.addingTimeInterval(ProactiveQuarantine.ttl + 60)
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: ["user-a", "USER-A"], current: "USER-A", serverConfirmed: false, now: soon) == .release, "every stamp names the current account → released")
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: ["USER-A", "USER-B"], current: "USER-A", serverConfirmed: false, now: soon) == .hold, "mixed stamps are no proof")
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: [], current: "USER-A", serverConfirmed: false, now: soon) == .hold, "no evidence → held")
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: ["USER-B"], current: "USER-A", serverConfirmed: true, now: soon) == .release, "the cloud confirms its server id for this account → released")
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: [], current: nil, serverConfirmed: false, now: soon) == .hold, "signed out → held")
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: [], current: "USER-A", serverConfirmed: false, now: late) == .expire, "no evidence within the bound → expired")
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: [], current: nil, serverConfirmed: false, now: late) == .expire, "expires signed out too")
    check(ProactiveQuarantine.decide(quarantinedAt: t0, stampedAccounts: ["USER-A"], current: "USER-A", serverConfirmed: false, now: late) == .release, "evidence still wins at expiry time")
}
@MainActor func pr90f_purgeDeadLetters() async {
    let kv = MemKV(); let t = at("2026-10-15T04:00:00Z")
    let q = CatpawPersistentQueue<SyncOp>(name: "pdl", store: kv, maxAttempts: 1, baseDelay: 1)
    q.enqueue(SyncOp(local: "s1", action: "snooze"), key: "a", account: "A", group: "s1", now: t)
    q.enqueue(SyncOp(local: "s2", action: "snooze"), key: "b", account: "B", group: "s2", now: t)
    _ = await q.drain(now: t, account: "A") { _ in .retry }; _ = await q.drain(now: t, account: "B") { _ in .retry }
    q.purge(account: "A")
    check(!q.deadLetters.contains { $0.account == "A" } && q.deadLetters.contains { $0.account == "B" }, "purge(account) clears that account's dead letters only")
    q.purge(account: nil); check(q.deadLetters.isEmpty, "purge(nil) clears every dead letter")
    check(CatpawPersistentQueue<SyncOp>(name: "pdl", store: kv).deadLetters.isEmpty, "persisted")
}
@MainActor final class RejectingPoster: ProactiveNotificationPoster {
    var adds: [ProactiveNotificationRequest] = [], removed: [String] = [], result = false, pending: [(Bool) -> Void] = []; var hold = false
    func requestAuthorization() async -> Bool { true }
    func add(_ r: ProactiveNotificationRequest, completion: @escaping @MainActor (Bool) -> Void) { adds.append(r); if hold { pending.append(completion) } else { completion(result) } }
    func remove(ids: [String]) { removed += ids }
}
@MainActor func pr90f_snoozeAwaitsAdd() async {
    let t = at("2026-10-15T04:00:00Z"); let e = AccountEpoch(account: "A"), poster = RejectingPoster(); var q = ProactiveQuotaLedger()
    let p = ProactiveDeliveryPipeline(epoch: e, poster: poster, clock: { t }, calendar: shanghai, loadQuota: { q }, saveQuota: { q = $0 })
    let tok = e.capture()!, base = ProactiveDeliveryPipeline.snoozeBase("sug", intent: "op-1")
    let out = await p.snooze(id: "sug", intent: "op-1", title: "t", body: "b", category: "c", info: [:], fire: t.addingTimeInterval(600), token: tok)
    check(out == .refused("system_rejected"), "the system rejected the add → not reported as posted (\(out))")
    check(q.entries[base] == nil, "rejected snooze holds no slot")
    // The awaited add only returns after the system answered.
    poster.hold = true; poster.result = true; var done: ProactiveDeliveryPipeline.Outcome?
    let task = Task { @MainActor in done = await p.snooze(id: "sug", intent: "op-2", title: "t", body: "b", category: "c", info: [:], fire: t.addingTimeInterval(600), token: tok) }
    for _ in 0..<20 { await Task.yield() }
    check(done == nil && poster.pending.count == 1, "still waiting for the system add")
    poster.pending.removeFirst()(true); await task.value
    check({ if case .posted = done { return true }; return false }(), "posted after the system confirmed (\(String(describing: done)))")
}
@MainActor func pr90f_clock() {
    let fixed = at("2026-10-15T02:00:00Z"), saved = ProactiveClock.now; ProactiveClock.now = { fixed }; defer { ProactiveClock.now = saved }
    let p = ProactiveDeliveryPipeline(epoch: AccountEpoch(account: "A"), poster: FakePoster(), loadQuota: { ProactiveQuotaLedger() }, saveQuota: { _ in })
    check(p.clock() == fixed, "the pipeline's default clock is the injected ProactiveClock")
}
func pr90f_wire() {
    let b = ProactiveSyncWire.createBody(clientID: "local-1", title: "评审", reason: "r", actions: ["snooze", "dismiss"], createdAt: at("2026-10-15T02:00:00Z"))
    check(b["client_id"] as? String == "local-1" && b["title"] as? String == "评审" && b["reason"] as? String == "r" && b["actions"] as? [String] == ["snooze", "dismiss"]
          && b["created_at"] as? String == "2026-10-15T02:00:00Z" && b["decision"] as? String == "notify", "offline create body (\(b))")
    let d = ProactiveUndo.withRestore(ProactiveUndo.snoozeDetail(until: at("2026-10-15T04:10:00Z"), intent: "op-1"), "posted")
    check(ProactiveUndo.restoreOutcome(detail: d) == "posted" && ProactiveUndo.snoozeIntent(detail: d) == "op-1" && ProactiveUndo.snoozeUntil(detail: d, at: .distantPast) == at("2026-10-15T04:10:00Z"), "undo records the re-arm outcome on the kept snooze (\(d))")
    check(ProactiveUndo.restoreOutcome(detail: ProactiveUndo.withRestore(d, "cardOnly:quiet_hours")) == "cardOnly:quiet_hours", "latest outcome wins")
}
/// The device side of the golden device → cloud round trip: two snoozes then undo, built only from the shipping
/// portable functions (operation ids, snooze detail, wire body, undo plan). CATPAW_WRITE_GOLDEN=1 rewrites the fixture;
/// otherwise the fixture must match what the client produces today (so neither side can drift alone).
func pr90f_golden() {
    let local = "LOCAL-SUGGESTION", t = at("2026-10-15T02:00:00Z")
    var taken: [(action: String, at: Date, detail: String?)] = [], requests: [[String: Any]] = [], gens = ProactiveActionGenerations()
    for (k, minutes) in [(1, 10.0), (2, 30.0)] {
        let op = ProactiveRules.operationID(suggestion: local, action: "snooze", generation: gens[local], ordinal: k)
        let until = t.addingTimeInterval(minutes * 60)
        taken.append(("snooze", t, ProactiveUndo.snoozeDetail(until: until, intent: op)))
        requests.append(["route": ProactiveSyncWire.route(action: "snooze"), "body": ProactiveSyncWire.body(action: "snooze", operationID: op, until: ProactiveSyncWire.iso(until))])
    }
    let plan = ProactiveUndo.plan(offered: ["create_reminder", "snooze", "dismiss"], taken: taken.map(\.action), status: "snoozed")
    let undoOp = gens.undo(local); taken.remove(at: plan.removedIndex!)
    requests.append(["route": ProactiveSyncWire.route(action: "undo"), "body": ProactiveSyncWire.body(action: "undo", operationID: undoOp, until: nil)])
    let restored = ProactiveUndo.restoredSnooze(taken: taken, status: plan.status)
    let g: [String: Any] = ["local_id": local, "server_now": ProactiveSyncWire.iso(t), "requests": requests,
                            "expect": ["status": plan.status, "taken": plan.after, "snooze_until": restored.map(ProactiveSyncWire.iso) ?? NSNull()]]
    let data = try! JSONSerialization.data(withJSONObject: g, options: [.sortedKeys, .prettyPrinted])
    let url = URL(fileURLWithPath: "../../services/edge/test/fixtures/proactive-sync-golden.json")
    if ProcessInfo.processInfo.environment["CATPAW_WRITE_GOLDEN"] == "1" { try! data.write(to: url); print("golden written: \(url.path)") }
    let onDisk = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
    check(onDisk == (try! JSONSerialization.jsonObject(with: data) as! NSDictionary), "golden device → cloud fixture matches the client's payloads")
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
        pr90d_ownership(); pr90d_legacyRejected(); await pr90d_scopedRequests(); await pr90d_deadLetterOrdering(); pr90d_snoozeRestore(); pr90d_localFeedbackGate()
        pr90e_owner(); await pr90e_repeatedSnooze(); pr90e_operationIDs(); pr90e_snoozeDetail(); await pr90e_resnoozeReleasesSlot(); await pr90e_deadLetterFuture()
        pr90f_quarantine(); await pr90f_purgeDeadLetters(); await pr90f_snoozeAwaitsAdd(); pr90f_clock(); pr90f_wire(); pr90f_golden()
        print(failures == 0 ? "PR90 proactive: all passed" : "PR90 proactive: \(failures) failed"); exit(failures == 0 ? 0 : 1)
    }
}
