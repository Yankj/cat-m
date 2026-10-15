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
    func acceptedWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {capability}
    func ensureConversationForExplicitSend(_ request:ConversationTurnRequest) async throws {ensureCalls += 1}
    func freezeAcceptedWork(_ request:ConversationTurnRequest,selection:ConversationAcceptedWorkSelection) async throws -> ConversationAcceptedWorkIntent {freezeCalls += 1;return try .init(request:request,selection:selection,expectedRevision:1,expectedGrantEpoch:1)}
    func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        let record=try await repository.record(stableID("conversation-first-journal-\(request.conversationID)"),scope:request.scope)
        guard case .preference(let value)=record.payload else {throw ConversationSessionError.invalidEvent}
        let saved=try JSONDecoder().decode(ConversationSession.self,from:Data(value.value.utf8))
        try deviceCheck(saved.turns.last?.request.acceptedWork==request.acceptedWork && request.acceptedWork != nil,"Exact finite wire must already be durable before a dispatch callback")
        replyCalls += 1;throw DeviceEffectTestFailure("Named response loss after dispatch checkpoint")
    }
    func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {readCalls += 1;try request.acceptedWork?.validate(request:request);return .init(request:request,events:[])}
    func counters()->[Int] {[ensureCalls,freezeCalls,replyCalls,readCalls]}
}

private enum AcceptedWorkApplicationMatrix {
    struct Case {let name:String;let run:() async throws -> Void}
    static func capability(available:Bool=true)->ConversationAcceptedWorkCapability {.init(available:available,routeHash:textHash("named synthetic accepted work route"),subjectID:stableID("named synthetic accepted work subject"),serverScopeID:stableID("named synthetic accepted work server scope"))}
    static func options()->ConversationAcceptedWorkOptions {.init(notAfter:Date().addingTimeInterval(3600),executionBudgetMilliseconds:60000,modelLimit:3,sourceLimit:0,toolPolicy:.localOutput)}
    static func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("accepted-work-application-"+UUID().uuidString)}
    static var cases:[Case] {[
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
