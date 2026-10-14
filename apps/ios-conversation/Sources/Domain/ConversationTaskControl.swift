import Foundation

public enum ConversationTaskControlError:Error,LocalizedError,Sendable {
    case notConfigured,invalidResponse,busy,stale,unavailable,originalNotFound,journalFull
    public var errorDescription:String? {switch self {
    case .notConfigured:return "工作控制服务尚未连接，已保存状态仍可查看。"
    case .invalidResponse:return "工作身份或控制回执不匹配，未确认控制结果。"
    case .busy:return "原控制尚在核对，请勿重复提交。"
    case .stale:return "工作状态或计划已变化，请读取最新状态。"
    case .unavailable:return "当前服务尚不支持控制工作，可继续查看状态。"
    case .originalNotFound:return "尚未找到原控制记录；结果仍未知，请继续核对。"
    case .journalFull:return "已保存的控制记录达到本机上限，请先保留并核对原记录。"
    }}
}
/// Only an adapter that proves URLSession never began may return this outcome.
public enum ConversationTaskControlDispatchFailure:Error,LocalizedError,Sendable {
    case notSent
    public var errorDescription:String? {"控制尚未发送，工作状态未获确认。"}
}
public struct ConversationTaskControlReference:Sendable,Equatable,Identifiable {
    public let scope:DataScope
    public let binding:ConversationTaskBinding
    public let subjectID:String,title:String
    public var id:UUID {binding.run_id}
    public init(scope:DataScope,binding:ConversationTaskBinding,subjectID:String,title:String) {self.scope=scope;self.binding=binding;self.subjectID=subjectID;self.title=title}
    public func validate() throws {
        guard ConversationTaskActionValidation.uuid(subjectID),ConversationTaskActionValidation.hash(binding.task_id),ConversationTaskActionValidation.hash(binding.request_hash),ConversationTaskActionValidation.positive(binding.delegation_revision),ConversationTaskActionValidation.positive(binding.grant_epoch) else {throw ConversationTaskControlError.invalidResponse}
    }
}
public enum ConversationTaskControlAction:String,Codable,Sendable {case pause,resume,revoke}
public struct ConversationTaskControlAuthority:Codable,Sendable,Equatable {
    public var delegation_revision:Int,grant_epoch:Int,state:String
    public init(delegation_revision:Int,grant_epoch:Int,state:String){self.delegation_revision=delegation_revision;self.grant_epoch=grant_epoch;self.state=state}
}
public struct ConversationTaskControlUnresolvedOperation:Codable,Sendable,Equatable,Identifiable {
    public var kind:String,operation_id:String,state:String,can_retry:Bool
    public var id:String {kind+":"+operation_id}
    public init(kind:String,operation_id:String,state:String,can_retry:Bool=false){self.kind=kind;self.operation_id=operation_id;self.state=state;self.can_retry=can_retry}
    public func validate() throws {
        let known=["model","public_source","effect"].contains(kind)
        let identity=kind=="model" ? ConversationTaskActionValidation.hash(operation_id) : ConversationTaskActionValidation.uuid(operation_id)
        let phase=kind=="model" ? state=="dispatched" : kind=="public_source" ? ["dispatched","unknown"].contains(state) : ["executing","outcome_unknown","failed"].contains(state)
        guard known,identity,!can_retry,phase else {throw ConversationTaskControlError.invalidResponse}
    }
}
/// This is a verified server projection, never an execution engine or a restored grant.
public struct ConversationTaskControlSnapshot:Codable,Sendable,Equatable {
    public var scope_id:String,subject_id:String,conversation_id:String,run_id:String,task_id:String,run_request_hash:String,delegation_id:String
    public var delegation_revision:Int,grant_epoch:Int,authority_reference:ConversationTaskControlAuthority,execution_revision:Int,task_status:String
    public var plan_reference:ConversationTaskActionPlanReference
    public var source_authorization_current:Bool,blocked_reason:String?,unresolved_operations:[ConversationTaskControlUnresolvedOperation]
    public var can_pause:Bool,can_resume:Bool,can_revoke:Bool,snapshot_hash:String
    private enum CodingKeys:String,CodingKey {case scope_id,subject_id,conversation_id,run_id,task_id,run_request_hash,delegation_id,delegation_revision,grant_epoch,authority_reference,execution_revision,task_status,plan_reference,source_authorization_current,blocked_reason,unresolved_operations,can_pause,can_resume,can_revoke,snapshot_hash}
    public init(scope_id:String,subject_id:String,conversation_id:String,run_id:String,task_id:String,run_request_hash:String,delegation_id:String,delegation_revision:Int,grant_epoch:Int,authority_reference:ConversationTaskControlAuthority,execution_revision:Int,task_status:String,plan_reference:ConversationTaskActionPlanReference,source_authorization_current:Bool,blocked_reason:String?,unresolved_operations:[ConversationTaskControlUnresolvedOperation],can_pause:Bool,can_resume:Bool,can_revoke:Bool,snapshot_hash:String){self.scope_id=scope_id;self.subject_id=subject_id;self.conversation_id=conversation_id;self.run_id=run_id;self.task_id=task_id;self.run_request_hash=run_request_hash;self.delegation_id=delegation_id;self.delegation_revision=delegation_revision;self.grant_epoch=grant_epoch;self.authority_reference=authority_reference;self.execution_revision=execution_revision;self.task_status=task_status;self.plan_reference=plan_reference;self.source_authorization_current=source_authorization_current;self.blocked_reason=blocked_reason;self.unresolved_operations=unresolved_operations;self.can_pause=can_pause;self.can_resume=can_resume;self.can_revoke=can_revoke;self.snapshot_hash=snapshot_hash}
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(scope_id,forKey:.scope_id);try c.encode(subject_id,forKey:.subject_id);try c.encode(conversation_id,forKey:.conversation_id);try c.encode(run_id,forKey:.run_id);try c.encode(task_id,forKey:.task_id);try c.encode(run_request_hash,forKey:.run_request_hash);try c.encode(delegation_id,forKey:.delegation_id)
        try c.encode(delegation_revision,forKey:.delegation_revision);try c.encode(grant_epoch,forKey:.grant_epoch);try c.encode(authority_reference,forKey:.authority_reference);try c.encode(execution_revision,forKey:.execution_revision);try c.encode(task_status,forKey:.task_status);try c.encode(plan_reference,forKey:.plan_reference)
        try c.encode(source_authorization_current,forKey:.source_authorization_current);try c.encode(blocked_reason,forKey:.blocked_reason);try c.encode(unresolved_operations,forKey:.unresolved_operations);try c.encode(can_pause,forKey:.can_pause);try c.encode(can_resume,forKey:.can_resume);try c.encode(can_revoke,forKey:.can_revoke);try c.encode(snapshot_hash,forKey:.snapshot_hash)
    }
    public var originalGrantCurrent:Bool {authority_reference.state=="active" && authority_reference.delegation_revision==delegation_revision && authority_reference.grant_epoch==grant_epoch}
    public var terminal:Bool {["succeeded","failed","cancelled"].contains(task_status)}
    public func allows(_ action:ConversationTaskControlAction)->Bool {switch action {case .pause:return can_pause;case .resume:return can_resume;case .revoke:return can_revoke}}
    public func digest() throws -> String {try ConversationTaskControlCodec.digest(self,excluding:"snapshot_hash")}
    public func validate(reference:ConversationTaskControlReference) throws {
        try reference.validate();let b=reference.binding
        guard scope_id==b.scope_id.uuidString.lowercased(),subject_id==reference.subjectID,conversation_id==b.conversation_id.uuidString.lowercased(),run_id==b.run_id.uuidString.lowercased(),task_id==b.task_id,run_request_hash==b.request_hash,delegation_id==b.delegation_id.uuidString.lowercased(),delegation_revision==b.delegation_revision,grant_epoch==b.grant_epoch,
              ConversationTaskControlCodec.nonnegative(execution_revision),ConversationTaskActionValidation.positive(plan_reference.revision),ConversationTaskActionValidation.hash(plan_reference.plan_hash),ConversationTaskActionValidation.positive(authority_reference.delegation_revision),ConversationTaskActionValidation.positive(authority_reference.grant_epoch),["active","paused","revoked"].contains(authority_reference.state),["queued","scheduled","running","waiting_input","outcome_unknown","paused","succeeded","failed","cancelled"].contains(task_status),
              unresolved_operations.count<=64,Set(unresolved_operations.map(\.id)).count==unresolved_operations.count,ConversationTaskActionValidation.hash(snapshot_hash),try digest()==snapshot_hash,
              blocked_reason.map({ConversationTaskActionValidation.text($0,max:160)}) ?? true,
              !can_pause || (originalGrantCurrent && !terminal && task_status != "paused"),
              !can_resume || (originalGrantCurrent && source_authorization_current && task_status=="paused" && blocked_reason=="user_paused" && unresolved_operations.isEmpty),
              !can_revoke || (authority_reference.state != "revoked" && !terminal),
              originalGrantCurrent || (!can_pause && !can_resume && blocked_reason=="grant_changed"),
              originalGrantCurrent && source_authorization_current || !can_resume,
              unresolved_operations.isEmpty || !can_resume else {throw ConversationTaskControlError.invalidResponse}
        for operation in unresolved_operations {try operation.validate()}
    }
}
public struct ConversationTaskControlRequest:Codable,Sendable,Equatable {
    public let operationID:UUID,action:ConversationTaskControlAction,expected_execution_revision:Int,expected_snapshot_hash:String,expected_grant_epoch:Int,expected_plan_revision:Int,expected_plan_hash:String
    private enum CodingKeys:String,CodingKey {case operationID="operation_id",action,expected_execution_revision,expected_snapshot_hash,expected_grant_epoch,expected_plan_revision,expected_plan_hash}
    public init(operationID:UUID,action:ConversationTaskControlAction,expected_execution_revision:Int,expected_snapshot_hash:String,expected_grant_epoch:Int,expected_plan_revision:Int,expected_plan_hash:String){self.operationID=operationID;self.action=action;self.expected_execution_revision=expected_execution_revision;self.expected_snapshot_hash=expected_snapshot_hash;self.expected_grant_epoch=expected_grant_epoch;self.expected_plan_revision=expected_plan_revision;self.expected_plan_hash=expected_plan_hash}
    public init(operationID:UUID,action:ConversationTaskControlAction,base:ConversationTaskControlSnapshot){self.init(operationID:operationID,action:action,expected_execution_revision:base.execution_revision,expected_snapshot_hash:base.snapshot_hash,expected_grant_epoch:base.grant_epoch,expected_plan_revision:base.plan_reference.revision,expected_plan_hash:base.plan_reference.plan_hash)}
    public func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(operationID.uuidString.lowercased(),forKey:.operationID);try c.encode(action,forKey:.action);try c.encode(expected_execution_revision,forKey:.expected_execution_revision);try c.encode(expected_snapshot_hash,forKey:.expected_snapshot_hash);try c.encode(expected_grant_epoch,forKey:.expected_grant_epoch);try c.encode(expected_plan_revision,forKey:.expected_plan_revision);try c.encode(expected_plan_hash,forKey:.expected_plan_hash)}
    public func validate(reference:ConversationTaskControlReference) throws {
        try reference.validate();let b=reference.binding
        guard ConversationTaskControlCodec.nonnegative(expected_execution_revision),expected_execution_revision<9_007_199_254_740_991,expected_grant_epoch==b.grant_epoch,ConversationTaskActionValidation.positive(expected_plan_revision),ConversationTaskActionValidation.hash(expected_snapshot_hash),ConversationTaskActionValidation.hash(expected_plan_hash),![b.scope_id,b.conversation_id,b.turn_id,b.delegation_id,b.operation_id,b.run_id].contains(operationID),try ConversationTaskActionJSON.encoded(self).count<=8000 else {throw ConversationTaskControlError.invalidResponse}
    }
    public func requestHash(reference:ConversationTaskControlReference) throws -> String {
        guard case .object(var object)=try ConversationTaskActionJSON.value(self) else {throw ConversationTaskControlError.invalidResponse}
        object["scope_id"] = .string(reference.binding.scope_id.uuidString.lowercased());object["run_id"] = .string(reference.binding.run_id.uuidString.lowercased())
        return try ConversationTaskActionJSON.object(object).digest()
    }
}
public struct ConversationTaskControlReceipt:Codable,Sendable,Equatable {
    public var operation_id:String,operation_hash:String,scope_id:String,subject_id:String,conversation_id:String,run_id:String,task_id:String,run_request_hash:String
    public var action:ConversationTaskControlAction,base_execution_revision:Int,accepted_execution_revision:Int,base_snapshot_hash:String,grant_epoch:Int,plan_reference:ConversationTaskActionPlanReference,result_task_status:String,applied_at:String,state:String,receipt_hash:String
    public func digest() throws -> String {try ConversationTaskControlCodec.digest(self,excluding:"receipt_hash")}
    public func validate(reference:ConversationTaskControlReference) throws {
        let b=reference.binding
        guard ConversationTaskActionValidation.uuid(operation_id),ConversationTaskActionValidation.hash(operation_hash),scope_id==b.scope_id.uuidString.lowercased(),subject_id==reference.subjectID,conversation_id==b.conversation_id.uuidString.lowercased(),run_id==b.run_id.uuidString.lowercased(),task_id==b.task_id,run_request_hash==b.request_hash,grant_epoch==b.grant_epoch,ConversationTaskControlCodec.nonnegative(base_execution_revision),base_execution_revision<9_007_199_254_740_991,accepted_execution_revision==base_execution_revision+1,ConversationTaskActionValidation.hash(base_snapshot_hash),ConversationTaskActionValidation.positive(plan_reference.revision),ConversationTaskActionValidation.hash(plan_reference.plan_hash),ConversationTaskActionValidation.utc(applied_at) != nil,state=="applied",ConversationTaskActionValidation.hash(receipt_hash),try digest()==receipt_hash,
              action == .pause ? result_task_status=="paused" : action == .revoke ? result_task_status=="cancelled" : ["scheduled","waiting_input"].contains(result_task_status) else {throw ConversationTaskControlError.invalidResponse}
    }
}
public struct ConversationTaskControlEnvelope:Codable,Sendable,Equatable {
    public var schema_version:Int,contract:String,control:ConversationTaskControlSnapshot,operation:ConversationTaskControlReceipt?
    public init(control:ConversationTaskControlSnapshot,operation:ConversationTaskControlReceipt?=nil){schema_version=1;contract="catpaw.task-control.v1";self.control=control;self.operation=operation}
    public func validate(reference:ConversationTaskControlReference) throws {
        guard schema_version==1,contract=="catpaw.task-control.v1" else {throw ConversationTaskControlError.invalidResponse}
        try control.validate(reference:reference)
        if let operation {try operation.validate(reference:reference);guard control.execution_revision>=operation.accepted_execution_revision else {throw ConversationTaskControlError.invalidResponse}}
    }
    public func validateApplied(reference:ConversationTaskControlReference,request:ConversationTaskControlRequest,base:ConversationTaskControlSnapshot) throws {
        try validate(reference:reference);try request.validate(reference:reference);try base.validate(reference:reference)
        guard let operation,operation.operation_id==request.operationID.uuidString.lowercased(),operation.action==request.action,operation.base_execution_revision==request.expected_execution_revision,operation.base_snapshot_hash==request.expected_snapshot_hash,operation.grant_epoch==request.expected_grant_epoch,operation.plan_reference.revision==request.expected_plan_revision,operation.plan_reference.plan_hash==request.expected_plan_hash,request.expected_execution_revision==base.execution_revision,request.expected_snapshot_hash==base.snapshot_hash,request.expected_plan_revision==base.plan_reference.revision,request.expected_plan_hash==base.plan_reference.plan_hash,base.allows(request.action) else {throw ConversationTaskControlError.invalidResponse}
        // Later execution or controls may advance the live projection; they never change this receipt.
        if control.execution_revision==operation.accepted_execution_revision {
            if request.action == .pause {guard control.task_status=="paused" else {throw ConversationTaskControlError.invalidResponse}}
            if request.action == .revoke {guard control.task_status=="cancelled",control.authority_reference.state=="revoked",control.authority_reference.grant_epoch==base.authority_reference.grant_epoch+1,control.authority_reference.delegation_revision==base.authority_reference.delegation_revision+1 else {throw ConversationTaskControlError.invalidResponse}}
        }
    }
}
public protocol ConversationTaskControlBackend:Sendable {
    func controlAvailability(_ reference:ConversationTaskControlReference) async throws -> Bool
    func readControl(_ reference:ConversationTaskControlReference) async throws -> ConversationTaskControlEnvelope
    func readControlOperation(_ reference:ConversationTaskControlReference,operationID:UUID) async throws -> ConversationTaskControlEnvelope
    func submitControl(_ reference:ConversationTaskControlReference,request:ConversationTaskControlRequest) async throws -> ConversationTaskControlEnvelope
}
public struct UnconfiguredConversationTaskControlBackend:ConversationTaskControlBackend {
    public init(){}
    public func controlAvailability(_ reference:ConversationTaskControlReference) async throws -> Bool {false}
    public func readControl(_ reference:ConversationTaskControlReference) async throws -> ConversationTaskControlEnvelope {throw ConversationTaskControlError.notConfigured}
    public func readControlOperation(_ reference:ConversationTaskControlReference,operationID:UUID) async throws -> ConversationTaskControlEnvelope {throw ConversationTaskControlError.notConfigured}
    public func submitControl(_ reference:ConversationTaskControlReference,request:ConversationTaskControlRequest) async throws -> ConversationTaskControlEnvelope {throw ConversationTaskControlError.notConfigured}
}
public enum ConversationTaskControlCodec {
    public static func nonnegative(_ value:Int)->Bool {(0...9_007_199_254_740_991).contains(value)}
    public static func digest<T:Encodable>(_ value:T,excluding field:String) throws -> String {
        guard case .object(var object)=try ConversationTaskActionJSON.value(value) else {throw ConversationTaskControlError.invalidResponse}
        object.removeValue(forKey:field);return try ConversationTaskActionJSON.object(object).digest()
    }
}
