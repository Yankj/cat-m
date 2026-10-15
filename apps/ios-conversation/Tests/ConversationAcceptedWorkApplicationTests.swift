import Foundation
#if !ACCEPTED_WORK_APPLICATION_PORTABLE
import XCTest
@testable import CatpawM
#endif

private actor AcceptedWorkJournalBackend:ConversationBackend {
    let repository:Repository
    let capability:ConversationAcceptedWorkCapability
    var ensureCalls=0,freezeCalls=0,replyCalls=0,readCalls=0
    init(repository:Repository,capability:ConversationAcceptedWorkCapability){self.repository=repository;self.capability=capability}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.providerUnverified,provider:"named synthetic journal checkpoint",detail:"No HTTP, Auth or model")}
    nonisolated var supportsArtifactContinuations:Bool {true}
    nonisolated var artifactContinuationSubjectID:UUID? {capability.subjectID}
    func revisionWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {capability}
    func freezeRevisionWork(_ request:ConversationTurnRequest,selection:ConversationRevisionWorkSelection) async throws -> ConversationRevisionWorkIntent {freezeCalls += 1;return try .init(request:request,selection:selection,expectedRevision:2,expectedGrantEpoch:1)}
    func acceptedWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {capability}
    func ensureConversationForExplicitSend(_ request:ConversationTurnRequest) async throws {ensureCalls += 1}
    func freezeAcceptedWork(_ request:ConversationTurnRequest,selection:ConversationAcceptedWorkSelection) async throws -> ConversationAcceptedWorkIntent {freezeCalls += 1;return try .init(request:request,selection:selection,expectedRevision:1,expectedGrantEpoch:1)}
    func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        let record=try await repository.record(stableID("conversation-first-journal-\(request.conversationID)"),scope:request.scope)
        guard case .preference(let value)=record.payload else {throw ConversationSessionError.invalidEvent}
        let saved=try JSONDecoder().decode(ConversationSession.self,from:Data(value.value.utf8))
        if let revision=request.revisionWork {try deviceCheck(saved.turns.last?.request.revisionWork==revision,"Exact new revision wrapper must already be durable before dispatch")}
        else {try deviceCheck(saved.turns.last?.request.acceptedWork==request.acceptedWork && request.acceptedWork != nil,"Exact finite wire must already be durable before a dispatch callback")}
        replyCalls += 1;throw DeviceEffectTestFailure("Named response loss after dispatch checkpoint")
    }
    func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {readCalls += 1;try request.acceptedWork?.validate(request:request);try request.revisionWork?.validate(request:request);return .init(request:request,events:[])}
    func counters()->[Int] {[ensureCalls,freezeCalls,replyCalls,readCalls]}
}

