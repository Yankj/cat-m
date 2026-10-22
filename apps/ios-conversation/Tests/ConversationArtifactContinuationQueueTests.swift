import Foundation
#if ARTIFACT_CONTINUATION_QUEUE_PORTABLE
import Darwin
@main private enum ArtifactContinuationQueueRunner {
    static func main() async {
        do {try await ArtifactContinuationQueueCases.roundTrip();print("PASS immutable targeted followup survives actual durable queue; offline synthetic only")}
        catch {print("FAIL \(error)");exit(1)}
    }
}
#else
import XCTest
@testable import cat
final class ConversationArtifactContinuationQueueTests:XCTestCase {
    func testLegacyAndTargetedFollowupColdQueuePreserveExactImmutableIntent() async throws {try await ArtifactContinuationQueueCases.roundTrip()}
}
#endif
private enum ArtifactContinuationQueueCases {
    struct Failure:Error {let message:String}
    static func roundTrip() async throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["ARTIFACT_CONTINUATION_TEST_ROOT"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent("continuation-queue-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("local.json"),scope=Profiles.user,conversation=UUID(),environment=UUID()
        let repo=try Repository(persistence:FilePersistence(url:file))
        try await repo.commit(scope:scope,mutations:[.create(environment,.core(.environment(ExecutionEnvironment(name:"Synthetic queue",kind:.local,connection:.connected,capabilityIDs:[],verifiedAt:nil)))),.create(conversation,.core(.conversation(Conversation(title:"Synthetic continuation queue",projectID:nil,expertID:nil,skillIDs:[],environmentID:environment,archivedAt:nil,draftText:"Independent ordinary draft"))))])
        let intent=ConversationArtifactContinuationIntent(intent:.reviseReport,runID:UUID(),taskID:textHash("synthetic-task"),artifactReference:.init(artifactID:textHash("synthetic-artifact"),version:2,contentHash:textHash("synthetic-selected-v2")),expectedGrantEpoch:3,expectedPlanRevision:4,expectedPlanHash:textHash("synthetic-plan4"))
        let target=try JSONSerialization.jsonObject(with:JSONEncoder().encode(intent))
        let id=UUID(),wire:[String:Any]=["id":id.uuidString,"text":"Please revise the second conclusion","continuation":target]
        let decoded=try JSONDecoder().decode(ConversationFollowup.self,from:JSONSerialization.data(withJSONObject:wire))
        let queue=ConversationFollowupQueueService(repository:repo,scope:scope,conversationID:conversation)
        try await queue.enqueue(decoded)
        let reopened=try Repository(persistence:FilePersistence(url:file)),cold=ConversationFollowupQueueService(repository:reopened,scope:scope,conversationID:conversation)
        let state=try await cold.state()
        guard let actual=state.pending.first else {throw Failure(message:"Durable queue lost the selected followup")}
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(actual)) as? [String:Any]
        guard let retained=encoded?["continuation"] as? NSDictionary,retained.isEqual(to:target as! [AnyHashable:Any]) else {throw Failure(message:"Durable followup stripped immutable continuation and could dispatch ordinary text")}
        let conversationRecord=try await reopened.record(conversation,scope:scope)
        guard conversationRecord.conversation?.draftText=="Independent ordinary draft" else {throw Failure(message:"Target queue replaced ordinary composer draft")}
        let legacy=try JSONDecoder().decode(ConversationFollowup.self,from:JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"text":"ordinary question"]))
        let legacyObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as? [String:Any]
        guard legacyObject?["continuation"]==nil else {throw Failure(message:"Ordinary messages gained a continuation intent")}
    }
}
