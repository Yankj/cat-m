import Foundation
import MapKit
import CoreLocation
import CryptoKit
import Observation
#if canImport(EventKit)
import EventKit
#endif
#if os(iOS)
import UIKit
import UserNotifications
import BackgroundTasks
import WidgetKit
#endif

// On-device ProactiveEngine (interview demo core).
// Non-user signal (EventKit next event / BGAppRefresh / simulated signal) → rule pre-filter → dedupe ledger
// (signal_hash) → evaluate (server /proactive/evaluate, local rules offline) → card + actionable local notification
// → user confirms → idempotent EventKit reminder write (operation_id in EKReminder url/notes).
// Memory: "提前 N 分钟" in the user's memories changes the reminder lead time and is cited in the card.

struct ProactiveLogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let at: Date
    let text: String
}

/// One candidate trigger, before dedupe.
struct ProactiveSignal: Equatable, Sendable {
    enum Source: String, Sendable { case eventKit = "calendar", simulated = "simulated", manual = "manual", background = "bg_refresh" }
    var source: Source
    var eventID: String
    var title: String
    var start: Date
    var place: String
    /// Debug 「模拟起点」— Why must say 「从模拟起点 X」; never silent.
    var simulatedOriginLabel: String? = nil
    var simulatedOriginLat: Double? = nil
    var simulatedOriginLon: Double? = nil
    /// EKEvent attendee names / phones for notify draft.
    var attendeeNames: [String] = []
    var attendeeRecipients: [String] = []
    /// Stable per (event, start): the same meeting never triggers twice.
    var signalHash: String {
        ProactiveRules.signalHash(eventID: eventID, start: start)
    }
}

@MainActor @Observable final class ProactiveEngine {
    static let shared = ProactiveEngine()
    static let notificationCategory = "CATPAW_PROACTIVE"
    static let createAction = "CATPAW_PROACTIVE_CREATE"
    static let laterAction = "CATPAW_PROACTIVE_LATER"
    static let notNowAction = "CATPAW_PROACTIVE_NOT_NOW"
    static let bgTaskID = "com.yankj.catpawm.proactive.refresh"

    private(set) var log: [ProactiveLogEntry] = []
    private(set) var calendarDenied = false
    private(set) var lastSuggestionID: String?
    var defaultLeadMinutes = 10
    private let defaults = UserDefaults.standard
    private let ledgerKey = "catpaw.proactive.ledger.v1", opsKey = "catpaw.proactive.ops.v1", suggestionsKey = "catpaw.proactive.suggestions.v1"
    #if canImport(EventKit)
    let store = EKEventStore()
    #endif

    // MARK: Log + ledger

    func note(_ text: String) {
        log.insert(.init(at: .now, text: text), at: 0)
        if log.count > 80 { log.removeLast(log.count - 80) }
        print("catpaw.proactive \(text)")
    }
    private var ledger: [String: Double] {
        get { defaults.dictionary(forKey: ledgerKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: ledgerKey) }
    }
    func resetLedger() { ledger = [:]; note("ledger cleared") }

    // MARK: Memory → lead time

    /// Looks for "提前 N 分钟" / "N minutes early" in the live agent memory; falls back to `defaultLeadMinutes`.
    /// Settings/debug writes the same phrase via `setLeadMinutes` so evaluate has hard evidence.
    func leadTime() async -> (minutes: Int, memory: ProactiveSuggestion.MemoryRef?) {
        // Cloud backend first, then the persisted on-device library (NoBug P0-1: survives cold start).
        var snaps: [MemoryLibrarySnapshot] = []
        if let backend = MemoryLibraryHub.backend, let snapshot = try? await backend.load() { snaps.append(snapshot) }
        if MemoryLibraryHub.backend !== MemoryLibraryHub.local, let local = try? await MemoryLibraryHub.local.load() { snaps.append(local) }
        if let hit = ProactiveRules.lead(in: snaps) { return (hit.minutes, .init(id: hit.item.id, content: hit.item.content)) }
        return (defaultLeadMinutes, nil)
    }

