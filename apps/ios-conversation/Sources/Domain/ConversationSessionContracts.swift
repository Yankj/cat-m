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
    public let verifiedReplyAt:Date?
    public init(state: State, provider: String, model: String? = nil, detail: String,verifiedReplyAt:Date?=nil) { self.state = state; self.provider = provider; self.model = model; self.detail = detail;self.verifiedReplyAt=verifiedReplyAt }
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
    public var image:ConversationImageReceipt? = nil
    public init(id: UUID = UUID(), role: Role, content: String, toolCallID: String? = nil, toolName: String? = nil, complete: Bool = true,image:ConversationImageReceipt?=nil) {
        self.image=image;self.id = id; self.role = role; self.content = content; self.toolCallID = toolCallID; self.toolName = toolName; self.complete = complete
    }
}
public struct ConversationRevisionWorkPolicy:Codable,Sendable,Equatable {
    public let toolPolicy:ConversationAcceptedWorkToolPolicy,sourceCount:Int
    private enum CodingKeys:String,CodingKey {case toolPolicy="tool_policy",sourceCount="source_count"}
    public init(toolPolicy:ConversationAcceptedWorkToolPolicy,sourceCount:Int) {self.toolPolicy=toolPolicy;self.sourceCount=sourceCount}
    public func validate() throws {guard (0...3).contains(sourceCount),(toolPolicy == .localOutput ? sourceCount==0:sourceCount>0) else {throw ConversationSessionError.invalidEvent}}
    public func validate(options:ConversationAcceptedWorkOptions) throws {try validate();try options.validate();guard options.toolPolicy==toolPolicy,options.sourceLimit>=sourceCount else {throw ConversationAcceptedWorkError.invalidSelection}}
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
    /// A negative source observation fences this frozen binding; it never grants execution.
    public var sourceAuthorizationCurrent: Bool? = nil
    public var planReference: ConversationArtifactEditPlanReference? = nil
    public var revisionRequiresNewWork:Bool? = nil
    public var revisionWorkPolicy:ConversationRevisionWorkPolicy? = nil
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
    public let continuationReceipt: ConversationTaskRevisionReceipt?
    public let memoryProposalReceipt:ConversationMemoryProposalReceipt?
    public let revisionWorkReceipt:ConversationRevisionWorkReceipt?
    public init(callID: String, name: String, content: String, committedGoals: [ConversationGoalProjection] = [], continuationReceipt: ConversationTaskRevisionReceipt? = nil,memoryProposalReceipt:ConversationMemoryProposalReceipt?=nil,revisionWorkReceipt:ConversationRevisionWorkReceipt?=nil) {self.revisionWorkReceipt=revisionWorkReceipt; self.callID = callID; self.name = name; self.content = content; self.committedGoals = committedGoals; self.continuationReceipt=continuationReceipt;self.memoryProposalReceipt=memoryProposalReceipt }
}
/// A fresh turn's immutable link to the original task. Acceptance is not task completion.
public struct ConversationTaskRevisionReceipt:Codable,Sendable,Equatable {
    public let operation_id:String,operation_hash:String,scope_id:String,subject_id:String,conversation_id:String,turn_id:String,call_id:String,run_id:String,task_id:String
    public let base_reference:ConversationArtifactVersionReference
    public let base_plan_reference:ConversationArtifactEditPlanReference
    public let accepted_plan_reference:ConversationArtifactEditPlanReference
    public let instruction_hash:String,source_auth_hash:String,fresh_source_auth_hash:String
    public let grant_epoch:Int
    public let accepted_at:String,receipt_hash:String,state:String
    public let result_reference:ConversationArtifactVersionReference?
    public let result_receipt_hash:String?
    public static let immutableKeys:Set<String>=["operation_id","operation_hash","scope_id","subject_id","conversation_id","turn_id","call_id","run_id","task_id","base_reference","base_plan_reference","accepted_plan_reference","instruction_hash","source_auth_hash","fresh_source_auth_hash","grant_epoch","accepted_at"]
    public func immutableHash() throws -> String {
        guard case .object(var value)=try ConversationTaskActionJSON.value(self) else {throw ConversationSessionError.invalidEvent}
        for key in ["state","result_reference","result_receipt_hash","receipt_hash"] {value.removeValue(forKey:key)}
        return try ConversationTaskActionJSON.object(value).digest()
    }
    /// The controlled relation is attached by the publication transaction, never model text.
    /// Corrected intermediate reports can produce more than one version within this operation.
    public func matchesModelArtifact(_ artifact:ConversationArtifactProjection) -> Bool {
        guard artifact.id==base_reference.artifactID,artifact.version>base_reference.version,artifact.version-base_reference.version<=32,
              textHash(artifact.body)==artifact.contentHash,
              let root=try? ConversationStrictJSON.object(Data(artifact.body.utf8),maxBytes:1_000_000),root["kind"] as? String=="report",
              let data=root["data"] as? [String:Any],data["source"] as? String != "user_revision",
              let relation=data["model_revision"] as? [String:Any],Set(relation.keys)==["operation_id","operation_hash","base_reference","plan_reference","instruction_hash"],
              relation["operation_id"] as? String==operation_id,relation["operation_hash"] as? String==operation_hash,relation["instruction_hash"] as? String==instruction_hash,
              let base=relation["base_reference"],let plan=relation["plan_reference"],
              (try? JSONDecoder().decode(ConversationArtifactVersionReference.self,from:JSONSerialization.data(withJSONObject:base)))==base_reference,
              (try? JSONDecoder().decode(ConversationArtifactEditPlanReference.self,from:JSONSerialization.data(withJSONObject:plan)))==accepted_plan_reference else {return false}
        return true
    }
    public func permitsCurrentPlan(_ plan:ConversationArtifactEditPlanReference?) -> Bool {
        guard let plan,(try? plan.validate()) != nil else {return false}
        return plan==accepted_plan_reference || plan.revision>accepted_plan_reference.revision
    }
    public func validate(request:ConversationTurnRequest,callID:String,sourceAuthHash:String?=nil) throws {
        guard let target=request.continuation,target.intent == .reviseReport,let binding=request.continuationOriginalBinding,let subject=request.continuationSubjectID,
              [operation_id,scope_id,subject_id,conversation_id,turn_id,run_id].allSatisfy(ConversationTaskActionValidation.uuid),
              [operation_hash,instruction_hash,source_auth_hash,fresh_source_auth_hash,receipt_hash].allSatisfy(ConversationTaskActionValidation.hash),
              scope_id==binding.scope_id.uuidString.lowercased(),subject_id==subject.uuidString.lowercased(),conversation_id==request.conversationID.uuidString.lowercased(),
              turn_id==request.operationID.uuidString.lowercased(),call_id==callID,!call_id.isEmpty,call_id.utf8.count<=256,
              run_id==target.runID.uuidString.lowercased(),run_id==binding.run_id.uuidString.lowercased(),task_id==target.taskID,task_id==binding.task_id,
              base_reference==target.artifactReference,base_plan_reference.revision==target.expectedPlanRevision,base_plan_reference.planHash==target.expectedPlanHash,
              target.expectedPlanRevision<9_007_199_254_740_991,accepted_plan_reference.revision==target.expectedPlanRevision+1,
              grant_epoch==target.expectedGrantEpoch,grant_epoch==binding.grant_epoch,
              ConversationTaskActionValidation.utc(accepted_at) != nil,["accepted","completed","blocked_unknown"].contains(state),
              sourceAuthHash==nil || source_auth_hash==sourceAuthHash,
              let raw=request.history.last?.content,instruction_hash==textHash(raw),
              try immutableHash()==receipt_hash else {throw ConversationSessionError.invalidEvent}
        try target.validate();try base_reference.validate();try base_plan_reference.validate();try accepted_plan_reference.validate()
        let digest=textHash("\(turn_id):\(call_id):catpaw.task-revision.v1")
        let expected="\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-4\(digest.dropFirst(13).prefix(3))-8\(digest.dropFirst(17).prefix(3))-\(digest.dropFirst(20).prefix(12))"
        guard operation_id==expected,![request.operationID,binding.conversation_id,binding.turn_id,binding.delegation_id,binding.operation_id,binding.run_id].map({$0.uuidString.lowercased()}).contains(operation_id) else {throw ConversationSessionError.invalidEvent}
        if state=="completed" {
            guard let result_reference,let result_receipt_hash,ConversationTaskActionValidation.hash(result_receipt_hash),result_reference.artifactID==base_reference.artifactID,result_reference.version>base_reference.version,result_reference.version-base_reference.version<=32 else {throw ConversationSessionError.invalidEvent};try result_reference.validate()
        } else {guard result_reference==nil,result_receipt_hash==nil else {throw ConversationSessionError.invalidEvent}}
    }
}
public struct ConversationTurnRequest: Codable, Sendable {
    public let scope: DataScope
    public let conversationID: UUID
    public let threadID: String?
    public let operationID: UUID
    public let epoch: Int
    public let history: [ConversationTranscriptMessage]
    public let context: [ConversationExplicitContext]
    public let image:ConversationVisionReference?
    public let continuation: ConversationArtifactContinuationIntent?
    public let continuationOriginalBinding: ConversationTaskBinding?
    public let continuationSubjectID: UUID?
    public let acceptedWork:ConversationAcceptedWorkIntent?
    public let revisionWork:ConversationRevisionWorkIntent?
    public private(set) var imageBytes:Data? = nil
    private enum CodingKeys:String,CodingKey {case scope,conversationID,threadID,operationID,epoch,history,context,image,continuation,continuationOriginalBinding,continuationSubjectID,acceptedWork,revisionWork}
    public func withImageBytes(_ bytes:Data?) -> Self {var value=self;value.imageBytes=bytes;return value}
    public init(scope: DataScope, conversationID: UUID, threadID: String?, operationID: UUID, epoch: Int, history: [ConversationTranscriptMessage], context: [ConversationExplicitContext] = [],image:ConversationVisionReference?=nil,imageBytes:Data?=nil,continuation:ConversationArtifactContinuationIntent?=nil,continuationOriginalBinding:ConversationTaskBinding?=nil,continuationSubjectID:UUID?=nil,acceptedWork:ConversationAcceptedWorkIntent?=nil,revisionWork:ConversationRevisionWorkIntent?=nil) {self.revisionWork=revisionWork; self.acceptedWork=acceptedWork;self.continuation=continuation;self.continuationOriginalBinding=continuationOriginalBinding;self.continuationSubjectID=continuationSubjectID;self.image=image;self.imageBytes=imageBytes;self.scope = scope; self.conversationID = conversationID; self.threadID = threadID; self.operationID = operationID; self.epoch = epoch; self.history = history; self.context = context }
    public func withRevisionWork(_ intent:ConversationRevisionWorkIntent) throws -> Self {
        guard acceptedWork==nil,revisionWork==nil || revisionWork==intent else {throw ConversationAcceptedWorkError.invalidFrozenIntent};try intent.validate(request:self)
        return .init(scope:scope,conversationID:conversationID,threadID:threadID,operationID:operationID,epoch:epoch,history:history,context:context,image:image,imageBytes:imageBytes,continuation:continuation,continuationOriginalBinding:continuationOriginalBinding,continuationSubjectID:continuationSubjectID,revisionWork:intent)
    }
    public func withAcceptedWork(_ intent:ConversationAcceptedWorkIntent) throws -> Self {
        guard revisionWork==nil,acceptedWork==nil || acceptedWork==intent else {throw ConversationAcceptedWorkError.invalidFrozenIntent};try intent.validate(request:self)
        return .init(scope:scope,conversationID:conversationID,threadID:threadID,operationID:operationID,epoch:epoch,history:history,context:context,image:image,imageBytes:imageBytes,continuation:continuation,continuationOriginalBinding:continuationOriginalBinding,continuationSubjectID:continuationSubjectID,acceptedWork:intent)
    }
}
public struct ConversationTurnEvent: Sendable {
    public enum Payload: Sendable {
        case thread(String), started(requestHash: String, conversationRevision: Int, grantEpoch: Int,attachmentReceipts:[ConversationImageReceipt]?=nil), textDelta(messageID: UUID, text: String), toolStarted(callID: String, name: String, arguments: String)
        case toolResult(ConversationToolResult), completed(messageID: UUID, finalTextHash: String,visionReceipt:ConversationVisionProviderReceipt?=nil), failed(message: String, reconciliationRequired: Bool)
        /// R7 optional wire event `reasoning_summary`: provider thought summary, before first text_delta.
        case reasoningSummary(messageID: UUID, text: String, thinkingMs: Int?)
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
    public var visionProviderReceipt:ConversationVisionProviderReceipt? = nil
    public var continuationReceipt:ConversationTaskRevisionReceipt? = nil
    public var revisionWorkReceipt:ConversationRevisionWorkReceipt? = nil
    /// R7 thinking row source (presentation lane renders it).
    public var reasoningSummary:String? = nil
    public var thinkingMs:Int? = nil
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
    func revisionWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability
    func freezeRevisionWork(_ request:ConversationTurnRequest,selection:ConversationRevisionWorkSelection) async throws -> ConversationRevisionWorkIntent
    func acceptedWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability
    func ensureConversationForExplicitSend(_ request:ConversationTurnRequest) async throws
    func freezeAcceptedWork(_ request:ConversationTurnRequest,selection:ConversationAcceptedWorkSelection) async throws -> ConversationAcceptedWorkIntent
    var supportsArtifactContinuations:Bool {get}
    var artifactContinuationSubjectID:UUID? {get}
    func imageCapabilities(scope:DataScope,conversationID:UUID) async throws -> ConversationImageCapability
    func imageConsent(scope:DataScope,conversationID:UUID,previewID:UUID,previewHash:String) async throws -> ConversationImageConsent
    func allowImageConsent(scope:DataScope,consent:ConversationImageConsent,nonSensitiveConfirmed:Bool) async throws -> Int
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent?
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws
    func connection(scope: DataScope) async -> ConversationConnection
    func recordCommittedReply(_ request:ConversationTurnRequest) async
    func recordedReplyEvidence(scope:DataScope) async -> ConversationConnection?
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error>
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation
    /// R7 §5.3 resume: GET the original turn's events after `afterSequence` (never re-POSTs).
    func resumeEvents(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error>
}
/// Stream-health sink (ConnectionMonitor in the App target). Domain-only so portable builds stay Network-free.
public protocol ConversationStreamResilience: Sendable {
    func waitForPath() async
    func reconnecting(attempt: Int, retryIn: Double) async
    func resumed() async
    func unreachable() async
    func settled() async
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
    func resumeEvents(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { throw ConversationSessionError.unresolvedOperation }
    func revisionWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {.init()}
    func freezeRevisionWork(_ request:ConversationTurnRequest,selection:ConversationRevisionWorkSelection) async throws -> ConversationRevisionWorkIntent {throw ConversationAcceptedWorkError.unavailable}
    func acceptedWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {.init()}
    func ensureConversationForExplicitSend(_ request:ConversationTurnRequest) async throws {}
    func freezeAcceptedWork(_ request:ConversationTurnRequest,selection:ConversationAcceptedWorkSelection) async throws -> ConversationAcceptedWorkIntent {throw ConversationAcceptedWorkError.unavailable}
    var supportsArtifactContinuations:Bool {false}
    var artifactContinuationSubjectID:UUID? {nil}
    func recordCommittedReply(_ request:ConversationTurnRequest) async {}
    func recordedReplyEvidence(scope:DataScope) async -> ConversationConnection? {nil}
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? { nil }
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws { throw ConversationSessionError.notConfigured }
}
