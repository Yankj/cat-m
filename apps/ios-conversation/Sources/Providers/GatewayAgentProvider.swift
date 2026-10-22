import Foundation

public struct GatewayConfiguration: Sendable {
    public let baseURL: URL
    public let providerID: String
    public let expectedReality: ExecutionReality
    public let localSynthetic: Bool
    public init(baseURL: URL, localSynthetic: Bool = false, providerID: String = "catpaw.gateway.v1") throws {
        guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              (baseURL.path.isEmpty || baseURL.path == "/"),
              (localSynthetic ? baseURL.scheme == "http" && baseURL.host == "127.0.0.1" : baseURL.scheme == "https") else {
            throw catError.invalid("Gateway requires HTTPS or an explicit local synthetic loopback URL.")
        }
        self.baseURL = baseURL; self.providerID = providerID; self.localSynthetic = localSynthetic
        self.expectedReality = localSynthetic ? .simulated : .remoteAccepted
    }
}

// Only a first-party gateway session token may be supplied here. Upstream model keys never belong in the App.
public protocol GatewaySessionCredentialProvider: Sendable {
    func sessionAuthorization() async throws -> String
}
public struct UnconfiguredGatewayCredentials: GatewaySessionCredentialProvider {
    public init() {}
    public func sessionAuthorization() async throws -> String { throw catError.unavailable("Gateway session credentials are not configured.") }
}

public struct GatewayResponse: Sendable {
    public let statusCode: Int
    public let chunks: AsyncThrowingStream<Data, Error>
    public init(statusCode: Int, chunks: AsyncThrowingStream<Data, Error>) { self.statusCode = statusCode; self.chunks = chunks }
}
public protocol GatewayTransport: Sendable {
    func open(_ request: URLRequest) async throws -> GatewayResponse
}
private final class RejectGatewayRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct URLSessionGatewayTransport: GatewayTransport {
    public init() {}
    public func open(_ request: URLRequest) async throws -> GatewayResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 35
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: RejectGatewayRedirects(), delegateQueue: nil)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw catError.unavailable("Invalid gateway response.") }
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                let worker = Task {
                    defer { session.invalidateAndCancel() }
                    do {
                        var buffer = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation(); buffer.append(byte)
                            if byte == 10 || buffer.count >= 4096 { continuation.yield(buffer); buffer.removeAll(keepingCapacity: true) }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { @Sendable _ in worker.cancel(); session.invalidateAndCancel() }
            }
            return GatewayResponse(statusCode: response.statusCode, chunks: stream)
        } catch { session.invalidateAndCancel(); throw error }
    }
}

public struct GatewayWireEvent: Codable, Sendable {
    public var operation_id: UUID
    public var runtime_epoch: Int
    public var sequence: Int
    public var reality: ExecutionReality
    public var type: String
    public var text: String?
    public var provider_operation_id: String?
    public var final_text_hash: String?
    public var finish_reason: MessageFinishReason?
    public var receipt_reference: String?
    public var code: String?
    public var retryable: Bool?
    public var retry_after_seconds: Int?
    public var index: Int?
    public var id: String?
    public var name: String?
    public var arguments: String?
    public func providerEvent() throws -> ProviderEvent? {
        let payload: ProviderEventPayload
        switch type {
        case "text_delta": guard let text else { throw catError.corrupt("Missing text delta.") }; payload = .textDelta(text)
        case "accepted": payload = .accepted(providerOperationID: provider_operation_id ?? "unreported")
        case "message_completed":
            guard let final_text_hash, let finish_reason else { throw catError.corrupt("Missing message terminal fields.") }
            payload = .messageCompleted(finalTextHash: final_text_hash, finishReason: finish_reason)
        case "task_completed": guard let receipt_reference else { throw catError.corrupt("Missing task receipt.") }; payload = .taskCompleted(receiptReference: receipt_reference)
        case "cancelled": payload = .cancelled
        case "outcome_unknown": payload = .outcomeUnknown
        case "failed": payload = .failed(ProviderFailure(code: code ?? "gateway_failed", displayMessage: "Gateway: \(code ?? "failed")", retryable: retryable ?? false, retryAfterSeconds: retry_after_seconds))
        case "tool_call_delta", "tool_call_complete": return nil // proposal only; no executor or permission granted
        default: throw catError.corrupt("Unsupported gateway event.")
        }
        return ProviderEvent(operationID: operation_id, sequence: sequence, runtimeEpoch: runtime_epoch, reality: reality, payload: payload)
    }
}

