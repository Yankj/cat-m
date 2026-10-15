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
actor QueueHistoryBackend:ConversationBackend {
    var admitting=false
    var histories:[UUID:[UUID]]=[:]
    var server:[ConversationTranscriptMessage]?=nil
    func allow(){admitting=true}
    func setServer(_ value:[ConversationTranscriptMessage]?){server=value}
    func serverTranscript(scope:DataScope,conversationID:UUID) async throws -> [ConversationTranscriptMessage]? {server}
    func history(_ id:UUID)->[UUID]?{histories[id]}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.providerUnverified,provider:"Synthetic history",detail:"No external network")}
    func reply(_ r:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        guard admitting else {throw ConversationDispatchFailure.notSent(reason:"Synthetic consent not yet granted")}
        histories[r.operationID]=r.history.map(\.id)
        let message=stableID("queue-history-reply-\(r.operationID)"),body="Synthetic reply"
        return AsyncThrowingStream {c in
            c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:1,payload:.started(requestHash:textHash(r.operationID.uuidString),conversationRevision:1,grantEpoch:1)))
            c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:2,payload:.textDelta(messageID:message,text:body)))
            c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:3,payload:.completed(messageID:message,finalTextHash:textHash(body))))
            c.finish()
        }
    }
    func observe(_ r:ConversationTurnRequest) async throws -> ConversationObservation {throw CatpawError.missing}
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
        try check(state.pauseReason == .preflight, "pre-admission hold is recorded as a preflight pause")
        let behind = ConversationFollowup(text: "typed while held")
        try await queue.enqueue(behind); try await queue.flush { message in await log.send(message); return .sent }
        state = try await queue.state()
        let capturedIDs = await log.captured()
        try check(state.paused && state.pending.map(\.id) == [d.id,behind.id] && !capturedIDs.contains(d.id), "regression: a new message queues silently behind a preflight hold (simulator '待发送·2 条')")
        let resumed = try await queue.resumePreflightHold()
        state = try await queue.state()
        try check(resumed && !state.paused && state.pauseReason == nil && state.pending.map(\.id) == [d.id,behind.id], "a fresh send clears a preflight hold without reordering")
        try await queue.flush { _ in .heldBeforeAdmission }
        try await queue.pause()
        let userResumed = try await queue.resumePreflightHold(); let userPaused = try await queue.state().paused
        try check(!userResumed && userPaused, "a user pause is never cleared by the preflight resume")
        try await queue.remove(behind.id)
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
        // Regression (simulator stuck at "已保存在本机 · 待发送"): a message refused before POST stays in the local
        // transcript as notSent. It must not enter later turns' wire history, or the server (0 messages) never
        // matches and every following send is refused as a conflict, pausing the queue forever.
        let hb=QueueHistoryBackend(),hs=ConversationSessionService(repository:repo,backend:hb)
        let hc=try await hs.create(scope:Profiles.user),hq=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:hc)
        let refused=ConversationFollowup(text:"你是？")
        try await hq.enqueue(refused)
        try await hq.flush {m in do {_=try await hs.send(scope:Profiles.user,conversationID:hc,text:m.text,operationID:m.id,preserveDraft:true);return .sent} catch is ConversationDispatchFailure {return .heldBeforeAdmission}}
        var hstate=try await hq.state(),hsaved=try await hs.read(scope:Profiles.user,conversationID:hc)
        try check(hstate.paused && hstate.pauseReason == .preflight && hsaved.turns.first?.state == .notSent && hsaved.messages.count == 1,"refusal before consent journals notSent and holds the queue (preflight)")
        await hb.allow()
        let later=ConversationFollowup(text:"第二条")
        try await hq.enqueue(later)
        try check(try await hq.resumePreflightHold(),"consent/new send clears the preflight hold")
        try await hq.flush {m in do {_=try await hs.send(scope:Profiles.user,conversationID:hc,text:m.text,operationID:m.id,preserveDraft:true);return .sent} catch is ConversationDispatchFailure {return .heldBeforeAdmission}}
        hstate=try await hq.state();hsaved=try await hs.read(scope:Profiles.user,conversationID:hc)
        let firstUser=stableID("conversation-user-\(refused.id)"),laterUser=stableID("conversation-user-\(later.id)")
        try check(hstate.pending.isEmpty && !hstate.paused && hsaved.turns.allSatisfy{$0.state == .completed},"held message and the one behind it are both sent after consent")
        let resentHistory=await hb.history(refused.id),laterHistory=await hb.history(later.id)
        try check(resentHistory?.last == firstUser && resentHistory?.count == 1,"resent held message carries only itself (server had nothing)")
        try check(laterHistory?.count == 3 && laterHistory?.first == firstUser && laterHistory?.last == laterUser,"later message history is exactly the admitted prefix plus itself")
        // Server-only messages (old chat: b09acdc3 admitted by an outbox turn, never written back) merge into the
        // local transcript idempotently, by server id, keeping local-only unsent messages and failure notices.
        let t0=Date(timeIntervalSince1970:1_000)
        let known=ConversationTranscriptMessage(role:.user,content:"早",createdAt:t0)
        var notice=ConversationTranscriptMessage(role:.assistant,content:"消息尚未发送",createdAt:t0.addingTimeInterval(5));notice.failure="notSent"
        let unsentLocal=ConversationTranscriptMessage(role:.user,content:"你是？",createdAt:t0.addingTimeInterval(6))
        let serverOnlyUser=ConversationTranscriptMessage(role:.user,content:String(repeating:"x",count:128),createdAt:.distantPast)
        let serverOnlyReply=ConversationTranscriptMessage(role:.assistant,content:"服务端回复",createdAt:.distantPast)
        let serverList=[known,serverOnlyUser,serverOnlyReply]
        let merged=ConversationSessionService.mergeServerTranscript(local:[known,notice,unsentLocal],server:serverList)
        try check(merged.map(\.id)==[known.id,notice.id,unsentLocal.id,serverOnlyUser.id,serverOnlyReply.id],"server-only rows are added after the last known server row; local unsent and failure notices are kept")
        try check(merged.filter{$0.id==notice.id}.first?.failure=="notSent","local failure notice keeps its metadata")
        try check(merged[3].createdAt>=merged[2].createdAt && merged[4].createdAt>=merged[3].createdAt,"server-only rows get non-decreasing createdAt")
        let again=ConversationSessionService.mergeServerTranscript(local:merged,server:serverList)
        try check(again.map(\.id)==merged.map(\.id),"merge is idempotent (dedup by server id)")
        let between=ConversationSessionService.mergeServerTranscript(local:[known,serverOnlyReply],server:[known,serverOnlyUser,serverOnlyReply])
        try check(between.map(\.id)==[known.id,serverOnlyUser.id,serverOnlyReply.id],"a server-only row between two known rows is inserted in server order")
        let sb=QueueHistoryBackend(),ss=ConversationSessionService(repository:repo,backend:sb),sc=try await ss.create(scope:Profiles.user)
        await sb.setServer([serverOnlyUser,serverOnlyReply])
        let synced=try await ss.syncServerTranscript(scope:Profiles.user,conversationID:sc)
        let syncedSession=try await ss.read(scope:Profiles.user,conversationID:sc)
        try check(synced && syncedSession.messages.map(\.id)==[serverOnlyUser.id,serverOnlyReply.id],"sync writes server-only messages into the local journal so the UI shows them")
        let second=try await ss.syncServerTranscript(scope:Profiles.user,conversationID:sc)
        try check(!second,"second sync is a no-op")
        print("EVIDENCE: migrated public queue behavior; transport actions in tests are explicit test closures")
    }
}
