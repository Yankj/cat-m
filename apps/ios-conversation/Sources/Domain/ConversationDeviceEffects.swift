import Foundation
import CoreFoundation

public enum ConversationDeviceEffectError: Error, Sendable { case invalidResponse, referenceMismatch, unsupportedPolicy }

/// This reference is frozen by the application service, never reconstructed from a UI label.
public struct ConversationDeviceEffectReference: Sendable, Equatable {
    public let scope: DataScope
    public let binding: ConversationTaskBinding
    public let subjectID: String
    public let actionID: String
    public let actionDigest: String
    public let decisionOperationID: String
    public let actionRevision: Int
    public init(scope: DataScope, binding: ConversationTaskBinding, subjectID: String, actionID: String, actionDigest: String, decisionOperationID: String, actionRevision: Int) throws {
        guard [subjectID, actionID, decisionOperationID].allSatisfy(ConversationTaskActionValidation.uuid),
              ConversationTaskActionValidation.hash(actionDigest), ConversationTaskActionValidation.positive(actionRevision), actionRevision >= 2,
              ConversationTaskActionValidation.hash(binding.task_id), ConversationTaskActionValidation.hash(binding.request_hash),
              ConversationTaskActionValidation.positive(binding.delegation_revision), ConversationTaskActionValidation.positive(binding.grant_epoch) else { throw ConversationDeviceEffectError.referenceMismatch }
        self.scope=scope; self.binding=binding; self.subjectID=subjectID; self.actionID=actionID
        self.actionDigest=actionDigest; self.decisionOperationID=decisionOperationID; self.actionRevision=actionRevision
    }
    public var effectID: String { get throws { try ConversationDeviceEffectsCodec.effectID(actionID: actionID) } }
}

// Application-service transport contracts. A preflight failure is the only proven not-sent outcome.
public enum ConversationDeviceEffectDispatchFailure:Error,Sendable {case notSent}
public enum ConversationDeviceEffectServiceError:Error,Sendable {case notConfigured,invalidJournal,busy,stale,unavailable,originalNotFound,journalFull}

public struct ConversationDeviceEffectResultRequest:Codable,Sendable,Equatable {
    public let operation_id:String
    public let subeffect:ConversationDeviceSubeffectKind
    public let expected_effect_revision:Int
    public let binding_hash,lease_id,dispatch_operation_id:String
    public let outcome:ConversationDeviceSubeffectState
    public let receipt:ConversationDeviceEffectReceipt?
    private enum CodingKeys:String,CodingKey {case operation_id,subeffect,expected_effect_revision,binding_hash,lease_id,dispatch_operation_id,outcome,receipt}
    public init(operationID:UUID,subeffect:ConversationDeviceSubeffectKind,base:ConversationDeviceEffectRecord,outcome:ConversationDeviceSubeffectState,receipt:ConversationDeviceEffectReceipt?) throws {
        guard let original=base.subeffects[subeffect].dispatch,[ConversationDeviceSubeffectState.dispatched,.unknown].contains(base.subeffects[subeffect].state),
              [.succeeded,.unknown,.notExecuted].contains(outcome),(outcome == .unknown)==(receipt==nil),
              receipt.map({$0.outcome==outcome && $0.effect_id==base.id && $0.subeffect_id==base.subeffects[subeffect].id && $0.dispatch_operation_id==original.operation_id && $0.binding_hash==base.binding_hash && $0.action_digest==base.frozen.action_digest && $0.device_id==base.frozen.target.device_id && $0.device_generation==base.frozen.device_generation}) ?? true else {throw ConversationDeviceEffectError.invalidResponse}
        if let receipt {try ConversationDeviceEffectsCodec.validateObservation(receipt,base:base,kind:subeffect)}
        operation_id=operationID.uuidString.lowercased();self.subeffect=subeffect;expected_effect_revision=base.revision
        binding_hash=base.binding_hash;lease_id=base.frozen.lease_id;dispatch_operation_id=original.operation_id;self.outcome=outcome;self.receipt=receipt
    }
    public func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(operation_id,forKey:.operation_id);try c.encode(subeffect,forKey:.subeffect);try c.encode(expected_effect_revision,forKey:.expected_effect_revision);try c.encode(binding_hash,forKey:.binding_hash);try c.encode(lease_id,forKey:.lease_id);try c.encode(dispatch_operation_id,forKey:.dispatch_operation_id);try c.encode(outcome,forKey:.outcome);try c.encode(receipt,forKey:.receipt)}
}
public struct ConversationDeviceEffectStopRequest:Codable,Sendable,Equatable {
    public let operation_id:String
    public let expected_effect_revision:Int
    public let binding_hash:String
    public init(operationID:UUID,base:ConversationDeviceEffectRecord) throws {guard base.stop==nil,base.state != .succeeded else {throw ConversationDeviceEffectError.invalidResponse};operation_id=operationID.uuidString.lowercased();expected_effect_revision=base.revision;binding_hash=base.binding_hash}
}
public protocol ConversationDeviceEffectBackend:Sendable {
    func deviceEffectAvailability(_ reference:ConversationDeviceEffectReference) async throws -> Bool
    func readOriginalDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction) async throws -> ConversationDeviceEffectEnvelope
    func admitDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectAdmissionRequest) async throws -> ConversationDeviceEffectEnvelope
    func dispatchDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectDispatchRequest) async throws -> ConversationDeviceEffectEnvelope
    func recordDeviceEffectResult(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectResultRequest) async throws -> ConversationDeviceEffectEnvelope
    func stopDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectStopRequest) async throws -> ConversationDeviceEffectEnvelope
}
public struct UnconfiguredConversationDeviceEffectBackend:ConversationDeviceEffectBackend {
    public init(){}
    public func deviceEffectAvailability(_ reference:ConversationDeviceEffectReference) async throws -> Bool {false}
    public func readOriginalDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction) async throws -> ConversationDeviceEffectEnvelope {throw ConversationDeviceEffectServiceError.notConfigured}
    public func admitDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectAdmissionRequest) async throws -> ConversationDeviceEffectEnvelope {throw ConversationDeviceEffectServiceError.notConfigured}
    public func dispatchDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectDispatchRequest) async throws -> ConversationDeviceEffectEnvelope {throw ConversationDeviceEffectServiceError.notConfigured}
    public func recordDeviceEffectResult(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectResultRequest) async throws -> ConversationDeviceEffectEnvelope {throw ConversationDeviceEffectServiceError.notConfigured}
    public func stopDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectStopRequest) async throws -> ConversationDeviceEffectEnvelope {throw ConversationDeviceEffectServiceError.notConfigured}
}

