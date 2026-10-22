import Foundation

public enum FixtureScenario: String, CaseIterable, Codable, Sendable { case success, failure, unexpectedEOF, cancelled, unknown }
public struct FixtureProvider: AgentProvider {
    public let scenario: FixtureScenario
    public let delayNanoseconds: UInt64
    public init(scenario: FixtureScenario = .success, delayNanoseconds: UInt64 = 120_000_000) { self.scenario = scenario; self.delayNanoseconds = delayNanoseconds }
    public func descriptor() async -> ProviderDescriptor {
        ProviderDescriptor(id: "catpaw.fixture.v1", version: "1.0", capabilities: [ProviderCapability(capabilityID: "reply", availability: .fixtureAvailable, requiredAuthorizationKinds: [])])
    }
    public func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        let text = "【模拟回复 · cat Fixture v1】\n已将你的输入保存到本机：\n\(request.frozenText)\n\n这条回复用于验证消息流、取消和成果关联。真实模型、研究与远程工具尚未连接。"
        return stream(context: request.context, text: text)
    }
    private func stream(context: ProviderContext, text: String) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                var sequence = 0
                func emit(_ payload: ProviderEventPayload) {
                    sequence += 1
                    continuation.yield(ProviderEvent(operationID: context.operationID, sequence: sequence, runtimeEpoch: context.runtimeEpoch, reality: .simulated, payload: payload))
                }
                do {
                    emit(.progress(ProgressSnapshot(label: "模拟准备", completedUnits: 0, totalUnits: 2)))
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        try Task.checkCancellation()
                        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
                        emit(.textDelta(String(line) + "\n"))
                        if scenario == .unexpectedEOF { continuation.finish(); return }
                    }
                    let final = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) + "\n" }.joined()
                    switch scenario {
                    case .success: emit(.messageCompleted(finalTextHash: textHash(final), finishReason: .stop)); emit(.taskCompleted(receiptReference: "fixture:v1:success"))
                    case .failure: emit(.failed(ProviderFailure(code: "fixture_failure", displayMessage: "模拟失败：保留输入和部分回复。", retryable: true, retryAfterSeconds: nil)))
                    case .cancelled: emit(.cancelled)
                    case .unknown: emit(.outcomeUnknown)
                    case .unexpectedEOF: break
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
    public func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        stream(context: request.context, text: "模拟任务：\(request.taskID.uuidString)")
    }
    public func observe(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent {
        ProviderEvent(operationID: operationID, sequence: 1, runtimeEpoch: context.runtimeEpoch, reality: .simulated, payload: .outcomeUnknown)
    }
    public func cancel(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent {
        ProviderEvent(operationID: operationID, sequence: 1, runtimeEpoch: context.runtimeEpoch, reality: .simulated, payload: .cancelled)
    }
}
public struct UnavailableRemoteProvider: AgentProvider {
    public init() {}
    public func descriptor() async -> ProviderDescriptor { ProviderDescriptor(id: "remote.unconfigured", version: "1", capabilities: [ProviderCapability(capabilityID: "reply", availability: .unavailable, requiredAuthorizationKinds: ["account", "data_scope"])]) }
    public func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { throw catError.unavailable("真实模型未配置：缺少合法接口、账号与数据范围。") }
    public func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { throw catError.unavailable("真实任务服务未配置。") }
    public func observe(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { throw catError.unavailable("无真实回执查询接口。") }
    public func cancel(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { throw catError.unavailable("无真实取消接口。") }
}
