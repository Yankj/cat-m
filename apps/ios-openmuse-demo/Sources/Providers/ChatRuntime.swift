import Foundation

extension Repository {
    @discardableResult private func requireReplyAttempt(task: WorkTask, scope: DataScope, epoch: Int) throws -> ChatRequest {
        let record = try self.record(stableID("reply-request-\(task.operationID)"), scope: scope)
        guard case .preference(let value) = record.payload, let data = value.value.data(using: .utf8) else { throw CatpawError.conflict }
        let request = try JSONDecoder().decode(ChatRequest.self, from: data)
        guard request.context.runtimeEpoch == epoch else { throw CatpawError.conflict }
        return request
    }
    public func persistOperation(scope: DataScope, messageID: UUID, taskID: UUID, outcome: OperationReducer) throws {
        let mr = try record(messageID, scope: scope), tr = try record(taskID, scope: scope)
        guard var m = mr.message, var t = tr.task else { throw CatpawError.missing }
        try requireReplyAttempt(task: t, scope: scope, epoch: outcome.attemptEpoch)
        guard t.state != .cancelled || outcome.taskState == .cancelled else { throw CatpawError.conflict }
        m.blocks = [.text(outcome.text + (outcome.error.map { "\n\n" + $0 } ?? ""))]; m.state = outcome.messageState
        m.reality = outcome.observedReality; t.reality = outcome.observedReality
        t.state = outcome.taskState == .succeeded && t.results.isEmpty ? .running : outcome.taskState
        for i in t.steps.indices { t.steps[i].state = i == 0 || outcome.taskState == .succeeded ? .succeeded : outcome.taskState }
        try commit(scope: scope, mutations: [.update(mr.id, mr.header.revision, .core(.message(m))), .update(tr.id, tr.header.revision, .core(.task(t)))])
    }
    public func finishReply(scope: DataScope, messageID: UUID, taskID: UUID, outcome: OperationReducer, blobHash: String) throws {
        let mr = try record(messageID, scope: scope), tr = try record(taskID, scope: scope)
        guard var m = mr.message, var t = tr.task, t.state == .running, outcome.taskState == .succeeded else { throw CatpawError.conflict }
        let request = try requireReplyAttempt(task: t, scope: scope, epoch: outcome.attemptEpoch)
        let id = stableID("reply-result-\(taskID)")
        let gatewayReply = request.context.providerID == "catpaw.gateway.v1"
        let title = gatewayReply ? (t.reality == .simulated ? "Gateway 合成回复.md" : "Gateway 回复.md") : "Fixture 回复.md"
        let source = gatewayReply ? (t.reality == .simulated ? "gateway_synthetic_chat" : "gateway") : "fixture"
        let reference = DocumentReference(documentID: id, version: 1, contentHash: blobHash)
        m.blocks = [.text(outcome.text)]; m.state = .completed
        t.state = .succeeded; t.results = [reference]
        for i in t.steps.indices { t.steps[i].state = .succeeded }
        var owners = [t.conversationID]
        var projectMutations: [Mutation] = []
        if let projectID = request.frozenConfiguration.projectID {
            let projectRecord = try record(projectID, scope: scope)
            guard case .core(.project(var project)) = projectRecord.payload else { throw CatpawError.scopeMismatch }
            owners.append(projectID)
            if !project.documentIDs.contains(id) { project.documentIDs.append(id) }
            projectMutations.append(.update(projectID, projectRecord.header.revision, .core(.project(project))))
        }
        try commit(scope: scope, mutations: [.create(id, .core(.document(Document(title: title, mimeType: "text/markdown", currentVersion: 1, ownerIDs: owners, sourceKind: source)))), .create(stableID("\(id)-v1"), .core(.documentVersion(DocumentVersion(documentID: id, version: 1, parentVersion: nil, privateBlobReference: blobHash, contentHash: blobHash)))), .update(mr.id, mr.header.revision, .core(.message(m))), .update(tr.id, tr.header.revision, .core(.task(t)))] + projectMutations)
    }
    public func failReplyPublication(scope: DataScope, messageID: UUID, taskID: UUID, text: String, reason: String, attemptEpoch: Int) throws {
        let mr = try record(messageID, scope: scope), tr = try record(taskID, scope: scope)
        guard var m = mr.message, var t = tr.task, ![.cancelled, .succeeded].contains(t.state) else { return }
        try requireReplyAttempt(task: t, scope: scope, epoch: attemptEpoch)
        m.state = .failed; m.blocks = [.text(text + "\n\n本地成果保存失败：" + reason)]; t.state = .failed
        try commit(scope: scope, mutations: [.update(mr.id, mr.header.revision, .core(.message(m))), .update(tr.id, tr.header.revision, .core(.task(t)))])
    }
    public func cancelPendingReply(scope: DataScope, messageID: UUID, taskID: UUID, attemptEpoch: Int) throws {
        let mr = try record(messageID, scope: scope), tr = try record(taskID, scope: scope)
        guard var m = mr.message, var t = tr.task, t.state != .succeeded else { return }
        try requireReplyAttempt(task: t, scope: scope, epoch: attemptEpoch)
        m.state = .cancelled; t.state = .cancelled
        try commit(scope: scope, mutations: [.update(mr.id, mr.header.revision, .core(.message(m))), .update(tr.id, tr.header.revision, .core(.task(t)))])
    }
}
// Trusted composition-root choice. A wire event can never select or upgrade this mode.
public enum ChatProviderMode: Sendable {
    case fixture, gateway
    public var reality: ExecutionReality { self == .fixture ? .simulated : .remoteAccepted }
    public var admissionReality: ExecutionReality { self == .fixture ? .simulated : .unknown }
}
public actor ChatRuntime {
    private struct LiveOperation {
        let attemptEpoch: Int
        var scope: DataScope
        var messageID: UUID
        var taskID: UUID
        var reducer: OperationReducer
        var worker: Task<Void, Never>?
    }
    private let repository: Repository
    private let service: WorkspaceService
    private var live: [UUID: LiveOperation] = [:]
    private var runtimeEpoch = 1
    private var attemptCounter = 0
    private let providerOverride: (any AgentProvider)?
    private let providerMode: ChatProviderMode
    private let beforeAdmissionCommit: (@Sendable () async -> Void)?
    private let afterAdmissionCommit: (@Sendable () async -> Void)?
    public init(repository: Repository, service: WorkspaceService, provider: (any AgentProvider)? = nil, providerMode: ChatProviderMode = .fixture, beforeAdmissionCommit: (@Sendable () async -> Void)? = nil, afterAdmissionCommit: (@Sendable () async -> Void)? = nil) { self.repository = repository; self.service = service; self.providerOverride = provider; self.providerMode = providerMode; self.beforeAdmissionCommit = beforeAdmissionCommit; self.afterAdmissionCommit = afterAdmissionCommit }
    @discardableResult public func send(scope: DataScope, conversationID: UUID, text: String, clientMessageID: UUID, scenario: FixtureScenario) async throws -> UUID {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatpawError.invalid("请输入内容。") }
        let admissionEpoch = runtimeEpoch
        guard providerMode == .fixture || providerOverride != nil else { throw CatpawError.unavailable("Gateway provider is not configured.") }
        let providerID = await providerOverride?.descriptor().id ?? "catpaw.fixture.v1"
        guard providerMode == .fixture || providerID == "catpaw.gateway.v1" else { throw CatpawError.invalid("Gateway mode requires the configured gateway adapter.") }
        let userID = stableID("user-message-\(clientMessageID)")
        let assistantID = stableID("assistant-message-\(clientMessageID)")
        let taskID = stableID("task-\(clientMessageID)")
        let operationID = stableID("reply-\(clientMessageID)")
        let existing = await repository.read(scope: scope)
        if let r = existing.records[userID] {
            guard r.message?.conversationID == conversationID,
                  r.message?.blocks.textValue == text else { throw CatpawError.invalid("消息ID与旧提交不一致。") }
            return operationID // Persisted duplicate never causes another provider invocation.
        }
        let cr = try await repository.record(conversationID, scope: scope)
        guard var c = cr.conversation else { throw CatpawError.missing }
        let sequence = (existing.list("message", scope: scope).compactMap(\.message).filter { $0.conversationID == conversationID }.map(\.sequence).max() ?? 0) + 1
        c.draftText = ""; if c.title == "新任务" { c.title = String(text.prefix(28)) }
        let user = ChatMessage(conversationID: conversationID, clientMessageID: clientMessageID, role: .user, blocks: [.text(text)], replyToID: nil, state: .localSaved, reality: .localEffect, sequence: sequence)
        let assistant = ChatMessage(conversationID: conversationID, clientMessageID: stableID("assistant-client-\(clientMessageID)"), role: .assistant, blocks: [.text("")], replyToID: userID, state: .waitingProvider, reality: providerMode.admissionReality, sequence: sequence + 1)
        let task = WorkTask(title: providerMode == .fixture ? "模拟回复" : "Gateway 回复", conversationID: conversationID, environmentID: c.environmentID, operationID: operationID, state: .queued, steps: [WorkStep(id: UUID(), title: "接收本地输入", state: .succeeded, evidenceReference: nil), WorkStep(id: UUID(), title: providerMode == .fixture ? "Fixture 回复" : "Gateway 回复", state: .queued, evidenceReference: nil)], results: [], reality: providerMode.admissionReality)
        let configRecord = existing.records[stableID("config-\(conversationID)")]
        var configuration = ConversationConfiguration(model: "Auto", safety: true, subagents: false)
        if case .preference(let p) = configRecord?.payload, let data = p.value.data(using: .utf8) { configuration = try JSONDecoder().decode(ConversationConfiguration.self, from: data) }
        let frozen = FrozenRequestConfiguration(conversationID: conversationID, userMessageID: userID, environmentID: c.environmentID, projectID: c.projectID, configuration: configuration, expertRevisions: Dictionary(uniqueKeysWithValues: [c.expertID].compactMap { $0 }.compactMap { id in existing.records[id].map { (id, $0.header.revision) } }), skillRevisions: Dictionary(uniqueKeysWithValues: c.skillIDs.compactMap { id in existing.records[id].map { (id, $0.header.revision) } }))
        attemptCounter += 1
        let epoch = attemptCounter
        let context = ProviderContext(scope: scope, operationID: operationID, environmentID: c.environmentID, providerID: providerID, runtimeEpoch: epoch, authorizationReferences: [])
        let request = ChatRequest(context: context, conversationID: conversationID, userMessageID: userID, frozenText: text, frozenTextHash: textHash(text), conversationRevision: cr.header.revision + 1, frozenConfiguration: frozen)
        let requestJSON = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        if let beforeAdmissionCommit { await beforeAdmissionCommit() }
        guard admissionEpoch == runtimeEpoch else { throw CancellationError() }
        try await repository.commit(operationID: clientMessageID, scope: scope, mutations: [.create(userID, .core(.message(user))), .create(assistantID, .core(.message(assistant))), .create(taskID, .core(.task(task))), .create(stableID("request-config-\(clientMessageID)"), .requestConfiguration(frozen)), .create(stableID("reply-request-\(operationID)"), .preference(Preference(key: "reply_request:\(operationID)", value: requestJSON))), .update(conversationID, cr.header.revision, .core(.conversation(c)))])
        if let afterAdmissionCommit { await afterAdmissionCommit() }
        guard admissionEpoch == runtimeEpoch else {
            var cancelled = OperationReducer(operationID: operationID, epoch: epoch, expectedReality: providerMode.reality); cancelled.cancel()
            try await repository.persistOperation(scope: scope, messageID: assistantID, taskID: taskID, outcome: cancelled)
            throw CancellationError()
        }
        live[operationID] = LiveOperation(attemptEpoch: epoch, scope: scope, messageID: assistantID, taskID: taskID, reducer: OperationReducer(operationID: operationID, epoch: epoch, expectedReality: providerMode.reality))
        let worker = Task { await self.consume(request: request, scenario: scenario) }
        live[operationID]?.worker = worker
        return operationID
    }
    public func retry(scope: DataScope, taskID: UUID, scenario: FixtureScenario) async throws {
        let admissionEpoch = runtimeEpoch
        guard providerMode == .fixture else { throw CatpawError.invalid("Remote requests require verification of the original operation before another attempt.") }
        let tr = try await repository.record(taskID, scope: scope)
        guard var task = tr.task, [.failed, .cancelled].contains(task.state), live[task.operationID] == nil else { throw CatpawError.invalid("只能重试明确失败或已取消的模拟运行；未知结果先核验。") }
        let saved = try await repository.record(stableID("reply-request-\(task.operationID)"), scope: scope)
        guard case .preference(let p) = saved.payload, let data = p.value.data(using: .utf8) else { throw CatpawError.missing }
        var request = try JSONDecoder().decode(ChatRequest.self, from: data)
        let retryProviderID = await providerOverride?.descriptor().id ?? "catpaw.fixture.v1"
        guard retryProviderID == request.context.providerID,
              (providerMode == .fixture ? task.reality == .simulated : [.unknown, .remoteAccepted].contains(task.reality)) else { throw CatpawError.invalid("Frozen provider changed; start an explicit new request.") }
        let s = await repository.read(scope: scope)
        guard let mr = s.list("message", scope: scope).first(where: { $0.message?.replyToID == request.userMessageID }), var message = mr.message else { throw CatpawError.missing }
        let archive = String(data: try JSONEncoder().encode([tr, mr]), encoding: .utf8)!
        task.state = .queued; task.results = []; message.state = .waitingProvider; message.blocks = [.text("")]
        task.reality = providerMode.admissionReality; message.reality = providerMode.admissionReality
        guard admissionEpoch == runtimeEpoch else { throw CancellationError() }
        attemptCounter = max(attemptCounter, request.context.runtimeEpoch) + 1
        let retryEpoch = attemptCounter
        request.context.runtimeEpoch = retryEpoch
        let requestJSON = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        try await repository.commit(scope: scope, mutations: [.update(tr.id, tr.header.revision, .core(.task(task))), .update(mr.id, mr.header.revision, .core(.message(message))), .update(saved.id, saved.header.revision, .preference(Preference(key: p.key, value: requestJSON))), .create(UUID(), .preference(Preference(key: "attempt_archive:\(task.operationID)", value: archive)))])
        guard admissionEpoch == runtimeEpoch else { var stopped = OperationReducer(operationID: task.operationID, epoch: retryEpoch, expectedReality: providerMode.reality); stopped.cancel(); try await repository.persistOperation(scope: scope, messageID: mr.id, taskID: tr.id, outcome: stopped); throw CancellationError() }
        live[task.operationID] = LiveOperation(attemptEpoch: retryEpoch, scope: scope, messageID: mr.id, taskID: tr.id, reducer: OperationReducer(operationID: task.operationID, epoch: retryEpoch, expectedReality: providerMode.reality))
        let frozenRequest = request
        let worker = Task { await self.consume(request: frozenRequest, scenario: scenario) }; live[task.operationID]?.worker = worker
    }
    private func consume(request: ChatRequest, scenario: FixtureScenario) async {
        let id = request.context.operationID
        defer { if live[id]?.attemptEpoch == request.context.runtimeEpoch { live.removeValue(forKey: id) } }
        do {
            let provider: any AgentProvider = providerOverride ?? FixtureProvider(scenario: scenario)
            for try await event in try await provider.reply(to: request) {
                guard var op = live[id], op.attemptEpoch == request.context.runtimeEpoch else { return }
                if op.reducer.accept(event) {
                    live[id] = op
                    try await repository.persistOperation(scope: op.scope, messageID: op.messageID, taskID: op.taskID, outcome: op.reducer)
                }
                if op.reducer.messageTerminal && op.reducer.taskTerminal { break }
            }
            guard var op = live[id], op.attemptEpoch == request.context.runtimeEpoch else { return }
            op.reducer.endOfStream(); live[id] = op
            try await repository.persistOperation(scope: op.scope, messageID: op.messageID, taskID: op.taskID, outcome: op.reducer)
            if op.reducer.taskState == .succeeded {
                let hash = try service.blobs.stage(Data(op.reducer.text.utf8))
                try await repository.finishReply(scope: op.scope, messageID: op.messageID, taskID: op.taskID, outcome: op.reducer, blobHash: hash)
            }
        } catch {
            guard var op = live[id], op.attemptEpoch == request.context.runtimeEpoch else { return }
            op.reducer.transportFailed(error.localizedDescription); live[id] = op
            do {
                if op.reducer.taskState == .outcomeUnknown { try await repository.persistOperation(scope: op.scope, messageID: op.messageID, taskID: op.taskID, outcome: op.reducer) }
                else { try await repository.failReplyPublication(scope: op.scope, messageID: op.messageID, taskID: op.taskID, text: op.reducer.text, reason: error.localizedDescription, attemptEpoch: op.attemptEpoch) }
            }
            catch { /* No false success: in-flight records remain recoverable at next launch. */ }
        }
    }
    public func cancel(operationID: UUID) async throws {
        guard var op = live[operationID] else { return }
        if providerMode == .gateway {
            op.reducer.transportFailed("Local observation stopped; the original remote operation requires verification.")
            op.reducer.epoch += 1; live[operationID] = op; op.worker?.cancel()
            try await repository.persistOperation(scope: op.scope, messageID: op.messageID, taskID: op.taskID, outcome: op.reducer)
            if live[operationID]?.attemptEpoch == op.attemptEpoch { live.removeValue(forKey: operationID) }
            return
        }
        op.reducer.cancel(); live[operationID] = op; op.worker?.cancel()
        try await repository.cancelPendingReply(scope: op.scope, messageID: op.messageID, taskID: op.taskID, attemptEpoch: op.attemptEpoch)
        if live[operationID]?.attemptEpoch == op.attemptEpoch { live.removeValue(forKey: operationID) }
    }
    public func suspend() async {
        runtimeEpoch += 1
        for id in Array(live.keys) { do { try await cancel(operationID: id) } catch { } }
    }
    public func awaitCompletion(operationID: UUID) async { if let worker = live[operationID]?.worker { await worker.value } }
    // Freeze a completion handle before cancellation; draining it must never wait for a successor attempt.
    func completionForCurrentAttempt(operationID: UUID) -> Task<Void, Never>? { live[operationID]?.worker }
    public func recoverInterrupted(scope: DataScope) async throws {
        let snapshot = await repository.read(scope: scope); var edits: [Mutation] = []
        for r in snapshot.list(scope: scope) {
            if var m = r.message, [.waitingProvider, .streaming].contains(m.state) {
                m.state = .failed
                m.blocks.append(.text([.remoteAccepted, .unknown].contains(m.reality) ? "应用中断，原请求结果未知；请先核验原记录，不要重复发送。" : "应用中断，未收到完成事件。请主动新建一轮。"))
                edits.append(.update(r.id, r.header.revision, .core(.message(m))))
            }
            if var t = r.task, [.queued, .preparing, .running].contains(t.state) {
                t.state = [.remoteAccepted, .unknown].contains(t.reality) ? .outcomeUnknown : .failed
                edits.append(.update(r.id, r.header.revision, .core(.task(t))))
            }
        }
        if !edits.isEmpty { try await repository.commit(scope: scope, mutations: edits) }
    }
}
extension Array where Element == MessageBlock {
    public var textValue: String { compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n") }
}
