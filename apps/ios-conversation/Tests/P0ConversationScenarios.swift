import Foundation
import SwiftUI
#if canImport(cat)
@testable import cat
#endif

actor P0ScriptedBackend: ConversationBackend {
    var requests:[UUID:ConversationTurnRequest]=[:],events:[UUID:[ConversationTurnEvent]]=[:]
    var streams:[UUID:AsyncThrowingStream<ConversationTurnEvent,Error>.Continuation]=[:]
    var sends=0,reads=0,holdConsent=false,consentWaiting=false,wrongObservation=false
    private var consent:CheckedContinuation<ConversationModelConsent?,Error>?
    func setConsentHold(){holdConsent=true}
    func modelConsent(scope:DataScope,conversationID:UUID) async throws -> ConversationModelConsent? {
        if !holdConsent{return nil};return try await withCheckedThrowingContinuation{consent=$0;consentWaiting=true}
    }
    func releaseConsent(){consent?.resume(returning:nil);consent=nil;consentWaiting=false}
    func connection(scope:DataScope) async -> ConversationConnection{.init(state:.providerUnverified,provider:"QA local scripted backend",detail:"No Auth or model requests")}
    func start(_ r:ConversationTurnRequest)->ConversationTurnEvent{.init(operationID:r.operationID,epoch:r.epoch,sequence:1,payload:.started(requestHash:textHash("p0:"+r.operationID.uuidString),conversationRevision:1,grantEpoch:1))}
    func reply(_ r:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error>{
        sends+=1;requests[r.operationID]=r;let initial=start(r);events[r.operationID]=[initial]
        return AsyncThrowingStream{c in streams[r.operationID]=c;c.yield(initial);c.onTermination={ [weak self] _ in guard let owner=self else{return};Task{await owner.detach(r.operationID)}}}
    }
    func detach(_ id:UUID){streams.removeValue(forKey:id)}
    func has(_ id:UUID)->Bool{requests[id] != nil}
    func counts()->[Int]{[sends,reads]}
    func isConsentWaiting()->Bool{consentWaiting}
    func setWrongObservation(){wrongObservation=true}
    func delta(_ id:UUID,_ value:String) throws{
        guard let r=requests[id] else{throw catError.missing};let e=ConversationTurnEvent(operationID:id,epoch:r.epoch,sequence:events[id]!.count+1,payload:.textDelta(messageID:stableID("p0-assistant-"+id.uuidString),text:value));events[id]!.append(e);streams[id]?.yield(e)
    }
    func finish(_ id:UUID,_ suffix:String) throws{
        guard let r=requests[id] else{throw catError.missing};var rest=suffix
        while !rest.isEmpty{let piece=String(rest.prefix(128));rest=String(rest.dropFirst(piece.count));try delta(id,piece)}
        let full=events[id]!.compactMap{e->String? in if case .textDelta(_,let t)=e.payload{return t};return nil}.joined()
        let e=ConversationTurnEvent(operationID:id,epoch:r.epoch,sequence:events[id]!.count+1,payload:.completed(messageID:stableID("p0-assistant-"+id.uuidString),finalTextHash:textHash(full)));events[id]!.append(e);streams[id]?.yield(e);streams[id]?.finish()
    }
    func observe(_ r:ConversationTurnRequest) async throws -> ConversationObservation{
        reads+=1;guard let saved=requests[r.operationID] else{throw catError.missing}
        let request=wrongObservation ? ConversationTurnRequest(scope:r.scope,conversationID:r.conversationID,threadID:r.threadID,operationID:UUID(),epoch:r.epoch,history:r.history):saved
        return .init(request:request,events:events[r.operationID]!,requestHash:textHash("p0:"+r.operationID.uuidString),grantEpoch:1,goals:[])
    }
}

@MainActor enum P0ConversationScenarios {
    static func until(_ body:() async throws->Bool) async throws{
        for _ in 0..<2000{if try await body(){return};try await Task.sleep(nanoseconds:1_000_000)};throw catError.invalid("QA phase deadline")
    }
    static func run(root:URL) async -> [[String:Any]] {
        var result:[[String:Any]]=[]
        func fixture() throws ->(P0ScriptedBackend,ConversationSessionService,Repository){
            let backend=P0ScriptedBackend(),repo=try Repository(persistence:FilePersistence(url:root.appendingPathComponent(UUID().uuidString+".json")))
            return(backend,ConversationSessionService(repository:repo,backend:backend),repo)
        }
        func check(_ name:String,_ body:() async throws->Bool) async {
            do{let ok=try await body();result.append(["case":name,"status":ok ? "PASS":"FAIL","layer":"portable actual Swift model/service + scripted backend; no iOS display evidence"]);print((ok ? "PASS: ":"FAIL: ")+name)}
            catch{result.append(["case":name,"status":"FAIL","error_type":String(describing:type(of:error))]);print("FAIL: "+name+" ("+String(describing:type(of:error))+")")}
        }
        await check("consent_preflight_requires_stable_visible_pending_state"){
            let(b,s,r)=try fixture();await b.setConsentHold();let model=ConversationFirstModel(repository:r,service:s);await model.start();model.editDraft("Synthetic local draft");model.prepareSend();try await until{await b.isConsentWaiting()}
            let acknowledged=model.checkingModelConsent && model.outgoingMessages.contains(where: { $0.text == "Synthetic local draft" && [.queued,.awaitingPermission].contains($0.state) }) && model.session?.turns.isEmpty == true
            // This checks observable state during a blocked preflight, not press duration or rendered latency.
            await model.deactivate();await b.releaseConsent();return acknowledged
        }
        for size in [32,4096,16384]{await check("stream_\(size)_characters_exact_body_single_message_terminal_hash"){
            let(b,s,_)=try fixture(),cid=try await s.openLatest(scope:Profiles.user),tid=UUID(),text=String(String(repeating:"中文🐾ABC\n",count:size/7+1).prefix(size))
            let send=Task{try await s.send(scope:Profiles.user,conversationID:cid,text:"synthetic",operationID:tid)};try await until{await b.has(tid)};try await b.finish(tid,text);_ = try await send.value
            let saved=try await s.read(scope:Profiles.user,conversationID:cid),answers=saved.messages.filter{$0.role == .assistant},counts=await b.counts()
            return saved.turns.count == 1 && saved.turns[0].id == tid && saved.turns[0].state == .completed && answers.count == 1 && answers[0].content == text && answers[0].complete && textHash(answers[0].content)==textHash(text) && counts[0] == 1
        }}
        for seconds in [5,30]{await check("detached_remote_progress_same_turn_resume_\(seconds)s_scenario"){
            let(b,s,_)=try fixture(),cid=try await s.openLatest(scope:Profiles.user),tid=UUID(),prefix="前台已收到。",tail="后台继续完成。"
            let send=Task{try await s.send(scope:Profiles.user,conversationID:cid,text:"synthetic",operationID:tid)};try await until{await b.has(tid)};try await b.delta(tid,prefix)
            try await until{try await s.read(scope:Profiles.user,conversationID:cid).turns.last?.lastSequence == 2};try await s.stopObserving(scope:Profiles.user,conversationID:cid);send.cancel();_ = try? await send.value
            // Server continues independently. The 5s/30s here are scenario labels; actual scene timing is a device gate.
            try await b.finish(tid,tail);try await s.observe(scope:Profiles.user,conversationID:cid);try await s.observe(scope:Profiles.user,conversationID:cid)
            let saved=try await s.read(scope:Profiles.user,conversationID:cid),counts=await b.counts(),answer=saved.messages.filter{$0.role == .assistant}
            return counts == [1,2] && saved.turns.count == 1 && saved.turns[0].id == tid && saved.turns[0].state == .completed && answer.count == 1 && answer[0].content == prefix+tail && answer[0].complete
        }}
        await check("unknown_or_completed_same_operation_never_replies_again"){
            let(b,s,_)=try fixture(),cid=try await s.openLatest(scope:Profiles.user),tid=UUID();let send=Task{try await s.send(scope:Profiles.user,conversationID:cid,text:"synthetic",operationID:tid)};try await until{await b.has(tid)}
            try await s.stopObserving(scope:Profiles.user,conversationID:cid);send.cancel();_ = try? await send.value
            _ = try await s.send(scope:Profiles.user,conversationID:cid,text:"synthetic",operationID:tid);let unknown=try await s.read(scope:Profiles.user,conversationID:cid);try await b.finish(tid,"complete");try await s.observe(scope:Profiles.user,conversationID:cid)
            _ = try await s.send(scope:Profiles.user,conversationID:cid,text:"synthetic",operationID:tid);let final=try await s.read(scope:Profiles.user,conversationID:cid),counts=await b.counts()
            return unknown.turns[0].state == .unknown && final.turns[0].state == .completed && counts[0] == 1 && final.messages.filter{$0.role == .user}.count == 1
        }
        await check("foreign_observation_rejected_without_text_mutation"){
            let(b,s,_)=try fixture(),cid=try await s.openLatest(scope:Profiles.user),tid=UUID();let send=Task{try await s.send(scope:Profiles.user,conversationID:cid,text:"synthetic",operationID:tid)};try await until{await b.has(tid)}
            try await s.stopObserving(scope:Profiles.user,conversationID:cid);send.cancel();_ = try? await send.value;let before=try await s.read(scope:Profiles.user,conversationID:cid);await b.setWrongObservation();var rejected=false
            do{try await s.observe(scope:Profiles.user,conversationID:cid)}catch ConversationSessionError.invalidEvent{rejected=true};let after=try await s.read(scope:Profiles.user,conversationID:cid)
            return rejected && before.messages.map(\.content)==after.messages.map(\.content) && after.turns.count == 1 && after.turns[0].id == tid
        }
        return result
    }
}
