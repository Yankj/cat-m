import Foundation
import XCTest
@testable import CatpawM

final class ConversationTurnActivityTests:XCTestCase {
    private func session(state:ConversationTurnRecord.State = .running)->ConversationSession {
        let cid=UUID(),id=UUID(),request=ConversationTurnRequest(scope:Profiles.user,conversationID:cid,threadID:nil,operationID:id,epoch:1,history:[])
        var session=ConversationSession(scope:Profiles.user,conversationID:cid)
        session.turns=[.init(id:id,request:request,state:state,lastSequence:1,error:nil)]
        session.messages=[.init(id:stableID("conversation-user-\(id)"),role:.user,content:"Named synthetic request")]
        return session
    }
    private func call(_ session:ConversationSession,_ call:String="named-call",name:String="agent_status",complete:Bool=false)->ConversationTranscriptMessage {
        .init(id:stableID("conversation-call-\(session.turns[0].id)-\(call)"),role:.assistant,content:"{\"private_arguments_not_for_presentation\":true}",toolCallID:call,toolName:name,complete:complete)
    }
    private func result(_ session:ConversationSession,_ call:String="named-call",name:String="agent_status")->ConversationTranscriptMessage {
        .init(id:stableID("conversation-tool-result-\(session.turns[0].id)-\(call)"),role:.tool,content:"{\"original_tool_result\":true}",toolCallID:call,toolName:name)
    }
    private func one(_ session:ConversationSession,file:StaticString=#filePath,line:UInt=#line)throws->ConversationTurnActivitySnapshot {
        let snapshots=ConversationTurnActivityProjection.snapshots(session:session);XCTAssertEqual(snapshots.count,1,file:file,line:line);return try XCTUnwrap(snapshots.first,file:file,line:line)
    }
    func testDispatchedAndAdmittedBeforeFirstTokenHaveOneStableHonestStatus()throws {
        var s=session(state:.dispatched),first=try one(s)
        XCTAssertEqual(first.id,s.turns[0].id);XCTAssertEqual(first.phase,.sending);XCTAssertEqual(first.phase.summaryKey,"正在发送…");XCTAssertTrue(first.tools.isEmpty)
        s.turns[0].state = .running;let admitted=try one(s);XCTAssertEqual(admitted.id,first.id);XCTAssertEqual(admitted.phase,.waiting);XCTAssertEqual(admitted.phase.summaryKey,"正在等待回复")
        first=try one(s);XCTAssertEqual(first,admitted)
    }
    func testIncrementalBodyKeepsSameActivityAndDoesNotPutTokensIntoSnapshot()throws {
        var s=session(),message=ConversationTranscriptMessage(role:.assistant,content:"First",complete:false);s.turns[0].assistantMessageID=message.id;s.messages.append(message)
        let first=try one(s);XCTAssertEqual(first.phase,.writing);XCTAssertTrue(first.hasVisibleText)
        message.content += " more text 🐾";s.messages[s.messages.count-1]=message
        XCTAssertEqual(try one(s),first,"Every token must not change the activity identity or its semantic state")
        s.turns[0].state = .completed;XCTAssertTrue(ConversationTurnActivityProjection.snapshots(session:s).isEmpty)
    }
    func testMultiplePendingToolsUseOneTurnSummaryWithOrderedRealFacts()throws {
        var s=session();let a=call(s,"first",name:"delegate_plan_v1"),b=call(s,"second",name:"agent_status");s.messages += [a,b]
        let projection=try one(s);XCTAssertEqual(projection.phase,.processing);XCTAssertEqual(projection.tools.map(\.id),[a.id,b.id]);XCTAssertEqual(projection.tools.map(\.state),[.pending,.pending]);XCTAssertEqual(projection.tools.map(\.titleKey),["创建工作计划","读取任务进展"])
        XCTAssertEqual(projection.tools[0].sourceMessageIDs,[a.id]);XCTAssertFalse(projection.phase.summaryKey.contains("完成"))
    }
    func testResultUpdatesOriginalCallFactWithoutInventingTaskCompletionOrRemovingBusinessResult()throws {
        var s=session();let c=call(s,name:"delegate_plan_v1");s.messages.append(c);let pending=try one(s)
        s.messages[s.messages.count-1].complete=true;let r=result(s,name:"delegate_plan_v1");s.messages.append(r)
        s.turns[0].state = .completed;let originalMessages=s.messages,rows=ConversationTimelineProjection.rows(messages:s.messages,turns:s.turns),settled=try one(s)
        XCTAssertEqual(settled.id,pending.id);XCTAssertEqual(settled.tools.count,1);XCTAssertEqual(settled.tools[0].id,c.id);XCTAssertEqual(settled.tools[0].state,.received)
        XCTAssertEqual(settled.tools[0].sourceMessageIDs,[c.id,r.id]);XCTAssertEqual(settled.phase,.ended);XCTAssertEqual(settled.phase.summaryKey,"本次回复已结束")
        XCTAssertEqual(rows.last?.message.id,r.id);XCTAssertEqual(rows.last?.presentation,.message);XCTAssertEqual(s.messages.map(\.id),originalMessages.map(\.id));XCTAssertEqual(s.messages.map(\.content),originalMessages.map(\.content));XCTAssertTrue(s.goals.isEmpty)
    }
    func testCompletedCallWithoutResultNeedsReviewInsteadOfSuccessfulOrInfinitePendingStatus()throws {
        var s=session(state:.completed);s.messages.append(call(s,complete:true));let activity=try one(s)
        XCTAssertEqual(activity.phase,.needsReview);XCTAssertEqual(activity.tools.map(\.state),[.needsReview])
        let row=ConversationTimelineProjection.rows(messages:s.messages,turns:s.turns).last;XCTAssertEqual(row?.presentation,.fallback);XCTAssertEqual(row?.issue,.inconsistentToolState)
    }
    func testInvalidPairAndUnknownNeverBecomeReceivedFromCompletedCallAlone()throws {
        var s=session();s.messages += [call(s,complete:true),result(s,name:"delegate_task")]
        let invalid=try one(s);XCTAssertEqual(invalid.phase,.needsReview);XCTAssertEqual(invalid.tools.map(\.state),[.needsReview,.needsReview])
        s=session(state:.unknown);s.messages.append(call(s,complete:true));let unknown=try one(s);XCTAssertEqual(unknown.phase,.needsReview);XCTAssertEqual(unknown.tools[0].state,.needsReview)
    }
    func testReceivedBusinessResultSurvivesFailedOrUnknownProse()throws {
        for state:ConversationTurnRecord.State in [.failed,.unknown] {
            var s=session(state:state);s.messages += [call(s,name:"present_cgui_v1",complete:true),result(s,name:"present_cgui_v1")]
            let activity=try one(s);XCTAssertEqual(activity.phase,.needsReview);XCTAssertEqual(activity.tools.count,1);XCTAssertEqual(activity.tools[0].state,.received)
            XCTAssertEqual(ConversationTimelineProjection.rows(messages:s.messages,turns:s.turns).last?.presentation,.message)
        }
    }
    func testUnsentOrCancelledAndForeignConversationNeverClaimActivity() {
        for state:ConversationTurnRecord.State in [.notSent,.cancelledBeforeSend] {var s=session(state:state);s.messages.append(call(s));XCTAssertTrue(ConversationTurnActivityProjection.snapshots(session:s).isEmpty)}
        let other=session();var s=session();s.turns=other.turns;s.messages=other.messages;XCTAssertTrue(ConversationTurnActivityProjection.snapshots(session:s).isEmpty)
    }
    func testSameCallNameInDifferentTurnsDoesNotMergeAndDuplicateTurnIdentityIsNotGuessed()throws {
        var s=session();s.messages.append(call(s));let a=try one(s);var other=session();let original=other.turns[0],request=ConversationTurnRequest(scope:s.scope,conversationID:s.conversationID,threadID:nil,operationID:original.id,epoch:1,history:[])
        other.turns=[.init(id:original.id,request:request,state:.running,lastSequence:1,error:nil)];other.messages=[call(other)];s.turns += other.turns;s.messages += other.messages
        let both=ConversationTurnActivityProjection.snapshots(session:s);XCTAssertEqual(both.count,2);XCTAssertEqual(both[0].id,a.id);XCTAssertNotEqual(both[0].tools[0].id,both[1].tools[0].id)
        s.turns.append(s.turns[0]);XCTAssertEqual(ConversationTurnActivityProjection.snapshots(session:s).map(\.id),[original.id])
    }
    func testUnknownToolNameUsesControlledGenericLabelAndNeverDisplaysArguments()throws {
        var s=session();s.messages.append(call(s,name:"unrecognized_private_name"));let activity=try one(s)
        XCTAssertEqual(activity.tools[0].titleKey,"工具处理");XCTAssertEqual(activity.tools[0].state,.pending);XCTAssertFalse(activity.tools[0].titleKey.contains("private"));XCTAssertEqual(activity.tools[0].state.labelKey,"等待工具回执")
    }
}

