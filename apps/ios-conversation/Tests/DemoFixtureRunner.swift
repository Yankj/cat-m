import Foundation
// catpaw.ui.v1 iOS network layer, portable (swiftc -D DEBUG, no SDK UI):
// 1) the recorded real-server SSE (services/edge/docs/fixtures/catpaw-ui-demo.jsonl) decodes into ConversationUIEvent;
// 2) the DEBUG demo backend drives ConversationSessionService through approval + every ui kind with submitUIDecision,
//    journaled by sequence and restored from disk; idempotency and friendly errors.
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL", message); exit(1) }; print("PASS", message) }
/// Demo backend whose streams pause before `turn_suspended` / `turn_completed`, so decisions arrive mid-stream.
actor SlowDemoBackend: ConversationBackend {
    let inner = CatpawDemoConversationBackend()
    private(set) var uiDecisions: [String] = []
    func connection(scope: DataScope) async -> ConversationConnection { await inner.connection(scope: scope) }
    private static func slow(_ source: AsyncThrowingStream<ConversationTurnEvent, Error>) -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in source {
                        switch event.payload { case .suspended, .completed, .uiBlockResolve: try await Task.sleep(nanoseconds: 300_000_000); default: break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { Self.slow(try await inner.reply(request)) }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation { try await inner.observe(request) }
    func submitApproval(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationApprovalDecision, argsHash: String, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        Self.slow(try await inner.submitApproval(request, interruptID: interruptID, decision: decision, argsHash: argsHash, operationID: operationID, afterSequence: afterSequence))
    }
    func submitUIDecision(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        uiDecisions.append(interruptID)
        return Self.slow(try await inner.submitUIDecision(request, interruptID: interruptID, decision: decision, argsHash: argsHash, response: response, operationID: operationID, afterSequence: afterSequence))
    }
}
actor EventLog { var items: [ConversationTurnEvent] = []; func add(_ e: ConversationTurnEvent) { items.append(e) }; func all() -> [ConversationTurnEvent] { items } }
func waitFor(_ condition: () async throws -> Bool) async throws { for _ in 0..<300 { if try await condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) } }

@main struct DemoFixtureRunner {
    static func main() async {
        do { try await run() }
        catch { print("FAIL DemoFixtureRunner: uncaught \(type(of: error)).\(error) — \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        let defaults = UserDefaults(suiteName: "catpaw-demo-fixture-test")!
        defaults.removeObject(forKey: CatpawDemoBackendSwitch.defaultsKey)
        check(!CatpawDemoBackendSwitch.isEnabled(arguments: [], defaults: defaults) && CatpawDemoBackendSwitch.isEnabled(arguments: ["-CatpawDemoBackend"], defaults: defaults), "demo switch: off by default, launch argument turns it on")
        defaults.set(true, forKey: CatpawDemoBackendSwitch.defaultsKey)
        check(CatpawDemoBackendSwitch.isEnabled(arguments: [], defaults: defaults), "demo switch: UserDefaults")
        defaults.removeObject(forKey: CatpawDemoBackendSwitch.defaultsKey)

        // 1) Recorded wire session.
        let fixture = URL(fileURLWithPath: "../../services/edge/docs/fixtures/catpaw-ui-demo.jsonl")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        var decoded: [ConversationUIEvent] = []
        var uiResolvedDecisions: [String] = []
        for line in lines {
            let step = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard step["direction"] as? String == "server" else { continue }
            for wire in step["events"] as! [[String: Any]] {
                let type = wire["type"] as! String, sequence = wire["sequence"] as! Int
                if type.hasPrefix("ui.") {
                    let data = try JSONSerialization.data(withJSONObject: wire["data"]!, options: [.sortedKeys])
                    decoded.append(try ConversationUIEvent.decode(type: type, sequence: sequence, payload: data))
                }
                if type == "approval_resolved", let data = wire["data"] as? [String: Any], data["kind"] as? String == "ui" { uiResolvedDecisions.append(data["decision"] as! String) }
            }
        }
        check(Set(decoded.filter { $0.type == .block }.compactMap(\.kind)) == ConversationUIEvent.kinds, "recording: every kind decodes")
        check(decoded.filter(\.waitsForDecision).count == 4 && decoded.filter(\.waitsForDecision).allSatisfy { $0.argsHash?.count == 64 && $0.expiresAt != nil }, "recording: 4 waiting blocks carry interruptId/argsHash/expiresAt")
        check(decoded.contains { $0.type == .update && $0.id == "demo-progress" } && decoded.filter { $0.type == .resolve }.compactMap(\.status) == ["submitted", "submitted", "submitted", "dismissed"], "recording: update + resolve statuses")
        check(uiResolvedDecisions == ["submitted", "submitted", "submitted", "dismissed"], "recording: approval_resolved kind ui decisions")
        check(decoded.map(\.sequence) == decoded.map(\.sequence).sorted(), "recording: ui events are in sequence order")
        let first = decoded[0], raw = try JSONSerialization.jsonObject(with: first.payload) as! [String: Any]
        check(raw["title"] as? String == "今天" && raw["body"] != nil, "payload is passed through as Data")
        var rejected = 0
        for (type, json) in [("ui.block", #"{"id":"x","kind":"popup"}"#), ("ui.block.update", #"{"id":"x","kind":"card"}"#), ("ui.block.resolve", #"{"id":"x","status":"done"}"#), ("ui.block", #"{"id":"x","kind":"choices","interruptId":"nope","argsHash":"a"}"#)] {
            do { _ = try ConversationUIEvent.decode(type: type, sequence: 1, payload: Data(json.utf8)) } catch { rejected += 1 }
        }
        check(rejected == 4, "malformed ui events are rejected")

        // 2) Service path with the demo backend.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catpaw-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appendingPathComponent("journal.json")
        let backend = CatpawDemoConversationBackend()
        let service = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: store)), backend: backend)
        let conversation = try await service.create(scope: Profiles.user)
        let operation = UUID()
        _ = try await service.send(scope: Profiles.user, conversationID: conversation, text: "帮我建个跑步任务，再弹个窗", operationID: operation)
        let approvals = try await service.pendingApprovals(scope: Profiles.user, conversationID: conversation)
        check(approvals.first?.tool == "create_task", "approval_requested → turn_suspended")
        try await service.submitApproval(scope: Profiles.user, conversationID: conversation, interruptID: approvals[0].interruptID, decision: .approve)
        var pending = try await service.pendingUIBlocks(scope: Profiles.user, conversationID: conversation)
        check(pending.map(\.id) == ["demo-choices"], "approve resumes: create_task result, round 1 ui blocks, suspended on choices")

        var stale = false
        do { try await service.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: operation, interruptID: pending[0].interruptID!, decision: .submit, argsHash: String(repeating: "f", count: 64), response: Data("{}".utf8)) }
        catch let failure as ConversationApprovalFailure { stale = failure == .stale && !failure.friendlyMessage.isEmpty }
        check(stale, "wrong argsHash → .stale with a friendly message")
        var invalid = ""
        do { try await service.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: operation, interruptID: pending[0].interruptID!, decision: .submit, argsHash: pending[0].argsHash!, response: Data(#"{"type":"ui.response","blockId":"other"}"#.utf8)) }
        catch let failure as ConversationApprovalFailure { invalid = failure.friendlyMessage }
        check(invalid == "填写的内容不符合要求，请检查后再提交。", "invalid ui.response → 422 ui_response_invalid, friendly message")

        let choicesOperation = UUID()
        let choices = Data(#"{"type":"ui.response","blockId":"demo-choices","actionId":null,"values":{},"selected":["a"],"respondedAt":"2026-10-16T00:10:00Z"}"#.utf8)
        try await service.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: operation, interruptID: pending[0].interruptID!, decision: .submit, argsHash: pending[0].argsHash!, response: choices, operationID: choicesOperation)
        pending = try await service.pendingUIBlocks(scope: Profiles.user, conversationID: conversation)
        check(Set(pending.map(\.id)) == ["demo-form", "demo-confirm", "demo-sheet"], "choices answered: resolve + round 2 suspended on form/confirm/sheet")
        var consumed = false
        do { _ = try await backend.submitUIDecision(try await service.read(scope: Profiles.user, conversationID: conversation).turns.last!.request, interruptID: CatpawDemoUIScript.interruptID("demo-choices"), decision: .dismiss, argsHash: String(repeating: "0", count: 64), response: nil, operationID: UUID(), afterSequence: 0) }
        catch ConversationApprovalFailure.consumed { consumed = true }
        check(consumed, "answering an answered block with another operation → .consumed")

        // Restore from disk mid-suspend: the journal has the ui events by sequence and the same pending blocks.
        let cold = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: store)), backend: backend)
        let restored = try await cold.read(scope: Profiles.user, conversationID: conversation).turns.last!
        let journal = restored.uiEvents ?? []
        check(journal.map(\.sequence) == journal.map(\.sequence).sorted() && Set(journal.map(\.sequence)).count == journal.count && restored.awaitingApproval && Set(restored.pendingUIBlocks.map(\.id)) == ["demo-form", "demo-confirm", "demo-sheet"], "journal survives reopen, ordered and unique by sequence")

        // pending_approvals snapshot: kind "ui" rows split out (server shape from approval.mjs pendingApprovals).
        let uiInterrupt = UUID().uuidString.lowercased(), hash = String(repeating: "b", count: 64)
        let snapshot: [[String: Any]] = [
            ["interrupt_id": UUID().uuidString.lowercased(), "call_id": "call-task", "tool": "create_task", "summary": "创建任务", "args_hash": String(repeating: "c", count: 64), "expires_at": "2026-10-16T00:20:00.000Z", "risk": "local_write", "remember_allowed": true, "arguments": ["title": "x"]],
            ["interrupt_id": uiInterrupt, "call_id": "call-ui", "tool": "render_ui", "summary": "表单", "args_hash": hash, "expires_at": "2026-10-16T00:20:00.000Z", "risk": "none", "remember_allowed": false, "kind": "ui",
             "block": ["schemaVersion": 1, "id": "f1", "kind": "form", "title": "登记", "fields": [["id": "name", "label": "名字", "type": "text"]], "interruptId": uiInterrupt, "argsHash": hash, "expiresAt": "2026-10-16T00:20:00.000Z"],
             "arguments": ["block": ["id": "f1"]]],
        ]
        let split = try NativeChatHTTPBackend.splitPendingApprovals(snapshot)
        check(split.tools.map(\.tool) == ["create_task"] && split.ui.map(\.blockID) == ["f1"] && split.ui[0].kind == "form" && split.ui[0].argsHash == hash, "snapshot: kind ui rows become ConversationUIApproval, tool rows stay approval cards")
        var mismatch = false
        var bad = snapshot[1]; bad["args_hash"] = String(repeating: "d", count: 64)
        do { _ = try ConversationUIApproval.decode(bad) } catch { mismatch = true }
        check(mismatch, "snapshot ui row whose block disagrees with the interrupt is rejected")
        let restoredUI = try await cold.pendingUIApprovals(scope: Profiles.user, conversationID: conversation)
        check(Set(restoredUI.map(\.blockID)) == ["demo-form", "demo-confirm", "demo-sheet"] && restoredUI.allSatisfy { $0.argsHash.count == 64 && !$0.block.isEmpty }, "pendingUIApprovals(scope:conversationID:) restores waiting blocks after reopen")
        let adapter = ConversationUIDecisionSubmitter(service: cold, scope: Profiles.user)
        var adapterError = ""
        do { try await adapter.closure(conversation, operation, restoredUI[0].interruptID, "approve", restoredUI[0].argsHash, nil, UUID()) }
        catch let failure as ConversationApprovalFailure { adapterError = failure.friendlyMessage }
        check(!adapterError.isEmpty, "adapter closure rejects an unknown decision string with a friendly error")

        let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        try await adapter.submitUIDecision(conversationID: conversation, turnID: operation, interruptID: byID["demo-confirm"]!.interruptID!, decision: .submit, argsHash: byID["demo-confirm"]!.argsHash!, response: Data(#"{"type":"ui.response","blockId":"demo-confirm","actionId":"approve","values":{},"selected":[],"respondedAt":"2026-10-16T00:10:00Z"}"#.utf8), operationID: UUID())
        try await cold.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: operation, interruptID: byID["demo-form"]!.interruptID!, decision: .submit, argsHash: byID["demo-form"]!.argsHash!, response: Data(#"{"type":"ui.response","blockId":"demo-form","actionId":null,"values":{"km":5,"at":"18:30"},"selected":[],"respondedAt":"2026-10-16T00:10:00Z"}"#.utf8))
        try await cold.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: operation, interruptID: byID["demo-sheet"]!.interruptID!, decision: .dismiss, argsHash: byID["demo-sheet"]!.argsHash!, response: nil)
        let done = try await cold.read(scope: Profiles.user, conversationID: conversation).turns.last!
        let finalJournal = done.uiEvents ?? []
        check(done.state == .completed && done.pendingUIBlocks.isEmpty, "partial answers in any order; last one completes the turn")
        check(Set(finalJournal.filter { $0.type == .block }.compactMap(\.kind)) == ConversationUIEvent.kinds && finalJournal.filter { $0.type == .resolve }.count == 4 && finalJournal.contains { $0.type == .update }, "journal holds every kind, the update and 4 resolves")

        // 3) Queued decisions while a stream is running.
        let slow = SlowDemoBackend()
        let queued = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("queue.json"))), backend: slow)
        let qConversation = try await queued.create(scope: Profiles.user), qOperation = UUID()
        let log = EventLog(), stream = await queued.turnEvents()
        let collector = Task { for await event in stream { await log.add(event) } }
        _ = try await queued.send(scope: Profiles.user, conversationID: qConversation, text: "排队测试", operationID: qOperation)
        let qApproval = try await queued.pendingApprovals(scope: Profiles.user, conversationID: qConversation)[0]
        let approving = Task { try await queued.submitApproval(scope: Profiles.user, conversationID: qConversation, interruptID: qApproval.interruptID, decision: .approve) }
        let choicesID = CatpawDemoUIScript.interruptID("demo-choices"), zero = String(repeating: "0", count: 64)
        try await waitFor { try await queued.read(scope: Profiles.user, conversationID: qConversation).turns.last?.uiEvents?.contains { $0.interruptID == choicesID } == true }
        // Stream is still running (paused before turn_suspended): the answer queues instead of throwing busy.
        let early = Task { try await queued.submitUIDecision(scope: Profiles.user, conversationID: qConversation, turnID: qOperation, interruptID: choicesID, decision: .submit, argsHash: zero, response: choices, operationID: choicesOperation) }
        let joined = Task { try await queued.submitUIDecision(scope: Profiles.user, conversationID: qConversation, turnID: qOperation, interruptID: choicesID, decision: .submit, argsHash: zero, response: choices, operationID: choicesOperation) }
        try await waitFor { await queued.queuedUIDecisions(conversationID: qConversation) == [choicesID] }
        var conflict = ""
        do { try await queued.submitUIDecision(scope: Profiles.user, conversationID: qConversation, turnID: qOperation, interruptID: choicesID, decision: .dismiss, argsHash: zero, response: nil) }
        catch ConversationApprovalFailure.rejected(_, let code) { conflict = code ?? "" }
        check(conflict == "approval_operation_conflict", "a different answer for a queued interrupt is a conflict")
        _ = try await approving.value
        let earlyOperation = try await early.value, joinedOperation = try await joined.value
        let sentChoices = await slow.uiDecisions.filter { $0 == choicesID }.count
        check(earlyOperation == qOperation && joinedOperation == qOperation && sentChoices == 1, "queued answer is sent once after turn_suspended; identical duplicate joins it")

        // Round 2 is streaming (paused before turn_suspended) right after choices: answer form/confirm/sheet in any order, cancel one.
        let qPending: [ConversationUIEvent] = try await queued.read(scope: Profiles.user, conversationID: qConversation).turns.last?.pendingUIBlocks ?? []
        check(Set(qPending.map(\.id)) == ["demo-form", "demo-confirm", "demo-sheet"], "round 2 pending after queued choices")
        let sheetID = CatpawDemoUIScript.interruptID("demo-sheet"), confirmID = CatpawDemoUIScript.interruptID("demo-confirm"), formID = CatpawDemoUIScript.interruptID("demo-form")
        let blocker = Task { try await queued.submitUIDecision(scope: Profiles.user, conversationID: qConversation, turnID: qOperation, interruptID: sheetID, decision: .dismiss, argsHash: zero, response: nil) }
        try await waitFor { await slow.uiDecisions.contains(sheetID) }
        let cancelled = Task { try await queued.submitUIDecision(scope: Profiles.user, conversationID: qConversation, turnID: qOperation, interruptID: formID, decision: .submit, argsHash: zero, response: Data(#"{"type":"ui.response","blockId":"demo-form","values":{"km":3},"respondedAt":"2026-10-16T00:10:00Z"}"#.utf8)) }
        let confirmTask = Task { try await queued.submitUIDecision(scope: Profiles.user, conversationID: qConversation, turnID: qOperation, interruptID: confirmID, decision: .submit, argsHash: zero, response: Data(#"{"type":"ui.response","blockId":"demo-confirm","actionId":"deny","respondedAt":"2026-10-16T00:10:00Z"}"#.utf8)) }
        try await waitFor { await queued.queuedUIDecisions(conversationID: qConversation).count == 2 }
        cancelled.cancel()
        var cancelError = false
        do { _ = try await cancelled.value } catch is CancellationError { cancelError = true }
        _ = try await blocker.value; _ = try await confirmTask.value
        let sentForm = await slow.uiDecisions.contains(formID)
        check(cancelError && !sentForm, "a queued decision can be cancelled before it is sent")
        let stillPending = try await queued.read(scope: Profiles.user, conversationID: qConversation).turns.last?.pendingUIBlocks.map(\.id) ?? []
        check(stillPending == ["demo-form"], "sheet then confirm answered out of order; form still waiting")

        // Past expiresAt (the queue checks at send time).
        await queued.setUIClock { Date(timeIntervalSince1970: 4_000_000_000) }
        var expiredLate = false
        do { try await queued.submitUIDecision(scope: Profiles.user, conversationID: qConversation, turnID: qOperation, interruptID: formID, decision: .dismiss, argsHash: zero, response: nil) }
        catch ConversationApprovalFailure.expired { expiredLate = true }
        let formSent = await slow.uiDecisions.contains(formID), formUnsent = !formSent
        check(expiredLate && formUnsent, "a decision past its block's expiresAt fails with .expired and is not sent")
        await queued.setUIClock { Date() }

        let events = await log.all()
        collector.cancel()
        check(!events.isEmpty && events.allSatisfy { $0.conversationID == qConversation && $0.turnID == qOperation }, "every emitted event carries conversationID and turnID")
        let legacy = ConversationTurnEvent(operationID: UUID(), epoch: 1, sequence: 1, payload: .thread("t"))
        check(legacy.conversationID == nil && legacy.turnID == nil && legacy.stamped(conversationID: qConversation, turnID: qOperation).turnID == qOperation, "old initializer still compiles; stamped fills ids")

        try? FileManager.default.removeItem(at: directory)
        print("PASS catpaw.ui.v1 network layer: recorded SSE decode + demo backend service path")
    }
}
