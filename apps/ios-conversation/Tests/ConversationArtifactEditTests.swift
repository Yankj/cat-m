import Foundation
#if ARTIFACT_EDIT_PORTABLE
import Darwin
@main private enum ConversationArtifactEditPortableRunner {
    @MainActor static func main() async {
        do {for (name,test) in ArtifactEditCases.cases {try await test();print("PASS "+name)};print("PASS \(ArtifactEditCases.cases.count) actual scoped edit lifecycle groups; offline synthetic only")}
        catch {print("FAIL "+String(describing:error));exit(1)}
    }
}
#else
import XCTest
@testable import cat
final class ConversationArtifactEditTests:XCTestCase {
    @MainActor func testCanonicalReceiptAndWireBoundsMatchServer() async throws {try await ArtifactEditCases.canonical()}
    @MainActor func testDraftAndOriginalBaseSurviveRestartWithoutChangingChatDraft() async throws {try await ArtifactEditCases.durableDraft()}
    @MainActor func testAppliedRevisionPreservesExactSourceSnapshotAndOldBody() async throws {try await ArtifactEditCases.applied()}
    @MainActor func testUnknownColdRestartReadsOriginalOperationWithoutAnotherPost() async throws {try await ArtifactEditCases.unknown()}
    @MainActor func testCASConflictRequiresExplicitRebaseAndPreservesOtherSelectionDraft() async throws {try await ArtifactEditCases.conflict()}
    @MainActor func testReceiptsRejectWrongSourceGrantBindingPlanHashAndBody() async throws {try await ArtifactEditCases.receipts()}
    @MainActor func testAdmissionLogoutAndDeletedConversationFenceLateResponses() async throws {try await ArtifactEditCases.fences()}
    @MainActor func testDurableOriginalIntentPrecedesDispatchAndDiskFailurePreventsPost() async throws {try await ArtifactEditCases.beforeDispatch()}
    @MainActor func testRefreshAndSubmissionKeepTypingAndOversizeRawInput() async throws {try await ArtifactEditCases.model()}
    @MainActor func testTwoServicesCannotDispatchTwoOriginalOperations() async throws {try await ArtifactEditCases.competition()}
}
#endif

