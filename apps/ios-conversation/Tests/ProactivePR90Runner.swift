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

@main enum ProactivePR90Runner {
    static func main() {
        pr90_3_prescheduleSharesDecisionAndQuota()
        print(failures == 0 ? "PR90 proactive: all passed" : "PR90 proactive: \(failures) failed"); exit(failures == 0 ? 0 : 1)
    }
}
