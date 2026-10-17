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
        XCTAssertNil(CatpawWorkPhase.from(.suspended(interruptIDs: ["i"], expiresAt: "2099-01-01T00:00:00Z")))   // B1
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
        XCTAssertEqual(CatpawWorkPhase.tool("calendar_list").bodyKey.key, "查看日历")
        XCTAssertEqual(CatpawWorkPhase.tool("some_unknown_tool").bodyKey.key, "正在处理")
        XCTAssertEqual(CatpawWorkPhase.tool("calendar_list").body(.english), "Checking calendar")
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

/// status-line v1.0: copy table coverage, 600 ms dwell / <1 s hidden, confirmation state, VoiceOver throttle.
final class StatusLineTests: XCTestCase {
    private func device(_ tool: String, confirm: String) -> ConversationTurnEvent.Payload {
        .deviceCall(ConversationDeviceCall(interruptID: UUID().uuidString.lowercased(), callID: "c-\(tool)", tool: tool, args: Data("{}".utf8), confirm: confirm, ttlSec: 600, argsHash: String(repeating: "a", count: 64), expiresAt: "2099-01-01T00:00:00Z"))
    }
    func testCopyTableCoversAllowlistAndMemoryTools() {
        let tools = NativeChatHTTPBackend.approvalToolNames.union(DeviceToolContract.clientTools).union(["memory_search", "memory_save", "memory_update", "memory_forget"])
        for t in tools {
            XCTAssertNotNil(ToolStepCopy.table[t], "missing copy for \(t)")
            XCTAssertFalse(ToolStepCopy.title(t).isEmpty); XCTAssertFalse(ToolStepCopy.symbol(t).isEmpty)
        }
        XCTAssertEqual(ToolStepCopy.title("some_unknown_tool"), ToolStepCopy.generic.running[0])
        XCTAssertEqual(ToolStepCopy.confirmTitle(nil), "等你确认")
    }
    func testUnderAppearDelayShowsNothing() {
        XCTAssertEqual(StatusLineThrottle.hideUnder, 0.6)   // visual SPEC §6
        let t0 = Date(); var th = StatusLineThrottle(turnStart: t0)
        _ = th.submit(.sending, at: t0)
        _ = th.submit(.accepted(occurrence: 0), at: t0.addingTimeInterval(0.3))
        XCTAssertNil(th.displayed(at: t0.addingTimeInterval(0.55)))
        XCTAssertEqual(th.displayed(at: t0.addingTimeInterval(0.6)), .accepted(occurrence: 0))   // latest wins pre-visibility
    }
    func testMinimumDwellAndLatestWins() {
        let t0 = Date(); var th = StatusLineThrottle(turnStart: t0)
        _ = th.submit(.accepted(occurrence: 0), at: t0)
        let delay = th.submit(.tool(name: "calendar_list", occurrence: 0), at: t0.addingTimeInterval(0.8))
        XCTAssertEqual(delay ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(th.displayed(at: t0.addingTimeInterval(0.8)), .accepted(occurrence: 0))
        _ = th.submit(.composing(occurrence: 0), at: t0.addingTimeInterval(1.0))
        _ = th.tick(at: t0.addingTimeInterval(1.2))
        XCTAssertEqual(th.displayed(at: t0.addingTimeInterval(1.2)), .composing(occurrence: 0))
    }
    func testAttentionStatesBypassDwell() {
        let t0 = Date(); var th = StatusLineThrottle(turnStart: t0)
        _ = th.submit(.tool(name: "calendar_create", occurrence: 0), at: t0.addingTimeInterval(0.7))
        _ = th.submit(.awaitingUser(tool: "calendar_create"), at: t0.addingTimeInterval(0.8))
        XCTAssertEqual(th.displayed(at: t0.addingTimeInterval(0.8)), .awaitingUser(tool: "calendar_create"))
        let w = StatusLinePhase.awaitingUser(tool: "calendar_create")
        XCTAssertEqual(w.title, "等你确认日程"); XCTAssertEqual(w.symbol, "arrow.down"); XCTAssertEqual(w.kind, .waiting)
        XCTAssertEqual(w.title(en: true), "Waiting for you to confirm the event")
        XCTAssertEqual(w.accessibilityTitle(en: false), "等你确认日程，确认卡片在下方")
        XCTAssertEqual(StatusLinePhase.failed(reason: "x").symbol, "exclamationmark.circle")
        XCTAssertEqual(StatusLinePhase.stopped.symbol, "stop.circle")
    }
    func testBilingualColumnsAndAnnouncementCategories() {
        for (name, e) in ToolStepCopy.table {
            XCTAssertEqual(e.running.count, e.runningEN.count, name)
            XCTAssertFalse(e.short.isEmpty || e.shortEN.isEmpty, name)
            XCTAssertEqual(e.confirm == nil, e.confirmEN == nil, name)
            XCTAssertFalse((e.running + [e.short] + [e.confirm ?? ""]).contains { $0.contains("…") || $0.contains("！") }, name)
        }
        XCTAssertEqual(StatusLinePhase.accepted(occurrence: 0).category, StatusLinePhase.accepted(occurrence: 1).category)
        XCTAssertEqual(StatusLinePhase.tool(name: "calendar_list", occurrence: 0).category, StatusLinePhase.tool(name: "calendar_list", occurrence: 1).category)
        XCTAssertNotEqual(StatusLinePhase.tool(name: "calendar_list", occurrence: 0).category, StatusLinePhase.tool(name: "places_search", occurrence: 0).category)
        XCTAssertEqual(ToolStepCopy.symbol("some_fetch_tool"), "doc.text.magnifyingglass")
    }
    func testConfirmationIsStatic() {
        var r = StatusLineReducer()
        r.apply(device("calendar_create", confirm: "card"))
        guard case .awaitingUser? = r.target else { return XCTFail("expected awaitingUser") }
        XCTAssertFalse(r.target!.animated)
        var r2 = StatusLineReducer()
        r2.apply(.toolStarted(callID: "a", name: "create_task", arguments: "{}"))
        r2.apply(.approvalRequested(ConversationApprovalRequest(interruptID: "i", callID: "a", tool: "create_task", summary: "", arguments: "{}", argsHash: String(repeating: "a", count: 64), expiresAt: "2099-01-01T00:00:00Z", risk: "local_write", rememberAllowed: true)))
        r2.apply(.suspended(interruptIDs: ["i"], expiresAt: "2099-01-01T00:00:00Z"))
        XCTAssertEqual(r2.target, .awaitingUser(tool: "create_task"))
    }
    func testToolThenTextHides() {
        var r = StatusLineReducer()
        r.apply(.toolStarted(callID: "a", name: "web_search", arguments: "{\"q\":\"secret\"}"))
        XCTAssertEqual(r.target, .tool(name: "web_search", occurrence: 0))
        XCTAssertFalse(r.target!.title.contains("secret"))
        r.apply(.textDelta(messageID: UUID(), text: "hi"))
        XCTAssertNil(r.target)
        r.apply(.failed(message: "cancelled", reconciliationRequired: false))
        XCTAssertEqual(r.target, .stopped)
    }
    func testKittenPosesAndBadges() {
        XCTAssertEqual(StatusLinePhase.accepted(occurrence: 0).pose, .thinking)
        XCTAssertNil(StatusLinePhase.accepted(occurrence: 0).badge)
        XCTAssertEqual(StatusLinePhase.tool(name: "calendar_create", occurrence: 0).pose, .tool)
        XCTAssertEqual(StatusLinePhase.tool(name: "calendar_create", occurrence: 0).badge?.symbol, "calendar")
        XCTAssertEqual(StatusLinePhase.tool(name: "mail_compose", occurrence: 0).pose, .writing)
        XCTAssertEqual(StatusLinePhase.composing(occurrence: 0).badge?.symbol, "pencil")
        XCTAssertEqual(StatusLinePhase.awaitingUser(tool: nil).pose, .waiting)
        XCTAssertEqual(StatusLinePhase.awaitingUser(tool: nil).badge?.tone, .waiting)
        XCTAssertEqual(StatusLinePhase.failed(reason: "x").badge?.symbol, "exclamationmark")
        XCTAssertEqual(StatusLinePhase.stopped.badge?.tone, .stopped)
        XCTAssertEqual(StatusLinePhase.switchingModel.badge?.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(ToolStepCopy.badgeSymbol("some_unknown_tool"), "ellipsis")
        for t in NativeChatHTTPBackend.approvalToolNames.union(ToolStepCopy.memoryTools) {
            XCTAssertFalse(ToolStepCopy.badgeSymbol(t).contains(".badge."), t)
        }
        for p in ["Thinking", "Tool", "Writing", "Waiting", "Done", "Failed", "Stopped"] {
            XCTAssertEqual(StatusLinePhase.KittenPose(rawValue: p)?.asset, "StatusKitten" + p)
        }
    }
    func testAnnouncementThrottle() {
        let t0 = Date(); var a = StatusLineAnnouncementThrottle()
        XCTAssertTrue(a.allow(at: t0)); XCTAssertFalse(a.allow(at: t0.addingTimeInterval(1.9))); XCTAssertTrue(a.allow(at: t0.addingTimeInterval(2.0)))
    }
}

/// PREREVIEW fixes (B1, P1-1..P1-3, B2 contract).
final class StatusLinePrereviewTests: XCTestCase {
    private func device(_ tool: String, confirm: String, id: String = "c1") -> ConversationTurnEvent.Payload {
        .deviceCall(ConversationDeviceCall(interruptID: "i-\(id)", callID: id, tool: tool, args: Data("{}".utf8), confirm: confirm, ttlSec: 600, argsHash: String(repeating: "a", count: 64), expiresAt: "2099-01-01T00:00:00Z"))
    }
    private let suspended = ConversationTurnEvent.Payload.suspended(interruptIDs: ["i"], expiresAt: "2099-01-01T00:00:00Z")

    /// B1: confirm:"none" device calls are followed by turn_suspended, but must never show 「等你确认」.
    func testAutoRunDeviceCallNeverWaits() {
        for tool in ["calendar_list", "places_search"] {
            var r = StatusLineReducer(); var seen: [StatusLinePhase?] = []
            for p in [ConversationTurnEvent.Payload.toolStarted(callID: "c1", name: tool, arguments: "{}"), device(tool, confirm: "none"), suspended] {
                r.apply(p); seen.append(r.target)
            }
            XCTAssertFalse(seen.contains { $0?.kind == .waiting }, tool)
            XCTAssertEqual(r.target, .tool(name: tool, occurrence: 0))
            XCTAssertEqual(r.target?.title, ToolStepCopy.title(tool))
        }
        var card = StatusLineReducer()
        card.apply(device("calendar_create", confirm: "card")); card.apply(suspended)
        XCTAssertEqual(card.target, .awaitingUser(tool: "calendar_create"))
        XCTAssertNil(CatpawWorkPhase.from(suspended))
    }
    /// P1-1: a rebuilt projection restores waiting.
    func testRestoreAwaiting() {
        var r = StatusLineReducer(); r.restoreAwaiting(tool: "calendar_create")
        XCTAssertEqual(r.target?.title, "等你确认日程")
        r.apply(.approvalResolved(interruptID: "i", callID: "c1", decision: "approved", remember: false))
        XCTAssertEqual(r.target?.kind, .working)
        var a = StatusLineReducer(); a.restoreAccepted()
        XCTAssertEqual(a.target, .accepted(occurrence: 0))
    }
    /// P1-2: static states are visible immediately, even inside the 0.6 s appear gate.
    func testStaticStatesBypassAppearGate() {
        let t0 = Date()
        for phase in [StatusLinePhase.awaitingUser(tool: nil), .failed(reason: "x"), .stopped] {
            var th = StatusLineThrottle(turnStart: t0)
            _ = th.submit(.sending, at: t0)
            _ = th.submit(phase, at: t0.addingTimeInterval(0.2))
            XCTAssertEqual(th.displayed(at: t0.addingTimeInterval(0.2)), phase)
        }
        var th = StatusLineThrottle(turnStart: t0); _ = th.submit(.sending, at: t0)
        XCTAssertNil(th.displayed(at: t0.addingTimeInterval(0.2)))
    }
    /// P1-3: attention (incl. stopped) always goes out; throttled working states get a replay delay.
    func testAnnouncementReplayAndStoppedPriority() {
        let t0 = Date(); var a = StatusLineAnnouncementThrottle()
        XCTAssertNil(a.request(attention: false, at: t0))
        XCTAssertEqual(a.request(attention: false, at: t0.addingTimeInterval(0.5)) ?? 0, 1.5, accuracy: 0.001)
        XCTAssertNil(a.request(attention: StatusLinePhase.stopped.kind != .working, at: t0.addingTimeInterval(0.6)))
        XCTAssertNotNil(a.request(attention: false, at: t0.addingTimeInterval(1.0)))
    }
    /// B2: ToolStepCopy covers every server-gated chat tool (device, memory, task, render_ui). Reads the edge sources in
    /// this repo; skipped where the checkout is not reachable (on-device runs).
    func testCopyCoversServerGatedTools() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shared = root.appendingPathComponent("services/edge/supabase/functions/_shared")
        func names(_ rel: String, _ pattern: String) throws -> Set<String> {
            let text = try String(contentsOf: shared.appendingPathComponent(rel), encoding: .utf8)
            let re = try NSRegularExpression(pattern: pattern)
            return Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
        }
        guard FileManager.default.fileExists(atPath: shared.path) else { throw XCTSkip("edge sources not reachable from the test host") }
        var tools = try names("core/src/device-call.mjs", #"fn\('([a-z_0-9]+)'"#)
        tools.formUnion(try names("agent-memory/contract.mjs", #"fn\('([a-z_0-9]+)'"#))
        tools.formUnion(try names("proactive/contract.mjs", #"name:\s*'([a-z_0-9]+)'"#))
        tools.formUnion(try names("core/src/generative-ui.mjs", #"RENDER_UI\s*=\s*'([a-z_0-9]+)'"#))
        XCTAssertTrue(tools.isSuperset(of: ["calendar_list", "memory_search", "memory_save", "memory_update", "memory_forget", "create_task", "render_ui"]), "\(tools.sorted())")
        for t in tools { XCTAssertNotNil(ToolStepCopy.table[t], "ToolStepCopy missing server-gated tool \(t)") }
    }
}

/// v1.1 item 3: Live Activity title = the user's own task text.
@MainActor final class CatpawTaskTitleTests: XCTestCase {
    func testFirstLineTrimmedCollapsedAndCapped() {
        XCTAssertEqual(CatpawTaskTitle.make("  把评审会   加进日历 \n明天下午三点，提醒我"), "把评审会 加进日历")
        XCTAssertEqual(CatpawTaskTitle.make("\n\n  hello\nworld"), "hello")
        let long = CatpawTaskTitle.make("请帮我整理一下这周所有会议的纪要并发给团队每个人")!
        XCTAssertEqual(long.count, CatpawTaskTitle.limit); XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(CatpawTaskTitle.make("abcdefghijabcdefghij"), "abcdefghijabcdefghij")
        XCTAssertNil(CatpawTaskTitle.make(" \n\t "))
    }
    /// R2 (NoBug P1-2): contacts are masked before the 20-character cut; ordinary short numbers stay.
    func testR2PhonesEmailsAndURLsAreMaskedBeforeTruncation() {
        XCTAssertEqual(CatpawTaskTitle.make("给张三打 13812345678"), "给张三打 •••")
        XCTAssertEqual(CatpawTaskTitle.make("给张三打13812345678"), "给张三打•••")
        XCTAssertEqual(CatpawTaskTitle.make("拨 +86 138-1234-5678 再说"), "拨 ••• 再说")
        XCTAssertEqual(CatpawTaskTitle.make("发邮件给 alice.w@example.com 说一声"), "发邮件给 ••• 说一声")
        XCTAssertEqual(CatpawTaskTitle.make("看看https://example.com/a?b=1"), "看看•••")
        XCTAssertEqual(CatpawTaskTitle.make("明天3点开会 房间 12345"), "明天3点开会 房间 12345")
        // a long number that would straddle the cut is masked first, so no digits of it survive truncation
        let t = CatpawTaskTitle.make("请帮我把这段话发给同事并打电话 13812345678 确认")!
        XCTAssertFalse(t.contains("138")); XCTAssertLessThanOrEqual(t.count, CatpawTaskTitle.limit)
        XCTAssertFalse(CatpawTaskTitle.make("联系 bob@example.com 或 021-6543 2100")!.contains("@"))
    }
    /// R3 (NoBug P2-R2-1): NFKC first (full-width ＠ / － / digits), dash and dot separators; only masked spans change.
    func testR3FullWidthDashDotAndIDNumbersAreMasked() {
        XCTAssertEqual(CatpawTaskTitle.make("打138－1234－5678，谢谢"), "打•••，谢谢")   // full-width hyphen; full-width comma kept
        XCTAssertEqual(CatpawTaskTitle.make("打138—1234—5678"), "打•••")             // em dash
        XCTAssertEqual(CatpawTaskTitle.make("打138–1234–5678"), "打•••")             // en dash
        XCTAssertEqual(CatpawTaskTitle.make("打138.1234.5678"), "打•••")
        XCTAssertEqual(CatpawTaskTitle.make("打138·1234·5678"), "打•••")
        XCTAssertEqual(CatpawTaskTitle.make("打１３８１２３４５６７８"), "打•••")       // full-width digits
        XCTAssertEqual(CatpawTaskTitle.make("发给 a＠b.com 吧"), "发给 ••• 吧")       // full-width @
        XCTAssertEqual(CatpawTaskTitle.make("ｂｏｂ＠ｅｘａｍｐｌｅ．ｃｏｍ"), "•••")
        XCTAssertEqual(CatpawTaskTitle.make("身份证 11010119900307123X"), "身份证 •••")  // no trailing X
        XCTAssertEqual(CatpawTaskTitle.make("明天下午三点，提醒我"), "明天下午三点，提醒我")   // unmasked text untouched by NFKC
        XCTAssertEqual(CatpawTaskTitle.make("房号 3.5 楼"), "房号 3.5 楼")
    }
    func testHandOffIsPerOperationAndConsumedOnce() {
        let a = UUID(), b = UUID()
        CatpawTaskTitles.note("订明早的车", operationID: a)
        XCTAssertNil(CatpawTaskTitles.take(b))
        XCTAssertEqual(CatpawTaskTitles.take(a), "订明早的车")
        XCTAssertNil(CatpawTaskTitles.take(a))
        CatpawTaskTitles.note("x", operationID: b); CatpawTaskTitles.reset(); XCTAssertNil(CatpawTaskTitles.take(b))
    }
}

/// v1.1 item 2 (B8): conversation residue outside the account partition is purged at sign-out.
final class AccountConversationLocalTests: XCTestCase {
    func testPurgeRemovesVariantsReactionsAndStagedDraftFiles() throws {
        let suite = "b8-\(UUID().uuidString)", d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("draft".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        d.set(["m1": "👍"], forKey: AccountConversationLocal.reactionsKey)
        d.set(Data("{}".utf8), forKey: AccountConversationLocal.replyVariantsPrefix + UUID().uuidString)
        d.set(true, forKey: "catpaw.onboarding.keep")
        AccountConversationLocal.purge(defaults: d, stagingDirectory: dir)
        XCTAssertNil(d.object(forKey: AccountConversationLocal.reactionsKey))
        XCTAssertFalse(d.dictionaryRepresentation().keys.contains { $0.hasPrefix(AccountConversationLocal.replyVariantsPrefix) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(d.bool(forKey: "catpaw.onboarding.keep"), "device-level keys untouched")
    }
}

#if canImport(ActivityKit) && os(iOS)
/// R2 (NoBug P1-2): an ended turn's task title leaves the lock screen after ~2 min, whatever the outcome.
@MainActor final class CatpawLiveActivityLingerTests: XCTestCase {
    func testR2EndedTurnsLingerAtMostTwoMinutes() {
        for kind in [CatpawWorkAttributes.ContentState.Kind.done, CatpawWorkAttributes.ContentState.Kind.failed, "stopped"] {
            XCTAssertLessThanOrEqual(CatpawLiveActivityCoordinator.dismissAfter(kind: kind), 2 * 60, kind)
        }
    }
}
#endif

/// v1.1 voice conversation: the hands-free loop (listening → sending → waiting → speaking → listening, barge-in, card
/// pause, exit) and the speech-text sanitizer. Pure domain code: no audio, no simulator microphone needed.
final class VoiceChatLoopTests: XCTestCase {
    func testSendRefusedGoesStraightBackToListeningAndForgetsTheText() {
        var loop = VoiceChatLoop()
        _ = loop.handle(.start); _ = loop.handle(.transcript("明天提醒我开会")); _ = loop.handle(.silenceElapsed)
        _ = loop.handle(.listeningEnded("明天提醒我开会"))
        XCTAssertEqual(loop.phase, .waiting); XCTAssertEqual(loop.sent, ["明天提醒我开会"])
        let effects = loop.handle(.sendRefused)
        XCTAssertEqual(loop.phase, .listening, "no 120 s wait: listen again")
        XCTAssertEqual(effects, [.haptic(.pause), .startListening, .haptic(.listen)])
        XCTAssertEqual(loop.sent, [], "a refused text was never sent")
        XCTAssertEqual(loop.handle(.sendRefused), [], "only meaningful while waiting")
        XCTAssertEqual(loop.phase, .listening)
    }
    // MARK: state machine
    func testVoiceLoopFullCycleListenSendWaitSpeakListen() {
        var loop = VoiceChatLoop()
        XCTAssertEqual(loop.handle(.start), [.startListening, .haptic(.listen)])
        XCTAssertEqual(loop.phase, .listening)
        XCTAssertEqual(loop.handle(.silenceElapsed), [], "silence before any speech keeps listening")
        XCTAssertEqual(loop.handle(.transcript("明天三点")), [])
        XCTAssertEqual(loop.handle(.transcript("明天三点开评审会")), [])
        XCTAssertEqual(loop.handle(.silenceElapsed), [.stopListening])
        XCTAssertEqual(loop.phase, .sending)
        XCTAssertEqual(loop.handle(.listeningEnded("明天三点开评审会")), [.send("明天三点开评审会"), .haptic(.turnSent)])
        XCTAssertEqual(loop.phase, .waiting)
        XCTAssertEqual(loop.sent, ["明天三点开评审会"])
        XCTAssertEqual(loop.handle(.transcript("late partial")), [], "late recognizer text after the send is ignored")
        XCTAssertEqual(loop.handle(.replyFinished(.init(speech: "好的，已经记下。", speakable: true))), [.haptic(.reply), .speak("好的，已经记下。")])
        XCTAssertEqual(loop.phase, .speaking)
        XCTAssertEqual(loop.handle(.speechFinished), [.startListening, .haptic(.listen)])
        XCTAssertEqual(loop.phase, .listening)
    }
    func testVoiceLoopFinalTextFallsBackToPartialAndEmptyRestartsListening() {
        var loop = VoiceChatLoop(); _ = loop.handle(.start)
        _ = loop.handle(.transcript("hello there")); _ = loop.handle(.silenceElapsed)
        XCTAssertEqual(loop.handle(.listeningEnded("")), [.send("hello there"), .haptic(.turnSent)])
        var quiet = VoiceChatLoop(); _ = quiet.handle(.start)
        XCTAssertEqual(quiet.handle(.listeningEnded("  ")), [.startListening, .haptic(.listen)], "nothing heard: listen again, send nothing")
        XCTAssertTrue(quiet.sent.isEmpty)
    }
    func testVoiceLoopBargeInStopsSpeechAndListens() {
        var loop = Self.speakingLoop()
        XCTAssertEqual(loop.handle(.bargeIn(alreadyListening: true)), [.stopSpeaking, .haptic(.listen)])
        XCTAssertEqual(loop.phase, .listening)
        var tapped = Self.speakingLoop()
        XCTAssertEqual(tapped.handle(.bargeIn(alreadyListening: false)), [.stopSpeaking, .haptic(.listen), .startListening])
        var idle = VoiceChatLoop(); _ = idle.handle(.start)
        XCTAssertEqual(idle.handle(.bargeIn(alreadyListening: true)), [], "barge-in only applies while speaking")
    }
    func testVoiceLoopCardPausesUntilResume() {
        var loop = VoiceChatLoop(); _ = loop.handle(.start); _ = loop.handle(.transcript("加个日程")); _ = loop.handle(.silenceElapsed); _ = loop.handle(.listeningEnded("加个日程"))
        XCTAssertEqual(loop.handle(.approvalRequired), [.haptic(.pause), .announceConfirmation, .releaseAudio])
        XCTAssertEqual(loop.phase, .paused(.needsConfirmation))
        XCTAssertEqual(loop.handle(.replyFinished(.init(speech: "x", speakable: true))), [], "no speaking or listening while paused")
        XCTAssertEqual(loop.handle(.silenceElapsed), [])
        XCTAssertEqual(loop.handle(.resume), [.startListening, .haptic(.listen)])
        var speaking = Self.speakingLoop()
        XCTAssertEqual(speaking.handle(.approvalRequired), [.stopSpeaking, .haptic(.pause), .announceConfirmation, .releaseAudio])
    }
    func testVoiceLoopTextOnlyReplyGoesBackToListening() {
        var loop = VoiceChatLoop(); _ = loop.handle(.start); _ = loop.handle(.listeningEnded("hi"))
        XCTAssertEqual(loop.handle(.replyFinished(.init(speech: "Hello", speakable: false))), [.startListening, .haptic(.listen)])
        var empty = VoiceChatLoop(); _ = empty.handle(.start); _ = empty.handle(.listeningEnded("hi"))
        XCTAssertEqual(empty.handle(.replyFinished(.init(speech: " ", speakable: true))), [.startListening, .haptic(.listen)])
    }
    func testVoiceLoopExitAndBackgroundStopEverythingOnce() {
        var loop = Self.speakingLoop()
        XCTAssertEqual(loop.handle(.exit), [.stopListening, .stopSpeaking, .deactivateAudio])
        XCTAssertEqual(loop.phase, .ended)
        XCTAssertEqual(loop.handle(.start), []); XCTAssertEqual(loop.handle(.exit), [], "ended is terminal")
        var bg = VoiceChatLoop(); _ = bg.handle(.start)
        XCTAssertEqual(bg.handle(.background), [.stopListening, .deactivateAudio])
        XCTAssertFalse(bg.isActive)
    }
    func testVoiceLoopInterruptionAndFailurePause() {
        var loop = Self.speakingLoop()
        XCTAssertEqual(loop.handle(.interruption), [.stopSpeaking, .haptic(.pause), .releaseAudio])
        XCTAssertEqual(loop.phase, .paused(.interrupted))
        XCTAssertEqual(loop.handle(.resume), [.startListening, .haptic(.listen)])
        XCTAssertEqual(loop.handle(.failed), [.stopListening, .haptic(.pause), .releaseAudio])
        XCTAssertEqual(loop.phase, .paused(.failed))
    }
    static func speakingLoop() -> VoiceChatLoop {
        var loop = VoiceChatLoop(); _ = loop.handle(.start); _ = loop.handle(.listeningEnded("hi"))
        _ = loop.handle(.replyFinished(.init(speech: "Hello", speakable: true))); return loop
    }

    // MARK: speech-text sanitizer
    func testSpeechTextSkipsCodeURLsAndMarkdown() {
        let r = VoiceSpeechText.make("## 结果\n**好的**，详情见 https://example.com/a?b=1 。\n- 第一项\n```swift\nlet x = 1\n```\n[文档](https://x.y) 已更新", english: false)
        XCTAssertEqual(r.text, "结果好的，详情见 。第一项文档 已更新")
        XCTAssertTrue(r.hadCode); XCTAssertFalse(r.hadCard)
        XCTAssertFalse(r.text.contains("http")); XCTAssertFalse(r.text.contains("let x"))
    }
    func testSpeechTextCardBecomesOneConfirmLine() {
        let cal = VoiceSpeechText.make("我帮你排好了。\n```json\n{\"type\":\"catpaw.ui.v1\",\"kind\":\"calendar_event\",\"title\":\"评审会\"}\n```", english: false)
        XCTAssertTrue(cal.hadCard)
        XCTAssertEqual(cal.text, "我帮你排好了。我准备了一张日程卡片，请在屏幕上确认。")
        XCTAssertFalse(cal.text.contains("{"))
        let bare = VoiceSpeechText.make("{\"type\":\"reminder\",\"title\":\"x\"}", english: true)
        XCTAssertEqual(bare.text, "I've prepared a reminder card. Please confirm it on screen.")
        let onlyCode = VoiceSpeechText.make("```\nprint(1)\n```", english: true)
        XCTAssertEqual(onlyCode.text, "The code is on screen.")
    }
    func testSpeechTextLongReplyIsCutAtASentence() {
        let long = String(repeating: "这是一句比较长的回答内容。", count: 80)
        let r = VoiceSpeechText.make(long, english: false)
        XCTAssertTrue(r.text.hasSuffix("其余内容请看屏幕。"))
        XCTAssertLessThanOrEqual(r.text.count, VoiceSpeechText.maxCharacters + 12)
        XCTAssertTrue(r.text.dropLast("其余内容请看屏幕。".count).hasSuffix("。"))
    }
    func testSpeechTextEnglishJoinsWithSpaces() {
        XCTAssertEqual(VoiceSpeechText.make("Sure.\n\n1. First step\n2. Second step", english: true).text, "Sure. First step Second step")
    }
    func testVoiceLoopCardReplyIsReadThenPauses() {
        var loop = VoiceChatLoop(); _ = loop.handle(.start); _ = loop.handle(.listeningEnded("加个日程"))
        let line = VoiceSpeechText.cardLine(kind: "calendar", english: false)
        XCTAssertEqual(loop.handle(.replyFinished(.init(speech: line, speakable: true, needsConfirmation: true))), [.haptic(.reply), .speak(line)])
        XCTAssertEqual(loop.handle(.speechFinished), [.haptic(.pause), .releaseAudio], "the card line already asked; no second announcement")
        XCTAssertEqual(loop.phase, .paused(.needsConfirmation))
        var mute = VoiceChatLoop(); _ = mute.handle(.start); _ = mute.handle(.listeningEnded("加个日程"))
        XCTAssertEqual(mute.handle(.replyFinished(.init(speech: line, speakable: false, needsConfirmation: true))), [.haptic(.pause), .announceConfirmation, .releaseAudio])
    }
    func testBargeInEchoFilter() {
        let speaking = "好的，我已经把评审会加到明天下午三点。"
        XCTAssertTrue(VoiceBargeIn.isLikelyEcho(heard: "评审会加到明天", speaking: speaking))
        XCTAssertTrue(VoiceBargeIn.isLikelyEcho(heard: "嗯", speaking: speaking), "one syllable never interrupts")
        XCTAssertFalse(VoiceBargeIn.isLikelyEcho(heard: "等一下 改成四点", speaking: speaking))
        XCTAssertFalse(VoiceBargeIn.isLikelyEcho(heard: "stop please", speaking: "Your meeting is at three."))
        XCTAssertTrue(VoiceBargeIn.isLikelyEcho(heard: "meeting is at", speaking: "Your meeting is at three."))
    }
    func testFillerIsNeverSentButShortYesNoRepliesAre() {
        XCTAssertFalse(VoiceChatLoop.isMeaningful("嗯"))
        XCTAssertFalse(VoiceChatLoop.isMeaningful("啊。"))
        XCTAssertFalse(VoiceChatLoop.isMeaningful("嗯嗯啊。"))
        XCTAssertFalse(VoiceChatLoop.isMeaningful("uh, um..."))
        XCTAssertFalse(VoiceChatLoop.isMeaningful("呃"))
        for reply in ["好", "行", "对", "不", "是", "嗯嗯", "嗯嗯？", "好。", " 不 ", "Yes", "no."] {
            XCTAssertTrue(VoiceChatLoop.isMeaningful(reply), "\(reply) is a yes/no reply and must be sent")
        }
        XCTAssertTrue(VoiceChatLoop.isMeaningful("嗯好的"))
        XCTAssertTrue(VoiceChatLoop.isMeaningful("ok"))
        XCTAssertTrue(VoiceChatLoop.isMeaningful("uh call mom"))
        var loop = VoiceChatLoop(); _ = loop.handle(.start); _ = loop.handle(.transcript("嗯"))
        XCTAssertEqual(loop.handle(.silenceElapsed), [], "filler alone does not end the utterance")
        XCTAssertEqual(loop.handle(.listeningEnded("嗯啊")), [.startListening, .haptic(.listen)], "filler is not sent")
        XCTAssertEqual(loop.sent, [])
        var yes = VoiceChatLoop(); _ = yes.handle(.start); _ = yes.handle(.transcript("好"))
        _ = yes.handle(.silenceElapsed); _ = yes.handle(.listeningEnded("好"))
        XCTAssertEqual(yes.sent, ["好"], "a one-character yes is sent")
    }
}

#if os(iOS)
// MARK: - R2 (NoBug voice-chat review): VoiceChatController with fake audio and a fake conversation host

@MainActor private final class FakeVoiceChatHost: VoiceChatHost {
    var session: ConversationSession? = ConversationSession(scope: Profiles.user, conversationID: UUID())
    var draft = ""
    var conversationID: UUID? = UUID()
    var hasStagedAttachments = false
    var edits: [String] = []
    var isInputComposing = false
    var compositionEnds = 0
    var outgoingMessageIDs: [UUID] = []
    func endInputComposition() { compositionEnds += 1; isInputComposing = false }
    func editDraft(_ text: String) { draft = text; edits.append(text) }
}

@MainActor private final class FakeVoiceChatIO: VoiceChatIO {
    var supported = true
    var starts = 0, stops = 0, cancels = 0, activations = 0, deactivations = 0
    /// Headphones by default (barge-in allowed); true = the built-in speaker.
    var outputIsBuiltInSpeaker = false
    /// Next N recognizer starts are refused (R3 retry).
    var refuseStarts = 0
    var spoken: [String] = []
    var onText: (@MainActor (String) -> Void)?
    var onEnd: (@MainActor (NativeVoiceController.DictationEnd) -> Void)?
    private var finish: (@MainActor () -> Void)?
    func startRecognizer(onText: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (NativeVoiceController.DictationEnd) -> Void) -> Bool {
        starts += 1
        if refuseStarts > 0 { refuseStarts -= 1; return false }
        self.onText = onText; self.onEnd = onEnd; return true
    }
    func stopRecognizer() { stops += 1 }
    func cancelRecognizer() { cancels += 1 }
    func supportsOnDeviceRecognition(_ language: AppLanguage) -> Bool { supported }
    func speak(_ text: String, english: Bool, onFinish: @escaping @MainActor () -> Void) { activations += 1; spoken.append(text); finish = onFinish }
    func stopSpeaking() { finish = nil }
    var isSpeaking: Bool { finish != nil }
    func finishSpeaking() { let f = finish; finish = nil; f?() }
    func activateAudio() { activations += 1 }
    func deactivateAudio() { deactivations += 1 }
    func haptic(_ haptic: VoiceChatHaptic) {}
    func observeSession(onInterruption: @escaping @MainActor () -> Void, onReset: @escaping @MainActor () -> Void) {}
    func stopObserving() {}
}

@MainActor final class VoiceChatControllerTests: XCTestCase {
    private var host: FakeVoiceChatHost!
    private var io: FakeVoiceChatIO!
    private var epoch: AccountEpoch!
    private var controller: VoiceChatController!
    private var sends = 0
    private var turnID = UUID()

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: VoiceChatSpeechPolicy.defaultsKey)
        host = FakeVoiceChatHost(); io = FakeVoiceChatIO(); epoch = AccountEpoch(account: "voice-account-a"); sends = 0; turnID = UUID()
        controller = VoiceChatController(io: io, epoch: epoch, observeAccounts: false)
        controller.pollInterval = 3_600_000_000_000   // the test drives pollReply itself
    }
    private func begin() {
        XCTAssertTrue(controller.begin(host: host, language: .chinese, send: { [unowned self] _ in
            self.sends += 1
            let request = ConversationTurnRequest(scope: Profiles.user, conversationID: self.host.session!.conversationID, threadID: nil, operationID: self.turnID, epoch: 1, history: [])
            self.host.session!.turns.append(ConversationTurnRecord(id: self.turnID, request: request, state: .running, lastSequence: 1, error: nil))
        }))
    }
    /// Says `text`, then 1.2 s of silence and the recognizer's final result.
    private func say(_ text: String) {
        io.onText?(text); controller.run(.silenceElapsed); io.onEnd?(.finished)
    }
    private func updateTurn(_ change: (inout ConversationTurnRecord) -> Void) {
        let i = host.session!.turns.firstIndex { $0.id == turnID }!
        change(&host.session!.turns[i])
    }
    private func call(_ tool: String, confirm: String) -> ConversationDeviceCall {
        ConversationDeviceCall(interruptID: UUID().uuidString.lowercased(), callID: UUID().uuidString, tool: tool, args: Data("{}".utf8), confirm: confirm, ttlSec: 60, argsHash: "h", expiresAt: "2026-10-17T12:00:00Z")
    }
    private func complete(_ text: String) {
        let message = ConversationTranscriptMessage(role: .assistant, content: text)
        host.session!.messages.append(message)
        updateTurn { $0.assistantMessageID = message.id; $0.state = .completed; $0.pendingDeviceCalls = nil }
    }

    // R1: a send the model refuses (pinyin still marked, unresolved turn, …) fails fast with a notice and listens again.
    func testRefusedSendFailsFastWithNoticeAndResumesListening() {
        XCTAssertTrue(controller.begin(host: host, language: .chinese, send: { [unowned self] _ in self.sends += 1 }))   // admits nothing
        let startsBefore = io.starts
        say("帮我订明天的会议室")
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(controller.loop.phase, .listening, "never waits for a reply that can't come")
        XCTAssertEqual(controller.notice, "这句没发出去，请再说一遍。")
        XCTAssertEqual(io.starts, startsBefore + 1, "a fresh recognizer listens again")
        XCTAssertEqual(host.draft, "", "the heard text does not stay in the composer")
        XCTAssertEqual(controller.loop.sent, [])
    }
    func testMarkedPinyinIsCommittedBeforeVoiceChatAndBeforeEachSend() {
        host.isInputComposing = true
        begin()
        XCTAssertEqual(host.compositionEnds, 1, "entering voice chat commits the IME composition")
        host.isInputComposing = true   // the user typed pinyin behind the overlay
        say("今天天气怎么样")
        XCTAssertEqual(host.compositionEnds, 2, "committed again right before the send")
        XCTAssertEqual(controller.loop.phase, .waiting, "admitted, so it waits for the reply")
        XCTAssertNil(controller.notice)
    }
    func testIDAdmissionCountsAsSentWithoutAJournaledTurnYet() {
        XCTAssertTrue(controller.begin(host: host, language: .chinese, send: { [unowned self] _ in self.sends += 1; self.host.outgoingMessageIDs.append(UUID()) }))
        say("讲个笑话")
        XCTAssertEqual(controller.loop.phase, .waiting, "an admitted intent (still saving locally) is a real send")
    }
    // R2: on the built-in speaker the mic hears the reply; only an explicit tap interrupts.
    func testNoAutomaticBargeInOnBuiltInSpeakerButTapStillInterrupts() {
        io.outputIsBuiltInSpeaker = true
        begin(); say("说一首诗")
        complete("床前明月光，疑是地上霜。")
        XCTAssertTrue(controller.pollReply()); XCTAssertEqual(controller.loop.phase, .speaking)
        let startsWhileSpeaking = io.starts
        io.onText?("今天天气很好啊")   // a stale recognizer callback must not interrupt either
        XCTAssertEqual(controller.loop.phase, .speaking, "speaker echo / room noise never barges in")
        XCTAssertEqual(io.starts, startsWhileSpeaking, "no recognizer runs during speech on the speaker")
        controller.orbTapped()
        XCTAssertEqual(controller.loop.phase, .listening, "an explicit tap interrupts")
        XCTAssertEqual(io.starts, startsWhileSpeaking + 1)
    }
    // R3: when the reply ends, a fresh recognizer starts (speaker: none was running during speech).
    func testRecognizerRestartsAfterSpeechFinishesOnSpeaker() {
        io.outputIsBuiltInSpeaker = true
        begin(); say("你好")
        complete("你好，有什么可以帮你？")
        XCTAssertTrue(controller.pollReply())
        let starts = io.starts
        io.finishSpeaking()
        XCTAssertEqual(controller.loop.phase, .listening)
        XCTAssertEqual(io.starts, starts + 1, "listening again right after the reply")
    }
    func testRecognizerRefusedRightAfterSpeechIsRetriedOnce() async {
        VoiceChatController.listenRetryDelay = 20_000_000
        defer { VoiceChatController.listenRetryDelay = 300_000_000 }
        io.outputIsBuiltInSpeaker = true
        begin(); say("你好")
        complete("你好。")
        XCTAssertTrue(controller.pollReply())
        let starts = io.starts
        io.refuseStarts = 1
        io.finishSpeaking()
        XCTAssertEqual(io.starts, starts + 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(io.starts, starts + 2, "one retry")
        XCTAssertEqual(controller.loop.phase, .listening, "the retry succeeded: still listening, no pause")
        XCTAssertNil(controller.notice)
    }
    func testRecognizerRefusedTwiceFailsVisibly() async {
        VoiceChatController.listenRetryDelay = 20_000_000
        defer { VoiceChatController.listenRetryDelay = 300_000_000 }
        io.refuseStarts = 2
        XCTAssertTrue(controller.begin(host: host, language: .chinese, send: { _ in }))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.loop.phase, .paused(.failed))
        XCTAssertEqual(controller.notice, "暂时无法使用语音输入。")
    }
    func testReadOnlyDeviceCallDoesNotPauseAndTheReplyIsSpoken() {
        begin(); say("明天有什么安排")
        XCTAssertEqual(sends, 1); XCTAssertEqual(controller.loop.phase, .waiting)
        updateTurn { $0.pendingDeviceCalls = [self.call("calendar_list", confirm: "none")]; $0.suspendedRequiresApproval = false; $0.suspendedWaitingFor = "device"; $0.lastSequence = 3 }
        XCTAssertFalse(controller.pollReply(), "a read-only device call keeps waiting")
        XCTAssertEqual(controller.loop.phase, .waiting)
        complete("明天下午三点有评审会。")
        XCTAssertTrue(controller.pollReply())
        XCTAssertEqual(controller.loop.phase, .speaking)
        XCTAssertEqual(io.spoken.last, "明天下午三点有评审会。")
        io.finishSpeaking()
        XCTAssertEqual(controller.loop.phase, .listening)
        XCTAssertEqual(io.deactivations, 0)
    }
    func testOldServerReadOnlyCallWithoutRequiresApprovalStillDoesNotPause() {
        begin(); say("附近有什么咖啡店")
        updateTurn { $0.pendingDeviceCalls = [self.call("places_search", confirm: "none")] }   // no requires_approval (old server)
        XCTAssertFalse(controller.pollReply())
        XCTAssertEqual(controller.loop.phase, .waiting)
    }
    func testCardCallPausesAndReleasesAudioAfterTheConfirmationLine() {
        begin(); say("帮我加个明天三点的日程")
        updateTurn { $0.pendingDeviceCalls = [self.call("calendar_create", confirm: "card")] }   // old server: confirm decides
        XCTAssertTrue(controller.pollReply())
        XCTAssertEqual(controller.loop.phase, .paused(.needsConfirmation))
        XCTAssertEqual(io.spoken.last, VoiceSpeechText.confirmationLine(english: false))
        XCTAssertEqual(io.deactivations, 0, "the confirmation line finishes first")
        io.finishSpeaking()
        XCTAssertEqual(io.deactivations, 1, "other apps are not left ducked while the user looks at the card")
        XCTAssertTrue(controller.audioReleased)
    }
    func testRequiresApprovalTrueOverridesConfirmNone() {
        var turn = ConversationTurnRecord(id: UUID(), request: ConversationTurnRequest(scope: Profiles.user, conversationID: UUID(), threadID: nil, operationID: UUID(), epoch: 1, history: []), state: .running, lastSequence: 1, error: nil)
        turn.pendingDeviceCalls = [call("calendar_list", confirm: "none")]
        XCTAssertFalse(turn.needsUserDecision); XCTAssertTrue(turn.awaitingApproval)
        turn.suspendedRequiresApproval = true
        XCTAssertTrue(turn.needsUserDecision, "a mixed round is decided by the server")
        turn.suspendedRequiresApproval = false; turn.pendingDeviceCalls = [call("calendar_create", confirm: "card")]
        XCTAssertFalse(turn.needsUserDecision)
    }
    func testSignOutEndsTheConversationAndNeverRestoresTheDraft() {
        host.draft = "上一个账号的草稿"
        begin(); host.draft = ""
        epoch.signOut()
        controller.exit(.accountChanged)
        XCTAssertEqual(controller.loop.phase, .ended)
        XCTAssertEqual(host.draft, "", "the draft never crosses accounts")
        XCTAssertGreaterThan(io.cancels, 0); XCTAssertGreaterThan(io.deactivations, 0)
    }
    func testRevokedSessionStopsTheMicOnTheNextRecognizedWords() {
        begin()
        epoch.bump()   // remote revoke / epoch change without a notification reaching the controller yet
        io.onText?("还在听吗")
        XCTAssertEqual(controller.loop.phase, .ended)
        XCTAssertGreaterThan(io.cancels, 0)
        XCTAssertEqual(sends, 0)
    }
    func testConversationSwitchEndsAPausedConversation() {
        begin(); say("帮我加个日程")
        updateTurn { $0.pendingDeviceCalls = [self.call("calendar_create", confirm: "card")]; $0.suspendedRequiresApproval = true }
        controller.pollReply(); io.finishSpeaking()
        host.conversationID = UUID()
        controller.orbTapped()   // 继续 after a switch must not resume into another conversation
        XCTAssertEqual(controller.loop.phase, .ended)
        controller.exit(.conversationChanged)
        XCTAssertEqual(controller.loop.phase, .ended)
    }
    func testUserExitRestoresTheTypedDraft() {
        host.draft = "我自己打的字"
        begin(); host.draft = ""
        controller.exit()
        XCTAssertEqual(host.draft, "我自己打的字")
    }
    func testFillerIsNotSent() {
        begin()
        let starts = io.starts
        say("嗯")
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(controller.loop.phase, .listening)
        io.onEnd?(.finished)
        XCTAssertGreaterThan(io.starts, starts, "listens again")
        XCTAssertEqual(sends, 0)
    }
    func testVoiceTurnNeverSendsStagedAttachments() {
        host.hasStagedAttachments = true
        begin(); say("把这张图发给他")
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(controller.loop.phase, .paused(.failed))
        XCTAssertTrue(host.edits.isEmpty)
    }
    func testReplyIsReadOnlyFromTheExactTurn() {
        begin()
        // Another turn's assistant message appears (e.g. an earlier queued turn) before ours is journaled.
        host.session!.messages.append(ConversationTranscriptMessage(role: .assistant, content: "别的回复"))
        say("今天天气怎么样")
        XCTAssertFalse(controller.pollReply())
        XCTAssertEqual(controller.reply, "", "no fallback to another turn's message")
    }
    func testUnsupportedOnDeviceRecognitionDoesNotStart() {
        io.supported = false
        XCTAssertFalse(controller.begin(host: host, language: .chinese, send: { _ in }))
        XCTAssertEqual(controller.notice, "此设备不支持离线语音对话")
        XCTAssertEqual(io.starts, 0)
        XCTAssertEqual(controller.loop.phase, .idle)
    }
    func testSpokenReplyMasksPhonesAndEmails() {
        begin(); say("他的联系方式是什么")
        complete("电话 13800138000，邮箱 bob@example.com。")
        controller.pollReply()
        let spoken = io.spoken.last ?? ""
        XCTAssertFalse(spoken.contains("13800138000")); XCTAssertFalse(spoken.contains("bob@example.com"))
    }
}
#endif

/// Voice audit (A): the mic dictates inline in the composer for tap and hold; only the waveform button goes full screen.
final class ComposerDictationEntryStructureTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Features/" + path), encoding: .utf8)
    }
    func testTapDictationUsesInlineBarAndNeverMountsFullScreenVoiceMode() throws {
        let hold = try source("Composer/ComposerHoldToTalk.swift"), root = try source("ConversationFirstView.swift")
        XCTAssertTrue(hold.contains("        if dictation.dictating {\n            ComposerDictationBar("), "inline bar for every dictation mode")
        XCTAssertFalse(hold.contains("struct VoiceModeHost"), "no full-screen dictation host")
        XCTAssertFalse(root.contains("VoiceModeHost()"), "the chat root mounts no full-screen dictation layer")
        let chat = try source("Composer/ComposerDictation.swift")
        XCTAssertTrue(chat.contains(".fullScreenCover(isPresented: $voiceChatPresented"), "the waveform button keeps the full-screen voice conversation")
    }
}
