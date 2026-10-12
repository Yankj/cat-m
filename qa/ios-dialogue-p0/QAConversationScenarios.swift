import Foundation
import SwiftUI
#if canImport(CatpawM)
@testable import CatpawM
#endif

// Only public model/service/repository boundaries are observed. No HTTP or Auth.
actor QAGatedBackend: ConversationBackend {
    let base = P0ScriptedBackend()
    var holdReads = false, holdReady = false, readCalls = 0
    var readWaiters: [Int:CheckedContinuation<Void,Never>] = [:]
    var readyWaiters: [CheckedContinuation<Void,Never>] = []
    func modelConsent(scope:DataScope,conversationID:UUID) async throws -> ConversationModelConsent? { try await base.modelConsent(scope:scope,conversationID:conversationID) }
    func connection(scope:DataScope) async -> ConversationConnection {
        if holdReady { await withCheckedContinuation { readyWaiters.append($0) } }
        return await base.connection(scope:scope)
    }
    func reply(_ r:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> { try await base.reply(r) }
    func observe(_ r:ConversationTurnRequest) async throws -> ConversationObservation {
        readCalls += 1
        let number=readCalls
        if holdReads { await withCheckedContinuation { readWaiters[number]=$0 } }
        return try await base.observe(r)
    }
    func gate(reads:Bool = false,ready:Bool = false) { holdReads=reads;holdReady=ready }
    func reads() -> Int { readCalls }
    func releaseRead(_ number:Int) { readWaiters.removeValue(forKey:number)?.resume() }
    func release() {
        holdReads=false;holdReady=false
        for c in readWaiters.values { c.resume() };readWaiters=[:]
        for c in readyWaiters { c.resume() };readyWaiters=[]
    }
}

@MainActor enum QAConversationScenarios {
    static func require(_ ok:Bool,_ reason:String) throws { if !ok { throw CatpawError.invalid(reason) } }
    static func until(_ predicate:() async throws -> Bool) async throws {
        for _ in 0..<3000 { if try await predicate() { return };try await Task.sleep(nanoseconds:1_000_000) }
        throw CatpawError.invalid("QA public-state deadline")
    }
    static func persistence(_ path:URL) throws -> any SnapshotPersistence {
        #if os(iOS)
        return try SwiftDataPersistence(url:path)
        #else
        return FilePersistence(url:path)
        #endif
    }
    static func fixture(_ root:URL) throws -> (ConversationFirstModel,QAGatedBackend,Repository,ConversationSessionService) {
        let repo=try Repository(persistence:persistence(root.appendingPathComponent(UUID().uuidString+".store")))
        let backend=QAGatedBackend(),service=ConversationSessionService(repository:repo,backend:backend)
        return (ConversationFirstModel(repository:repo,service:service),backend,repo,service)
    }

    // Same behavioral requirement on both versions; the adapter maps each public API.
    // Build13 has no public outgoing/checking state. No reflection or private fields.
    static func consentFeedback(_ root:URL) async throws {
        let (model,b,_,_)=try fixture(root);await model.start();await b.base.setConsentHold()
        let text="Synthetic consent pending 🐾";model.editDraft(text);model.prepareSend()
        #if QA_PENDING
        let id=model.outgoingMessages.first?.id
        let immediate=model.outgoingMessages.first?.text == text && model.outgoingMessages.first?.state == .savingLocal
        #else
        let immediate=model.busy || model.enqueueing || model.sending || model.pendingModelConsent != nil || model.error != nil
        #endif
        try await until { await b.base.isConsentWaiting() }
        var stable=true
        for _ in 0..<20 {
            #if QA_PENDING
            stable = stable && model.checkingModelConsent && model.outgoingMessages.count == 1 && model.outgoingMessages.first?.id == id && model.outgoingMessages.first?.text == text && [.queued,.awaitingPermission].contains(model.outgoingMessages.first!.state)
            #else
            stable = stable && (model.busy || model.enqueueing || model.sending || model.pendingModelConsent != nil || model.error != nil)
            #endif
            try await Task.sleep(nanoseconds:100_000_000)
        }
        let counts=await b.base.counts(),turns=model.session?.turns.count
        await model.deactivate();await b.base.releaseConsent();await b.release()
        try require(immediate && stable && counts[0] == 0 && turns == 0,"pending consent lacked stable local acknowledgement; no presented-frame timing measured")
    }

    #if QA_PENDING
    static func duplicateTapAndIntentFIFO(_ root:URL) async throws {
        let (m,b,r,s)=try fixture(root);await m.start();await b.base.setConsentHold()
        m.editDraft("Synthetic identical 🐾");for _ in 0..<12 { m.prepareSend() }
        try require(m.outgoingMessages.count == 1,"duplicate taps captured the consumed draft more than once")
        let first=m.outgoingMessages[0].id
        m.editDraft("Synthetic identical 🐾");m.prepareSend();let second=m.outgoingMessages[1].id
        m.editDraft("later unsent draft\n原文🐾")
        try await until { await b.base.isConsentWaiting() && !m.enqueueing }
        try require(first != second,"separate identical submissions lost independent IDs")
        await b.base.releaseConsent()
        try await until { await b.base.has(first) };try await b.base.finish(first,"first answer")
        try await until { await b.base.has(second) };try await b.base.finish(second,"second answer")
        try await until { m.session?.turns.count == 2 && m.session?.turns.allSatisfy({$0.state == .completed}) == true && !m.busy }
        let id=m.conversationID!;try await m.flushDraft()
        let saved=try await s.read(scope:Profiles.user,conversationID:id),record=try await r.record(id,scope:Profiles.user),counts=await b.base.counts()
        await m.deactivate()
        try require(saved.turns.map(\.id) == [first,second] && saved.messages.filter({$0.role == .user}).count == 2 && counts[0] == 2 && record.conversation?.draftText == "later unsent draft\n原文🐾","FIFO or later draft was lost")
    }
    static func repeatedReadRecoversUnknownOnce(_ root:URL) async throws {
        let (m,b,_,s)=try fixture(root);await m.start();m.editDraft("Synthetic unknown");m.prepareSend();let original=m.outgoingMessages[0].id
        try await until { await b.base.has(original) };await m.suspend()
        try await b.base.finish(original,"remote complete while detached")
        await b.gate(reads:true);await m.resumeForeground();try await until { await b.reads() == 1 }
        for _ in 0..<12 { m.readOriginal() }
        let heldReads=await b.reads();try require(heldReads == 1 && m.busy,"duplicate read actions created observers")
        await b.release();try await until { m.session?.turns.first?.state == .completed && !m.busy && m.observerLifecycle == .foregroundIdle }
        _ = try await s.send(scope:Profiles.user,conversationID:m.conversationID!,text:"Synthetic unknown",operationID:original)
        let c=await b.base.counts(),saved=m.session!;await m.deactivate()
        try require(c[0] == 1 && saved.turns.count == 1 && saved.turns[0].id == original && saved.messages.filter({$0.role == .assistant}).count == 1,"unknown recovery resent or duplicated original")
    }
    static func foregroundReadIndependentOfReadiness(_ root:URL) async throws {
        let (m,b,_,_)=try fixture(root);await m.start();m.editDraft("Synthetic original");m.prepareSend();let id=m.outgoingMessages[0].id
        try await until { await b.base.has(id) };await m.suspend();try await b.base.finish(id,"completed original")
        await b.gate(ready:true);await m.resumeForeground()
        try await until { m.session?.turns.first?.state == .completed && !m.busy }
        let c=await b.base.counts(),phase=m.observerLifecycle;await b.release();await m.deactivate()
        try require(c[0] == 1 && c[1] >= 1 && phase == .foregroundIdle,"readiness blocked original GET or observer remained stuck")
    }
    static func staleReadCannotClearReplacement(_ root:URL) async throws {
        let (m,b,_,_)=try fixture(root);await m.start();m.editDraft("Synthetic observer replacement");m.prepareSend();let original=m.outgoingMessages[0].id
        try await until { await b.base.has(original) };try await b.base.delta(original,"partial original")
        try await until { m.session?.turns.first?.lastSequence == 2 };await m.suspend()
        await b.gate(reads:true);await m.resumeForeground();try await until { await b.reads() == 1 }
        await m.suspend();await m.resumeForeground();try await until { await b.reads() == 2 }
        await b.releaseRead(1);try await Task.sleep(nanoseconds:50_000_000)
        let replacementRetained=m.busy && m.observerLifecycle == .reconnecting && m.session?.turns.first?.state == .unknown
        try await b.base.finish(original," complete")
        await b.releaseRead(2);try await until { m.session?.turns.first?.state == .completed && !m.busy }
        let saved=m.session!,counts=await b.base.counts();await b.release();await m.deactivate()
        try require(replacementRetained && counts[0] == 1 && counts[1] == 2 && saved.turns.count == 1 && saved.turns[0].id == original && saved.messages.filter({$0.role == .assistant}).map(\.content) == ["partial original complete"],"late cancelled observation cleared or mutated its foreground replacement")
    }
    static func userPauseAndDraftSurviveReopen(_ root:URL) async throws {
        let path=root.appendingPathComponent(UUID().uuidString+".store"),repo=try Repository(persistence:persistence(path)),service=ConversationSessionService(repository:repo)
        let cid=try await service.openLatest(scope:Profiles.user),q=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid),message=ConversationFollowup(text:"paused original 🐾")
        try await service.saveDraft(scope:Profiles.user,conversationID:cid,text:"remaining draft\n中文🐾")
        try await q.enqueue(message,remainingDraft:"remaining draft\n中文🐾");try await q.pause();try await q.pause(reason:.background);try await q.resume(backgroundOnly:true)
        let reopened=try Repository(persistence:persistence(path)),rq=ConversationFollowupQueueService(repository:reopened,scope:Profiles.user,conversationID:cid)
        let state=try await rq.state(),record=try await reopened.record(cid,scope:Profiles.user)
        try require(state.paused && state.pauseReason == .user && state.pending.map(\.id) == [message.id] && record.conversation?.draftText == "remaining draft\n中文🐾","user pause/draft did not survive reopen")
        try await rq.resume();let resumed=try await rq.state();try require(!resumed.paused && resumed.pending.map(\.id) == [message.id],"explicit resume changed queued intent")
    }
    static func compositionGuard(_ root:URL) async throws {
        let (m,b,_,_)=try fixture(root);await m.start();let original="拼音 nihao\nsecond line🐾";m.editDraft(original);m.updateInputComposition(true)
        for _ in 0..<12 { m.prepareSend() }
        let c=await b.base.counts();try require(!m.canAcceptDraft && m.draft == original && m.outgoingMessages.isEmpty && c[0] == 0,"marked text model guard changed draft or sent")
        m.updateInputComposition(false);await b.base.setConsentHold();m.prepareSend();try await until { await b.base.isConsentWaiting() }
        let accepted=m.outgoingMessages.first?.text == original;await m.deactivate();await b.base.releaseConsent()
        try require(accepted,"committed composition did not preserve exact original")
    }
    #if os(iOS)
    static func swiftDataAdmissionRollback(_ root:URL) async throws {
        let path=root.appendingPathComponent(UUID().uuidString+".store"),storage=try SwiftDataPersistence(url:path),repo=try Repository(persistence:storage),b=QAGatedBackend(),service=ConversationSessionService(repository:repo,backend:b),m=ConversationFirstModel(repository:repo,service:service)
        await m.start();let text="保存失败原文\n🐾";m.editDraft(text);try await m.flushDraft();let before=await repo.read(scope:Profiles.user)
        storage.failNextSaveForTesting();m.prepareSend();try await until { m.outgoingMessages.first?.state == .failed && !m.enqueueing }
        let cid=m.conversationID!,after=await repo.read(scope:Profiles.user),counts=await b.base.counts()
        let reopened=try Repository(persistence:SwiftDataPersistence(url:path)),record=try await reopened.record(cid,scope:Profiles.user),queue=ConversationFollowupQueueService(repository:reopened,scope:Profiles.user,conversationID:cid),state=try await queue.state()
        let preserved=m.draft == text;await m.deactivate()
        try require(after.sequence == before.sequence && counts[0] == 0 && state.pending.isEmpty && record.conversation?.draftText == text && preserved,"SwiftData failed admission committed partial queue/draft or called provider")
    }
    #endif
    #endif
    static func cases() -> [(String,(URL) async throws -> Void)] {
        var all:[(String,(URL) async throws -> Void)] = [("consent_held_2s_stable_local_feedback",consentFeedback)]
        #if QA_PENDING
        all += [("duplicate_tap_consumes_draft_once_identical_intents_FIFO",duplicateTapAndIntentFIFO),("held_read_deduplicates_and_recovers_original_unknown",repeatedReadRecoversUnknownOnce),("foreground_original_read_independent_of_readiness",foregroundReadIndependentOfReadiness),("late_observer_cannot_clear_foreground_replacement",staleReadCannotClearReplacement),("user_pause_exact_draft_and_queue_reopen",userPauseAndDraftSurviveReopen),("composition_guard_then_exact_committed_text",compositionGuard)]
        #if os(iOS)
        all += [("swiftdata_admission_failure_atomic_rollback_reopen",swiftDataAdmissionRollback)]
        #endif
        #endif
        return all
    }
    static func run(_ root:URL) async -> [[String:String]] {
        var results:[[String:String]]=[]
        for (name,body) in cases() {
            do { try await body(root);results.append(["case":name,"status":"PASS"]);print("PASS: "+name) }
            catch { results.append(["case":name,"status":"FAIL","error":error.localizedDescription]);print("FAIL: "+name+" — "+error.localizedDescription) }
        }
        return results
    }
}
