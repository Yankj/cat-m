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
/// Mirrors the confirmed server receipt shape, with explicit expected transcript bytes.
/// No model, HTTP, or task execution is performed by this test backend.
actor DelegationReceiptConversationBackend: ConversationBackend {
    private let text: String
    private let toolName: String
    private let serverPersistsAssistant: Bool
    private let terminalHash: String?
    private var requests: [ConversationTurnRequest] = []
    private var remote: [ConversationTranscriptMessage] = []
    private var observations: [UUID: ConversationObservation] = [:]
    init(text: String, serverPersistsAssistant: Bool, terminalHash: String? = nil, toolName: String = "delegate_task") { self.text = text; self.toolName = toolName; self.serverPersistsAssistant = serverPersistsAssistant; self.terminalHash = terminalHash }
    func connection(scope: DataScope) async -> ConversationConnection { .init(state: .connected, provider: "Explicit delegation receipt fixture", detail: "No network/model") }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let previous = request.history.dropLast().filter { $0.role == .user || ($0.role == .assistant && $0.toolName == nil && $0.complete) }
        guard previous.count == remote.count, zip(previous, remote).allSatisfy({ $0.id == $1.id && $0.role == $1.role && $0.content == $1.content }), let user = request.history.last else {
            throw ConversationDispatchFailure.notSent(reason: "Synthetic server transcript disagrees with follow-up history")
        }
        requests.append(request); remote.append(user)
        let message = UUID()
        var events: [ConversationTurnEvent] = []
        func emit(_ payload: ConversationTurnEvent.Payload) { events.append(.init(operationID: request.operationID, epoch: request.epoch, sequence: events.count + 1, payload: payload)) }
        if requests.count == 1 {
            emit(.toolStarted(callID: "delegation-receipt", name: toolName, arguments: "{}"))
            let goal = ConversationGoalProjection(id: "synthetic-delegation", revision: 1, title: "Synthetic durable projection", state: .working, summary: "Not a real task", updatedAt: Date(timeIntervalSince1970: 0))
            emit(.toolResult(.init(callID: "delegation-receipt", name: toolName, content: "{}", committedGoals: [goal])))
            if !text.isEmpty { emit(.textDelta(messageID: message, text: text)) }
            emit(.completed(messageID: message, finalTextHash: terminalHash ?? textHash(text)))
            if serverPersistsAssistant { remote.append(.init(id: message, role: .assistant, content: text)) }
        } else {
            let answer = "Synthetic follow-up received"
            emit(.textDelta(messageID: message, text: answer)); emit(.completed(messageID: message, finalTextHash: textHash(answer)))
            remote.append(.init(id: message, role: .assistant, content: answer))
        }
        observations[request.operationID] = .init(request: request, events: events)
        return AsyncThrowingStream { c in for event in events { c.yield(event) }; c.finish() }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        guard let observation = observations[request.operationID] else { throw ConversationSessionError.invalidEvent }; return observation
    }
    func captured() -> [ConversationTurnRequest] { requests }
    func prependHistoricalReply(_ message: ConversationTranscriptMessage) { remote.insert(message, at: 0) }
    func replaceObservedTerminalHash(operationID: UUID, hash: String) {
        guard let old = observations[operationID] else { return }
        let events = old.events.map { event -> ConversationTurnEvent in
            guard case .completed(let id, _, let receipt) = event.payload else { return event }
            return .init(operationID: event.operationID, epoch: event.epoch, sequence: event.sequence, payload: .completed(messageID: id, finalTextHash: hash, visionReceipt: receipt))
        }
        observations[operationID] = .init(request: old.request, events: events)
    }
}
actor PresentationConversationBackend: ConversationBackend {
    private let forgedGoal: Bool
    init(forgedGoal: Bool) { self.forgedGoal = forgedGoal }
    func connection(scope: DataScope) async -> ConversationConnection { .init(state: .connected, provider: "Explicit compiled presentation fixture", detail: "No network/model") }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let id = UUID(), text = "Synthetic prose remains readable"
        let goals = forgedGoal ? [ConversationGoalProjection(id: "forged-presentation-goal", revision: 1, title: "Must not acquire authority", state: .completed, summary: "Fixture only", updatedAt: Date(timeIntervalSince1970: 0))] : []
        return AsyncThrowingStream { c in
            c.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .toolStarted(callID: "presentation", name: "present_cgui_v1", arguments: "{}")))
            c.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 2, payload: .toolResult(.init(callID: "presentation", name: "present_cgui_v1", content: "{}", committedGoals: goals))))
            c.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 3, payload: .textDelta(messageID: id, text: text)))
            c.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 4, payload: .completed(messageID: id, finalTextHash: textHash(text))))
            c.finish()
        }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation { throw ConversationSessionError.invalidEvent }
}

