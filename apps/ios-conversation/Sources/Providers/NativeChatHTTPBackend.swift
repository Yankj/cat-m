import Foundation
import CoreFoundation

public struct NativeChatConfiguration: Sendable {
    public let origin: URL
    public let localScope: DataScope
    public let serverScopeID: UUID
    public let allowInjectedTestProvider: Bool
    public let useFrozenFixtureMetadata: Bool
    public let fixtureExpectedReality: String
    public let publishableKey: String?
    public let edgeRegion: String?
    public init(origin: URL, localScope: DataScope, serverScopeID: UUID, allowInjectedTestProvider: Bool = false, useFrozenFixtureMetadata: Bool = false, fixtureExpectedReality: String = "injected_synthetic_fixture", publishableKey: String? = nil, edgeRegion: String? = nil) throws {
        try NativeAPIBase.validate(origin,allowLoopback:true)
        let c = URLComponents(url:origin,resolvingAgainstBaseURL:false)!
        guard publishableKey == nil || publishableKey?.range(of:"^sb_publishable_[A-Za-z0-9_-]{10,2000}$",options:.regularExpression) != nil else { throw NativeAuthError.invalidConfiguration }
        guard !useFrozenFixtureMetadata || (allowInjectedTestProvider && c.scheme == "http" && c.host == "127.0.0.1") else { throw CatpawError.invalid("冻结 fixture metadata 仅允许明确 loopback 测试。") }
        guard ["injected_synthetic_fixture","provider_unverified"].contains(fixtureExpectedReality) else { throw ConversationSessionError.invalidEvent }
        if let edgeRegion { guard edgeRegion.utf8.count <= 40,edgeRegion.range(of:"^[a-z]{2}(?:-[a-z]+){1,3}-[0-9]+$",options:.regularExpression) != nil else { throw NativeAuthError.invalidConfiguration } }
        // Pin only this application's confirmed Edge API. Auth and other origins
        // retain default routing. Explicit region routing has no automatic failover.
        let currentEdge = c.scheme == "https" && (c.port == nil || c.port == 443) && c.host?.lowercased() == "dbyklgxdvjbutxzsjeth.supabase.co" && ["/functions/v1/catpaw-api","/functions/v1/catpaw-api/"].contains(c.path)
        self.edgeRegion = currentEdge ? (edgeRegion ?? "us-east-1") : nil
        self.origin = origin; self.localScope = localScope; self.serverScopeID = serverScopeID; self.allowInjectedTestProvider = allowInjectedTestProvider; self.useFrozenFixtureMetadata = useFrozenFixtureMetadata; self.fixtureExpectedReality = fixtureExpectedReality; self.publishableKey = publishableKey
    }
    public func makeRequest(route: String, authorization: String) throws -> URLRequest {
        guard authorization.hasPrefix("Bearer "),authorization.count > 7,!authorization.contains("\r"),!authorization.contains("\n") else { throw ConversationSessionError.notConfigured }
        var request = URLRequest(url:try NativeAPIBase.endpoint(base:origin,route:route));request.timeoutInterval = 60
        request.setValue(authorization,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("text/event-stream, application/json",forHTTPHeaderField:"Accept")
        if let publishableKey { request.setValue(publishableKey,forHTTPHeaderField:"apikey") }
        if let edgeRegion { request.setValue(edgeRegion,forHTTPHeaderField:"x-region") };return request
    }
}
/// An authenticated application session, never an OpenRouter key or client-chosen identity.
public protocol NativeChatSessionCredentials: Sendable { func authorization(scope: DataScope) async throws -> String; func rejected(scope: DataScope) async }
public extension NativeChatSessionCredentials { func rejected(scope: DataScope) async { } }
public struct MissingNativeChatSession: NativeChatSessionCredentials {
    public init() {}
    public func authorization(scope: DataScope) async throws -> String { throw ConversationSessionError.notConfigured }
}
public actor NativeChatHTTPBackend: ConversationBackend {
    private let configuration: NativeChatConfiguration
    private let credentials: any NativeChatSessionCredentials
    private let session: URLSession
    private var bindingCache: [UUID: [String: ConversationTaskBinding]] = [:]
    private var toolTitles: [UUID: [String: String]] = [:]
    private var observedModelState: ConversationConnection.State?
    public init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials = MissingNativeChatSession()) {
        self.configuration = configuration; self.credentials = credentials
        let policy = URLSessionConfiguration.ephemeral; policy.urlCache = nil; policy.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: policy, delegate: NativeChatNoRedirect(), delegateQueue: nil)
    }
    public func close() { session.invalidateAndCancel(); bindingCache.removeAll(); toolTitles.removeAll(); observedModelState = nil }
    public func connection(scope: DataScope) async -> ConversationConnection {
        let auth: String
        do { auth = try await authorization(scope) }
        catch { return ConversationConnection(state: .notConfigured, provider: "OpenRouter", detail: "缺少有效后台登录会话；模型 key 由服务端管理。") }
        if observedModelState == .notConfigured { return ConversationConnection(state: .notConfigured, provider: "OpenRouter", detail: "后台返回 not_configured；服务端模型尚未配置。") }
        do {
            if configuration.useFrozenFixtureMetadata {
                let metadata = try await json("/catpaw/testing/v1/fixture", auth: auth)
                guard metadata["authentication"] as? String == "explicit_test_fixture_session", metadata["model_reality"] as? String == configuration.fixtureExpectedReality, metadata["real_supabase_login_verified"] as? Bool == false else { throw ConversationSessionError.invalidEvent }
                let live = configuration.fixtureExpectedReality == "provider_unverified"
                return ConversationConnection(state: .providerUnverified, provider: live ? "OpenRouter free synthetic" : "scripted_ios_fixture", detail: live ? "明确的合成测试身份；免费真实模型链路待验，正式登录未验。" : "明确的合成测试身份；无真实 Auth 或模型调用。")
            }
            let readiness = try await json("/readyz", auth: auth)
            guard readiness["ready"] as? Bool == true else { return ConversationConnection(state: .unavailable, provider: "OpenRouter", detail: "后台有界执行入口尚未准备好，未发送模型请求。") }
            return ConversationConnection(state: .providerUnverified, provider: "OpenRouter", detail: "后台 readiness 与登录会话可用；真实模型回答仍待验证。")
        } catch { return ConversationConnection(state: .unavailable, provider: "OpenRouter", detail: Self.friendlyTransportMessage(error) + "原请求与输入保留。") }
    }
    public func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? {
        guard configuration.publishableKey != nil else { return nil }
        let auth = try await authorization(scope),base = scopePath+"/conversations/"+conversationID.uuidString.lowercased()
        do { _ = try await json(base,auth:auth) } catch NativeChatHTTPFailure.status(404) { _ = try await json(scopePath+"/conversations",auth:auth,body:["conversation_id":conversationID.uuidString.lowercased()]) }
        let metadata = try await json("/catpaw/privacy/v1/model-route",auth:auth),ui = try Self.object(metadata["ui"]),routeHash = try Self.sha(metadata["route_hash"])
        let path = "/catpaw/privacy/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+conversationID.uuidString.lowercased()+"/model-consent"
        let stored = try await json(path,auth:auth);let prior = stored["consent"] as? [String:Any]
        if prior?["decision"] as? String == "allow",prior?["route_hash"] as? String == routeHash { return nil }
        guard let title = ui["title"] as? String,let body = ui["body"] as? String,title.utf8.count <= 512,body.utf8.count <= 12000 else { throw ConversationSessionError.invalidEvent }
        let revision = prior?["revision"] as? Int ?? 0;guard revision >= 0 else { throw ConversationSessionError.invalidEvent }
        return .init(conversationID:conversationID,title:title,body:body,routeHash:routeHash,expectedRevision:revision)
    }
    public func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws {
        let auth = try await authorization(scope),path = "/catpaw/privacy/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+consent.conversationID.uuidString.lowercased()+"/model-consent"
        let reply = try await json(path,auth:auth,body:["decision":"allow","expected_revision":consent.expectedRevision,"route_hash":consent.routeHash]),row = try Self.object(reply["consent"])
        guard row["decision"] as? String == "allow",row["route_hash"] as? String == consent.routeHash,row["revision"] as? Int == consent.expectedRevision+1 else { throw ConversationSessionError.invalidEvent }
    }
    public func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let auth: String, grant: Int, upload: URLRequest
        do { (auth, grant, upload) = try await prepare(request) }
        catch { throw ConversationDispatchFailure.notSent(reason: Self.friendlyTransportMessage(error)) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var postInitiated = false
                do {
                    try Task.checkCancellation()
                    postInitiated = true // From here a transport error cannot prove non-admission.
                    let (bytes, response) = try await self.session.bytes(for: upload)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        if (response as? HTTPURLResponse)?.statusCode == 401 { await self.credentials.rejected(scope: request.scope) }
                        throw NativeChatHTTPFailure.turnResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                    if http.mimeType == "application/json" {
                        var data = Data(); for try await b in bytes { guard data.count < 2_000_000 else { throw ConversationSessionError.invalidEvent }; data.append(b) }
                        let snapshot = try Self.object(JSONSerialization.jsonObject(with: data)); try Self.chatEnvelope(snapshot)
                        let turn = try Self.object(snapshot["turn"])
                        for event in try Self.array(turn["events"]) { continuation.yield(try await self.decode(event, request: request, grant: grant, auth: auth)) }
                    } else {
                        guard http.mimeType == "text/event-stream" else { throw ConversationSessionError.invalidEvent }
                        for try await line in bytes.lines {
                            try Task.checkCancellation(); guard line.utf8.count <= 262144 else { throw ConversationSessionError.invalidEvent }
                            if line.isEmpty || line.hasPrefix(":") { continue }
                            guard line.hasPrefix("data: ") else { throw ConversationSessionError.invalidEvent }
                            let wire = try Self.object(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)))
                            continuation.yield(try await self.decode(wire, request: request, grant: grant, auth: auth))
                        }
                    }
                    continuation.finish() // EOF is never synthesized into completion.
                } catch {
                    let failure: Error = error is URLError
                        ? CatpawError.unavailable(Self.friendlyTransportMessage(error) + (postInitiated ? "本轮发送结果尚未确认；请读取原请求状态，不要重新发送。" : ""))
                        : error
                    continuation.finish(throwing: postInitiated ? failure : ConversationDispatchFailure.notSent(reason: failure.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() } // detaches observation only
        }
    }
    private static func friendlyTransportMessage(_ error: Error) -> String {
        guard let network = error as? URLError else { return error.localizedDescription }
        switch network.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "网络连接已中断。请检查网络后再读取进展。"
        case .timedOut:
            return "连接超时。请稍后读取进展。"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "暂时无法连接服务。请检查网络后再试。"
        default: return "网络请求未完成。请检查连接后再读取进展。"
        }
    }
    private func prepare(_ request: ConversationTurnRequest) async throws -> (String, Int, URLRequest) {
        try Task.checkCancellation()
        let auth = try await authorization(request.scope)
        let conversation = try await readConversation(request, auth: auth, mayCreate: true)
        let revision = try Self.positive(conversation["revision"]), grant = try Self.positive(conversation["grant_epoch"])
        let remote = try Self.array(conversation["messages"])
        let previous = request.history.dropLast().filter { $0.role == .user || ($0.role == .assistant && $0.toolName == nil && $0.complete) }
        guard remote.count == previous.count else { throw CatpawError.conflict }
        for (wire, local) in zip(remote, previous) {
            guard UUID(uuidString: wire["id"] as? String ?? "") == local.id, wire["role"] as? String == local.role.rawValue, wire["content"] as? String == local.content else { throw CatpawError.conflict }
        }
        guard let message = request.history.last, message.role == .user else { throw ConversationSessionError.invalidEvent }
        let body: [String: Any] = ["turn_id": request.operationID.uuidString.lowercased(), "expected_revision": revision, "expected_grant_epoch": grant,
                                 "message": ["id": message.id.uuidString.lowercased(), "text": message.content], "context": request.context.map { ["id": $0.id, "text": $0.text] }]
        let bytes = try Self.jsonData(body); guard bytes.count <= 40000 else { throw CatpawError.invalid("本轮上下文超过后台请求上限。") }
        var upload = try self.request(path(request) + "/turns", auth: auth); upload.httpMethod = "POST"; upload.httpBody = bytes
        try Task.checkCancellation()
        return (auth, grant, upload)
    }
    public func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        let auth = try await authorization(request.scope)
        let conversation = try await readConversation(request, auth: auth, mayCreate: false)
        let currentGrant = try Self.positive(conversation["grant_epoch"])
        let wrapper = try await json(path(request) + "/turns/" + request.operationID.uuidString.lowercased(), auth: auth)
        try Self.chatEnvelope(wrapper)
        let turn = try Self.object(wrapper["turn"])
        guard UUID(uuidString: turn["id"] as? String ?? "") == request.operationID,
              UUID(uuidString: turn["conversation_id"] as? String ?? "") == request.conversationID,
              UUID(uuidString: turn["scope_id"] as? String ?? "") == configuration.serverScopeID,
              try Self.positive(turn["grant_epoch"]) == currentGrant else { throw ConversationSessionError.invalidEvent }
        var events: [ConversationTurnEvent] = [], goals: [ConversationGoalProjection] = []
        for wire in try Self.array(turn["events"]) {
            let event = try await decode(wire, request: request, grant: currentGrant, auth: auth); events.append(event)
            if case .toolResult(let result) = event.payload { goals += result.committedGoals }
        }
        // Read original bindings before their projection; never create a task to recover it.
        var bindings = Array(bindingCache[request.operationID, default: [:]].values)
        for message in request.history where message.role == .tool && message.toolName == "delegate_task" {
            if let data = message.content.data(using: .utf8), let candidate = try? JSONSerialization.jsonObject(with: data), let binding = try? binding(candidate, request: request, currentTurn: false) {
                let original = try await json(path(request) + "/turns/" + binding.turn_id.uuidString.lowercased(), auth: auth)
                try Self.chatEnvelope(original); let prior = try Self.object(original["turn"])
                let confirmed = try Self.array(prior["task_bindings"]).compactMap { try? self.binding($0, request: request, currentTurn: false) }
                guard confirmed.contains(binding) else { throw ConversationSessionError.invalidEvent }
                bindings.append(binding)
            }
        }
        var seen: Set<String> = []
        for b in bindings where seen.insert(b.task_id).inserted { goals.append(try await projection(b, title: title(b.call_id, turnID: b.turn_id, history: request.history), request: request, auth: auth)) }
        return ConversationObservation(request: request, events: events, requestHash: try Self.sha(turn["request_hash"]), grantEpoch: currentGrant, goals: goals)
    }
    private func readConversation(_ value: ConversationTurnRequest, auth: String, mayCreate: Bool) async throws -> [String: Any] {
        var wrapper: [String: Any]
        do { wrapper = try await json(path(value), auth: auth) }
        catch NativeChatHTTPFailure.status(404) where mayCreate {
            wrapper = try await json(scopePath + "/conversations", auth: auth, body: ["conversation_id": value.conversationID.uuidString.lowercased()])
        }
        try Self.chatEnvelope(wrapper); let c = try Self.object(wrapper["conversation"])
        guard UUID(uuidString: c["id"] as? String ?? "") == value.conversationID, UUID(uuidString: c["scope_id"] as? String ?? "") == configuration.serverScopeID,
              c["state"] as? String == "active", c["policy"] as? String == "conversation-local-output-v1" else { throw ConversationSessionError.invalidEvent }
        return c
    }
    private func decode(_ wire: [String: Any], request: ConversationTurnRequest, grant: Int, auth: String) async throws -> ConversationTurnEvent {
        try Self.chatEnvelope(wire)
        let sequence = try Self.positive(wire["sequence"])
        guard UUID(uuidString: wire["scope_id"] as? String ?? "") == configuration.serverScopeID,
              UUID(uuidString: wire["conversation_id"] as? String ?? "") == request.conversationID,
              UUID(uuidString: wire["turn_id"] as? String ?? "") == request.operationID,
              try Self.positive(wire["grant_epoch"]) == grant,
              wire["cursor"] as? String == request.operationID.uuidString.lowercased() + ":\(sequence)" else { throw ConversationSessionError.invalidEvent }
        let reality = wire["model_reality"] as? String
        guard reality == "provider_unverified" || reality == "not_configured" || (configuration.allowInjectedTestProvider && reality == "injected_test_provider") || (configuration.useFrozenFixtureMetadata && reality == "injected_synthetic_fixture") else { throw ConversationSessionError.invalidEvent }
        observedModelState = reality == "not_configured" ? .notConfigured : .providerUnverified
        let data = try Self.object(wire["data"]), type = wire["type"] as? String
        let payload: ConversationTurnEvent.Payload
        switch type {
        case "turn_started": payload = .started(requestHash: try Self.sha(data["request_hash"]), conversationRevision: try Self.positive(data["conversation_revision"]), grantEpoch: grant)
        case "text_delta":
            guard reality != "not_configured", let id = UUID(uuidString: data["message_id"] as? String ?? ""), let text = data["text"] as? String else { throw ConversationSessionError.invalidEvent }
            payload = .textDelta(messageID: id, text: text)
        case "tool_call":
            guard reality != "not_configured", let name = data["name"] as? String, ["delegate_task", "agent_status"].contains(name), let id = data["call_id"] as? String, !id.isEmpty else { throw ConversationSessionError.invalidEvent }
            if name == "delegate_task", let args = data["arguments"] as? [String: Any], let title = args["title"] as? String, title.utf16.count <= 160 { toolTitles[request.operationID, default: [:]][id] = title }
            payload = .toolStarted(callID: id, name: name, arguments: String(decoding: try Self.jsonData(Self.object(data["arguments"])), as: UTF8.self))
        case "tool_result":
            guard reality != "not_configured", let name = data["name"] as? String, let call = data["call_id"] as? String, !call.isEmpty else { throw ConversationSessionError.invalidEvent }
            let result = try Self.object(data["result"]); var goals: [ConversationGoalProjection] = []
            if name == "delegate_task" {
                let b = try binding(result, request: request, currentTurn: true); guard b.call_id == call, b.grant_epoch == grant else { throw ConversationSessionError.invalidEvent }
                if let known = bindingCache[request.operationID]?[call] { guard known == b else { throw ConversationSessionError.invalidEvent } }
                let goal = try await projection(b, title: title(call, turnID: b.turn_id, history: request.history), request: request, auth: auth)
                // Commit only verified projections; replay the same binding without duplication.
                bindingCache[request.operationID, default: [:]][call] = b
                goals.append(goal)
            } else if name == "agent_status" {
                var known = Array(bindingCache[request.operationID, default: [:]].values)
                for message in request.history where message.role == .tool && message.toolName == "delegate_task" {
                    if let raw = try? JSONSerialization.jsonObject(with: Data(message.content.utf8)), let b = try? binding(raw, request: request, currentTurn: false) { known.append(b) }
                }
                for row in try Self.array(result["tasks"]) {
                    let run = try Self.object(row["run"])
                    if let b = known.first(where: { UUID(uuidString: run["id"] as? String ?? "") == $0.run_id && run["request_hash"] as? String == $0.request_hash }) { goals.append(try await projection(b, title: title(b.call_id, turnID: b.turn_id, history: request.history), request: request, auth: auth, supplied: row)) }
                }
            } else { throw ConversationSessionError.invalidEvent }
            payload = .toolResult(ConversationToolResult(callID: call, name: name, content: String(decoding: try Self.jsonData(result), as: UTF8.self), committedGoals: goals))
        case "turn_completed":
            guard reality != "not_configured", let id = UUID(uuidString: data["message_id"] as? String ?? "") else { throw ConversationSessionError.invalidEvent }
            let bindings = try Self.array(data["task_bindings"]); guard bindings.count <= 1 else { throw ConversationSessionError.invalidEvent }
            let confirmed = try bindings.map { try binding($0, request: request, currentTurn: true) }
            let known = bindingCache[request.operationID, default: [:]]
            guard confirmed.count == known.count, Set(confirmed.map(\.call_id)).count == confirmed.count,
                  confirmed.allSatisfy({ $0.grant_epoch == grant && known[$0.call_id] == $0 }) else { throw ConversationSessionError.invalidEvent }
            payload = .completed(messageID: id, finalTextHash: try Self.sha(data["final_text_hash"]))
        case "turn_failed":
            guard let code = data["code"] as? String, let reconciliation = data["reconciliation_required"] as? Bool else { throw ConversationSessionError.invalidEvent }
            payload = .failed(message: code, reconciliationRequired: reconciliation)
        default: throw ConversationSessionError.invalidEvent
        }
        return ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: sequence, payload: payload)
    }
    private func binding(_ raw: Any, request: ConversationTurnRequest, currentTurn: Bool) throws -> ConversationTaskBinding {
        let b = try JSONDecoder().decode(ConversationTaskBinding.self, from: Self.jsonData(raw))
        guard b.scope_id == configuration.serverScopeID, b.conversation_id == request.conversationID, !currentTurn || b.turn_id == request.operationID,
              Set([b.conversation_id, b.turn_id, b.delegation_id, b.operation_id, b.run_id]).count == 5,
              !b.call_id.isEmpty, Self.opaque(b.task_id), b.delegation_revision > 0, b.grant_epoch > 0,
              try Self.sha(b.request_hash) == b.request_hash,
              b.projection_url == "/catpaw/v1/scopes/\(configuration.serverScopeID.uuidString.lowercased())/runs/\(b.run_id.uuidString.lowercased())" else { throw ConversationSessionError.invalidEvent }
        return b
    }
    private func projection(_ binding: ConversationTaskBinding, title: String, request: ConversationTurnRequest, auth: String, supplied: [String: Any]? = nil) async throws -> ConversationGoalProjection {
        let wrapper: [String: Any]
        if let supplied { wrapper = supplied } else { wrapper = try await json(binding.projection_url, auth: auth) }
        guard try Self.positive(wrapper["schema_version"]) == 1 else { throw ConversationSessionError.invalidEvent }
        let run = try Self.object(wrapper["run"]), task = try Self.object(wrapper["task"])
        guard UUID(uuidString: run["id"] as? String ?? "") == binding.run_id, UUID(uuidString: run["operation_id"] as? String ?? "") == binding.operation_id,
              UUID(uuidString: run["delegation_id"] as? String ?? "") == binding.delegation_id,
              run["task_id"] as? String == binding.task_id, task["id"] as? String == binding.task_id,
              run["request_hash"] as? String == binding.request_hash, try Self.positive(run["grant_epoch"]) == binding.grant_epoch,
              try Self.positive(run["delegation_revision"]) == binding.delegation_revision else { throw ConversationSessionError.invalidEvent }
        let authority = run["authorization_state"] as? String == "current"
        let state: ConversationGoalProjection.State
        switch authority ? run["state"] as? String : nil { case "queued", "scheduled": state = .queued; case "running": state = .working; case "waiting_input": state = .waitingInput; case "succeeded": state = .completed; case "failed": state = .failed; case "paused": state = .paused; case "cancelled": state = .cancelled; default: state = .unknown }
        var artifacts: [ConversationArtifactProjection] = []
        if authority {
            for ref in try Self.array(run["artifact_references"]) {
                guard let id = ref["artifact_id"] as? String, Self.opaque(id) else { throw ConversationSessionError.invalidEvent }
                let version = try Self.positive(ref["version"]), hash = try Self.sha(ref["content_hash"])
                let a = try await json("/catpaw/v1/scopes/\(configuration.serverScopeID.uuidString.lowercased())/artifacts/\(id)/versions/\(version)", auth: auth)
                guard try Self.positive(a["schema_version"]) == 1 else { throw ConversationSessionError.invalidEvent }
                let record = try Self.object(a["artifact"])
                guard record["artifact_id"] as? String == id, try Self.positive(record["version"]) == version, record["content_hash"] as? String == hash,
                      UUID(uuidString: record["run_id"] as? String ?? "") == binding.run_id, record["task_id"] as? String == binding.task_id,
                      let body = record["body"] as? String, body.utf8.count <= 1_000_000, textHash(body) == hash else { throw ConversationSessionError.invalidEvent }
                let parsed = try Self.object(JSONSerialization.jsonObject(with: Data(body.utf8))), data = try Self.object(parsed["data"])
                guard let title = parsed["title"] as? String, let summary = parsed["summary"] as? String, let content = data["content"] as? String else { throw ConversationSessionError.invalidEvent }
                artifacts.append(ConversationArtifactProjection(id: id, version: version, contentHash: hash, body: body, title: title, summary: summary, content: content))
            }
        }
        guard state != .completed || !artifacts.isEmpty else { throw ConversationSessionError.invalidEvent }
        var goal = ConversationGoalProjection(id: binding.task_id, revision: binding.delegation_revision, title: artifacts.first?.title ?? title, state: state,
            summary: artifacts.first?.summary ?? (authority ? "任务已保存；进展来自原任务读取。" : "授权已变更；当前状态待核验。"), updatedAt: Date())
        goal.binding = binding; goal.artifacts = artifacts; return goal
    }
    private func title(_ call: String, turnID: UUID, history: [ConversationTranscriptMessage]) -> String {
        if let current = toolTitles[turnID]?[call] { return current }
        if let message = history.last(where: { $0.role == .assistant && $0.toolName == "delegate_task" && $0.id == stableID("conversation-call-\(turnID)-\(call)") }),
           let object = try? JSONSerialization.jsonObject(with: Data(message.content.utf8)) as? [String: Any], let title = object["title"] as? String { return title }
        return "进行中的目标"
    }
    private var scopePath: String { "/catpaw/chat/v1/scopes/" + configuration.serverScopeID.uuidString.lowercased() }
    private func path(_ r: ConversationTurnRequest) -> String { scopePath + "/conversations/" + r.conversationID.uuidString.lowercased() }
    private func authorization(_ scope: DataScope) async throws -> String {
        guard scope == configuration.localScope else { throw CatpawError.scopeMismatch }
        let value = try await credentials.authorization(scope: scope)
        guard value.hasPrefix("Bearer "), value.count > 7, value.utf8.count < 8192, !value.contains("\n"), !value.contains("\r") else { throw ConversationSessionError.notConfigured }
        return value
    }
    private func request(_ path: String, auth: String) throws -> URLRequest {
        try configuration.makeRequest(route:path,authorization:auth)
    }
    private func json(_ path: String, auth: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = try request(path, auth: auth)
        if let body { request.httpMethod = "POST"; request.httpBody = try Self.jsonData(body) }
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 { await credentials.rejected(scope: configuration.localScope) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NativeChatHTTPFailure.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard data.count <= 2_000_000 else { throw ConversationSessionError.invalidEvent }
        return try Self.object(JSONSerialization.jsonObject(with: data))
    }
    private static func object(_ raw: Any?) throws -> [String: Any] { guard let x = raw as? [String: Any] else { throw ConversationSessionError.invalidEvent }; return x }
    private static func array(_ raw: Any?) throws -> [[String: Any]] { guard let x = raw as? [[String: Any]] else { throw ConversationSessionError.invalidEvent }; return x }
    private static func positive(_ raw: Any?) throws -> Int { guard let x = raw as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(), x.doubleValue > 0, x.doubleValue.rounded() == x.doubleValue, x.doubleValue <= 9007199254740991 else { throw ConversationSessionError.invalidEvent }; return x.intValue }
    private static func sha(_ raw: Any?) throws -> String { guard let x = raw as? String, x.count == 64, x.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ConversationSessionError.invalidEvent }; return x }
    private static func opaque(_ x: String) -> Bool { x.range(of: "^[A-Za-z0-9._-]{1,256}$", options: .regularExpression) != nil }
    private static func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    private static func chatEnvelope(_ x: [String: Any]) throws { guard try positive(x["schema_version"]) == 1, x["contract"] as? String == "catpaw.native-chat.v1" else { throw ConversationSessionError.invalidEvent } }
}
private enum NativeChatHTTPFailure: Error, LocalizedError {
    case status(Int), turnResponse(Int)
    var errorDescription: String? {
        switch self {
        case .status(let code): return "后台读取返回 HTTP \(code)，保留原请求。"
        case .turnResponse(let code):
            let reason = code == 401 ? "登录状态需要复核" : (code == 429 ? "服务繁忙" : "服务响应异常")
            return "\(reason)（HTTP \(code)）。本轮发送结果尚未确认；请读取原请求状态，不要重新发送。"
        }
    }
}
private final class NativeChatNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
