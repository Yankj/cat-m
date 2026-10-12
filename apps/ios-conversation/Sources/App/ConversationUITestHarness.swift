#if DEBUG
import Foundation

/// Explicit native interaction harness. No credentials, HTTP, model or Worker.
/// Activated only with a valid isolated CF_UI_TEST_STORE and named test scenario.
actor ConversationUITestHarness: ConversationBackend {
    private var dispatches = 0
    private var requests: [UUID: ConversationTurnRequest] = [:]
    private var streams: [UUID: AsyncThrowingStream<ConversationTurnEvent, Error>.Continuation] = [:]
    func connection(scope: DataScope) async -> ConversationConnection {
        ConversationConnection(state: .providerUnverified, provider: "交互测试专用", detail: "合成后端，无模型调用 · 请求次数：\(dispatches)")
    }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        dispatches += 1; requests[request.operationID] = request
        return AsyncThrowingStream { continuation in
            streams[request.operationID] = continuation
            continuation.yield(started(request))
            continuation.onTermination = { [weak self] _ in Task { await self?.detach(request.operationID) } }
        }
    }
    private func started(_ r: ConversationTurnRequest) -> ConversationTurnEvent {
        ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 1, payload: .started(requestHash: textHash("explicit-ui-test:" + r.operationID.uuidString), conversationRevision: 1, grantEpoch: 1))
    }
    private func detach(_ id: UUID) { streams.removeValue(forKey: id) }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        guard requests[request.operationID] != nil else { throw CatpawError.unavailable("测试原请求不存在") }
        return ConversationObservation(request: request, events: [started(request)], requestHash: textHash("explicit-ui-test:" + request.operationID.uuidString), grantEpoch: 1, goals: [])
    }
}
#endif
