import Foundation
import XCTest
import UIKit
@testable import CatpawM

final class ConversationArtifactContinuationComposerTests:XCTestCase {
    private struct Fixture {
        let root:URL,repository:Repository,conversation:UUID,subject:UUID,reference:ConversationArtifactContinuationReference
    }
    private func fixture() async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("continuation-composer-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=try Repository(persistence:FilePersistence(url:root.appendingPathComponent("local.json")))
        let conversation=try await ConversationSessionService(repository:repository).create(scope:Profiles.user),subject=UUID(),server=UUID(),run=UUID()
        let binding=ConversationTaskBinding(scope_id:server,conversation_id:conversation,turn_id:UUID(),call_id:"synthetic-original-call",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash("synthetic-task"),request_hash:textHash("synthetic-request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/\(server.uuidString.lowercased())/runs/\(run.uuidString.lowercased())")
        let reference=ConversationArtifactContinuationReference(scope:Profiles.user,subjectID:subject,goalID:binding.task_id,binding:binding,artifactReference:.init(artifactID:textHash("synthetic-artifact"),version:2,contentHash:textHash("synthetic-v2")),planReference:.init(revision:1,planHash:textHash("synthetic-plan")),mode:.reviseReport,taskTitle:"Synthetic task",artifactTitle:"Synthetic report")
        return .init(root:root,repository:repository,conversation:conversation,subject:subject,reference:reference)
    }
    func testColdComposerKeepsTwoModesExactRawAndIndependentOrdinaryDraft() async throws {
        let c=try await fixture();defer{try? FileManager.default.removeItem(at:c.root)}
        let service=ConversationArtifactContinuationService(repository:c.repository,scope:Profiles.user,subjectID:c.subject),raw="第二条结论补风险\n\u{FEFF}\u{85}"
        _=try await service.activate(c.reference,ordinaryDraft:"Independent ordinary draft")
        let revise=ConversationArtifactContinuationDraft(reference:c.reference,raw:raw,editSequence:1)
        try await service.saveDraft(revise)
        let r=c.reference,ask=ConversationArtifactContinuationReference(scope:r.scope,subjectID:r.subjectID,goalID:r.goalID,binding:r.binding,artifactReference:r.artifactReference,planReference:r.planReference,mode:.explainReport,taskTitle:r.taskTitle,artifactTitle:r.artifactTitle)
        _=try await service.activate(ask,ordinaryDraft:nil,priorDraft:revise)
        let question=ConversationArtifactContinuationDraft(reference:ask,raw:"Why this conclusion?",editSequence:1)
        try await service.saveDraft(question)
        let coldRepo=try Repository(persistence:FilePersistence(url:c.root.appendingPathComponent("local.json"))),cold=ConversationArtifactContinuationService(repository:coldRepo,scope:Profiles.user,subjectID:c.subject)
        let state=try await cold.state(conversationID:c.conversation)
        XCTAssertEqual(state.activeDraft,question);XCTAssertEqual(state.drafts[r.id.uuidString.lowercased()],revise)
        let ordinary=try await cold.leave(question);XCTAssertEqual(ordinary,"Independent ordinary draft")
        let restored=try await cold.activate(r,ordinaryDraft:ordinary)
        XCTAssertEqual(restored.activeDraft?.raw.utf8.map{$0},raw.utf8.map{$0})
        do {try await cold.saveDraft(.init(reference:r,raw:"late overwrite",editSequence:1));XCTFail("Same sequence cannot overwrite newer raw")}
        catch {guard case ConversationArtifactContinuationError.staleDraft=error else {throw error}}
        let retained=try await cold.state(conversationID:c.conversation);XCTAssertEqual(retained.activeDraft?.raw,raw)
    }
    func testForeignSubjectAndClosedServiceCannotReadOrOverwriteSavedTarget() async throws {
        let c=try await fixture();defer{try? FileManager.default.removeItem(at:c.root)}
        let service=ConversationArtifactContinuationService(repository:c.repository,scope:Profiles.user,subjectID:c.subject)
        _=try await service.activate(c.reference,ordinaryDraft:"Ordinary")
        let draft=ConversationArtifactContinuationDraft(reference:c.reference,raw:"Preserve private draft",editSequence:1);try await service.saveDraft(draft)
        let foreign=ConversationArtifactContinuationService(repository:c.repository,scope:Profiles.user,subjectID:UUID())
        do {_=try await foreign.state(conversationID:c.conversation);XCTFail("Another subject cannot read target draft")}
        catch {guard case ConversationArtifactContinuationError.invalidReference=error else {throw error}}
        await service.invalidate()
        do {try await service.saveDraft(.init(reference:c.reference,raw:"late",editSequence:2));XCTFail("Closed service cannot persist")}
        catch {guard case ConversationArtifactContinuationError.closed=error else {throw error}}
        let reopened=ConversationArtifactContinuationService(repository:c.repository,scope:Profiles.user,subjectID:c.subject),state=try await reopened.state(conversationID:c.conversation)
        XCTAssertEqual(state.activeDraft,draft)
    }
    func testFailedQueueCommitKeepsTargetRawAndNeverCreatesPartialFollowup() async throws {
        let c=try await fixture();defer{try? FileManager.default.removeItem(at:c.root)}
        let storage=try SwiftDataPersistence(url:c.root.appendingPathComponent("atomic.store")),repository=try Repository(persistence:storage)
        let snapshot=await c.repository.read(scope:Profiles.user)
        try await repository.commit(scope:Profiles.user,mutations:snapshot.records.values.map{.create($0.id,$0.payload)})
        let service=ConversationArtifactContinuationService(repository:repository,scope:Profiles.user,subjectID:c.subject),queue=ConversationFollowupQueueService(repository:repository,scope:Profiles.user,conversationID:c.conversation)
        _=try await service.activate(c.reference,ordinaryDraft:"Ordinary preserved")
        let draft=ConversationArtifactContinuationDraft(reference:c.reference,raw:"Exact selected report instruction",editSequence:1);try await service.saveDraft(draft)
        let message=ConversationFollowup(text:draft.raw,continuation:try c.reference.sendIntent()),remaining=ConversationArtifactContinuationDraft(reference:c.reference,raw:"",editSequence:2)
        storage.failNextSaveForTesting()
        do {try await queue.enqueue(message,remainingContinuationDraft:remaining,continuationService:service);XCTFail("Injected disk failure must roll back queue and composer together")}catch{}
        let pending=try await queue.state(),state=try await service.state(conversationID:c.conversation)
        XCTAssertTrue(pending.pending.isEmpty);XCTAssertEqual(state.activeDraft,draft)
        try await queue.enqueue(message,remainingContinuationDraft:remaining,continuationService:service)
        let coldRepository=try Repository(persistence:SwiftDataPersistence(url:c.root.appendingPathComponent("atomic.store"))),cold=ConversationArtifactContinuationService(repository:coldRepository,scope:Profiles.user,subjectID:c.subject),coldQueue=ConversationFollowupQueueService(repository:coldRepository,scope:Profiles.user,conversationID:c.conversation)
        let durable=try await coldQueue.state(),composer=try await cold.state(conversationID:c.conversation),ordinary=try await coldRepository.record(c.conversation,scope:Profiles.user)
        XCTAssertEqual(durable.pending,[message]);XCTAssertEqual(composer.activeDraft,remaining);XCTAssertEqual(ordinary.conversation?.draftText,"Ordinary preserved")
    }
    @MainActor func testActualMarkedTextCannotSwitchOrLeaveTargetAndNeverSendsAutomatically() async throws {
        let c=try await fixture();defer{try? FileManager.default.removeItem(at:c.root)}
        let backend=P0ExperienceBackend(scenario:"p0-ui-artifact-edit"),session=ConversationSessionService(repository:c.repository,backend:backend)
        let model=ConversationFirstModel(repository:c.repository,service:session,subjectID:c.subject)
        await model.start()
        let conversation=model.conversationID!
        _=try await session.send(scope:Profiles.user,conversationID:conversation,text:"Synthetic local report",operationID:UUID())
        await model.refresh();let goal=model.session!.goals.values.first!,selected=ConversationArtifactIdentity(goal.artifacts[0])
        model.editDraft("Ordinary input before selection")
        let editor=ConversationTextView();editor.compositionChanged={model.updateInputComposition($0)}
        editor.setMarkedText("未定输入",selectedRange:NSRange(location:3,length:0))
        XCTAssertNotNil(editor.markedTextRange);XCTAssertTrue(model.isInputComposing)
        let ignored=await model.stageArtifactContinuation(goalID:goal.id,selection:selected,mode:.reviseReport)
        XCTAssertFalse(ignored);XCTAssertNil(model.artifactContinuation);XCTAssertEqual(model.draft,"Ordinary input before selection")
        editor.unmarkText();let staged=await model.stageArtifactContinuation(goalID:goal.id,selection:selected,mode:.reviseReport)
        XCTAssertTrue(staged);model.editDraft("Unsubmitted revision raw")
        editor.setMarkedText("修改",selectedRange:NSRange(location:2,length:0))
        let closed=await model.leaveArtifactContinuation();XCTAssertFalse(closed);XCTAssertEqual(model.artifactContinuation?.artifactReference,.init(selected));XCTAssertEqual(model.draft,"Unsubmitted revision raw")
        editor.unmarkText();let exited=await model.leaveArtifactContinuation();XCTAssertTrue(exited);XCTAssertEqual(model.draft,"Ordinary input before selection")
        let counts=await backend.consentInvocationCounts();XCTAssertEqual(counts,[0,1],"Selecting, editing and leaving never dispatch another turn")
    }
}
