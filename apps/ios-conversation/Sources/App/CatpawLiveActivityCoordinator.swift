import Foundation
import Combine

/// r11: single source of truth for the header cat head + Live Activity step text, fed by turn events.
@MainActor final class CatpawPresenceHub: ObservableObject {
    static let shared = CatpawPresenceHub()
    /// nil = idle (header shows a calm cat head that blinks occasionally).
    @Published private(set) var state: CatpawPresenceState?
    @Published private(set) var step: String = ""
    private var settle: Task<Void, Never>?
    func set(_ state: CatpawPresenceState?, step: String) {
        settle?.cancel()
        self.state = state; self.step = step
        if state == .done || state == .error {
            settle = Task { [weak self] in
                try? await Task.sleep(nanoseconds: (state == .done ? 2_200 : 4_000) * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.state = nil; self?.step = ""
            }
        }
    }
}

/// chat-ux-1505 #4a: pure turn-event → Live Activity phase mapping (unit-tested). Every stage transition maps to a phase,
/// including the ones that used to be dropped (approval / device call / suspended → 等你确认; approval resolved → working).
enum CatpawWorkPhase: Equatable {
    case thinking, tool(String), awaitingUser, writing, done, failed
    /// nil = event does not change the activity.
    static func from(_ payload: ConversationTurnEvent.Payload) -> CatpawWorkPhase? {
        switch payload {
        case .started, .reasoningSummary: return .thinking
        case .toolStarted(_, let name, _): return .tool(name)
        case .deviceCall(let call): return call.confirm == "none" || DeviceToolContract.autoRunReadOnlyTools.contains(call.tool) ? .tool(call.tool) : .awaitingUser
        case .approvalRequested: return .awaitingUser
        // PREREVIEW B1/P2-3: the server suspends for every interrupt, including confirm:"none" device calls; the
        // answerable ones already arrived as approvalRequested / card deviceCall, so suspended alone changes nothing.
        case .suspended: return nil
        case .approvalResolved, .toolResult: return .thinking
        case .textDelta, .textPreview: return .writing   // live text is the answer appearing (the hub / activity dedupe .writing)
        case .completed: return .done
        case .failed: return .failed
        default: return nil
        }
    }
    /// `CatpawWorkAttributes.ContentState.kind` string (Sources/Shared, shared with the widget).
    var kind: String {
        switch self {
        case .thinking: return "thinking"
        case .tool: return "tool"
        case .awaitingUser: return "needs_user"
        case .writing: return "writing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
    var isTerminal: Bool { self == .done || self == .failed }
    /// UIStrings key + arguments for the body line. Known tools get a human step (「正在查日历」), never a raw tool id.
    var bodyKey: (key: String, arguments: [String]) {
        switch self {
        case .thinking: return ("正在思考…", [])
        case .tool(let name): return (ToolStepCopy.short(name), [])   // one table (status-line SPEC §9); unknown → 正在处理
        case .awaitingUser: return ("等你确认", [])
        case .writing: return ("正在整理回答…", [])
        case .done: return ("已完成", [])
        case .failed: return ("未完成，需核对", [])
        }
    }
    /// Localised Live Activity body. Tool copy comes straight from ToolStepCopy (zh/en columns), other phases from UIStrings.
    func body(_ language: AppLanguage) -> String {
        if case .tool(let name) = self { return ToolStepCopy.short(name, en: language == .english) }
        return language.ui(bodyKey.key, arguments: bodyKey.arguments)
    }
}
/// v1.1: the Live Activity title is the user's own task — first non-empty line of the user message, whitespace collapsed,
/// trimmed to ~20 characters. Only the typed text is used (never tool names / arguments); nil → widget generic title.
/// R2 (NoBug P1-2): emails, URLs and phone-like digit runs (6+ digits, spaces / dashes allowed) are masked BEFORE the cut,
/// so a contact never reaches the lock screen / Dynamic Island; the widget also marks the title `.privacySensitive()`.
enum CatpawTaskTitle {
    static let limit = 20
    static let mask = "•••"
    static func make(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }).first(where: { !$0.isEmpty }) else { return nil }
        let masked = redact(line)
        return masked.count <= limit ? masked : String(masked.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
    /// R3 (NoBug P2-R2-1): matching runs on the NFKC form (full-width ＠ / － / digits fold to ASCII); separators also
    /// cover dashes (‐‑‒–—―), dots (. · ・). Matches are mapped back per character, so only the masked spans change —
    /// the rest of the title keeps its own characters (full-width Chinese punctuation stays full-width).
    static let patterns = [#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,                       // email
                           #"(?i)(?:https?://|www\.)\S+"#,                                           // URL
                           #"\+?\d(?:[ \-‐‑‒–—―.·・]?\d){5,}(?:[Xx](?![A-Za-z]))?"#]                  // 6+ digits: phone / card / id numbers
    static func redact(_ s: String) -> String {
        let orig = Array(s)
        var norm = "", starts: [Int] = []   // UTF-16 offset in `norm` where orig[i]'s NFKC form begins
        for c in orig { starts.append(norm.utf16.count); norm += String(c).precomposedStringWithCompatibilityMapping }
        let length = norm.utf16.count
        var hit = [Bool](repeating: false, count: orig.count)
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: norm, range: NSRange(location: 0, length: length)) where m.range.length > 0 {
                let lo = m.range.location, hi = m.range.location + m.range.length
                for i in orig.indices where starts[i] < hi && (i + 1 < orig.count ? starts[i + 1] : length) > lo { hit[i] = true }
            }
        }
        var out = "", i = 0
        while i < orig.count {
            if hit[i] { out += mask; while i < orig.count && hit[i] { i += 1 } } else { out.append(orig[i]); i += 1 }
        }
        return out
    }
}

/// Hand-off from the send path (operation id = turn id) to the Live Activity coordinator.
@MainActor enum CatpawTaskTitles {
    private static var pending: [UUID: String] = [:]
    static func note(_ text: String, operationID: UUID) {
        if pending.count > 32 { pending.removeAll() }   // bounded: a turn that never starts must not leak titles
        pending[operationID] = CatpawTaskTitle.make(text)
    }
    static func take(_ operationID: UUID) -> String? { pending.removeValue(forKey: operationID) }
    static func reset() { pending.removeAll() }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import UIKit

/// Drives the `CatpawWorkAttributes` Live Activity (lock screen + Dynamic Island) from
/// `ConversationSessionService.turnEvents()`.
/// - start: a `delegate_*` tool starts, or a turn is still running after `longTurnThreshold`
/// - update: every tool call / result, reasoning summary, first answer text
/// - end: `completed` → `.done`, `failed` → `.failed`
/// Requested with `pushType: .token`; each token → `PUT /devices/tokens {kind: live_activity_update, activity_id}`.
@MainActor final class CatpawLiveActivityCoordinator {
    static let shared = CatpawLiveActivityCoordinator()
    static let longTurnThreshold: TimeInterval = 5
    private static let longTaskTools: Set<String> = ["delegate_task", "delegate_plan_v1"]

