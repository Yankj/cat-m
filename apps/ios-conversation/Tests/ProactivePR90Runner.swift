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

@main enum ProactivePR90Runner {
    static func main() {
        pr90_3_prescheduleSharesDecisionAndQuota()
        pr90_accountEpoch()
        pr90_4_serverActionStates()
        print(failures == 0 ? "PR90 proactive: all passed" : "PR90 proactive: \(failures) failed"); exit(failures == 0 ? 0 : 1)
    }
}
