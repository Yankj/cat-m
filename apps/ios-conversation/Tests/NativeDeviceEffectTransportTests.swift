import Foundation
#if !DEVICE_EFFECT_TRANSPORT_PORTABLE
import XCTest
@testable import cat
#endif

private enum DeviceEffectTransportMatrix {
    struct Case {let name:String;let run:() async throws -> Void}
    static func native(_ f:DeviceEffectDiskFixture,local:DataScope=Profiles.user,server:UUID?=nil,subject:UUID?=nil,configured:Bool=true) throws -> NativeChatHTTPBackend {
        let session=URLSessionConfiguration.ephemeral;session.protocolClasses=[DeviceEffectWireProtocol.self]
        return NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"https://"+f.host)!,localScope:local,serverScopeID:server ?? f.source.reference.binding.scope_id,expectedSubjectID:configured ? (subject ?? UUID(uuidString:f.source.reference.subjectID)!) : nil),credentials:f.credentials,sessionConfiguration:session)
    }
    static var cases:[Case] {[
        .init(name:"subject scope and missing configuration fail before any HTTP") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                let count=DeviceEffectCounter();DeviceEffectWireProtocol.register(f.host){_ in count.increment();throw DeviceEffectTestFailure("Unexpected network admission")}
                let admission=try JSONDecoder().decode(ConversationDeviceEffectAdmissionRequest.self,from:DeviceEffectApplicationFixture.json(f.source.raw["admission"]!))
                for backend in [try native(f,subject:UUID()),try native(f,server:UUID()),try native(f,local:Profiles.demo),try native(f,configured:false)] {
                    _=try await deviceReject{_=try await backend.readOriginalDeviceEffect(f.source.reference,action:f.source.action)}
                    let error=try await deviceReject{_=try await backend.admitDeviceEffect(f.source.reference,action:f.source.action,request:admission)}
                    try deviceCheck(error is ConversationDeviceEffectDispatchFailure,"POST preflight has an explicit not-sent classification");await backend.close()
                }
                try deviceCheck(count.count()==0,"Wrong identity never reaches URLSession")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"missing or malformed capability never enables execution") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                let ready=try ConversationStrictJSON.object(f.source.readiness)
                var fixtures:[[String:Any]]=[["ready":true,"chat_capabilities":["task_actions":["contract":"catpaw.task-action.v1","execution":true]]]]
                for patch in [["dispatch":1],["unknown_resend":true],["verified_receipts":false],["action_contract":"catpaw.task-action.v1"]] {
                    var value=ready,caps=value["chat_capabilities"] as! [String:Any],effect=caps["device_effects"] as! [String:Any]
                    for (key,v) in patch {effect[key]=v};caps["device_effects"]=effect;value["chat_capabilities"]=caps;fixtures.append(value)
                }
                for value in fixtures {
                    let data=try DeviceEffectApplicationFixture.json(value);DeviceEffectWireProtocol.register(f.host){_ in .init(data:data)}
                    try deviceCheck(try await f.backend.deviceEffectAvailability(f.source.reference)==false,"Invalid readiness cannot expand approval")
                }
                let data=try f.source.readiness;DeviceEffectWireProtocol.register(f.host){_ in .init(data:data)}
                try deviceCheck(try await f.backend.deviceEffectAvailability(f.source.reference),"Only complete explicitly synthetic capability is available in this test")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"fresh dispatch has typed permit but replay and original GET cannot mint it") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                let request=try f.source.request("calendar"),first=try f.source.response("calendar_permit")
                DeviceEffectWireProtocol.register(f.host){_ in .init(data:first)}
                try deviceCheck(try await f.backend.dispatchDeviceEffect(f.source.reference,action:f.source.action,request:request).dispatchPermit != nil,"Actual adapter returns exact first dispatch permit")
                _=try await deviceReject{_=try await f.backend.readOriginalDeviceEffect(f.source.reference,action:f.source.action)}
                let replay=try f.source.response("calendar_replay");DeviceEffectWireProtocol.register(f.host){_ in .init(data:replay)}
                try deviceCheck(try await f.backend.dispatchDeviceEffect(f.source.reference,action:f.source.action,request:request).dispatchPermit==nil,"Repeated response has no permit")
                try deviceCheck(try await f.backend.readOriginalDeviceEffect(f.source.reference,action:f.source.action).dispatchPermit==nil,"GET is read-only")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"GET404 is original missing while POST401404 and malformed bytes remain unknown") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                let missing=Data(#"{"schema_version":1,"error":{"code":"not_found","retryable":false,"reconciliation_required":true}}"#.utf8)
                DeviceEffectWireProtocol.register(f.host){_ in .init(status:404,data:missing)}
                let read=try await deviceReject{_=try await f.backend.readOriginalDeviceEffect(f.source.reference,action:f.source.action)}
                try deviceCheck(read as? ConversationDeviceEffectServiceError == .originalNotFound,"Original404 mapping")
                let request=try f.source.request("calendar")
                for status in [401,404] {
                    DeviceEffectWireProtocol.register(f.host){_ in .init(status:status,data:missing)}
                    let failure=try await deviceReject{_=try await f.backend.dispatchDeviceEffect(f.source.reference,action:f.source.action,request:request)}
                    try deviceCheck(!(failure is ConversationDeviceEffectDispatchFailure),"POST was attempted, never inferred not-sent")
                }
                try deviceCheck(await f.credentials.rejections()==1,"Same existing credentials handle401")
                for data in [Data(#"{"schema_version":1,"\u0073chema_version":1}"#.utf8),Data(repeating:32,count:512_001)] {
                    DeviceEffectWireProtocol.register(f.host){_ in .init(data:data)}
                    let failure=try await deviceReject{_=try await f.backend.dispatchDeviceEffect(f.source.reference,action:f.source.action,request:request)}
                    try deviceCheck(!(failure is ConversationDeviceEffectDispatchFailure),"Malformed response still has an unknown original POST")
                }
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"rehashed Unicode-normalized target or parameters cannot replace frozen bytes") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                for part in ["parameters","target"] {
                    var raw=try ConversationStrictJSON.object(f.source.response("admitted")),effect=raw["effect"] as! [String:Any],frozen=effect["frozen"] as! [String:Any],value=frozen[part] as! [String:Any]
                    let key=part=="parameters" ? "title":"calendar_display_name"
                    value[key]=(value[key] as! String).precomposedStringWithCanonicalMapping;frozen[part]=value;effect["frozen"]=frozen
                    effect["binding_hash"]=try ConversationDeviceEffectsCodec.canonicalHashJSON(DeviceEffectApplicationFixture.json(frozen))
                    var body=effect;for k in ["record_hash","state","execution_current","unresolved_subeffects","can_redispatch"] {body.removeValue(forKey:k)}
                    effect["record_hash"]=try ConversationDeviceEffectsCodec.canonicalHashJSON(DeviceEffectApplicationFixture.json(body));raw["effect"]=effect
                    let data=try DeviceEffectApplicationFixture.json(raw);DeviceEffectWireProtocol.register(f.host){_ in .init(data:data)}
                    _=try await deviceReject{_=try await f.backend.readOriginalDeviceEffect(f.source.reference,action:f.source.action)}
                }
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"client wall clock cannot extend a delayed live permit") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                let clock=DeviceEffectMonotonic(),ids=try f.source.operationIDs(["admission","calendarDispatch"]),date=f.source.createdAt,counter=DeviceEffectCounter()
                let service=ConversationDeviceEffectService(repository:f.repository,subjectID:UUID(uuidString:f.source.reference.subjectID),backend:f.backend,clock:{date},operationID:{ids.next()},monotonic:{clock.read()})
                await service.setAdmissionAllowed(true);_=try await service.refresh(f.source.action);_=try await service.admit(f.source.action,expectedActionDigest:f.source.reference.actionDigest,executionRevision:0)
                let state=try await service.refresh(f.source.action);await f.server.configure(afterPost:{clock.set(16)})
                _=try await deviceReject{_=try await service.dispatch(f.source.action,subeffect:.calendar,expectedSnapshotHash:state.snapshotHash!){_ in counter.increment()}}
                try deviceCheck(counter.count()==0,"Monotonic lease expires even when Date remains fixed")
                let saved=try await service.localState(f.source.action);try deviceCheck(saved.operations.contains{$0.permitConsumed},"Stale live permit stays consumed and cannot reappear")
                await f.close()
            } catch {await f.close();throw error}
        },
        .init(name:"unsafe integers and oversized observations are proven not sent") {
            let (f,_)=try await DeviceEffectDiskFixture.make([])
            do {
                let count=DeviceEffectCounter();DeviceEffectWireProtocol.register(f.host){_ in count.increment();throw DeviceEffectTestFailure("Unexpected outbound malformed request")}
                var admission=f.source.raw["admission"] as! [String:Any];admission["expected_execution_revision"]=9_007_199_254_740_992 as Int64
                let invalidAdmission=try JSONDecoder().decode(ConversationDeviceEffectAdmissionRequest.self,from:DeviceEffectApplicationFixture.json(admission))
                let admissionError=try await deviceReject{_=try await f.backend.admitDeviceEffect(f.source.reference,action:f.source.action,request:invalidAdmission)}
                try deviceCheck(admissionError is ConversationDeviceEffectDispatchFailure,"Invalid constructor never escapes as unknown admission")
                var dispatch=(f.source.raw["dispatch_requests"] as! [String:[String:Any]])["calendar"]!;dispatch["expected_effect_revision"]=9_007_199_254_740_992 as Int64
                let invalidDispatch=try JSONDecoder().decode(ConversationDeviceEffectDispatchRequest.self,from:DeviceEffectApplicationFixture.json(dispatch))
                let dispatchError=try await deviceReject{_=try await f.backend.dispatchDeviceEffect(f.source.reference,action:f.source.action,request:invalidDispatch)}
                try deviceCheck(dispatchError is ConversationDeviceEffectDispatchFailure,"Unsafe dispatch integer is preflight")
                let result=try ConversationDeviceEffectResultRequest(operationID:UUID(),subeffect:.calendar,base:f.source.record("calendar_replay"),outcome:.succeeded,receipt:f.source.record("calendar_succeeded").subeffects.calendar.receipt)
                var raw=try ConversationStrictJSON.object(ConversationTaskActionJSON.encoded(result)),receipt=raw["receipt"] as! [String:Any],external=receipt["external_reference"] as! [String:Any]
                external["event_identifier"]=String(repeating:"x",count:32_768);receipt["external_reference"]=external;raw["receipt"]=receipt
                let oversized=try JSONDecoder().decode(ConversationDeviceEffectResultRequest.self,from:DeviceEffectApplicationFixture.json(raw))
                let resultError=try await deviceReject{_=try await f.backend.recordDeviceEffectResult(f.source.reference,action:f.source.action,request:oversized)}
                try deviceCheck(resultError is ConversationDeviceEffectDispatchFailure && count.count()==0,"Oversized receipt cannot start URLSession")
                _=try await deviceReject{_=try ConversationDeviceEffectResultRequest(operationID:UUID(),subeffect:.calendar,base:f.source.record("calendar_replay"),outcome:.succeeded,receipt:oversized.receipt)}
                await f.close()
            } catch {await f.close();throw error}
        }
    ]}
}
#if DEVICE_EFFECT_TRANSPORT_PORTABLE
@main struct DeviceEffectTransportPortableRunner {
    static func main() async throws {for test in DeviceEffectTransportMatrix.cases {do{try await test.run();print("PASS: "+test.name)}catch{print("FAIL: "+test.name+" · "+String(describing:error));throw error}};print("EVIDENCE: actual existing NativeChatHTTPBackend/URLSession via URLProtocol; external Auth/model/SQL/OS/network = NOT_RUN")}
}
#else
final class NativeDeviceEffectTransportTests:XCTestCase {
    func testStrictDeviceEffectNativeHTTPAndLivePermitMatrix() async throws {for test in DeviceEffectTransportMatrix.cases {do{try await test.run()}catch{XCTFail(test.name+": "+String(describing:error));throw error}}}
}
#endif
