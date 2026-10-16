import Foundation

// Codex PR90 #3 / P2: one persisted delivery quota shared by the in-app path and the pre-scheduled path.
// Every system notification has a delivery identity (the signal hash / event id). A pre-scheduled notification
// *reserves* a slot on its fire day; once the fire time has passed it counts as delivered even if the user never
// tapped it ("shown but not tapped"). An in-app delivery of the same identity converts the reservation instead of
// counting twice. Cross-timezone rule: a slot belongs to the local calendar day (device time zone at recording)
// of its delivery instant, stored as a "yyyy-MM-dd" key, so travelling never re-opens or double-charges a day.
struct ProactiveQuotaLedger: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case reserved, delivered }
    struct Entry: Codable, Sendable, Equatable { var day: String; var at: Double; var state: State }
    var entries: [String: Entry] = [:]
    /// Alternate delivery ids (server event_id) → the identity they deliver, so an APNs push and the local post dedupe.
    var aliases: [String: String] = [:]
    init() {}
    mutating func alias(_ alt: String, to id: String) { if alt != id { aliases[alt] = id } }
    private func resolve(_ id: String) -> String { aliases[id] ?? id }

    static func day(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func count(on d: Date, calendar: Calendar = .current) -> Int {
        let k = Self.day(d, calendar: calendar); return entries.values.filter { $0.day == k }.count
    }
    func has(_ id: String) -> Bool { entries[resolve(id)] != nil }
    /// Reserve a slot for a future (pre-scheduled) delivery. Same identity → idempotent. Returns false when the fire day is full.
    mutating func reserve(_ id: String, fire: Date, cap: Int = ProactiveRules.dailyNotifyCap, calendar: Calendar = .current) -> Bool {
        if let e = entries[id] { return e.state == .reserved || e.day == Self.day(fire, calendar: calendar) }
        guard count(on: fire, calendar: calendar) < cap else { return false }
        entries[id] = .init(day: Self.day(fire, calendar: calendar), at: fire.timeIntervalSince1970, state: .reserved); return true
    }
    /// A real system notification was posted now. Converts this identity's reservation; never counts one identity twice.
    /// Returns false when the identity was already delivered (the second path must not post).
    @discardableResult mutating func recordDelivery(_ raw: String, at: Date, calendar: Calendar = .current) -> Bool {
        let id = resolve(raw)
        if entries[id]?.state == .delivered { return false }
        if let e = entries[id], e.state == .reserved, e.at <= at.timeIntervalSince1970 { entries[id]?.state = .delivered; return false }  // already fired
        entries[id] = .init(day: Self.day(at, calendar: calendar), at: at.timeIntervalSince1970, state: .delivered); return true
    }
    /// Fired reservations become deliveries ("shown but not tapped"): the in-app path must not post them again.
    @discardableResult mutating func settle(now: Date) -> Bool {
        var changed = false
        for (k, e) in entries where e.state == .reserved && e.at <= now.timeIntervalSince1970 { entries[k]?.state = .delivered; changed = true }
        return changed
    }
    /// Drop an unfired reservation (pre-scheduled request removed / superseded).
    mutating func release(_ id: String, now: Date) {
        if let e = entries[id], e.state == .reserved, e.at > now.timeIntervalSince1970 { entries[id] = nil }
    }
    mutating func prune(now: Date, keepDays: Double = 3) {
        entries = entries.filter { $0.value.at > now.timeIntervalSince1970 - keepDays * 86400 }
    }
}

extension ProactiveRules {
    /// The pre-scheduled path shares the decision: same offline level as the in-app path, evaluated for the fire instant,
    /// then the same on-device gate (quiet hours at fire time). Returns the level to post, or nil (don't schedule).
    static func prescheduleLevel(minutesUntilAtFire: Int, leadMinutes: Int, travelMinutes: Int?, fire: Date, deliveredOnFireDay: Int, calendar: Calendar = .current) -> ProactiveLevel? {
        let level = localLevel(minutesUntil: minutesUntilAtFire, leadMinutes: leadMinutes, travelMinutes: travelMinutes)
        guard level >= .notify else { return nil }
        let plan = delivery(level: level, now: fire, deliveredToday: deliveredOnFireDay, calendar: calendar)
        return plan.systemNotification ? plan.level : nil
    }
}

