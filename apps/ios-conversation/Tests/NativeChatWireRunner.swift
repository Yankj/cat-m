import Foundation
struct WireTestSession: NativeChatSessionCredentials { func authorization(scope: DataScope) async throws -> String { "Bearer explicit-wire-test-only" } }
@main struct NativeChatWireRunner {
    static func main() async throws {
        let origin = URL(string: CommandLine.arguments[1])!, root = URL(fileURLWithPath: CommandLine.arguments[2])
        func backend(_ allow: Bool = true) throws -> NativeChatHTTPBackend { NativeChatHTTPBackend(configuration: try NativeChatConfiguration(origin: origin, localScope: Profiles.user, serverScopeID: Profiles.user.workspaceID, allowInjectedTestProvider: allow), credentials: WireTestSession()) }
        func check(_ condition: Bool, _ text: String) throws { guard condition else { throw CatpawError.invalid(text) }; print("PASS: " + text) }
        let headerConfiguration=try NativeChatConfiguration(origin:origin,localScope:Profiles.user,serverScopeID:Profiles.user.workspaceID)
        for (label,value) in [("CR","Bearer synthetic\rinjected"),("LF","Bearer synthetic\ninjected"),("CRLF","Bearer synthetic\r\ninjected"),("byte budget","Bearer "+String(repeating:"a",count:8185))] {
            var rejected=false
            do {_=try headerConfiguration.makeRequest(route:"/readyz",authorization:value)}catch ConversationSessionError.notConfigured {rejected=true}
            try check(rejected,"public request constructor rejects authorization "+label+" before creating a request")
        }
        let repo = try Repository(persistence: FilePersistence(url: root.appendingPathComponent("wire-chat.json")))
        let userSession = try SupabaseUserAccessSession(projectURL: URL(string: "https://abcdefghijklmnopqrst.supabase.co")!, localScope: Profiles.user)
        let expired = Date(timeIntervalSince1970: 1)
        var unavailable = false
        do { _ = try await userSession.authorization(scope: Profiles.user) } catch ConversationSessionError.notConfigured { unavailable = true }
        try check(unavailable, "no user JWT means no identity/default authorization")
        try await userSession.updateFromAuth(accessToken: "testheader.testpayload.testsignature", expiresAt: Date().addingTimeInterval(3600))
        let explicitAuthorization = try await userSession.authorization(scope: Profiles.user)
        try check(explicitAuthorization == "Bearer testheader.testpayload.testsignature", "transport receives only explicitly supplied user access JWT, never metadata-derived identity")
        var wrongScope = false
        do { _ = try await userSession.authorization(scope: Profiles.demo) } catch CatpawError.scopeMismatch { wrongScope = true }
        try check(wrongScope, "session transport refuses another local scope")
        try await userSession.updateFromAuth(accessToken: "testheader.testpayload.testsignature", expiresAt: expired)
        unavailable = false
        do { _ = try await userSession.authorization(scope: Profiles.user) } catch ConversationSessionError.notConfigured { unavailable = true }
        try check(unavailable, "expired user session cannot dispatch")
        try await userSession.updateFromAuth(accessToken: "testheader.testpayload.testsignature", expiresAt: Date().addingTimeInterval(3600))
        await userSession.clear()
        unavailable = false
        do { _ = try await userSession.authorization(scope: Profiles.user) } catch ConversationSessionError.notConfigured { unavailable = true }
        try check(unavailable, "logout clears credential without granting or canceling a business task")
        let empty = try NativeChatComposition.make(publicConfiguration: [:], localScope: Profiles.user)
        let emptyState = await empty.backend.connection(scope: Profiles.user)
        try check(empty.loginSession == nil && emptyState.state == .notConfigured, "missing approved deployment stays unconfigured in application composition")
        let configured = try NativeChatComposition.make(publicConfiguration: ["CatpawBackendOrigin": origin.absoluteString, "CatpawSupabaseProjectURL": "https://abcdefghijklmnopqrst.supabase.co", "CatpawServerScopeID": Profiles.user.workspaceID.uuidString], localScope: Profiles.user)
        let missingSession = await configured.backend.connection(scope: Profiles.user)
        try check(configured.loginSession != nil && missingSession.state == .notConfigured, "public configuration alone cannot manufacture a user login")
        var readiness = URLRequest(url: origin.appendingPathComponent("wire-test-ready")); readiness.httpMethod = "POST"; readiness.setValue("Bearer explicit-wire-test-only", forHTTPHeaderField: "Authorization"); readiness.httpBody = Data("{\"ready\":false}".utf8)
        _ = try await URLSession.shared.data(for: readiness)
        let gated = try backend()
        let gateState = await gated.connection(scope: Profiles.user)
        try check(gateState.state == .unavailable, "v3 readiness=false cannot claim ready or admit a model turn")
        readiness.httpBody = Data("{\"ready\":true}".utf8); _ = try await URLSession.shared.data(for: readiness)
        let service = ConversationSessionService(repository: repo, backend: try backend())
        let id = try await service.openLatest(scope: Profiles.user)
        _ = try await service.send(scope: Profiles.user, conversationID: id, text: "wire-only question", operationID: UUID(), context: [ConversationExplicitContext(id: "explicit-context", text: "fictional wire fixture")])
        _ = try await service.send(scope: Profiles.user, conversationID: id, text: "wire-question-2", operationID: UUID())
        var state = try await service.read(scope: Profiles.user, conversationID: id)
        try check(state.turns.count == 2 && state.turns.allSatisfy { $0.state == .completed } && state.messages.count == 4 && state.goals.isEmpty, "HTTP/SSE second turn checks authoritative scoped history; ordinary Q&A creates no goals")
        let taskConvo = try await service.create(scope: Profiles.user)
        _ = try await service.send(scope: Profiles.user, conversationID: taskConvo, text: "wire-task", operationID: UUID())
        state = try await service.read(scope: Profiles.user, conversationID: taskConvo)
        try check(state.goals.count == 1 && state.goals.values.first?.state == .completed && state.goals.values.first?.artifacts.first?.content == "Original immutable wire content" && state.goals.values.first?.binding?.conversation_id == taskConvo, "delegate_task binding reads original run and verifies immutable artifact version/hash before a completed card")
        let recovered = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("wire-chat.json"))), backend: try backend())
        try await recovered.observe(scope: Profiles.user, conversationID: taskConvo)
        state = try await recovered.read(scope: Profiles.user, conversationID: taskConvo)
        try check(state.goals.values.first?.artifactHistory.count == 1, "restart reads same task/turn/artifact and retains immutable artifact history")
        for toolName in ["delegate_plan_v1", "delegate_sources_v1"] {
            for (label, text, persisted) in [("empty", "", false), ("bom", " \t\n\u{00A0}\u{FEFF}", false), ("nel", "\u{0085}", true), ("prose", " 已受理 ", true)] {
                FileHandle.standardError.write(Data("WIRE CASE explicit loopback only: \(toolName) / \(label)\n".utf8))
                let matrixStore = root.appendingPathComponent("wire-\(toolName)-\(label).json")
                let matrix = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: matrixStore)), backend: try backend())
                let conversation = try await matrix.create(scope: Profiles.user), operation = UUID()
                let prompt = "wire-delegation-\(toolName)-\(label)" + (toolName == "delegate_sources_v1" ? " https://docs.example.org/docs/one" : "")
                _ = try await matrix.send(scope: Profiles.user, conversationID: conversation, text: prompt, operationID: operation)
                let received = try await matrix.read(scope: Profiles.user, conversationID: conversation)
                guard let goal = received.goals.values.first, let binding = goal.binding else { throw CatpawError.invalid("Expected original \(toolName) binding") }
                let prose = received.messages.filter { $0.role == .assistant && $0.toolName == nil }.map(\.content)
                try check(received.turns.count == 1 && received.turns.last?.state == .completed && received.turns.last?.id == operation && goal.state == .queued && goal.title == "Wire-only \(toolName) \(label)" && prose == (persisted ? [text] : []), "\(toolName) \(label) HTTP/SSE preserves exact transcript and separates completed chat from queued task")
                let restarted = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: matrixStore)), backend: try backend())
                try await restarted.observe(scope: Profiles.user, conversationID: conversation)
                let original = try await restarted.read(scope: Profiles.user, conversationID: conversation)
                try check(original.turns.last?.id == operation && original.goals[goal.id]?.binding == binding && original.messages.filter { $0.role == .assistant && $0.toolName == nil }.map(\.content) == prose, "\(toolName) \(label) restart GET validates the original task/turn/run and terminal hash")
                let followup = UUID()
                _ = try await restarted.send(scope: Profiles.user, conversationID: conversation, text: "wire-followup-\(toolName)-\(label)", operationID: followup)
                let continued = try await restarted.read(scope: Profiles.user, conversationID: conversation)
                try check(continued.turns.count == 2 && continued.turns.allSatisfy { $0.state == .completed } && continued.goals.count == 1 && continued.goals[goal.id]?.binding == binding, "\(toolName) \(label) new follow-up matches server history without another delegation")
                let historical = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: matrixStore)), backend: try backend())
                try await historical.observe(scope: Profiles.user, conversationID: conversation)
                let readback = try await historical.read(scope: Profiles.user, conversationID: conversation)
                try check(readback.turns.last?.id == followup && readback.goals.count == 1 && readback.goals[goal.id]?.binding == binding && readback.goals[goal.id]?.title == goal.title && readback.goals[goal.id]?.state == .queued, "\(toolName) \(label) cold latest-turn recovery rechecks historical binding and restores its title")
            }
        }
        let pendingID = try await service.create(scope: Profiles.user), original = UUID()
        do { _ = try await service.send(scope: Profiles.user, conversationID: pendingID, text: "wire-interrupt", operationID: original) } catch { }
        state = try await service.read(scope: Profiles.user, conversationID: pendingID)
        try check(state.turns.last?.state == .unknown, "SSE EOF without terminal is unknown, never success")
        try await service.observe(scope: Profiles.user, conversationID: pendingID)
        state = try await service.read(scope: Profiles.user, conversationID: pendingID)
        try check(state.turns.count == 1 && state.turns.last?.id == original && state.turns.last?.state == .completed, "unknown request resolves by GET of original turn without redispatch")
        for mode in ["wire-bad-scope", "wire-bad-artifact"] {
            let c = try await service.create(scope: Profiles.user)
            do { _ = try await service.send(scope: Profiles.user, conversationID: c, text: mode, operationID: UUID()) } catch { }
            state = try await service.read(scope: Profiles.user, conversationID: c)
            try check(state.turns.last?.state == .unknown && state.goals.isEmpty, "reject \(mode) without forged success or goal")
        }
        let mismatchID = try await service.create(scope: Profiles.user)
        do { _ = try await service.send(scope: Profiles.user, conversationID: mismatchID, text: "wire-bad-terminal", operationID: UUID()) } catch { }
        state = try await service.read(scope: Profiles.user, conversationID: mismatchID)
        try check(state.turns.last?.state == .unknown && state.goals.count == 1, "mismatched terminal task binding cannot complete chat; previously verified original goal remains")
        let unconfiguredBackend = try backend(), unconfigured = ConversationSessionService(repository: repo, backend: unconfiguredBackend), c = try await unconfigured.create(scope: Profiles.user)
        do { _ = try await unconfigured.send(scope: Profiles.user, conversationID: c, text: "wire-unconfigured", operationID: UUID()) } catch { }
        state = try await unconfigured.read(scope: Profiles.user, conversationID: c)
        let status = await unconfigured.connection(scope: Profiles.user)
        let diagnostic = "DIAGNOSTIC explicit loopback only: connection=\(status.state.rawValue), turn=\(state.turns.last?.state.rawValue ?? "none"), error=\(state.turns.last?.error ?? "none"), assistant_count=\(state.messages.filter { $0.role == .assistant }.count), goal_count=\(state.goals.count)\n"
        FileHandle.standardError.write(Data(diagnostic.utf8))
        try check(status.state != .connected && state.turns.last?.state == .failed && state.turns.last?.error == "not_configured" && state.messages.filter { $0.role == .assistant }.isEmpty && state.goals.isEmpty, "original not_configured failure is preserved with no fake assistant/goal or verified connection")
        let strict = ConversationSessionService(repository: repo, backend: try backend(false)), strictID = try await strict.create(scope: Profiles.user)
        do { _ = try await strict.send(scope: Profiles.user, conversationID: strictID, text: "wire-only question", operationID: UUID()) } catch { }
        state = try await strict.read(scope: Profiles.user, conversationID: strictID)
        try check(state.turns.last?.state == .unknown && state.messages.count == 1, "production adapter rejects injected_test_provider provenance")
        for (mode, expected) in [("wire-scheduled", ConversationGoalProjection.State.queued), ("wire-outcome-unknown", .unknown), ("wire-future-state", .unknown), ("wire-revoked-scheduled", .unknown)] {
            let cid = try await service.create(scope: Profiles.user), tid = UUID()
            _ = try await service.send(scope: Profiles.user, conversationID: cid, text: mode, operationID: tid)
            let saved = try await service.read(scope: Profiles.user, conversationID: cid)
            guard let goal = saved.goals.values.first, let binding = goal.binding else { throw CatpawError.invalid("Expected verified task binding") }
            try check(goal.state == expected && saved.turns.last?.state == .completed && goal.id == binding.task_id && binding.turn_id == tid, "\(mode) preserves separate completed chat and authoritative task status")
            try check(mode == "wire-revoked-scheduled" ? goal.artifacts.isEmpty : goal.artifacts.first.map { textHash($0.body) == $0.contentHash } == true, "\(mode) exposes hash-verified artifact only under current authority")
            try check(goal.sourceAuthorizationCurrent == (mode != "wire-revoked-scheduled"),"\(mode) records source authority separately from unknown task outcome")
            let restarted = ConversationSessionService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("wire-chat.json"))), backend: try backend())
            try await restarted.observe(scope: Profiles.user, conversationID: cid)
            let readback = try await restarted.read(scope: Profiles.user, conversationID: cid)
            try check(readback.turns.last?.id == tid && readback.goals[goal.id]?.binding == binding && readback.goals[goal.id]?.state == expected, "\(mode) restart reads original task/turn/run without redispatch")
            try check(readback.goals[goal.id]?.sourceAuthorizationCurrent == goal.sourceAuthorizationCurrent,"\(mode) cold journal retains the source authority observation")
        }
        for ending in ["lf", "crlf", "cr"] {
            let cid = try await service.create(scope: Profiles.user), operation = UUID()
            _ = try await service.send(scope: Profiles.user, conversationID: cid, text: "wire-sse-\(ending)-unicode", operationID: operation)
            let saved = try await service.read(scope: Profiles.user, conversationID: cid)
            try check(saved.turns.last?.state == .completed && saved.messages.last?.content == "Wire Unicode \u{0085} \u{2028} \u{2029} 😺." && saved.goals.isEmpty, "ASCII \(ending) SSE framing preserves raw NEL/line separators/emoji JSON bytes and ignores comments")
            try await service.observe(scope: Profiles.user, conversationID: cid)
            let observed = try await service.read(scope: Profiles.user, conversationID: cid)
            try check(observed.turns.count == 1 && observed.turns.last?.id == operation && observed.messages.last?.content == saved.messages.last?.content, "ASCII \(ending) exact Unicode terminal hash replays by original GET without a new turn")
        }
        let truncatedID = try await service.create(scope: Profiles.user), truncatedOperation = UUID()
        do { _ = try await service.send(scope: Profiles.user, conversationID: truncatedID, text: "wire-sse-unterminated", operationID: truncatedOperation) } catch { }
        let truncated = try await service.read(scope: Profiles.user, conversationID: truncatedID)
        try check(truncated.turns.last?.state == .unknown && truncated.messages.last?.complete == false, "unterminated terminal SSE line at EOF cannot declare completion")
        try await service.observe(scope: Profiles.user, conversationID: truncatedID)
        let resumed = try await service.read(scope: Profiles.user, conversationID: truncatedID)
        try check(resumed.turns.count == 1 && resumed.turns.last?.id == truncatedOperation && resumed.turns.last?.state == .completed, "unterminated EOF recovers the original committed terminal by GET without duplicate POST")
        let failedHTTP = try await service.create(scope:Profiles.user), failedOperation = UUID()
        do { _ = try await service.send(scope:Profiles.user,conversationID:failedHTTP,text:"wire-http-500",operationID:failedOperation) } catch { }
        let uncertain = try await service.read(scope:Profiles.user,conversationID:failedHTTP)
        try check(uncertain.turns.last?.state == .unknown && uncertain.turns.last?.error?.contains("HTTP 500") == true && uncertain.messages.allSatisfy { $0.role != .assistant }, "HTTP 500 after POST remains unknown with a specific recovery path and no fake reply")
        do { _ = try await service.send(scope:Profiles.user,conversationID:failedHTTP,text:"must not resend",operationID:UUID()); throw CatpawError.invalid("unknown redispatched") } catch ConversationSessionError.unresolvedOperation { }
        try await service.observe(scope:Profiles.user,conversationID:failedHTTP)
        let confirmed = try await service.read(scope:Profiles.user,conversationID:failedHTTP)
        try check(confirmed.turns.count == 1 && confirmed.turns.last?.id == failedOperation && confirmed.turns.last?.state == .completed, "HTTP 500 recovers the committed original through GET only")
        var stats = URLRequest(url: origin.appendingPathComponent("wire-test-stats")); stats.setValue("Bearer explicit-wire-test-only", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: stats), counts = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check(counts["turnPosts"] as? Int == 34 && (counts["turnReads"] as? Int ?? 0) >= 34, "reconciliation uses reads; thirty-four explicit fixture requests caused exactly thirty-four turn POSTs")
        var stop = URLRequest(url:origin.appendingPathComponent("wire-test-offline")); stop.setValue("Bearer explicit-wire-test-only",forHTTPHeaderField:"Authorization")
        _ = try await URLSession.shared.data(for:stop)
        let disconnected = ConversationSessionService(repository:repo,backend:try backend()), offlineID = try await disconnected.create(scope:Profiles.user)
        try await disconnected.saveDraft(scope:Profiles.user,conversationID:offlineID,text:"offline preserved draft")
        var offlineError = ""
        do { _ = try await disconnected.send(scope:Profiles.user,conversationID:offlineID,text:"offline preserved draft",operationID:UUID()) } catch { offlineError = error.localizedDescription }
        let offlineState = try await disconnected.read(scope:Profiles.user,conversationID:offlineID)
        let offlineCore = try await repo.record(offlineID,scope:Profiles.user)
        try check(offlineState.turns.isEmpty && offlineError.contains("无法连接服务") && offlineCore.conversation?.draftText == "offline preserved draft", "preflight network outage creates no turn and preserves the saved draft with clear connection guidance")
        print("EVIDENCE: all cases use an explicit loopback wire fixture; live model calls = 0")
    }
}
