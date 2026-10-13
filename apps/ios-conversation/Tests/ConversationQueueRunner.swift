import Foundation
actor QueueSendLog {
    var ids: [UUID] = []
    var continuation: CheckedContinuation<Void,Never>?
    var waiting: CheckedContinuation<Void,Never>?
    func send(_ message: ConversationFollowup) async { ids.append(message.id); if ids.count == 1 { await withCheckedContinuation { continuation = $0; waiting?.resume(); waiting = nil } } }
    func untilFirst() async { if continuation != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func captured() -> [UUID] { ids }
}
actor QueueEditBackend:ConversationBackend {
    var admitting=false
    var finishes=true
    var sent:[UUID]=[]
    func allow(){admitting=true}
    func leaveUnknown(){finishes=false}
    func captured()->[UUID]{sent}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.providerUnverified,provider:"Synthetic queue edit",detail:"No external network")}
    func reply(_ r:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        guard admitting else {throw ConversationDispatchFailure.notSent(reason:"Synthetic proof of no POST")}
        sent.append(r.operationID)
        let message=stableID("queue-edit-reply-\(r.operationID)"),body="Synthetic edited reply"
        return AsyncThrowingStream {c in
            c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:1,payload:.started(requestHash:textHash(r.operationID.uuidString),conversationRevision:1,grantEpoch:1)))
            c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:2,payload:.textDelta(messageID:message,text:body)))
            if finishes {c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:3,payload:.completed(messageID:message,finalTextHash:textHash(body))))}
            c.finish()
        }
    }
    func observe(_ r:ConversationTurnRequest) async throws -> ConversationObservation {throw CatpawError.missing}
}
@main struct ConversationQueueRunner {
    static func main() async throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("queue.json")
        let repo = try Repository(persistence: FilePersistence(url: path)), service = ConversationSessionService(repository: repo)
        let id = try await service.openLatest(scope: Profiles.user)
        let queue = ConversationFollowupQueueService(repository: repo, scope: Profiles.user, conversationID: id)
        func check(_ good: Bool, _ text: String) throws { guard good else { throw CatpawError.invalid(text) }; print("PASS: " + text) }
        let a = ConversationFollowup(text: "first"), b = ConversationFollowup(text: "second"), c = ConversationFollowup(text: "third")
        try await queue.enqueue(a); try await queue.enqueue(b)
        let log = QueueSendLog()
        let flush = Task { try await queue.flush { message in await log.send(message); return .sent } }
        await log.untilFirst()
        try await queue.enqueue(c)
        try await queue.flush { message in await log.send(message); return .sent }
        let crashed = ConversationFollowupQueueService(repository: try Repository(persistence: FilePersistence(url: path)), scope: Profiles.user, conversationID: id)
        let crashState = try await crashed.state()
        var inflightRejected = false
        do { try await crashed.resume() } catch ConversationSessionError.unresolvedOperation { inflightRejected = true }
        try check(crashState.paused && crashState.inflight?.id == a.id && inflightRejected, "restart with durable in-flight intent holds original identity instead of dispatching again")
        let before = await log.captured()
        try check(before == [a.id], "one active run while new follow-ups can be added")
        try await queue.pause(); await log.release(); try await flush.value
        var state = try await queue.state()
        try check(state.paused && state.pending.map(\.id) == [b.id,c.id], "pause holds ordered follow-ups and never sends the next message")
        let edited=try await queue.edit(b,text:"edited second",session:service)
        state=try await queue.state()
        try check(state.paused && state.pending.map(\.id) == [edited.id,c.id] && edited.id != b.id,"edit stays paused, uses a fresh intent identity and preserves queue order")
        var staleRejected=false
        do {_=try await queue.edit(b,text:"stale replacement",session:service)} catch CatpawError.conflict {staleRejected=true}
        try check(staleRejected,"stale editor cannot overwrite or recreate a replaced message")
        var activeRejected=false
        do {_=try await queue.edit(a,text:"change admitted intent",session:service)} catch CatpawError.conflict {activeRejected=true}
        try check(activeRejected,"an in-flight or already sent item cannot be edited through the queue")
        let disk = ConversationFollowupQueueService(repository: try Repository(persistence: FilePersistence(url: path)), scope: Profiles.user, conversationID: id)
        state = try await disk.state()
        try check(state.paused && state.pending.map(\.text) == ["edited second","third"], "edited follow-ups and pause survive real repository restart")
        try await queue.resume(); try await queue.flush { message in await log.send(message); return .sent }
        let order = await log.captured()
        try check(order == [a.id,edited.id,c.id], "explicit resume drains edited follow-ups in order once")
        let d = ConversationFollowup(text: "server refused before admission")
        try await queue.enqueue(d); try await queue.flush { _ in .heldBeforeAdmission }
        state = try await queue.state()
        try check(state.paused && state.pending.map(\.id) == [d.id], "known pre-admission refusal restores same message to queue front on hold")
        try await queue.resume()
        do { try await queue.flush { message in await log.send(message); throw CatpawError.unavailable("explicit test failure after transcript admission") } } catch { }
        try await queue.resume(); try await queue.flush { message in await log.send(message); return .sent }
        let failures = await log.captured()
        try check(failures.filter { $0 == d.id }.count == 1, "failed admitted message is never implicitly resent")
        let e = ConversationFollowup(text: "remove only this")
        try await queue.enqueue(e); try await queue.remove(e.id)
        state = try await queue.state(); try check(state.pending.isEmpty, "user can remove an unsent follow-up")
        let cross = ConversationFollowupQueueService(repository: repo, scope: Profiles.demo, conversationID: id)
        var rejected = false; do { _ = try await cross.state() } catch CatpawError.scopeMismatch { rejected = true }
        try check(rejected, "queue state cannot cross scope")
        let backend=QueueEditBackend(),editingService=ConversationSessionService(repository:repo,backend:backend)
        let editingConversation=try await editingService.create(scope:Profiles.user)
        let editingQueue=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:editingConversation)
        let original=ConversationFollowup(text:"known refusal before POST")
        try await editingQueue.enqueue(original)
        try await editingQueue.flush {message in
            do {_=try await editingService.send(scope:Profiles.user,conversationID:editingConversation,text:message.text,operationID:message.id);return .sent}
            catch is ConversationDispatchFailure {return .heldBeforeAdmission}
        }
        let replacement=try await editingQueue.edit(original,text:"replacement after known refusal",session:editingService)
        let saved=try await editingService.read(scope:Profiles.user,conversationID:editingConversation),held=try await editingQueue.state()
        try check(saved.turns.first?.state == .cancelledBeforeSend && saved.messages.isEmpty && held.paused && held.pending.map(\.id) == [replacement.id],"known no-POST journal cancellation and edited queue commit together")
        var invalidRejected=false
        do {_=try await editingQueue.edit(replacement,text:String(repeating:"x",count:8001),session:editingService)} catch {invalidRejected=true}
        let afterInvalid=try await editingQueue.state()
        try check(invalidRejected && afterInvalid.pending.first?.text == replacement.text,"invalid edit leaves the saved pending message intact")
        await backend.allow();try await editingQueue.resume()
        try await editingQueue.flush {message in
            _=try await editingService.send(scope:Profiles.user,conversationID:editingConversation,text:message.text,operationID:message.id);return .sent
        }
        let completed=try await editingService.read(scope:Profiles.user,conversationID:editingConversation),sent=await backend.captured()
        try check(completed.turns.last?.state == .completed && completed.messages.first?.content == replacement.text && sent == [replacement.id],"explicit resume sends the changed payload once without replaying its cancelled request")
        await backend.leaveUnknown()
        let unknown=ConversationFollowup(text:"synthetic interrupted original")
        do {_=try await editingService.send(scope:Profiles.user,conversationID:editingConversation,text:unknown.text,operationID:unknown.id)} catch ConversationSessionError.unresolvedOperation {}
        // A stale queue entry must not authorize rewriting an original unknown request.
        try await editingQueue.enqueue(unknown);try await editingQueue.pause()
        var unknownRejected=false
        do {_=try await editingQueue.edit(unknown,text:"must never replace unknown",session:editingService)} catch ConversationSessionError.unresolvedOperation {unknownRejected=true}
        let unchanged=try await editingQueue.state(),unknownSession=try await editingService.read(scope:Profiles.user,conversationID:editingConversation)
        try check(unknownRejected && unchanged.pending.first?.id == unknown.id && unknownSession.unresolved?.id == unknown.id,"unknown request remains immutable even if a stale pending queue entry exists")
        print("EVIDENCE: migrated public queue behavior; transport actions in tests are explicit test closures")
    }
}
