import Foundation

public enum ConversationTaskActionError:Error,LocalizedError,Sendable {
    case notConfigured,invalidResponse,busy,stale,unavailable,originalNotFound
    public var errorDescription:String? {switch self {
    case .notConfigured:return "审批服务尚未连接，已保存事项仍可查看。"
    case .invalidResponse:return "审批对象或校验信息不匹配，未记录决定。"
    case .busy:return "原决定尚在核对，请勿重复提交。"
    case .stale:return "审批已过期或内容已更新，请读取最新事项。"
    case .unavailable:return "当前服务尚不支持提交决定，可继续查看事项。"
    case .originalNotFound:return "尚未找到原决定记录；结果仍未知，请继续核对或寻求帮助。"
    }}
}
public struct ConversationTaskActionReference:Sendable,Equatable,Identifiable {
    public let scope:DataScope
    public let binding:ConversationTaskBinding
    public let subjectID:String
    public let title:String
    public var id:UUID {binding.run_id}
    public init(scope:DataScope,binding:ConversationTaskBinding,subjectID:String,title:String) {self.scope=scope;self.binding=binding;self.subjectID=subjectID;self.title=title}
}
/// Data only: unknown operators remain readable and can never dispatch a decision.
public indirect enum ConversationTaskActionJSON:Codable,Sendable,Equatable {
    case null,string(String),integer(Int),bool(Bool),array([Self]),object([String:Self])
    public init(from decoder:Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null} else if let v=try? c.decode(Bool.self){self = .bool(v)} else if let v=try? c.decode(String.self){self = .string(v)} else if let v=try? c.decode(Int.self),(-9_007_199_254_740_991...9_007_199_254_740_991).contains(v) {self = .integer(v)} else if let v=try? c.decode([Self].self){self = .array(v)} else {self = .object(try c.decode([String:Self].self))}
    }
    public func encode(to encoder:Encoder) throws {var c=encoder.singleValueContainer();switch self {case .null:try c.encodeNil();case .string(let v):try c.encode(v);case .integer(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .array(let v):try c.encode(v);case .object(let v):try c.encode(v)}}
    public static func value<T:Encodable>(_ v:T) throws -> Self {try JSONDecoder().decode(Self.self,from:encoded(v))}
    public func decoded<T:Decodable>(_ type:T.Type) throws -> T {try JSONDecoder().decode(type,from:Self.encoded(self))}
    public static func encoded<T:Encodable>(_ v:T) throws -> Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(v)}
    public func digest() throws -> String {bytesHash(try Self.encoded(self))}
}
public struct ConversationDeviceCalendarTarget:Codable,Sendable,Equatable {
    public var device_id:String,environment_id:String,calendar_id:String,calendar_display_name:String,calendar_snapshot_hash:String
    public init(device_id:String,environment_id:String,calendar_id:String,calendar_display_name:String,calendar_snapshot_hash:String) {self.device_id=device_id;self.environment_id=environment_id;self.calendar_id=calendar_id;self.calendar_display_name=calendar_display_name;self.calendar_snapshot_hash=calendar_snapshot_hash}
    public func validate() throws {guard ConversationTaskActionValidation.uuid(device_id),ConversationTaskActionValidation.uuid(environment_id),ConversationTaskActionValidation.hash(calendar_snapshot_hash),ConversationTaskActionValidation.text(calendar_id,max:256),ConversationTaskActionValidation.text(calendar_display_name,max:200) else {throw ConversationTaskActionError.invalidResponse}}
}
public struct ConversationCalendarCreateParameters:Codable,Sendable,Equatable {
    public var title:String,start_at:String,end_at:String,time_zone:String
    public var reminder_offset_seconds:Int?
    private enum CodingKeys:String,CodingKey {case title,start_at,end_at,time_zone,reminder_offset_seconds}
    public init(title:String,start_at:String,end_at:String,time_zone:String,reminder_offset_seconds:Int?) {self.title=title;self.start_at=start_at;self.end_at=end_at;self.time_zone=time_zone;self.reminder_offset_seconds=reminder_offset_seconds}
    public func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(title,forKey:.title);try c.encode(start_at,forKey:.start_at);try c.encode(end_at,forKey:.end_at);try c.encode(time_zone,forKey:.time_zone);try c.encode(reminder_offset_seconds,forKey:.reminder_offset_seconds)}
    public func validate() throws {
        guard ConversationTaskActionValidation.text(title,max:200),let start=ConversationTaskActionValidation.utc(start_at),let end=ConversationTaskActionValidation.utc(end_at),start.timeIntervalSince1970>=0,end.timeIntervalSince1970<4_134_067_200,end>start,end.timeIntervalSince(start)<=604800,
              time_zone.utf16.count<=80,(time_zone=="UTC" || time_zone.range(of:"^[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)+$",options:.regularExpression) != nil),TimeZone(identifier:time_zone) != nil,
              reminder_offset_seconds.map({(-604800...0).contains($0)}) ?? true else {throw ConversationTaskActionError.invalidResponse}
    }
}
public struct ConversationTaskActionPlanReference:Codable,Sendable,Equatable {public var revision:Int,plan_hash:String;public init(revision:Int,plan_hash:String){self.revision=revision;self.plan_hash=plan_hash}}
public struct ConversationTaskActionArtifactReference:Codable,Sendable,Equatable {public var artifact_id:String,version:Int,content_hash:String;public init(artifact_id:String,version:Int,content_hash:String){self.artifact_id=artifact_id;self.version=version;self.content_hash=content_hash}}
public struct ConversationTaskActionFrozen:Codable,Sendable,Equatable {
    public var id:String,proposal_operation_id:String,scope_id:String,subject_id:String,conversation_id:String,turn_id:String,run_id:String,task_id:String,request_hash:String,delegation_id:String
    public var delegation_revision:Int,grant_epoch:Int
    public var plan_reference:ConversationTaskActionPlanReference
    public var kind:String,tool_version:Int
    public var target:ConversationTaskActionJSON,parameters:ConversationTaskActionJSON
    public var parameters_hash:String
    public var artifact_reference:ConversationTaskActionArtifactReference?
    public var created_at:String,expires_at:String
    private enum CodingKeys:String,CodingKey {case id,proposal_operation_id,scope_id,subject_id,conversation_id,turn_id,run_id,task_id,request_hash,delegation_id,delegation_revision,grant_epoch,plan_reference,kind,tool_version,target,parameters,parameters_hash,artifact_reference,created_at,expires_at}
    public init(id:String,proposal_operation_id:String,scope_id:String,subject_id:String,conversation_id:String,turn_id:String,run_id:String,task_id:String,request_hash:String,delegation_id:String,delegation_revision:Int,grant_epoch:Int,plan_reference:ConversationTaskActionPlanReference,kind:String,tool_version:Int,target:ConversationTaskActionJSON,parameters:ConversationTaskActionJSON,parameters_hash:String,artifact_reference:ConversationTaskActionArtifactReference?,created_at:String,expires_at:String){self.id=id;self.proposal_operation_id=proposal_operation_id;self.scope_id=scope_id;self.subject_id=subject_id;self.conversation_id=conversation_id;self.turn_id=turn_id;self.run_id=run_id;self.task_id=task_id;self.request_hash=request_hash;self.delegation_id=delegation_id;self.delegation_revision=delegation_revision;self.grant_epoch=grant_epoch;self.plan_reference=plan_reference;self.kind=kind;self.tool_version=tool_version;self.target=target;self.parameters=parameters;self.parameters_hash=parameters_hash;self.artifact_reference=artifact_reference;self.created_at=created_at;self.expires_at=expires_at}
    public func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(id,forKey:.id);try c.encode(proposal_operation_id,forKey:.proposal_operation_id);try c.encode(scope_id,forKey:.scope_id);try c.encode(subject_id,forKey:.subject_id);try c.encode(conversation_id,forKey:.conversation_id);try c.encode(turn_id,forKey:.turn_id);try c.encode(run_id,forKey:.run_id);try c.encode(task_id,forKey:.task_id);try c.encode(request_hash,forKey:.request_hash);try c.encode(delegation_id,forKey:.delegation_id);try c.encode(delegation_revision,forKey:.delegation_revision);try c.encode(grant_epoch,forKey:.grant_epoch);try c.encode(plan_reference,forKey:.plan_reference);try c.encode(kind,forKey:.kind);try c.encode(tool_version,forKey:.tool_version);try c.encode(target,forKey:.target);try c.encode(parameters,forKey:.parameters);try c.encode(parameters_hash,forKey:.parameters_hash);try c.encode(artifact_reference,forKey:.artifact_reference);try c.encode(created_at,forKey:.created_at);try c.encode(expires_at,forKey:.expires_at)}
    public func digest() throws -> String {bytesHash(try ConversationTaskActionJSON.encoded(self))}
}
public struct ConversationTaskActionCapability:Codable,Sendable,Equatable {
    public var kind:String,tool_version:Int,effect_class:String,execution_location:String,registered:Bool,executable:Bool,unavailable_reason:String,os_target_verified:Bool
    public init(kind:String,tool_version:Int=1,effect_class:String="device_calendar_write",execution_location:String="registered_device",registered:Bool=true,executable:Bool=false,unavailable_reason:String="device_executor_not_configured",os_target_verified:Bool=false){self.kind=kind;self.tool_version=tool_version;self.effect_class=effect_class;self.execution_location=execution_location;self.registered=registered;self.executable=executable;self.unavailable_reason=unavailable_reason;self.os_target_verified=os_target_verified}
}
public struct ConversationTaskActionEffect:Codable,Sendable,Equatable {
    public var status:String,receipt:ConversationTaskActionJSON
    public init(status:String="not_dispatched",receipt:ConversationTaskActionJSON = .null){self.status=status;self.receipt=receipt}
}
public struct ConversationTaskActionSnapshot:Codable,Sendable,Equatable,Identifiable {
    public var frozen:ConversationTaskActionFrozen
    public var revision:Int,action_digest:String,approval_status:String,approval_binding_current:Bool,invalidation_reason:String?,decision_operation_id:String?,execution_authorized:Bool,capability:ConversationTaskActionCapability,effect:ConversationTaskActionEffect,superseded_by:String?
    public var id:String {frozen.id}
    private enum CodingKeys:String,CodingKey {case revision,action_digest,approval_status,approval_binding_current,invalidation_reason,decision_operation_id,execution_authorized,capability,effect,superseded_by}
    public init(frozen:ConversationTaskActionFrozen,revision:Int=1,action_digest:String,approval_status:String="pending",approval_binding_current:Bool=true,invalidation_reason:String?=nil,decision_operation_id:String?=nil,execution_authorized:Bool=false,capability:ConversationTaskActionCapability,effect:ConversationTaskActionEffect = .init(),superseded_by:String?=nil) {self.frozen=frozen;self.revision=revision;self.action_digest=action_digest;self.approval_status=approval_status;self.approval_binding_current=approval_binding_current;self.invalidation_reason=invalidation_reason;self.decision_operation_id=decision_operation_id;self.execution_authorized=execution_authorized;self.capability=capability;self.effect=effect;self.superseded_by=superseded_by}
    public init(from decoder:Decoder) throws {frozen=try .init(from:decoder);let c=try decoder.container(keyedBy:CodingKeys.self);revision=try c.decode(Int.self,forKey:.revision);action_digest=try c.decode(String.self,forKey:.action_digest);approval_status=try c.decode(String.self,forKey:.approval_status);approval_binding_current=try c.decode(Bool.self,forKey:.approval_binding_current);invalidation_reason=try c.decodeIfPresent(String.self,forKey:.invalidation_reason);decision_operation_id=try c.decodeIfPresent(String.self,forKey:.decision_operation_id);execution_authorized=try c.decode(Bool.self,forKey:.execution_authorized);capability=try c.decode(ConversationTaskActionCapability.self,forKey:.capability);effect=try c.decode(ConversationTaskActionEffect.self,forKey:.effect);superseded_by=try c.decodeIfPresent(String.self,forKey:.superseded_by)}
    public func encode(to encoder:Encoder) throws {try frozen.encode(to:encoder);var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(revision,forKey:.revision);try c.encode(action_digest,forKey:.action_digest);try c.encode(approval_status,forKey:.approval_status);try c.encode(approval_binding_current,forKey:.approval_binding_current);try c.encode(invalidation_reason,forKey:.invalidation_reason);try c.encode(decision_operation_id,forKey:.decision_operation_id);try c.encode(execution_authorized,forKey:.execution_authorized);try c.encode(capability,forKey:.capability);try c.encode(effect,forKey:.effect);try c.encodeIfPresent(superseded_by,forKey:.superseded_by)}
    public var isSupported:Bool {frozen.kind=="calendar.create.v1" && frozen.tool_version==1}
    public var calendarTarget:ConversationDeviceCalendarTarget? {isSupported ? try? frozen.target.decoded(ConversationDeviceCalendarTarget.self) : nil}
    public var calendarParameters:ConversationCalendarCreateParameters? {isSupported ? try? frozen.parameters.decoded(ConversationCalendarCreateParameters.self) : nil}
    public func canDecide(at now:Date)->Bool {isSupported && approval_status=="pending" && approval_binding_current && invalidation_reason==nil && decision_operation_id==nil && superseded_by==nil && (ConversationTaskActionValidation.utc(frozen.expires_at).map{$0>now} ?? false)}
    public func validate(reference:ConversationTaskActionReference) throws {
        let f=frozen,b=reference.binding
        guard [f.id,f.proposal_operation_id,f.scope_id,f.subject_id,f.conversation_id,f.turn_id,f.run_id,f.delegation_id].allSatisfy(ConversationTaskActionValidation.uuid),f.scope_id==b.scope_id.uuidString.lowercased(),f.subject_id==reference.subjectID,f.conversation_id==b.conversation_id.uuidString.lowercased(),f.turn_id==b.turn_id.uuidString.lowercased(),f.run_id==b.run_id.uuidString.lowercased(),f.task_id==b.task_id,f.request_hash==b.request_hash,f.delegation_id==b.delegation_id.uuidString.lowercased(),f.delegation_revision==b.delegation_revision,f.grant_epoch==b.grant_epoch,
              ConversationTaskActionValidation.positive(f.plan_reference.revision),ConversationTaskActionValidation.positive(f.delegation_revision),ConversationTaskActionValidation.positive(f.grant_epoch),ConversationTaskActionValidation.hash(f.task_id),ConversationTaskActionValidation.hash(f.plan_reference.plan_hash),ConversationTaskActionValidation.hash(f.request_hash),ConversationTaskActionValidation.hash(f.parameters_hash),try f.parameters.digest()==f.parameters_hash,try f.digest()==action_digest,ConversationTaskActionValidation.positive(revision),try ConversationTaskActionJSON.encoded(f).count<=16384,
              let start=ConversationTaskActionValidation.utc(f.created_at),let expiry=ConversationTaskActionValidation.utc(f.expires_at),expiry.timeIntervalSince(start)==1800,
              !execution_authorized,!capability.executable,!capability.os_target_verified,capability.kind==f.kind,capability.tool_version==f.tool_version,effect.receipt == .null,["not_dispatched","waiting_device"].contains(effect.status),effect.status != "waiting_device" || (approval_status=="approved" && approval_binding_current),
              decision_operation_id.map(ConversationTaskActionValidation.uuid) ?? true,superseded_by.map(ConversationTaskActionValidation.uuid) ?? true else {throw ConversationTaskActionError.invalidResponse}
        if let artifact=f.artifact_reference {guard artifact.artifact_id.range(of:"^[A-Za-z0-9._-]{1,256}$",options:.regularExpression) != nil,ConversationTaskActionValidation.positive(artifact.version),ConversationTaskActionValidation.hash(artifact.content_hash) else {throw ConversationTaskActionError.invalidResponse}}
        if isSupported {
            guard try f.id==ConversationTaskActionValidation.actionID(runID:f.run_id,proposalID:f.proposal_operation_id),["pending","approved","denied","expired","invalidated"].contains(approval_status),capability.registered,capability.effect_class=="device_calendar_write",capability.execution_location=="registered_device",capability.unavailable_reason=="device_executor_not_configured",let target=calendarTarget,let parameters=calendarParameters,
                  try ConversationTaskActionJSON.value(target)==f.target,try ConversationTaskActionJSON.value(parameters)==f.parameters else {throw ConversationTaskActionError.invalidResponse}
            try target.validate();try parameters.validate()
            guard (approval_status != "pending" || decision_operation_id==nil),(["approved","denied"].contains(approval_status) == (decision_operation_id != nil)),approval_binding_current == (invalidation_reason==nil) else {throw ConversationTaskActionError.invalidResponse}
            if let decisionID=decision_operation_id {guard revision>=2,![f.id,f.proposal_operation_id,f.run_id,f.delegation_id,f.conversation_id,f.turn_id].contains(decisionID) else {throw ConversationTaskActionError.invalidResponse}}
        }
    }
}
public enum ConversationTaskActionDecision:String,Codable,Sendable {case approve,deny}
/// The HTTP adapter may use this only when it proves no POST began.
public enum ConversationTaskActionDispatchFailure:Error,LocalizedError,Sendable {
    case notSent
    public var errorDescription:String? {"决定尚未发送；这份事项仍保留。"}
}
public struct ConversationTaskActionDecisionRequest:Codable,Sendable,Equatable {
    public let operationID:UUID,decision:ConversationTaskActionDecision,expected_revision:Int,action_digest:String,expected_grant_epoch:Int
    private enum CodingKeys:String,CodingKey {case operationID="operation_id",decision,expected_revision,action_digest,expected_grant_epoch}
    public init(operationID:UUID,decision:ConversationTaskActionDecision,expected_revision:Int,action_digest:String,expected_grant_epoch:Int){self.operationID=operationID;self.decision=decision;self.expected_revision=expected_revision;self.action_digest=action_digest;self.expected_grant_epoch=expected_grant_epoch}
    public func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(operationID.uuidString.lowercased(),forKey:.operationID);try c.encode(decision,forKey:.decision);try c.encode(expected_revision,forKey:.expected_revision);try c.encode(action_digest,forKey:.action_digest);try c.encode(expected_grant_epoch,forKey:.expected_grant_epoch)}
    public func requestHash(reference:ConversationTaskActionReference,actionID:String) throws -> String {
        guard case .object(var value)=try ConversationTaskActionJSON.value(self) else {throw ConversationTaskActionError.invalidResponse}
        value["contract"] = .string("catpaw.task-action.v1");value["run_id"] = .string(reference.binding.run_id.uuidString.lowercased());value["action_id"] = .string(actionID)
        return try ConversationTaskActionJSON.object(value).digest()
    }
}
public struct ConversationTaskActionDecisionReceipt:Codable,Sendable,Equatable {
    public var operation_id:String,action_id:String,decision:ConversationTaskActionDecision,state:String,action_digest:String,committed_at:String
    public init(operation_id:String,action_id:String,decision:ConversationTaskActionDecision,state:String="accepted",action_digest:String,committed_at:String){self.operation_id=operation_id;self.action_id=action_id;self.decision=decision;self.state=state;self.action_digest=action_digest;self.committed_at=committed_at}
}
public struct ConversationTaskActionEnvelope:Codable,Sendable {
    public var schema_version:Int,contract:String,action:ConversationTaskActionSnapshot,decision:ConversationTaskActionDecisionReceipt?
    public init(action:ConversationTaskActionSnapshot,decision:ConversationTaskActionDecisionReceipt?=nil){schema_version=1;contract="catpaw.task-action.v1";self.action=action;self.decision=decision}
}
public struct ConversationTaskActionCatalog:Codable,Sendable {
    public var schema_version:Int,contract:String,run_id:String,task_id:String,actions:[ConversationTaskActionSnapshot]
    public init(reference:ConversationTaskActionReference,actions:[ConversationTaskActionSnapshot]){schema_version=1;contract="catpaw.task-action.v1";run_id=reference.binding.run_id.uuidString.lowercased();task_id=reference.binding.task_id;self.actions=actions}
    public func validate(reference:ConversationTaskActionReference) throws {guard schema_version==1,contract=="catpaw.task-action.v1",run_id==reference.binding.run_id.uuidString.lowercased(),task_id==reference.binding.task_id,actions.count<=32,Set(actions.map(\.id)).count==actions.count else {throw ConversationTaskActionError.invalidResponse};for action in actions {try action.validate(reference:reference)}}
}
public protocol ConversationTaskActionBackend:Sendable {
    func decisionAvailability(_ reference:ConversationTaskActionReference) async throws -> Bool
    func readActions(_ reference:ConversationTaskActionReference) async throws -> ConversationTaskActionCatalog
    func readAction(_ reference:ConversationTaskActionReference,actionID:String) async throws -> ConversationTaskActionEnvelope
    func decideAction(_ reference:ConversationTaskActionReference,actionID:String,request:ConversationTaskActionDecisionRequest) async throws -> ConversationTaskActionEnvelope
    func readDecision(_ reference:ConversationTaskActionReference,actionID:String,operationID:UUID) async throws -> ConversationTaskActionEnvelope
}
public struct UnconfiguredConversationTaskActionBackend:ConversationTaskActionBackend {
    public init(){}
    public func decisionAvailability(_ reference:ConversationTaskActionReference) async throws -> Bool {false}
    public func readActions(_ reference:ConversationTaskActionReference) async throws -> ConversationTaskActionCatalog {throw ConversationTaskActionError.notConfigured}
    public func readAction(_ reference:ConversationTaskActionReference,actionID:String) async throws -> ConversationTaskActionEnvelope {throw ConversationTaskActionError.notConfigured}
    public func decideAction(_ reference:ConversationTaskActionReference,actionID:String,request:ConversationTaskActionDecisionRequest) async throws -> ConversationTaskActionEnvelope {throw ConversationTaskActionError.notConfigured}
    public func readDecision(_ reference:ConversationTaskActionReference,actionID:String,operationID:UUID) async throws -> ConversationTaskActionEnvelope {throw ConversationTaskActionError.notConfigured}
}
public enum ConversationTaskActionValidation {
    public static func uuid(_ v:String)->Bool {v.range(of:"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression) != nil}
    public static func hash(_ v:String)->Bool {v.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
    public static func positive(_ v:Int)->Bool {(1...9_007_199_254_740_991).contains(v)}
    public static func actionID(runID:String,proposalID:String) throws -> String {
        let digest=Array(try ConversationTaskActionJSON.object(["contract":.string("catpaw.task-action.v1"),"run_id":.string(runID),"proposal_operation_id":.string(proposalID)]).digest())
        return String(digest[0..<8])+"-"+String(digest[8..<12])+"-4"+String(digest[13..<16])+"-8"+String(digest[17..<20])+"-"+String(digest[20..<32])
    }
    public static func text(_ v:String,max:Int)->Bool {ConversationTaskPlanContent.hasNonWhitespace(v) && v.utf16.count<=max && !v.unicodeScalars.contains{(0...31).contains($0.value) || $0.value==127}}
    public static func utc(_ v:String)->Date? {let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];guard v.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$",options:.regularExpression) != nil,let d=formatter.date(from:v),formatter.string(from:d)==v else {return nil};return d}
}
