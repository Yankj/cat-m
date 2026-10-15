import XCTest
@testable import CatpawM

final class ConversationFirstNativeTests: XCTestCase {
    #if DEBUG
    func testFixtureBadgeRequiresExplicitDebugLaunchOptIn() {
        XCTAssertFalse(CatpawDebugPresentation.showFixtureBadge(arguments: [], environment: [:]))
        XCTAssertFalse(CatpawDebugPresentation.showFixtureBadge(arguments: ["-Unrelated"], environment: ["CF_UI_TEST_SCENARIO":"p0-ui-echo"]))
        XCTAssertTrue(CatpawDebugPresentation.showFixtureBadge(arguments: ["-CatpawShowFixtureBadge"], environment: [:]))
        XCTAssertTrue(CatpawDebugPresentation.showFixtureBadge(arguments: [], environment: ["CatpawShowFixtureBadge":"1"]))
        XCTAssertFalse(CatpawDebugPresentation.showFixtureBadge(arguments: [], environment: ["CatpawShowFixtureBadge":"0"]))
    }
    #endif

    func testScheduledProjectionStateAndSameIDReadbackInsideSimulator() async throws {
        guard let text = R9WireFixtureConfiguration.origin, let origin = URL(string:text), origin.scheme == "http", origin.host == "127.0.0.1" else { throw XCTSkip("Requires the explicit zero-model r9 loopback wire runner") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:dir) }
        let path = dir.appendingPathComponent("r9-state.store")
        func backend() throws -> NativeChatHTTPBackend { NativeChatHTTPBackend(configuration:try NativeChatConfiguration(origin:origin,localScope:Profiles.user,serverScopeID:Profiles.user.workspaceID,allowInjectedTestProvider:true),credentials:NativeR9WireCredentials()) }
        let service = ConversationSessionService(repository:try Repository(persistence:SwiftDataPersistence(url:path)),backend:try backend())
        var evidence:[[String:Any]] = []
        for (mode,expected) in [("wire-scheduled",ConversationGoalProjection.State.queued),("wire-outcome-unknown",.unknown),("wire-future-state",.unknown),("wire-revoked-scheduled",.unknown)] {
            let cid = try await service.create(scope:Profiles.user), tid = UUID()
            _ = try await service.send(scope:Profiles.user,conversationID:cid,text:mode,operationID:tid)
            let saved = try await service.read(scope:Profiles.user,conversationID:cid), goal = try XCTUnwrap(saved.goals.values.first), binding = try XCTUnwrap(goal.binding)
            XCTAssertEqual(goal.state,expected); XCTAssertEqual(saved.turns.last?.state,.completed); XCTAssertEqual(binding.turn_id,tid); XCTAssertEqual(binding.task_id,goal.id)
            if mode == "wire-revoked-scheduled" { XCTAssertTrue(goal.artifacts.isEmpty) }
            else { let artifact = try XCTUnwrap(goal.artifacts.first); XCTAssertEqual(artifact.contentHash,textHash(artifact.body)); XCTAssertEqual(artifact.version,1) }
            let reopened = ConversationSessionService(repository:try Repository(persistence:SwiftDataPersistence(url:path)),backend:try backend())
            try await reopened.observe(scope:Profiles.user,conversationID:cid)
            let after = try await reopened.read(scope:Profiles.user,conversationID:cid)
            XCTAssertEqual(after.turns.last?.id,tid); XCTAssertEqual(after.goals[goal.id]?.binding,binding); XCTAssertEqual(after.goals[goal.id]?.state,expected)
            evidence.append(["mode":mode,"conversation_id":cid.uuidString,"turn_id":tid.uuidString,"task_id":goal.id,"run_id":binding.run_id.uuidString,"state":goal.state.rawValue,"artifact_hash":goal.artifacts.first?.contentHash ?? "no-authority"])
        }
        var stats = URLRequest(url:origin.appendingPathComponent("wire-test-stats")); stats.setValue("Bearer explicit-wire-test-only",forHTTPHeaderField:"Authorization")
        let (data,response) = try await URLSession.shared.data(for:stats); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]); XCTAssertEqual(counts["turnPosts"] as? Int,4); XCTAssertGreaterThanOrEqual(counts["turnReads"] as? Int ?? 0,4)
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:["cases":evidence,"live_model_calls":0,"production_auth":false],options:.sortedKeys),uniformTypeIdentifier:"public.json"); attachment.name = "r9-native-state-same-id-readback"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testV5FrozenSyntheticHTTPAdapterInsideSimulator() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["CATPAW_V5_FIXTURE_B64URL"] else { throw XCTSkip("Requires explicit frozen scripted CLI harness") }
        var normalized = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        let data = try XCTUnwrap(Data(base64Encoded: normalized)), config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(config["authentication"] as? String, "explicit_test_fixture_session"); XCTAssertEqual(config["production_login_verified"] as? Bool, false)
        let origin = try XCTUnwrap(URL(string: try XCTUnwrap(config["base_url"] as? String)))
        XCTAssertEqual(origin.scheme, "http"); XCTAssertEqual(origin.host, "127.0.0.1")
        let token = try XCTUnwrap(config["access_token"] as? String), scope = try XCTUnwrap(config["scope"] as? [String: String]), serverID = try XCTUnwrap(scope["scope_id"].flatMap(UUID.init(uuidString:)))
        func call(_ path: String, tick: Bool = false) async throws -> [String: Any] {
            var r = URLRequest(url: origin.appendingPathComponent(path)); r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if tick { r.httpMethod = "POST"; r.httpBody = Data("{}".utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (d,response) = try await URLSession.shared.data(for:r)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with:d) as? [String: Any])
        }
        let metadata = try await call("catpaw/testing/v1/fixture"), cases = try XCTUnwrap(metadata["cases"] as? [[String: Any]]), chosen = try XCTUnwrap(cases.first { $0["id"] as? String == "local-report" })
        XCTAssertEqual(metadata["model_reality"] as? String,"injected_synthetic_fixture")
        let context = try XCTUnwrap(chosen["context"] as? [[String:String]]).map { ConversationExplicitContext(id:$0["id"]!,text:$0["text"]!) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:dir) }
        let path = dir.appendingPathComponent("v5.store"), repo = try Repository(persistence: SwiftDataPersistence(url:path))
        let backend = NativeChatHTTPBackend(configuration: try NativeChatConfiguration(origin:origin,localScope:Profiles.user,serverScopeID:serverID,allowInjectedTestProvider:true,useFrozenFixtureMetadata:true),credentials:NativeV5FixtureCredentials(token:token))
        let service = ConversationSessionService(repository:repo,backend:backend), id = try await service.openLatest(scope:Profiles.user), operation = UUID()
        _ = try await service.send(scope:Profiles.user,conversationID:id,text:try XCTUnwrap(chosen["message"] as? String),operationID:operation,context:context)
        var saved = try await service.read(scope:Profiles.user,conversationID:id)
        XCTAssertEqual(saved.turns.last?.state,.completed); XCTAssertEqual(saved.goals.count,1)
        try await service.stopObserving(scope:Profiles.user,conversationID:id)
        _ = try await call("catpaw/testing/v1/tick",tick:true)
        try await Task.sleep(nanoseconds:1_200_000_000)
        _ = try await call("catpaw/testing/v1/tick",tick:true)
        let reopened = ConversationSessionService(repository:try Repository(persistence:SwiftDataPersistence(url:path)),backend:backend)
        try await reopened.observe(scope:Profiles.user,conversationID:id); saved = try await reopened.read(scope:Profiles.user,conversationID:id)
        let goal = try XCTUnwrap(saved.goals.values.first), artifact = try XCTUnwrap(goal.artifacts.first)
        XCTAssertEqual(goal.state,.completed); XCTAssertEqual(saved.turns.last?.id,operation); XCTAssertEqual(saved.turns.count,1)
        XCTAssertEqual(artifact.version,1); XCTAssertEqual(artifact.contentHash,textHash(artifact.body)); XCTAssertTrue(artifact.content.contains("雨具"))
        let final = try await call("catpaw/testing/v1/fixture"); XCTAssertEqual(final["provider_requests"] as? Int,2)
    }
    func testV4SyntheticHTTPAdapterInsideSimulator() async throws {
        guard let value = ProcessInfo.processInfo.environment["CATPAW_V4_SYNTHETIC_ORIGIN"] else { throw XCTSkip("Run Scripts/test-native-v4-synthetic.py for the explicit v4 loopback test") }
        guard let origin = URL(string: value), origin.scheme == "http", origin.host == "127.0.0.1" else { XCTFail("Test origin must be owned loopback; received public test origin: " + value); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository(persistence: SwiftDataPersistence(url: dir.appendingPathComponent("v4.store")))
        let backend = NativeChatHTTPBackend(configuration: try NativeChatConfiguration(origin: origin, localScope: Profiles.user, serverScopeID: Profiles.user.workspaceID, allowInjectedTestProvider: true), credentials: NativeV4SyntheticCredentials())
        let service = ConversationSessionService(repository: repo, backend: backend), id = try await service.openLatest(scope: Profiles.user)
        let ready = await backend.connection(scope: Profiles.user); XCTAssertEqual(ready.state, .providerUnverified)
        _ = try await service.send(scope: Profiles.user, conversationID: id, text: "原生合成问答，请直接回答", operationID: UUID())
        let question = try await service.read(scope: Profiles.user, conversationID: id)
        XCTAssertEqual(question.turns.last?.state, .completed); XCTAssertTrue(question.goals.isEmpty)
        _ = try await service.send(scope: Profiles.user, conversationID: id, text: "请用合成资料，保存一份完整的中文本地报告后停止", operationID: UUID(), context: [ConversationExplicitContext(id: "synthetic-trip", text: "固定合成三日旅行；衣物、雨具、随身物品")])
        var saved = try await service.read(scope: Profiles.user, conversationID: id)
        for _ in 0..<30 {
            try await service.observe(scope: Profiles.user, conversationID: id)
            saved = try await service.read(scope: Profiles.user, conversationID: id)
            if saved.goals.values.first?.state == .completed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await service.observe(scope: Profiles.user, conversationID: id)
        let goal = try XCTUnwrap(saved.goals.values.first), artifact = try XCTUnwrap(goal.artifacts.first)
        XCTAssertEqual(saved.turns.count, 2); XCTAssertEqual(saved.turns.last?.state, .completed); XCTAssertEqual(goal.state, .completed)
        XCTAssertEqual(textHash(artifact.body), artifact.contentHash); XCTAssertEqual(artifact.version, 1)
        XCTAssertTrue(artifact.content.contains("雨具")); XCTAssertEqual(goal.binding?.conversation_id, id)
        var request = URLRequest(url: origin.appendingPathComponent("native-v4-test/stats")); request.setValue("Bearer unit-test-a", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request), stats = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(stats["turnPosts"] as? Int, 2); XCTAssertEqual(stats["live_model_calls"] as? Int, 0)
    }
    func testSwiftDataNotSentSurvivesRestartAndExplicitResumeUsesOriginalID() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("preflight.store"), backend = NativeRecoveryTestBackend()
        let repo = try Repository(persistence: SwiftDataPersistence(url: path))
        let service = ConversationSessionService(repository: repo, backend: backend)
        let id = try await service.openLatest(scope: Profiles.user), original = UUID()
        let text = "原生测试：未发送输入跨重启保留"
        try await service.saveDraft(scope: Profiles.user, conversationID: id, text: text)
        do { _ = try await service.send(scope: Profiles.user, conversationID: id, text: text, operationID: original); XCTFail("Preflight should refuse") } catch is ConversationDispatchFailure { }
        let restartedRepo = try Repository(persistence: SwiftDataPersistence(url: path))
        let restarted = ConversationSessionService(repository: restartedRepo, backend: backend)
        let held = try await restarted.read(scope: Profiles.user, conversationID: id)
        let core = try await restartedRepo.record(id, scope: Profiles.user)
        XCTAssertNil(held.unresolved); XCTAssertEqual(held.pendingUnsent?.id, original); XCTAssertEqual(core.conversation?.draftText, text)
        _ = try await restarted.send(scope: Profiles.user, conversationID: id, text: text, operationID: original)
        let saved = try await restarted.read(scope: Profiles.user, conversationID: id), requests = await backend.captured()
        XCTAssertEqual(saved.turns.count, 1); XCTAssertEqual(saved.turns.first?.state, .completed)
        XCTAssertEqual(saved.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(requests.map(\.operationID), [original, original])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(requests[0]), try encoder.encode(requests[1]))
    }
    func testSwiftDataAdmissionSaveFailureRollsBackBeforeBackendCall() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = try SwiftDataPersistence(url: dir.appendingPathComponent("rollback.store")), backend = NativeRecoveryTestBackend()
        let repo = try Repository(persistence: storage), service = ConversationSessionService(repository: repo, backend: backend)
        let id = try await service.openLatest(scope: Profiles.user)
        try await service.saveDraft(scope: Profiles.user, conversationID: id, text: "Keep after failed save")
        storage.failNextSaveForTesting()
        do { _ = try await service.send(scope: Profiles.user, conversationID: id, text: "Keep after failed save", operationID: UUID()); XCTFail("Save must fail") } catch { }
        let saved = try await service.read(scope: Profiles.user, conversationID: id), core = try await repo.record(id, scope: Profiles.user), requests = await backend.captured()
        XCTAssertTrue(saved.turns.isEmpty); XCTAssertTrue(saved.messages.isEmpty); XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(core.conversation?.draftText, "Keep after failed save")
    }
    func testUnconfiguredConversationPreservesDraftAndHasNoSimulatedAnswer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try Repository(persistence: FilePersistence(url: dir.appendingPathComponent("chat.json")))
        let service = ConversationSessionService(repository: repository)
        let id = try await service.openLatest(scope: Profiles.user)
        try await service.saveDraft(scope: Profiles.user, conversationID: id, text: "Prepare Friday's presentation")
        do { _ = try await service.send(scope: Profiles.user, conversationID: id, text: "Prepare Friday's presentation", operationID: UUID()); XCTFail("Unavailable backend must refuse sending") }
        catch ConversationSessionError.notConfigured { }
        let state = try await service.read(scope: Profiles.user, conversationID: id)
        let saved = try await repository.record(id, scope: Profiles.user)
        XCTAssertTrue(state.messages.isEmpty); XCTAssertTrue(state.goals.isEmpty)
        XCTAssertEqual(saved.conversation?.draftText, "Prepare Friday's presentation")
    }
    func testQueueRemainsHeldAfterNativeRepositoryRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("queue.json")
        let repo = try Repository(persistence: FilePersistence(url: path))
        let id = try await ConversationSessionService(repository: repo).openLatest(scope: Profiles.user)
        let queue = ConversationFollowupQueueService(repository: repo, scope: Profiles.user, conversationID: id)
        let message = ConversationFollowup(text: "explicit native queue test only")
        try await queue.enqueue(message); try await queue.pause()
        let restarted = ConversationFollowupQueueService(repository: try Repository(persistence: FilePersistence(url: path)), scope: Profiles.user, conversationID: id)
        let state = try await restarted.state()
        XCTAssertTrue(state.paused); XCTAssertEqual(state.pending.map(\.id), [message.id])
        XCTAssertNil(state.inflight)
    }

}