public struct ConversationDeviceEffectPolicyReference: Codable, Sendable, Equatable {
    public let contract: String
    public let version: Int
    public let policy_hash: String
}
public struct ConversationExecutableTaskActionFrozenV2: Codable, Sendable, Equatable {
    public let contract, id, proposal_operation_id, scope_id, subject_id, conversation_id, turn_id, run_id, task_id, request_hash, delegation_id: String
    public let delegation_revision, grant_epoch: Int
    public let plan_reference: ConversationTaskActionPlanReference
    public let kind: String
    public let tool_version: Int
    public let target: ConversationDeviceCalendarTarget
    public let parameters: ConversationCalendarCreateParameters
    public let parameters_hash: String
    public let artifact_reference: ConversationTaskActionArtifactReference?
    public let execution_policy: ConversationDeviceEffectPolicyReference
    public let created_at, expires_at: String
    private enum CodingKeys: String, CodingKey { case contract,id,proposal_operation_id,scope_id,subject_id,conversation_id,turn_id,run_id,task_id,request_hash,delegation_id,delegation_revision,grant_epoch,plan_reference,kind,tool_version,target,parameters,parameters_hash,artifact_reference,execution_policy,created_at,expires_at }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(contract,forKey:.contract);try c.encode(id,forKey:.id);try c.encode(proposal_operation_id,forKey:.proposal_operation_id)
        try c.encode(scope_id,forKey:.scope_id);try c.encode(subject_id,forKey:.subject_id);try c.encode(conversation_id,forKey:.conversation_id)
        try c.encode(turn_id,forKey:.turn_id);try c.encode(run_id,forKey:.run_id);try c.encode(task_id,forKey:.task_id);try c.encode(request_hash,forKey:.request_hash)
        try c.encode(delegation_id,forKey:.delegation_id);try c.encode(delegation_revision,forKey:.delegation_revision);try c.encode(grant_epoch,forKey:.grant_epoch)
        try c.encode(plan_reference,forKey:.plan_reference);try c.encode(kind,forKey:.kind);try c.encode(tool_version,forKey:.tool_version)
        try c.encode(target,forKey:.target);try c.encode(parameters,forKey:.parameters);try c.encode(parameters_hash,forKey:.parameters_hash)
        try c.encode(artifact_reference,forKey:.artifact_reference);try c.encode(execution_policy,forKey:.execution_policy)
        try c.encode(created_at,forKey:.created_at);try c.encode(expires_at,forKey:.expires_at)
    }
}
/// This is the durable v2 decision consumed by the isolated backend primitive.
/// It is separate from the old v1 review receipt and grants no OS permission by itself.
public struct ConversationExecutableActionDecisionV2: Codable, Sendable, Equatable {
    public let id, contract, action_id, run_id, task_id, scope_id, subject_id, action_digest: String
    public let decision: ConversationTaskActionDecision
    public let execution_policy: ConversationDeviceEffectPolicyReference
    public let committed_at: String
}
public struct ConversationApprovedDeviceAction: Sendable, Equatable {
    public let reference: ConversationDeviceEffectReference
    public let frozen: ConversationExecutableTaskActionFrozenV2
    public let decision: ConversationExecutableActionDecisionV2
    fileprivate init(reference:ConversationDeviceEffectReference,frozen: ConversationExecutableTaskActionFrozenV2, decision: ConversationExecutableActionDecisionV2) { self.reference=reference;self.frozen=frozen;self.decision=decision }
}
public enum ConversationDeviceSubeffectKind: String, Codable, Sendable { case calendar, notification }
public enum ConversationDeviceSubeffectState: String, Codable, Sendable {
    case notDispatched="not_dispatched", notRequired="not_required", dispatched, unknown, succeeded, notExecuted="not_executed", cancelledBeforeDispatch="cancelled_before_dispatch"
}
public enum ConversationDeviceEffectState: String, Codable, Sendable { case admitted, dispatching, unknown, partialUnknown="partial_unknown", partial, succeeded, stopped }
public struct ConversationDeviceEffectAdmissionRequest: Codable, Sendable, Equatable {
    public let operation_id, action_id, decision_operation_id: String
    public let expected_action_revision: Int
    public let action_digest: String
    public let expected_grant_epoch, expected_plan_revision: Int
    public let expected_plan_hash: String
    public let expected_execution_revision: Int
    public let device_id, calendar_snapshot_hash: String
    public let policy_reference: ConversationDeviceEffectPolicyReference
    public init(operationID: UUID, reference: ConversationDeviceEffectReference, action: ConversationApprovedDeviceAction, executionRevision: Int) throws {
        guard reference==action.reference, executionRevision >= 0, executionRevision <= 9_007_199_254_740_991 else {throw ConversationDeviceEffectError.invalidResponse}
        operation_id=operationID.uuidString.lowercased();action_id=reference.actionID;decision_operation_id=reference.decisionOperationID
        expected_action_revision=reference.actionRevision;action_digest=reference.actionDigest;expected_grant_epoch=reference.binding.grant_epoch
        expected_plan_revision=action.frozen.plan_reference.revision;expected_plan_hash=action.frozen.plan_reference.plan_hash
        expected_execution_revision=executionRevision;device_id=action.frozen.target.device_id;calendar_snapshot_hash=action.frozen.target.calendar_snapshot_hash
        policy_reference=action.frozen.execution_policy
    }
}
public struct ConversationDeviceEffectDispatchRequest: Codable, Sendable, Equatable {
    public let operation_id: String
    public let subeffect: ConversationDeviceSubeffectKind
    public let expected_effect_revision: Int
    public let binding_hash, lease_id: String
    public init(operationID: UUID, subeffect: ConversationDeviceSubeffectKind, expectedRevision: Int, bindingHash: String, leaseID: String) throws {
        guard ConversationTaskActionValidation.positive(expectedRevision), ConversationTaskActionValidation.hash(bindingHash), ConversationTaskActionValidation.uuid(leaseID) else {throw ConversationDeviceEffectError.invalidResponse}
        self.operation_id=operationID.uuidString.lowercased();self.subeffect=subeffect;self.expected_effect_revision=expectedRevision;self.binding_hash=bindingHash;self.lease_id=leaseID
    }
}
public struct ConversationDeviceEffectFrozen: Codable, Sendable, Equatable {
    public let id, action_id, action_digest, decision_operation_id, scope_id, subject_id, conversation_id, turn_id, run_id, task_id, run_request_hash, delegation_id: String
    public let delegation_revision, grant_epoch, execution_revision: Int
    public let task_lease_id, task_lease_until: String?
    public let target: ConversationDeviceCalendarTarget
    public let parameters: ConversationCalendarCreateParameters
    public let device_generation: Int
    public let policy_reference: ConversationDeviceEffectPolicyReference
    public let admission_operation_id, admission_request_hash, admitted_at, approval_expires_at, lease_id, lease_expires_at: String
    private enum CodingKeys: String,CodingKey {case id,action_id,action_digest,decision_operation_id,scope_id,subject_id,conversation_id,turn_id,run_id,task_id,run_request_hash,delegation_id,delegation_revision,grant_epoch,execution_revision,task_lease_id,task_lease_until,target,parameters,device_generation,policy_reference,admission_operation_id,admission_request_hash,admitted_at,approval_expires_at,lease_id,lease_expires_at}
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(action_id,forKey:.action_id);try c.encode(action_digest,forKey:.action_digest);try c.encode(decision_operation_id,forKey:.decision_operation_id)
        try c.encode(scope_id,forKey:.scope_id);try c.encode(subject_id,forKey:.subject_id);try c.encode(conversation_id,forKey:.conversation_id);try c.encode(turn_id,forKey:.turn_id)
        try c.encode(run_id,forKey:.run_id);try c.encode(task_id,forKey:.task_id);try c.encode(run_request_hash,forKey:.run_request_hash);try c.encode(delegation_id,forKey:.delegation_id)
        try c.encode(delegation_revision,forKey:.delegation_revision);try c.encode(grant_epoch,forKey:.grant_epoch);try c.encode(execution_revision,forKey:.execution_revision)
        try c.encode(task_lease_id,forKey:.task_lease_id);try c.encode(task_lease_until,forKey:.task_lease_until);try c.encode(target,forKey:.target);try c.encode(parameters,forKey:.parameters)
        try c.encode(device_generation,forKey:.device_generation);try c.encode(policy_reference,forKey:.policy_reference);try c.encode(admission_operation_id,forKey:.admission_operation_id)
        try c.encode(admission_request_hash,forKey:.admission_request_hash);try c.encode(admitted_at,forKey:.admitted_at);try c.encode(approval_expires_at,forKey:.approval_expires_at)
        try c.encode(lease_id,forKey:.lease_id);try c.encode(lease_expires_at,forKey:.lease_expires_at)
    }
}
public struct ConversationDeviceEffectDispatchRecord: Codable, Sendable, Equatable {
    public let contract, effect_id, subeffect_id: String
    public let kind: ConversationDeviceSubeffectKind
    public let operation_id, request_hash, binding_hash, lease_id, dispatched_at, dispatch_hash: String
}
public struct ConversationDeviceCalendarReceiptReference: Codable, Sendable, Equatable {
    public let calendar_id, event_identifier, calendar_item_identifier: String
    public let external_identifier: String?
    public let effect_marker, content_hash: String
    private enum CodingKeys: String,CodingKey {case calendar_id,event_identifier,calendar_item_identifier,external_identifier,effect_marker,content_hash}
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(calendar_id,forKey:.calendar_id);try c.encode(event_identifier,forKey:.event_identifier)
        try c.encode(calendar_item_identifier,forKey:.calendar_item_identifier);try c.encode(external_identifier,forKey:.external_identifier)
        try c.encode(effect_marker,forKey:.effect_marker);try c.encode(content_hash,forKey:.content_hash)
    }
}
public struct ConversationDeviceNotificationReceiptReference: Codable, Sendable, Equatable {
    public let request_identifier, schedule_hash, due_at, state: String
}
public struct ConversationDeviceEffectReceipt: Codable, Sendable, Equatable {
    public let contract, effect_id, subeffect_id, dispatch_operation_id, action_digest, binding_hash, device_id: String
    public let device_generation: Int
    public let outcome: ConversationDeviceSubeffectState
    public let external_reference: ConversationTaskActionJSON
    public let observed_at: String
    public var calendarReference: ConversationDeviceCalendarReceiptReference? {try? external_reference.decoded(ConversationDeviceCalendarReceiptReference.self)}
    public var notificationReference: ConversationDeviceNotificationReceiptReference? {try? external_reference.decoded(ConversationDeviceNotificationReceiptReference.self)}
}
public struct ConversationDeviceSubeffect: Codable, Sendable, Equatable {
    public let id: String
    public let kind: ConversationDeviceSubeffectKind
    public let state: ConversationDeviceSubeffectState
    public let dispatch: ConversationDeviceEffectDispatchRecord?
    public let receipt: ConversationDeviceEffectReceipt?
    public let receipt_hash, result_operation_id: String?
    private enum CodingKeys:String,CodingKey {case id,kind,state,dispatch,receipt,receipt_hash,result_operation_id}
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(id,forKey:.id);try c.encode(kind,forKey:.kind);try c.encode(state,forKey:.state)
        try c.encode(dispatch,forKey:.dispatch);try c.encode(receipt,forKey:.receipt);try c.encode(receipt_hash,forKey:.receipt_hash);try c.encode(result_operation_id,forKey:.result_operation_id)
    }
}
public struct ConversationDeviceSubeffects: Codable, Sendable, Equatable {
    public let calendar, notification: ConversationDeviceSubeffect
    public subscript(_ kind: ConversationDeviceSubeffectKind) -> ConversationDeviceSubeffect {kind == .calendar ? calendar : notification}
}
public struct ConversationDeviceEffectStop: Codable, Sendable, Equatable {public let operation_id, reason, stopped_at: String}
public struct ConversationDeviceUnresolvedSubeffect: Codable, Sendable, Equatable {
    public let kind: ConversationDeviceSubeffectKind
    public let subeffect_id, dispatch_operation_id: String
    public let state: ConversationDeviceSubeffectState
    public let can_retry: Bool
}
public struct ConversationDeviceEffectRecord: Codable, Sendable, Equatable {
    public let id, contract: String
    public let frozen: ConversationDeviceEffectFrozen
    public let binding_hash: String
    public let revision: Int
    public let stop: ConversationDeviceEffectStop?
    public let subeffects: ConversationDeviceSubeffects
    public let record_hash: String
    public let state: ConversationDeviceEffectState
    public let execution_current: Bool
    public let unresolved_subeffects: [ConversationDeviceUnresolvedSubeffect]
    public let can_redispatch: Bool
    private enum CodingKeys:String,CodingKey {case id,contract,frozen,binding_hash,revision,stop,subeffects,record_hash,state,execution_current,unresolved_subeffects,can_redispatch}
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(id,forKey:.id);try c.encode(contract,forKey:.contract);try c.encode(frozen,forKey:.frozen)
        try c.encode(binding_hash,forKey:.binding_hash);try c.encode(revision,forKey:.revision);try c.encode(stop,forKey:.stop);try c.encode(subeffects,forKey:.subeffects)
        try c.encode(record_hash,forKey:.record_hash);try c.encode(state,forKey:.state);try c.encode(execution_current,forKey:.execution_current)
        try c.encode(unresolved_subeffects,forKey:.unresolved_subeffects);try c.encode(can_redispatch,forKey:.can_redispatch)
    }
}
/// No Decodable, Codable or public initializer: original GET decoding cannot manufacture this value.
/// The service must only pass a new dispatch response, never cached first-response bytes.
/// This is transport admission only; a later executor still needs one-consume, fresh authority/OS gates.
public struct ConversationDeviceDispatchPermit: Sendable, Equatable {
    public let dispatch: ConversationDeviceEffectDispatchRecord
    public let leaseExpiresAt: String
    fileprivate init(dispatch:ConversationDeviceEffectDispatchRecord,leaseExpiresAt:String) {self.dispatch=dispatch;self.leaseExpiresAt=leaseExpiresAt}
}
public struct ConversationDeviceEffectEnvelope: Sendable, Equatable {
    public let effect: ConversationDeviceEffectRecord
    public let dispatchPermit: ConversationDeviceDispatchPermit?
    fileprivate init(effect:ConversationDeviceEffectRecord,dispatchPermit:ConversationDeviceDispatchPermit?) {self.effect=effect;self.dispatchPermit=dispatchPermit}
}