public struct GatewaySSEDecoder {
    private var buffer = Data()
    private var fields: [String] = []
    public init() {}
    public mutating func feed(_ data: Data) throws -> [GatewayWireEvent] {
        buffer.append(data); var events: [GatewayWireEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            guard let value = String(data: line, encoding: .utf8) else { throw catError.corrupt("Invalid UTF8 SSE.") }
            if value.isEmpty {
                if !fields.isEmpty {
                    events.append(try JSONDecoder().decode(GatewayWireEvent.self, from: Data(fields.joined(separator: "\n").utf8)))
                    fields = []
                }
            } else if value.hasPrefix("data:") {
                let field = value.dropFirst(5); fields.append(String(field.first == " " ? field.dropFirst() : field))
            }
            if fields.joined(separator: "\n").utf8.count > 1024 * 1024 { throw catError.corrupt("SSE frame too large.") }
        }
        guard buffer.count <= 1024 * 1024 else { throw catError.corrupt("SSE frame too large.") }
        return events
    }
    public func finish() throws {
        guard buffer.isEmpty, fields.isEmpty else { throw catError.corrupt("SSE ended inside a frame.") }
    }
}

private struct GatewayChatAdmission: Encodable {
    let operation_id: UUID
    let runtime_epoch: Int
    let model_id: String
    let text: String
    let frozen_text_hash: String
    let scope: GatewayScope
}
public struct GatewayScope: Codable, Sendable {
    public let profile_id: UUID
    public let workspace_id: UUID
    public init(_ scope: DataScope) { profile_id = scope.profileID; workspace_id = scope.workspaceID }
    public var native: DataScope { DataScope(profileID: profile_id, workspaceID: workspace_id) }
}

