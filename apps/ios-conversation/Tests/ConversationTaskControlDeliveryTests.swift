import Foundation
import XCTest
@testable import CatpawM

private actor ControlDeliveryGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private var started=false
    func pause() async {started=true;await withCheckedContinuation{continuation=$0}}
    func hasStarted()->Bool {started}
    func release(){continuation?.resume();continuation=nil}
}
/// Named offline backend. It exercises the actual host/session recovery path with no HTTP/model/effect.
private actor ControlDeliveryConversationBackend:ConversationBackend {
    let controls:ConversationTaskControlFixtureBackend,subject:UUID,goalConversation:UUID
    private var replyGate:ControlDeliveryGate?,readGate:ControlDeliveryGate?
    private var reads:[UUID]=[],replyCalls:[UUID]=[]
    init(controls:ConversationTaskControlFixtureBackend,subject:UUID,goalConversation:UUID){self.controls=controls;self.subject=subject;self.goalConversation=goalConversation}
    func gateNextReply(_ gate:ControlDeliveryGate){replyGate=gate}
    func gateReads(_ gate:ControlDeliveryGate){readGate=gate}
    func resetCounts(){reads=[];replyCalls=[]}
    func counts()->([UUID],[UUID]){(reads,replyCalls)}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.providerUnverified,provider:"Named offline host control delivery",detail:"No Auth/HTTP/model/SQL")}
    func reference(_ request:ConversationTurnRequest)->ConversationTaskControlReference {
        if let binding=request.history.compactMap({message -> ConversationTaskBinding? in guard message.role == .tool,message.toolName=="delegate_task" else {return nil};return try? JSONDecoder().decode(ConversationTaskBinding.self,from:Data(message.content.utf8))}).first {return .init(scope:request.scope,binding:binding,subjectID:subject.uuidString.lowercased(),title:"Named offline work")}
        let call="offline-control-delivery-"+request.operationID.uuidString,run=stableID(call+"-run")
        return .init(scope:request.scope,binding:.init(scope_id:request.scope.workspaceID,conversation_id:request.conversationID,turn_id:request.operationID,call_id:call,delegation_id:stableID(call+"-delegation"),operation_id:stableID(call+"-operation"),run_id:run,task_id:textHash(call+"-task"),request_hash:textHash(call),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+request.scope.workspaceID.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased()),subjectID:subject.uuidString.lowercased(),title:"Named offline work")
    }
    private func hash(_ request:ConversationTurnRequest)->String {textHash("Named offline host turn "+request.operationID.uuidString)}
    private func events(_ request:ConversationTurnRequest) async throws -> [ConversationTurnEvent] {
        let body="Named offline host delivery response",message=stableID("delivery-assistant-"+request.operationID.uuidString)
        var values:[ConversationTurnEvent.Payload]=[.started(requestHash:hash(request),conversationRevision:1,grantEpoch:1)]
        if request.conversationID==goalConversation && request.epoch==1 {
            let ref=reference(request),goal=try await controls.goal(ref),call=ref.binding.call_id
            values += [.toolStarted(callID:call,name:"delegate_task",arguments:"{}"),.toolResult(.init(callID:call,name:"delegate_task",content:String(decoding:try JSONEncoder().encode(ref.binding),as:UTF8.self),committedGoals:[goal]))]
        }
        values += [.textDelta(messageID:message,text:body),.completed(messageID:message,finalTextHash:textHash(body))]
        return values.enumerated().map{.init(operationID:request.operationID,epoch:request.epoch,sequence:$0.offset+1,payload:$0.element)}
    }
    func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        replyCalls.append(request.conversationID);let all=try await events(request),gate=replyGate;replyGate=nil
        return AsyncThrowingStream {stream in
            if let gate {for value in all.dropLast(){stream.yield(value)};Task{await gate.pause();if let last=all.last {stream.yield(last)};stream.finish()}}
            else {for value in all {stream.yield(value)};stream.finish()}
        }
    }
    func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {
        reads.append(request.conversationID)
        if let readGate {await readGate.pause()}
        let goals=request.conversationID==goalConversation ? [try await controls.goal(reference(request))] : []
        return .init(request:request,events:try await events(request),requestHash:hash(request),grantEpoch:1,goals:goals)
    }
}
@MainActor final class ConversationTaskControlDeliveryTests:XCTestCase {
    private struct Fixture {
        let directory:URL,repository:Repository,session:ConversationSessionService,controls:ConversationTaskControlFixtureBackend,controlService:ConversationTaskControlService,backend:ControlDeliveryConversationBackend,model:ConversationFirstModel,reference:ConversationTaskControlReference,conversationB:UUID,subject:UUID
    }
    private func wait(_ condition:@MainActor () async -> Bool) async throws {
        for _ in 0..<800 {if await condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Named offline host delivery condition timed out");throw ConversationTaskControlError.invalidResponse
    }
    private func step<T>(_ name:String,_ operation:() async throws -> T) async throws -> T {
        do {return try await operation()}catch {XCTFail("Named offline host fixture stage ‘"+name+"’: "+String(describing:error));throw error}
    }
    private func fixture(selectedB:Bool=false) async throws -> Fixture {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("catpaw-host-control-delivery-"+UUID().uuidString),path=directory.appendingPathComponent("client.json"),repository=try Repository(persistence:FilePersistence(url:path)),subject=UUID(),a=UUID(),b=UUID()
        let controls=try ConversationTaskControlFixtureBackend(url:directory.appendingPathComponent("separate-synthetic-server.json")),backend=ControlDeliveryConversationBackend(controls:controls,subject:subject,goalConversation:a),session=ConversationSessionService(repository:repository,backend:backend),controlService=ConversationTaskControlService(repository:repository,scope:Profiles.user,backend:controls)
        _=try await step("create original A with its session journal"){try await session.create(scope:Profiles.user,id:a)}
        _=try await step("create independent B with its session journal"){try await session.create(scope:Profiles.user,id:b)}
        _=try await step("seed original A goal through actual session send"){try await session.send(scope:Profiles.user,conversationID:a,text:"Named offline goal",operationID:UUID())}
        _=try await step("seed independent B completed turn through actual session send"){try await session.send(scope:Profiles.user,conversationID:b,text:"Named unrelated completed chat",operationID:UUID())}
        for (id,title,draft) in [(a,"Named A","A draft"),(b,"Named B","B draft")] {
            try await step("restore named draft on the created conversation") {
                let record=try await repository.record(id,scope:Profiles.user);guard var value=record.conversation else {throw CatpawError.missing};value.title=title;value.draftText=draft
                try await repository.commit(scope:Profiles.user,mutations:[.update(record.id,record.header.revision,.core(.conversation(value)))])
            }
        }
        let saved=try await step("read saved A binding"){try await session.read(scope:Profiles.user,conversationID:a)}
        guard let goal=saved.goals.values.first,let binding=goal.binding else {throw ConversationTaskControlError.invalidResponse}
        let reference=ConversationTaskControlReference(scope:Profiles.user,binding:binding,subjectID:subject.uuidString.lowercased(),title:goal.title),initial=try await step("read control CAS snapshot"){try await controlService.refresh(reference)}
        _=try await step("persist original pause operation"){try await controlService.submit(reference,action:.pause,expectedSnapshotHash:initial.latest!.snapshot_hash)}
        try await step("read back paused A through existing observe"){try await session.observe(scope:Profiles.user,conversationID:a)}
        try await step("remember selected scoped conversation"){try await session.rememberSelection(scope:Profiles.user,conversationID:selectedB ? b:a)}
        let model=ConversationFirstModel(repository:repository,service:session,taskControlService:controlService,subjectID:subject);model.setNetworkAdmissionAllowed(false);await model.start()
        XCTAssertTrue(model.loaded,"Named offline host start: "+(model.error ?? "none"))
        return .init(directory:directory,repository:repository,session:session,controls:controls,controlService:controlService,backend:backend,model:model,reference:reference,conversationB:b,subject:subject)
    }
    private func open(_ f:Fixture) async throws {
        f.model.setNetworkAdmissionAllowed(true)
        try await wait{let count=await f.backend.counts();return !f.model.busy && count.0.contains(f.reference.binding.conversation_id)}
        await f.backend.resetCounts()
    }
    private func resume(_ f:Fixture) async throws -> ConversationTaskControlEnvelope {let state=try await f.controlService.refresh(f.reference);return try await f.controlService.submit(f.reference,action:.resume,expectedSnapshotHash:state.latest!.snapshot_hash)}
    private func cleanup(_ f:Fixture) async {await f.model.deactivate();try? FileManager.default.removeItem(at:f.directory)}
    func testBusyOrdinaryStreamKeepsResumeDeliveryUntilOriginalTaskCanBeRead() async throws {
        let f=try await fixture();try await open(f);let gate=ControlDeliveryGate();await f.backend.gateNextReply(gate)
        f.model.editDraft("Named ordinary streaming turn");f.model.send();try await wait{await gate.hasStarted() && f.model.busy}
        let envelope=try await resume(f);try await f.model.recordAppliedTaskControl(envelope,reference:f.reference)
        let before=await f.backend.counts();XCTAssertTrue(before.0.isEmpty);XCTAssertEqual(f.model.session?.goals[f.reference.binding.task_id]?.state,.paused)
        await gate.release();try await wait{let counts=await f.backend.counts();return counts.0==[f.reference.binding.conversation_id] && f.model.session?.goals[f.reference.binding.task_id]?.state == .queued && !f.model.busy}
        let stats=await f.controls.debugStats();XCTAssertEqual(stats["control_posts"],2,"Only the explicit pause and resume; recovery is GET")
        await cleanup(f)
    }
    func testLateReceiptAfterSelectingBReadsOriginalAAndPreservesBSelectionAndDraft() async throws {
        let f=try await fixture();try await open(f);let envelope=try await resume(f);try await f.model.select(f.conversationB);f.model.editDraft("Unrelated B draft after selection")
        try await f.model.recordAppliedTaskControl(envelope,reference:f.reference)
        try await wait{let counts=await f.backend.counts();return counts.0==[f.reference.binding.conversation_id] && !f.model.busy}
        XCTAssertEqual(f.model.conversationID,f.conversationB);XCTAssertEqual(f.model.draft,"Unrelated B draft after selection");let a=try await f.session.read(scope:Profiles.user,conversationID:f.reference.binding.conversation_id);XCTAssertEqual(a.goals[f.reference.binding.task_id]?.state,.queued)
        let counts=await f.backend.counts();XCTAssertTrue(counts.1.isEmpty);let stats=await f.controls.debugStats();XCTAssertEqual(stats["control_posts"],2)
        await cleanup(f)
    }
    func testBackgroundDefersOriginalDeliveryAndForegroundReadsWithoutAnotherControlPost() async throws {
        let f=try await fixture();try await open(f);let envelope=try await resume(f);await f.model.suspend();try await f.model.recordAppliedTaskControl(envelope,reference:f.reference)
        let held=await f.backend.counts();XCTAssertTrue(held.0.isEmpty);await f.model.resumeForeground()
        try await wait{let counts=await f.backend.counts();return counts.0==[f.reference.binding.conversation_id] && f.model.session?.goals[f.reference.binding.task_id]?.state == .queued && !f.model.busy}
        let stats=await f.controls.debugStats();XCTAssertEqual(stats["control_posts"],2);await cleanup(f)
    }
    func testLogoutFencesLateOriginalGetAndCannotReviveClosedHost() async throws {
        let f=try await fixture();try await open(f);let envelope=try await resume(f),gate=ControlDeliveryGate();await f.backend.gateReads(gate);try await f.model.recordAppliedTaskControl(envelope,reference:f.reference);try await wait{await gate.hasStarted()}
        await f.model.deactivate();await gate.release();f.model.setNetworkAdmissionAllowed(true);await f.model.resumeForeground()
        do {try await f.model.recordAppliedTaskControl(envelope,reference:f.reference);XCTFail("A closed account must not accept delivery")}catch{}
        XCTAssertNil(f.model.session);XCTAssertNil(f.model.conversationID);XCTAssertFalse(f.model.loaded)
        let saved=try await f.session.read(scope:Profiles.user,conversationID:f.reference.binding.conversation_id);XCTAssertEqual(saved.goals[f.reference.binding.task_id]?.state,.paused,"Late GET cannot overwrite the closed journal")
        let counts=await f.backend.counts();XCTAssertEqual(counts.0,[f.reference.binding.conversation_id]);XCTAssertTrue(counts.1.isEmpty);let stats=await f.controls.debugStats();XCTAssertEqual(stats["control_posts"],2)
        try? FileManager.default.removeItem(at:f.directory)
    }
    func testColdHostSelectedOnBRestoresAppliedOriginalAReceiptFromScopedJournal() async throws {
        let f=try await fixture();try await open(f);_=try await resume(f);try await f.model.select(f.conversationB);await f.model.deactivate()
        let repository=try Repository(persistence:FilePersistence(url:f.directory.appendingPathComponent("client.json"))),controls=try ConversationTaskControlFixtureBackend(url:f.directory.appendingPathComponent("separate-synthetic-server.json")),backend=ControlDeliveryConversationBackend(controls:controls,subject:f.subject,goalConversation:f.reference.binding.conversation_id),session=ConversationSessionService(repository:repository,backend:backend),controlService=ConversationTaskControlService(repository:repository,scope:Profiles.user,backend:controls),model=ConversationFirstModel(repository:repository,service:session,taskControlService:controlService,subjectID:f.subject)
        model.setNetworkAdmissionAllowed(false);await model.start();XCTAssertEqual(model.conversationID,f.conversationB);model.setNetworkAdmissionAllowed(true)
        try await wait{let counts=await backend.counts();return counts.0==[f.reference.binding.conversation_id] && !model.busy}
        let saved=try await session.read(scope:Profiles.user,conversationID:f.reference.binding.conversation_id);XCTAssertEqual(saved.goals[f.reference.binding.task_id]?.state,.queued);XCTAssertEqual(model.conversationID,f.conversationB)
        let counts=await backend.counts();XCTAssertTrue(counts.1.isEmpty);let stats=await controls.debugStats();XCTAssertEqual(stats["control_posts"],2)
        await model.deactivate();try? FileManager.default.removeItem(at:f.directory)
    }
}