/// Pure strict wire codec. It imports no network, UI, account manager, OS or executor.
public enum ConversationDeviceEffectsCodec {
    public static let effectContract="catpaw.device-effect.v1"
    public static let actionContract="catpaw.task-action.v2"
    private static let maximumBytes=512_000
    public static func canonicalHash<T:Encodable>(_ value:T) throws -> String {try ConversationTaskActionJSON.value(value).digest()}
    public static func canonicalHashJSON(_ data:Data) throws -> String {_=try ConversationStrictJSON.object(data,maxBytes:maximumBytes);return try JSONDecoder().decode(ConversationTaskActionJSON.self,from:data).digest()}
    public static func supportedPolicy() throws -> ConversationDeviceEffectPolicyReference {
        let policy=ConversationTaskActionJSON.object(["contract":.string(effectContract),"version":.integer(1),"action_kind":.string("calendar.create.v2"),"notification_channel":.string("catpaw_local_notification"),"unknown_recovery":.string("original_only"),"execution_location":.string("registered_device")])
        return .init(contract:effectContract,version:1,policy_hash:try policy.digest())
    }
    public static func effectID(actionID:String) throws -> String {guard ConversationTaskActionValidation.uuid(actionID) else {throw ConversationDeviceEffectError.invalidResponse};return try identity(["contract":.string(effectContract),"action_id":.string(actionID)])}
    public static func subeffectID(effectID:String,kind:ConversationDeviceSubeffectKind) throws -> String {guard ConversationTaskActionValidation.uuid(effectID) else {throw ConversationDeviceEffectError.invalidResponse};return try identity(["contract":.string(effectContract),"effect_id":.string(effectID),"kind":.string(kind.rawValue)])}
    private static func leaseID(effectID:String,operationID:String) throws -> String {try identity(["contract":.string(effectContract),"effect_id":.string(effectID),"admission_operation_id":.string(operationID),"lease":.integer(1)])}
    private static func identity(_ fields:[String:ConversationTaskActionJSON]) throws -> String {
        let h=Array(try ConversationTaskActionJSON.object(fields).digest())
        return String(h[0..<8])+"-"+String(h[8..<12])+"-4"+String(h[13..<16])+"-8"+String(h[17..<20])+"-"+String(h[20..<32])
    }
    public static func decodeApprovedAction(frozenData:Data,decisionData:Data,reference:ConversationDeviceEffectReference) throws -> ConversationApprovedDeviceAction {
        let raw=try object(frozenData);try frozenShape(raw)
        let f=try JSONDecoder().decode(ConversationExecutableTaskActionFrozenV2.self,from:frozenData)
        let dRaw=try object(decisionData);try keys(dRaw,"id contract action_id run_id task_id scope_id subject_id action_digest decision execution_policy committed_at");try policyShape(dict(dRaw,"execution_policy"))
        let d=try JSONDecoder().decode(ConversationExecutableActionDecisionV2.self,from:decisionData),b=reference.binding
        guard f.contract==actionContract,f.kind=="calendar.create.v2",f.tool_version==2,
              [f.id,f.proposal_operation_id,f.scope_id,f.subject_id,f.conversation_id,f.turn_id,f.run_id,f.delegation_id].allSatisfy(ConversationTaskActionValidation.uuid),
              f.id==reference.actionID,f.scope_id==b.scope_id.uuidString.lowercased(),f.subject_id==reference.subjectID,
              f.conversation_id==b.conversation_id.uuidString.lowercased(),f.turn_id==b.turn_id.uuidString.lowercased(),f.run_id==b.run_id.uuidString.lowercased(),
              f.task_id==b.task_id,f.request_hash==b.request_hash,f.delegation_id==b.delegation_id.uuidString.lowercased(),
              f.delegation_revision==b.delegation_revision,f.grant_epoch==b.grant_epoch,
              ConversationTaskActionValidation.positive(f.plan_reference.revision),ConversationTaskActionValidation.hash(f.plan_reference.plan_hash),
              f.parameters_hash==(try canonicalHash(f.parameters)),reference.actionDigest==(try canonicalHash(f)),
              f.parameters.start_at.hasSuffix(".000Z"),f.parameters.end_at.hasSuffix(".000Z"),date(f.parameters.start_at) != nil,date(f.parameters.end_at) != nil,
              try f.execution_policy==supportedPolicy(),let created=date(f.created_at),let expires=date(f.expires_at),expires.timeIntervalSince(created)==1800,
              d.contract==actionContract,d.id==reference.decisionOperationID,d.action_id==f.id,d.run_id==f.run_id,d.task_id==f.task_id,
              d.scope_id==f.scope_id,d.subject_id==f.subject_id,d.action_digest==reference.actionDigest,d.decision == .approve,d.execution_policy==f.execution_policy,
              let committed=date(d.committed_at),committed>=created,committed<expires else {throw ConversationDeviceEffectError.referenceMismatch}
        try f.target.validate();try f.parameters.validate()
        if let a=f.artifact_reference {guard a.artifact_id.range(of:"^[A-Za-z0-9._-]{1,256}$",options:.regularExpression) != nil,ConversationTaskActionValidation.positive(a.version),ConversationTaskActionValidation.hash(a.content_hash) else {throw ConversationDeviceEffectError.invalidResponse}}
        guard ![f.id,f.proposal_operation_id,f.scope_id,f.conversation_id,f.turn_id,f.run_id,f.delegation_id].contains(d.id) else {throw ConversationDeviceEffectError.invalidResponse}
        return .init(reference:reference,frozen:f,decision:d)
    }
    public static func decodeOriginal(_ data:Data,reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction) throws -> ConversationDeviceEffectEnvelope {
        let raw=try object(data)
        guard raw["dispatch_permit"] is NSNull else {throw ConversationDeviceEffectError.invalidResponse}
        return .init(effect:try record(raw,reference:reference,action:action),dispatchPermit:nil)
    }
    public static func decodeDispatchResponse(_ data:Data,reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectDispatchRequest) throws -> ConversationDeviceEffectEnvelope {
        guard ConversationTaskActionValidation.uuid(request.operation_id),ConversationTaskActionValidation.positive(request.expected_effect_revision),ConversationTaskActionValidation.hash(request.binding_hash),ConversationTaskActionValidation.uuid(request.lease_id) else {throw ConversationDeviceEffectError.invalidResponse}
        let raw=try object(data),r=try record(raw,reference:reference,action:action)
        if raw["dispatch_permit"] is NSNull {return .init(effect:r,dispatchPermit:nil)}
        let p=try dict(raw,"dispatch_permit")
        try keys(p,"contract effect_id subeffect_id kind operation_id request_hash binding_hash lease_id dispatched_at dispatch_hash lease_expires_at")
        var dispatch=p;dispatch.removeValue(forKey:"lease_expires_at")
        let wire=try JSONDecoder().decode(ConversationDeviceEffectDispatchRecord.self,from:json(dispatch))
        let child=r.subeffects[request.subeffect]
        guard r.execution_current,r.stop==nil,r.state == .dispatching,child.state == .dispatched,child.receipt==nil,
              wire==child.dispatch,wire.kind==request.subeffect,wire.operation_id==request.operation_id,
              wire.request_hash==(try canonicalHash(request)),wire.binding_hash==request.binding_hash,wire.lease_id==request.lease_id,
              r.revision==request.expected_effect_revision+1,p["lease_expires_at"] as? String==r.frozen.lease_expires_at else {throw ConversationDeviceEffectError.invalidResponse}
        return .init(effect:r,dispatchPermit:.init(dispatch:wire,leaseExpiresAt:r.frozen.lease_expires_at))
    }
    private static func record(_ raw:[String:Any],reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction) throws -> ConversationDeviceEffectRecord {
        guard reference==action.reference else {throw ConversationDeviceEffectError.referenceMismatch}
        try keys(raw,"schema_version contract effect dispatch_permit")
        guard let schema=raw["schema_version"] as? NSNumber,CFGetTypeID(schema) != CFBooleanGetTypeID(),schema.intValue==1,raw["contract"] as? String==effectContract else {throw ConversationDeviceEffectError.invalidResponse}
        let e=try dict(raw,"effect");try keys(e,"id contract frozen binding_hash revision stop subeffects record_hash state execution_current unresolved_subeffects can_redispatch")
        let fRaw=try dict(e,"frozen")
        try keys(fRaw,"id action_id action_digest decision_operation_id scope_id subject_id conversation_id turn_id run_id task_id run_request_hash delegation_id delegation_revision grant_epoch execution_revision task_lease_id task_lease_until target parameters device_generation policy_reference admission_operation_id admission_request_hash admitted_at approval_expires_at lease_id lease_expires_at")
        try targetShape(dict(fRaw,"target"));try parametersShape(dict(fRaw,"parameters"));try policyShape(dict(fRaw,"policy_reference"))
        let children=try dict(e,"subeffects");try keys(children,"calendar notification")
        for kind in [ConversationDeviceSubeffectKind.calendar,.notification] {try childShape(dict(children,kind.rawValue),kind:kind)}
        if !(e["stop"] is NSNull) {try keys(dict(e,"stop"),"operation_id reason stopped_at")}
        guard let unresolved=e["unresolved_subeffects"] as? [[String:Any]],unresolved.count<=2 else {throw ConversationDeviceEffectError.invalidResponse}
        for u in unresolved {try keys(u,"kind subeffect_id dispatch_operation_id state can_retry")}
        let r=try JSONDecoder().decode(ConversationDeviceEffectRecord.self,from:json(e)),f=r.frozen,a=action.frozen
        var sealed=e
        for k in ["record_hash","state","execution_current","unresolved_subeffects","can_redispatch"] {sealed.removeValue(forKey:k)}
        guard r.contract==effectContract,r.id==(try reference.effectID),f.id==r.id,
              r.record_hash==(try hashObject(sealed)),r.binding_hash==(try canonicalHash(f)),ConversationTaskActionValidation.positive(r.revision),!r.can_redispatch,
              f.action_id==reference.actionID,f.action_digest==reference.actionDigest,f.decision_operation_id==reference.decisionOperationID,
              f.scope_id==a.scope_id,f.subject_id==a.subject_id,f.conversation_id==a.conversation_id,f.turn_id==a.turn_id,f.run_id==a.run_id,
              f.task_id==a.task_id,f.run_request_hash==a.request_hash,f.delegation_id==a.delegation_id,f.delegation_revision==a.delegation_revision,f.grant_epoch==a.grant_epoch,
              (try canonicalHash(f.target))==(try canonicalHash(a.target)),(try canonicalHash(f.parameters))==a.parameters_hash,f.policy_reference==a.execution_policy,f.approval_expires_at==a.expires_at,
              f.execution_revision>=0,f.device_generation>0,ConversationTaskActionValidation.uuid(f.admission_operation_id),ConversationTaskActionValidation.hash(f.admission_request_hash),
              f.lease_id==(try leaseID(effectID:r.id,operationID:f.admission_operation_id)),
              let admitted=date(f.admitted_at),let expiry=date(f.lease_expires_at),let approvalExpiry=date(f.approval_expires_at),
              let decisionAt=date(action.decision.committed_at),admitted>=decisionAt,expiry>admitted,expiry.timeIntervalSince(admitted)<=15,expiry<=approvalExpiry,
              (f.task_lease_id==nil)==(f.task_lease_until==nil),f.task_lease_id.map(ConversationTaskActionValidation.uuid) ?? true,
              f.task_lease_until.map({date($0).map{$0>admitted} ?? false}) ?? true else {throw ConversationDeviceEffectError.referenceMismatch}
        let expectedAdmission=try ConversationDeviceEffectAdmissionRequest(operationID:UUID(uuidString:f.admission_operation_id)!,reference:reference,action:action,executionRevision:f.execution_revision)
        guard f.admission_request_hash==(try canonicalHash(expectedAdmission)) else {throw ConversationDeviceEffectError.referenceMismatch}
        var operations=[f.admission_operation_id]
        var expectedUnknown:[ConversationDeviceUnresolvedSubeffect]=[]
        for kind in [ConversationDeviceSubeffectKind.calendar,.notification] {
            let c=r.subeffects[kind]
            guard c.id==(try subeffectID(effectID:r.id,kind:kind)),c.kind==kind else {throw ConversationDeviceEffectError.invalidResponse}
            if [.notDispatched,.notRequired,.cancelledBeforeDispatch].contains(c.state) {guard c.dispatch==nil,c.receipt==nil,c.receipt_hash==nil,c.result_operation_id==nil else {throw ConversationDeviceEffectError.invalidResponse}}
            else {guard c.dispatch != nil else {throw ConversationDeviceEffectError.invalidResponse}}
            if c.state == .notRequired {guard kind == .notification,f.parameters.reminder_offset_seconds==nil else {throw ConversationDeviceEffectError.invalidResponse}}
            if kind == .calendar {guard c.state != .notRequired else {throw ConversationDeviceEffectError.invalidResponse}}
            if c.state == .cancelledBeforeDispatch {guard r.stop != nil else {throw ConversationDeviceEffectError.invalidResponse}}
            if let d=c.dispatch {
                let dRaw=try dict(try dict(children,kind.rawValue),"dispatch")
                var body=dRaw;body.removeValue(forKey:"dispatch_hash")
                guard d.contract==effectContract,d.effect_id==r.id,d.subeffect_id==c.id,d.kind==kind,d.binding_hash==r.binding_hash,d.lease_id==f.lease_id,
                      ConversationTaskActionValidation.uuid(d.operation_id),ConversationTaskActionValidation.hash(d.request_hash),d.dispatch_hash==(try hashObject(body)),
                      let dispatched=date(d.dispatched_at),dispatched>=admitted,dispatched<expiry else {throw ConversationDeviceEffectError.invalidResponse}
                operations.append(d.operation_id)
                if [.dispatched,.unknown].contains(c.state) {expectedUnknown.append(.init(kind:kind,subeffect_id:c.id,dispatch_operation_id:d.operation_id,state:c.state,can_retry:false))}
            }
            if let op=c.result_operation_id {guard ConversationTaskActionValidation.uuid(op) else {throw ConversationDeviceEffectError.invalidResponse};operations.append(op)}
            if let receipt=c.receipt {
                guard c.result_operation_id != nil,[.succeeded,.notExecuted].contains(c.state),receipt.outcome==c.state,c.receipt_hash==(try canonicalHash(receipt)) else {throw ConversationDeviceEffectError.invalidResponse}
                try validateObservation(receipt,base:r,kind:kind)
            } else {guard ![.succeeded,.notExecuted].contains(c.state),c.receipt_hash==nil else {throw ConversationDeviceEffectError.invalidResponse}}
        }
        if r.subeffects.notification.dispatch != nil {guard r.subeffects.calendar.state == .succeeded,f.parameters.reminder_offset_seconds != nil else {throw ConversationDeviceEffectError.invalidResponse}}
        if let stop=r.stop {guard ConversationTaskActionValidation.uuid(stop.operation_id),stop.reason=="user_stopped",let stoppedAt=date(stop.stopped_at),stoppedAt>=admitted,!r.execution_current else {throw ConversationDeviceEffectError.invalidResponse};operations.append(stop.operation_id)}
        let forbidden=[r.id,f.lease_id,a.id,a.proposal_operation_id,a.scope_id,a.conversation_id,a.turn_id,a.run_id,a.delegation_id,action.decision.id,r.subeffects.calendar.id,r.subeffects.notification.id]
        guard Set(operations).count==operations.count,!operations.contains(where:{forbidden.contains($0)}),
              expectedUnknown.sorted(by:{$0.kind.rawValue<$1.kind.rawValue})==r.unresolved_subeffects.sorted(by:{$0.kind.rawValue<$1.kind.rawValue}) else {throw ConversationDeviceEffectError.invalidResponse}
        let states=[r.subeffects.calendar.state,r.subeffects.notification.state]
        let computed:ConversationDeviceEffectState
        if r.stop != nil {computed = .stopped}
        else if states.allSatisfy({[.succeeded,.notRequired].contains($0)}) {computed = .succeeded}
        else if states.contains(.unknown) {computed=states.contains(.succeeded) ? .partialUnknown : .unknown}
        else if states.contains(.notExecuted) {computed = .partial}
        else if states.contains(.dispatched) {computed = .dispatching}
        else {computed=states.contains(.succeeded) ? .partial : .admitted}
        // The server conservatively projects an expired dispatched outcome as unknown.
        let expiredUnknown=states.contains(.dispatched) && !r.execution_current && r.stop==nil && r.state==(states.contains(.succeeded) ? .partialUnknown : .unknown)
        guard r.state==computed || expiredUnknown else {throw ConversationDeviceEffectError.invalidResponse}
        return r
    }
    /// Shared structural validation for an outgoing observation and the original server projection.
    /// It validates immutable identity; the backend still needs a registered-device OS proof verifier.
    static func validateObservation(_ receipt:ConversationDeviceEffectReceipt,base r:ConversationDeviceEffectRecord,kind:ConversationDeviceSubeffectKind) throws {
        let c=r.subeffects[kind],f=r.frozen
        guard let d=c.dispatch,[.succeeded,.notExecuted].contains(receipt.outcome),
              receipt.contract==effectContract,receipt.effect_id==r.id,receipt.subeffect_id==c.id,receipt.dispatch_operation_id==d.operation_id,
              receipt.action_digest==f.action_digest,receipt.binding_hash==r.binding_hash,receipt.device_id==f.target.device_id,receipt.device_generation==f.device_generation,
              let observed=date(receipt.observed_at),let dispatched=date(d.dispatched_at),observed>=dispatched else {throw ConversationDeviceEffectError.invalidResponse}
        _=try canonicalHash(receipt)
        if receipt.outcome == .notExecuted {guard receipt.external_reference == .null else {throw ConversationDeviceEffectError.invalidResponse}}
        else if kind == .calendar {
            guard let v=receipt.calendarReference,try canonicalHash(v)==receipt.external_reference.digest(),v.calendar_id.utf16.elementsEqual(f.target.calendar_id.utf16),v.effect_marker=="catpawm://calendar-effect/"+c.id,
                  [v.calendar_id,v.event_identifier,v.calendar_item_identifier,v.effect_marker].allSatisfy({validText($0,limit:512)}),
                  v.external_identifier.map({$0.utf16.count<=512}) ?? true,ConversationTaskActionValidation.hash(v.content_hash) else {throw ConversationDeviceEffectError.invalidResponse}
        } else {
            guard let v=receipt.notificationReference,try canonicalHash(v)==receipt.external_reference.digest(),let offset=f.parameters.reminder_offset_seconds,let start=date(f.parameters.start_at),v.request_identifier==c.id,
                  ["pending","delivered"].contains(v.state),date(v.due_at)==start.addingTimeInterval(Double(offset)),
                  v.schedule_hash==(try ConversationTaskActionJSON.object(["subeffect_id":.string(c.id),"due_at":.string(v.due_at),"parameters_hash":.string(try canonicalHash(f.parameters)),"channel":.string("catpaw_local_notification")]).digest()) else {throw ConversationDeviceEffectError.invalidResponse}
        }
    }
    private static func object(_ data:Data) throws -> [String:Any] {
        let raw=try ConversationStrictJSON.object(data,maxBytes:maximumBytes)
        // Every number in this contract is an exact JS-safe integer; Bool remains a distinct JSON type.
        _=try JSONDecoder().decode(ConversationTaskActionJSON.self,from:data)
        return raw
    }
    private static func keys(_ value:[String:Any],_ fields:String) throws {guard Set(value.keys)==Set(fields.split(separator:" ").map(String.init)) else {throw ConversationDeviceEffectError.invalidResponse}}
    private static func dict(_ value:[String:Any],_ key:String) throws -> [String:Any] {guard let d=value[key] as? [String:Any] else {throw ConversationDeviceEffectError.invalidResponse};return d}
    private static func json(_ value:[String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    private static func hashObject(_ value:[String:Any]) throws -> String {try canonicalHashJSON(json(value))}
    private static func date(_ value:String)->Date? {guard let d=ConversationTaskActionValidation.utc(value),d.timeIntervalSince1970>=0,d.timeIntervalSince1970<4_133_980_800 else {return nil};return d}
    private static func validText(_ value:String,limit:Int)->Bool {value.utf16.count>0 && value.utf16.count<=limit && !value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127})}
    private static func policyShape(_ value:[String:Any]) throws {try keys(value,"contract version policy_hash")}
    private static func targetShape(_ value:[String:Any]) throws {try keys(value,"device_id environment_id calendar_id calendar_display_name calendar_snapshot_hash")}
    private static func parametersShape(_ value:[String:Any]) throws {try keys(value,"title start_at end_at time_zone reminder_offset_seconds")}
    private static func frozenShape(_ value:[String:Any]) throws {
        try keys(value,"contract id proposal_operation_id scope_id subject_id conversation_id turn_id run_id task_id request_hash delegation_id delegation_revision grant_epoch plan_reference kind tool_version target parameters parameters_hash artifact_reference execution_policy created_at expires_at")
        try keys(dict(value,"plan_reference"),"revision plan_hash");try targetShape(dict(value,"target"));try parametersShape(dict(value,"parameters"));try policyShape(dict(value,"execution_policy"))
        if !(value["artifact_reference"] is NSNull) {try keys(dict(value,"artifact_reference"),"artifact_id version content_hash")}
    }
    private static func childShape(_ value:[String:Any],kind:ConversationDeviceSubeffectKind) throws {
        try keys(value,"id kind state dispatch receipt receipt_hash result_operation_id")
        if !(value["dispatch"] is NSNull) {try keys(dict(value,"dispatch"),"contract effect_id subeffect_id kind operation_id request_hash binding_hash lease_id dispatched_at dispatch_hash")}
        if !(value["receipt"] is NSNull) {
            let r=try dict(value,"receipt");try keys(r,"contract effect_id subeffect_id dispatch_operation_id action_digest binding_hash device_id device_generation outcome external_reference observed_at")
            if !(r["external_reference"] is NSNull) {try keys(dict(r,"external_reference"),kind == .calendar ? "calendar_id event_identifier calendar_item_identifier external_identifier effect_marker content_hash" : "request_identifier schedule_hash due_at state")}
        }
    }
}
