import Foundation
import XCTest
@testable import CatpawM

final class ConversationArtifactContinuationProjectionTests:XCTestCase {
    private func fixture() throws -> (ConversationTaskRevisionReceipt,ConversationTurnRequest) {
        let scope=UUID(uuidString:"00000000-0000-4000-8000-000000000001")!,subject=UUID(uuidString:"00000000-0000-4000-8000-000000000002")!,conversation=UUID(uuidString:"00000000-0000-4000-8000-000000000003")!,turn=UUID(uuidString:"00000000-0000-4000-8000-000000000004")!,run=UUID(uuidString:"00000000-0000-4000-8000-000000000005")!
        let raw="第二条结论补风险 / 中文\n\u{FEFF}\u{85}",task=String(repeating:"b",count:64),artifact=ConversationArtifactVersionReference(artifactID:String(repeating:"c",count:64),version:3,contentHash:String(repeating:"d",count:64))
        let binding=ConversationTaskBinding(scope_id:scope,conversation_id:conversation,turn_id:UUID(uuidString:"00000000-0000-4000-8000-000000000006")!,call_id:"original-call",delegation_id:UUID(uuidString:"00000000-0000-4000-8000-000000000007")!,operation_id:UUID(uuidString:"00000000-0000-4000-8000-000000000008")!,run_id:run,task_id:task,request_hash:textHash("original request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/\(scope.uuidString.lowercased())/runs/\(run.uuidString.lowercased())")
        let target=ConversationArtifactContinuationIntent(intent:.reviseReport,runID:run,taskID:task,artifactReference:artifact,expectedGrantEpoch:1,expectedPlanRevision:1,expectedPlanHash:String(repeating:"e",count:64))
        let request=ConversationTurnRequest(scope:Profiles.user,conversationID:conversation,threadID:conversation.uuidString,operationID:turn,epoch:2,history:[.init(role:.user,content:raw)],continuation:target,continuationOriginalBinding:binding,continuationSubjectID:subject)
        let record=try JSONDecoder().decode(ConversationTaskRevisionReceipt.self,from:Self.serverReceipt)
        return (record,request)
    }
    func testNodeCanonicalReceiptAndRawInstructionHashMatchSwiftWithoutRebindingOriginalTask() throws {
        let (receipt,request)=try fixture()
        XCTAssertEqual(textHash(request.history[0].content),"e2d59c09a9dce6f1267073b87a0764b74df1560176aac031fab0bedbc85c0d22")
        try receipt.validate(request:request,callID:"offline-revision-call")
        XCTAssertNotEqual(request.operationID,request.continuationOriginalBinding?.turn_id)
        let restored=try JSONDecoder().decode(ConversationTurnRequest.self,from:JSONEncoder().encode(request))
        XCTAssertEqual(restored.continuation,request.continuation);XCTAssertEqual(restored.continuationOriginalBinding,request.continuationOriginalBinding)
        XCTAssertEqual(restored.continuationSubjectID,request.continuationSubjectID)
    }
    func testReceiptRejectsDifferentRawTextAndReadOnlyIntent() throws {
        let (receipt,request)=try fixture(),target=request.continuation!
        let changed=ConversationTurnRequest(scope:request.scope,conversationID:request.conversationID,threadID:request.threadID,operationID:request.operationID,epoch:request.epoch,history:[.init(role:.user,content:request.history[0].content+"changed")],continuation:target,continuationOriginalBinding:request.continuationOriginalBinding,continuationSubjectID:request.continuationSubjectID)
        XCTAssertThrowsError(try receipt.validate(request:changed,callID:"offline-revision-call"))
        let readonly=ConversationArtifactContinuationIntent(intent:.explainReport,runID:target.runID,taskID:target.taskID,artifactReference:target.artifactReference,expectedGrantEpoch:target.expectedGrantEpoch,expectedPlanRevision:target.expectedPlanRevision,expectedPlanHash:target.expectedPlanHash)
        let ask=ConversationTurnRequest(scope:request.scope,conversationID:request.conversationID,threadID:request.threadID,operationID:request.operationID,epoch:request.epoch,history:request.history,continuation:readonly,continuationOriginalBinding:request.continuationOriginalBinding,continuationSubjectID:request.continuationSubjectID)
        XCTAssertThrowsError(try receipt.validate(request:ask,callID:"offline-revision-call"))
    }
    func testCorrectedVersionRequiresExactControlledModelRelationAndCannotUseManualOrOldArtifact() throws {
        let (receipt,_)=try fixture()
        func artifact(version:Int,operation:String?=nil,manual:Bool=false) throws -> ConversationArtifactProjection {
            let base=try JSONSerialization.jsonObject(with:JSONEncoder().encode(receipt.base_reference)),plan=try JSONSerialization.jsonObject(with:JSONEncoder().encode(receipt.accepted_plan_reference))
            let data:[String:Any]=["content":"Synthetic corrected model result","source":manual ? "user_revision" : "local_task","model_revision":["operation_id":operation ?? receipt.operation_id,"operation_hash":receipt.operation_hash,"instruction_hash":receipt.instruction_hash,"base_reference":base,"plan_reference":plan]]
            let body=String(decoding:try JSONSerialization.data(withJSONObject:["kind":"report","data":data],options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
            return .init(id:receipt.base_reference.artifactID,version:version,contentHash:textHash(body),body:body,title:"Synthetic report",summary:"Synthetic corrected result",content:"Synthetic corrected model result")
        }
        XCTAssertTrue(receipt.matchesModelArtifact(try artifact(version:4)))
        XCTAssertTrue(receipt.matchesModelArtifact(try artifact(version:5)),"A corrected intermediate version is part of the same operation")
        XCTAssertFalse(receipt.matchesModelArtifact(try artifact(version:3)))
        XCTAssertFalse(receipt.matchesModelArtifact(try artifact(version:36)))
        XCTAssertFalse(receipt.matchesModelArtifact(try artifact(version:5,operation:UUID().uuidString.lowercased())))
        XCTAssertFalse(receipt.matchesModelArtifact(try artifact(version:5,manual:true)))
        XCTAssertTrue(receipt.permitsCurrentPlan(receipt.accepted_plan_reference))
        XCTAssertTrue(receipt.permitsCurrentPlan(.init(revision:3,planHash:textHash("Later applied plan"))),"Historical completion is read through the original operation while the current task has advanced")
        XCTAssertFalse(receipt.permitsCurrentPlan(.init(revision:2,planHash:textHash("Foreign same-revision plan"))))
        XCTAssertFalse(receipt.permitsCurrentPlan(receipt.base_plan_reference))
    }
    private static let serverReceipt=Data(#"""
{
  "operation_id": "4be0881b-ad2e-4a70-8213-586cd46ed48d",
  "operation_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "scope_id": "00000000-0000-4000-8000-000000000001",
  "subject_id": "00000000-0000-4000-8000-000000000002",
  "conversation_id": "00000000-0000-4000-8000-000000000003",
  "turn_id": "00000000-0000-4000-8000-000000000004",
  "call_id": "offline-revision-call",
  "run_id": "00000000-0000-4000-8000-000000000005",
  "task_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "base_reference": {
    "artifact_id": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "version": 3,
    "content_hash": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  },
  "base_plan_reference": {
    "revision": 1,
    "plan_hash": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  },
  "accepted_plan_reference": {
    "revision": 2,
    "plan_hash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  },
  "instruction_hash": "e2d59c09a9dce6f1267073b87a0764b74df1560176aac031fab0bedbc85c0d22",
  "source_auth_hash": "85a52b5371d08b64beb46c2684e245729e6c4ad4c9b058e039c718e0fd2460a5",
  "fresh_source_auth_hash": "d364d5d65fb0a8e5d4cdb22e3d9e8fdf0ae20539592803880d5c9ab6df4abde3",
  "grant_epoch": 1,
  "accepted_at": "2026-10-14T00:00:00.000Z",
  "receipt_hash": "9d3232b0e3d98c7c5ee5937150c63467c7082bcce04e2ba0d3299a04b22ad57d",
  "state": "accepted"
}
"""#.utf8)
}
