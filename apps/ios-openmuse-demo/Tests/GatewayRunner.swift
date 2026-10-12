import Foundation

func check(_ value: Bool, _ label: String) throws {
    guard value else { throw CatpawError.invalid("FAIL: " + label) }
    print("PASS: " + label)
}
struct MockGatewayTransport: GatewayTransport {
    let bytes: Data
    func open(_ request: URLRequest) async throws -> GatewayResponse {
        try check(request.value(forHTTPHeaderField: "X-Catpaw-Demo") == "synthetic-only", "native adapter marks synthetic loopback")
        let chunks = AsyncThrowingStream<Data, Error> { c in for byte in bytes { c.yield(Data([byte])) }; c.finish() }
        return GatewayResponse(statusCode: 200, chunks: chunks)
    }
}
func wire(_ operation: UUID, _ sequence: Int, _ type: String, _ fields: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = ["operation_id": operation.uuidString, "runtime_epoch": 1, "sequence": sequence, "type": type, "reality": "simulated"]
    object.merge(fields, uniquingKeysWith: { _, b in b })
    return Data("data: \(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))\r\n\r\n".utf8)
}
#if GATEWAY_INTEGRATION
struct RemoteSyntheticProvider: AgentProvider {
    func descriptor() async -> ProviderDescriptor { ProviderDescriptor(id: "catpaw.gateway.v1", version: "test-only", capabilities: []) }
    func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(ProviderEvent(operationID: request.context.operationID, sequence: 1, runtimeEpoch: request.context.runtimeEpoch, reality: .remoteAccepted, payload: .accepted(providerOperationID: "test-only:synthetic")))
            c.yield(ProviderEvent(operationID: request.context.operationID, sequence: 2, runtimeEpoch: request.context.runtimeEpoch, reality: .remoteAccepted, payload: .textDelta("synthetic remote wire")))
            c.yield(ProviderEvent(operationID: request.context.operationID, sequence: 3, runtimeEpoch: request.context.runtimeEpoch, reality: .remoteAccepted, payload: .messageCompleted(finalTextHash: textHash("synthetic remote wire"), finishReason: .stop)))
            c.yield(ProviderEvent(operationID: request.context.operationID, sequence: 4, runtimeEpoch: request.context.runtimeEpoch, reality: .remoteAccepted, payload: .taskCompleted(receiptReference: "test-only:synthetic")))
            c.finish()
        }
    }
    func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { throw CatpawError.missing }
    func observe(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent { throw CatpawError.missing }
    func cancel(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent { throw CatpawError.missing }
}
#endif
@main struct GatewayRunner {
    static func main() async throws {
        let operation = UUID(), conversation = UUID(), message = UUID(), env = UUID()
        let config = try GatewayConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!, localSynthetic: true)
        let frozen = FrozenRequestConfiguration(conversationID: conversation, userMessageID: message, environmentID: env, projectID: nil, configuration: ConversationConfiguration(model: "dots-free", safety: true, subagents: false), expertRevisions: [:], skillRevisions: [:])
        let request = ChatRequest(context: ProviderContext(scope: Profiles.demo, operationID: operation, environmentID: env, providerID: "catpaw.gateway.v1", runtimeEpoch: 1, authorizationReferences: []), conversationID: conversation, userMessageID: message, frozenText: "synthetic", frozenTextHash: textHash("synthetic"), conversationRevision: 1, frozenConfiguration: frozen)
        var data = try wire(operation, 1, "accepted", ["provider_operation_id": "mock"])
        data.append(try wire(operation, 2, "text_delta", ["text": "猫爪"]))
        data.append(try wire(operation, 3, "message_completed", ["final_text_hash": textHash("猫爪"), "finish_reason": "stop"]))
        data.append(try wire(operation, 4, "task_completed", ["receipt_reference": "mock-response:synthetic"]))
        let provider = GatewayAgentProvider(configuration: config, transport: MockGatewayTransport(bytes: data))
        var reducer = OperationReducer(operationID: operation, epoch: 1)
        for try await event in try await provider.reply(to: request) { _ = reducer.accept(event) }
        reducer.endOfStream()
        try check(reducer.text == "猫爪" && reducer.taskState == .succeeded, "SSE byte fragments map into existing ProviderEvent/reducer")
        let incomplete = GatewayAgentProvider(configuration: config, transport: MockGatewayTransport(bytes: try wire(operation, 1, "text_delta", ["text": "partial"])))
        do { for try await _ in try await incomplete.reply(to: request) {} ; throw CatpawError.invalid("missing terminal accepted") }
        catch { try check(error.localizedDescription.contains("explicit task terminal"), "native adapter rejects missing terminal") }
        do { _ = try GatewayConfiguration(baseURL: URL(string: "http://example.com")!); throw CatpawError.invalid("HTTP accepted") }
        catch { try check(error.localizedDescription.contains("HTTPS"), "native configuration refuses insecure non-loopback endpoint") }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/swift-state")
        try? FileManager.default.removeItem(at: root)
        let repo = try Repository(persistence: FilePersistence(url: root.appendingPathComponent("state.json")))
        let blobs = try BlobStore(root: root.appendingPathComponent("blobs"))
        let service = WorkspaceService(repository: repo, blobs: blobs)
        try await service.bootstrap(scope: Profiles.demo)
        let environment = service.environmentID(.local, Profiles.demo)
        let importer = GatewayAssistantImporter(repository: repo, blobs: blobs)
        let projectionURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/native-projection.json")
        let projection = try Data(contentsOf: projectionURL)
        let imported = try await importer.apply(projection, expectedScope: Profiles.demo, environmentID: environment)
        try check(imported, "backend projection commits into native Repository")
        let before = await repo.read(scope: Profiles.demo)
        let duplicate = try await importer.apply(projection, expectedScope: Profiles.demo, environmentID: environment)
        let after = await repo.read(scope: Profiles.demo)
        try check(!duplicate && before.sequence == after.sequence, "duplicate sync is idempotent without another commit")
        let artifactRecord = after.list("artifact", scope: Profiles.demo).first!
        guard case .artifact(let artifact) = artifactRecord.payload else { fatalError() }
        let read = try await service.readDocument(scope: Profiles.demo, id: artifact.documentReference.documentID, version: artifact.documentReference.version)
        try check(read.0.contentHash == artifact.currentReference.contentHash && String(decoding: read.1, as: UTF8.self).contains("模拟"), "native reader opens same artifact version/hash")
        let restarted = try Repository(persistence: FilePersistence(url: root.appendingPathComponent("state.json")))
        try check((await restarted.read(scope: Profiles.demo)).list("run", scope: Profiles.demo).count == 2, "native imported runs recover after restart")
        var wrongScopeRejected = false
        do { _ = try await importer.apply(projection, expectedScope: Profiles.user, environmentID: environment) }
        catch CatpawError.scopeMismatch { wrongScopeRejected = true }
        try check(wrongScopeRejected, "projection rejects other profile scope")
        var corrupt = try JSONSerialization.jsonObject(with: projection) as! [String: Any]
        var artifacts = corrupt["artifacts"] as! [[String: Any]]
        var versions = artifacts[0]["versions"] as! [[String: Any]]
        versions[0]["body"] = "tampered"; artifacts[0]["versions"] = versions; corrupt["artifacts"] = artifacts
        corrupt["sync_cursor"] = (corrupt["sync_cursor"] as! Int) + 1
        let corruptData = try JSONSerialization.data(withJSONObject: corrupt)
        var corruptRejected = false
        do { _ = try await importer.apply(corruptData, expectedScope: Profiles.demo, environmentID: environment) }
        catch { corruptRejected = error.localizedDescription.contains("hash") }
        try check(corruptRejected, "tampered artifact does not publish")
        try check((await repo.read(scope: Profiles.demo)).sequence == after.sequence, "failed import preserves Repository sequence")
        #if GATEWAY_INTEGRATION
        let remoteEvent = ProviderEvent(operationID: operation, sequence: 1, runtimeEpoch: 1, reality: .remoteAccepted, payload: .textDelta("synthetic remote wire"))
        var defaultReducer = OperationReducer(operationID: operation, epoch: 1)
        try check(!defaultReducer.accept(remoteEvent), "default fixture reducer refuses wire-driven reality upgrade")
        var realReducer = OperationReducer(operationID: operation, epoch: 1, expectedReality: .remoteAccepted)
        try check(realReducer.observedReality == .unknown && !realReducer.accept(remoteEvent), "real request is unknown until explicit remote acceptance")
        let acceptance = ProviderEvent(operationID: operation, sequence: 1, runtimeEpoch: 1, reality: .remoteAccepted, payload: .accepted(providerOperationID: "synthetic"))
        try check(realReducer.accept(acceptance) && realReducer.observedReality == .remoteAccepted, "composition root pins remote accepted mode")
        let verifiedEvent = ProviderEvent(operationID: operation, sequence: 2, runtimeEpoch: 1, reality: .remoteVerified, payload: .textDelta("forged upgrade"))
        try check(!realReducer.accept(verifiedEvent), "remote accepted mode refuses forged remote verified event")
        let wrongEpoch = ProviderEvent(operationID: operation, sequence: 2, runtimeEpoch: 2, reality: .remoteAccepted, payload: .textDelta("late epoch"))
        try check(!realReducer.accept(wrongEpoch), "real mode still fences runtime epoch")
        var refusedReducer = OperationReducer(operationID: operation, epoch: 1, expectedReality: .remoteAccepted)
        let refusal = ProviderEvent(operationID: operation, sequence: 1, runtimeEpoch: 1, reality: .unknown, payload: .failed(ProviderFailure(code: "free_protection_unverified", displayMessage: "synthetic guard", retryable: false, retryAfterSeconds: nil)))
        try check(refusedReducer.accept(refusal) && refusedReducer.observedReality == .unknown && refusedReducer.taskState == .failed, "preflight failure does not claim remote acceptance")
        let remoteConversation = try await service.createConversation(scope: Profiles.demo, environment: environment, project: nil, configuration: ConversationConfiguration(model: "dots-free", safety: true, subagents: false))
        let runtime = ChatRuntime(repository: repo, service: service, provider: RemoteSyntheticProvider(), providerMode: .gateway)
        let replyOperation = try await runtime.send(scope: Profiles.demo, conversationID: remoteConversation, text: "synthetic wire test only", clientMessageID: UUID(), scenario: .success)
        await runtime.awaitCompletion(operationID: replyOperation)
        let completedSnapshot = await repo.read(scope: Profiles.demo)
        let remoteTask = completedSnapshot.list("task", scope: Profiles.demo).compactMap(\.task).first { $0.operationID == replyOperation }!
        try check(remoteTask.state == .succeeded && remoteTask.reality == .remoteAccepted, "patched runtime preserves admitted provider reality through completion")
        let remoteDocument = completedSnapshot.records[remoteTask.results[0].documentID]!.document!
        try check(remoteDocument.sourceKind == "gateway" && remoteDocument.title == "Gateway 回复.md", "gateway result gets explicit source label")
        #endif
        if CommandLine.arguments.contains("--http") {
            let port = Int(CommandLine.arguments.last!)!
            let liveConfiguration = try GatewayConfiguration(baseURL: URL(string: "http://127.0.0.1:\(port)")!, localSynthetic: true)
            let liveProvider = GatewayAgentProvider(configuration: liveConfiguration)
            var liveReducer = OperationReducer(operationID: request.context.operationID, epoch: request.context.runtimeEpoch)
            for try await event in try await liveProvider.reply(to: request) { _ = liveReducer.accept(event) }
            liveReducer.endOfStream()
            try check(liveReducer.taskState == .succeeded && liveReducer.text.contains("模拟"), "URLSession Swift client interoperates with actual loopback gateway SSE")
        }
        print("Native gateway contract checks completed; no external model API called.")
    }
}