/// chat-ux-1505 #4a: every stage transition maps to a Live Activity phase (no stage is dropped → no stuck 「正在思考…」).
final class CatpawWorkPhaseMappingTests: XCTestCase {
    private func device(_ tool: String, confirm: String) -> ConversationTurnEvent.Payload {
        .deviceCall(ConversationDeviceCall(interruptID: UUID().uuidString.lowercased(), callID: "c-\(tool)", tool: tool, args: Data("{}".utf8), confirm: confirm, ttlSec: 600, argsHash: String(repeating: "a", count: 64), expiresAt: "2099-01-01T00:00:00Z"))
    }
    func testStagesMap() {
        XCTAssertEqual(CatpawWorkPhase.from(.started(requestHash: "h", conversationRevision: 1, grantEpoch: 1)), .thinking)
        XCTAssertEqual(CatpawWorkPhase.from(.reasoningSummary(messageID: UUID(), text: "x", thinkingMs: nil)), .thinking)
        XCTAssertEqual(CatpawWorkPhase.from(.toolStarted(callID: "1", name: "calendar_list", arguments: "{}")), .tool("calendar_list"))
        XCTAssertEqual(CatpawWorkPhase.from(.suspended(interruptIDs: ["i"], expiresAt: "2099-01-01T00:00:00Z")), .awaitingUser)
        XCTAssertEqual(CatpawWorkPhase.from(.approvalResolved(interruptID: "i", callID: "1", decision: "allow", remember: false)), .thinking)
        XCTAssertEqual(CatpawWorkPhase.from(.textDelta(messageID: UUID(), text: "a")), .writing)
        XCTAssertEqual(CatpawWorkPhase.from(.completed(messageID: UUID(), finalTextHash: "h")), .done)
        XCTAssertEqual(CatpawWorkPhase.from(.failed(message: "x", reconciliationRequired: false)), .failed)
        XCTAssertNil(CatpawWorkPhase.from(.thread("t")))
    }
    func testDeviceCallsNeedingACardAwaitUser_readOnlyAutoRunStayTool() {
        XCTAssertEqual(CatpawWorkPhase.from(device("calendar_create", confirm: "card")), .awaitingUser)
        XCTAssertEqual(CatpawWorkPhase.from(device("places_search", confirm: "card")), .tool("places_search"))
        XCTAssertEqual(CatpawWorkPhase.from(device("calendar_list", confirm: "none")), .tool("calendar_list"))
    }
    func testKindsMatchSharedAttributesAndTerminals() {
        typealias K = CatpawWorkAttributes.ContentState.Kind
        XCTAssertEqual(CatpawWorkPhase.thinking.kind, K.thinking)
        XCTAssertEqual(CatpawWorkPhase.tool("x").kind, K.tool)
        XCTAssertEqual(CatpawWorkPhase.writing.kind, K.writing)
        XCTAssertEqual(CatpawWorkPhase.awaitingUser.kind, K.needsUser)
        XCTAssertEqual(CatpawWorkPhase.done.kind, K.done)
        XCTAssertEqual(CatpawWorkPhase.failed.kind, K.failed)
        XCTAssertTrue(CatpawWorkPhase.done.isTerminal && CatpawWorkPhase.failed.isTerminal && !CatpawWorkPhase.awaitingUser.isTerminal)
        XCTAssertEqual(CatpawWorkPhase.tool("calendar_list").bodyKey.key, "正在查日历")
        XCTAssertEqual(CatpawWorkPhase.tool("some_unknown_tool").bodyKey.key, "正在使用工具…")
    }
}

