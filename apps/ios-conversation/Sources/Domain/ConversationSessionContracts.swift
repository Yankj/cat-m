import Foundation
#if canImport(os)
import os
private let sendDiagnosticLog=Logger(subsystem:"catpaw",category:"send")
#endif
/// Metadata-only send diagnostics (roles, short ids, statuses, lengths; never message text).
public func sendDiagnostic(_ line:String) {
    #if canImport(os)
    sendDiagnosticLog.error("\(line, privacy: .public)")
    #endif
}

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
    /// When this message entered the transcript. Turn events carry no server timestamp today, so this is
    /// the local journal append time (first append; streaming deltas keep it). A future server-sent time
    /// should be passed explicitly. Journals written before this field decode as `.distantPast` (sorts first).
    public let createdAt: Date
    public init(id: UUID = UUID(), role: Role, content: String, toolCallID: String? = nil, toolName: String? = nil, complete: Bool = true,image:ConversationImageReceipt?=nil,createdAt:Date=Date()) {
        self.image=image;self.id = id; self.role = role; self.content = content; self.toolCallID = toolCallID; self.toolName = toolName; self.complete = complete;self.createdAt=createdAt
    }
    private enum CodingKeys: String, CodingKey { case id, role, content, toolCallID, toolName, complete, failure, image, createdAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); role = try c.decode(Role.self, forKey: .role); content = try c.decode(String.self, forKey: .content)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID); toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        complete = try c.decode(Bool.self, forKey: .complete)
        failure = try c.decodeIfPresent(String.self, forKey: .failure); image = try c.decodeIfPresent(ConversationImageReceipt.self, forKey: .image)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
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
    /// catpaw.approval.v1 `tool_result.status`: "ok", "denied" (user denied / approval expired / cancelled; not executed) or "error". nil from older servers.
    public var status:String? = nil
    public init(callID: String, name: String, content: String, committedGoals: [ConversationGoalProjection] = [], continuationReceipt: ConversationTaskRevisionReceipt? = nil,memoryProposalReceipt:ConversationMemoryProposalReceipt?=nil,revisionWorkReceipt:ConversationRevisionWorkReceipt?=nil) {self.revisionWorkReceipt=revisionWorkReceipt; self.callID = callID; self.name = name; self.content = content; self.committedGoals = committedGoals; self.continuationReceipt=continuationReceipt;self.memoryProposalReceipt=memoryProposalReceipt }
}
extension ConversationToolResult { public func withStatus(_ status:String?) -> Self { var copy=self; copy.status=status; return copy } }
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
    /// catpaw.chat-attachments.v1: ready attachment ids sent as schema_version 2 `message.attachment_ids` (plain turns only).
    /// Single use on the server: a resend of a FAILED turn needs a new upload under new ids (ChatAttachmentSendCoordinator).
    public private(set) var attachmentIDs:[UUID]? = nil
    private enum CodingKeys:String,CodingKey {case scope,conversationID,threadID,operationID,epoch,history,context,image,continuation,continuationOriginalBinding,continuationSubjectID,acceptedWork,revisionWork,attachmentIDs}
    public func withImageBytes(_ bytes:Data?) -> Self {var value=self;value.imageBytes=bytes;return value}
    public func withAttachmentIDs(_ ids:[UUID]?) -> Self {var value=self;value.attachmentIDs=(ids?.isEmpty ?? true) ? nil : ids;return value}
    public var hasUploadedAttachments:Bool {!(attachmentIDs ?? []).isEmpty}
    /// Re-anchors a plain (not work-frozen) unsent request on the current dispatchable history.
    public func withHistory(_ history:[ConversationTranscriptMessage]) -> Self {
        let value=Self(scope:scope,conversationID:conversationID,threadID:threadID,operationID:operationID,epoch:epoch,history:history,context:context,image:image,imageBytes:imageBytes,continuation:continuation,continuationOriginalBinding:continuationOriginalBinding,continuationSubjectID:continuationSubjectID)
        return value.withAttachmentIDs(attachmentIDs)
    }
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
        /// catpaw.approval.v1 `approval_requested`: a tool call waits for the user's decision (follows its `toolStarted`).
        case approvalRequested(ConversationApprovalRequest)
        /// catpaw.approval.v1 `turn_suspended`: the turn waits for decisions. NOT terminal; the stream ends here.
        case suspended(interruptIDs: [String], expiresAt: String)
        /// catpaw.approval.v1 `approval_resolved`: decision is "approved", "denied", "expired" or "cancelled".
        case approvalResolved(interruptID: String, callID: String, decision: String, remember: Bool)
        /// catpaw.ui.v1 `ui.block` (new block; `interruptID` set when it waits for `submitUIDecision`).
        case uiBlock(ConversationUIEvent)
        /// catpaw.ui.v1 `ui.block.update`: shallow merge into the block with the same id.
        case uiBlockUpdate(ConversationUIEvent)
        /// catpaw.ui.v1 `ui.block.resolve`: `status` is submitted, dismissed, error, expired or cancelled.
        case uiBlockResolve(ConversationUIEvent)
        /// catpaw.device.v1 `device_call`: run a tool on this phone, then `submitDeviceResult` (the turn is suspended until then).
        case deviceCall(ConversationDeviceCall)
        /// Side-channel wire events with no transcript effect (`memory.used`, `memory.update`, `memory_recalled`,
        /// `proactive_suggestion`). They still occupy a sequence number, so they must be decoded, not dropped.
        /// The raw `data` object is forwarded to `ConversationSideChannelEvents.handler` by the backend.
        case sideChannel(type: String, data: Data)
    }
    public let operationID: UUID
    public let epoch: Int
    public let sequence: Int
    public let payload: Payload
    /// Advisory busy delay from `turn_failed{code:rate_limited, retry_after_seconds}` (R7 busy card).
    public let retryAfterSeconds: Int?
    /// Conversation of this event; nil only from backends/tests that predate the field. The session service always fills it.
    public let conversationID: UUID?
    /// Server turn id (`turn_id` on the wire; equals `operationID` for native-chat turns). Nil only from older producers.
    public let turnID: UUID?
    public init(operationID: UUID, epoch: Int, sequence: Int, payload: Payload, retryAfterSeconds: Int? = nil, conversationID: UUID? = nil, turnID: UUID? = nil) { self.operationID = operationID; self.epoch = epoch; self.sequence = sequence; self.payload = payload; self.retryAfterSeconds = retryAfterSeconds; self.conversationID = conversationID; self.turnID = turnID }
    /// Same event with routing ids filled (keeps ids already set).
    public func stamped(conversationID: UUID, turnID: UUID) -> ConversationTurnEvent {
        ConversationTurnEvent(operationID: operationID, epoch: epoch, sequence: sequence, payload: payload, retryAfterSeconds: retryAfterSeconds, conversationID: self.conversationID ?? conversationID, turnID: self.turnID ?? turnID)
    }
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
    /// Set when the turn failed with `rate_limited`; drives ConnectionMonitor.busy.
    public var retryAfterSeconds:Int? = nil
    /// catpaw.approval.v1: interrupts still waiting for a decision (state stays `.running`, the server turn is `awaiting_approval`).
    public var pendingApprovals:[ConversationApprovalRequest]? = nil
    /// catpaw.ui.v1 events of this turn, ordered by sequence (journal; replays and resumes are de-duplicated by sequence).
    public var uiEvents:[ConversationUIEvent]? = nil
    /// Waiting ui blocks: `ui.block` with an interrupt and no `ui.block.resolve` yet.
    public var pendingUIBlocks:[ConversationUIEvent] {
        let events = uiEvents ?? [], resolved = Set(events.filter { $0.type == .resolve }.map(\.id))
        return events.filter { $0.waitsForDecision && !resolved.contains($0.id) }
    }
    /// Snapshot `pending_approvals` with kind "ui" (authoritative after observe / cold start).
    public var pendingUIApprovals:[ConversationUIApproval]? = nil
    /// catpaw.device.v1: `device_call`s of this turn still waiting for `POST …/device-result`.
    public var pendingDeviceCalls:[ConversationDeviceCall]? = nil
    public var awaitingApproval:Bool { state == .running && (!(pendingApprovals ?? []).isEmpty || !pendingUIBlocks.isEmpty || !(pendingUIApprovals ?? []).isEmpty || !(pendingDeviceCalls ?? []).isEmpty) }
}
/// catpaw.device.v1 `device_call` (services/edge/docs/device-call-contract.md). `args` is the raw JSON object.
public struct ConversationDeviceCall: Codable, Sendable, Equatable, Identifiable {
    public static let contract = "catpaw.device.v1"
    public static let header = "X-Catpaw-Device-Contract"
    /// The app turns this on once a device-call renderer and executor are installed (DeviceCallHub, #44); off = header not sent, server never offers device tools.
    nonisolated(unsafe) public static var clientEnabled = false
    public static let statuses: Set<String> = ["ok", "cancelled", "denied", "error"]
    public let interruptID: String
    public let callID: String
    public let tool: String
    public let args: Data
    public let confirm: String
    public let ttlSec: Int
    public let argsHash: String
    public let expiresAt: String
    public var id: String { callID }
    public init(interruptID: String, callID: String, tool: String, args: Data, confirm: String, ttlSec: Int, argsHash: String, expiresAt: String) { self.interruptID = interruptID; self.callID = callID; self.tool = tool; self.args = args; self.confirm = confirm; self.ttlSec = ttlSec; self.argsHash = argsHash; self.expiresAt = expiresAt }
    /// The wire JSON in #44's `DeviceCall` shape (`call_id, tool, args, confirm, ttl_sec`) for `JSONDecoder().decode(DeviceCall.self, …)`.
    public var wireJSON: Data {
        let args = (try? JSONSerialization.jsonObject(with: self.args)) ?? [String: Any]()
        return (try? JSONSerialization.data(withJSONObject: ["call_id": callID, "tool": tool, "args": args, "confirm": confirm, "ttl_sec": ttlSec], options: [.sortedKeys])) ?? Data()
    }
}
/// catpaw.approval.v1 interrupt as shown to the user (services/edge/docs/approval-contract.md).
public struct ConversationApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String { interruptID }
    public let interruptID: String
    public let callID: String
    public let tool: String
    /// Server-made one-line argument summary (≤ 240 chars); safe to show.
    public let summary: String
    /// Canonical JSON of the call arguments (sorted keys), for an optional detail view.
    public let arguments: String
    /// Must be echoed in the decision; a mismatch is `approval_stale`.
    public let argsHash: String
    /// ISO-8601 UTC; after it the server resolves the interrupt as `expired` (denied to the model).
    public let expiresAt: String
    /// "local_write", "device_write" or "external_write".
    public let risk: String
    /// True only for first-use classes (create_task/update_task): `.approveAlways` is allowed.
    public let rememberAllowed: Bool
    public init(interruptID: String, callID: String, tool: String, summary: String, arguments: String, argsHash: String, expiresAt: String, risk: String, rememberAllowed: Bool) { self.interruptID = interruptID; self.callID = callID; self.tool = tool; self.summary = summary; self.arguments = arguments; self.argsHash = argsHash; self.expiresAt = expiresAt; self.risk = risk; self.rememberAllowed = rememberAllowed }
}
public enum ConversationApprovalDecision: String, Codable, Sendable { case approve, deny, approveAlways = "approve_always" }
/// catpaw.ui.v1 answer to a waiting block (services/edge/docs/generative-ui-contract.md).
public enum ConversationUIDecision: String, Codable, Sendable { case submit, dismiss, reportError = "report_error" }
/// One catpaw.ui.v1 wire event. `payload` is the server's `data` object byte-for-byte (the renderer decodes it);
/// the key fields are decoded for routing, journal and decisions. Journaled on the turn record by `sequence`.
public struct ConversationUIEvent: Codable, Sendable, Equatable {
    public enum EventType: String, Codable, Sendable { case block = "ui.block", update = "ui.block.update", resolve = "ui.block.resolve" }
    public static let contract = "catpaw.ui.v1"
    public static let header = "X-Catpaw-UI-Contract"
    public static let resolveStatuses: Set<String> = ["submitted", "dismissed", "error", "expired", "cancelled"]
    public static let kinds: Set<String> = ["card", "choices", "confirm", "form", "sheet", "list", "progress"]
    public let type: EventType
    public let sequence: Int
    public let payload: Data
    public let id: String
    public let kind: String?
    public let interruptID: String?
    public let argsHash: String?
    public let expiresAt: String?
    public let status: String?
    public var waitsForDecision: Bool { type == .block && interruptID != nil }
    /// Validates the key fields of one `ui.*` event's `data`; throws `invalidEvent` on anything malformed.
    public static func decode(type raw: String, sequence: Int, payload: Data) throws -> ConversationUIEvent {
        guard let type = EventType(rawValue: raw), sequence > 0, payload.count <= 65536,
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 64 else { throw ConversationSessionError.invalidEvent }
        let kind = object["kind"] as? String, interrupt = object["interruptId"] as? String, hash = object["argsHash"] as? String
        let expires = object["expiresAt"] as? String, status = object["status"] as? String
        switch type {
        case .block:
            guard let kind, kinds.contains(kind), status == nil else { throw ConversationSessionError.invalidEvent }
            if let interrupt { guard UUID(uuidString: interrupt) != nil, let hash, hash.count == 64, expires != nil else { throw ConversationSessionError.invalidEvent } }
            else { guard hash == nil else { throw ConversationSessionError.invalidEvent } }
        case .update:
            guard kind == nil, interrupt == nil, status == nil else { throw ConversationSessionError.invalidEvent }
        case .resolve:
            guard let status, resolveStatuses.contains(status) else { throw ConversationSessionError.invalidEvent }
        }
        return ConversationUIEvent(type: type, sequence: sequence, payload: payload, id: id, kind: kind, interruptID: interrupt?.lowercased(), argsHash: hash, expiresAt: expires, status: status)
    }
    public init(type: EventType, sequence: Int, payload: Data, id: String, kind: String?, interruptID: String?, argsHash: String?, expiresAt: String?, status: String?) {
        self.type = type; self.sequence = sequence; self.payload = payload; self.id = id; self.kind = kind; self.interruptID = interruptID; self.argsHash = argsHash; self.expiresAt = expiresAt; self.status = status
    }
}
/// A pending `kind:"ui"` entry of the turn snapshot's `pending_approvals` (cold-start restore of waiting ui blocks).
/// Server fields: interrupt_id, call_id, tool ("render_ui"), summary, args_hash, expires_at, risk ("none"),
/// remember_allowed (false), kind ("ui"), block (the `ui.block` data incl. interruptId/argsHash/expiresAt), arguments.
public struct ConversationUIApproval: Codable, Sendable, Equatable, Identifiable {
    public var id: String { interruptID }
    public let interruptID: String
    public let callID: String
    public let argsHash: String
    public let expiresAt: String
    public let blockID: String
    public let kind: String
    /// The block exactly as `ui.block` data (re-serialised with sorted keys); feed it to the renderer.
    public let block: Data
    public init(interruptID: String, callID: String, argsHash: String, expiresAt: String, blockID: String, kind: String, block: Data) {
        self.interruptID = interruptID; self.callID = callID; self.argsHash = argsHash; self.expiresAt = expiresAt; self.blockID = blockID; self.kind = kind; self.block = block
    }
    /// Validates one snapshot entry with `kind == "ui"`; the block must agree with the interrupt.
    public static func decode(_ raw: [String: Any]) throws -> ConversationUIApproval {
        guard raw["kind"] as? String == "ui", let id = raw["interrupt_id"] as? String, UUID(uuidString: id) != nil,
              let call = raw["call_id"] as? String, !call.isEmpty, let hash = raw["args_hash"] as? String, hash.count == 64,
              let expires = raw["expires_at"] as? String, let block = raw["block"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: block, options: [.sortedKeys]) else { throw ConversationSessionError.invalidEvent }
        let event = try ConversationUIEvent.decode(type: ConversationUIEvent.EventType.block.rawValue, sequence: 1, payload: data)
        guard event.interruptID == id.lowercased(), event.argsHash == hash, let kind = event.kind else { throw ConversationSessionError.invalidEvent }
        return ConversationUIApproval(interruptID: id.lowercased(), callID: call, argsHash: hash, expiresAt: expires, blockID: event.id, kind: kind, block: data)
    }
    /// From a journaled waiting `ui.block`.
    public init?(_ event: ConversationUIEvent) {
        guard event.waitsForDecision, let interrupt = event.interruptID, let hash = event.argsHash, let kind = event.kind else { return nil }
        self.init(interruptID: interrupt, callID: "", argsHash: hash, expiresAt: event.expiresAt ?? "", blockID: event.id, kind: kind, block: event.payload)
    }
}
extension ConversationApprovalFailure {
    /// User-facing text for approval and catpaw.ui.v1 decisions.
    public var friendlyMessage: String {
        switch self {
        case .transport: return "网络中断，确认可能未送达；会用同一个请求自动重试。"
        case .expired: return "已超过 10 分钟，这个确认已过期，助手会按未确认继续。"
        case .consumed: return "这个确认已经处理过了。"
        case .stale: return "内容已变化，请查看最新内容后再确认。"
        case .notFound: return "找不到这个确认，可能已被取消。"
        case .noPendingApproval: return "当前没有等待确认的内容。"
        case .unsupported: return "当前连接不支持在这里确认。"
        case .rejected(_, let code):
            switch code ?? "" {
            case "approval_operation_conflict": return "这个确认已用另一个答案提交过。"
            case "ui_response_invalid", "approval_schema_invalid": return "填写的内容不符合要求，请检查后再提交。"
            case "approval_grant_conflict": return "对话已变化，请刷新后再试。"
            default: return "确认未被接受，请稍后再试。"
            }
        }
    }
}
public enum ConversationApprovalFailure: Error, Sendable, Equatable {
    /// Network error / 5xx before a response: resend with the SAME decision operationID (idempotent).
    case transport
    /// 409 approval_expired: 10 minutes passed; the call was denied to the model and the turn resumed.
    case expired
    /// 409 approval_consumed: already decided (or turn no longer awaiting).
    case consumed
    /// 409 approval_stale: args_hash differs from the pending call.
    case stale
    /// 404: unknown turn or interrupt.
    case notFound
    /// Other refusal (approval_operation_conflict, approval_grant_conflict, 422 …).
    case rejected(status: Int, code: String?)
    /// Backend without the approval contract.
    case unsupported
    /// No pending interrupt with that id in the local journal.
    case noPendingApproval
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
    /// Snapshot `pending_approvals` (cold-start restore). Empty when none or not provided.
    public var pendingApprovals: [ConversationApprovalRequest] = []
    /// Snapshot `state` (e.g. "awaiting_approval"); nil when not provided.
    public var serverState: String? = nil
    /// Snapshot `pending_approvals` with kind "ui" (kept out of `pendingApprovals`, which stays tool approvals only).
    public var pendingUIApprovals: [ConversationUIApproval] = []
    public init(request: ConversationTurnRequest, events: [ConversationTurnEvent], requestHash: String? = nil, grantEpoch: Int? = nil, goals: [ConversationGoalProjection] = [], pendingApprovals: [ConversationApprovalRequest] = [], serverState: String? = nil, pendingUIApprovals: [ConversationUIApproval] = []) { self.pendingUIApprovals = pendingUIApprovals; self.request = request; self.events = events; self.requestHash = requestHash; self.grantEpoch = grantEpoch; self.goals = goals; self.pendingApprovals = pendingApprovals; self.serverState = serverState }
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
public struct ConversationBusyRetryStatus: Sendable, Equatable {
    public let attempt: Int
    public let maxAttempts: Int
    public let secondsRemaining: Int
    /// true while an automatic retry is scheduled; false once retries are exhausted or cancelled (show manual retry).
    public let automatic: Bool
    public var message: String { automatic ? "模型繁忙，正在重试（\(attempt)/\(maxAttempts)）" : "模型繁忙，暂时没有回复。可以稍后点按重试。" }
}
public protocol ConversationBackend: Sendable {
    /// The server's authoritative chat transcript (user and assistant messages, server order), or nil when this
    /// backend has no server transcript. Used by `ConversationSessionService.syncServerTranscript`.
    func serverTranscript(scope: DataScope, conversationID: UUID) async throws -> [ConversationTranscriptMessage]?
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
    /// R7 busy retry of the SAME turn (server restarts `failed{rate_limited}` with no output in place).
    func retryBusyTurn(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error>
    /// R2 stop: `POST …/turns/{id}/cancel` with body `{}`. Idempotent; safe to resend after a network error.
    /// Throws `ConversationTurnCancelFailure` for transport, 404 and other refusals.
    func cancelTurn(_ request: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt
    /// catpaw.approval.v1: `POST …/turns/{t}/interrupts/{i}/decision?after_sequence=N` with
    /// `{operation_id, decision, args_hash}`; on success streams the SAME turn's events after N (SSE).
    /// Throws `ConversationApprovalFailure` for refusals.
    func submitApproval(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationApprovalDecision, argsHash: String, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error>
    /// catpaw.ui.v1: same decision route as approval.v1 with `decision` submit/dismiss/report_error and the raw `response` object.
    func submitUIDecision(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error>
    /// catpaw.device.v1: `POST …/turns/{t}/device-result` `{call_id, operation_id, args_hash, status, data?}`; streams the SAME turn like a decision.
    func submitDeviceResult(_ request: ConversationTurnRequest, call: ConversationDeviceCall, status: String, data: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error>
}
/// `cancel{turn_id,state,cancelled,already_terminal}` from the Edge cancel route (services/edge/docs/turn-cancel-contract.md).
public struct ConversationTurnCancelReceipt: Sendable, Equatable {
    public let turnID: UUID
    /// Server turn state after the call: `failed`, `completed` or `outcome_unknown`.
    public let state: String
    public let cancelled: Bool
    public let alreadyTerminal: Bool
    public init(turnID: UUID, state: String, cancelled: Bool, alreadyTerminal: Bool) { self.turnID = turnID; self.state = state; self.cancelled = cancelled; self.alreadyTerminal = alreadyTerminal }
}
public enum ConversationTurnCancelFailure: Error, Sendable, Equatable {
    /// Network error, timeout or 5xx: the cancel may or may not have landed; resending is safe.
    case transport
    /// 404: unknown turn (e.g. the POST was not admitted yet).
    case notFound
    /// 401/403/422 or a malformed response: resending will not help.
    case rejected(status: Int)
    /// This backend has no cancel route.
    case unsupported
}
/// Result of `ConversationSessionService.cancelCurrentTurn`.
public enum ConversationTurnCancelOutcome: Sendable, Equatable {
    /// No dispatched/running/unknown turn in this conversation; nothing was sent.
    case noActiveTurn
    /// The turn ended as `failed{cancelled}`; partial text stays in the journal.
    case cancelled(operationID: UUID)
    /// The turn had already completed (cancel raced completion); the full answer was read back.
    case completed(operationID: UUID)
    /// The turn had already failed for another reason (server `state`).
    case alreadyTerminal(operationID: UUID, state: String)
    /// The outcome could not be read back; the turn is left `unknown` for observe/continueFetching.
    case reconciling(operationID: UUID)
}
/// Stream-health sink (ConnectionMonitor in the App target). Domain-only so portable builds stay Network-free.
public protocol ConversationStreamResilience: Sendable {
    func waitForPath() async
    func reconnecting(attempt: Int, retryIn: Double) async
    func resumed() async
    func unreachable() async
    func settled() async
    func syncing() async
    func busy(retryIn: Int) async
    func isPathSatisfied() async -> Bool
    /// Operation IDs waiting in the offline outbox ("等待网络 · 联网后自动发送").
    func outboxChanged(pending: [UUID]) async
    func clearBusy() async
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
    func serverTranscript(scope: DataScope, conversationID: UUID) async throws -> [ConversationTranscriptMessage]? { nil }
    func resumeEvents(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { throw ConversationSessionError.unresolvedOperation }
    func retryBusyTurn(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { throw ConversationSessionError.unresolvedOperation }
    func cancelTurn(_ request: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt { throw ConversationTurnCancelFailure.unsupported }
    func submitApproval(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationApprovalDecision, argsHash: String, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { throw ConversationApprovalFailure.unsupported }
    func submitUIDecision(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { throw ConversationApprovalFailure.unsupported }
    func submitDeviceResult(_ request: ConversationTurnRequest, call: ConversationDeviceCall, status: String, data: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { throw ConversationApprovalFailure.unsupported }
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

/// Sink for side-channel turn events. The network layer calls `dispatch`; the app installs the handler at composition
/// time (`MemoryEventSink.installSideChannel()`), so wire code and portable test scripts do not depend on feature files.
public enum ConversationSideChannelEvents {
    public typealias Handler = @Sendable (_ type: String, _ turnID: UUID, _ data: Data) -> Void
    public static let types: Set<String> = ["memory.used", "memory.update", "memory_recalled", "proactive_suggestion"]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: Handler?
    public static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return installed }
        set { lock.lock(); installed = newValue; lock.unlock() }
    }
    public static func dispatch(type: String, turnID: UUID, data: Data) {
        guard let handler else { return }
        handler(type, turnID, data)
    }
}