    private struct Turn {
        var conversationID: String
        var startedAt = Date()
        var step = 0
        var body: String
        var activity: Activity<CatpawWorkAttributes>?
        var timer: Task<Void, Never>?
        var answering = false
        var kind = CatpawWorkAttributes.ContentState.Kind.thinking
        var token = AccountEpoch.shared.capture()   // Codex PR91 p91c-3: account the turn started under
        /// chat-ux-1505 #4a: ActivityKit updates are chained so they land in event order (separate `Task {update}`s
        /// could apply an older state last and leave the lock screen on 「正在思考…」).
        var lastUpdate: Task<Void, Never>?
        var tool: String?
        var summary: String?
    }
    private var turns: [UUID: Turn] = [:]
    private var tokenObservers: [String: Task<Void, Never>] = [:]

    private func ui(_ key: String, _ arguments: [String] = []) -> String { AppLanguage(locale: .current).ui(key, arguments: arguments) }

    /// Runs until the calling task is cancelled (attach with SwiftUI `.task`).
    /// `taskText`: the conversation's latest user message, read once when a turn starts — it becomes the activity title.
    func observe(_ service: ConversationSessionService, conversationID: @escaping @MainActor () -> UUID?,
                 taskText: @escaping @MainActor () -> String? = { nil }) async {
        observePushToStartTokens()
        let stream = await service.turnEvents()
        for await event in stream {
            if Task.isCancelled { break }
            var text: String? = nil
            if case .started = event.payload { text = taskText() }
            handle(event, conversationID: conversationID(), taskText: text)
        }
    }