/// ux-round-1505: ContentState gained optional fields; payloads from older builds and the proactive server must still decode.
final class CatpawWorkContentStateCompatibilityTests: XCTestCase {
    func testOldPayloadDecodesWithNilNewFields() throws {
        let old = #"{"title":"提醒","body":"10 点给客户回电话","kind":"reminder_due","taskID":"t-1"}"#
        let s = try JSONDecoder().decode(CatpawWorkAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertEqual(s.kind, "reminder_due"); XCTAssertEqual(s.taskID, "t-1")
        XCTAssertNil(s.startedAt); XCTAssertNil(s.endedAt); XCTAssertNil(s.step); XCTAssertNil(s.tool); XCTAssertNil(s.summary)
    }
    func testNewPayloadRoundTripsAndStaysSmall() throws {
        let s = CatpawWorkAttributes.ContentState(title: "Catpaw 正在工作", body: "正在查日历", kind: "tool", taskID: UUID().uuidString,
                                                  startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, step: 2, tool: "calendar_list", summary: "评审会加进日历")
        let data = try JSONEncoder().encode(s)
        XCTAssertLessThan(data.count, 4096)
        XCTAssertEqual(try JSONDecoder().decode(CatpawWorkAttributes.ContentState.self, from: data), s)
    }
}

/// chat-ux-1505 follow-up: the Live Activity title is the user's task text, not always 「Catpaw 正在处理」.
final class CatpawLiveActivityTaskTitleTests: XCTestCase {
    func testTaskTitleIsFirstLineCollapsedAndTruncated() {
        XCTAssertEqual(CatpawLiveActivityCoordinator.taskTitle("附近有哪些适合办公的咖啡馆？"), "附近有哪些适合办公的咖啡馆？")
        XCTAssertEqual(CatpawLiveActivityCoordinator.taskTitle("\n  帮我  起草周报 \n第二行细节"), "帮我 起草周报")
        let long = String(repeating: "很", count: 40)
        let t = CatpawLiveActivityCoordinator.taskTitle(long)
        XCTAssertEqual(t?.count, CatpawLiveActivityCoordinator.taskTitleLimit)
        XCTAssertEqual(t?.hasSuffix("…"), true)
        XCTAssertNil(CatpawLiveActivityCoordinator.taskTitle("  \n \n"))
        XCTAssertNil(CatpawLiveActivityCoordinator.taskTitle(nil))
    }
}