struct ArtifactEditTestContext {
    let root:URL
    let localURL:URL
    let serverURL:URL
    let repository:Repository
    let backend:ConversationArtifactEditFixtureBackend
    let service:ConversationArtifactEditService
    let reference:ConversationArtifactEditReference
    func remove(){try? FileManager.default.removeItem(at:root)}
}
enum ArtifactEditTestSupport {
    struct Failure:Error {let message:String}
    static func check(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    static func fixture(mode:ConversationArtifactEditFixtureBackend.Mode = .applied) async throws -> ArtifactEditTestContext {
        let runtime=ProcessInfo.processInfo.environment["ARTIFACT_EDIT_TEST_ROOT"].map{URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory
        let root=runtime.appendingPathComponent("artifact-edit-"+UUID().uuidString,isDirectory:true),local=root.appendingPathComponent("local.json"),server=root.appendingPathComponent("synthetic-server.json")
        let serverScope=UUID(),partition=AuthenticatedLocalPartition(issuer:"https://synthetic.example.invalid/auth/v1",subject:stableID("P0-task-review-subject"),serverScopeID:serverScope),scope=partition.scope,conversation=UUID(),run=UUID(),environment=UUID()
        let repository=try Repository(persistence:FilePersistence(url:local))
        try await repository.commit(scope:scope,mutations:[.create(environment,.core(.environment(ExecutionEnvironment(name:"Offline fixture",kind:.local,connection:.connected,capabilityIDs:[],verifiedAt:nil)))),.create(conversation,.core(.conversation(Conversation(title:"Synthetic edit lifecycle",projectID:nil,expertID:nil,skillIDs:[],environmentID:environment,archivedAt:nil,draftText:"Independent ordinary chat draft"))))])
        let binding=ConversationTaskBinding(scope_id:serverScope,conversation_id:conversation,turn_id:UUID(),call_id:"synthetic-artifact-edit",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash("fixture-task-"+conversation.uuidString),request_hash:textHash("fixture-run-request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+serverScope.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        let data:[String:Any]=["content":"Original synthetic report","source_contract":"sourced-report-v1","updated_at":"2026-10-14T02:01:00.000Z","sources":[["source_id":"source-1","read_id":"11111111-2222-4333-8444-555555555555","requested_url":"https://www.swift.org/documentation/","final_url":"https://www.swift.org/documentation/","read_at":"2026-10-14T02:00:00.000Z","content_hash":textHash("Synthetic original bytes; no fetch")]],"source_receipt_references":[["source_id":"source-1","receipt_hash":textHash("Synthetic receipt reference")]],"citations":[["source_id":"source-1","quote":"Original synthetic attribution"]]]
        let body=try ConversationArtifactEditCodec.canonicalString(["kind":"report","title":"Synthetic report","summary":"No HTTP or model was used","data":data])
        let artifact=ConversationArtifactProjection(id:textHash("fixture-artifact-"+conversation.uuidString),version:2,contentHash:textHash(body),body:body,title:"Synthetic report",summary:"No HTTP or model was used",content:"Original synthetic report")
        let reference=ConversationArtifactEditReference(scope:scope,binding:binding,subjectID:partition.subject,artifact:artifact),backend=try ConversationArtifactEditFixtureBackend(url:server,mode:mode)
        return .init(root:root,localURL:local,serverURL:server,repository:repository,backend:backend,service:ConversationArtifactEditService(repository:repository,scope:scope,backend:backend),reference:reference)
    }
    static func draft(_ state:ConversationArtifactEditLocalState,_ reference:ConversationArtifactEditReference,text:String="Human edited text",sequence:Int=1) throws -> ConversationArtifactEditDraft {
        guard let base=state.base(for:reference) else {throw Failure(message:"Missing trusted selected base")}
        return .init(baseReference:base.versionReference,planReference:base.planReference,content:.init(title:"Human title",summary:"Human summary",content:text),editSequence:sequence)
    }
    static func projection(_ snapshot:ConversationArtifactEditSnapshot) throws -> ConversationArtifactProjection {let doc=try snapshot.document();return .init(id:snapshot.artifactID,version:snapshot.version,contentHash:snapshot.contentHash,body:snapshot.body,title:doc.title,summary:doc.summary,content:doc.content)}
    static func request(_ base:ConversationArtifactEditSnapshot,text:String="Other client changed text") throws -> ConversationArtifactEditAmendRequest {.init(operationID:UUID(),expectedVersion:base.version,expectedContentHash:base.contentHash,expectedGrantEpoch:base.grantEpoch,expectedPlanRevision:base.planReference.revision,expectedPlanHash:base.planReference.planHash,content:.init(title:"Other title",summary:"Other summary",content:text))}
    static func object<T:Encodable>(_ value:T) throws -> [String:Any] {try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]}
    static func decode<T:Decodable>(_ type:T.Type,_ value:[String:Any]) throws -> T {try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))}
}

@MainActor enum ArtifactEditCases {
    static let cases:[(String,@MainActor () async throws -> Void)]=[("cross-language receipt + strict wire bounds",canonical),("draft/base restart + independent chat draft",durableDraft),("same artifact immutable revision + original sources",applied),("unknown cold restart GET original operation",unknown),("CAS conflict + explicit rebase + separate selection drafts",conflict),("exact receipt source/grant/binding/body fences",receipts),("admission/logout/deleted-conversation late callback fences",fences),("durable intent before dispatch + disk failure",beforeDispatch),("typing during GET/POST + oversized raw + disk failure",model),("shared repository two-service submission competition",competition)]
    static func canonical() async throws {
        let json=#"{"operation_id":"11111111-1111-4111-8111-111111111111","state":"applied","scope_id":"22222222-2222-4222-8222-222222222222","subject_id":"33333333-3333-4333-8333-333333333333","run_id":"44444444-4444-4444-8444-444444444444","task_id":"1111111111111111111111111111111111111111111111111111111111111111","conversation_id":"55555555-5555-4555-8555-555555555555","artifact_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","run_request_hash":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","source_auth_hash":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","delegation_id":"66666666-6666-4666-8666-666666666666","delegation_revision":1,"grant_epoch":1,"plan_reference":{"revision":1,"plan_hash":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"base_reference":{"artifact_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":1,"content_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"result_reference":{"artifact_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":2,"content_hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"content":{"title":"标题 / \"引用\"","summary":"摘要 \uFEFF\u0085 /\n下一行","content":"正文 / 路径\\name\n\uFEFF\u0085结束"},"origin":"user_revision","source_evidence_boundary":"original_snapshot_only","committed_at":"2026-10-14T00:00:00.000Z","receipt_hash":"7a72c4f05aca39161096cc40f44f5e879c01e13f4d29559d369308dff4ea61e8"}"#
        let receipt=try JSONDecoder().decode(ConversationArtifactEditAmendment.self,from:Data(json.utf8))
        try ArtifactEditTestSupport.check(try receipt.canonicalHash()==receipt.receiptHash,"Swift canonical receipt differs from fixed ECMAScript bytes")
        try receipt.content.validate()
        for invalid in [ConversationArtifactEditContent(title:String(repeating:"🙂",count:81),summary:"s",content:"c"),.init(title:"\u{FEFF}",summary:"s",content:"c"),.init(title:"t",summary:"s",content:"c\u{0000}"),.init(title:"t",summary:"s",content:String(repeating:"x",count:16001))] {do {try invalid.validate();throw ArtifactEditTestSupport.Failure(message:"Invalid wire content accepted")}catch ConversationArtifactEditError.invalidResponse{}}
        try ConversationArtifactEditContent(title:"\u{0085}",summary:"s",content:"c").validate()
    }
    static func durableDraft() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        try ArtifactEditTestSupport.check(c.reference.scope.workspaceID != c.reference.binding.scope_id,"Local/server scope fixture must differ")
        let initial=try await c.service.refresh(c.reference),draft=try ArtifactEditTestSupport.draft(initial,c.reference,text:String(repeating:"x",count:16001))
        try await c.service.saveDraft(c.reference,draft:draft)
        let reopenedRepo=try Repository(persistence:FilePersistence(url:c.localURL)),reopened=ConversationArtifactEditService(repository:reopenedRepo,scope:c.reference.scope)
        let restored=try await reopened.localState(c.reference),conversation=try await reopenedRepo.record(c.reference.binding.conversation_id,scope:c.reference.scope)
        try ArtifactEditTestSupport.check(restored.draft(for:c.reference)==draft && conversation.conversation?.draftText=="Independent ordinary chat draft","Restart lost base/raw or replaced chat draft")
        do {_ = try await c.service.submit(c.reference);throw ArtifactEditTestSupport.Failure(message:"Overlong wire content posted")}catch ConversationArtifactEditError.invalidResponse{}
        try ArtifactEditTestSupport.check((await c.backend.operations()).posts.isEmpty,"Local 16k+ draft sent HTTP")
    }
    static func applied() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        let initial=try await c.service.refresh(c.reference),draft=try ArtifactEditTestSupport.draft(initial,c.reference)
        try await c.service.saveDraft(c.reference,draft:draft)
        let envelope=try await c.service.submit(c.reference),saved=try await c.service.localState(c.reference),old=try await c.backend.readArtifact(c.reference,version:2)
        try ArtifactEditTestSupport.check(envelope.artifact.version==3 && envelope.artifact.artifactID==c.reference.artifact.id && saved.submission?.state == .applied && saved.draft(for:c.reference)==nil,"Same-artifact CAS or exact draft clearing failed")
        try ArtifactEditTestSupport.check(old.artifact.body==c.reference.artifact.body && !old.artifact.isCurrent,"Original immutable body changed")
        let before=try ConversationArtifactEditCodec.object(old.artifact.body)["data"] as! [String:Any],after=try ConversationArtifactEditCodec.object(envelope.artifact.body)["data"] as! [String:Any]
        for key in ["sources","source_contract","source_receipt_references"] {try ArtifactEditTestSupport.check(try ConversationArtifactEditCodec.canonicalString(["v":before[key]!])==ConversationArtifactEditCodec.canonicalString(["v":after[key]!]),"Original source snapshot changed")}
        try ArtifactEditTestSupport.check(after["citations"]==nil && after["original_citations"] != nil && (after["user_revision"] as? [String:Any])?["claims_verification"] as? String=="not_rechecked","Human content claimed new source verification")
    }
    static func unknown() async throws {
        let c=try await ArtifactEditTestSupport.fixture(mode:.unknown);defer{c.remove()}
        let initial=try await c.service.refresh(c.reference),draft=try ArtifactEditTestSupport.draft(initial,c.reference)
        try await c.service.saveDraft(c.reference,draft:draft)
        do {_ = try await c.service.submit(c.reference);throw ArtifactEditTestSupport.Failure(message:"Expected synthetic lost reply")}catch is URLError{}
        let pending=try await c.service.localState(c.reference),original=pending.submission!.request.operationID
        do {_ = try await c.service.submit(c.reference);throw ArtifactEditTestSupport.Failure(message:"Unknown submitted again")}catch ConversationArtifactEditError.busy{}
        await c.service.invalidate()
        let repo=try Repository(persistence:FilePersistence(url:c.localURL)),backend=try ConversationArtifactEditFixtureBackend(url:c.serverURL,mode:.unknown),reopened=ConversationArtifactEditService(repository:repo,scope:c.reference.scope,backend:backend)
        let restored=try await reopened.refresh(c.reference),calls=await backend.operations()
        try ArtifactEditTestSupport.check(restored.submission?.state == .applied && restored.submission?.request.operationID==original && calls.posts==[original] && calls.reads==[original],"Cold recovery replaced or resent original operation")
        try ArtifactEditTestSupport.check(restored.latest?.version==3 && restored.draft(for:c.reference)==nil,"Recovered receipt did not restore exact applied result")
    }
    static func conflict() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        let initial=try await c.service.refresh(c.reference),draft=try ArtifactEditTestSupport.draft(initial,c.reference),base=initial.latest!
        try await c.service.saveDraft(c.reference,draft:draft)
        let external=try await c.backend.amendArtifact(c.reference,request:ArtifactEditTestSupport.request(base))
        do {_ = try await c.service.submit(c.reference);throw ArtifactEditTestSupport.Failure(message:"Stale CAS overwrote new version")}catch catError.conflict{}
        try ArtifactEditTestSupport.check(!(await c.service.isFresh(c.reference)),"Conflict retained fresh admission")
        let changed=try await c.service.refresh(c.reference)
        try ArtifactEditTestSupport.check(changed.draft(for:c.reference)==draft && changed.latest?.version==3,"Conflict refreshed over user draft")
        do {_ = try await c.service.submit(c.reference);throw ArtifactEditTestSupport.Failure(message:"Stale draft submitted after GET")}catch ConversationArtifactEditError.staleDraft{}
        let other=ConversationArtifactEditReference(scope:c.reference.scope,binding:c.reference.binding,subjectID:c.reference.subjectID,artifact:try ArtifactEditTestSupport.projection(external.artifact))
        let otherState=try await c.service.refresh(other),otherDraft=try ArtifactEditTestSupport.draft(otherState,other,text:"Independent version three draft")
        try await c.service.saveDraft(other,draft:otherDraft)
        let rebased=try await c.service.rebaseDraft(c.reference)
        try ArtifactEditTestSupport.check(rebased.draft(for:c.reference)?.baseReference.version==3 && rebased.draft(for:c.reference)?.content==draft.content && rebased.draft(for:other)==otherDraft,"Explicit rebase changed text or another selection draft")
        let applied=try await c.service.submit(c.reference)
        try ArtifactEditTestSupport.check(applied.artifact.version==4,"Rebased CAS did not advance same artifact")
    }
    static func receipts() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        let base=(try await c.backend.readArtifact(c.reference,version:nil)).artifact,request=try ArtifactEditTestSupport.request(base),valid=try await c.backend.amendArtifact(c.reference,request:request)
        try valid.validateApplied(reference:c.reference,request:request,base:base)
        // A hash-consistent GET body still must distinguish a JSON Boolean from the grant number.
        for body in [valid.artifact.body.replacingOccurrences(of:"\"grant_epoch\":1",with:"\"grant_epoch\":true"),valid.artifact.body.replacingOccurrences(of:"\"grant_epoch\":1",with:"\"grant_epoch\":1,\"grant_epoch\":1")] {
            var object=try ArtifactEditTestSupport.object(valid),artifact=object["artifact"] as! [String:Any]
            artifact["body"]=body;artifact["content_hash"]=textHash(body)
            var current=artifact["current_reference"] as! [String:Any];current["content_hash"]=textHash(body);artifact["current_reference"]=current;object["artifact"]=artifact;object.removeValue(forKey:"amendment")
            do {try ArtifactEditTestSupport.decode(ConversationArtifactEditEnvelope.self,object).validate(reference:c.reference);throw ArtifactEditTestSupport.Failure(message:"GET body accepted Boolean or duplicate grant epoch")}catch ConversationArtifactEditError.invalidResponse{}
        }
        for (key,value) in [("scope_id",UUID().uuidString),("subject_id",UUID().uuidString),("run_id",UUID().uuidString),("task_id",textHash("foreign-task")),("conversation_id",UUID().uuidString),("source_auth_hash",textHash("foreign-source")),("run_request_hash",textHash("foreign-request")),("delegation_id",UUID().uuidString),("delegation_revision",2),("grant_epoch",2),("receipt_hash",textHash("wrong-receipt"))] as [(String,Any)] {
            var object=try ArtifactEditTestSupport.object(valid),receipt=object["amendment"] as! [String:Any];receipt[key]=value
            if key != "receipt_hash" {let partial=try ArtifactEditTestSupport.decode(ConversationArtifactEditAmendment.self,receipt);receipt["receipt_hash"]=try partial.canonicalHash()}
            object["amendment"]=receipt;let bad=try ArtifactEditTestSupport.decode(ConversationArtifactEditEnvelope.self,object)
            do {try bad.validateApplied(reference:c.reference,request:request,base:base);throw ArtifactEditTestSupport.Failure(message:"Wrong exact receipt field accepted: "+key)}catch ConversationArtifactEditError.invalidResponse{}
        }
        for mode in ["source_body","body_hash","plan","version"] {
            var object=try ArtifactEditTestSupport.object(valid),artifact=object["artifact"] as! [String:Any],receipt=object["amendment"] as! [String:Any]
            if mode=="body_hash" {artifact["content_hash"]=textHash("incorrect-body")}
            if mode=="plan" {receipt["plan_reference"]=["revision":2,"plan_hash":textHash("foreign-plan")]}
            if mode=="version" {var result=receipt["result_reference"] as! [String:Any];result["version"]=4;receipt["result_reference"]=result}
            if mode=="source_body" {
                var body=try ConversationArtifactEditCodec.object(valid.artifact.body),data=body["data"] as! [String:Any],sources=data["sources"] as! [[String:Any]];sources[0]["content_hash"]=textHash("Changed original source bytes");data["sources"]=sources;body["data"]=data
                let bytes=try ConversationArtifactEditCodec.canonicalString(body),hash=textHash(bytes);artifact["body"]=bytes;artifact["content_hash"]=hash
                var current=artifact["current_reference"] as! [String:Any];current["content_hash"]=hash;artifact["current_reference"]=current;receipt["result_reference"]=current
            }
            receipt["receipt_hash"]=try ArtifactEditTestSupport.decode(ConversationArtifactEditAmendment.self,receipt).canonicalHash();object["artifact"]=artifact;object["amendment"]=receipt
            do {try ArtifactEditTestSupport.decode(ConversationArtifactEditEnvelope.self,object).validateApplied(reference:c.reference,request:request,base:base);throw ArtifactEditTestSupport.Failure(message:"Tampered applied envelope accepted: "+mode)}catch ConversationArtifactEditError.invalidResponse{}
        }
    }
    static func fences() async throws {
        try await queuedDraftTeardown()
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        let held=ArtifactEditHoldingBackend(base:c.backend),service=ConversationArtifactEditService(repository:c.repository,scope:c.reference.scope,backend:held)
        await held.holdRead();let read=Task{try await service.refresh(c.reference)};await held.waitForRead();await service.invalidate();await held.releaseRead()
        do {_ = try await read.value;throw ArtifactEditTestSupport.Failure(message:"Late logout response populated head")}catch is CancellationError{}
        let reopened=ConversationArtifactEditService(repository:c.repository,scope:c.reference.scope,backend:c.backend),state=try await reopened.localState(c.reference)
        try ArtifactEditTestSupport.check(state.latest==nil,"Logout revived a late current head")
        let initial=try await reopened.refresh(c.reference);try await reopened.saveDraft(c.reference,draft:ArtifactEditTestSupport.draft(initial,c.reference));await reopened.setAdmissionAllowed(false)
        do {_ = try await reopened.submit(c.reference);throw ArtifactEditTestSupport.Failure(message:"Closed admission dispatched")}catch ConversationArtifactEditError.busy{}
        let foreign=ConversationArtifactEditReference(scope:Profiles.demo,binding:c.reference.binding,subjectID:c.reference.subjectID,artifact:c.reference.artifact)
        do {_ = try await reopened.localState(foreign);throw ArtifactEditTestSupport.Failure(message:"Cross-account draft read")}catch catError.scopeMismatch{}
        let deleted=ConversationArtifactEditService(repository:c.repository,scope:c.reference.scope,backend:held);_ = try await deleted.refresh(c.reference)
        await held.holdPost();let post=Task{try await deleted.submit(c.reference)};await held.waitForPost()
        let before=await c.repository.read(scope:c.reference.scope),record=try await c.repository.record(c.reference.binding.conversation_id,scope:c.reference.scope)
        try await c.repository.commit(scope:c.reference.scope,mutations:[.remove(record.id,record.header.revision)]);await held.releasePost()
        do {_ = try await post.value;throw ArtifactEditTestSupport.Failure(message:"Deleted conversation accepted late mutation")}catch catError.missing{}
        let after=await c.repository.read(scope:c.reference.scope)
        for (id,r) in before.records where r.payload.kind=="preference" {try ArtifactEditTestSupport.check(after.records[id]?.header.revision==r.header.revision,"Late reply rewrote preference after deletion")}
    }
    private static func queuedDraftTeardown() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        let model=ConversationArtifactEditModel(service:c.service,reference:c.reference)
        await model.load(admissionAllowed:true)
        let counts=await c.backend.stats()
        for index in 1...8 {model.content="Exact accepted queued raw \(index)";try ArtifactEditTestSupport.check(model.stageDraft(),"Open editor rejected accepted local draft")}
        let expected=model.raw
        async let first=c.service.invalidate()
        async let second=c.service.invalidate()
        let results=await (first,second)
        try ArtifactEditTestSupport.check(results.0 && results.1 && model.draftSaved && !model.canEditLocal,"Teardown did not join the accepted local queue")
        let repository=try Repository(persistence:FilePersistence(url:c.localURL)),reopened=ConversationArtifactEditService(repository:repository,scope:c.reference.scope)
        let state=try await reopened.localState(c.reference)
        try ArtifactEditTestSupport.check(state.draft(for:c.reference)?.content==expected && state.draft(for:c.reference)?.editSequence==8,"Immediate invalidation lost the exact last queued raw on cold read")
        model.content="Rejected after closing";try ArtifactEditTestSupport.check(!model.stageDraft(),"Closed editor accepted a new stage")
        await c.service.setAdmissionAllowed(true)
        do {_=try await c.service.refresh(c.reference);throw ArtifactEditTestSupport.Failure(message:"Teardown reopened server admission")}catch ConversationArtifactEditError.notConfigured{}
        try ArtifactEditTestSupport.check(await c.backend.stats()==counts,"Local teardown issued another GET or POST")

        // An authorized GET that is still in flight must not block local teardown.
        let d=try await ArtifactEditTestSupport.fixture();defer{d.remove()};_ = try await d.service.refresh(d.reference)
        let held=ArtifactEditHoldingBackend(base:d.backend),service=ConversationArtifactEditService(repository:d.repository,scope:d.reference.scope,backend:held),pendingModel=ConversationArtifactEditModel(service:service,reference:d.reference)
        await held.holdRead();let load=Task{await pendingModel.load(admissionAllowed:true)};await held.waitForRead()
        pendingModel.content="Local queue drains while original GET remains held";try ArtifactEditTestSupport.check(pendingModel.stageDraft(),"Cached base did not accept local raw")
        let before=await d.backend.stats(),drained=await service.invalidate(),after=await d.backend.stats()
        try ArtifactEditTestSupport.check(drained && pendingModel.draftSaved && after==before,"Local drain waited on network or caused an extra request")
        await held.releaseRead();await load.value
        let cold=ConversationArtifactEditService(repository:try Repository(persistence:FilePersistence(url:d.localURL)),scope:d.reference.scope)
        try ArtifactEditTestSupport.check(try await cold.localState(d.reference).draft(for:d.reference)?.content.content==pendingModel.content,"Late network response overwrote drained local raw")
    }
    static func beforeDispatch() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        let inspecting=ArtifactEditInspectingBackend(base:c.backend,localURL:c.localURL),service=ConversationArtifactEditService(repository:c.repository,scope:c.reference.scope,backend:inspecting)
        let state=try await service.refresh(c.reference);try await service.saveDraft(c.reference,draft:ArtifactEditTestSupport.draft(state,c.reference));_ = try await service.submit(c.reference)
        try ArtifactEditTestSupport.check(await inspecting.observedOriginalIntent(),"POST preceded durable original intent")
        let d=try await ArtifactEditTestSupport.fixture();defer{d.remove()};let next=try await d.service.refresh(d.reference);try await d.service.saveDraft(d.reference,draft:ArtifactEditTestSupport.draft(next,d.reference))
        try FileManager.default.removeItem(at:d.localURL);try FileManager.default.createDirectory(at:d.localURL,withIntermediateDirectories:true)
        do {_ = try await d.service.submit(d.reference);throw ArtifactEditTestSupport.Failure(message:"Disk failure still dispatched")}catch {if error is ArtifactEditTestSupport.Failure {throw error}}
        try ArtifactEditTestSupport.check((await d.backend.operations()).posts.isEmpty,"Failed intent commit caused a POST")
    }
    static func model() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()};_ = try await c.service.refresh(c.reference)
        let held=ArtifactEditHoldingBackend(base:c.backend),service=ConversationArtifactEditService(repository:c.repository,scope:c.reference.scope,backend:held),model=ConversationArtifactEditModel(service:service,reference:c.reference)
        await held.holdRead();let load=Task{await model.load(admissionAllowed:true)};await held.waitForRead()
        model.title="Keep typing during GET";model.content="Raw intention during refresh";model.stageDraft();await held.releaseRead();await load.value;await model.flushDraft()
        try ArtifactEditTestSupport.check(model.title=="Keep typing during GET" && model.content=="Raw intention during refresh","GET restored old raw fields")
        model.content=String(repeating:"x",count:16001);model.stageDraft();await model.flushDraft()
        try ArtifactEditTestSupport.check(model.draftSaved && !model.canSubmit && model.wireValidationMessage != nil,"16k+ local raw was lost or submitted")
        model.content=String(repeating:"x",count:32001);model.stageDraft();let tooLongClosed=await model.close()
        try ArtifactEditTestSupport.check(!tooLongClosed && model.preventDismiss && model.content.utf16.count==32001,"Unsavable raw closed or clipped")
        model.content="Submit current intention";model.stageDraft();await model.flushDraft();try ArtifactEditTestSupport.check(model.canSubmit,"Valid draft did not become submit-ready")
        await held.holdPost();let post=Task{await model.submit(admissionAllowed:true)};await held.waitForPost()
        model.content="New input after original POST";model.stageDraft();await model.flushDraft();await held.releasePost();await post.value
        let saved=try await service.localState(c.reference)
        try ArtifactEditTestSupport.check(model.content=="New input after original POST" && saved.draft(for:c.reference)?.content.content==model.content,"Applied reply erased newer typing")
        try FileManager.default.removeItem(at:c.localURL);try FileManager.default.createDirectory(at:c.localURL,withIntermediateDirectories:true)
        model.content="Keep raw on persistence failure";model.stageDraft();await model.flushDraft();let diskClosed=await model.close()
        try ArtifactEditTestSupport.check(!diskClosed && model.preventDismiss && model.content=="Keep raw on persistence failure","Failed persistence falsely reported kept draft")
    }
    static func competition() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove()}
        let initial=try await c.service.refresh(c.reference);try await c.service.saveDraft(c.reference,draft:ArtifactEditTestSupport.draft(initial,c.reference))
        let held=ArtifactEditHoldingBackend(base:c.backend),first=ConversationArtifactEditService(repository:c.repository,scope:c.reference.scope,backend:held),second=ConversationArtifactEditService(repository:c.repository,scope:c.reference.scope,backend:c.backend)
        _ = try await first.refresh(c.reference);_ = try await second.refresh(c.reference)
        await held.holdPost();let one=Task{try await first.submit(c.reference)};await held.waitForPost()
        do {_ = try await second.submit(c.reference);throw ArtifactEditTestSupport.Failure(message:"Second service dispatched unresolved intent")}catch ConversationArtifactEditError.busy{}
        await held.releasePost();_ = try await one.value
        try ArtifactEditTestSupport.check((await c.backend.operations()).posts.count==1,"Shared durable journal allowed two original POSTs")
    }
}