    /// Settings / debug: writes a REAL memory item into the store Settings › 记忆 lists (MemoryLibraryHub.backend).
    /// Returns a user-facing outcome; no shadow store — if the library refuses, nothing is used.
    @discardableResult func setLeadMinutes(_ minutes: Int) async -> String {
        let n = min(180, max(1, minutes)), phrase = "开会提前 \(n) 分钟准备"
        guard let backend = MemoryLibraryHub.backend else { note("lead write failed: no memory library"); return "记忆库不可用，未写入" }
        do {
            let snap = try await backend.load()
            let old = snap.items.filter { $0.content.range(of: #"提前\s*\d{1,3}\s*分钟"#, options: .regularExpression) != nil }.map(\.id)
            if !old.isEmpty { try await backend.forget(ids: old) }
            let id = try await backend.create(kind: "preference", content: phrase)
            note("lead memory created id=\(id) “\(phrase)” in \(type(of: backend))")
            return "已写入记忆：\(phrase)"
        } catch MemoryLibraryError.notEnabled, MemoryLibraryError.unsupported {
            // Settings › 记忆 lists Hub.backend. If agent-memory is 未开通 / no create, install a local
            // stub as the same page backend so the row is visible+deletable (honest label, no UserDefaults).
            // Persisted on-device library (Application Support) — survives cold start; migrated when the gate opens.
            let stub = MemoryLibraryHub.local
            if MemoryLibraryHub.backend !== stub { MemoryLibraryHub.install(backend: stub) }
            do {
                let snap = try await stub.load()
                let old = snap.items.filter { $0.content.range(of: #"提前\s*\d{1,3}\s*分钟"#, options: .regularExpression) != nil }.map(\.id)
                if !old.isEmpty { try await stub.forget(ids: old) }
                let id = try await stub.create(kind: "preference", content: phrase)
                note("lead memory local-stub id=\(id) (agent-memory unavailable)")
                return "agent-memory 未开通 — 已写入本机记忆库（设置 › 记忆可见可删）：\(phrase)"
            } catch {
                note("lead local-stub failed: \(error)"); return "写入本机记忆库失败"
            }
        } catch { note("lead write failed: \(error)"); return "写入记忆失败" }
    }

    /// Delete lead preference + matching memory so evaluate falls back to default.
    func clearLeadMinutes() async {
        if let backend = MemoryLibraryHub.backend, let snap = try? await backend.load() {
            let ids = snap.items.filter { ($0.content.contains("提前") && $0.content.contains("分钟")) }.map(\.id)
            if !ids.isEmpty { try? await backend.forget(ids: ids) }
        }
        let localIDs = MemoryLibraryHub.local.items.filter { ProactiveRules.isLeadMemory($0.content) }.map(\.id)
        if !localIDs.isEmpty { try? await MemoryLibraryHub.local.forget(ids: localIDs) }
        note("lead_minutes cleared — evaluate uses default \(defaultLeadMinutes)")
    }

    /// Debug / Settings entry: prompt When-In-Use so travelETA can use a real fix (no silent CBD fallback).
    @discardableResult func requestLocationAccess() async -> String {
        #if canImport(CoreLocation) && os(iOS)
        let status = CLLocationManager.authorizationStatus()
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            if let c = await Self.requestCurrentCoordinate() {
                return String(format: "已授权 · 当前约 %.4f, %.4f", c.latitude, c.longitude)
            }
            return "已授权 · 暂无定位点（可在模拟器 Features › Location 设望京）"
        case .denied, .restricted:
            return "定位被拒绝 — 请到系统设置开启"
        case .notDetermined:
            let ok = await LocationOnceProbe().requestWhenInUse()
            return ok ? "已授权 When-In-Use" : "未授权"
        @unknown default:
            return "未知定位状态"
        }
        #else
        return "本平台无定位"
        #endif
    }



    // MARK: Signals

    /// Real non-user signal: the next calendar event in the coming 3 hours.
    /// `ask`: only explicit user actions (debug panel, permission card) may show the system prompt; background /
    /// foreground scans stay silent while the status is undetermined.
    func scanCalendar(source: ProactiveSignal.Source = .eventKit, ask: Bool = false) async {
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined && !ask { return }
        if status == .notDetermined {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if !granted { return calendarUnavailable() }
        } else if status != .fullAccess && status != .authorized { return calendarUnavailable() }
        calendarDenied = false
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(3 * 3600), calendars: nil)
        guard let event = store.events(matching: predicate).filter({ !$0.isAllDay && $0.startDate > now }).sorted(by: { $0.startDate < $1.startDate }).first else {
            note("collect source=\(source.rawValue) upcoming=0 → nothing to do"); return
        }
        let names = (event.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        let recipients = (event.attendees ?? []).compactMap { att -> String? in
            let url = att.url
            guard let scheme = url.scheme?.lowercased() else { return nil }
            if scheme == "tel" || scheme == "sms" {
                let prefix = scheme + ":"
                return url.absoluteString.replacingOccurrences(of: prefix, with: "")
            }
            return nil
        }
        await handle(.init(source: source, eventID: event.calendarItemIdentifier, title: event.title ?? "日程", start: event.startDate, place: event.location ?? "",
                           attendeeNames: names, attendeeRecipients: recipients))
        #endif
    }
    private func calendarUnavailable() {
        calendarDenied = true
        note("collect calendar=denied → degrade card (manual meeting input)")
        let degrade = ProactiveSuggestion(id: "permission-calendar", title: "日历权限未开启", reason: "开启日历后我能在会前主动提醒你；也可以手动告诉我下一场会。",
                                          actions: [.dismiss], signals: [.init(kind: "permission", text: "calendar=denied")], createdAt: .now)
        ProactiveSuggestionStore.shared.adopt(degrade)
    }

    /// Pipeline core shared by EventKit, BGAppRefresh, the debug panel and the manual degrade input.
    @discardableResult func handle(_ signal: ProactiveSignal, now: Date = .now) async -> ProactiveSuggestion? {
        note("collect source=\(signal.source.rawValue) event=\(signal.title) start=\(signal.start.formatted(date: .omitted, time: .shortened))")
        // Rule pre-filter
        let minutes = signal.start.timeIntervalSince(now) / 60
        guard ProactiveRules.inWindow(start: signal.start, now: now) else { note("filter drop: starts in \(Int(minutes)) min (window 0–180)"); return nil }
        // Dedupe ledger
        let hash = signal.signalHash
        if let seen = ledger[hash] {
            note("dedupe SUPPRESSED duplicate signal_hash=\(hash) (first seen \(Date(timeIntervalSince1970: seen).formatted(date: .omitted, time: .shortened)))")
            return nil
        }
        var l = ledger; _ = ProactiveRules.admit(hash, ledger: &l, now: now); ledger = l
        note("dedupe new signal_hash=\(hash)")
        // Evaluate
        let lead = await leadTime()
        let simOrigin: CLLocationCoordinate2D? = {
            guard let la = signal.simulatedOriginLat, let lo = signal.simulatedOriginLon else { return nil }
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }()
        let travel = await Self.travelETA(to: signal.place, from: simOrigin, simulatedLabel: signal.simulatedOriginLabel)
        let travelMinutes = travel.minutes
        let usedETA = travel.usedETA
        let originNote = travel.originNote
        // leave_at = meeting_start - lead_minutes - travel_minutes (travel 0 only when ETA unused → lead only)
        let leaveAt = ProactiveRules.leaveAt(start: signal.start, leadMinutes: lead.minutes, travelMinutes: travelMinutes, usedETA: usedETA)
        let remindAt = leaveAt  // remind when user should leave
        let decision = await evaluateRemote(signal, leadMinutes: lead.minutes, travelMinutes: usedETA ? travelMinutes : nil)
            ?? evaluateLocal(signal, leadMinutes: lead.minutes, now: now)
        guard decision.intervene else { note("decide silent: \(decision.why)"); return nil }
        note("decide intervene (\(decision.via)): \(decision.why); lead=\(lead.minutes) travel=\(usedETA ? String(travelMinutes ?? 0) : "unused") leaveAt=\(leaveAt.formatted(date: .omitted, time: .shortened))")
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        var memories: [ProactiveSuggestion.MemoryRef] = []
        if let m = lead.memory { memories.append(m) }
        var signals: [ProactiveSuggestion.Signal] = [
            .init(kind: signal.source == .eventKit || signal.source == .background ? "calendar" : signal.source.rawValue,
                  text: "\(signal.start.formatted(f)) \(signal.title)\(signal.place.isEmpty ? "" : " · " + signal.place)"),
            .init(kind: "time", text: "现在 \(now.formatted(f)) · 建议 \(leaveAt.formatted(f)) 出发"),
            .init(kind: "rule", text: lead.memory != nil
                  ? "提前 \(lead.minutes) 分钟（记忆） · signal_hash=\(hash)"
                  : "提前 \(lead.minutes) 分钟（默认） · signal_hash=\(hash)")
        ]
        if usedETA, let tm = travelMinutes, tm > 0 {
            let originBit = originNote.map { " · \($0)" } ?? ""
            signals.insert(.init(kind: "travel", text: "路途约 \(tm) 分钟（MapKit）\(originBit)"), at: 1)
        } else {
            signals.insert(.init(kind: "travel", text: "未用到 ETA"), at: 1)
        }
        let title: String
        let reason: String
        if usedETA, let tm = travelMinutes, tm > 0 {
            title = "\(leaveAt.formatted(f)) 该出发 · \(signal.title)"
            let originBit = originNote.map { "（\($0)）" } ?? ""
            reason = lead.memory != nil
                ? "记忆提前 \(lead.minutes) 分钟 + 路途 \(tm) 分钟\(originBit) → \(leaveAt.formatted(f)) 出发（会 \(signal.start.formatted(f)) 开始）"
                : "默认提前 \(lead.minutes) 分钟 + 路途 \(tm) 分钟\(originBit) → \(leaveAt.formatted(f)) 出发"
        } else {
            title = "\(signal.start.formatted(f)) \(signal.title) · 要我 \(leaveAt.formatted(f)) 提醒你吗？"
            reason = lead.memory != nil
                ? "你习惯提前 \(lead.minutes) 分钟准备（未用到 ETA），提醒定在 \(leaveAt.formatted(f))"
                : "会议 \(Int(minutes)) 分钟后开始，默认提前 \(lead.minutes) 分钟（未用到 ETA）"
        }
        let suggestion = ProactiveSuggestion(
            id: "evt-" + hash,
            title: title, reason: reason,
            memories: memories, actions: [.create_reminder, .notify_attendees, .snooze, .dismiss],
            signals: signals, status: .pending, createdAt: now)
        // A notification may have recovered and acted on this same meeting while evaluation awaited
        // its response. Preserve that newer inbox state instead of replacing it with a pending card.
        if let existing = ProactiveSuggestionStore.shared.items[suggestion.id] { return existing }
        pendingReminders[suggestion.id] = .init(title: signal.title, due: remindAt, start: signal.start, place: signal.place,
                                                operationID: "op-" + hash, leaveAt: leaveAt, leadMinutes: lead.minutes,
                                                travelMinutes: usedETA ? travelMinutes : nil, usedETA: usedETA)
        if !signal.attendeeNames.isEmpty || !signal.attendeeRecipients.isEmpty {
            pendingAttendees[suggestion.id] = (signal.attendeeNames, signal.attendeeRecipients)
        }
        rememberServerID(local: suggestion.id)
        ProactiveLocalBackend.save(suggestion)
        ProactiveSuggestionStore.shared.adopt(suggestion)
        lastSuggestionID = suggestion.id
        intervene(suggestion)
        return suggestion
    }

    struct Decision { var intervene: Bool; var why: String; var via: String }
    private func evaluateLocal(_ s: ProactiveSignal, leadMinutes: Int, now: Date) -> Decision {
        let minutes = Int(s.start.timeIntervalSince(now) / 60)
        if minutes < 3 { return .init(intervene: false, why: "too late to help (\(minutes) min)", via: "local") }
        return .init(intervene: true, why: "meeting in \(minutes) min, lead \(leadMinutes) min", via: "local rules")
    }
    /// 三角's `/catpaw/proactive/v1` base (edge fn catpaw-proactive); nil when not configured / signed out.
    static func apiBase() -> URL? {
        let info = Bundle.main.infoDictionary
        guard let raw = (info?["CatpawProactiveBaseURL"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? (info?["CatpawSupabaseProjectURL"] as? String).flatMap({ $0.isEmpty ? nil : $0 + "/functions/v1/catpaw-proactive" }) else { return nil }
        return URL(string: raw)?.appendingPathComponent("catpaw/proactive/v1")
    }
    static func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let base = apiBase(), let bearer = try? await CatpawPushTokenUploader.shared.bearer() else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 6)
        request.httpMethod = "POST"; request.setValue(bearer, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.httpBody = payload
        // #63 S1: stable per (route, body) so a retry after a dropped response replays instead of re-running.
        let key = (body["operation_id"] as? String).map { "op-\($0)-\(path.split(separator: "/").last ?? "")" }
            ?? "pr-" + SHA256.hash(data: Data(path.utf8) + (payload ?? Data())).prefix(16).map { String(format: "%02x", $0) }.joined()
        request.setValue(String(key.prefix(200)), forHTTPHeaderField: "Idempotency-Key")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { FeatureEnrollment.shared.proactiveDisabled = true; shared.note("server proactive feature_disabled → local rules; enroll prompt shown in Settings") }
        guard status == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    /// Server suggestion id per local suggestion, for action/undo/feedback write-back.
    private(set) var serverIDs: [String: String] = [:]
    private var lastRemote: [String: Any]?
    /// `POST /catpaw/proactive/v1/evaluate`; nil (offline / not deployed) → local rules.
    private func evaluateRemote(_ s: ProactiveSignal, leadMinutes: Int, travelMinutes: Int? = nil) async -> Decision? {
        let minutes = Int(s.start.timeIntervalSince(.now) / 60)
        var data: [String: Any] = ["title": s.title, "location": s.place, "minutes_until": minutes]
        // Never claim ETA when unused / zero — omit the key rather than send 0.
        if let travelMinutes, travelMinutes > 0 { data["travel_minutes"] = travelMinutes }
        let body: [String: Any] = ["signals": [["type": "meeting_upcoming", "source": s.source.rawValue, "dedupe_key": s.signalHash, "data": data]],
                                   "context": ["time_zone": TimeZone.current.identifier, "lead_minutes": leadMinutes]]
        guard let json = await Self.post("evaluate", body) else { note("evaluate server unavailable → local rules"); lastRemote = nil; return nil }
        lastRemote = json
        let decision = (json["decision"] as? String) ?? "card"
        return .init(intervene: decision != "silent", why: "\(decision) · \((json["reason"] as? String) ?? "") conf=\((json["confidence"] as? Double).map { String(format: "%.2f", $0) } ?? "-") source=\((json["source"] as? String) ?? "?")", via: "server")
    }
    func rememberServerID(local: String) {
        if let sug = lastRemote?["suggestion"] as? [String: Any], let id = sug["id"] as? String { serverIDs[local] = id }
        else if let id = lastRemote?["event_id"] as? String { serverIDs[local] = id }
    }
    func syncAction(_ action: String, local: String, operationID: String) {
        guard let id = serverIDs[local] else { return }
        Task { let r = await Self.post("suggestions/\(id)/\(action == "undo" ? "undo" : "action")", action == "undo" ? ["operation_id": operationID] : ["action": action, "operation_id": operationID])
            note("server \(action) id=\(id) \(r == nil ? "failed (kept local)" : "recorded")") }
    }

    // MARK: Intervene: card + banner + actionable notification

    private func intervene(_ s: ProactiveSuggestion) {
        #if os(iOS)
        CatpawInAppBannerCenter.shared.show(CatpawInAppBanner(title: s.title, body: s.reason, symbol: "calendar.badge.clock", deepLink: URL(string: "catpawm://proactive")))
        let content = UNMutableNotificationContent()
        content.title = s.title; content.body = s.reason; content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["catpaw_proactive_id": s.id]
        let request = UNNotificationRequest(identifier: s.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            try? await center.add(request)
        }
        note("intervene card + banner + local notification id=\(s.id)")
        if let leave = pendingReminders[s.id]?.leaveAt {
            CatpawLeaveActivity.start(suggestionID: s.id, meetingTitle: pendingReminders[s.id]?.title ?? s.title, leaveAt: leave)
        }
        #endif
    }

    // MARK: Confirmed write (idempotent)

    struct PendingReminder: Codable, Sendable {
        var title: String; var due: Date; var start: Date; var place: String; var operationID: String
        /// leave_at = start - lead_minutes - travel_minutes (nil travel → lead only).
        var leaveAt: Date? = nil
        var leadMinutes: Int = 10
        var travelMinutes: Int? = nil
        /// false when MapKit ETA failed / skipped — Why must say 「未用到 ETA」.
        var usedETA: Bool = false
    }
    private static let attendeesKey = "catpaw.proactive.attendees.v1"
    private var pendingAttendees: [String: (names: [String], recipients: [String])] {
        get {
            guard let data = defaults.data(forKey: Self.attendeesKey),
                  let raw = try? JSONDecoder().decode([String: AttendeesDTO].self, from: data) else { return [:] }
            return raw.mapValues { ($0.names, $0.recipients) }
        }
        set {
            let raw = newValue.mapValues { AttendeesDTO(names: $0.names, recipients: $0.recipients) }
            defaults.set(try? JSONEncoder().encode(raw), forKey: Self.attendeesKey)
        }
    }
    private struct AttendeesDTO: Codable { var names: [String]; var recipients: [String] }
    private var pendingReminders: [String: PendingReminder] {
        get { (defaults.data(forKey: suggestionsKey)).flatMap { try? JSONDecoder().decode([String: PendingReminder].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: suggestionsKey) }
    }

    func pendingReminder(for suggestionID: String) -> PendingReminder? {
        pendingReminders[suggestionID]
    }
    func attendees(for suggestionID: String) -> (names: [String], recipients: [String]) {
        pendingAttendees[suggestionID] ?? ([], [])
    }

    enum WriteOutcome: Equatable { case created(String), alreadyExists(String), denied, failed(String) }

    /// Creates the EKReminder once per operation_id; a second confirm finds the existing one.
    func confirmReminder(_ suggestionID: String) async -> WriteOutcome {
        guard let p = pendingReminders[suggestionID] else { note("confirm unknown suggestion \(suggestionID)"); return .failed("unknown") }
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        let now = EKEventStore.authorizationStatus(for: .reminder)
        guard now == .fullAccess || now == .authorized else { note("write reminders=denied → degrade"); return .denied }
        let marker = URL(string: "catpawm://op/\(p.operationID)")!
        if let existing = await findReminder(marker: marker) {
            note("write idempotent: operation_id=\(p.operationID) already exists → no duplicate")
            return .alreadyExists(existing)
        }
        let r = EKReminder(eventStore: store)
        r.title = "准备：\(p.title)"
        r.notes = "Catpaw 主动提醒 · operation_id=\(p.operationID)" + (p.place.isEmpty ? "" : "\n地点：\(p.place)")
        r.url = marker
        r.calendar = store.defaultCalendarForNewReminders()
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: p.due)
        r.addAlarm(EKAlarm(absoluteDate: p.due))
        do {
            try store.save(r, commit: true)
            note("write EKReminder created operation_id=\(p.operationID) due=\(p.due.formatted(date: .omitted, time: .shortened))")
            return .created(r.calendarItemIdentifier)
        } catch { note("write failed: \(error.localizedDescription)"); return .failed(error.localizedDescription) }
        #else
        return .failed("no EventKit")
        #endif
    }
    #if canImport(EventKit)
    private func findReminder(marker: URL) async -> String? {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [String] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { items in
                c.resume(returning: (items ?? []).filter { $0.url == marker || ($0.notes ?? "").contains(marker.lastPathComponent) }.map(\.calendarItemIdentifier))
            }
        }
        return found.first
    }
    func removeReminder(_ suggestionID: String) async {
        guard let p = pendingReminders[suggestionID], let id = await findReminder(marker: URL(string: "catpawm://op/\(p.operationID)")!),
              let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? store.remove(item, commit: true); note("undo removed reminder operation_id=\(p.operationID)")
    }
    #endif

    func snooze(_ suggestionID: String, minutes: Int = 10) {
        #if os(iOS)
        guard let s = ProactiveSuggestionStore.shared.items[suggestionID] else { return }
        let content = UNMutableNotificationContent()
        content.title = s.title; content.body = s.reason; content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["catpaw_proactive_id": s.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + "-snooze", content: content,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)))
        note("snooze \(minutes) min id=\(s.id)")
        #endif
    }


    // MARK: MapKit travel ETA (transit preferred)

    /// Geocode meeting place → MKDirections.
    /// Origin = real CLLocation When-In-Use, or explicit debug 模拟起点. No silent Shanghai/CBD fallback.
    /// travel > 180 min → invalid → usedETA=false. Why must never claim ETA when unused.
    static func travelETA(
        to place: String,
        from origin: CLLocationCoordinate2D? = nil,
        simulatedLabel: String? = nil
    ) async -> (minutes: Int?, usedETA: Bool, originNote: String?) {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, false, nil) }
        let src: CLLocationCoordinate2D
        let note: String?
        if let origin, let label = simulatedLabel, !label.isEmpty {
            src = origin
            note = "从模拟起点 \(label)"
        } else if let origin, simulatedLabel == nil {
            // Caller passed a real/resolved coordinate (e.g. pipeline location) without a sim label.
            src = origin
            note = nil
        } else if let real = await Self.requestCurrentCoordinate() {
            src = real
            note = nil
        } else {
            return (nil, false, nil)  // no auth / no fix → 未用到 ETA
        }
        do {
            let geocoder = CLGeocoder()
            let marks = try await geocoder.geocodeAddressString(trimmed)
            guard let dest = marks.first?.location?.coordinate else { return (nil, false, note) }
            for mode in [MKDirectionsTransportType.transit, .automobile, .walking] {
                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: src))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
                req.transportType = mode
                req.requestsAlternateRoutes = false
                let directions = MKDirections(request: req)
                guard let resp = try? await directions.calculate(), let route = resp.routes.first else { continue }
                let mins = max(1, Int(route.expectedTravelTime / 60))
                if ProactiveRules.validTravel(mins) == nil { return (nil, false, note) }  // cap: > 180 min → invalid
                return (mins, true, note)
            }
            return (nil, false, note)
        } catch {
            return (nil, false, note)
        }
    }

    /// One-shot When-In-Use location. Returns nil if denied / undetermined (no prompt from background) / timeout.
    static func requestCurrentCoordinate() async -> CLLocationCoordinate2D? {
        #if canImport(CoreLocation) && os(iOS)
        let status = CLLocationManager.authorizationStatus()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        let probe = await MainActor.run { LocationOnceProbe() }
        return await probe.coordinate(timeout: 4)
        #else
        return nil
        #endif
    }

    // MARK: Out-of-app: pre-scheduled notification + BGAppRefresh

    /// Pre-schedules a local notification for the next event (fires even if the app is killed).
    func prescheduleNextEvent() async {
        #if canImport(EventKit) && os(iOS)
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return }
        let now = Date.now, lead = await leadTime()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        guard let e = store.events(matching: predicate).filter({ !$0.isAllDay && $0.startDate > now }).sorted(by: { $0.startDate < $1.startDate }).first else { return }
        let fire = e.startDate.addingTimeInterval(TimeInterval(-(lead.minutes + 5) * 60))
        guard fire > now.addingTimeInterval(60) else { return }
        let signal = ProactiveSignal(
            source: .background,
            eventID: e.calendarItemIdentifier,
            title: e.title ?? "日程",
            start: e.startDate,
            place: e.location ?? ""
        )
        let content = UNMutableNotificationContent()
        content.title = "\(e.startDate.formatted(date: .omitted, time: .shortened)) \(e.title ?? "日程")"
        content.body = "要我提前 \(lead.minutes) 分钟提醒你准备吗？"
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = [
            "catpaw_proactive_id": "evt-" + signal.signalHash,
            "catpaw_proactive_event": e.calendarItemIdentifier,
            "catpaw_proactive_title": signal.title,
            "catpaw_proactive_start": e.startDate.timeIntervalSince1970,
            "catpaw_proactive_due": e.startDate.addingTimeInterval(TimeInterval(-lead.minutes * 60)).timeIntervalSince1970,
            "catpaw_proactive_place": signal.place,
        ]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pre-" + e.calendarItemIdentifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        note("prescheduled notification at \(fire.formatted(date: .omitted, time: .shortened)) for \(e.title ?? "")")
        #endif
    }

    #if os(iOS)
    static var categories: Set<UNNotificationCategory> {
        let isChinese = Locale.current.language.languageCode?.identifier == "zh"
        return [UNNotificationCategory(identifier: notificationCategory, actions: [
            UNNotificationAction(identifier: createAction, title: isChinese ? "创建提醒" : "Create reminder", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "checklist")),
            UNNotificationAction(identifier: laterAction, title: isChinese ? "稍后提醒" : "Snooze", options: [], icon: UNNotificationActionIcon(systemImageName: "clock")),
            UNNotificationAction(identifier: notNowAction, title: isChinese ? "暂不处理" : "Not now", options: [], icon: UNNotificationActionIcon(systemImageName: "xmark"))],
            intentIdentifiers: [], options: [.customDismissAction])]
    }
    /// Notification action → the existing proactive action client. Returns true for every proactive payload,
    /// including malformed/unknown actions, so it can never fall through to an unrelated push action path.
    func handleNotification(actionIdentifier: String, userInfo: [AnyHashable: Any]) async -> Bool {
        let isProactive = userInfo["catpaw_proactive_id"] is String || userInfo["catpaw_proactive_event"] is String
        guard isProactive else { return false }

        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            _ = resolveNotificationSuggestion(userInfo)
            CatpawRouteCenter.shared.pending = .proactive
            return true
        }

        let action: ProactiveSuggestion.Action
        switch actionIdentifier {
        case Self.createAction: action = .create_reminder
        case Self.laterAction: action = .snooze
        case Self.notNowAction: action = .dismiss
        default:
            note("notification ignored action=\(actionIdentifier)")
            return true
        }

        guard let suggestion = resolveNotificationSuggestion(userInfo) else {
            note("notification unresolved suggestion")
            return true
        }
        let suggestions = ProactiveSuggestionStore.shared
        guard !suggestions.busy.contains(suggestion.id),
              suggestion.effectiveStatus == .pending || suggestion.effectiveStatus == .snoozed,
              suggestion.effectiveActions.contains(action) else {
            note("notification ignored unavailable action id=\(suggestion.id)")
            return true
        }
        await ProactiveSuggestionStore.shared.perform(action, suggestion)
        return true
    }

    private func resolveNotificationSuggestion(_ userInfo: [AnyHashable: Any]) -> ProactiveSuggestion? {
        let id = userInfo["catpaw_proactive_id"] as? String
        let context = notificationContext(userInfo)
        let signal = context.map {
            ProactiveSignal(source: .background, eventID: $0.eventID, title: $0.title, start: $0.start, place: $0.place)
        }
        if userInfo["catpaw_proactive_event"] != nil && context == nil { return nil }
        if let id, let signal, id != "evt-" + signal.signalHash { return nil }
        if let id, let suggestion = ProactiveSuggestionStore.shared.items[id] {
            guard pendingReminder(for: id).map({ $0.start > .now }) ?? true else { return nil }
            return suggestion
        }

        guard let signal, let context else { return nil }
        let expectedID = "evt-" + signal.signalHash
        if let existing = ProactiveSuggestionStore.shared.items[expectedID] { return existing }

        // Recover the scheduled meeting without evaluating it or posting another notification. Mark
        // its existing signal as seen so a foreground scan cannot generate a second intervention.
        var seen = ledger
        seen[signal.signalHash] = Date.now.timeIntervalSince1970
        ledger = seen
        var reminders = pendingReminders
        let reminder = reminders[expectedID] ?? PendingReminder(
            title: signal.title, due: context.due, start: signal.start, place: signal.place,
            operationID: "op-" + signal.signalHash
        )
        reminders[expectedID] = reminder
        pendingReminders = reminders
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let suggestion = ProactiveSuggestion(
            id: expectedID,
            title: "\(signal.start.formatted(time)) \(signal.title)",
            reason: "会议即将开始，准备提醒定在 \(reminder.due.formatted(time))",
            actions: [.create_reminder, .snooze, .dismiss],
            signals: [.init(kind: "calendar", text: "\(signal.start.formatted(time)) \(signal.title)")],
            status: .pending, createdAt: .now
        )
        ProactiveLocalBackend.save(suggestion)
        ProactiveSuggestionStore.shared.adopt(suggestion)
        return suggestion
    }

    private func notificationContext(_ userInfo: [AnyHashable: Any]) -> CatpawScheduledMeetingNotification? {
        let now = Date.now
        if let context = CatpawScheduledMeetingNotification(userInfo: userInfo, defaultLeadMinutes: defaultLeadMinutes, now: now) {
            return context
        }
        // Only the legacy event-ID-only format needs an EventKit lookup. Invalid new metadata fails closed.
        guard userInfo["catpaw_proactive_title"] == nil, userInfo["catpaw_proactive_start"] == nil else { return nil }
        guard let eventID = userInfo["catpaw_proactive_event"] as? String, !eventID.isEmpty else { return nil }
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        if (status == .fullAccess || status == .authorized),
           let event = store.calendarItem(withIdentifier: eventID) as? EKEvent {
            var recovered = userInfo
            recovered["catpaw_proactive_title"] = event.title ?? "日程"
            recovered["catpaw_proactive_start"] = event.startDate.timeIntervalSince1970
            recovered["catpaw_proactive_place"] = event.location ?? ""
            return CatpawScheduledMeetingNotification(userInfo: recovered, defaultLeadMinutes: defaultLeadMinutes, now: now)
        }
        #endif
        return nil
    }

    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            Task { @MainActor in
                ProactiveEngine.shared.note("BGAppRefresh fired")
                await ProactiveEngine.shared.scanCalendar(source: .background)
                await ProactiveEngine.shared.prescheduleNextEvent()
                scheduleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }
    static func scheduleBackgroundRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: bgTaskID)
        r.earliestBeginDate = Date.now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    #endif
}

