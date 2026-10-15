import Foundation
// DEBUG demo backend: approval + create_task script and the catpaw.ui.v1 script (every kind, update, resolve, idempotent decisions).
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL", message); exit(1) } }
func collect(_ stream: AsyncThrowingStream<ConversationTurnEvent, Error>) async throws -> [ConversationTurnEvent] { var out: [ConversationTurnEvent] = []; for try await event in stream { out.append(event) }; return out }
@main struct DemoFixtureRunner {
    static func main() async throws {
        let defaults = UserDefaults(suiteName: "catpaw-demo-fixture-test")!
        defaults.removeObject(forKey: CatpawDemoBackendSwitch.defaultsKey)
        check(!CatpawDemoBackendSwitch.isEnabled(arguments: [], defaults: defaults), "off by default")
        check(CatpawDemoBackendSwitch.isEnabled(arguments: ["-CatpawDemoBackend"], defaults: defaults), "launch argument")
        defaults.set(true, forKey: CatpawDemoBackendSwitch.defaultsKey)
        check(CatpawDemoBackendSwitch.isEnabled(arguments: [], defaults: defaults), "UserDefaults")
        defaults.removeObject(forKey: CatpawDemoBackendSwitch.defaultsKey)

        let backend = CatpawDemoConversationBackend()
        let scope = DataScope(profileID: UUID(), workspaceID: UUID())
        let request = ConversationTurnRequest(scope: scope, conversationID: UUID(), threadID: nil, operationID: UUID(), epoch: 1, history: [.init(id: UUID(), role: .user, content: "帮我建个跑步任务，再弹个窗")])
        let first = try await collect(backend.reply(request))
        var approval: ConversationApprovalRequest?
        for event in first { if case .approvalRequested(let value) = event.payload { approval = value } }
        guard let approval else { check(false, "approval_requested"); return }
        check(approval.tool == "create_task" && approval.rememberAllowed, "create_task approval")
        if case .suspended(let ids, _) = first.last?.payload { check(ids == [approval.interruptID], "turn_suspended ids") } else { check(false, "ends suspended") }
        check(first.map(\.sequence) == Array(1...first.count), "continuous sequence")
        let operation = UUID()
        let resumed = try await collect(backend.submitApproval(request, interruptID: approval.interruptID, decision: .approve, argsHash: approval.argsHash, operationID: operation, afterSequence: first.count))
        if case .approvalResolved(_, _, let decision, _) = resumed.first?.payload { check(decision == "approved", "approval_resolved approved") } else { check(false, "approval_resolved first") }
        var toolStatus: String?
        for event in resumed { if case .toolResult(let result) = event.payload { toolStatus = result.status } }
        check(toolStatus == "ok", "create_task tool_result ok")
        if case .completed = resumed.last?.payload {} else { check(false, "turn_completed") }
        let replay = try await collect(backend.submitApproval(request, interruptID: approval.interruptID, decision: .approve, argsHash: approval.argsHash, operationID: operation, afterSequence: first.count))
        check(replay.count == resumed.count, "decision replay is idempotent")
        var conflict = false
        do { _ = try await backend.submitApproval(request, interruptID: approval.interruptID, decision: .deny, argsHash: approval.argsHash, operationID: UUID(), afterSequence: 0) } catch ConversationApprovalFailure.consumed { conflict = true }
        check(conflict, "second decision is consumed")

        let script = CatpawDemoUIScript()
        var events = await script.start()
        check(events.filter { $0.type == "ui.block" }.count == 4 && events.last?.type == "turn_suspended", "round 1")
        var invalid = false
        do { _ = try await script.respond(blockID: "demo-choices", decision: .submit, responseJSON: "{}", operationID: UUID()) } catch CatpawDemoUIFailure.invalidResponse { invalid = true }
        check(invalid, "bad ui.response rejected")
        let choices = UUID(), answer = #"{"type":"ui.response","blockId":"demo-choices","actionId":null,"values":{},"selected":["a"],"respondedAt":"2026-10-16T00:10:00Z"}"#
        events += try await script.respond(blockID: "demo-choices", decision: .submit, responseJSON: answer, operationID: choices)
        let again = try await script.respond(blockID: "demo-choices", decision: .submit, responseJSON: answer, operationID: choices)
        check(again.first?.type == "approval_resolved", "ui decision replay")
        events += try await script.respond(blockID: "demo-form", decision: .submit, responseJSON: #"{"type":"ui.response","blockId":"demo-form","actionId":null,"values":{"km":5,"at":"18:30"},"selected":[],"respondedAt":"2026-10-16T00:10:00Z"}"#, operationID: UUID())
        events += try await script.respond(blockID: "demo-confirm", decision: .submit, responseJSON: #"{"type":"ui.response","blockId":"demo-confirm","actionId":"approve","values":{},"selected":[],"respondedAt":"2026-10-16T00:10:00Z"}"#, operationID: UUID())
        events += try await script.respond(blockID: "demo-sheet", decision: .dismiss, responseJSON: nil, operationID: UUID())
        var kinds = Set<String>()
        for event in events where event.type == "ui.block" {
            let object = try JSONSerialization.jsonObject(with: Data(event.json.utf8)) as! [String: Any]
            kinds.insert(object["kind"] as! String)
        }
        check(kinds == ["card", "list", "progress", "choices", "form", "confirm", "sheet"], "every kind")
        check(events.contains { $0.type == "ui.block.update" } && events.filter { $0.type == "ui.block.resolve" }.count == 4, "update + 4 resolves")
        check(events.last?.type == "turn_completed", "ui script completes")
        check(events.map(\.sequence) == Array(1...events.count), "ui sequence continuous")
        print("PASS demo fixture: approval/create_task resume + catpaw.ui.v1 every kind, update, resolve, idempotent decisions")
    }
}
