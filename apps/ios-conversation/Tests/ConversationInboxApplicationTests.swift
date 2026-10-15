import Foundation
import XCTest
@testable import CatpawM

/// Named synthetic inputs exercise real journal, file persistence and host selection.
/// Maintained HTTP bytes and actual native interaction are tested separately.
private actor InboxHostFixtureBackend:ConversationBackend,ConversationInboxBackend {
    let item:ConversationInboxItem,goal:ConversationGoalProjection,reference:ConversationInboxReference
    private var replyCalls=0
    init(item:ConversationInboxItem,goal:ConversationGoalProjection,reference:ConversationInboxReference){self.item=item;self.goal=goal;self.reference=reference}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.providerUnverified,provider:"Named offline inbox host",detail:"No HTTP/Auth/model/SQL")}
    func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        replyCalls+=1
        let message=stableID("offline-inbox-reply-"+request.operationID.uuidString),body="Named offline completion"
        let payloads:[ConversationTurnEvent.Payload]=[.started(requestHash:textHash("named offline inbox turn"),conversationRevision:1,grantEpoch:1),.toolStarted(callID:item.binding.call_id,name:"delegate_task",arguments:"{}"),.toolResult(.init(callID:item.binding.call_id,name:"delegate_task",content:String(decoding:try JSONEncoder().encode(item.binding),as:UTF8.self),committedGoals:[goal])),.textDelta(messageID:message,text:body),.completed(messageID:message,finalTextHash:textHash(body))]
        return AsyncThrowingStream {stream in for (index,payload) in payloads.enumerated(){stream.yield(.init(operationID:request.operationID,epoch:request.epoch,sequence:index+1,payload:payload))};stream.finish()}
    }
    func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {
        .init(request:request,events:[],requestHash:textHash("named offline inbox turn"),grantEpoch:1,goals:request.conversationID==item.binding.conversation_id ? [goal]:[])
    }
    func count()->Int {replyCalls}
    func readInbox(reference:ConversationInboxReference,cursor:String?,limit:Int) async throws -> ConversationInboxPage {.init(scopeID:self.reference.serverScopeID,subjectID:self.reference.subjectID,items:[item])}
    func readReceivedTask(reference:ConversationInboxReference,item:ConversationInboxItem) async throws -> ConversationGoalProjection {goal}
}
@MainActor final class ConversationInboxApplicationTests:XCTestCase {
    private struct Fixture {let path:URL,repository:Repository,session:ConversationSessionService,backend:InboxHostFixtureBackend,inbox:ConversationInboxService,model:ConversationFirstModel,item:ConversationInboxItem,b:UUID}
    private func fixture(seedOriginal:Bool=true) async throws -> Fixture {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent("inbox-host-"+UUID().uuidString).appendingPathComponent("store.json")
        let repository=try Repository(persistence:FilePersistence(url:path)),a=UUID(),b=UUID(),turn=UUID(),server=UUID(),subject=UUID(),run=UUID()
        let binding=ConversationTaskBinding(scope_id:server,conversation_id:a,turn_id:turn,call_id:"named-offline-inbox-call",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash("named offline inbox task"),request_hash:textHash("named offline inbox request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+server.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        let body=String(decoding:try JSONSerialization.data(withJSONObject:["kind":"report","title":"Named offline report","summary":"Synthetic only","data":["content":"Immutable synthetic report body"]],options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
        let artifact=ConversationArtifactProjection(id:textHash("named offline artifact"),version:1,contentHash:textHash(body),body:body,title:"Named offline report",summary:"Synthetic only",content:"Immutable synthetic report body")
        let reference=ConversationInboxReference(scope:Profiles.user,serverScopeID:server,subjectID:subject)
        let item=ConversationInboxItem(binding:binding,title:artifact.title,createdAt:"2026-10-15T00:00:00.000Z",updatedAt:"2026-10-15T00:01:00.000Z",taskStatus:.succeeded,authorizationState:.current,artifacts:[.init(artifactID:artifact.id,version:1,contentHash:artifact.contentHash)],planReference:nil,pendingActionCount:0)
        var goal=ConversationGoalProjection(id:binding.task_id,revision:1,title:artifact.title,state:.completed,summary:artifact.summary,updatedAt:Date());goal.binding=binding;goal.artifacts=[artifact];goal.sourceAuthorizationCurrent=true
        let backend=InboxHostFixtureBackend(item:item,goal:goal,reference:reference),session=ConversationSessionService(repository:repository,backend:backend)
        if seedOriginal {_=try await session.create(scope:Profiles.user,id:a);_=try await session.send(scope:Profiles.user,conversationID:a,text:"Named original A",operationID:turn)}
        _=try await session.create(scope:Profiles.user,id:b);try await session.rememberSelection(scope:Profiles.user,conversationID:b)
        let inbox=ConversationInboxService(reference:reference,backend:backend),model=ConversationFirstModel(repository:repository,service:session,inboxService:inbox,subjectID:subject)
        await model.start();await model.resumeForeground();XCTAssertEqual(model.conversationID,b)
        return .init(path:path,repository:repository,session:session,backend:backend,inbox:inbox,model:model,item:item,b:b)
    }
    func testInspectionKeepsBAndExplicitReturnPreservesExactDraftThroughColdReopen() async throws {
        let f=try await fixture(),raw="B unsent draft \u{4e2d}\u{6587} \u{1f431}\n  whitespace remains  "
        f.model.editDraft(raw)
        _=try await f.inbox.refresh();let resolved=try await f.inbox.resolve(item:f.item)
        XCTAssertEqual(resolved.artifacts.first?.contentHash,f.item.artifacts.first?.contentHash)
        XCTAssertEqual(f.model.conversationID,f.b);XCTAssertEqual(f.model.draft,raw)
        let priorCount=await f.backend.count();let returned=await f.model.returnToReceivedWork(f.item);XCTAssertTrue(returned)
        XCTAssertEqual(f.model.conversationID,f.item.binding.conversation_id)
        XCTAssertEqual(f.model.session?.goals[f.item.binding.task_id]?.artifacts.first?.contentHash,f.item.artifacts.first?.contentHash)
        try await f.model.select(f.b);XCTAssertEqual(f.model.draft,raw)
        let afterCount=await f.backend.count();XCTAssertEqual(afterCount,priorCount,"Retrieval and navigation must not dispatch")
        _=await f.model.deactivate()
        let reopened=try Repository(persistence:FilePersistence(url:f.path)),saved=try await reopened.record(f.b,scope:Profiles.user)
        XCTAssertEqual(saved.conversation?.draftText,raw)
        let cold=ConversationSessionService(repository:reopened,backend:f.backend),selected=try await cold.openLatest(scope:Profiles.user)
        XCTAssertEqual(selected,f.b)
    }
    func testMissingOriginalJournalDoesNotCreateConversationOrDiscardB() async throws {
        let f=try await fixture(seedOriginal:false);f.model.editDraft("B exact pending draft")
        _=try await f.inbox.refresh();let returned=await f.model.returnToReceivedWork(f.item);XCTAssertFalse(returned)
        XCTAssertEqual(f.model.conversationID,f.b);XCTAssertEqual(f.model.draft,"B exact pending draft")
        let snapshot=await f.repository.read(scope:Profiles.user)
        XCTAssertNil(snapshot.records[f.item.binding.conversation_id]);let count=await f.backend.count();XCTAssertEqual(count,0)
        _=await f.model.deactivate()
    }
    func testEverySelectionReadGateCanCancelWithoutHalfSwitchingBPresentation() async throws {
        let f=try await fixture(),raw="B draft held during target reads"
        for rejectAt in 1...7 {
            f.model.editDraft(raw);var checks=0
            do {try await f.model.select(f.item.binding.conversation_id,admission:{checks+=1;return checks<rejectAt});XCTFail("Expected read gate cancellation")}
            catch is CancellationError {}catch {XCTFail("Unexpected selection failure: "+String(describing:error))}
            XCTAssertEqual(f.model.conversationID,f.b,"Gate \(rejectAt)")
            XCTAssertEqual(f.model.draft,raw,"Gate \(rejectAt)")
            XCTAssertNil(f.model.artifactContinuation);XCTAssertFalse(f.model.busy)
            let selected=try await f.session.openLatest(scope:Profiles.user);XCTAssertEqual(selected,f.b,"Cancelled navigation must restore its exact preference revision")
        }
        _=await f.model.deactivate()
    }
    func testNewConversationStillCreatesAndSelectsItsOwnQueueAfterAtomicSelectionChange() async throws {
        let f=try await fixture();f.model.editDraft("B original draft before new conversation")
        f.model.newConversation()
        for _ in 0..<500 {if f.model.conversationID != f.b {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNotEqual(f.model.conversationID,f.b,f.model.error ?? "No selection error")
        XCTAssertEqual(f.model.draft,"")
        try await f.model.select(f.b);XCTAssertEqual(f.model.draft,"B original draft before new conversation")
        _=await f.model.deactivate()
    }
    func testComposingAndClosedAdmissionCannotSwitchOrWriteOriginal() async throws {
        let f=try await fixture();_=try await f.inbox.refresh()
        f.model.updateInputComposition(true);let composing=await f.model.returnToReceivedWork(f.item);XCTAssertFalse(composing);XCTAssertEqual(f.model.conversationID,f.b)
        f.model.updateInputComposition(false);f.model.setNetworkAdmissionAllowed(false)
        let closed=await f.model.returnToReceivedWork(f.item);XCTAssertFalse(closed);XCTAssertEqual(f.model.conversationID,f.b)
        _=await f.model.deactivate()
    }
}
