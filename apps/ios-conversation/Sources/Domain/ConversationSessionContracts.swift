import Foundation

public enum ConversationSessionError: Error, LocalizedError, Sendable {
    case notConfigured, unresolvedOperation, invalidEvent, busy, pendingUnsent
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "模型尚未连接。输入已保留，请先完成模型连接。"
        case .unresolvedOperation: return "上次请求结果尚未确认。先读取原请求状态，不重复创建。"
        case .invalidEvent: return "服务返回了不匹配的对话或工具结果，未记录成功。"
        case .busy: return "当前对话正在处理上一条消息。"
        case .pendingUnsent: return "这条消息尚未发送。继续发送原消息，或先移除再编辑。"
        }
    }
}
/// Use only when the adapter proves it did not initiate a turn POST.
public enum ConversationDispatchFailure: Error, LocalizedError, Sendable {
    case notSent(reason: String)
    public var errorDescription: String? { if case .notSent(let reason) = self { return "消息尚未发送，输入已保留。" + reason }; return nil }
}
public struct ConversationConnection: Codable, Sendable {
    public enum State: String, Codable, Sendable { case notConfigured = "not_configured", providerUnverified = "provider_unverified", connected, unavailable }
    public let state: State
    public let provider: String
    public let model: String?
    public let detail: String
    public init(state: State, provider: String, model: String? = nil, detail: String) { self.state = state; self.provider = provider; self.model = model; self.detail = detail }
}
public struct ConversationTranscriptMessage: Codable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }
    public let id: UUID
    public let role: Role
    public var content: String
    public let toolCallID: String?
    public let toolName: String?
    public var complete: Bool
    public var failure: String? = nil
    public init(id: UUID = UUID(), role: Role, content: String, toolCallID: String? = nil, toolName: String? = nil, complete: Bool = true) {
        self.id = id; self.role = role; self.content = content; self.toolCallID = toolCallID; self.toolName = toolName; self.complete = complete
    }
}
public struct ConversationGoalProjection: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, working, waitingInput = "waiting_input", completed, failed, paused, cancelled, unknown }
    public let id: String
    public let revision: Int
    public let title: String
    public let state: State
    public let summary: String
    public let updatedAt: Date
    public var binding: ConversationTaskBinding? = nil
    public var artifacts: [ConversationArtifactProjection] = []
    public var artifactHistory: [ConversationArtifactProjection] = []
    public init(id: String, revision: Int, title: String, state: State, summary: String, updatedAt: Date) { self.id = id; self.revision = revision; self.title = title; self.state = state; self.summary = summary; self.updatedAt = updatedAt }
}
public struct ConversationTaskBinding: Codable, Sendable, Equatable {
    public let scope_id: UUID
    public let conversation_id: UUID
    public let turn_id: UUID
    public let call_id: String
    public let delegation_id: UUID
    public let operation_id: UUID
    public let run_id: UUID
    public let task_id: String
    public let request_hash: String
    public let delegation_revision: Int
    public let grant_epoch: Int
    public let projection_url: String
}
public struct ConversationArtifactProjection: Codable, Sendable, Identifiable {
    public let id: String
    public let version: Int
    public let contentHash: String
    public let body: String
    public let title: String
    public let summary: String
    public let content: String
}
public struct ConversationExplicitContext: Codable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}
public struct ConversationToolResult: Codable, Sendable {
    public let callID: String
    public let name: String
    public let content: String
    /// Only confirmed persistent service projections can populate this list. Tool arguments cannot.
    public let committedGoals: [ConversationGoalProjection]
    public init(callID: String, name: String, content: String, committedGoals: [ConversationGoalProjection] = []) { self.callID = callID; self.name = name; self.content = content; self.committedGoals = committedGoals }
}
public struct ConversationTurnRequest: Codable, Sendable {
    public let scope: DataScope
    public let conversationID: UUID
    public let threadID: String?
    public let operationID: UUID
    public let epoch: Int
    public let history: [ConversationTranscriptMessage]
    public let context: [ConversationExplicitContext]
    public init(scope: DataScope, conversationID: UUID, threadID: String?, operationID: UUID, epoch: Int, history: [ConversationTranscriptMessage], context: [ConversationExplicitContext] = []) { self.scope = scope; self.conversationID = conversationID; self.threadID = threadID; self.operationID = operationID; self.epoch = epoch; self.history = history; self.context = context }
}
public struct ConversationTurnEvent: Sendable {
    public enum Payload: Sendable {
        case thread(String), started(requestHash: String, conversationRevision: Int, grantEpoch: Int), textDelta(messageID: UUID, text: String), toolStarted(callID: String, name: String, arguments: String)
        case toolResult(ConversationToolResult), completed(messageID: UUID, finalTextHash: String), failed(message: String, reconciliationRequired: Bool)
    }
    public let operationID: UUID
    public let epoch: Int
    public let sequence: Int
    public let payload: Payload
    public init(operationID: UUID, epoch: Int, sequence: Int, payload: Payload) { self.operationID = operationID; self.epoch = epoch; self.sequence = sequence; self.payload = payload }
}
public struct ConversationTurnRecord: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case dispatched, running, completed, failed, unknown, notSent, cancelledBeforeSend }
    public let id: UUID
    public let request: ConversationTurnRequest
    public var state: State
    public var lastSequence: Int
    public var error: String?
    public var assistantMessageID: UUID? = nil
    public var serverRequestHash: String? = nil
    public var serverGrantEpoch: Int? = nil
    public var serverConversationRevision: Int? = nil
}
public struct ConversationSession: Codable, Sendable {
    public let scope: DataScope
    public let conversationID: UUID
    public var threadID: String?
    public var messages: [ConversationTranscriptMessage]
    public var goals: [String: ConversationGoalProjection]
    public var turns: [ConversationTurnRecord]
    public init(scope: DataScope, conversationID: UUID) { self.scope = scope; self.conversationID = conversationID; messages = []; goals = [:]; turns = [] }
    public var unresolved: ConversationTurnRecord? { turns.last(where: { [.dispatched, .running, .unknown].contains($0.state) }) }
    public var pendingUnsent: ConversationTurnRecord? { turns.last(where: { $0.state == .notSent }) }
}
public struct ConversationObservation: Sendable {
    public let request: ConversationTurnRequest
    public let events: [ConversationTurnEvent]
    public let requestHash: String?
    public let grantEpoch: Int?
    public let goals: [ConversationGoalProjection]
    public init(request: ConversationTurnRequest, events: [ConversationTurnEvent], requestHash: String? = nil, grantEpoch: Int? = nil, goals: [ConversationGoalProjection] = []) { self.request = request; self.events = events; self.requestHash = requestHash; self.grantEpoch = grantEpoch; self.goals = goals }
}
/// Client projection seam, not a new Agent engine. A verified server adapter supplies the wire.
public struct ConversationModelConsent: Sendable, Identifiable {
    public var id: UUID { conversationID }
    public let conversationID: UUID
    public let title: String
    public let body: String
    public let routeHash: String
    public let expectedRevision: Int
}
public protocol ConversationBackend: Sendable {
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent?
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws
    func connection(scope: DataScope) async -> ConversationConnection
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error>
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation
}
public struct UnconfiguredConversationBackend: ConversationBackend {
    public init() {}
    public func connection(scope: DataScope) async -> ConversationConnection {
        ConversationConnection(state: .notConfigured, provider: "OpenRouter", detail: "调试平台已选；API key 与后台对话连接尚未配置。")
    }
    public func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { throw ConversationSessionError.notConfigured }
    public func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation { throw ConversationSessionError.notConfigured }
}

public extension ConversationBackend {
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? { nil }
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws { throw ConversationSessionError.notConfigured }
}
