import Foundation
import CoreFoundation

/// Reuses the existing authenticated session, redirect policy and account teardown.
extension NativeChatHTTPBackend:ConversationDeviceEffectBackend {
    private static func deviceBoolean(_ value:Any?)->Bool? {guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {return nil};return n.boolValue}
    private static func deviceBody<T:Encodable>(_ value:T) throws -> Data {
        do {
            let data=try ConversationTaskActionJSON.encoded(value)
            guard data.count<=32_768 else {throw ConversationDeviceEffectError.invalidResponse}
            _=try ConversationDeviceEffectsCodec.canonicalHashJSON(data)
            return data
        } catch {throw ConversationDeviceEffectDispatchFailure.notSent}
    }
    public func deviceEffectAvailability(_ reference:ConversationDeviceEffectReference) async throws -> Bool {
        let data=try await deviceEffectReadinessWire(reference:reference)
        let ready=try ConversationStrictJSON.object(data,maxBytes:128_000)
        guard Self.deviceBoolean(ready["ready"])==true,let caps=ready["chat_capabilities"] as? [String:Any],let effect=caps["device_effects"] as? [String:Any],
              effect["contract"] as? String==ConversationDeviceEffectsCodec.effectContract,effect["action_contract"] as? String==ConversationDeviceEffectsCodec.actionContract,
              Self.deviceBoolean(effect["unknown_resend"])==false,
              ["read","admit","dispatch","record","stop","registered_device","verified_target","verified_receipts"].allSatisfy({Self.deviceBoolean(effect[$0])==true}),
              let policy=effect["policy_reference"] as? [String:Any],Set(policy.keys)==Set(["contract","version","policy_hash"]),
              let number=policy["version"] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue==1 else {return false}
        let supported=try ConversationDeviceEffectsCodec.supportedPolicy()
        return policy["contract"] as? String==supported.contract && policy["policy_hash"] as? String==supported.policy_hash
    }
    public func readOriginalDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction) async throws -> ConversationDeviceEffectEnvelope {
        guard reference==action.reference else {throw ConversationDeviceEffectError.referenceMismatch}
        return try ConversationDeviceEffectsCodec.decodeOriginal(await deviceEffectWire(reference:reference,suffix:"",body:nil,limit:512_000),reference:reference,action:action)
    }
    public func admitDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectAdmissionRequest) async throws -> ConversationDeviceEffectEnvelope {
        do {
            guard reference==action.reference,ConversationTaskActionValidation.uuid(request.operation_id),let operation=UUID(uuidString:request.operation_id),try request==ConversationDeviceEffectAdmissionRequest(operationID:operation,reference:reference,action:action,executionRevision:request.expected_execution_revision) else {throw ConversationDeviceEffectError.referenceMismatch}
        } catch {throw ConversationDeviceEffectDispatchFailure.notSent}
        let body=try Self.deviceBody(request)
        let data=try await deviceEffectWire(reference:reference,suffix:"admissions",body:body,limit:512_000)
        let result=try ConversationDeviceEffectsCodec.decodeOriginal(data,reference:reference,action:action)
        guard result.effect.frozen.admission_operation_id==request.operation_id,result.effect.frozen.admission_request_hash==(try ConversationDeviceEffectsCodec.canonicalHash(request)) else {throw ConversationDeviceEffectError.invalidResponse}
        return result
    }
    public func dispatchDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectDispatchRequest) async throws -> ConversationDeviceEffectEnvelope {
        guard reference==action.reference,ConversationTaskActionValidation.uuid(request.operation_id),ConversationTaskActionValidation.positive(request.expected_effect_revision),ConversationTaskActionValidation.hash(request.binding_hash),ConversationTaskActionValidation.uuid(request.lease_id) else {throw ConversationDeviceEffectDispatchFailure.notSent}
        let body=try Self.deviceBody(request)
        let data=try await deviceEffectWire(reference:reference,suffix:"dispatches",body:body,limit:512_000)
        return try ConversationDeviceEffectsCodec.decodeDispatchResponse(data,reference:reference,action:action,request:request)
    }
    public func recordDeviceEffectResult(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectResultRequest) async throws -> ConversationDeviceEffectEnvelope {
        guard reference==action.reference,ConversationTaskActionValidation.uuid(request.operation_id),ConversationTaskActionValidation.positive(request.expected_effect_revision),ConversationTaskActionValidation.uuid(request.dispatch_operation_id),ConversationTaskActionValidation.uuid(request.lease_id),ConversationTaskActionValidation.hash(request.binding_hash),[.succeeded,.unknown,.notExecuted].contains(request.outcome),(request.outcome == .unknown)==(request.receipt==nil) else {throw ConversationDeviceEffectDispatchFailure.notSent}
        let body=try Self.deviceBody(request)
        let data=try await deviceEffectWire(reference:reference,suffix:"results",body:body,limit:512_000)
        let result=try ConversationDeviceEffectsCodec.decodeOriginal(data,reference:reference,action:action),child=result.effect.subeffects[request.subeffect]
        guard child.result_operation_id==request.operation_id,child.state==request.outcome,child.receipt==request.receipt else {throw ConversationDeviceEffectError.invalidResponse};return result
    }
    public func stopDeviceEffect(_ reference:ConversationDeviceEffectReference,action:ConversationApprovedDeviceAction,request:ConversationDeviceEffectStopRequest) async throws -> ConversationDeviceEffectEnvelope {
        guard reference==action.reference,ConversationTaskActionValidation.uuid(request.operation_id),ConversationTaskActionValidation.positive(request.expected_effect_revision),ConversationTaskActionValidation.hash(request.binding_hash) else {throw ConversationDeviceEffectDispatchFailure.notSent}
        let body=try Self.deviceBody(request)
        let data=try await deviceEffectWire(reference:reference,suffix:"stop",body:body,limit:512_000)
        let result=try ConversationDeviceEffectsCodec.decodeOriginal(data,reference:reference,action:action)
        guard result.effect.stop?.operation_id==request.operation_id else {throw ConversationDeviceEffectError.invalidResponse};return result
    }
}
