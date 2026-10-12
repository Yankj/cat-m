import Foundation

func require(_ value: Bool, _ text: String) throws { if !value { throw CatpawError.invalid(text) }; print("PASS: " + text) }
actor ScriptedConversationBackend: ConversationBackend {
    private(set) var requests: [ConversationTurnRequest] = []
    func connection(scope: DataScope) async -> ConversationConnection { ConversationConnection(state: .connected, provider: "Explicit test backend", model: "test-only", detail: "Not included in the app") }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        requests.append(request)
        let text = requests.count == 1 ? "受众是谁？" : "已收到受众。"
        let id = UUID()
        return AsyncThrowingStream { c in
            c.yield(ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .textDelta(messageID: id, text: text)))
            c.yield(ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: 2, payload: .completed(messageID: id, finalTextHash: textHash(text))))
            c.finish()
        }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation { throw CatpawError.unavailable("No scripted observation in this test") }
    func captured() -> [ConversationTurnRequest] { requests }
}
actor InterruptedConversationBackend: ConversationBackend {
    private var calls = 0
    private var reads = 0
    private let message = UUID()
    func connection(scope: DataScope) async -> ConversationConnection { ConversationConnection(state: .connected, provider: "Explicit test backend", detail: "Test only") }
    func reply(_ r: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        calls += 1
        return AsyncThrowingStream { c in c.yield(ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 1, payload: .textDelta(messageID: message, text: "部分回复"))); c.finish() }
    }
    func observe(_ r: ConversationTurnRequest) async throws -> ConversationObservation {
        reads += 1
        return ConversationObservation(request: r, events: [ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 2, payload: .completed(messageID: message, finalTextHash: textHash("部分回复")))])
    }
    func counts() -> (Int,Int) { (calls,reads) }
}
actor DelayedObservationBackend: ConversationBackend {
    private var pending: CheckedContinuation<ConversationObservation, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var original: ConversationTurnRequest?
    private let id = UUID()
    func connection(scope: DataScope) async -> ConversationConnection { ConversationConnection(state: .connected, provider: "Explicit delayed test backend", detail: "Test only") }
    func reply(_ r: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        AsyncThrowingStream { c in c.yield(ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 1, payload: .textDelta(messageID: id, text: "partial"))); c.finish() }
    }
    func observe(_ r: ConversationTurnRequest) async throws -> ConversationObservation {
        original = r
        return await withCheckedContinuation { continuation in pending = continuation; waiting?.resume(); waiting = nil }
    }
    func waitUntilRead() async { if pending != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func resolveLate() {
        guard let r = original else { return }
        pending?.resume(returning: ConversationObservation(request: r, events: [ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 2, payload: .completed(messageID: id, finalTextHash: textHash("partial")))])); pending = nil
    }
}
actor ConcurrentAdmissionBackend: ConversationBackend {
    private var connections: [CheckedContinuation<ConversationConnection,Never>] = []
    private var replies = 0
    func connection(scope: DataScope) async -> ConversationConnection {
        await withCheckedContinuation { c in
            connections.append(c)
            if connections.count == 2 { let values = connections; connections = []; for value in values { value.resume(returning: ConversationConnection(state: .connected, provider: "Explicit concurrent test backend", detail: "Test only")) } }
        }
    }
    func reply(_ r: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        replies += 1; let id = UUID()
        return AsyncThrowingStream { c in c.yield(ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 1, payload: .textDelta(messageID: id, text: "only once"))); c.yield(ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 2, payload: .completed(messageID: id, finalTextHash: textHash("only once")))); c.finish() }
    }
    func observe(_ r: ConversationTurnRequest) async throws -> ConversationObservation { throw ConversationSessionError.invalidEvent }
    func count() -> Int { replies }
}
@main struct ConversationSessionRunner {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let repository = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("chat.json")))
        let service = ConversationSessionService(repository: repository)
        let first = try await service.openLatest(scope: Profiles.user)
        let next = try await service.openLatest(scope: Profiles.user)
        let snapshot = await repository.read(scope: Profiles.user)
        try require(first == next && snapshot.list("conversation", scope: Profiles.user).count == 1 && snapshot.list("task", scope: Profiles.user).isEmpty && snapshot.list("expert", scope: Profiles.user).isEmpty && snapshot.list("document", scope: Profiles.user).isEmpty, "cold startup opens one durable conversation without fixture tasks, catalogs or sample files")
        let draft = "帮我准备周五客户演示，先写5分钟提纲"
        try await service.saveDraft(scope: Profiles.user, conversationID: first, text: draft)
        var notConfigured = false
        do { _ = try await service.send(scope: Profiles.user, conversationID: first, text: draft, operationID: UUID()) }
        catch ConversationSessionError.notConfigured { notConfigured = true }
        catch { }
        let untouched = try await service.read(scope: Profiles.user, conversationID: first)
        let savedDraft = try await repository.record(first, scope: Profiles.user)
        try require(notConfigured && untouched.messages.isEmpty && untouched.goals.isEmpty && savedDraft.conversation?.draftText == draft, "not_configured preserves the actual input without a fake reply, goal or success")
        let backend = ScriptedConversationBackend()
        let connected = ConversationSessionService(repository: repository, backend: backend)
        let other = try await connected.openLatest(scope: Profiles.demo)
        try await connected.saveDraft(scope: Profiles.demo, conversationID: other, text: "other workspace secret")
        _ = try await connected.send(scope: Profiles.user, conversationID: first, text: draft, operationID: UUID())
        _ = try await connected.send(scope: Profiles.user, conversationID: first, text: "受众是客户的产品负责人", operationID: UUID())
        let requests = await backend.captured()
        let answered = try await connected.read(scope: Profiles.user, conversationID: first)
        try require(requests.count == 2 && requests[1].scope == Profiles.user && requests[1].history.map(\.content) == [draft,"受众是谁？","受众是客户的产品负责人"] && answered.messages.count == 4 && answered.goals.isEmpty, "second turn carries the complete scoped conversation and ordinary answers do not create goals")
        let frozenOperation = UUID()
        _ = try await connected.send(scope: Profiles.user, conversationID: first, text: "scope-bound question", operationID: frozenOperation, context: [ConversationExplicitContext(id: "version", text: "v1")])
        var rejected = false
        do { _ = try await connected.send(scope: Profiles.user, conversationID: first, text: "scope-bound question", operationID: frozenOperation, context: [ConversationExplicitContext(id: "version", text: "v2")]) } catch CatpawError.conflict { rejected = true }
        try require(rejected, "same operation cannot change frozen explicit context")
        let interrupted = InterruptedConversationBackend()
        let dropped = ConversationSessionService(repository: repository, backend: interrupted)
        let original = UUID()
        do { _ = try await dropped.send(scope: Profiles.user, conversationID: first, text: "继续准备", operationID: original) } catch { }
        let pending = try await dropped.read(scope: Profiles.user, conversationID: first)
        let restartedRepository = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("chat.json")))
        let restarted = ConversationSessionService(repository: restartedRepository, backend: interrupted)
        try await restarted.observe(scope: Profiles.user, conversationID: first)
        let resolved = try await restarted.read(scope: Profiles.user, conversationID: first)
        let counts = await interrupted.counts()
        try require(pending.turns.last?.state == .unknown && resolved.turns.last?.id == original && resolved.turns.last?.state == .completed && counts.0 == 1 && counts.1 == 1, "restart resolves the same unknown operation by observation without another provider create")
        let delayed = DelayedObservationBackend(), guarded = ConversationSessionService(repository: repository, backend: delayed)
        let lateID = try await guarded.create(scope: Profiles.user)
        do { _ = try await guarded.send(scope: Profiles.user, conversationID: lateID, text: "late read test", operationID: UUID()) } catch { }
        let observation = Task { try await guarded.observe(scope: Profiles.user, conversationID: lateID) }
        await delayed.waitUntilRead()
        try await guarded.stopObserving(scope: Profiles.user, conversationID: lateID)
        await delayed.resolveLate()
        do { try await observation.value } catch { }
        let fenced = try await guarded.read(scope: Profiles.user, conversationID: lateID)
        try require(fenced.turns.last?.state == .unknown && fenced.messages.last?.complete == false, "a delayed original read cannot publish completion after observation was stopped")
        let simultaneous = ConcurrentAdmissionBackend(), serialized = ConversationSessionService(repository: repository, backend: simultaneous)
        let shared = try await serialized.create(scope: Profiles.user)
        let one = Task { try? await serialized.send(scope: Profiles.user, conversationID: shared, text: "one", operationID: UUID()) }
        let two = Task { try? await serialized.send(scope: Profiles.user, conversationID: shared, text: "two", operationID: UUID()) }
        _ = await (one.value,two.value)
        let single = try await serialized.read(scope: Profiles.user, conversationID: shared), sends = await simultaneous.count()
        try require(sends == 1 && single.turns.count == 1 && single.turns.first?.state == .completed, "simultaneous admission keeps one active identity and cannot erase another turn or cancel its completion")
    }
}