/// Real backend for the suggestion card/inbox: confirm writes the EKReminder.
@MainActor final class ProactiveLocalBackend: ProactiveSuggestionBackend {
    private static let key = "catpaw.proactive.inbox.v1"
    /// Persisted inbox so cards survive relaunch / notification cold start.
    static func save(_ s: ProactiveSuggestion) {
        var all = load(); all[s.id] = s
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
        CatpawWidgetSnapshotWriter.write(Array(all.values))
    }
    static func load() -> [String: ProactiveSuggestion] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: ProactiveSuggestion].self, from: $0) } ?? [:]
    }
    private let mock = ProactiveSuggestionMock([])
    init() { for s in Self.load().values { mock.adopt(s); ProactiveSuggestionStore.shared.adopt(s) } }
    func list() async throws -> [ProactiveSuggestion] { try await mock.list() }
    func perform(_ action: ProactiveSuggestion.Action, on id: String) async throws -> ProactiveSuggestion {
        var s = ProactiveSuggestionStore.shared.items[id] ?? ProactiveSuggestion(id: id, title: "", reason: "")
        switch action {
        case .create_reminder:
            switch await ProactiveEngine.shared.confirmReminder(id) {
            case .created: s.status = .done; s.taken = (s.taken ?? []) + [.init(action: action, at: .now, detail: "已写入提醒事项")]
            case .alreadyExists: s.status = .done; s.taken = (s.taken ?? []) + [.init(action: action, at: .now, detail: "提醒已存在，未重复创建")]
            case .denied: throw ProactiveEngineError.remindersDenied
            case .failed: throw ProactiveEngineError.writeFailed
            }
        case .snooze: ProactiveEngine.shared.snooze(id); s.status = .snoozed; s.taken = (s.taken ?? []) + [.init(action: action, at: .now)]
        case .dismiss:
            CatpawLeaveActivity.stop(suggestionID: id)
            s.status = .dismissed; s.taken = (s.taken ?? []) + [.init(action: action, at: .now)]
        case .notify_attendees:
            // P0-4: MessageUI via DeviceToolRouter — never mark done unless compose was presented and user sent.
            let outcome = await Self.notifyAttendees(for: id)
            switch outcome {
            case .sent:
                s.status = .done
                s.taken = (s.taken ?? []) + [.init(action: action, at: .now, detail: "已发送短信")]
            case .cancelled:
                // Sheet opened then cancelled — stay pending; record evidence without done.
                s.taken = (s.taken ?? []) + [.init(action: action, at: .now, detail: "已打开短信 · 已取消")]
            case .unavailable:
                s.taken = (s.taken ?? []) + [.init(action: action, at: .now, detail: "本机无法发短信（模拟器常见）")]
                mock.adopt(s); Self.save(s)  // persist evidence; stay pending
                throw ProactiveEngineError.smsUnavailable
            case .error:
                s.taken = (s.taken ?? []) + [.init(action: action, at: .now, detail: "短信打开失败")]
                mock.adopt(s); Self.save(s)
                throw ProactiveEngineError.writeFailed
            }
        }
        ProactiveEngine.shared.syncAction(action.rawValue, local: id, operationID: "op-\(id)-\(action.rawValue)")
        mock.adopt(s); Self.save(s); return s
    }
    func undo(_ id: String) async throws -> ProactiveSuggestion {
        CatpawLeaveActivity.stop(suggestionID: id)
        #if canImport(EventKit)
        await ProactiveEngine.shared.removeReminder(id)
        #endif
        var s = ProactiveSuggestionStore.shared.items[id] ?? ProactiveSuggestion(id: id, title: "", reason: "")
        // Keep sent-SMS evidence; undo only rolls back reminder / pending state.
        let kept = (s.taken ?? []).filter { $0.action == .notify_attendees && ($0.detail?.contains("已发送") == true) }
        s.status = .pending
        s.taken = kept
        mock.adopt(s); Self.save(s)
        return s
    }
    func feedback(_ value: ProactiveFeedback, on id: String) async throws { ProactiveEngine.shared.note("feedback \(value.rawValue) id=\(id)") }
}
enum ProactiveEngineError: Error, Equatable { case remindersDenied, writeFailed, smsUnavailable }