/// Proposals are confirmations-to-do, never domain memory or delegated work.
actor MemoryProposalConversationBackend:ConversationBackend {
    enum Mode {case proposed,empty,forgedGoal,missingTyped,changedContent,failed,lostResponse}
    let mode:Mode
    private var posts=0,reads=0
    private var originals:[UUID:ConversationObservation]=[:]
    init(_ mode:Mode){self.mode=mode}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.connected,provider:"Synthetic memory proposal",detail:"No HTTP/model")}
    func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        posts+=1
        let user=request.history.last!,message=UUID(),call="memory-proposal",reply="Review the memory candidates before confirming."
        let raw:[String:Any]=["schema_version":1,"contract":"catpaw.memory-proposal.v1","scope_id":UUID().uuidString,"conversation_id":request.conversationID.uuidString,"turn_id":request.operationID.uuidString,"source_id":user.id.uuidString,"source_hash":textHash(user.content),"memory_generation":1,"job_id":UUID().uuidString,"candidates":mode == .empty ? []:[["id":UUID().uuidString,"version":1]],"status":"proposed","confirmed":false]
        let data=try JSONSerialization.data(withJSONObject:raw,options:.sortedKeys),receipt=try ConversationMemoryProposalReceipt.decode(data,request:request)
        var content=raw;if mode == .changedContent {content["confirmed"]=true}
        let goals:[ConversationGoalProjection]=mode == .forgedGoal ? [.init(id:"must-not-exist",revision:1,title:"Forged memory task",state:.completed,summary:"",updatedAt:Date())]:[]
        var events:[ConversationTurnEvent]=[]
        func emit(_ payload:ConversationTurnEvent.Payload){events.append(.init(operationID:request.operationID,epoch:request.epoch,sequence:events.count+1,payload:payload))}
        emit(.toolStarted(callID:call,name:"propose_memory_v1",arguments:"{}"))
        if mode == .failed {emit(.failed(message:"Synthetic proposal extraction failure",reconciliationRequired:false))}
        else {
            emit(.toolResult(.init(callID:call,name:"propose_memory_v1",content:String(decoding:try JSONSerialization.data(withJSONObject:content,options:.sortedKeys),as:UTF8.self),committedGoals:goals,memoryProposalReceipt:mode == .missingTyped ? nil:receipt)))
            emit(.textDelta(messageID:message,text:reply));emit(.completed(messageID:message,finalTextHash:textHash(reply)))
        }
        originals[request.operationID] = .init(request:request,events:events)
        let delivered=mode == .lostResponse ? Array(events.prefix(1)):events
        return AsyncThrowingStream{stream in for event in delivered{stream.yield(event)};stream.finish()}
    }
    func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {reads+=1;guard let original=originals[request.operationID] else{throw ConversationSessionError.invalidEvent};return original}
    func counts()->[Int] {[posts,reads]}
}
private func memoryProposalSessionChecks(directory:URL) async throws {
    for mode in [MemoryProposalConversationBackend.Mode.proposed,.empty,.forgedGoal,.missingTyped,.changedContent,.failed,.lostResponse] {
        let url=directory.appendingPathComponent("proposal-"+String(describing:mode)+".json"),backend=MemoryProposalConversationBackend(mode)
        let service=ConversationSessionService(repository:try Repository(persistence:FilePersistence(url:url)),backend:backend),conversation=try await service.create(scope:Profiles.user),operation=UUID()
        do{_=try await service.send(scope:Profiles.user,conversationID:conversation,text:"Remember a fictional preference, after confirmation.",operationID:operation)}catch{}
        let saved=try await service.read(scope:Profiles.user,conversationID:conversation)
        try require(saved.goals.isEmpty,"Memory proposal \(mode) cannot become a task Goal")
        if mode == .proposed || mode == .empty {
            guard let message=saved.messages.first(where:{$0.role == .tool && $0.toolName=="propose_memory_v1"}) else{throw ConversationSessionError.invalidEvent}
            let receipt=try ConversationMemoryProposalReceipt.transcript(message,session:saved)
            try require(saved.turns.last?.state == .completed && !receipt.confirmed && receipt.candidates.isEmpty==(mode == .empty),"Memory proposal \(mode) retains validated pending references and readable prose")
        }else if mode == .failed {
            try require(saved.turns.last?.state == .failed && saved.messages.contains(where:{$0.toolName=="propose_memory_v1" && $0.failure != nil}),"Started then failed memory extraction keeps its own failure state")
        }else if mode == .lostResponse {
            try require(saved.turns.last?.state == .unknown,"Lost proposal response remains unknown before original GET")
            let cold=ConversationSessionService(repository:try Repository(persistence:FilePersistence(url:url)),backend:backend)
            try await cold.observe(scope:Profiles.user,conversationID:conversation)
            let recovered=try await cold.read(scope:Profiles.user,conversationID:conversation),counts=await backend.counts()
            try require(recovered.turns.last?.id==operation && recovered.turns.last?.state == .completed && recovered.goals.isEmpty && counts==[1,1],"Cold memory proposal recovery reads the original operation without another submission")
        }else{try require(saved.turns.last?.state == .unknown && saved.messages.allSatisfy({$0.role != .tool}),"Forged/missing typed/changed memory receipt \(mode) cannot persist a proposal result")}
    }
}