actor ArtifactEditHoldingBackend:ConversationArtifactEditBackend {
    let base:ConversationArtifactEditFixtureBackend
    private var heldRead=false,heldPost=false,startedRead=false,startedPost=false
    private var readReady:[CheckedContinuation<Void,Never>]=[],postReady:[CheckedContinuation<Void,Never>]=[]
    private var readRelease:CheckedContinuation<Void,Never>?,postRelease:CheckedContinuation<Void,Never>?
    init(base:ConversationArtifactEditFixtureBackend){self.base=base}
    func holdRead(){heldRead=true;startedRead=false}
    func holdPost(){heldPost=true;startedPost=false}
    func waitForRead() async {if startedRead{return};await withCheckedContinuation{readReady.append($0)}}
    func waitForPost() async {if startedPost{return};await withCheckedContinuation{postReady.append($0)}}
    func releaseRead(){heldRead=false;readRelease?.resume();readRelease=nil}
    func releasePost(){heldPost=false;postRelease?.resume();postRelease=nil}
    func readArtifact(_ reference:ConversationArtifactEditReference,version:Int?) async throws -> ConversationArtifactEditEnvelope {if version==nil,heldRead {startedRead=true;readReady.forEach{$0.resume()};readReady=[];await withCheckedContinuation{readRelease=$0}};return try await base.readArtifact(reference,version:version)}
    func amendArtifact(_ reference:ConversationArtifactEditReference,request:ConversationArtifactEditAmendRequest) async throws -> ConversationArtifactEditEnvelope {let result=try await base.amendArtifact(reference,request:request);if heldPost {startedPost=true;postReady.forEach{$0.resume()};postReady=[];await withCheckedContinuation{postRelease=$0}};return result}
    func readAmendment(_ reference:ConversationArtifactEditReference,operationID:UUID) async throws -> ConversationArtifactEditEnvelope {try await base.readAmendment(reference,operationID:operationID)}
}
actor ArtifactEditInspectingBackend:ConversationArtifactEditBackend {
    let base:ConversationArtifactEditFixtureBackend
    let localURL:URL
    private var observed=false
    init(base:ConversationArtifactEditFixtureBackend,localURL:URL){self.base=base;self.localURL=localURL}
    func observedOriginalIntent()->Bool {observed}
    func readArtifact(_ reference:ConversationArtifactEditReference,version:Int?) async throws -> ConversationArtifactEditEnvelope {try await base.readArtifact(reference,version:version)}
    func readAmendment(_ reference:ConversationArtifactEditReference,operationID:UUID) async throws -> ConversationArtifactEditEnvelope {try await base.readAmendment(reference,operationID:operationID)}
    func amendArtifact(_ reference:ConversationArtifactEditReference,request:ConversationArtifactEditAmendRequest) async throws -> ConversationArtifactEditEnvelope {
        let freshRepository=try Repository(persistence:FilePersistence(url:localURL))
        let records=await freshRepository.read(scope:reference.scope)
        for record in records.list("preference",scope:reference.scope) {if case .preference(let p)=record.payload,let state=try? JSONDecoder().decode(ConversationArtifactEditLocalState.self,from:Data(p.value.utf8)),state.submission?.request==request,state.submission?.state == .unknown {observed=true}}
        guard observed else {throw ArtifactEditTestSupport.Failure(message:"Original submission was not persisted before backend port")}
        return try await base.amendArtifact(reference,request:request)
    }
}
