import Foundation

actor AcceptedThenEOFProvider: AgentProvider {
    private var calls = 0
    enum Ending: Sendable { case eof, brokenConnection, waitForCancellation }
    private let ending: Ending
    init(ending: Ending = .eof) { self.ending = ending }
    func count() -> Int { calls }
    func descriptor() async -> ProviderDescriptor { ProviderDescriptor(id: "catpaw.gateway.v1", version: "synthetic-test", capabilities: []) }
    func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        calls += 1
        return AsyncThrowingStream { stream in
            stream.yield(ProviderEvent(operationID: request.context.operationID, sequence: 1, runtimeEpoch: request.context.runtimeEpoch, reality: .remoteAccepted, payload: .accepted(providerOperationID: "synthetic-only")))
            stream.yield(ProviderEvent(operationID: request.context.operationID, sequence: 2, runtimeEpoch: request.context.runtimeEpoch, reality: .remoteAccepted, payload: .textDelta("retained synthetic partial")))
            switch ending {
            case .eof: stream.finish()
            case .brokenConnection: stream.finish(throwing: URLError(.networkConnectionLost))
            case .waitForCancellation: break
            }
        }
    }
    func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { throw catError.unavailable("test") }
    func observe(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { throw catError.unavailable("test") }
    func cancel(operationID: UUID, context: ProviderContext) async throws -> ProviderEvent { throw catError.unavailable("test") }
}

@main struct GatewaySafetyRegression {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawGatewaySafety-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("store.json")))
        let service = WorkspaceService(repository: repo, blobs: try BlobStore(root: directory.appendingPathComponent("blobs")))
        try await service.bootstrap(scope: Profiles.demo)
        let environment = service.environmentID(.local, Profiles.demo)
        let conversation = try await service.createConversation(scope: Profiles.demo, environment: environment, project: nil, configuration: ConversationConfiguration(model: "qwen-beijing", safety: true, subagents: false))
        let provider = AcceptedThenEOFProvider()
        let runtime = ChatRuntime(repository: repo, service: service, provider: provider, providerMode: .gateway)
        let operation = try await runtime.send(scope: Profiles.demo, conversationID: conversation, text: "synthetic only", clientMessageID: UUID(), scenario: .success)
        await runtime.awaitCompletion(operationID: operation)
        let snapshot = await repo.read(scope: Profiles.demo)
        let record = snapshot.list("task", scope: Profiles.demo).first { $0.task?.operationID == operation }!
        guard record.task?.state == .outcomeUnknown, record.task?.results.isEmpty == true else { throw catError.invalid("Accepted EOF became retryable or published a result") }
        print("PASS accepted remote EOF stays outcomeUnknown without a result")
        var retryRejected = false
        do { try await runtime.retry(scope: Profiles.demo, taskID: record.id, scenario: .success) }
        catch { retryRejected = true }
        guard retryRejected, await provider.count() == 1 else { throw catError.invalid("Unknown request was resent or invoked provider twice") }
        print("PASS unknown result refuses a new epoch/provider invocation")
        let reopened = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("store.json")))
        let reopenedRuntime = ChatRuntime(repository: reopened, service: WorkspaceService(repository: reopened, blobs: service.blobs), provider: provider, providerMode: .gateway)
        try await reopenedRuntime.recoverInterrupted(scope: Profiles.demo)
        let recovered = try await reopened.record(record.id, scope: Profiles.demo)
        guard recovered.task?.state == .outcomeUnknown else { throw catError.invalid("Restart erased unknown status") }
        print("PASS restart preserves original unknown operation for verification")
        let interrupted = try await repo.record(record.id, scope: Profiles.demo)
        var inFlight = interrupted.task!; inFlight.state = .running
        try await repo.commit(scope: Profiles.demo, mutations: [.update(interrupted.id, interrupted.header.revision, .core(.task(inFlight)))])
        let interruptedStore = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("store.json")))
        let recoveringRuntime = ChatRuntime(repository: interruptedStore, service: WorkspaceService(repository: interruptedStore, blobs: service.blobs), provider: provider, providerMode: .gateway)
        try await recoveringRuntime.recoverInterrupted(scope: Profiles.demo)
        let interruptedRecovery = try await interruptedStore.record(record.id, scope: Profiles.demo)
        guard interruptedRecovery.task?.state == .outcomeUnknown, await provider.count() == 1 else { throw catError.invalid("In-flight accepted recovery changed outcome or invoked the provider") }
        print("PASS recovery of accepted in-flight work becomes unknown without resending")
        let candidateService = WorkspaceService(repository: interruptedStore, blobs: service.blobs)
        for ending in [AcceptedThenEOFProvider.Ending.brokenConnection, .waitForCancellation] {
            let candidate = AcceptedThenEOFProvider(ending: ending)
            let candidateRuntime = ChatRuntime(repository: interruptedStore, service: candidateService, provider: candidate, providerMode: .gateway)
            let candidateOperation = try await candidateRuntime.send(scope: Profiles.demo, conversationID: conversation, text: "synthetic safety boundary", clientMessageID: UUID(), scenario: .success)
            if ending == .waitForCancellation {
                for _ in 0..<100 {
                    let current = await interruptedStore.read(scope: Profiles.demo)
                    if current.list("task", scope: Profiles.demo).contains(where: { $0.task?.operationID == candidateOperation && $0.task?.reality == .remoteAccepted }) { break }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                try await candidateRuntime.cancel(operationID: candidateOperation)
            } else { await candidateRuntime.awaitCompletion(operationID: candidateOperation) }
            let current = await interruptedStore.read(scope: Profiles.demo)
            guard let task = current.list("task", scope: Profiles.demo).first(where: { $0.task?.operationID == candidateOperation })?.task,
                  task.state == .outcomeUnknown, task.results.isEmpty else { throw catError.invalid("Transport loss or local cancel claimed remote failure/success/cancellation") }
            print(ending == .brokenConnection ? "PASS accepted connection loss preserves unknown" : "PASS local cancel stops observation and retains unknown remote outcome")
        }
        var externalRejected = false
        do { _ = try GatewayConfiguration(baseURL: URL(string: "https://example.com")!, localSynthetic: true) }
        catch { externalRejected = error.localizedDescription.contains("loopback") }
        guard externalRejected else { throw catError.invalid("Synthetic mode accepted external host") }
        print("PASS synthetic mode cannot route demo data to an external HTTPS host")
    }
}