public actor GatewayAgentProvider: AgentProvider {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayTransport
    private let credentials: any GatewaySessionCredentialProvider
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var workerContexts: [UUID: ProviderContext] = [:]
    public init(configuration: GatewayConfiguration, transport: any GatewayTransport = URLSessionGatewayTransport(), credentials: any GatewaySessionCredentialProvider = UnconfiguredGatewayCredentials()) {
        self.configuration = configuration; self.transport = transport; self.credentials = credentials
    }
    public func descriptor() async -> ProviderDescriptor {
        ProviderDescriptor(id: configuration.providerID, version: "1", capabilities: [ProviderCapability(capabilityID: "text_reply", availability: configuration.localSynthetic ? .fixtureAvailable : .unverified, requiredAuthorizationKinds: configuration.localSynthetic ? [] : ["gateway_session"])])
    }
    public func reply(to request: ChatRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        guard request.context.providerID == configuration.providerID, request.frozenTextHash == textHash(request.frozenText),
              ["qwen-beijing", "dots-free", "nemotron-free", "glm-flash"].contains(request.frozenConfiguration.configuration.model),
              !configuration.localSynthetic || request.context.scope == Profiles.demo else { throw catError.invalid("Gateway request identity, scope or explicit model is invalid.") }
        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/chat"))
        urlRequest.httpMethod = "POST"; urlRequest.timeoutInterval = 35
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if configuration.localSynthetic { urlRequest.setValue("synthetic-only", forHTTPHeaderField: "X-Catpaw-Demo") }
        else { urlRequest.setValue(try await credentials.sessionAuthorization(), forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try JSONEncoder().encode(GatewayChatAdmission(operation_id: request.context.operationID, runtime_epoch: request.context.runtimeEpoch,
            model_id: request.frozenConfiguration.configuration.model, text: request.frozenText, frozen_text_hash: request.frozenTextHash, scope: GatewayScope(request.context.scope)))
        let transport = self.transport, expected = configuration.expectedReality, operation = request.context.operationID
        guard workers[operation] == nil else { throw catError.conflict }
        return AsyncThrowingStream { continuation in
            let worker = Task {
                defer { self.removeWorker(operation) }
                do {
                    let response = try await transport.open(urlRequest)
                    guard response.statusCode == 200 else { throw catError.unavailable("Gateway HTTP \(response.statusCode).") }
                    var decoder = GatewaySSEDecoder(), lastSequence = 0, terminal = false, messageFinished = false, accumulated = "", sawTool = false
                    var accepted = expected == .simulated, finishReason: MessageFinishReason?
                    for try await data in response.chunks {
                        try Task.checkCancellation()
                        for wire in try decoder.feed(data) {
                            let unknownFailure = expected == .remoteAccepted && wire.reality == .unknown && ["failed", "cancelled", "outcome_unknown"].contains(wire.type)
                            guard wire.operation_id == operation, wire.runtime_epoch == request.context.runtimeEpoch,
                                  wire.sequence > lastSequence, wire.reality == expected || unknownFailure, !terminal else { throw catError.corrupt("Gateway event identity/reality/sequence mismatch.") }
                            if wire.type == "accepted" { accepted = true }
                            guard accepted || unknownFailure else { throw catError.corrupt("Gateway data preceded remote acceptance.") }
                            lastSequence = wire.sequence
                            if wire.type.hasPrefix("tool_call_") { sawTool = true; continue }
                            if wire.type == "text_delta" {
                                guard !messageFinished else { throw catError.corrupt("Delta after message terminal.") }; accumulated += wire.text ?? ""
                            }
                            if wire.type == "message_completed" {
                                guard !messageFinished, wire.final_text_hash == textHash(accumulated) else { throw catError.corrupt("Gateway final text hash mismatch.") }; messageFinished = true; finishReason = wire.finish_reason
                            }
                            if wire.type == "task_completed" {
                                guard messageFinished, !sawTool, finishReason == .stop else { throw catError.corrupt("Gateway task terminal without completed text or tool policy.") }; terminal = true
                            }
                            if ["failed", "cancelled", "outcome_unknown"].contains(wire.type) { terminal = true }
                            if let event = try wire.providerEvent() { continuation.yield(event) }
                        }
                    }
                    try decoder.finish()
                    guard terminal else { throw catError.unavailable("Gateway ended without an explicit task terminal.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            workers[operation] = worker
            workerContexts[operation] = request.context
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
    private func removeWorker(_ operation: UUID) { workers.removeValue(forKey: operation); workerContexts.removeValue(forKey: operation) }
    public func start(_ request: TaskRequest) async throws -> AsyncThrowingStream<ProviderEvent, Error> { throw catError.unavailable("Use the delegation service; chat admission does not authorize a task.") }
    public func observe(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent { throw catError.unavailable("Use the gateway observe endpoint; no verified result is inferred locally.") }
    public func cancel(operationID: EntityID, context: ProviderContext) async throws -> ProviderEvent {
        guard let saved = workerContexts[operationID], context.operationID == operationID,
              context.scope == saved.scope, context.runtimeEpoch == saved.runtimeEpoch,
              context.providerID == configuration.providerID else { throw catError.conflict }
        workers[operationID]?.cancel()
        return ProviderEvent(operationID: operationID, sequence: 1, runtimeEpoch: context.runtimeEpoch, reality: configuration.expectedReality, payload: .cancelled)
    }
}
