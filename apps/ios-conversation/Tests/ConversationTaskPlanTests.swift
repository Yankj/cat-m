import Foundation
#if !TASK_PLAN_PORTABLE
import XCTest
@testable import cat

final class ConversationTaskPlanTests:XCTestCase {
    func testAuthenticatedLocalPartitionKeepsServerBindingAcrossUnknownRestart() async throws {
        let serverScope=UUID(uuidString:"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,partition=AuthenticatedLocalPartition(issuer:"https://scope.example.invalid/auth/v1",subject:UUID(),serverScopeID:serverScope)
        XCTAssertNotEqual(partition.scope.workspaceID,serverScope)
        let path=FileManager.default.temporaryDirectory.appendingPathComponent("TaskPlan-Scope-"+UUID().uuidString).appendingPathComponent("store.json");defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let repo=try Repository(persistence:FilePersistence(url:path)),session=ConversationSessionService(repository:repo),cid=try await session.create(scope:partition.scope),run=UUID()
        let binding=ConversationTaskBinding(scope_id:serverScope,conversation_id:cid,turn_id:UUID(),call_id:"synthetic-auth-plan",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash("synthetic-auth-task"),request_hash:textHash("synthetic-auth-request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+serverScope.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        let reference=ConversationTaskPlanReference(scope:partition.scope,binding:binding,title:"Synthetic authenticated partition plan"),backend=ConversationTaskPlanFixtureBackend(mode:.unknown),service=ConversationTaskPlanService(repository:repo,scope:partition.scope,backend:backend)
        let original=try await service.refresh(reference),plan=try XCTUnwrap(original.snapshot)
        let draft=ConversationTaskPlanDraft(baseRevision:1,basePlanHash:plan.acceptedPlanHash,goal:"Keep account scoped raw text",requirements:"")
        try await service.saveDraft(reference,draft:draft)
        do {_ = try await service.submit(reference);XCTFail("Unknown fixture must interrupt its response")}catch{}
        let interrupted=try await service.localState(reference),operation=try XCTUnwrap(interrupted.submission?.request.operationID)
        await service.invalidate()
        let reopenedRepo=try Repository(persistence:FilePersistence(url:path)),reopened=ConversationTaskPlanService(repository:reopenedRepo,scope:partition.scope,backend:backend)
        let restored=try await reopened.refresh(reference),counts=await backend.counts()
        XCTAssertEqual(restored.draft,draft);XCTAssertEqual(restored.snapshot?.runID,binding.run_id);XCTAssertEqual(restored.submission?.request.operationID,operation);XCTAssertEqual(counts.0,[operation]);XCTAssertEqual(counts.1,[operation])
        let foreign=ConversationTaskPlanReference(scope:Profiles.demo,binding:binding,title:reference.title)
        do {_ = try await reopened.localState(foreign);XCTFail("The fixed local partition must still fence another account")}catch catError.scopeMismatch{}
    }
    func testCanonicalPlanHashMatchesECMAScriptFixturesAndStrictBounds() throws {
        let content=ConversationTaskPlanContent(title:"公开 / 资料",goal:"比较三份资料\n保留“来源”",requirements:"",stopConditions:["已保存 / 已核验"],steps:[.init(id:"compose",title:"撰写",detail:"https://example.com/a/b"),.init(id:"save",title:"保存",detail:""),.init(id:"verify",title:"核验",detail:"中文与🙂")])
        try content.validate();XCTAssertEqual(try content.canonicalHash(),"6c5a15d05ff9bf1eb8d4238947381f267abe27365b71245e42255e30c24dbdb4")
        var oversized=content;oversized.goal=String(repeating:"x",count:4001);XCTAssertThrowsError(try oversized.validate())
        var reordered=content;reordered.steps.reverse();XCTAssertThrowsError(try reordered.validate())
        var emptyBOM=content;emptyBOM.goal="\u{FEFF}";XCTAssertThrowsError(try emptyBOM.validate())
        var nonWhitespaceNEL=content;nonWhitespaceNEL.goal="\u{0085}";XCTAssertNoThrow(try nonWhitespaceNEL.validate())
        let shared=ConversationTaskPlanContent(title:"本地计划",goal:"整理已提供的虚构材料",requirements:"仅使用对话资料，不访问网络",stopConditions:["保存本地报告并验证后结束"],steps:[.init(id:"compose",title:"整理资料",detail:"使用给定信息"),.init(id:"save",title:"保存成果",detail:""),.init(id:"verify",title:"核对成果",detail:"检查当前计划")])
        XCTAssertEqual(try shared.canonicalHash(),"ca764e5b243afeba0e45424c1fd0831730940c92e407a2e586e713e710b0db64")
    }
    func testModificationDraftSurvivesCloseRestartAndNeverChangesChatDraft() async throws {
        let (repo,service,_,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let session=ConversationSessionService(repository:repo);try await session.saveDraft(scope:reference.scope,conversationID:reference.binding.conversation_id,text:"Independent chat draft")
        let state=try await service.refresh(reference),plan=try XCTUnwrap(state.snapshot)
        let draft=ConversationTaskPlanDraft(baseRevision:plan.acceptedRevision,basePlanHash:plan.acceptedPlanHash,goal:"Modified goal",requirements:"Risk comparison")
        try await service.saveDraft(reference,draft:draft)
        let reopenedRepo=try Repository(persistence:FilePersistence(url:path)),reopened=ConversationTaskPlanService(repository:reopenedRepo)
        let local=try await reopened.localState(reference),conversation=try await reopenedRepo.record(reference.binding.conversation_id,scope:reference.scope)
        XCTAssertEqual(local.draft,draft);XCTAssertEqual(conversation.conversation?.draftText,"Independent chat draft")
    }
    func testAppliedAmendmentUsesSameRunAndClearsOnlySubmittedDraft() async throws {
        let (_,service,backend,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let initial=try await service.refresh(reference),plan=try XCTUnwrap(initial.snapshot)
        try await service.saveDraft(reference,draft:.init(baseRevision:plan.acceptedRevision,basePlanHash:plan.acceptedPlanHash,goal:"Modified goal",requirements:"Risk comparison"))
        let changed=try await service.submit(reference),snapshot=try XCTUnwrap(changed.snapshot),counts=await backend.counts()
        XCTAssertEqual(snapshot.runID,reference.id);XCTAssertEqual(snapshot.taskID,reference.binding.task_id);XCTAssertEqual(snapshot.acceptedRevision,2);XCTAssertEqual(snapshot.appliedRevision,2)
        XCTAssertEqual(changed.submission?.state,.applied);XCTAssertNil(changed.draft);XCTAssertEqual(counts.0.count,1);XCTAssertEqual(changed.drafts["1"]?.requirements,"Risk comparison")
    }
    func testPendingAndUnknownReconcileOriginalOperationWithoutAnotherPost() async throws {
        for mode in [ConversationTaskPlanFixtureBackend.Mode.pending,.unknown] {
            let (repo,service,backend,reference,path)=try await fixture(mode:mode);defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
            let initial=try await service.refresh(reference),plan=try XCTUnwrap(initial.snapshot)
            try await service.saveDraft(reference,draft:.init(baseRevision:plan.acceptedRevision,basePlanHash:plan.acceptedPlanHash,goal:"Modified goal",requirements:"Risk comparison"))
            do {_ = try await service.submit(reference)}catch{XCTAssertEqual(mode,.unknown)}
            let saved=try await service.localState(reference),original=try XCTUnwrap(saved.submission?.request.operationID)
            do {_ = try await service.submit(reference);XCTFail("Unresolved amendment cannot dispatch again")}catch ConversationTaskPlanError.busy{}
            let reopened=ConversationTaskPlanService(repository:repo,backend:backend)
            let reconciled=try await reopened.refresh(reference),counts=await backend.counts()
            XCTAssertEqual(counts.0,[original]);XCTAssertEqual(counts.1,[original]);XCTAssertEqual(reconciled.snapshot?.appliedRevision,1);XCTAssertNotNil(reconciled.draft)
            XCTAssertEqual(reconciled.submission?.state,mode == .pending ? .pending : .unknown)
        }
    }
    func testCASConflictKeepsExactDraft() async throws {
        let (repo,initial,backend,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let cached=try await initial.refresh(reference),plan=try XCTUnwrap(cached.snapshot)
        let draft=ConversationTaskPlanDraft(baseRevision:1,basePlanHash:plan.acceptedPlanHash,goal:"Keep user goal",requirements:"Keep user requirements")
        try await initial.saveDraft(reference,draft:draft)
        let conflict=ConversationTaskPlanService(repository:repo,backend:ConflictTaskPlanBackend(base:backend))
        do {_ = try await conflict.submit(reference);XCTFail("CAS must reject")}catch catError.conflict{}
        let saved=try await conflict.localState(reference);XCTAssertEqual(saved.draft,draft);XCTAssertEqual(saved.submission?.state,.rejected)
        let counts=await backend.counts();XCTAssertTrue(counts.0.isEmpty)
    }
    func testChangedRevisionPreservesDraftUntilExplicitRebase() async throws {
        let (_,service,backend,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let original=try await service.refresh(reference),plan=try XCTUnwrap(original.snapshot)
        let draft=ConversationTaskPlanDraft(baseRevision:1,basePlanHash:plan.acceptedPlanHash,goal:"Keep exact user text",requirements:"")
        try await service.saveDraft(reference,draft:draft)
        var external=plan.content;external.requirements="Another client update"
        _ = try await backend.amendPlan(reference,request:.init(operationID:UUID(),expectedRevision:1,expectedPlanHash:plan.acceptedPlanHash,expectedGrantEpoch:reference.binding.grant_epoch,content:external))
        let refreshed=try await service.refresh(reference)
        XCTAssertEqual(refreshed.snapshot?.acceptedRevision,2);XCTAssertEqual(refreshed.draft,draft)
        do {_ = try await service.submit(reference);XCTFail("Old revision must not dispatch")}catch ConversationTaskPlanError.staleDraft{}
        let rebased=try await service.rebaseDraft(reference)
        XCTAssertEqual(rebased.draft?.baseRevision,2);XCTAssertEqual(rebased.draft?.goal,draft.goal);XCTAssertEqual(rebased.draft?.requirements,"");XCTAssertEqual(rebased.drafts["1"],draft)
        let applied=try await service.submit(reference);XCTAssertEqual(applied.snapshot?.acceptedRevision,3)
    }
    func testStepReceiptRequiresAppliedRevisionTypeHashAndValidUTCDate() async throws {
        let (_,_,backend,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let envelope=try await backend.readPlan(reference),plan=envelope.plan
        func snapshot(_ receipt:ConversationTaskPlanStepReceipt,taskStatus:String="scheduled")->ConversationTaskPlanSnapshot {
            .init(runID:plan.runID,taskID:plan.taskID,conversationID:plan.conversationID,acceptedRevision:1,acceptedPlanHash:plan.acceptedPlanHash,appliedRevision:1,appliedPlanHash:plan.appliedPlanHash,applicationState:.applied,taskStatus:taskStatus,content:plan.content,appliedContent:plan.appliedContent,stepReceipts:[receipt])
        }
        func receipt(revision:Int=1,hash:String?=nil,kind:ConversationTaskPlanStepReceipt.Kind = .modelResponse,date:String="2026-10-14T00:00:00.000Z")->ConversationTaskPlanStepReceipt {
            .init(stepID:"compose",planRevision:revision,planHash:hash ?? plan.appliedPlanHash,receiptKind:kind,receiptHash:textHash("synthetic-receipt"),createdAt:date)
        }
        XCTAssertNoThrow(try snapshot(receipt()).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(revision:2)).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(hash:textHash("wrong-plan"))).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(kind:.artifactSaved)).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(date:"2026-99-14T00:00:00.000Z")).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(date:"2026-02-30T00:00:00.000Z")).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(date:"0000-01-01T00:00:00.000Z")).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(date:"2026-10-14T00:00:00+00:00")).validate(reference:reference))
        XCTAssertThrowsError(try snapshot(receipt(),taskStatus:"pretend_completed").validate(reference:reference))
    }
    func testClosedAdmissionAndForeignScopeCannotDispatchOrReadAnotherDraft() async throws {
        let (_,service,backend,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let initial=try await service.refresh(reference),plan=try XCTUnwrap(initial.snapshot)
        try await service.saveDraft(reference,draft:.init(baseRevision:1,basePlanHash:plan.acceptedPlanHash,goal:"Offline local edit",requirements:""))
        await service.setAdmissionAllowed(false)
        do {_ = try await service.submit(reference);XCTFail("Closed admission cannot dispatch")}catch{}
        let foreign=ConversationTaskPlanReference(scope:Profiles.demo,binding:reference.binding,title:reference.title)
        do {_ = try await service.localState(foreign);XCTFail("Foreign scope must be denied")}catch catError.scopeMismatch{}
        let counts=await backend.counts();XCTAssertTrue(counts.0.isEmpty)
    }
    func testLateReadAfterLogoutCannotPopulatePlanCache() async throws {
        let (repo,_,backend,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        let delayed=DelayedTaskPlanBackend(base:backend),service=ConversationTaskPlanService(repository:repo,backend:delayed)
        let read=Task {try await service.refresh(reference)};await delayed.waitUntilRead()
        await service.invalidate();await delayed.release()
        do {_ = try await read.value;XCTFail("Logout must fence late plan")}catch is CancellationError{}
        let next=ConversationTaskPlanService(repository:repo),state=try await next.localState(reference)
        XCTAssertNil(state.snapshot)
    }
    @MainActor func testRefreshDoesNotOverwriteTypingWhileReadIsInFlight() async throws {
        let (repo,initial,backend,reference,path)=try await fixture();defer{try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
        _ = try await initial.refresh(reference)
        let delayed=DelayedTaskPlanBackend(base:backend),service=ConversationTaskPlanService(repository:repo,backend:delayed),model=ConversationTaskPlanModel(service:service,reference:reference)
        let read=Task {await model.load()};await delayed.waitUntilRead()
        model.beginEditing();model.goal="Typing during refresh";model.requirements="Keep current intention";model.stageDraft()
        await delayed.release();await read.value;await model.flushDraft()
        XCTAssertEqual(model.goal,"Typing during refresh");XCTAssertEqual(model.requirements,"Keep current intention")
        let persisted=try await service.localState(reference);XCTAssertEqual(persisted.draft?.goal,"Typing during refresh")
        let localLong=String(repeating:"x",count:4001)
        model.goal=localLong;model.stageDraft();await model.flushDraft()
        XCTAssertTrue(model.draftSaved);XCTAssertFalse(model.canSubmit);XCTAssertNotNil(model.wireValidationMessage)
        let refresh=Task {await model.load()};await delayed.waitUntilRead();await delayed.release();await refresh.value
        XCTAssertEqual(model.goal,localLong);XCTAssertTrue(model.editing)
        let longState=try await service.localState(reference);XCTAssertEqual(longState.draft?.goal,localLong)
        model.goal=String(repeating:"x",count:8001);model.stageDraft()
        let oversizedClose=await model.finishEditing();XCTAssertFalse(oversizedClose);XCTAssertTrue(model.preventDismiss);XCTAssertEqual(model.goal.utf16.count,8001)
        model.goal="Cannot persist yet";model.stageDraft();await model.flushDraft()
        try FileManager.default.removeItem(at:path);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        model.goal="Keep raw despite disk failure";model.stageDraft();await model.flushDraft()
        let failedClose=await model.finishEditing();XCTAssertFalse(failedClose);XCTAssertTrue(model.preventDismiss);XCTAssertEqual(model.goal,"Keep raw despite disk failure")
        try FileManager.default.removeItem(at:path)
        await model.flushDraft();XCTAssertTrue(model.draftSaved);XCTAssertFalse(model.preventDismiss)
        model.goal="Submit this revision";model.requirements="Request before flight";model.stageDraft();await model.flushDraft();XCTAssertTrue(model.canSubmit)
        await delayed.holdNextAmendment()
        let submission=Task {await model.submit(admissionAllowed:true)};await delayed.waitUntilAmendment()
        model.goal="New intention during submission";model.requirements="Never restore old fields";model.stageDraft();await model.flushDraft()
        await delayed.releaseAmendment();await submission.value
        XCTAssertEqual(model.goal,"New intention during submission");XCTAssertEqual(model.requirements,"Never restore old fields");XCTAssertTrue(model.editing)
        XCTAssertEqual(model.state.snapshot?.appliedRevision,2);XCTAssertEqual(model.state.submission?.state,.applied)
        let continued=try await service.localState(reference);XCTAssertEqual(continued.draft?.goal,"New intention during submission")
        let conflictingService=ConversationTaskPlanService(repository:repo,backend:ConflictTaskPlanBackend(base:backend)),conflictModel=ConversationTaskPlanModel(service:conflictingService,reference:reference)
        await conflictModel.load();conflictModel.beginEditing();await conflictModel.rebaseDraft();XCTAssertTrue(conflictModel.canSubmit)
        await conflictModel.submit(admissionAllowed:true)
        XCTAssertFalse(conflictModel.freshlyRead);XCTAssertFalse(conflictModel.canSubmit);XCTAssertEqual(conflictModel.state.submission?.state,.rejected);XCTAssertEqual(conflictModel.goal,"New intention during submission")
    }
    private func fixture(mode:ConversationTaskPlanFixtureBackend.Mode = .applied) async throws -> (Repository,ConversationTaskPlanService,ConversationTaskPlanFixtureBackend,ConversationTaskPlanReference,URL) {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent("TaskPlan-"+UUID().uuidString).appendingPathComponent("store.json")
        let repo=try Repository(persistence:FilePersistence(url:path)),session=ConversationSessionService(repository:repo),cid=try await session.create(scope:Profiles.user)
        let binding=ConversationTaskBinding(scope_id:Profiles.user.workspaceID,conversation_id:cid,turn_id:UUID(),call_id:"synthetic-plan",delegation_id:UUID(),operation_id:UUID(),run_id:UUID(),task_id:textHash("synthetic-task"),request_hash:textHash("synthetic-request"),delegation_revision:1,grant_epoch:1,projection_url:"/explicit-offline-fixture")
        let reference=ConversationTaskPlanReference(scope:Profiles.user,binding:binding,title:"Synthetic research plan"),backend=ConversationTaskPlanFixtureBackend(mode:mode),service=ConversationTaskPlanService(repository:repo,backend:backend)
        return (repo,service,backend,reference,path)
    }
}
private struct ConflictTaskPlanBackend:ConversationTaskPlanBackend {
    let base:ConversationTaskPlanFixtureBackend
    func readPlan(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanEnvelope {try await base.readPlan(reference)}
    func amendPlan(_ reference:ConversationTaskPlanReference,request:ConversationTaskPlanAmendRequest) async throws -> ConversationTaskPlanEnvelope {throw catError.conflict}
    func readAmendment(_ reference:ConversationTaskPlanReference,operationID:UUID) async throws -> ConversationTaskPlanEnvelope {try await base.readAmendment(reference,operationID:operationID)}
}
private actor DelayedTaskPlanBackend:ConversationTaskPlanBackend {
    let base:ConversationTaskPlanFixtureBackend
    private var pending:CheckedContinuation<Void,Never>?
    private var ready:CheckedContinuation<Void,Never>?
    private var holdingAmendment=false
    private var pendingAmendment:CheckedContinuation<Void,Never>?
    private var amendmentReady:CheckedContinuation<Void,Never>?
    init(base:ConversationTaskPlanFixtureBackend){self.base=base}
    func readPlan(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanEnvelope {await withCheckedContinuation{pending=$0;ready?.resume();ready=nil};return try await base.readPlan(reference)}
    func waitUntilRead() async {if pending != nil {return};await withCheckedContinuation{ready=$0}}
    func release(){pending?.resume();pending=nil}
    func holdNextAmendment(){holdingAmendment=true}
    func waitUntilAmendment() async {if pendingAmendment != nil {return};await withCheckedContinuation{amendmentReady=$0}}
    func releaseAmendment(){pendingAmendment?.resume();pendingAmendment=nil}
    func amendPlan(_ reference:ConversationTaskPlanReference,request:ConversationTaskPlanAmendRequest) async throws -> ConversationTaskPlanEnvelope {
        if holdingAmendment {holdingAmendment=false;await withCheckedContinuation{pendingAmendment=$0;amendmentReady?.resume();amendmentReady=nil}}
        return try await base.amendPlan(reference,request:request)
    }
    func readAmendment(_ reference:ConversationTaskPlanReference,operationID:UUID) async throws -> ConversationTaskPlanEnvelope {try await base.readAmendment(reference,operationID:operationID)}
}
#endif

/// These checks run against the actual local model/service/repository, with no HTTP transport.
@MainActor private enum TaskPlanDraftDrainChecks {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func check(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    struct Context {
        let repository:Repository
        let service:ConversationTaskPlanService
        let backend:TaskPlanDrainBackend
        let reference:ConversationTaskPlanReference
        let path:URL
        func remove(){try? FileManager.default.removeItem(at:path.deletingLastPathComponent())}
    }
    static func fixture(mode:ConversationTaskPlanFixtureBackend.Mode = .applied) async throws -> Context {
        let root=ProcessInfo.processInfo.environment["TASK_PLAN_TEST_ROOT"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory
        let path=root.appendingPathComponent("PlanDraftDrain-"+UUID().uuidString).appendingPathComponent("store.json")
        let repo=try Repository(persistence:FilePersistence(url:path)),session=ConversationSessionService(repository:repo),cid=try await session.create(scope:Profiles.user)
        let binding=ConversationTaskBinding(scope_id:Profiles.user.workspaceID,conversation_id:cid,turn_id:UUID(),call_id:"offline-plan-draft-drain",delegation_id:UUID(),operation_id:UUID(),run_id:UUID(),task_id:textHash("offline-plan-draft-drain-task"),request_hash:textHash("offline-plan-draft-drain-request"),delegation_revision:1,grant_epoch:1,projection_url:"/explicit-offline-fixture")
        let reference=ConversationTaskPlanReference(scope:Profiles.user,binding:binding,title:"Offline plan draft drain"),backend=TaskPlanDrainBackend(base:ConversationTaskPlanFixtureBackend(mode:mode)),service=ConversationTaskPlanService(repository:repo,backend:backend)
        return Context(repository:repo,service:service,backend:backend,reference:reference,path:path)
    }
    static func queuedImmediateLogout() async throws {
        let c=try await fixture();defer{c.remove()}
        let model=ConversationTaskPlanModel(service:c.service,reference:c.reference)
        await model.load();model.beginEditing();await model.flushDraft()
        let before=await c.backend.counts()
        for index in 1...8 {model.goal="Exact queued plan raw \(index) / 中文\n";model.requirements="Exact queued requirement \(index)";model.stageDraft()}
        let expected=model.state.draft
        async let first=c.service.invalidate()
        async let second=c.service.invalidate()
        let drained=await (first,second)
        await model.flushDraft()
        let cold=ConversationTaskPlanService(repository:try Repository(persistence:FilePersistence(url:c.path)))
        let saved=try await cold.localState(c.reference)
        try check(saved.draft==expected,"Immediate invalidation lost the last queued raw: expected \(expected?.goal ?? "nil"), stored \(saved.draft?.goal ?? "nil")")
        try check(drained.0 && drained.1 && model.draftSaved && model.tearingDown && !model.canEdit,"Concurrent teardown did not join the accepted local queue")
        try check(await c.backend.counts()==before,"Local logout issued an additional HTTP GET or POST")
        model.goal="Rejected after local close";try check(!model.stageDraft(),"Closed model accepted another stage")
        await c.service.setAdmissionAllowed(true)
        do {_ = try await c.service.refresh(c.reference);throw Failure(description:"Closed service reopened HTTP admission")}catch ConversationTaskPlanError.notConfigured{}
        try check(await c.backend.counts()==before,"Closed service dispatched a new request")
    }
    static func heldReadDoesNotBlockDrain() async throws {
        let c=try await fixture();defer{c.remove()};_ = try await c.service.refresh(c.reference)
        let service=ConversationTaskPlanService(repository:c.repository,backend:c.backend),model=ConversationTaskPlanModel(service:service,reference:c.reference)
        await c.backend.holdNextRead();let read=Task{await model.load()};await c.backend.waitUntilRead()
        model.beginEditing();model.goal="Accepted local raw while GET remains held";model.requirements="No network wait for local drain";model.stageDraft()
        let expected=model.state.draft,before=await c.backend.counts()
        let drained=await service.invalidate();await model.flushDraft()
        try check(drained && model.draftSaved,"Held GET prevented local teardown completion")
        try check(await c.backend.counts()==before,"Draining admitted a new server request")
        await c.backend.releaseRead();await read.value
        let cold=ConversationTaskPlanService(repository:try Repository(persistence:FilePersistence(url:c.path))),saved=try await cold.localState(c.reference)
        try check(saved.draft==expected && model.draftSaved,"Held GET blocked or overwrote accepted local raw")
    }
    static func validPlanColdReopensAndSubmits() async throws {
        let c=try await fixture();defer{c.remove()}
        let model=ConversationTaskPlanModel(service:c.service,reference:c.reference)
        await model.load();model.beginEditing();model.goal="Valid normal plan goal";model.requirements="Keep normal reopen path";model.stageDraft()
        try check(await model.finishEditing(),"Normal valid plan draft did not close")
        let expected=model.state.draft
        let cold=ConversationTaskPlanService(repository:try Repository(persistence:FilePersistence(url:c.path)),backend:c.backend),reopened=ConversationTaskPlanModel(service:cold,reference:c.reference)
        await reopened.load();try check(reopened.state.draft==expected && reopened.goal==expected?.goal && reopened.canSubmit,"Valid cold plan did not reopen as submit-ready")
        await reopened.submit(admissionAllowed:true)
        try check(reopened.state.snapshot?.acceptedRevision==2 && reopened.state.snapshot?.runID==c.reference.id && reopened.state.submission?.state == .applied,"Normal reopen changed the original run or failed the plan CAS")
    }
    static func diskFailureReportsFalseAndKeepsRaw() async throws {
        let c=try await fixture();defer{c.remove()}
        let model=ConversationTaskPlanModel(service:c.service,reference:c.reference)
        await model.load();model.beginEditing();await model.flushDraft()
        let before=await c.backend.counts()
        try FileManager.default.removeItem(at:c.path);try FileManager.default.createDirectory(at:c.path,withIntermediateDirectories:true)
        model.goal="Keep exact failed IO raw / 中文\n";model.requirements="Report failure without any HTTP";try check(model.stageDraft(),"Open editor did not accept the local raw")
        async let first=c.service.invalidate()
        async let second=c.service.invalidate()
        let drained=await(first,second)
        try check(!drained.0 && !drained.1 && !model.draftSaved && model.preventDismiss && model.draftSaveIssue != nil && model.goal=="Keep exact failed IO raw / 中文\n","IO failure was falsely reported as a saved draft")
        try check(await c.backend.counts()==before,"Failed local drain issued another request")
        try check(!(await c.service.invalidate()),"Repeated invalidation lost the IO failure result")
    }
    static func heldPostDrainsRawAndKeepsOriginalIdentity() async throws {
        let c=try await fixture();defer{c.remove()}
        let model=ConversationTaskPlanModel(service:c.service,reference:c.reference)
        await model.load();model.beginEditing();model.goal="Original accepted amendment";model.requirements="Before POST";model.stageDraft();await model.flushDraft()
        await c.backend.holdNextPost();let post=Task{await model.submit(admissionAllowed:true)};await c.backend.waitUntilPost()
        let original=try await c.service.localState(c.reference).submission?.request.operationID
        try check(original != nil,"POST began before persisting its original operation")
        model.goal="New raw queued while original POST is held";model.requirements="Do not overwrite with the late response";try check(model.stageDraft(),"In-flight POST blocked local draft admission")
        let expected=model.state.draft,before=await c.backend.counts(),drained=await c.service.invalidate()
        let afterDrain=await c.backend.counts()
        try check(drained && model.draftSaved && afterDrain==before,"Local drain waited for POST or dispatched again")
        await c.backend.releasePost();await post.value
        let cold=ConversationTaskPlanService(repository:try Repository(persistence:FilePersistence(url:c.path)),backend:c.backend),saved=try await cold.localState(c.reference)
        try check(saved.draft==expected && saved.submission?.state == .unknown && saved.submission?.request.operationID==original,"Late POST changed raw or original operation state after logout")
        let reconciled=try await cold.refresh(c.reference),after=await c.backend.counts()
        try check(reconciled.draft==expected && reconciled.submission?.request.operationID==original && after.posts==before.posts && after.originalReads==[original!],"Cold recovery resent POST or lost the exact original GET identity")
    }
    static func unknownColdRecoveryOnlyReadsOriginalOperation() async throws {
        let c=try await fixture(mode:.unknown);defer{c.remove()}
        let initial=try await c.service.refresh(c.reference),plan=initial.snapshot!
        let draft=ConversationTaskPlanDraft(baseRevision:plan.acceptedRevision,basePlanHash:plan.acceptedPlanHash,goal:"Exact unknown amendment raw",requirements:"Recover the original operation only")
        try await c.service.saveDraft(c.reference,draft:draft)
        do {_ = try await c.service.submit(c.reference);throw Failure(description:"Unknown fixture did not interrupt its reply")}catch catError.unavailable{}
        let saved=try await c.service.localState(c.reference),original=saved.submission!.request.operationID,before=await c.backend.counts()
        try check(await c.service.invalidate(),"Unknown receipt prevented local-only teardown")
        let cold=ConversationTaskPlanService(repository:try Repository(persistence:FilePersistence(url:c.path)),backend:c.backend),recovered=try await cold.refresh(c.reference),after=await c.backend.counts()
        try check(recovered.draft==draft && recovered.submission?.request.operationID==original && after.posts==[original] && after.originalReads==[original] && after.current==before.current,"Unknown recovery created a new request or read a fresh plan")
    }
    static func localTicketIsScopeBoundAndOneShot() async throws {
        let c=try await fixture();defer{c.remove()}
        let plan=try await c.service.refresh(c.reference).snapshot!,id=UUID()
        try check(c.service.localDraftDrains.register(id,scope:c.reference.scope){true},"Fixed scope did not register a drainer")
        guard let ticket=c.service.localDraftDrains.accept(id) else {throw Failure(description:"Open registry did not admit a ticket")}
        let draft=ConversationTaskPlanDraft(baseRevision:1,basePlanHash:plan.acceptedPlanHash,goal:"One local scope ticket",requirements:"")
        let foreign=ConversationTaskPlanReference(scope:Profiles.demo,binding:c.reference.binding,title:c.reference.title)
        do {try await c.service.saveDraft(foreign,draft:draft,ticket:ticket);throw Failure(description:"Foreign scope consumed a local ticket")}catch is CancellationError{}
        try await c.service.saveDraft(c.reference,draft:draft,ticket:ticket)
        do {try await c.service.saveDraft(c.reference,draft:draft,ticket:ticket);throw Failure(description:"Local ticket was reused")}catch is CancellationError{}
        try check(await c.service.localState(c.reference).draft==draft,"Foreign attempt consumed the rightful local draft ticket")
    }
    static let cases:[(String,@MainActor () async throws -> Void)]=[
        ("queued8-immediate-logout-cold-exact-raw",queuedImmediateLogout),
        ("held-get-does-not-block-local-drain",heldReadDoesNotBlockDrain),
        ("valid-plan-cold-reopen-and-submit",validPlanColdReopensAndSubmits),
        ("disk-failure-returns-false-keeps-raw",diskFailureReportsFalseAndKeepsRaw),
        ("held-post-drains-raw-keeps-original-id",heldPostDrainsRawAndKeepsOriginalIdentity),
        ("unknown-cold-recovery-original-get-only",unknownColdRecoveryOnlyReadsOriginalOperation),
        ("local-ticket-scope-and-one-shot",localTicketIsScopeBoundAndOneShot)
    ]
}
private actor TaskPlanDrainBackend:ConversationTaskPlanBackend {
    struct Counts:Equatable {var current=0;var posts:[UUID]=[];var originalReads:[UUID]=[]}
    let base:ConversationTaskPlanFixtureBackend
    private var requests=Counts()
    private var holdingRead=false
    private var pending:CheckedContinuation<Void,Never>?
    private var ready:CheckedContinuation<Void,Never>?
    private var holdingPost=false
    private var pendingPost:CheckedContinuation<Void,Never>?
    private var postReady:CheckedContinuation<Void,Never>?
    init(base:ConversationTaskPlanFixtureBackend){self.base=base}
    func counts()->Counts {requests}
    func holdNextRead(){holdingRead=true}
    func waitUntilRead() async {if pending != nil{return};await withCheckedContinuation{ready=$0}}
    func releaseRead(){pending?.resume();pending=nil}
    func holdNextPost(){holdingPost=true}
    func waitUntilPost() async {if pendingPost != nil{return};await withCheckedContinuation{postReady=$0}}
    func releasePost(){pendingPost?.resume();pendingPost=nil}
    func readPlan(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanEnvelope {
        requests.current += 1
        if holdingRead {holdingRead=false;await withCheckedContinuation{pending=$0;ready?.resume();ready=nil}}
        return try await base.readPlan(reference)
    }
    func amendPlan(_ reference:ConversationTaskPlanReference,request:ConversationTaskPlanAmendRequest) async throws -> ConversationTaskPlanEnvelope {
        requests.posts.append(request.operationID)
        if holdingPost {holdingPost=false;await withCheckedContinuation{pendingPost=$0;postReady?.resume();postReady=nil}}
        return try await base.amendPlan(reference,request:request)
    }
    func readAmendment(_ reference:ConversationTaskPlanReference,operationID:UUID) async throws -> ConversationTaskPlanEnvelope {requests.originalReads.append(operationID);return try await base.readAmendment(reference,operationID:operationID)}
}
#if TASK_PLAN_PORTABLE
@main private struct TaskPlanDraftDrainRunner {
    @MainActor static func main() async {
        var failures=0
        for (name,run) in TaskPlanDraftDrainChecks.cases {
            do {try await run();print("PASS \(name)")}
            catch {failures += 1;print("FAIL \(name): \(error)")}
        }
        print("Task plan draft checks: \(TaskPlanDraftDrainChecks.cases.count-failures)/\(TaskPlanDraftDrainChecks.cases.count) passed (offline fixtures only)")
        if failures>0 {exit(1)}
    }
}
#else
final class ConversationTaskPlanDraftDrainTests:XCTestCase {
    @MainActor func testQueuedEightImmediateLogoutColdExactRaw() async throws {try await TaskPlanDraftDrainChecks.queuedImmediateLogout()}
    @MainActor func testHeldGETDoesNotBlockLocalDrain() async throws {try await TaskPlanDraftDrainChecks.heldReadDoesNotBlockDrain()}
    @MainActor func testValidPlanColdReopensAndSubmits() async throws {try await TaskPlanDraftDrainChecks.validPlanColdReopensAndSubmits()}
    @MainActor func testDiskFailureReportsFalseAndKeepsRaw() async throws {try await TaskPlanDraftDrainChecks.diskFailureReportsFalseAndKeepsRaw()}
    @MainActor func testHeldPOSTDrainsRawAndKeepsOriginalIdentity() async throws {try await TaskPlanDraftDrainChecks.heldPostDrainsRawAndKeepsOriginalIdentity()}
    @MainActor func testUnknownColdRecoveryOnlyReadsOriginalOperation() async throws {try await TaskPlanDraftDrainChecks.unknownColdRecoveryOnlyReadsOriginalOperation()}
    @MainActor func testLocalTicketIsScopeBoundAndOneShot() async throws {try await TaskPlanDraftDrainChecks.localTicketIsScopeBoundAndOneShot()}
}
#endif