private struct NativeV4SyntheticCredentials: NativeChatSessionCredentials {
    func authorization(scope: DataScope) async throws -> String { "Bearer unit-test-a" }
}
private struct NativeR9WireCredentials: NativeChatSessionCredentials {
    func authorization(scope:DataScope) async throws -> String { "Bearer explicit-wire-test-only" }
}
// Test-target-only dependency injected by the explicit runner before compilation
// and restored in finally. No URL, identity or credential is added to the App.
private enum R9WireFixtureConfiguration {
    static let origin: String? = nil // R9_WIRE_COMPILE_INPUT
}
private struct NativeV5FixtureCredentials: NativeChatSessionCredentials {
    let token: String
    func authorization(scope: DataScope) async throws -> String { "Bearer " + token }
}

private actor NativeRecoveryTestBackend: ConversationBackend {
    private var requests: [ConversationTurnRequest] = []
    func captured() -> [ConversationTurnRequest] { requests }
    func connection(scope: DataScope) async -> ConversationConnection { ConversationConnection(state: .providerUnverified, provider: "Native test only", detail: "No model or network") }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        requests.append(request)
        if requests.count == 1 { throw ConversationDispatchFailure.notSent(reason: "Test-only authority preflight refusal") }
        let id = UUID(), text = "Native test-only answer"
        return AsyncThrowingStream { c in
            c.yield(ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .textDelta(messageID: id, text: text)))
            c.yield(ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: 2, payload: .completed(messageID: id, finalTextHash: textHash(text))))
            c.finish()
        }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation { throw CatpawError.unavailable("Unused native test observation") }
}
