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
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

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
    }
    private var turns: [UUID: Turn] = [:]
    private var tokenObservers: [String: Task<Void, Never>] = [:]

    private func ui(_ key: String, _ arguments: [String] = []) -> String { AppLanguage(locale: .current).ui(key, arguments: arguments) }

    /// Runs until the calling task is cancelled (attach with SwiftUI `.task`).
    func observe(_ service: ConversationSessionService, conversationID: @escaping @MainActor () -> UUID?) async {
        observePushToStartTokens()
        let stream = await service.turnEvents()
        for await event in stream {
            if Task.isCancelled { break }
            handle(event, conversationID: conversationID())
        }
    }

    func handle(_ event: ConversationTurnEvent, conversationID: UUID?) {
        let id = event.operationID
        let hub = CatpawPresenceHub.shared
        switch event.payload {
        case .started: hub.set(.waiting, step: ui("正在思考…"))
        case .reasoningSummary: hub.set(.thinking, step: ui("正在思考…"))
        case .toolStarted(_, let name, _): hub.set(.working, step: ui("正在调用工具：{0}", [name]))
        case .toolResult: hub.set(.thinking, step: ui("正在思考…"))
        case .textDelta: if hub.state != .streaming { hub.set(.streaming, step: ui("正在整理回答…")) }
        case .completed: hub.set(.done, step: ui("已完成"))
        case .failed: hub.set(.error, step: ui("未完成，需核对"))
        default: break
        }
        switch event.payload {
        case .started:
            guard turns[id] == nil else { return }
            var turn = Turn(conversationID: conversationID?.uuidString ?? "", body: ui("正在思考…"))
            turn.timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.longTurnThreshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.startIfNeeded(id)
            }
            turns[id] = turn
        case .reasoningSummary:
            mutate(id) { $0.kind = CatpawWorkAttributes.ContentState.Kind.thinking; $0.body = self.ui("正在思考…") }
        case .toolStarted(_, let name, _):
            ensureTracked(id, conversationID: conversationID)
            mutate(id) { $0.step += 1; $0.kind = CatpawWorkAttributes.ContentState.Kind.tool; $0.body = self.ui("正在调用工具：{0}", [name]) }
            if Self.longTaskTools.contains(name) { startIfNeeded(id) }
        case .toolResult(let result):
            mutate(id) { $0.kind = CatpawWorkAttributes.ContentState.Kind.thinking; $0.body = self.ui("工具已返回：{0}", [result.name]) }
        case .textDelta:
            guard turns[id]?.answering == false else { return }
            mutate(id) { $0.answering = true; $0.kind = CatpawWorkAttributes.ContentState.Kind.writing; $0.body = self.ui("正在整理回答…") }
        case .completed:
            finish(id, kind: CatpawWorkAttributes.ContentState.Kind.done, title: ui("已完成"))
        case .failed:
            finish(id, kind: CatpawWorkAttributes.ContentState.Kind.failed, title: ui("未完成，需核对"))
        default:
            break
        }
    }

    private func ensureTracked(_ id: UUID, conversationID: UUID?) {
        if turns[id] == nil { turns[id] = Turn(conversationID: conversationID?.uuidString ?? "", body: ui("正在思考…")) }
    }

    /// Exactly the backend `content-state` shape `{title, body, kind, taskID}`.
    private func state(_ id: UUID, _ turn: Turn, _ kind: String) -> CatpawWorkAttributes.ContentState {
        .init(title: ui("Catpaw 正在工作"), body: turn.body, kind: kind, taskID: id.uuidString)
    }

    private func mutate(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard var turn = turns[id] else { return }
        change(&turn); turns[id] = turn
        guard let activity = turn.activity else { return }
        let content = ActivityContent(state: state(id, turn, turn.kind), staleDate: Date().addingTimeInterval(120))
        Task { await activity.update(content) }
    }

    private func startIfNeeded(_ id: UUID) {
        guard var turn = turns[id], turn.activity == nil, !turn.conversationID.isEmpty else { return }
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

    private func finish(_ id: UUID, kind: String, title: String) {
        guard var turn = turns.removeValue(forKey: id) else { return }
        turn.timer?.cancel()
        guard let activity = turn.activity else { return }
        turn.body = title
        let content = ActivityContent(state: state(id, turn, kind), staleDate: nil)
        let activityID = activity.id
        tokenObservers.removeValue(forKey: activityID)?.cancel()
        Task {
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(kind == CatpawWorkAttributes.ContentState.Kind.done ? 5 * 60 : 30 * 60)))
            await CatpawPushTokenUploader.shared.forgetActivity(activityID)
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
