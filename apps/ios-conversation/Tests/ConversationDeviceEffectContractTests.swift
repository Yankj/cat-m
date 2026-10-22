import Foundation
#if !DEVICE_EFFECT_CONTRACT_PORTABLE
import XCTest
@testable import cat
#endif

/// Fixed Node-maintained primitive responses. Every provider observation is explicit synthetic data.
private enum DeviceEffectContractMatrix {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func check(_ value:@autoclosure () throws -> Bool,_ detail:String) throws {if try !value() {throw Failure(description:detail)}}
    static func rejects(_ detail:String,_ body:() throws -> Void) throws {do {try body()} catch {return};throw Failure(description:"Expected rejection: "+detail)}
    static func json(_ value:Any) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    static func object(_ value:Any?) throws -> [String:Any] {guard let value=value as? [String:Any] else {throw Failure(description:"Fixture object missing")};return value}
    static func fixture() throws -> [String:Any] {
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/device-effect-contract-v2.json")
        let value=try ConversationStrictJSON.object(Data(contentsOf:url),maxBytes:512_000)
        try check(value["reality"] as? String=="synthetic_offline_maintained_primitive_no_OS_or_HTTP","Fixture must declare actual maintained primitive and synthetic OS")
        let p=try object(value["provenance"]);try check(p["external_calls"] as? Int==0,"No external fixture calls")
        return value
    }
    static func reference(_ f:[String:Any],subject:String?=nil,localScope:DataScope?=nil,serverScope:String?=nil) throws -> ConversationDeviceEffectReference {
        let i=try object(f["identity"]),s=try object(i["scope"])
        var binding=try object(i["binding"]);if let serverScope {binding["scope_id"]=serverScope}
        let b=try JSONDecoder().decode(ConversationTaskBinding.self,from:json(binding))
        let scope=localScope ?? DataScope(profileID:UUID(uuidString:s["profile_id"] as! String)!,workspaceID:UUID(uuidString:s["workspace_id"] as! String)!)
        return try .init(scope:scope,binding:b,subjectID:subject ?? (i["subject"] as! String),actionID:i["action_id"] as! String,actionDigest:i["action_digest"] as! String,decisionOperationID:i["decision_operation_id"] as! String,actionRevision:i["action_revision"] as! Int)
    }
    static func approved(_ f:[String:Any],_ r:ConversationDeviceEffectReference) throws -> ConversationApprovedDeviceAction {
        try ConversationDeviceEffectsCodec.decodeApprovedAction(frozenData:json(f["frozen"]!),decisionData:json(f["decision"]!),reference:r)
    }
    static func response(_ f:[String:Any],_ name:String) throws -> Data {try json(try object(f["responses"])[name]!)}
    static func request(_ f:[String:Any],_ kind:String) throws -> ConversationDeviceEffectDispatchRequest {try JSONDecoder().decode(ConversationDeviceEffectDispatchRequest.self,from:json(try object(f["dispatch_requests"])[kind]!))}
    static func patched(_ f:[String:Any],_ name:String,reseal:Bool=true,_ mutate:(inout [String:Any]) throws -> Void) throws -> Data {
        var raw=try object(try object(f["responses"])[name]),e=try object(raw["effect"]);try mutate(&e)
        if reseal {
            var body=e;for key in ["record_hash","state","execution_current","unresolved_subeffects","can_redispatch"] {body.removeValue(forKey:key)}
            e["record_hash"]=try ConversationDeviceEffectsCodec.canonicalHashJSON(json(body))
        }
        raw["effect"]=e;return try json(raw)
    }
    static func canonical() throws {
        let f=try fixture(),r=try reference(f),a=try approved(f,r),h=try object(f["hashes"])
        try check(try ConversationDeviceEffectsCodec.canonicalHash(a.frozen)==h["frozen"] as? String,"Actual Node frozen canonical hash")
        try check(try ConversationDeviceEffectsCodec.canonicalHash(a.frozen.parameters)==h["parameters"] as? String,"Exact Unicode parameters canonical hash")
        try check(try ConversationDeviceEffectsCodec.supportedPolicy().policy_hash==h["policy"] as? String,"Compiled policy identity")
        try check(try r.effectID==h["effect_id"] as? String,"One stable root derived by Node")
        let root=try r.effectID
        for kind in [ConversationDeviceSubeffectKind.calendar,.notification] {try check(try ConversationDeviceEffectsCodec.subeffectID(effectID:root,kind:kind)==h[kind.rawValue+"_child_id"] as? String,"Fixed "+kind.rawValue+" child UUID")}
        try check(try ConversationDeviceEffectsCodec.subeffectID(effectID:root,kind:.calendar) != ConversationDeviceEffectsCodec.subeffectID(effectID:root,kind:.notification),"Independent child identities")
        try check(a.frozen.parameters.title.utf8.contains(0xcc),"Decomposed accent bytes remain unnormalized")
        let admitted=try ConversationDeviceEffectsCodec.decodeOriginal(response(f,"admitted"),reference:r,action:a)
        let admission=try ConversationDeviceEffectAdmissionRequest(operationID:UUID(uuidString:admitted.effect.frozen.admission_operation_id)!,reference:r,action:a,executionRevision:0)
        try check(try ConversationDeviceEffectsCodec.canonicalHash(admission)==h["admission"] as? String,"Exact persisted admission payload hash")
        for kind in ["calendar","notification"] {try check(try ConversationDeviceEffectsCodec.canonicalHash(request(f,kind))==h[kind+"_dispatch"] as? String,"Exact dispatch payload hash")}
        try rejects("invalid root ID input"){_ = try ConversationDeviceEffectsCodec.effectID(actionID:"display-card")}
    }
    static func oldReviewAndChangedPolicy() throws {
        let f=try fixture(),r=try reference(f)
        var frozen=try object(f["frozen"]);frozen["contract"]="catpaw.task-action.v1";frozen["kind"]="calendar.create.v1";frozen["tool_version"]=1
        try rejects("old review-only approval cannot execute"){_ = try ConversationDeviceEffectsCodec.decodeApprovedAction(frozenData:json(frozen),decisionData:json(f["decision"]!),reference:r)}
        frozen=try object(f["frozen"]);var policy=try object(frozen["execution_policy"]);policy["version"]=2;policy["policy_hash"]=String(repeating:"a",count:64);frozen["execution_policy"]=policy
        var changed=f,i=try object(f["identity"]),decision=try object(f["decision"])
        let digest=try ConversationDeviceEffectsCodec.canonicalHashJSON(json(frozen));i["action_digest"]=digest;decision["action_digest"]=digest;decision["execution_policy"]=policy
        changed["identity"]=i;changed["frozen"]=frozen;changed["decision"]=decision
        try rejects("new unsupported policy even after consistent digest update"){_ = try approved(changed,reference(changed))}
        var denied=try object(f["decision"]);denied["decision"]="deny"
        try rejects("deny is not an approved device action"){_ = try ConversationDeviceEffectsCodec.decodeApprovedAction(frozenData:json(f["frozen"]!),decisionData:json(denied),reference:r)}
        var beforeEpoch=f,iBefore=try object(f["identity"]),fBefore=try object(f["frozen"]),dBefore=try object(f["decision"])
        fBefore["created_at"]="1969-12-31T23:00:00.000Z";fBefore["expires_at"]="1969-12-31T23:30:00.000Z";dBefore["committed_at"]="1969-12-31T23:00:00.000Z"
        let preEpochHash=try ConversationDeviceEffectsCodec.canonicalHashJSON(json(fBefore));iBefore["action_digest"]=preEpochHash;dBefore["action_digest"]=preEpochHash
        beforeEpoch["identity"]=iBefore;beforeEpoch["frozen"]=fBefore;beforeEpoch["decision"]=dBefore
        try rejects("Node device UTC range applies even to consistent old dates"){_ = try approved(beforeEpoch,reference(beforeEpoch))}
        frozen=try object(f["frozen"]);frozen["executable"]=true
        try rejects("caller execution field is not schema authority"){_ = try ConversationDeviceEffectsCodec.decodeApprovedAction(frozenData:json(frozen),decisionData:json(f["decision"]!),reference:r)}
    }
    static func referenceIsolation() throws {
        let f=try fixture(),r=try reference(f),a=try approved(f,r)
        let foreign=UUID().uuidString.lowercased()
        for other in [try reference(f,subject:foreign),try reference(f,localScope:.init(profileID:UUID(),workspaceID:UUID())),try reference(f,serverScope:foreign)] {
            try rejects("original response cannot cross immutable account/scope"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(response(f,"revoked_original"),reference:other,action:a)}
            try rejects("admission cannot rebind approved action"){_ = try ConversationDeviceEffectAdmissionRequest(operationID:UUID(),reference:other,action:a,executionRevision:0)}
        }
        try rejects("approved action must belong to current trusted subject"){_ = try approved(f,reference(f,subject:foreign))}
    }
    static func strictScalarsAndShape() throws {
        let f=try fixture(),r=try reference(f),a=try approved(f,r)
        var raw=try object(try object(f["responses"])["admitted"]);raw["schema_version"]=true
        try rejects("Bool is not schema integer"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(json(raw),reference:r,action:a)}
        for value:Any in [true,9_007_199_254_740_992,1.5,"1"] {
            let data=try patched(f,"admitted",reseal:false){$0["revision"]=value}
            try rejects("unsafe or wrong revision type \(value)"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(data,reference:r,action:a)}
        }
        let boolData=try patched(f,"admitted",reseal:false){$0["execution_current"]=1}
        try rejects("integer is not authority Bool"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(boolData,reference:r,action:a)}
        let unknown=try patched(f,"partial_unknown") {var children=try object($0["subeffects"]),n=try object(children["notification"]);n["state"]="retrying";children["notification"]=n;$0["subeffects"]=children}
        try rejects("unregistered child state"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(unknown,reference:r,action:a)}
        raw=try object(try object(f["responses"])["admitted"]);raw["allow_expired"]=true
        try rejects("extra transport authority fields"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(json(raw),reference:r,action:a)}
        let duplicated=Data("{\"schema_version\":1,\"\\u0073chema_version\":1,\"contract\":\"catpaw.device-effect.v1\"}".utf8)
        try rejects("escaped duplicate key"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(duplicated,reference:r,action:a)}
        try rejects("wire bound"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(Data(repeating:32,count:512_001),reference:r,action:a)}
    }
    static func permitAndReadReplay() throws {
        let f=try fixture(),r=try reference(f),a=try approved(f,r)
        for kind in ["calendar","notification"] {
            let request=try request(f,kind),data=try response(f,kind+"_permit")
            let fresh=try ConversationDeviceEffectsCodec.decodeDispatchResponse(data,reference:r,action:a,request:request)
            try check(fresh.dispatchPermit?.dispatch.operation_id==request.operation_id,"Only exact first dispatch produces typed permit")
            try rejects("GET cannot construct any permit"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(data,reference:r,action:a)}
            let wrong=try ConversationDeviceEffectDispatchRequest(operationID:UUID(),subeffect:request.subeffect,expectedRevision:request.expected_effect_revision,bindingHash:request.binding_hash,leaseID:request.lease_id)
            try rejects("response belongs to another local dispatch"){_ = try ConversationDeviceEffectsCodec.decodeDispatchResponse(data,reference:r,action:a,request:wrong)}
        }
        let replay=try ConversationDeviceEffectsCodec.decodeDispatchResponse(response(f,"calendar_replay"),reference:r,action:a,request:request(f,"calendar"))
        try check(replay.dispatchPermit==nil,"Repeated dispatch does not remint execution authority")
        for name in ["admitted","calendar_replay","calendar_expired_original","calendar_succeeded","partial_unknown","revoked_original","succeeded","stopped","stopped_late_fact"] {
            try check(try ConversationDeviceEffectsCodec.decodeOriginal(response(f,name),reference:r,action:a).dispatchPermit==nil,"Original "+name+" has no permit")
        }
    }
    static func independentChildReceipts() throws {
        let f=try fixture(),r=try reference(f),a=try approved(f,r)
        let partial=try ConversationDeviceEffectsCodec.decodeOriginal(response(f,"partial_unknown"),reference:r,action:a).effect
        let calendarUnknown=try ConversationDeviceEffectsCodec.decodeOriginal(response(f,"calendar_expired_original"),reference:r,action:a).effect
        try check(calendarUnknown.state == .unknown && calendarUnknown.subeffects.calendar.state == .dispatched && calendarUnknown.subeffects.calendar.receipt==nil && calendarUnknown.unresolved_subeffects.first?.kind == .calendar,"Expired calendar dispatch is unknown, never inferred not-executed")
        try check(partial.state == .partialUnknown && partial.subeffects.calendar.state == .succeeded && partial.subeffects.notification.state == .unknown,"Real primitive preserves calendar success and notification uncertainty separately")
        try check(partial.subeffects.calendar.receipt?.calendarReference?.event_identifier=="synthetic/EventKit-event","Known system reference is retained")
        try check(partial.unresolved_subeffects.count==1 && !partial.unresolved_subeffects[0].can_retry,"Only original unresolved notification is recoverable")
        let complete=try ConversationDeviceEffectsCodec.decodeOriginal(response(f,"succeeded"),reference:r,action:a).effect
        try check(complete.state == .succeeded && complete.subeffects.notification.receipt?.notificationReference?.request_identifier==complete.subeffects.notification.id,"Both child receipts bind completion")
        let noReminder=try object(f["without_reminder"]),nr=try reference(noReminder),na=try approved(noReminder,nr)
        try check(na.frozen.parameters.reminder_offset_seconds==nil,"Exact null is an intentional absent reminder")
        let nrComplete=try ConversationDeviceEffectsCodec.decodeOriginal(response(noReminder,"succeeded"),reference:nr,action:na).effect
        try check(nrComplete.state == .succeeded && nrComplete.subeffects.notification.state == .notRequired && nrComplete.subeffects.notification.dispatch==nil && nrComplete.subeffects.notification.receipt==nil,"Actual Node null reminder creates no notification dispatch or receipt")
        let nrHashes=try object(noReminder["hashes"])
        try check(try ConversationDeviceEffectsCodec.canonicalHash(na.frozen.parameters)==nrHashes["parameters"] as? String,"Node/Swift explicit null reminder canonical bytes")
        let bad=try patched(f,"succeeded"){var children=try object($0["subeffects"]),n=try object(children["notification"]),receipt=try object(n["receipt"]),ext=try object(receipt["external_reference"]);ext["due_at"]="2026-10-16T01:00:00.000Z";receipt["external_reference"]=ext;n["receipt"]=receipt;n["receipt_hash"]=try ConversationDeviceEffectsCodec.canonicalHashJSON(json(receipt));children["notification"]=n;$0["subeffects"]=children}
        try rejects("rehashed receipt with wrong exact due"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(bad,reference:r,action:a)}
    }
    static func corruptOriginalIdentity() throws {
        let f=try fixture(),r=try reference(f),a=try approved(f,r)
        let missing=try patched(f,"partial_unknown"){var children=try object($0["subeffects"]),n=try object(children["notification"]);n["dispatch"]=NSNull();children["notification"]=n;$0["subeffects"]=children}
        try rejects("unknown without original dispatch identity"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(missing,reference:r,action:a)}
        let wrong=try patched(f,"calendar_succeeded"){var children=try object($0["subeffects"]),c=try object(children["calendar"]),receipt=try object(c["receipt"]);receipt["device_id"]=UUID().uuidString.lowercased();c["receipt"]=receipt;c["receipt_hash"]=try ConversationDeviceEffectsCodec.canonicalHashJSON(json(receipt));children["calendar"]=c;$0["subeffects"]=children}
        try rejects("corrupt receipt binding despite rehashed mutable record"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(wrong,reference:r,action:a)}
        let retry=try patched(f,"revoked_original"){var unknown=$0["unresolved_subeffects"] as! [[String:Any]];unknown[0]["can_retry"]=true;$0["unresolved_subeffects"]=unknown}
        try rejects("unknown inventory cannot offer blind retry"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(retry,reference:r,action:a)}
        let forged=try patched(f,"partial_unknown"){$0["state"]="succeeded"}
        try rejects("projection cannot claim completed with unknown child"){_ = try ConversationDeviceEffectsCodec.decodeOriginal(forged,reference:r,action:a)}
    }
    static func revokedAndStoppedFacts() throws {
        let f=try fixture(),r=try reference(f),a=try approved(f,r)
        let old=try ConversationDeviceEffectsCodec.decodeOriginal(response(f,"revoked_original"),reference:r,action:a)
        try check(!old.effect.execution_current && old.dispatchPermit==nil && old.effect.state == .partialUnknown,"Expired/revoked original remains readable without execution")
        let stopped=try ConversationDeviceEffectsCodec.decodeOriginal(response(f,"stopped_late_fact"),reference:r,action:a)
        try check(stopped.effect.state == .stopped && stopped.effect.stop != nil && stopped.effect.subeffects.calendar.state == .succeeded && stopped.effect.subeffects.notification.state == .succeeded,"Late known facts preserve stop instead of restoring execution")
        try check(stopped.dispatchPermit==nil && !stopped.effect.execution_current,"No new device authority after stop")
    }
    static let cases:[(String,() throws -> Void)]=[
        ("actual Node/Swift canonical and deterministic identities",canonical),
        ("old review-only and changed execution policy",oldReviewAndChangedPolicy),
        ("immutable trusted subject and both scopes",referenceIsolation),
        ("strict JSON scalars states schema and byte boundary",strictScalarsAndShape),
        ("first dispatch permit versus original GET and replay",permitAndReadReplay),
        ("calendar and notification receipts remain independent",independentChildReceipts),
        ("corrupt original operation and receipt identity",corruptOriginalIdentity),
        ("revoked and stopped late facts never grant execution",revokedAndStoppedFacts)
    ]
}
#if DEVICE_EFFECT_CONTRACT_PORTABLE
@main struct DeviceEffectContractPortableRunner {
    static func main() throws {for (name,run) in DeviceEffectContractMatrix.cases {try run();print("PASS: "+name)};print("EVIDENCE: actual maintained Node primitive synthetic fixture; pure Swift contract only; HTTP/OS/Auth/model/SQL = NOT_RUN")}
}
#else
final class ConversationDeviceEffectContractTests:XCTestCase {
    func testActualNodeSwiftCanonicalIdentity() throws {try DeviceEffectContractMatrix.canonical()}
    func testOldReviewApprovalCannotAcquireExecutionPolicy() throws {try DeviceEffectContractMatrix.oldReviewAndChangedPolicy()}
    func testImmutableReferenceRejectsOtherSubjectAndScopes() throws {try DeviceEffectContractMatrix.referenceIsolation()}
    func testStrictJSONRejectsUnsafeScalarsAndUnknownStates() throws {try DeviceEffectContractMatrix.strictScalarsAndShape()}
    func testOnlyExactFreshDispatchResponseCreatesPermit() throws {try DeviceEffectContractMatrix.permitAndReadReplay()}
    func testPartialCalendarAndNotificationReceiptsRemainIndependent() throws {try DeviceEffectContractMatrix.independentChildReceipts()}
    func testCorruptOriginalIdentityNeverOffersRecoveryExecution() throws {try DeviceEffectContractMatrix.corruptOriginalIdentity()}
    func testStoppedAndRevokedFactsDoNotRestoreAuthority() throws {try DeviceEffectContractMatrix.revokedAndStoppedFacts()}
}
#endif