extension ProactiveLocalBackend {
    /// Builds a short 「告诉参会人」 draft from the pending meeting and presents MessageUI.
    fileprivate static func notifyAttendees(for suggestionID: String) async -> DeviceToolRouter.NotifyComposeOutcome {
        let pending = ProactiveEngine.shared.pendingReminder(for: suggestionID)
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        let title = pending?.title ?? "会议"
        let start = pending.map { $0.start.formatted(f) } ?? ""
        let place = pending?.place ?? ""
        var lines = ["我可能稍晚到一下（Catpaw 提醒）。", "会议：\(title)" + (start.isEmpty ? "" : " · \(start)")]
        if !place.isEmpty { lines.append("地点：\(place)") }
        if let leaveAt = pending?.leaveAt {
            lines.append("我计划 \(leaveAt.formatted(f)) 出发")
        }
        let attendees = ProactiveEngine.shared.attendees(for: suggestionID)
        if !attendees.names.isEmpty { lines.append("参会人：" + attendees.names.joined(separator: "、")) }
        let body = lines.joined(separator: "\n")
        let recipients = attendees.recipients
        let router = (DeviceCallHub.executor as? DeviceToolRouter) ?? DeviceToolRouter()
        ProactiveEngine.shared.note("notify_attendees present MessageUI suggestion=\(suggestionID) recipients=\(recipients.count)")
        return await router.notifyAttendeesCompose(body: body, recipients: recipients)
    }
}


