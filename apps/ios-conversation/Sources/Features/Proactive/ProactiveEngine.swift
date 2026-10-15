import Foundation
import CryptoKit
import Observation
#if canImport(EventKit)
import EventKit
#endif
#if os(iOS)
import UIKit
import UserNotifications
import BackgroundTasks
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
    /// Stable per (event, start): the same meeting never triggers twice.
    var signalHash: String {
        let raw = "\(eventID)|\(Int(start.timeIntervalSince1970))"
        return SHA256.hash(data: Data(raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor @Observable final class ProactiveEngine {
    static let shared = ProactiveEngine()
    static let notificationCategory = "CATPAW_PROACTIVE"
    static let createAction = "CATPAW_PROACTIVE_CREATE", laterAction = "CATPAW_PROACTIVE_LATER"
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
    func leadTime() async -> (minutes: Int, memory: ProactiveSuggestion.MemoryRef?) {
        guard let backend = MemoryLibraryHub.backend, let snapshot = try? await backend.load(), snapshot.useMemory else { return (defaultLeadMinutes, nil) }
        for item in snapshot.items {
            let text = item.content
            if let r = text.range(of: #"提前\s*(\d{1,3})\s*分钟"#, options: .regularExpression) ?? text.range(of: #"(\d{1,3})\s*min(ute)?s? (early|ahead)"#, options: .regularExpression),
               let n = Int(text[r].filter(\.isNumber)), n > 0, n <= 180 {
                return (n, .init(id: item.id, content: text))
            }
        }
        return (defaultLeadMinutes, nil)
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
        await handle(.init(source: source, eventID: event.calendarItemIdentifier, title: event.title ?? "日程", start: event.startDate, place: event.location ?? ""))
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
        guard minutes > 0, minutes <= 180 else { note("filter drop: starts in \(Int(minutes)) min (window 0–180)"); return nil }
        // Dedupe ledger
        let hash = signal.signalHash
        if let seen = ledger[hash] {
            note("dedupe SUPPRESSED duplicate signal_hash=\(hash) (first seen \(Date(timeIntervalSince1970: seen).formatted(date: .omitted, time: .shortened)))")
            return nil
        }
        var l = ledger; l[hash] = now.timeIntervalSince1970; ledger = l
        note("dedupe new signal_hash=\(hash)")
        // Evaluate
        let lead = await leadTime()
        let remindAt = signal.start.addingTimeInterval(TimeInterval(-lead.minutes * 60))
        let decision = await evaluateRemote(signal, leadMinutes: lead.minutes) ?? evaluateLocal(signal, leadMinutes: lead.minutes, now: now)
        guard decision.intervene else { note("decide silent: \(decision.why)"); return nil }
        note("decide intervene (\(decision.via)): \(decision.why)")
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        var memories: [ProactiveSuggestion.MemoryRef] = []
        if let m = lead.memory { memories.append(m) }
        let suggestion = ProactiveSuggestion(
            id: "evt-" + hash,
            title: "\(signal.start.formatted(f)) \(signal.title) · 要我 \(remindAt.formatted(f)) 提醒你吗？",
            reason: lead.memory != nil ? "你习惯提前 \(lead.minutes) 分钟准备，所以提醒定在 \(remindAt.formatted(f))" : "会议 \(Int(minutes)) 分钟后开始，默认提前 \(lead.minutes) 分钟提醒",
            memories: memories, actions: [.create_reminder, .snooze, .dismiss],
            signals: [.init(kind: signal.source == .eventKit || signal.source == .background ? "calendar" : signal.source.rawValue,
                            text: "\(signal.start.formatted(f)) \(signal.title)\(signal.place.isEmpty ? "" : " · " + signal.place)"),
                      .init(kind: "time", text: "现在 \(now.formatted(f))"), .init(kind: "rule", text: "signal_hash=\(hash)")],
            status: .pending, createdAt: now)
        pendingReminders[suggestion.id] = .init(title: signal.title, due: remindAt, start: signal.start, place: signal.place, operationID: "op-" + hash)
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
    private func evaluateRemote(_ s: ProactiveSignal, leadMinutes: Int) async -> Decision? {
        let minutes = Int(s.start.timeIntervalSince(.now) / 60)
        let body: [String: Any] = ["signals": [["type": "meeting_upcoming", "source": s.source.rawValue, "dedupe_key": s.signalHash,
                                                "data": ["title": s.title, "location": s.place, "minutes_until": minutes, "travel_minutes": 0]]],
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
        #endif
    }

    // MARK: Confirmed write (idempotent)

    struct PendingReminder: Codable, Sendable { var title: String; var due: Date; var start: Date; var place: String; var operationID: String }
    private var pendingReminders: [String: PendingReminder] {
        get { (defaults.data(forKey: suggestionsKey)).flatMap { try? JSONDecoder().decode([String: PendingReminder].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: suggestionsKey) }
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
        let content = UNMutableNotificationContent()
        content.title = "\(e.startDate.formatted(date: .omitted, time: .shortened)) \(e.title ?? "日程")"
        content.body = "要我提前 \(lead.minutes) 分钟提醒你准备吗？"
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["catpaw_proactive_event": e.calendarItemIdentifier]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pre-" + e.calendarItemIdentifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        note("prescheduled notification at \(fire.formatted(date: .omitted, time: .shortened)) for \(e.title ?? "")")
        #endif
    }

    #if os(iOS)
    static var categories: Set<UNNotificationCategory> {
        let lang = AppLanguage(locale: .current)
        return [UNNotificationCategory(identifier: notificationCategory, actions: [
            UNNotificationAction(identifier: createAction, title: lang.ui("创建提醒"), options: [], icon: UNNotificationActionIcon(systemImageName: "checklist")),
            UNNotificationAction(identifier: laterAction, title: lang.ui("稍后"), options: [], icon: UNNotificationActionIcon(systemImageName: "clock"))],
            intentIdentifiers: [], options: [.customDismissAction])]
    }
    /// Notification action → confirm / snooze. Returns true if handled.
    func handleNotification(actionIdentifier: String, userInfo: [AnyHashable: Any]) async -> Bool {
        if let eventID = userInfo["catpaw_proactive_event"] as? String {
            // Pre-scheduled notification: rebuild the signal from EventKit, then act.
            await scanCalendar(source: .background)
            _ = eventID
            if actionIdentifier == Self.createAction, let id = lastSuggestionID { await act(.create_reminder, id) }
            return true
        }
        guard let id = userInfo["catpaw_proactive_id"] as? String else { return false }
        switch actionIdentifier {
        case Self.createAction: await act(.create_reminder, id)
        case Self.laterAction: await act(.snooze, id)
        case UNNotificationDefaultActionIdentifier: CatpawRouteCenter.shared.pending = .proactive
        default: break
        }
        return true
    }
    private func act(_ action: ProactiveSuggestion.Action, _ id: String) async {
        guard let s = ProactiveSuggestionStore.shared.items[id] else { return }
        await ProactiveSuggestionStore.shared.perform(action, s)
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
        case .dismiss: s.status = .dismissed; s.taken = (s.taken ?? []) + [.init(action: action, at: .now)]
        case .notify_attendees: s.status = .done; s.taken = (s.taken ?? []) + [.init(action: action, at: .now)]
        }
        ProactiveEngine.shared.syncAction(action.rawValue, local: id, operationID: "op-\(id)-\(action.rawValue)")
        mock.adopt(s); Self.save(s); return s
    }
    func undo(_ id: String) async throws -> ProactiveSuggestion {
        #if canImport(EventKit)
        await ProactiveEngine.shared.removeReminder(id)
        #endif
        var s = ProactiveSuggestionStore.shared.items[id] ?? ProactiveSuggestion(id: id, title: "", reason: ""); s.status = .pending; s.taken = []; return s
    }
    func feedback(_ value: ProactiveFeedback, on id: String) async throws { ProactiveEngine.shared.note("feedback \(value.rawValue) id=\(id)") }
}
enum ProactiveEngineError: Error { case remindersDenied, writeFailed }

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
