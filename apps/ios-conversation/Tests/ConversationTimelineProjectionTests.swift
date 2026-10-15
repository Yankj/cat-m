import Foundation
import XCTest
@testable import CatpawM

final class ConversationTimelineProjectionTests:XCTestCase {
    private func turn(_ id:UUID=UUID(),state:ConversationTurnRecord.State = .running,assistant:UUID?=nil)->ConversationTurnRecord {
        let request=ConversationTurnRequest(scope:Profiles.user,conversationID:UUID(),threadID:nil,operationID:id,epoch:1,history:[])
        var turn=ConversationTurnRecord(id:id,request:request,state:state,lastSequence:4,error:nil)
        turn.assistantMessageID=assistant;return turn
    }
    private func call(_ turn:ConversationTurnRecord,_ call:String="same-call",name:String="agent_status",complete:Bool=false)->ConversationTranscriptMessage {
        .init(id:stableID("conversation-call-\(turn.id)-\(call)"),role:.assistant,content:"{\"original_arguments\":true}",toolCallID:call,toolName:name,complete:complete)
    }
    private func result(_ turn:ConversationTurnRecord,_ call:String="same-call",name:String="agent_status")->ConversationTranscriptMessage {
        .init(id:stableID("conversation-tool-result-\(turn.id)-\(call)"),role:.tool,content:"{\"original_receipt\":true}",toolCallID:call,toolName:name)
    }
    func testCallAndVerifiedResultReplaceInPlaceWithoutChangingOriginalMessages() {
        let t=turn(),pending=call(t),body=ConversationTranscriptMessage(role:.assistant,content:"Partial answer",complete:false)
        let live=ConversationTimelineProjection.rows(messages:[pending,body],turns:[t])
        XCTAssertEqual(live.count,2);XCTAssertEqual(live[0].id,pending.id);XCTAssertEqual(live[0].presentation,.processPending)
        var finished=pending;finished.complete=true
        let receipt=result(t),done=ConversationTimelineProjection.rows(messages:[finished,body,receipt],turns:[t])
        XCTAssertEqual(done.count,2);XCTAssertEqual(done[0].id,live[0].id);XCTAssertEqual(done[0].message.id,receipt.id)
        XCTAssertEqual(done[0].message.content,receipt.content);XCTAssertEqual(done[0].sourceMessageIDs,[pending.id,receipt.id])
        XCTAssertEqual(done[1].message.id,body.id);XCTAssertEqual(done[1].message.content,body.content)
        XCTAssertFalse(pending.complete);XCTAssertTrue(finished.complete)
    }
    func testIdenticalCallIDsInDifferentTurnsNeverCrossPair() {
        let a=turn(),b=turn(),ac=call(a,complete:true),bc=call(b),ar=result(a)
        let rows=ConversationTimelineProjection.rows(messages:[ac,bc,ar],turns:[a,b])
        XCTAssertEqual(rows.count,2);XCTAssertEqual(rows[0].message.id,ar.id);XCTAssertEqual(rows[0].turnID,a.id)
        XCTAssertEqual(rows[1].message.id,bc.id);XCTAssertEqual(rows[1].turnID,b.id);XCTAssertEqual(rows[1].presentation,.processPending)
    }
    func testUserAndIncrementalAnswerKeepOriginalUUIDOrderAndTurn() {
        let answer=UUID(),t=turn(assistant:answer),user=ConversationTranscriptMessage(id:stableID("conversation-user-\(t.id)"),role:.user,content:"Question")
        let body=ConversationTranscriptMessage(id:answer,role:.assistant,content:"One",complete:false)
        let before=ConversationTimelineProjection.rows(messages:[user,body],turns:[t])
        var increment=body;increment.content += " two 🐾"
        let after=ConversationTimelineProjection.rows(messages:[user,increment],turns:[t])
        XCTAssertEqual(before.map(\.id),after.map(\.id));XCTAssertEqual(after.map(\.id),[user.id,body.id])
        XCTAssertEqual(after.map(\.turnID),[t.id,t.id]);XCTAssertEqual(after[1].message.content,increment.content)
    }
    func testCompletedCallWithoutResultCannotClaimSuccessfulRead() {
        let t=turn(),c=call(t,complete:true)
        let rows=ConversationTimelineProjection.rows(messages:[c],turns:[t])
        XCTAssertEqual(rows[0].presentation,.processPending);XCTAssertEqual(rows[0].issue,.missingResult)
    }
    func testTerminalCompletedTurnWithoutToolResultRequiresReconciliationInsteadOfActivity() {
        for callComplete in [false,true] {
            let t=turn(state:.completed),c=call(t,complete:callComplete)
            let rows=ConversationTimelineProjection.rows(messages:[c],turns:[t])
            XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].message.id,c.id)
            XCTAssertEqual(rows[0].presentation,.fallback);XCTAssertEqual(rows[0].issue,.inconsistentToolState)
        }
    }
    func testFailureIsNeverCoveredByAResultAndUnknownRemainsVisible() {
        let t=turn();var c=call(t,complete:true);c.failure="Actual tool failure"
        let rows=ConversationTimelineProjection.rows(messages:[c,result(t)],turns:[t])
        XCTAssertEqual(rows.count,2);XCTAssertTrue(rows.allSatisfy{$0.presentation == .fallback && $0.issue == .failedMessage})
        XCTAssertEqual(rows[0].message.failure,"Actual tool failure")
        let unknown=turn(state:.unknown),u=ConversationTimelineProjection.rows(messages:[call(unknown,complete:true)],turns:[unknown])
        XCTAssertEqual(u.count,1);XCTAssertEqual(u[0].issue,.unknownTurn);XCTAssertEqual(u[0].presentation,.fallback)
    }
    func testKnownToolResultAndOriginalArtifactEntrySurviveFailedOrUnknownProseStream() {
        for state:ConversationTurnRecord.State in [.failed,.unknown] {
            for name in ["delegate_task","present_cgui_v1","propose_memory_v1","revise_current_report_v1",ConversationRevisionWorkCodec.toolName] {
                let t=turn(state:state),c=call(t,name:name,complete:true),r=result(t,name:name)
                let rows=ConversationTimelineProjection.rows(messages:[c,r],turns:[t])
                XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].presentation,.message);XCTAssertNil(rows[0].issue)
                XCTAssertEqual(rows[0].message.id,r.id);XCTAssertEqual(rows[0].message.toolName,r.toolName)
                XCTAssertEqual(rows[0].message.content,r.content,"Known receipt remains available to the existing strict artifact/receipt renderer")
            }
        }
    }
    func testInvalidOrphanAndAmbiguousRecordsFailVisibleWithoutGuessing() {
        let t=turn(),receipt=result(t)
        let orphan=ConversationTimelineProjection.rows(messages:[receipt],turns:[t])
        XCTAssertEqual(orphan.count,1);XCTAssertEqual(orphan[0].issue,.missingCall)
        var foreign=call(t);foreign=ConversationTranscriptMessage(id:UUID(),role:.assistant,content:foreign.content,toolCallID:foreign.toolCallID,toolName:foreign.toolName)
        XCTAssertEqual(ConversationTimelineProjection.rows(messages:[foreign],turns:[t])[0].issue,.unownedTool)
        let ambiguous=ConversationTimelineProjection.rows(messages:[call(t)],turns:[t,t])
        XCTAssertEqual(ambiguous[0].issue,.ambiguousTurn)
        let wrongName=ConversationTimelineProjection.rows(messages:[call(t,complete:true),result(t,name:"delegate_task")],turns:[t])
        XCTAssertEqual(wrongName.count,2);XCTAssertTrue(wrongName.allSatisfy{$0.issue == .toolMismatch})
        let reversed=ConversationTimelineProjection.rows(messages:[receipt,call(t,complete:true)],turns:[t])
        XCTAssertEqual(reversed.count,2);XCTAssertTrue(reversed.allSatisfy{$0.issue == .invalidOrder})
    }
    func testDedicatedToolRenderersReceiveExactOriginalResultIdentityAndPayload() {
        for name in ["present_cgui_v1","propose_memory_v1","revise_current_report_v1",ConversationRevisionWorkCodec.toolName] {
            let t=turn(),c=call(t,name:name,complete:true),r=result(t,name:name)
            let rows=ConversationTimelineProjection.rows(messages:[c,r],turns:[t])
            XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].presentation,.message)
            XCTAssertEqual(rows[0].id,c.id);XCTAssertEqual(rows[0].message.id,r.id);XCTAssertEqual(rows[0].message.toolName,name)
            XCTAssertEqual(rows[0].message.toolCallID,r.toolCallID);XCTAssertEqual(rows[0].message.content,r.content)
        }
    }
    func testDuplicateMessageUUIDsRemainVisibleWithUniqueRowIDs() {
        let t=turn(),c=call(t)
        let rows=ConversationTimelineProjection.rows(messages:[c,c,result(t)],turns:[t])
        XCTAssertEqual(rows.count,3);XCTAssertEqual(Set(rows.map(\.id)).count,3)
        XCTAssertEqual(rows[0].message.id,c.id);XCTAssertEqual(rows[1].message.id,c.id)
        XCTAssertEqual(rows[0].issue,.duplicateIdentity);XCTAssertEqual(rows[1].issue,.duplicateIdentity)
    }
}
