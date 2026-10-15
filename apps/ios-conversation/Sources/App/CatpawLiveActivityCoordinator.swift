import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Drives the `CatpawWorkAttributes` Live Activity (lock screen + Dynamic Island) from
/// `ConversationSessionService.turnEvents()`.
/// - start: a `delegate_*` tool starts, or a turn is still running after `longTurnThreshold`
/// - update: every tool call / result, reasoning summary, first answer text
/// - end: `completed` → `.done`, `failed` → `.failed`
/// Requested with `pushType: .token`; every push token goes to `CatpawPushTokenUploader`.
@MainActor final class CatpawLiveActivityCoordinator {
    static let shared = CatpawLiveActivityCoordinator()
    static let longTurnThreshold: TimeInterval = 8
    private static let longTaskTools: Set<String> = ["delegate_task", "delegate_plan_v1"]

    private struct Turn {
        var conversationID: String
        var startedAt = Date()
        var step = 0
        var stepTitle: String
        var activity: Activity<CatpawWorkAttributes>?
        var timer: Task<Void, Never>?
        var answering = false
    }
    private var turns: [UUID: Turn] = [:]
    private var tokenObservers: [String: Task<Void, Never>] = [:]

    private func ui(_ key: String, _ arguments: [String] = []) -> String { AppLanguage(locale: .current).ui(key, arguments: arguments) }

    /// Runs until the calling task is cancelled (attach with SwiftUI `.task`).
    func observe(_ service: ConversationSessionService, conversationID: @escaping @MainActor () -> UUID?) async {
        let stream = await service.turnEvents()
        for await event in stream {
            if Task.isCancelled { break }
            handle(event, conversationID: conversationID())
        }
    }

    func handle(_ event: ConversationTurnEvent, conversationID: UUID?) {
        let id = event.operationID
        switch event.payload {
        case .started:
            guard turns[id] == nil else { return }
            var turn = Turn(conversationID: conversationID?.uuidString ?? "", stepTitle: ui("正在思考…"))
            turn.timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.longTurnThreshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.startIfNeeded(id)
            }
            turns[id] = turn
        case .reasoningSummary:
            mutate(id) { $0.stepTitle = self.ui("正在思考…") }
        case .toolStarted(_, let name, _):
            ensureTracked(id, conversationID: conversationID)
            mutate(id) { $0.step += 1; $0.stepTitle = self.ui("正在调用工具：{0}", [name]) }
            if Self.longTaskTools.contains(name) { startIfNeeded(id) }
        case .toolResult(let result):
            mutate(id) { $0.stepTitle = self.ui("工具已返回：{0}", [result.name]) }
        case .textDelta:
            guard turns[id]?.answering == false else { return }
            mutate(id) { $0.answering = true; $0.stepTitle = self.ui("正在整理回答…") }
        case .completed:
            finish(id, status: .done, title: ui("已完成"))
        case .failed:
            finish(id, status: .failed, title: ui("未完成，需核对"))
        default:
            break
        }
    }

    private func ensureTracked(_ id: UUID, conversationID: UUID?) {
        if turns[id] == nil { turns[id] = Turn(conversationID: conversationID?.uuidString ?? "", stepTitle: ui("正在思考…")) }
    }

    private func state(_ turn: Turn, _ status: CatpawWorkAttributes.ContentState.Status) -> CatpawWorkAttributes.ContentState {
        let count = max(turn.step, 1)
        return .init(status: status, stepTitle: turn.stepTitle, stepIndex: min(max(turn.step, 1), count), stepCount: count, needsUserCardID: nil, updatedAt: Date())
    }

    private func mutate(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard var turn = turns[id] else { return }
        change(&turn); turns[id] = turn
        guard let activity = turn.activity else { return }
        let content = ActivityContent(state: state(turn, .running), staleDate: Date().addingTimeInterval(120))
        Task { await activity.update(content) }
    }

    private func startIfNeeded(_ id: UUID) {
        guard var turn = turns[id], turn.activity == nil, !turn.conversationID.isEmpty else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = CatpawWorkAttributes(taskID: id.uuidString, conversationID: turn.conversationID, title: ui("Catpaw 正在工作"))
        do {
            let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state(turn, .running), staleDate: Date().addingTimeInterval(120)), pushType: .token)
            turn.activity = activity; turns[id] = turn
            observeToken(activity, turnID: id, conversationID: turn.conversationID)
        } catch {
            // Disabled by the user / system budget: the in-app UI remains the source of truth.
        }
    }

    private func observeToken(_ activity: Activity<CatpawWorkAttributes>, turnID: UUID, conversationID: String) {
        let activityID = activity.id
        tokenObservers[activityID] = Task {
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await CatpawPushTokenUploader.shared.enqueue(.liveActivity(token: token, activityID: activityID, taskID: turnID.uuidString, conversationID: conversationID))
            }
        }
    }

    private func finish(_ id: UUID, status: CatpawWorkAttributes.ContentState.Status, title: String) {
        guard var turn = turns.removeValue(forKey: id) else { return }
        turn.timer?.cancel()
        guard let activity = turn.activity else { return }
        turn.stepTitle = title
        if status == .done { turn.step = max(turn.step, 1) }
        let content = ActivityContent(state: state(turn, status), staleDate: nil)
        let activityID = activity.id
        tokenObservers.removeValue(forKey: activityID)?.cancel()
        Task {
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(status == .done ? 5 * 60 : 30 * 60)))
            await CatpawPushTokenUploader.shared.retire(activityID: activityID)
        }
    }
}
#endif