private enum AcceptedWorkApplicationMatrix {
    struct Case {let name:String;let run:() async throws -> Void}
    static func capability(available:Bool=true)->ConversationAcceptedWorkCapability {.init(available:available,routeHash:textHash("named synthetic accepted work route"),subjectID:stableID("named synthetic accepted work subject"),serverScopeID:stableID("named synthetic accepted work server scope"))}
    static func options()->ConversationAcceptedWorkOptions {.init(notAfter:Date().addingTimeInterval(3600),executionBudgetMilliseconds:60000,modelLimit:3,sourceLimit:0,toolPolicy:.localOutput)}
    static func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("accepted-work-application-"+UUID().uuidString)}
    static func revisionReference(conversation:UUID,capability:ConversationAcceptedWorkCapability)->ConversationArtifactContinuationReference {
        let run=UUID(),binding=ConversationTaskBinding(scope_id:capability.serverScopeID!,conversation_id:conversation,turn_id:UUID(),call_id:"synthetic-original-call",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash("synthetic-task"),request_hash:textHash("synthetic-original-request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+capability.serverScopeID!.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        return .init(scope:Profiles.user,subjectID:capability.subjectID!,goalID:binding.task_id,binding:binding,artifactReference:.init(artifactID:textHash("synthetic-report"),version:1,contentHash:textHash("synthetic-report-body")),planReference:.init(revision:1,planHash:textHash("synthetic-plan")),mode:.reviseReport,taskTitle:"Synthetic original task",artifactTitle:"Synthetic original report")
    }
    static var cases:[Case] {[
        .init(name:"server source policy is exact and cannot downgrade to local or under-budget the catalog") {
            let policy=ConversationRevisionWorkPolicy(toolPolicy:.publicSources,sourceCount:3)
            var selected=options();_=try await deviceReject{try policy.validate(options:selected)}
            selected.toolPolicy = .publicSources;selected.sourceLimit=2;_=try await deviceReject{try policy.validate(options:selected)}
            selected.sourceLimit=3;try policy.validate(options:selected)
            _=try await deviceReject{try ConversationRevisionWorkPolicy(toolPolicy:.publicSources,sourceCount:4).validate()}
            _=try await deviceReject{try ConversationRevisionWorkPolicy(toolPolicy:.localOutput,sourceCount:1).validate()}
            try deviceCheck(selected.toolPolicy == .publicSources && selected.sourceLimit==3,"New source work keeps the exact server policy with explicit sufficient source budget")
        },
        .init(name:"revision target review queue commits atomically and cold keeps exact new decision") {
            let root=directory();defer{try? FileManager.default.removeItem(at:root)}
            let file=FilePersistence(url:root.appendingPathComponent("local.json")),disk=DeviceEffectFailingPersistence(url:file.url),repo=try Repository(persistence:disk),service=ConversationSessionService(repository:repo),cid=try await service.create(scope:Profiles.user),cap=capability()
            let ref=revisionReference(conversation:cid,capability:cap),target=try ref.sendIntent(),composer=ConversationArtifactContinuationService(repository:repo,scope:Profiles.user,subjectID:cap.subjectID),drafts=ConversationAcceptedWorkDraftService(repository:repo,scope:Profiles.user,subjectID:cap.subjectID),queue=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid)
            _=try await composer.activate(ref,ordinaryDraft:"Independent ordinary draft")
            let draft=ConversationAcceptedWorkDraft(conversationID:cid,raw:"Exact revision original 🐾\nsecond line",options:options(),revisionTarget:target);try await drafts.save(draft)
            let coldDraft=try await ConversationAcceptedWorkDraftService(repository:repo,scope:Profiles.user,subjectID:cap.subjectID).read(conversationID:cid)
            try deviceCheck(coldDraft==draft,"Closing/reopening preserves target plus new terms")
            let authorization=try ConversationAcceptedWorkSelection(decisionID:draft.id,options:draft.options,capability:cap),selected=try ConversationRevisionWorkSelection(authorization:authorization,target:target,originalText:draft.raw),message=ConversationFollowup(text:draft.raw,continuation:target,revisionWork:selected),remaining=ConversationArtifactContinuationDraft(reference:ref,raw:"",editSequence:1)
            disk.setFailure(true);_=try await deviceReject{try await queue.enqueue(message,remainingContinuationDraft:remaining,continuationService:composer,acceptedWorkDraft:draft,acceptedWorkDraftService:drafts)};disk.setFailure(false)
            let failed=try await queue.state(),retained=try await drafts.read(conversationID:cid);try deviceCheck(failed.pending.isEmpty && retained==draft,"Failed revision queue cannot clear review or add work")
            try await queue.enqueue(message,remainingContinuationDraft:remaining,continuationService:composer,acceptedWorkDraft:draft,acceptedWorkDraftService:drafts)
            let reopened=try Repository(persistence:file),cold=ConversationFollowupQueueService(repository:reopened,scope:Profiles.user,conversationID:cid),cleared=try await drafts.read(conversationID:cid),composerState=try await composer.state(conversationID:cid)
            try deviceCheck(try await cold.state().pending==[message],"Cold queue retains sameTask/CAS/raw/new-decision and all explicit limits")
            try deviceCheck(cleared==nil && composerState.activeDraft?.raw=="","Review clear and continuation draft clear share one commit")
            try await cold.pause();_=try await deviceReject{_=try await cold.edit(message,text:"Changed revision",session:service)}
            try deviceCheck(try await cold.state().pending==[message],"Changed text cannot inherit new revision decision")
            try deviceCheck(try await reopened.record(cid,scope:Profiles.user).conversation?.draftText=="Independent ordinary draft","Confirmation keeps ordinary draft")
        },
        .init(name:"fresh revision may review an old false authority but ordinary route stays blocked; unknown never reposts") {
            let root=directory();defer{try? FileManager.default.removeItem(at:root)}
            let file=FilePersistence(url:root.appendingPathComponent("local.json")),repo=try Repository(persistence:file),cap=capability(),backend=AcceptedWorkJournalBackend(repository:repo,capability:cap),service=ConversationSessionService(repository:repo,backend:backend),cid=try await service.create(scope:Profiles.user),ref=revisionReference(conversation:cid,capability:cap),target=try ref.sendIntent()
            var saved=try await service.read(scope:Profiles.user,conversationID:cid),goal=ConversationGoalProjection(id:ref.goalID,revision:1,title:"Synthetic task",state:.unknown,summary:"Old grant expired or generation superseded",updatedAt:Date())
            goal.binding=ref.binding;goal.sourceAuthorizationCurrent=false;goal.revisionRequiresNewWork=true;goal.revisionWorkPolicy = .init(toolPolicy:.localOutput,sourceCount:0);goal.planReference=ref.planReference
            goal.artifactHistory=[.init(id:ref.artifactReference.artifactID,version:ref.artifactReference.version,contentHash:ref.artifactReference.contentHash,body:"synthetic-report-body",title:"Synthetic",summary:"Prior",content:"Prior")];saved.goals[goal.id]=goal
            let journal=try await repo.record(stableID("conversation-first-journal-\(cid)"),scope:Profiles.user),encoded=try JSONEncoder().encode(saved)
            try await repo.commit(scope:Profiles.user,mutations:[.update(journal.id,journal.header.revision,.preference(.init(key:"conversation_session:\(cid)",value:String(decoding:encoded,as:UTF8.self))))])
            _=try await deviceReject{_=try await service.send(scope:Profiles.user,conversationID:cid,text:"Unconfirmed change",operationID:UUID(),continuation:target)}
            try deviceCheck(await backend.counters()==[0,0,0,0],"False old authority cannot use ordinary revision route")
            let auth=try ConversationAcceptedWorkSelection(decisionID:UUID(),options:options(),capability:cap),raw="Confirmed exact revision 🐾",selection=try ConversationRevisionWorkSelection(authorization:auth,target:target,originalText:raw),operation=UUID()
            _=try await deviceReject{_=try await service.send(scope:Profiles.user,conversationID:cid,text:raw,operationID:operation,continuation:target,revisionWork:selection)}
            let unknown=try await service.read(scope:Profiles.user,conversationID:cid)
            try deviceCheck(unknown.unresolved?.id==operation && unknown.unresolved?.request.revisionWork?.selection==selection,"Fresh explicitly reviewed revision reaches journal without reusing old authority")
            let cold=ConversationSessionService(repository:try Repository(persistence:file),backend:backend);try await cold.observe(scope:Profiles.user,conversationID:cid)
            _=try await cold.send(scope:Profiles.user,conversationID:cid,text:raw,operationID:operation,continuation:target,revisionWork:selection)
            try deviceCheck(await backend.counters()==[0,1,1,1],"Cold unknown GET and same operation replay never freeze or POST again")
            try deviceCheck(try await cold.read(scope:Profiles.user,conversationID:cid).goals.count==1,"Revision preserves original Task without second Goal")
        },
        .init(name:"cold unconfirmed review preserves original UUID text and expired deadline without authority") {
            let root=directory();defer{try? FileManager.default.removeItem(at:root)}
            let file=FilePersistence(url:root.appendingPathComponent("local.json")),repo=try Repository(persistence:file),service=ConversationSessionService(repository:repo),cid=try await service.create(scope:Profiles.user)
            let cap=capability(),drafts=ConversationAcceptedWorkDraftService(repository:repo,scope:Profiles.user,subjectID:cap.subjectID)
            var terms=options();terms.notAfter=Date(timeIntervalSince1970:100)
            let draft=ConversationAcceptedWorkDraft(conversationID:cid,raw:"Original fictional request 🐾",options:terms);try await drafts.save(draft)
            let coldRepo=try Repository(persistence:file),cold=ConversationAcceptedWorkDraftService(repository:coldRepo,scope:Profiles.user,subjectID:cap.subjectID)
            try deviceCheck(try await cold.read(conversationID:cid)==draft,"Cold read cannot renew deadline or replace original text/UUID")
            try deviceCheck(try await ConversationSessionService(repository:coldRepo).read(scope:Profiles.user,conversationID:cid).turns.isEmpty,"A review is not an admitted turn")
            let foreign=ConversationAcceptedWorkDraftService(repository:coldRepo,scope:Profiles.user,subjectID:UUID());_=try await deviceReject{_=try await foreign.read(conversationID:cid)}
        },
        .init(name:"disk failure rolls back queue plus review clearing; success commits original selection atomically") {
            let root=directory();defer{try? FileManager.default.removeItem(at:root)}
            let file=FilePersistence(url:root.appendingPathComponent("local.json")),disk=DeviceEffectFailingPersistence(url:file.url),repo=try Repository(persistence:disk),cid=try await ConversationSessionService(repository:repo).create(scope:Profiles.user)
            let cap=capability(),drafts=ConversationAcceptedWorkDraftService(repository:repo,scope:Profiles.user,subjectID:cap.subjectID),queue=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid)
            let draft=ConversationAcceptedWorkDraft(conversationID:cid,raw:"Original atomic queue request",options:options());try await drafts.save(draft)
            let selection=try ConversationAcceptedWorkSelection(decisionID:draft.id,options:draft.options,capability:cap),message=ConversationFollowup(text:draft.raw,acceptedWork:selection)
            disk.setFailure(true);_=try await deviceReject{try await queue.enqueue(message,remainingDraft:"",acceptedWorkDraft:draft,acceptedWorkDraftService:drafts)};disk.setFailure(false)
            let held=try await queue.state(),restored=try await drafts.read(conversationID:cid)
            try deviceCheck(held.pending.isEmpty && restored==draft,"Failed queue save cannot clear review")
            try await queue.enqueue(message,remainingDraft:"",acceptedWorkDraft:draft,acceptedWorkDraftService:drafts)
            let cold=try Repository(persistence:file),state=try await ConversationFollowupQueueService(repository:cold,scope:Profiles.user,conversationID:cid).state()
            try deviceCheck(state.pending==[message],"Cold queue keeps exact original decision/options/message UUID")
            let coldDraft=try await ConversationAcceptedWorkDraftService(repository:cold,scope:Profiles.user,subjectID:cap.subjectID).read(conversationID:cid)
            try deviceCheck(coldDraft==nil,"Only confirmed queue commit clears unconfirmed review")
        },
        .init(name:"queued finite text cannot be edited to inherit an old confirmation") {
            let root=directory();defer{try? FileManager.default.removeItem(at:root)}
            let repo=try Repository(persistence:FilePersistence(url:root.appendingPathComponent("local.json"))),service=ConversationSessionService(repository:repo),cid=try await service.create(scope:Profiles.user),cap=capability(),drafts=ConversationAcceptedWorkDraftService(repository:repo,scope:Profiles.user,subjectID:cap.subjectID),queue=ConversationFollowupQueueService(repository:repo,scope:Profiles.user,conversationID:cid)
            let draft=ConversationAcceptedWorkDraft(conversationID:cid,raw:"Original finite request",options:options());try await drafts.save(draft)
            let selected=try ConversationAcceptedWorkSelection(decisionID:draft.id,options:draft.options,capability:cap),message=ConversationFollowup(text:draft.raw,acceptedWork:selected)
            try await queue.enqueue(message,acceptedWorkDraft:draft,acceptedWorkDraftService:drafts);try await queue.pause()
            _=try await deviceReject{_=try await queue.edit(message,text:"Changed request",session:service)}
            try deviceCheck(try await queue.state().pending==[message],"Rejected edit must keep original queued packet")
            try deviceCheck(try await service.read(scope:Profiles.user,conversationID:cid).turns.isEmpty,"Rejected local edit creates no turn")
        },
        .init(name:"frozen wire journal precedes dispatch and cold unknown only observes original UUID") {
            let root=directory();defer{try? FileManager.default.removeItem(at:root)}
            let file=FilePersistence(url:root.appendingPathComponent("local.json")),repo=try Repository(persistence:file),cap=capability(),backend=AcceptedWorkJournalBackend(repository:repo,capability:cap),service=ConversationSessionService(repository:repo,backend:backend),cid=try await service.create(scope:Profiles.user)
            let selected=try ConversationAcceptedWorkSelection(decisionID:UUID(),options:options(),capability:cap),operation=UUID(),raw="Original frozen text 🐾"
            _=try await deviceReject{_=try await service.send(scope:Profiles.user,conversationID:cid,text:raw,operationID:operation,acceptedWork:selected)}
            let saved=try await service.read(scope:Profiles.user,conversationID:cid);try deviceCheck(saved.unresolved?.id==operation && saved.unresolved?.state == .unknown,"Lost callback remains original unknown")
            let coldRepo=try Repository(persistence:file),cold=ConversationSessionService(repository:coldRepo,backend:backend);try await cold.observe(scope:Profiles.user,conversationID:cid)
            _=try await cold.send(scope:Profiles.user,conversationID:cid,text:raw,operationID:operation,acceptedWork:selected)
            try deviceCheck(await backend.counters()==[1,1,1,1],"Recovery and same operation replay never freeze/ensure/dispatch again")
            try deviceCheck(try await cold.read(scope:Profiles.user,conversationID:cid).unresolved?.request.acceptedWork==saved.unresolved?.request.acceptedWork,"Every frozen term remains exact on cold original read")
        },
        .init(name:"stale availability rejects before ensure frozen journal and dispatch") {
            let root=directory();defer{try? FileManager.default.removeItem(at:root)}
            let repo=try Repository(persistence:FilePersistence(url:root.appendingPathComponent("local.json"))),backend=AcceptedWorkJournalBackend(repository:repo,capability:capability(available:false)),service=ConversationSessionService(repository:repo,backend:backend),cid=try await service.create(scope:Profiles.user)
            let selected=try ConversationAcceptedWorkSelection(decisionID:UUID(),options:options(),capability:capability())
            _=try await deviceReject{_=try await service.send(scope:Profiles.user,conversationID:cid,text:"Held before admission",operationID:UUID(),acceptedWork:selected)}
            try deviceCheck(await backend.counters()==[0,0,0,0],"No ensure/freeze/reply for stale capability")
            try deviceCheck(try await service.read(scope:Profiles.user,conversationID:cid).turns.isEmpty,"No dispatched journal or admitted message")
        }
    ]}
}
#if ACCEPTED_WORK_APPLICATION_PORTABLE
@main struct AcceptedWorkApplicationRunner {static func main() async throws {for value in AcceptedWorkApplicationMatrix.cases {do{try await value.run();print("PASS: "+value.name)}catch{print("FAIL: "+value.name+": "+String(describing:error));throw error}};print("LIMIT local FilePersistence/Repository/queue/session composition with a named dispatch checkpoint double; no real server/Auth/model/OS")}}
#else
final class ConversationAcceptedWorkApplicationTests:XCTestCase {func testDurableReviewQueueAndOriginalRequestRecovery() async throws {for value in AcceptedWorkApplicationMatrix.cases {do{try await value.run()}catch{XCTFail(value.name+": "+String(describing:error));throw error}}}}
#endif