/// Debug panel / degrade card adapter: simulated meetings go through the same real pipeline.
struct ProactiveEngineSignalAdapter: ProactiveSignalEngine {
    func run(_ input: ProactiveSignalInput, update: @escaping @Sendable (ProactiveStageResult) async -> Void) async -> ProactivePipelineSuggestion? {
        await update(.init(stage: .collect, status: .passed, details: ["meetings=\(input.meetings.count)", "calendar=\(input.calendarAuthorized ? "authorized" : "manual")"]))
        guard let m = input.meetings.filter({ $0.start > input.now }).sorted(by: { $0.start < $1.start }).first else {
            for s in [ProactivePipelineStage.filter, .merge, .decide, .intervene] { await update(.init(stage: s, status: .skipped, details: ["no candidate"])) }
            return nil
        }
        let signal = ProactiveSignal(source: input.calendarAuthorized ? .simulated : .manual, eventID: m.id.uuidString, title: m.title, start: m.start, place: m.place)
        await update(.init(stage: .filter, status: .passed, details: ["next=\(m.title)", "signal_hash=\(signal.signalHash)"]))
        let result = await ProactiveEngine.shared.handle(signal, now: input.now)
        let last = await MainActor.run { ProactiveEngine.shared.log.first?.text ?? "" }
        await update(.init(stage: .merge, status: result == nil ? .skipped : .passed, details: [last]))
        await update(.init(stage: .decide, status: result == nil ? .skipped : .passed, details: result.map { [$0.reason] } ?? ["suppressed / silent"]))
        await update(.init(stage: .intervene, status: result == nil ? .skipped : .passed, details: result == nil ? [] : ["card + banner + notification"]))
        return result.map { ProactivePipelineSuggestion(id: $0.id, kind: "meeting_prep", title: $0.title, body: $0.reason, channel: .push, meetingTitle: m.title, meetingStart: m.start, place: m.place, leaveAt: nil) }
    }
}