// R2 stop: cancelCurrentTurn → POST cancel, one `.failed(cancelled)` on turnEvents, no resend.
actor CancelScenarioBackend: ConversationBackend {
    enum Mode: Sendable { case cancelled, raced, readBackFails }
    let mode: Mode
    let message = UUID()
    private var transportFailures: Int
    private var live: AsyncThrowingStream<ConversationTurnEvent, Error>.Continuation?
    private(set) var replies = 0, cancels = 0, observes = 0
    init(mode: Mode, transportFailures: Int = 0) { self.mode = mode; self.transportFailures = transportFailures }
    func connection(scope: DataScope) async -> ConversationConnection { ConversationConnection(state: .connected, provider: "Explicit test backend", detail: "Test only") }
    func reply(_ r: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        replies += 1
        let (stream, c) = AsyncThrowingStream.makeStream(of: ConversationTurnEvent.self)
        c.yield(ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 1, payload: .textDelta(messageID: message, text: "部分回答")))
        live = c // stays open like a running SSE turn
        return stream
    }
    private func terminal(_ r: ConversationTurnRequest) -> ConversationTurnEvent {
        ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 2, payload: mode == .raced ? .completed(messageID: message, finalTextHash: textHash("部分回答")) : .failed(message: "cancelled", reconciliationRequired: false))
    }
    func cancelTurn(_ r: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt {
        cancels += 1
        if transportFailures > 0 { transportFailures -= 1; throw ConversationTurnCancelFailure.transport }
        live?.yield(terminal(r)); live?.finish(); live = nil // the stream's own terminal event races the response
        return mode == .raced ? .init(turnID: r.operationID, state: "completed", cancelled: false, alreadyTerminal: true)
                              : .init(turnID: r.operationID, state: "failed", cancelled: true, alreadyTerminal: false)
    }
    func observe(_ r: ConversationTurnRequest) async throws -> ConversationObservation {
        observes += 1
        if mode == .readBackFails && observes == 1 { throw CatpawError.unavailable("offline read-back") }
        return ConversationObservation(request: r, events: [ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: 1, payload: .textDelta(messageID: message, text: "部分回答")), terminal(r)])
    }
    func counts() -> [Int] { [replies, cancels, observes] }
}
actor CancelEventLog {
    private(set) var items: [String] = []
    func add(_ e: ConversationTurnEvent) {
        switch e.payload {
        case .failed(let code, _): items.append("failed:" + code)
        case .completed: items.append("completed")
        case .textDelta: items.append("delta")
        default: items.append("other")
        }
    }
}
func cancelSessionChecks(directory: URL) async throws {
    func scenario(_ name: String, _ backend: CancelScenarioBackend) async throws -> (ConversationSessionService, UUID, UUID, CancelEventLog, Task<Void, Never>) {
        let repository = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("cancel-\(name).json")))
        let service = ConversationSessionService(repository: repository, backend: backend)
        let conversation = try await service.create(scope: Profiles.user)
        let log = CancelEventLog(), events = await service.turnEvents()
        let collector = Task { for await e in events { await log.add(e) } }
        let operation = UUID()
        let sending = Task { _ = try? await service.send(scope: Profiles.user, conversationID: conversation, text: "写一段长回答", operationID: operation) }
        for _ in 0..<200 {
            if try await service.read(scope: Profiles.user, conversationID: conversation).turns.last?.lastSequence == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = sending
        return (service, conversation, operation, log, collector)
    }
    func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    do {
        let backend = CancelScenarioBackend(mode: .cancelled, transportFailures: 1)
        let (service, conversation, operation, log, collector) = try await scenario("cancelled", backend)
        let outcome = try await service.cancelCurrentTurn(scope: Profiles.user, conversationID: conversation)
        let again = try await service.cancelCurrentTurn(scope: Profiles.user, conversationID: conversation)
        try await settle(); collector.cancel()
        let saved = try await service.read(scope: Profiles.user, conversationID: conversation)
        let items = await log.items, counts = await backend.counts()
        try require(outcome == .cancelled(operationID: operation) && again == .noActiveTurn, "cancelCurrentTurn ends the running turn as cancelled; a second stop finds no active turn")
        try require(items.filter { $0 == "failed:cancelled" }.count == 1 && items.first == "delta", "turnEvents receives exactly one failed(cancelled) although stream and response both report it")
        try require(saved.turns.last?.state == .failed && saved.turns.last?.error == "cancelled" && saved.turns.last?.lastSequence == 2 && saved.messages.contains(where: { $0.role == .assistant && $0.content == "部分回答" }), "the stopped turn keeps the partial answer and the server sequence")
        try require(counts == [1, 2, 1], "a transport error resends the idempotent cancel; the turn is never re-POSTed")
        try require(saved.unresolved == nil, "the next message is an ordinary new turn")
    }
    do {
        let backend = CancelScenarioBackend(mode: .raced)
        let (service, conversation, operation, log, collector) = try await scenario("raced", backend)
        let outcome = try await service.cancelCurrentTurn(scope: Profiles.user, conversationID: conversation)
        try await settle(); collector.cancel()
        let saved = try await service.read(scope: Profiles.user, conversationID: conversation)
        let items = await log.items
        try require(outcome == .completed(operationID: operation) && saved.turns.last?.state == .completed && items.last == "completed" && !items.contains(where: { $0.hasPrefix("failed") }), "cancelled=false/state=completed reads the turn back and emits completed")
    }
    do {
        let backend = CancelScenarioBackend(mode: .readBackFails)
        let (service, conversation, operation, log, collector) = try await scenario("readback", backend)
        let outcome = try await service.cancelCurrentTurn(scope: Profiles.user, conversationID: conversation)
        let pending = try await service.read(scope: Profiles.user, conversationID: conversation)
        try await service.observe(scope: Profiles.user, conversationID: conversation)
        try await settle(); collector.cancel()
        let resolved = try await service.read(scope: Profiles.user, conversationID: conversation)
        let items = await log.items
        try require(outcome == .reconciling(operationID: operation) && pending.turns.last?.state == .unknown, "a failed read-back leaves the turn unknown for reconciliation")
        try require(resolved.turns.last?.state == .failed && resolved.turns.last?.error == "cancelled" && items.filter { $0 == "failed:cancelled" }.count == 1, "later reconciliation applies the server stop without a second cancelled event")
    }
}
@main struct ConversationSessionRunner {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try await memoryProposalSessionChecks(directory:directory)
        try await cancelSessionChecks(directory:directory)
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
        // The existing deployed server omits blank prose when completing a delegation receipt.
        // ECMAScript trim includes BOM; NEL remains actual text and must be preserved.
        for toolName in ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"] {
          for (label, text, persisted) in [("empty", "", false), ("server whitespace", " \t\n\u{00A0}\u{FEFF}", false), ("NEL", "\u{0085}", true), ("actual prose", " 已受理 ", true)] {
            let path = directory.appendingPathComponent("delegation-\(toolName)-\(label).json")
            let receiptBackend = DelegationReceiptConversationBackend(text: text, serverPersistsAssistant: persisted, toolName: toolName)
            let receiptService = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: path)), backend: receiptBackend)
            let cid = try await receiptService.create(scope: Profiles.user), original = UUID()
            _ = try await receiptService.send(scope: Profiles.user, conversationID: cid, text: "Synthetic research goal", operationID: original)
            let reopened = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: path)), backend: receiptBackend)
            try await reopened.observe(scope: Profiles.user, conversationID: cid)
            let beforeFollowup = try await reopened.read(scope: Profiles.user, conversationID: cid)
            let prose = beforeFollowup.messages.filter { $0.role == .assistant && $0.toolName == nil }
            try require(beforeFollowup.turns.last?.id == original && beforeFollowup.turns.last?.state == .completed && beforeFollowup.goals["synthetic-delegation"]?.state == .working && prose.map(\.content) == (persisted ? [text] : []), "\(toolName) \(label) delegation preserves committed turn and task projection while matching the server transcript after read-only restart")
            _ = try await reopened.send(scope: Profiles.user, conversationID: cid, text: "Synthetic modification of the same work", operationID: UUID())
            let captured = await receiptBackend.captured(), final = try await reopened.read(scope: Profiles.user, conversationID: cid)
            try require(captured.count == 2 && final.turns.count == 2 && final.turns.allSatisfy({ $0.state == .completed }) && captured[1].history.contains(where: { $0.toolName == toolName && $0.role == .tool }), "\(toolName) \(label) delegation accepts follow-up using the original tool receipt without transcript conflict or another delegation")
          }
        }
        // Preserve the former client journal representation and verify repair only on an
        // authoritative read of its original completion, without submitting that turn again.
        let legacyPath = directory.appendingPathComponent("legacy-blank-delegation.json")
        let legacyRepo = try Repository(persistence: FilePersistence(url: legacyPath)), legacyBackend = DelegationReceiptConversationBackend(text: "", serverPersistsAssistant: false)
        let legacyService = ConversationSessionService(repository: legacyRepo, backend: legacyBackend), legacyID = try await legacyService.create(scope: Profiles.user), legacyOperation = UUID()
        _ = try await legacyService.send(scope: Profiles.user, conversationID: legacyID, text: "Synthetic former-client delegation", operationID: legacyOperation)
        var legacy = try await legacyService.read(scope: Profiles.user, conversationID: legacyID)
        guard let legacyMessage = legacy.turns.last?.assistantMessageID else { throw CatpawError.missing }
        let otherReply = ConversationTranscriptMessage(role: .assistant, content: "")
        legacy.messages.insert(otherReply, at: 0); await legacyBackend.prependHistoricalReply(otherReply)
        legacy.messages.append(.init(id: legacyMessage, role: .assistant, content: ""))
        let journal = try await legacyRepo.record(stableID("conversation-first-journal-\(legacyID)"), scope: Profiles.user)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await legacyRepo.commit(scope: Profiles.user, mutations: [.update(journal.id, journal.header.revision, .preference(.init(key: "conversation_session:\(legacyID)", value: String(decoding: try encoder.encode(legacy), as: UTF8.self))))])
        let repaired = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: legacyPath)), backend: legacyBackend)
        await legacyBackend.replaceObservedTerminalHash(operationID: legacyOperation, hash: textHash("different completion"))
        var legacyHashRejected = false
        do { try await repaired.observe(scope: Profiles.user, conversationID: legacyID) } catch ConversationSessionError.invalidEvent { legacyHashRejected = true }
        let unchangedLegacy = try await repaired.read(scope: Profiles.user, conversationID: legacyID)
        try require(legacyHashRejected && unchangedLegacy.messages.contains(where: { $0.id == legacyMessage }) && unchangedLegacy.messages.contains(where: { $0.id == otherReply.id }), "same-ID completion with a mismatched hash cannot rewrite former-client or unrelated blank history")
        await legacyBackend.replaceObservedTerminalHash(operationID: legacyOperation, hash: textHash(""))
        try await repaired.observe(scope: Profiles.user, conversationID: legacyID)
        let legacyRead = try await repaired.read(scope: Profiles.user, conversationID: legacyID)
        try require(legacyRead.turns.last?.id == legacyOperation && legacyRead.turns.last?.state == .completed && legacyRead.messages.allSatisfy({ $0.id != legacyMessage }) && legacyRead.messages.contains(where: { $0.id == otherReply.id && $0.content.isEmpty }) && legacyRead.goals["synthetic-delegation"]?.state == .working, "original completion read repairs only its former-client blank row while preserving unrelated history and committed identities")
        _ = try await repaired.send(scope: Profiles.user, conversationID: legacyID, text: "Synthetic same-work follow-up after repair", operationID: UUID())
        try require(await legacyBackend.captured().count == 2, "former-client delegation repair is read-only and admits only the new follow-up")
        let invalidBackend = DelegationReceiptConversationBackend(text: "", serverPersistsAssistant: false, terminalHash: textHash("mismatched terminal"))
        let invalidService = ConversationSessionService(repository: repository, backend: invalidBackend), invalidID = try await invalidService.create(scope: Profiles.user)
        var invalidTerminalRejected = false
        do { _ = try await invalidService.send(scope: Profiles.user, conversationID: invalidID, text: "Synthetic invalid terminal", operationID: UUID()) } catch ConversationSessionError.invalidEvent { invalidTerminalRejected = true }
        let invalidSaved = try await invalidService.read(scope: Profiles.user, conversationID: invalidID)
        try require(invalidTerminalRejected && invalidSaved.turns.last?.state == .unknown && invalidSaved.goals["synthetic-delegation"]?.state == .working, "blank delegation still requires the exact terminal text hash and cannot declare task completion")
        let presentation = ConversationSessionService(repository: repository, backend: PresentationConversationBackend(forgedGoal: false)), presentationID = try await presentation.create(scope: Profiles.user)
        _ = try await presentation.send(scope: Profiles.user, conversationID: presentationID, text: "Synthetic compiled presentation", operationID: UUID())
        let presented = try await presentation.read(scope: Profiles.user, conversationID: presentationID)
        try require(presented.turns.last?.state == .completed && presented.goals.isEmpty && presented.messages.contains(where: { $0.role == .assistant && $0.toolName == nil && $0.content == "Synthetic prose remains readable" }), "explicit offline presentation receipt preserves ordinary prose without acquiring task authority")
        let forged = ConversationSessionService(repository: repository, backend: PresentationConversationBackend(forgedGoal: true)), forgedID = try await forged.create(scope: Profiles.user)
        var forgeryRejected = false
        do { _ = try await forged.send(scope: Profiles.user, conversationID: forgedID, text: "Synthetic forged presentation authority", operationID: UUID()) } catch ConversationSessionError.invalidEvent { forgeryRejected = true }
        let forgery = try await forged.read(scope: Profiles.user, conversationID: forgedID)
        try require(forgeryRejected && forgery.turns.last?.state == .unknown && forgery.goals.isEmpty && forgery.messages.filter({ $0.role == .tool }).isEmpty, "presentation tool cannot smuggle committed goals or a completion receipt into domain state")
    }
}