    /// Lock-screen / Dynamic Island title from the user's own words: first non-empty line, whitespace collapsed, at most
    /// `taskTitleLimit` characters (then 「…」). Nil for empty input → the widget's 「Catpaw 正在处理」 fallback.
    /// v1.1 R2: one title rule for both paths — CatpawTaskTitle (masking before the cut, 20 characters).
    static let taskTitleLimit = CatpawTaskTitle.limit
    nonisolated static func taskTitle(_ raw: String?) -> String? { raw.flatMap(CatpawTaskTitle.make) }

    func handle(_ event: ConversationTurnEvent, conversationID: UUID?, taskText: String? = nil) {
        let id = event.operationID
        guard let phase = CatpawWorkPhase.from(event.payload) else { return }
        let body = phase.body(AppLanguage(locale: .current))
        let hub = CatpawPresenceHub.shared
        switch phase {
        case .thinking: hub.set(hub.state == nil ? .waiting : .thinking, step: body)
        case .tool: hub.set(.working, step: body)
        case .awaitingUser: hub.set(.waiting, step: body)
        case .writing: if hub.state != .streaming { hub.set(.streaming, step: body) }
        case .done: hub.set(.done, step: body)
        case .failed: hub.set(.error, step: body)
        }
        if case .started = event.payload, turns[id] == nil {
            var turn = Turn(conversationID: conversationID?.uuidString ?? "", body: body)
            turn.summary = CatpawTaskTitles.take(id) ?? Self.taskTitle(taskText)   // per-operation note first, else the latest user message
            turn.timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.longTurnThreshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.startIfNeeded(id)
            }
            turns[id] = turn
            return
        }
        if phase.isTerminal { finish(id, kind: phase.kind, title: body); return }
        if case .writing = phase, turns[id]?.answering == true { return }   // one update per answer, not per token
        ensureTracked(id, conversationID: conversationID)
        mutate(id) {
            if case .tool(let name) = phase { $0.step += 1; $0.tool = name }
            if case .writing = phase { $0.answering = true }
            $0.kind = phase.kind; $0.body = body
        }
        if case .tool(let name) = phase, Self.longTaskTools.contains(name) { startIfNeeded(id) }
        // Waiting on the user (device call / approval) is exactly when the lock screen matters: show it now.
        if phase == .awaitingUser { startIfNeeded(id) }
    }

    private func ensureTracked(_ id: UUID, conversationID: UUID?) {
        if turns[id] == nil {
            var turn = Turn(conversationID: conversationID?.uuidString ?? "", body: ui("正在思考…"))
            turn.summary = CatpawTaskTitles.take(id)
            turns[id] = turn
        }
    }

    /// Exactly the backend `content-state` shape `{title, body, kind, taskID}`.
    private func state(_ id: UUID, _ turn: Turn, _ kind: String, endedAt: Date? = nil) -> CatpawWorkAttributes.ContentState {
        // ux-round-1505: startedAt drives the on-device timer, step = honest dot count, tool → spoken verb in the widget.
        // summary = the user's task text (CatpawTaskTitles, else the latest user message), masked; nil → widget generic title.
        .init(title: ui("Catpaw 正在工作"), body: turn.body, kind: kind, taskID: id.uuidString,
              startedAt: turn.startedAt, endedAt: endedAt, step: turn.step > 0 ? turn.step : nil, tool: turn.tool, summary: turn.summary)
    }

    private func mutate(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard var turn = turns[id] else { return }
        change(&turn); turns[id] = turn
        guard let activity = turn.activity else { return }
        let content = ActivityContent(state: state(id, turn, turn.kind), staleDate: Date().addingTimeInterval(120))
        let previous = turn.lastUpdate
        turns[id]?.lastUpdate = Task { await previous?.value; await activity.update(content, alertConfiguration: nil) }   // local step updates never alert
    }