/// #48: App Group snapshot for the Home/Lock widgets. The widget reads the same JSON (`catpaw.widget.snapshot.v1.json`);
/// without the App Group entitlement (`group.com.yankj.catpawm`, needs portal registration) the container is nil,
/// nothing is written and the widget shows its truthful empty state.
@MainActor enum CatpawWidgetSnapshotWriter {
    static let group = "group.com.yankj.catpawm"
    static let file = "catpaw.widget.snapshot.v1.json"
    static func write(_ suggestions: [ProactiveSuggestion]) {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let now = Date.now
        let pending = suggestions
            .filter {
                $0.effectiveStatus == .pending &&
                (ProactiveEngine.shared.pendingReminder(for: $0.id).map { $0.start > now } ?? true)
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                return $0.id < $1.id
            }

        var body: [String: Any] = [
            "version": 2,
            "updated_at": now.timeIntervalSince1970,
        ]
        if let suggestion = pending.first {
            var value: [String: Any] = [
                "id": suggestion.id,
                "title": suggestion.title,
                "why": suggestion.reason,
            ]
            if let reminder = ProactiveEngine.shared.pendingReminder(for: suggestion.id) {
                value["expires_at"] = reminder.start.timeIntervalSince1970
            }
            body["suggestion"] = value
        }

        let meetings: [(suggestion: ProactiveSuggestion, signal: ProactiveSuggestion.Signal, reminder: ProactiveEngine.PendingReminder?)] = pending.compactMap { suggestion in
            guard let signal = suggestion.signals?.first(where: { $0.kind == "calendar" }) else { return nil }
            return (suggestion, signal, ProactiveEngine.shared.pendingReminder(for: suggestion.id))
        }
        let meeting = meetings.min { lhs, rhs in
            if let left = lhs.reminder?.start, let right = rhs.reminder?.start { return left < right }
            if lhs.reminder != nil { return true }
            if rhs.reminder != nil { return false }
            return (lhs.suggestion.createdAt ?? .distantFuture) < (rhs.suggestion.createdAt ?? .distantFuture)
        }
        if let meeting {
            var value: [String: Any] = [
                "id": meeting.suggestion.id,
                "title": meeting.reminder?.title ?? meeting.signal.text,
                "why": meeting.suggestion.reason,
            ]
            if let reminder = meeting.reminder {
                value["starts_at"] = reminder.start.timeIntervalSince1970
                if !reminder.place.isEmpty { value["place"] = reminder.place }
            }
            body["meeting"] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
}


#if canImport(CoreLocation) && os(iOS)
/// Single-fix CLLocationManager wrapper for travelETA origin.
@MainActor private final class LocationOnceProbe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var authCont: CheckedContinuation<Bool, Never>?
    func requestWhenInUse() async -> Bool {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { cont in
            self.authCont = cont
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }
    func coordinate(timeout: TimeInterval) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            self.cont = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish(nil)
            }
        }
    }
    private func finish(_ c: CLLocationCoordinate2D?) {
        guard let cont else { return }
        self.cont = nil
        cont.resume(returning: c)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined, let authCont else { return }
        self.authCont = nil
        authCont.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
    }
}
#endif

#if canImport(ActivityKit) && os(iOS)


@MainActor enum CatpawLeaveActivity {
    static func start(suggestionID: String, meetingTitle: String, leaveAt: Date) {
        CatpawLiveActivityCoordinator.shared.startLeaveCountdown(suggestionID: suggestionID, meetingTitle: meetingTitle, leaveAt: leaveAt)
    }
    static func stop(suggestionID: String) {
        CatpawLiveActivityCoordinator.shared.stopLeaveCountdown(suggestionID: suggestionID)
    }
}
#else
@MainActor enum CatpawLeaveActivity {
    static func start(suggestionID: String, meetingTitle: String, leaveAt: Date) {}
    static func stop(suggestionID: String) {}
}
#endif

