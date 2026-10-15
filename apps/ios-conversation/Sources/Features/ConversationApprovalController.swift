import SwiftUI

/// catpaw.approval.v1 presentation (A2 UI lane). Source of truth is the persisted turn:
/// `turn.pendingApprovals` (set by `approval_requested`, kept while `turn_suspended`, pruned by `approval_resolved`).
/// Decisions go through `ConversationSessionService.submitApproval`, which pumps the continuation into the journal.
@MainActor final class ConversationApprovalController: ObservableObject {
    enum Outcome: Equatable { case approved, denied, expired, cancelled, failed(String) }
    @Published private(set) var working: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    /// Resolved interrupts of the current turn (from `approval_resolved` or our own decision), shown as a compact receipt.
    @Published private(set) var outcomes: [String: (tool: String, outcome: Outcome)] = [:]
    /// One decision operation id per interrupt so a transport retry is idempotent (contract §5).
    private var operationIDs: [String: UUID] = [:]
    private var tools: [String: String] = [:]
    private var listener: Task<Void, Never>?
    private var operationID: UUID?

    func observe(_ model: ConversationFirstModel, turn: ConversationTurnRecord?) {
        if let turn, turn.id != operationID { operationID = turn.id; outcomes = [:]; errors = [:]; operationIDs = [:] }
        for approval in turn?.pendingApprovals ?? [] { tools[approval.interruptID] = approval.tool }
        guard listener == nil else { return }
        let service = model.service
        listener = Task { [weak self] in
            let events = await service.turnEvents()
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                if case let .approvalResolved(id, _, decision, _) = event.payload, event.operationID == self.operationID {
                    let outcome: Outcome = switch decision { case "approved": .approved; case "expired": .expired; case "cancelled": .cancelled; default: .denied }
                    self.outcomes[id] = (self.tools[id] ?? "", outcome); self.working.remove(id)
                }
            }
        }
    }
    deinit { listener?.cancel() }

    func decide(_ approval: ConversationApprovalRequest, _ decision: ConversationApprovalDecision, model: ConversationFirstModel) {
        guard let conversationID = model.conversationID, !working.contains(approval.interruptID) else { return }
        let id = approval.interruptID
        let operation = operationIDs[id] ?? UUID(); operationIDs[id] = operation
        working.insert(id); errors[id] = nil; tools[id] = approval.tool
        Task {
            do {
                try await model.service.submitApproval(scope: model.scope, conversationID: conversationID, interruptID: id, decision: decision, operationID: operation)
                if outcomes[id] == nil { outcomes[id] = (approval.tool, decision == .deny ? .denied : .approved) }
            } catch let failure as ConversationApprovalFailure {
                switch failure {
                case .transport: errors[id] = "网络中断，确认未送达。请重试。"   // keep operationID → idempotent resend
                case .expired: outcomes[id] = (approval.tool, .expired)
                case .consumed, .noPendingApproval: if outcomes[id] == nil { outcomes[id] = (approval.tool, .failed("这项确认已处理")) }
                case .stale: operationIDs[id] = nil; errors[id] = "操作内容已变化，请重新确认。"
                case .notFound: outcomes[id] = (approval.tool, .failed("这项确认已不存在"))
                case .unsupported: errors[id] = "当前服务暂不支持确认操作。"
                case .rejected: operationIDs[id] = nil; errors[id] = "确认未被接受，请稍后重试。"
                }
            } catch ConversationSessionError.busy {
                errors[id] = "正在处理上一项操作，请稍候再试。"
            } catch {
                errors[id] = "确认结果待核对，请读取原请求进展。"
            }
            working.remove(id)
            await model.refresh(rebuildHistory: false)
        }
    }
}