    private func startIfNeeded(_ id: UUID) {
        guard var turn = turns[id], turn.activity == nil, !turn.conversationID.isEmpty else { return }
        guard turn.token != nil, AccountEpoch.shared.isValid(turn.token) else { turns[id] = nil; return }   // signed out / switched: never request
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = CatpawWorkAttributes(taskID: id.uuidString, conversationID: turn.conversationID, title: ui("Catpaw 正在工作"))
        do {
            let content = ActivityContent(state: state(id, turn, turn.kind), staleDate: Date().addingTimeInterval(120))
            if let activity = try? Activity.request(attributes: attributes, content: content, pushType: .token) {
                turn.activity = activity; turns[id] = turn
                observeToken(activity, turnID: id, conversationID: turn.conversationID)
            } else {
                // No aps-environment (simulator / unsigned trial build): run a local-only activity driven by in-app updates.
                turn.activity = try Activity.request(attributes: attributes, content: content, pushType: nil); turns[id] = turn
            }
        } catch {
            // Disabled by the user / system budget: the in-app UI remains the source of truth.
        }
    }

    /// Codex PR91 p91b-3: sign-out. Cancels every pending 5 s start timer (so no `Activity.request` fires after sign-out),
    /// drops tracked turns and token observers, and ends every work activity — including ones from before a relaunch.
    func resetForSignOut() {
        CatpawTaskTitles.reset()
        for turn in turns.values { turn.timer?.cancel() }
        turns.removeAll()
        for task in tokenObservers.values { task.cancel() }
        tokenObservers.removeAll()
        let ending = Activity<CatpawWorkAttributes>.activities
        Task { for a in ending { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    private var pushToStartObserver: Task<Void, Never>?
    /// Push-to-start (iOS 17.2+): lets the server start a Live Activity, e.g. for `reminder_due`.
    private func observePushToStartTokens() {
        guard pushToStartObserver == nil else { return }
        if #available(iOS 17.2, *) {
            pushToStartObserver = Task {
                for await data in Activity<CatpawWorkAttributes>.pushToStartTokenUpdates {
                    await CatpawPushTokenUploader.shared.enqueue(.init(kind: .liveActivityStart, token: data))
                }
            }
        }
    }

    private func observeToken(_ activity: Activity<CatpawWorkAttributes>, turnID: UUID, conversationID: String) {
        let activityID = activity.id
        tokenObservers[activityID] = Task {
            for await data in activity.pushTokenUpdates {
                await CatpawPushTokenUploader.shared.enqueue(.init(kind: .liveActivityUpdate, token: data, activityID: activityID))
            }
        }
    }

    /// R2 (NoBug P1-2): every ended turn (done, failed, stopped) lingers 2 min, then the system removes it — the task
    /// title must not outlive the task on the lock screen (was 15 min for failed / stopped).
    static let endedLinger: TimeInterval = 2 * 60
    static func dismissAfter(kind: String) -> TimeInterval { endedLinger }

    /// chat-ux-1505 #4a: background / relaunch. (1) While an activity is live, ask for background time so the SSE can
    /// deliver the next stages (and the end) after the user locks the phone. (2) On launch / foreground, end activities
    /// no tracked turn owns (app was killed mid-turn) instead of leaving 「正在思考…」 on the lock screen for hours.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    func sceneDidEnterBackground() {
        guard backgroundTask == .invalid, turns.values.contains(where: { $0.activity != nil }) else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "catpaw.liveActivity") { [weak self] in self?.endBackgroundTask() }
    }
    func sceneDidBecomeActive() { endBackgroundTask(); endOrphanedActivities() }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    func endOrphanedActivities() {
        let owned = Set(turns.values.compactMap { $0.activity?.id })
        for activity in Activity<CatpawWorkAttributes>.activities where !owned.contains(activity.id) && activity.activityState == .active {
            let final = CatpawWorkAttributes.ContentState(title: ui("Catpaw 正在工作"), body: ui("打开 Catpaw 查看结果"), kind: CatpawWorkAttributes.ContentState.Kind.needsUser, taskID: activity.attributes.taskID)
            Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60))) }
        }
    }

    private func finish(_ id: UUID, kind: String, title: String) {
        guard var turn = turns.removeValue(forKey: id) else { return }
        turn.timer?.cancel()
        guard let activity = turn.activity else { if turns.values.allSatisfy({ $0.activity == nil }) { endBackgroundTask() }; return }
        turn.body = title
        let content = ActivityContent(state: state(id, turn, kind, endedAt: Date()), staleDate: nil)
        let activityID = activity.id
        tokenObservers.removeValue(forKey: activityID)?.cancel()
        let previous = turn.lastUpdate
        Task {
            await previous?.value   // the final state must land after every pending update
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(Self.dismissAfter(kind: kind))))
            await CatpawPushTokenUploader.shared.forgetActivity(activityID)
            await MainActor.run { if self.turns.values.allSatisfy({ $0.activity == nil }) { self.endBackgroundTask() } }
        }
    }

    /// Simulator acceptance: start → update → end a local Live Activity when `CATPAW_ACCEPTANCE_LIVE_ACTIVITY=1`.
    /// No-op when Live Activities are disabled by the system.


    // MARK: Proactive leave_at countdown (isolated from chat-turn LA)

    private var leaveActivities: [String: Activity<CatpawLeaveAttributes>] = [:]

    /// Start / refresh a leave_at Live Activity for a proactive card. No-op when ActivityKit unavailable.
    func startLeaveCountdown(suggestionID: String, meetingTitle: String, leaveAt: Date) {
        #if canImport(ActivityKit) && os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let minutes = max(0, Int(leaveAt.timeIntervalSinceNow / 60))
        let state = CatpawLeaveAttributes.ContentState(title: "该出发了", leaveAt: leaveAt, minutesLeft: minutes, meetingTitle: meetingTitle)
        let attrs = CatpawLeaveAttributes(suggestionID: suggestionID, meetingTitle: meetingTitle)
        if let existing = leaveActivities[suggestionID] {
            Task { await existing.update(ActivityContent(state: state, staleDate: leaveAt.addingTimeInterval(600))) }
            return
        }
        do {
            let activity = try Activity.request(attributes: attrs, content: ActivityContent(state: state, staleDate: leaveAt.addingTimeInterval(600)), pushType: nil)
            leaveActivities[suggestionID] = activity
        } catch {
            print("catpaw.leaveLA start failed \(error)")
        }
        #endif
    }

    func stopLeaveCountdown(suggestionID: String) {
        #if canImport(ActivityKit) && os(iOS)
        var targets: [Activity<CatpawLeaveAttributes>] = []
        if let cached = leaveActivities.removeValue(forKey: suggestionID) { targets.append(cached) }
        // Process may have restarted — also scan system Activity.activities by suggestionID.
        for a in Activity<CatpawLeaveAttributes>.activities where a.attributes.suggestionID == suggestionID {
            if !targets.contains(where: { $0.id == a.id }) { targets.append(a) }
            leaveActivities.removeValue(forKey: suggestionID)
        }
        for activity in targets {
            let final = CatpawLeaveAttributes.ContentState(title: "已结束", leaveAt: .now, minutesLeft: 0, meetingTitle: activity.attributes.meetingTitle)
            Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate) }
        }
        #endif
    }

    func acceptanceProbe() async {
        #if DEBUG || DEVICE_TRIAL
        guard ProcessInfo.processInfo.environment["CATPAW_ACCEPTANCE_LIVE_ACTIVITY"] == "1" else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let id = UUID()
        turns[id] = Turn(conversationID: "acceptance", body: ui("正在思考…"))
        startIfNeeded(id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        mutate(id) { $0.kind = CatpawWorkAttributes.ContentState.Kind.writing; $0.body = self.ui("正在整理回答…") }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        finish(id, kind: CatpawWorkAttributes.ContentState.Kind.done, title: ui("已完成"))
        #endif
    }
}
#endif
