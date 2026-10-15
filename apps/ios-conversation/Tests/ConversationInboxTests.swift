import Foundation
import XCTest
@testable import CatpawM

final class ConversationInboxTests:XCTestCase {
    private let reference=ConversationInboxReference(scope:Profiles.user,serverScopeID:UUID(),subjectID:UUID())
    private func item(artifacts:[ConversationInboxArtifactReference]=[])->ConversationInboxItem {
        let run=UUID()
        let binding=ConversationTaskBinding(scope_id:reference.serverScopeID,conversation_id:UUID(),turn_id:UUID(),call_id:"inbox-fixture-call",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash(run.uuidString),request_hash:textHash("inbox-fixture-original-request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+reference.serverScopeID.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        return .init(binding:binding,title:"Synthetic received work",createdAt:"2026-10-15T08:00:00.000Z",updatedAt:"2026-10-15T08:01:00.000Z",taskStatus:.succeeded,authorizationState:.current,artifacts:artifacts,planReference:.init(revision:1,planHash:textHash("plan")),pendingActionCount:0)
    }
    private func page(_ items:[ConversationInboxItem],cursor:String?=nil)->ConversationInboxPage {.init(scopeID:reference.serverScopeID,subjectID:reference.subjectID,items:items,nextCursor:cursor)}
    private func object(_ page:ConversationInboxPage) throws -> [String:Any] {try JSONSerialization.jsonObject(with:JSONEncoder().encode(page)) as! [String:Any]}
    private func decode(_ object:[String:Any]) throws -> ConversationInboxPage {try .decode(JSONSerialization.data(withJSONObject:object),reference:reference)}
    private func artifact(_ version:Int)->ConversationArtifactProjection {
        let body="{\"title\":\"Report\",\"summary\":\"Fixture only\",\"data\":{\"content\":\"Version \(version)\"}}"
        return .init(id:textHash("same-artifact"),version:version,contentHash:textHash(body),body:body,title:"Report",summary:"Fixture only",content:"Version \(version)")
    }
    private func goal(_ item:ConversationInboxItem,head:[ConversationArtifactProjection]=[],history:[ConversationArtifactProjection]=[])->ConversationGoalProjection {
        var goal=ConversationGoalProjection(id:item.binding.task_id,revision:1,title:item.title,state:.completed,summary:"Synthetic read only",updatedAt:Date())
        goal.binding=item.binding;goal.artifacts=head;goal.artifactHistory=history;goal.sourceAuthorizationCurrent=false
        return goal
    }
    private func ready(_ backend:InboxReadOnlyTestBackend) async -> ConversationInboxService {
        let service=ConversationInboxService(reference:reference,backend:backend);await service.setAdmissionAllowed(true);return service
    }
    private func waitUntilHeld(_ backend:InboxReadOnlyTestBackend) async throws {
        for _ in 0..<1000 {if await backend.isWaiting(){return};await Task.yield()}
        XCTFail("Expected the named synthetic GET to be held");throw ConversationInboxError.unavailable
    }
    func testExactWireRoundTripKeepsNullCursorAndRunIdentity() throws {
        let value=item(),wire=try JSONEncoder().encode(page([value]))
        let decoded=try ConversationInboxPage.decode(wire,reference:reference)
        XCTAssertEqual(decoded.items.first?.id,value.binding.run_id);XCTAssertNil(decoded.nextCursor)
        XCTAssertEqual(decoded.items.first?.binding,value.binding)
        var row=try object(page([value]));row["next_cursor"]=nil
        XCTAssertThrowsError(try decode(row),"Required nullable fields must still exist")
    }
    func testStrictWireRejectsExtraEscapedDuplicateAndForeignIdentity() throws {
        var wire=try object(page([item()]));wire["can_execute"]=true;XCTAssertThrowsError(try decode(wire))
        wire=try object(page([item()]));wire["subject_id"]=UUID().uuidString;XCTAssertThrowsError(try decode(wire))
        wire=try object(page([item()]));wire["scope_id"]=reference.scope.workspaceID.uuidString;XCTAssertThrowsError(try decode(wire))
        let valid=String(decoding:try JSONEncoder().encode(page([])),as:UTF8.self)
        let duplicate="{\"schema_version\":1,\"schema\\u005fversion\":1,"+valid.dropFirst()
        XCTAssertThrowsError(try ConversationInboxPage.decode(Data(duplicate.utf8),reference:reference))
    }
    func testBindingURLAliasAndMalformedReferenceNeverDecode() throws {
        for change in ["projection_url","grant_epoch","run_id"] {
            var wire=try object(page([item()])),rows=wire["items"] as! [[String:Any]],binding=rows[0]["binding"] as! [String:Any]
            if change=="projection_url" {binding[change]="https://unapproved.invalid/run"}
            else if change=="grant_epoch" {binding[change]=true}
            else {binding[change]=binding["turn_id"]}
            rows[0]["binding"]=binding;wire["items"]=rows;XCTAssertThrowsError(try decode(wire))
        }
    }
    func testInvalidDatesCountsAndDuplicateRunsAreRejected() throws {
        let value=item();XCTAssertThrowsError(try page([value,value]).validate(reference))
        for change in ["created_at","updated_at","pending_action_count","task_status"] {
            var wire=try object(page([value])),rows=wire["items"] as! [[String:Any]]
            switch change {case "created_at":rows[0][change]="2026-02-30T08:00:00.000Z";case "updated_at":rows[0][change]="2026-10-14T08:00:00.000Z";case "pending_action_count":rows[0][change] = -1;default:rows[0][change]="model_guessed_done"}
            wire["items"]=rows;XCTAssertThrowsError(try decode(wire))
        }
    }
    func testResolutionKeepsNewHeadAndVerifiesExactOldVersionInHistory() throws {
        let old=artifact(1),new=artifact(2),value=item(artifacts:[.init(artifactID:old.id,version:old.version,contentHash:old.contentHash)])
        let resolved=goal(value,head:[new],history:[old])
        XCTAssertNoThrow(try value.validateResolved(resolved,reference:reference))
        XCTAssertEqual(resolved.artifacts.first?.version,2);XCTAssertEqual(resolved.artifactHistory.first?.version,1)
        XCTAssertEqual(resolved.sourceAuthorizationCurrent,false,"Reading history cannot grant execution")
        XCTAssertThrowsError(try value.validateResolved(goal(value,head:[new]),reference:reference),"New head cannot silently replace the selected exact old version")
    }
    func testResolutionRejectsWrongBindingAndConflictingArtifactBytes() throws {
        let old=artifact(1),value=item(artifacts:[.init(artifactID:old.id,version:1,contentHash:old.contentHash)])
        var foreign=goal(value,head:[old]);foreign.binding=item().binding;XCTAssertThrowsError(try value.validateResolved(foreign,reference:reference))
        let corrupt=ConversationArtifactProjection(id:old.id,version:old.version,contentHash:old.contentHash,body:old.body+" ",title:old.title,summary:old.summary,content:old.content)
        XCTAssertThrowsError(try value.validateResolved(goal(value,head:[corrupt]),reference:reference))
    }
    func testReadOnlyRefreshPaginationAndResolutionUseSamePartition() async throws {
        let first=item(),second=item(),backend=InboxReadOnlyTestBackend()
        await backend.enqueue(page([first],cursor:"page-2"));await backend.enqueue(page([second]));await backend.setGoal(goal(first))
        let service=await ready(backend),initial=try await service.refresh(),full=try await service.loadMore()
        XCTAssertTrue(initial.isFresh);XCTAssertEqual(full.items.map(\.id),[first.id,second.id]);XCTAssertNil(full.nextCursor)
        let resolved=try await service.resolve(item:first);XCTAssertEqual(resolved.binding,first.binding)
        let calls=await backend.calls();XCTAssertEqual(calls.map(\.reference),[reference,reference]);XCTAssertEqual(calls.map(\.cursor),[nil,"page-2"]);XCTAssertEqual(calls.map(\.limit),[20,20])
    }
    func testDuplicatePageCannotAppendAndNetworkFailureIsOnlyStale() async throws {
        let value=item(),backend=InboxReadOnlyTestBackend();await backend.enqueue(page([value],cursor:"next"));await backend.enqueue(page([value]))
        let service=await ready(backend);_=try await service.refresh()
        do {_=try await service.loadMore();XCTFail("Repeated run must fail")}catch{XCTAssertEqual(error as? ConversationInboxError,.invalidResponse)}
        var snapshot=await service.snapshot();XCTAssertEqual(snapshot.items.map(\.id),[value.id]);XCTAssertFalse(snapshot.isFresh)
        await backend.failNext(.unavailable)
        do {_=try await service.refresh();XCTFail("Transport failure")}catch{XCTAssertEqual(error as? ConversationInboxError,.unavailable)}
        snapshot=await service.snapshot();XCTAssertEqual(snapshot.items.map(\.id),[value.id]);XCTAssertFalse(snapshot.isFresh)
    }
    func testCursorCycleAndFilteredEmptyPageDoNotInventCompletion() async throws {
        let value=item(),backend=InboxReadOnlyTestBackend();await backend.enqueue(page([],cursor:"one"));await backend.enqueue(page([value],cursor:"one"))
        let service=await ready(backend),initial=try await service.refresh();XCTAssertTrue(initial.items.isEmpty);XCTAssertEqual(initial.nextCursor,"one")
        do {_=try await service.loadMore();XCTFail("Cursor cycle")}catch{XCTAssertEqual(error as? ConversationInboxError,.invalidResponse)}
        let snapshot=await service.snapshot();XCTAssertTrue(snapshot.items.isEmpty);XCTAssertFalse(snapshot.isFresh)
    }
    func testAccessDeniedClearsSnapshotRatherThanRestoringOldFacts() async throws {
        let backend=InboxReadOnlyTestBackend();await backend.enqueue(page([item()]));let service=await ready(backend);_=try await service.refresh();await backend.failNext(.accessDenied)
        do {_=try await service.refresh();XCTFail("Access denied")}catch{XCTAssertEqual(error as? ConversationInboxError,.accessDenied)}
        let snapshot=await service.snapshot();XCTAssertTrue(snapshot.items.isEmpty);XCTAssertNil(snapshot.nextCursor);XCTAssertFalse(snapshot.isFresh)
    }
    func testLateOldRefreshCannotReplaceNewerSnapshot() async throws {
        let old=item(),new=item(),backend=InboxReadOnlyTestBackend();await backend.holdNextPage();let service=await ready(backend)
        let previous=Task{try await service.refresh()};try await waitUntilHeld(backend)
        await backend.enqueue(page([new]));_=try await service.refresh();await backend.release(page([old]))
        do {_=try await previous.value;XCTFail("Old generation must fail")}catch is CancellationError{}catch{XCTFail("Unexpected \(error)")}
        let snapshot=await service.snapshot();XCTAssertEqual(snapshot.items.map(\.id),[new.id]);XCTAssertTrue(snapshot.isFresh)
    }
    func testInvalidationFencesLateResponseAndCannotReopen() async throws {
        let backend=InboxReadOnlyTestBackend();await backend.holdNextPage();let service=await ready(backend)
        let pending=Task{try await service.refresh()};try await waitUntilHeld(backend);await service.invalidate();await backend.release(page([item()]))
        do {_=try await pending.value;XCTFail("Closed service cannot accept response")}catch{}
        await service.setAdmissionAllowed(true)
        do {_=try await service.refresh();XCTFail("invalidate is permanent")}catch{XCTAssertEqual(error as? ConversationInboxError,.closed)}
        let snapshot=await service.snapshot();XCTAssertTrue(snapshot.items.isEmpty);XCTAssertFalse(snapshot.isFresh)
    }
    func testDeniedResolutionClearsSnapshot() async throws {
        let value=item(),backend=InboxReadOnlyTestBackend();await backend.enqueue(page([value]));await backend.failResolution(.accessDenied)
        let service=await ready(backend);_=try await service.refresh()
        do {_=try await service.resolve(item:value);XCTFail("Revoked viewer must not receive cached facts")}catch{XCTAssertEqual(error as? ConversationInboxError,.accessDenied)}
        let snapshot=await service.snapshot();XCTAssertTrue(snapshot.items.isEmpty);XCTAssertFalse(snapshot.isFresh)
    }
    func testLateResolutionCannotCrossAdmissionGeneration() async throws {
        let value=item(),backend=InboxReadOnlyTestBackend();await backend.enqueue(page([value]));let held=expectation(description:"Named synthetic resolution entered its held read");await backend.holdNextResolution(onHeld:{held.fulfill()})
        let service=await ready(backend);_=try await service.refresh()
        let pending=Task{try await service.resolve(item:value)}
        await fulfillment(of:[held],timeout:5)
        let waiting=await backend.isResolutionWaiting();XCTAssertTrue(waiting)
        await service.setAdmissionAllowed(false);await service.setAdmissionAllowed(true);await backend.releaseResolution(goal(value))
        do {_=try await pending.value;XCTFail("Old lifecycle response must not reach the new viewer")}catch is CancellationError{}catch{XCTFail("Unexpected \(error)")}
        let snapshot=await service.snapshot();XCTAssertFalse(snapshot.isFresh)
    }
    func testUnavailableAdmissionNeverCallsBackend() async throws {
        let backend=InboxReadOnlyTestBackend(),service=ConversationInboxService(reference:reference,backend:backend)
        do {_=try await service.refresh();XCTFail("Root must explicitly enable network reading")}catch{XCTAssertEqual(error as? ConversationInboxError,.closed)}
        let calls=await backend.calls();XCTAssertTrue(calls.isEmpty)
    }
}
private struct InboxReadCall:Sendable {let reference:ConversationInboxReference;let cursor:String?;let limit:Int}
/// In-process injected typed GET seam; no HTTP, model, task worker or persistence.
private actor InboxReadOnlyTestBackend:ConversationInboxBackend {
    private var pages:[Result<ConversationInboxPage,ConversationInboxError>]=[]
    private var recorded:[InboxReadCall]=[]
    private var resolved:ConversationGoalProjection?
    private var resolutionError:ConversationInboxError?
    private var shouldHoldResolution=false
    private var onResolutionHeld:(@Sendable()->Void)?
    private var heldResolution:CheckedContinuation<ConversationGoalProjection,Error>?
    private var shouldHold=false
    private var held:CheckedContinuation<ConversationInboxPage,Error>?
    func enqueue(_ page:ConversationInboxPage){pages.append(.success(page))}
    func failNext(_ error:ConversationInboxError){pages.append(.failure(error))}
    func setGoal(_ goal:ConversationGoalProjection){resolved=goal}
    func failResolution(_ error:ConversationInboxError){resolutionError=error}
    func holdNextResolution(onHeld:(@Sendable()->Void)?=nil){shouldHoldResolution=true;onResolutionHeld=onHeld}
    func isResolutionWaiting()->Bool{heldResolution != nil}
    func releaseResolution(_ goal:ConversationGoalProjection){let continuation=heldResolution;heldResolution=nil;continuation?.resume(returning:goal)}
    func holdNextPage(){shouldHold=true}
    func isWaiting()->Bool{held != nil}
    func release(_ page:ConversationInboxPage){let continuation=held;held=nil;continuation?.resume(returning:page)}
    func calls()->[InboxReadCall]{recorded}
    func readInbox(reference:ConversationInboxReference,cursor:String?,limit:Int) async throws -> ConversationInboxPage {
        recorded.append(.init(reference:reference,cursor:cursor,limit:limit))
        if shouldHold {shouldHold=false;return try await withCheckedThrowingContinuation{held=$0}}
        guard !pages.isEmpty else {throw ConversationInboxError.unavailable};return try pages.removeFirst().get()
    }
    func readReceivedTask(reference:ConversationInboxReference,item:ConversationInboxItem) async throws -> ConversationGoalProjection {
        if shouldHoldResolution {shouldHoldResolution=false;return try await withCheckedThrowingContinuation{heldResolution=$0;onResolutionHeld?();onResolutionHeld=nil}}
        if let resolutionError {throw resolutionError}
        guard let resolved else {throw ConversationInboxError.unavailable};return resolved
    }
}
