import Foundation
#if ARTIFACT_PROJECTION_PORTABLE
import Darwin
@main private enum ArtifactProjectionPortable {
    static func main() async {
        do {try await ArtifactProjectionScenarios.revisionAndRecovery();try await ArtifactProjectionScenarios.revocationAndFreshVersion();try await ArtifactProjectionScenarios.rejectIdentityAndCorruption();try await ArtifactProjectionScenarios.scopeAndDeletion();try await ArtifactProjectionScenarios.confirmedCancellationAndLateHeads();print("PASS 5 artifact journal scenario groups; offline injected projections, no network/model")}
        catch {print("FAIL \(error)");exit(1)}
    }
}
#else
import XCTest
@testable import cat
final class ConversationArtifactProjectionTests:XCTestCase {
    func testRevisionAndLateReadPreserveDraftAndHistory() async throws {try await ArtifactProjectionScenarios.revisionAndRecovery()}
    func testConfirmedSourceInvalidationCannotBeUndoneByLateOrHigherHeads() async throws {try await ArtifactProjectionScenarios.revocationAndFreshVersion()}
    func testIdentityAndCorruptVersionCannotChangeJournal() async throws {try await ArtifactProjectionScenarios.rejectIdentityAndCorruption()}
    func testForeignScopeAndDeletedConversationCannotResurrect() async throws {try await ArtifactProjectionScenarios.scopeAndDeletion()}
    func testConfirmedCancellationSurvivesWithdrawnSourceLateHeadsAndColdReads() async throws {try await ArtifactProjectionScenarios.confirmedCancellationAndLateHeads()}
}
#endif
private enum ArtifactProjectionScenarios {
    struct Failure:Error {let message:String}
    static func check(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    static func artifact(_ version:Int,content:String="Offline user revision") throws -> ConversationArtifactProjection {
        let title="Offline report v\(version)",summary="Synthetic projection only"
        let body=String(decoding:try JSONSerialization.data(withJSONObject:["kind":"report","title":title,"summary":summary,"data":["content":content,"source":"user_revision"]],options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
        return .init(id:String(repeating:"a",count:64),version:version,contentHash:textHash(body),body:body,title:title,summary:summary,content:content)
    }
    struct Fixture {
        let root:URL,repository:Repository,backend:ArtifactJournalFixtureBackend,service:ConversationSessionService,conversationID:UUID,binding:ConversationTaskBinding
    }
    static func fixture() async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("artifact-journal-"+UUID().uuidString)
        let repository=try Repository(persistence:FilePersistence(url:root.appendingPathComponent("store.json")))
        let backend=ArtifactJournalFixtureBackend(artifact:try artifact(1)),service=ConversationSessionService(repository:repository,backend:backend)
        let id=try await service.create(scope:Profiles.user)
        _=try await service.send(scope:Profiles.user,conversationID:id,text:"Injected journal fixture only",operationID:UUID())
        let binding=try await backend.binding()
        try await service.saveDraft(scope:Profiles.user,conversationID:id,text:"Unsent unrelated Chinese 草稿")
        return .init(root:root,repository:repository,backend:backend,service:service,conversationID:id,binding:binding)
    }
    static func revisionAndRecovery() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let v2=try artifact(2);try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:v2)
        try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
        let state=try await f.service.read(scope:Profiles.user,conversationID:f.conversationID),goal=state.goals[f.binding.task_id]!
        try check(goal.artifacts.first?.version==2 && goal.title==v2.title && goal.state == .completed,"Late original v1 replaced current v2 or changed completion")
        try check(Set(goal.artifactHistory.map(\.version))==Set([1,2]),"Immutable history was lost")
        let draft=try await f.repository.record(f.conversationID,scope:Profiles.user).conversation?.draftText
        try check(draft=="Unsent unrelated Chinese 草稿","Revision touched chat draft")
        let counts=await f.backend.counts();try check(counts.0==1 && counts.1==1,"Revision sent another turn")
        let reopened=ConversationSessionService(repository:try Repository(persistence:FilePersistence(url:f.root.appendingPathComponent("store.json"))))
        let cold=try await reopened.read(scope:Profiles.user,conversationID:f.conversationID)
        try check(cold.goals[f.binding.task_id]?.artifacts.first?.contentHash==v2.contentHash,"Cold journal lost revision")
        await f.backend.hideCurrent();try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
        let hidden=try await f.service.read(scope:Profiles.user,conversationID:f.conversationID).goals[f.binding.task_id]!
        try check(hidden.artifacts.isEmpty && hidden.state == .unknown && hidden.artifactHistory.count==2,"Revoked empty projection invented current authority")
    }
    static func rejectIdentityAndCorruption() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let good=try artifact(2)
        let corrupt=ConversationArtifactProjection(id:good.id,version:2,contentHash:good.contentHash,body:good.body+" ",title:good.title,summary:good.summary,content:good.content)
        do {try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:corrupt);throw Failure(message:"Corrupt body accepted")} catch is ConversationSessionError {}
        let wrong=ConversationArtifactProjection(id:String(repeating:"b",count:64),version:2,contentHash:good.contentHash,body:good.body,title:good.title,summary:good.summary,content:good.content)
        do {try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:wrong);throw Failure(message:"Different artifact accepted")} catch is ConversationSessionError {}
        try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:good)
        let collision=try artifact(2,content:"Different same-version body")
        do {try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:collision);throw Failure(message:"Same-version collision accepted")} catch is ConversationSessionError {}
        let state=try await f.service.read(scope:Profiles.user,conversationID:f.conversationID)
        try check(state.goals[f.binding.task_id]?.artifacts.first?.contentHash==good.contentHash,"Rejected collision changed journal")
    }
    static func revocationAndFreshVersion() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:try artifact(2))
        await f.backend.setCurrent(try artifact(3));try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
        let fresh=try await f.service.read(scope:Profiles.user,conversationID:f.conversationID).goals[f.binding.task_id]!
        try check(fresh.artifacts.first?.version==3 && fresh.sourceAuthorizationCurrent==true,"Legitimate new head was hidden without a source invalidation")
        await f.backend.hideCurrent();try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
        for version in [1,3,4] {
            await f.backend.setCurrent(try artifact(version));try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
            let hidden=try await f.service.read(scope:Profiles.user,conversationID:f.conversationID).goals[f.binding.task_id]!
            try check(hidden.artifacts.isEmpty && hidden.state == .unknown && hidden.sourceAuthorizationCurrent==false,"Late old/equal/unseen head revived a superseded frozen binding")
            try check(Set(hidden.artifactHistory.map(\.version))==Set([1,2,3]),"A stale snapshot changed immutable known history")
        }
        do {try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:try artifact(4));throw Failure(message:"Late applied callback revived an invalidated source")}catch is ConversationSessionError {}
        let cold=ConversationSessionService(repository:try Repository(persistence:FilePersistence(url:f.root.appendingPathComponent("store.json"))),backend:f.backend)
        try await cold.observe(scope:Profiles.user,conversationID:f.conversationID)
        let hidden=try await cold.read(scope:Profiles.user,conversationID:f.conversationID).goals[f.binding.task_id]!
        try check(hidden.artifacts.isEmpty && hidden.sourceAuthorizationCurrent==false,"Cold journal lost the source invalidation barrier")
        let legacy=try await fixture();defer{try? FileManager.default.removeItem(at:legacy.root)}
        try await legacy.service.recordArtifactRevision(scope:Profiles.user,binding:legacy.binding,artifact:try artifact(2))
        await legacy.backend.hideCurrent(legacy:true);try await legacy.service.observe(scope:Profiles.user,conversationID:legacy.conversationID)
        await legacy.backend.setCurrent(try artifact(2));try await legacy.service.observe(scope:Profiles.user,conversationID:legacy.conversationID)
        let migrated=try await legacy.service.read(scope:Profiles.user,conversationID:legacy.conversationID).goals[legacy.binding.task_id]!
        try check(migrated.artifacts.isEmpty && migrated.sourceAuthorizationCurrent==false,"Legacy hidden journal was exposed by an equal-head snapshot")
    }
    static func scopeAndDeletion() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let foreign=DataScope(profileID:UUID(),workspaceID:UUID())
        do {try await f.service.recordArtifactRevision(scope:foreign,binding:f.binding,artifact:try artifact(2));throw Failure(message:"Foreign local scope accepted")} catch is catError {}
        let record=try await f.repository.record(f.conversationID,scope:Profiles.user)
        try await f.repository.commit(scope:Profiles.user,mutations:[.remove(record.id,record.header.revision)])
        do {try await f.service.recordArtifactRevision(scope:Profiles.user,binding:f.binding,artifact:try artifact(2));throw Failure(message:"Deleted conversation resurrected")} catch is catError {}
    }
    static func confirmedCancellationAndLateHeads() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        await f.backend.cancelCurrent();try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
        let stopped=try await f.service.read(scope:Profiles.user,conversationID:f.conversationID).goals[f.binding.task_id]!
        try check(stopped.state == .cancelled && stopped.sourceAuthorizationCurrent==false && stopped.artifacts.isEmpty,"Confirmed cancellation became unknown or restored artifact authority")
        for version in [1,2,3] {
            await f.backend.setCurrent(try artifact(version));try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
            let preserved=try await f.service.read(scope:Profiles.user,conversationID:f.conversationID).goals[f.binding.task_id]!
            try check(preserved.state == .cancelled && preserved.sourceAuthorizationCurrent==false && preserved.artifacts.isEmpty && preserved.artifactHistory.map(\.version)==[1],"Late completed/current projection revived cancellation or added a hidden head")
        }
        await f.backend.hideCurrent();try await f.service.observe(scope:Profiles.user,conversationID:f.conversationID)
        let cold=ConversationSessionService(repository:try Repository(persistence:FilePersistence(url:f.root.appendingPathComponent("store.json"))),backend:f.backend)
        try await cold.observe(scope:Profiles.user,conversationID:f.conversationID)
        let saved=try await cold.read(scope:Profiles.user,conversationID:f.conversationID).goals[f.binding.task_id]!
        try check(saved.state == .cancelled && saved.sourceAuthorizationCurrent==false && saved.artifacts.isEmpty,"Late unknown or cold restore erased cancellation")
        let counts=await f.backend.counts();try check(counts.0==1,"Cancellation recovery sent another turn")
    }
}
private actor ArtifactJournalFixtureBackend:ConversationBackend {
    let initial:ConversationArtifactProjection
    private var request:ConversationTurnRequest?,originalGoal:ConversationGoalProjection?,posts=0,reads=0,hidden=false,legacyHidden=false,cancelled=false,replacement:ConversationArtifactProjection?
    init(artifact:ConversationArtifactProjection){initial=artifact}
    func connection(scope:DataScope) async -> ConversationConnection {.init(state:.connected,provider:"Explicit offline journal fixture",detail:"No external requests")}
    func reply(_ r:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
        posts += 1;request=r
        let b=ConversationTaskBinding(scope_id:UUID(),conversation_id:r.conversationID,turn_id:r.operationID,call_id:"journal-only",delegation_id:UUID(),operation_id:UUID(),run_id:UUID(),task_id:"journal-task",request_hash:textHash("offline-journal"),delegation_revision:1,grant_epoch:1,projection_url:"/fixture-only")
        var goal=ConversationGoalProjection(id:b.task_id,revision:1,title:initial.title,state:.completed,summary:initial.summary,updatedAt:Date());goal.binding=b;goal.artifacts=[initial];originalGoal=goal
        let result=ConversationToolResult(callID:b.call_id,name:"delegate_plan_v1",content:"{}",committedGoals:[goal])
        return AsyncThrowingStream {c in c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:1,payload:.toolStarted(callID:b.call_id,name:"delegate_plan_v1",arguments:"{}")));c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:2,payload:.toolResult(result)));c.yield(.init(operationID:r.operationID,epoch:r.epoch,sequence:3,payload:.completed(messageID:UUID(),finalTextHash:textHash(""))));c.finish()}
    }
    func observe(_ r:ConversationTurnRequest) async throws -> ConversationObservation {
        reads += 1;var goal=originalGoal!
        if let replacement {goal=ConversationGoalProjection(id:goal.id,revision:1,title:replacement.title,state:.completed,summary:replacement.summary,updatedAt:Date());goal.binding=originalGoal?.binding;goal.artifacts=[replacement]}
        goal.sourceAuthorizationCurrent=true
        if hidden {goal=ConversationGoalProjection(id:goal.id,revision:1,title:goal.title,state:cancelled ? .cancelled:.unknown,summary:"Original authority changed",updatedAt:Date());goal.binding=originalGoal?.binding;goal.sourceAuthorizationCurrent=legacyHidden ? nil:false}
        return .init(request:r,events:[],goals:[goal])
    }
    func binding() throws -> ConversationTaskBinding {guard let b=originalGoal?.binding else {throw ConversationSessionError.invalidEvent};return b}
    func counts()->(Int,Int){(posts,reads)}
    func hideCurrent(legacy:Bool=false){hidden=true;legacyHidden=legacy;cancelled=false}
    func cancelCurrent(){hidden=true;legacyHidden=false;cancelled=true}
    func setCurrent(_ artifact:ConversationArtifactProjection){hidden=false;replacement=artifact;cancelled=false}
}