// Codex PR90 #6: idempotency identity across undo. Each undo starts a new generation for that suggestion, so an
// action re-taken after undo gets a fresh operation_id (the cloud keeps old ids burned: a late retry of an undone
// op never resurrects it). Generation 0 keeps the legacy id so ops already in flight still dedupe.
struct ProactiveActionGenerations: Codable, Sendable, Equatable {
    var values: [String: Int] = [:]
    init() {}
    subscript(_ suggestion: String) -> Int { values[suggestion] ?? 0 }
    /// Returns the undo's own operation id, then advances the generation.
    mutating func undo(_ suggestion: String) -> String {
        let g = self[suggestion]; values[suggestion] = g + 1; return "undo-\(suggestion)-g\(g)"
    }
}
extension ProactiveRules {
    static func operationID(suggestion: String, action: String, generation: Int) -> String {
        generation == 0 ? "op-\(suggestion)-\(action)" : "op-\(suggestion)-\(action)-g\(generation)"
    }
}

extension ProactiveRules {
    /// Codex PR90 P2: the on-device gate runs against the actual delivery instant. `evaluatedAt` is the (possibly
    /// simulated) clock the chain started with; the wall-clock time spent in evaluation / ETA awaits is added to it.
    static func deliveryInstant(evaluatedAt: Date, startedWall: Date, wall: Date = .now) -> Date {
        evaluatedAt.addingTimeInterval(max(0, wall.timeIntervalSince(startedWall)))
    }
}

extension ProactiveRules {
    /// NoBug: trigger key for on-device meeting suggestions (same key the cloud learns feedback weights under).
    static let localTrigger = "meeting_upcoming"
    /// Applies 三角's learned feedback gate (`ProactiveFeedbackSync.shared.gate`) to a local decision. Never raises a level.
    static func applyFeedbackGate(_ level: ProactiveLevel, trigger: String = localTrigger, confidence: Double? = nil,
                                  gate: ((String, Double, String) -> String)?) -> ProactiveLevel {
        guard level > .silent, let gate else { return level }
        return min(level, ProactiveLevel(server: gate(level.name, confidence ?? localConfidence(trigger, nil, nil), trigger)))
    }
}

extension ProactiveRules {
    /// 三角's per-trigger confidences for offline decisions (same table the feedback gate is calibrated on).
    /// `detail` for flights: "cancelled" | "delay_60" | "delay_30" | anything else (gate change etc.).
    static func localConfidence(_ trigger: String, _ minutesUntil: Int?, _ detail: String?) -> Double {
        switch trigger {
        case "meeting_upcoming": return (minutesUntil ?? .max) <= 10 ? 0.7 : 0.6
        case "travel_conflict": return 0.85
        case "flight_status": return detail == "cancelled" ? 0.9 : detail == "delay_60" ? 0.8 : detail == "delay_30" ? 0.75 : 0.7
        case "meeting_conflict", "schedule_conflict": return 0.75
        case "traffic": return 0.65
        default: return 0.6
        }
    }
    /// Pre-scheduled notification fires when the user should start getting ready: start − lead (no fixed +5).
    static func prescheduleFire(start: Date, leadMinutes: Int) -> Date { start.addingTimeInterval(TimeInterval(-leadMinutes * 60)) }
    /// Level for the pre-scheduled notification: the cloud decision for the fire instant when available, else local rules;
    /// then the learned feedback gate with the trigger's confidence. nil → don't schedule (silent / card).
    static func prescheduleDecision(cloud: ProactiveLevel?, leadMinutes: Int, trigger: String = localTrigger,
                                    gate: ((String, Double, String) -> String)?) -> ProactiveLevel? {
        let base = cloud ?? localLevel(minutesUntil: leadMinutes, leadMinutes: leadMinutes, travelMinutes: nil)
        let level = applyFeedbackGate(base, trigger: trigger, confidence: localConfidence(trigger, leadMinutes, nil), gate: gate)
        return level >= .notify ? level : nil
    }
}
