import Foundation
#if !TASK_ACTION_TRANSPORT_PORTABLE
import XCTest
@testable import CatpawM
#endif

private final class ActionWireProtocol:URLProtocol,@unchecked Sendable {
    struct Reply {var status:Int=200;var data:Data;var headers:[String:String]=["Content-Type":"application/json"]}
    static var handler:((URLRequest) throws -> Reply)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){do{guard let handler=Self.handler else {throw URLError(.unsupportedURL)};let reply=try handler(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:reply.status,httpVersion:"HTTP/1.1",headerFields:reply.headers)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:reply.data);client?.urlProtocolDidFinishLoading(self)}catch{client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading(){}
}
private actor ActionWireCredentials:NativeChatSessionCredentials {
    private var rejections=0
    func authorization(scope:DataScope) async throws -> String {"Bearer explicit-local-action-fixture"}
    func rejected(scope:DataScope) async {rejections += 1}
    func count()->Int {rejections}
}
private enum TaskActionTransportMatrix {
    struct Failure:Error {let description:String}
    struct Case {let name:String;let run:() async throws -> Void}
    static func check(_ value:@autoclosure () throws -> Bool,_ detail:String) throws {if try !value(){throw Failure(description:detail)}}
    static func rejected(_ body:() async throws -> Void) async throws -> Error {do{try await body()}catch{return error};throw Failure(description:"Expected rejected transport")}
    static func body(_ request:URLRequest)->Data {
        if let body=request.httpBody{return body};guard let stream=request.httpBodyStream else{return Data()}
        stream.open();defer{stream.close()};var data=Data(),chunk=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {let n=stream.read(&chunk,maxLength:chunk.count);if n<=0 {break};data.append(contentsOf:chunk.prefix(n))};return data
    }
    static func fixture()->(NativeChatHTTPBackend,ConversationTaskActionReference,ActionWireCredentials) {
        let server=UUID(uuidString:"cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,run=UUID(uuidString:"11111111-aaaa-4aaa-8aaa-111111111111")!
        let binding=ConversationTaskBinding(scope_id:server,conversation_id:UUID(uuidString:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,turn_id:UUID(uuidString:"dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,call_id:"intercepted-action-fixture",delegation_id:UUID(uuidString:"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,operation_id:UUID(uuidString:"ffffffff-ffff-4fff-8fff-ffffffffffff")!,run_id:run,task_id:String(repeating:"1",count:64),request_hash:String(repeating:"2",count:64),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+server.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        let session=URLSessionConfiguration.ephemeral;session.protocolClasses=[ActionWireProtocol.self]
        let credentials=ActionWireCredentials(),config=try! NativeChatConfiguration(origin:URL(string:"https://actions.example.invalid")!,localScope:Profiles.user,serverScopeID:server)
        return (NativeChatHTTPBackend(configuration:config,credentials:credentials,sessionConfiguration:session),.init(scope:Profiles.user,binding:binding,subjectID:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",title:"Intercepted offline review"),credentials)
    }
    static func action(_ reference:ConversationTaskActionReference) throws -> ConversationTaskActionSnapshot {
        let b=reference.binding,proposal="55555555-aaaa-4aaa-8aaa-555555555555",target=ConversationDeviceCalendarTarget(device_id:"22222222-aaaa-4aaa-8aaa-222222222222",environment_id:"33333333-aaaa-4aaa-8aaa-333333333333",calendar_id:"offline/calendar-1",calendar_display_name:"Intercepted synthetic calendar",calendar_snapshot_hash:String(repeating:"3",count:64)),parameters=ConversationCalendarCreateParameters(title:"Synthetic review",start_at:"2026-10-15T02:00:00.000Z",end_at:"2026-10-15T03:00:00.000Z",time_zone:"Asia/Shanghai",reminder_offset_seconds:-600)
        let p=try ConversationTaskActionJSON.value(parameters),frozen=ConversationTaskActionFrozen(id:try ConversationTaskActionValidation.actionID(runID:b.run_id.uuidString.lowercased(),proposalID:proposal),proposal_operation_id:proposal,scope_id:b.scope_id.uuidString.lowercased(),subject_id:reference.subjectID,conversation_id:b.conversation_id.uuidString.lowercased(),turn_id:b.turn_id.uuidString.lowercased(),run_id:b.run_id.uuidString.lowercased(),task_id:b.task_id,request_hash:b.request_hash,delegation_id:b.delegation_id.uuidString.lowercased(),delegation_revision:1,grant_epoch:1,plan_reference:.init(revision:1,plan_hash:String(repeating:"4",count:64)),kind:"calendar.create.v1",tool_version:1,target:try .value(target),parameters:p,parameters_hash:try p.digest(),artifact_reference:nil,created_at:"2026-10-14T00:00:00.000Z",expires_at:"2026-10-14T00:30:00.000Z")
        return .init(frozen:frozen,action_digest:try frozen.digest(),capability:.init(kind:frozen.kind))
    }
    static func request(_ action:ConversationTaskActionSnapshot,digest:String?=nil)->ConversationTaskActionDecisionRequest {.init(operationID:UUID(uuidString:"77777777-AAAA-4AAA-8AAA-777777777777")!,decision:.approve,expected_revision:1,action_digest:digest ?? action.action_digest,expected_grant_epoch:1)}
    static var cases:[Case] {[
        Case(name:"URLSession actions paths and original decision UUID use lower canonical identities with bounded exact body") {
            let (backend,reference,_)=fixture(),original=try action(reference),decision=request(original);var paths:[String]=[],posts=0
            ActionWireProtocol.handler={wire in
                paths.append(wire.url!.path);try check(wire.value(forHTTPHeaderField:"Authorization")=="Bearer explicit-local-action-fixture" && wire.value(forHTTPHeaderField:"Accept")=="application/json","Pinned native headers")
                if wire.httpMethod=="POST" {posts += 1;let data=body(wire),object=try JSONSerialization.jsonObject(with:data) as! [String:Any];try check(Set(object.keys)==Set(["operation_id","decision","expected_revision","action_digest","expected_grant_epoch"]),"No subject/key/target override in decision");try check(object["operation_id"] as? String==decision.operationID.uuidString.lowercased() && data.count<=16384,"Exact lower operation");try check(try JSONDecoder().decode(ConversationTaskActionDecisionRequest.self,from:data)==decision,"Original request")}
                if wire.url!.path.hasSuffix("/actions") {return .init(data:try ConversationTaskActionJSON.encoded(ConversationTaskActionCatalog(reference:reference,actions:[original])))}
                var value=original;let decided=wire.url!.path.contains("/decisions");if decided {value.revision=2;value.approval_status="approved";value.decision_operation_id=decision.operationID.uuidString.lowercased();value.effect = .init(status:"waiting_device")}
                return .init(data:try ConversationTaskActionJSON.encoded(ConversationTaskActionEnvelope(action:value,decision:decided ? .init(operation_id:decision.operationID.uuidString.lowercased(),action_id:value.id,decision:.approve,action_digest:value.action_digest,committed_at:"2026-10-14T00:05:00.000Z"):nil)))
            };defer{ActionWireProtocol.handler=nil}
            _ = try await backend.readActions(reference);_ = try await backend.readAction(reference,actionID:original.id);_ = try await backend.decideAction(reference,actionID:original.id,request:decision);_ = try await backend.readDecision(reference,actionID:original.id,operationID:decision.operationID)
            try check(posts==1 && paths.count==4 && paths.allSatisfy{$0.contains(reference.binding.run_id.uuidString.lowercased())} && paths.last!.hasSuffix("/decisions/"+decision.operationID.uuidString.lowercased()),"One explicit POST, original GET path");await backend.close()
        },
        Case(name:"URLSession readiness true false absent wrong contract and unready never manufacture decision capability") {
            let (backend,reference,_)=fixture();defer{ActionWireProtocol.handler=nil}
            for (object,expected):([String:Any],Bool) in [(["ready":true,"chat_capabilities":["task_actions":["contract":"catpaw.task-action.v1","review":true,"decision":true]]],true),(["ready":true,"chat_capabilities":["task_actions":["contract":"catpaw.task-action.v1","review":true,"decision":false]]],false),(["ready":true],false),(["ready":true,"chat_capabilities":["task_actions":["contract":"future","review":true,"decision":true]]],false),(["ready":false,"chat_capabilities":["task_actions":["contract":"catpaw.task-action.v1","review":true,"decision":true]]],false)] {
                ActionWireProtocol.handler={wire in try check(wire.httpMethod=="GET" && wire.url!.path=="/readyz","Availability read only");return .init(data:try JSONSerialization.data(withJSONObject:object))};let value=try await backend.decisionAvailability(reference);try check(value==expected,"No inferred capability")
            };await backend.close()
        },
        Case(name:"URLSession401 rejects current credentials and preserves unknown POST result") {
            let (backend,reference,credentials)=fixture(),value=try action(reference);ActionWireProtocol.handler={_ in .init(status:401,data:Data(#"{"schema_version":1,"error":{"code":"session_revoked","reconciliation_required":true,"retryable":false}}"#.utf8))};defer{ActionWireProtocol.handler=nil}
            let failure=try await rejected{_ = try await backend.decideAction(reference,actionID:value.id,request:request(value))};let count=await credentials.count();try check(count==1 && !(failure is ConversationTaskActionDispatchFailure),"401 original decision remains unknown");await backend.close()
        },
        Case(name:"URLSession invalid digest revision epoch and cross scope are rejected before every request") {
            let (backend,reference,_)=fixture(),value=try action(reference);var calls=0;ActionWireProtocol.handler={_ in calls += 1;return .init(status:500,data:Data())};defer{ActionWireProtocol.handler=nil}
            for req in [request(value,digest:"bad-digest"),.init(operationID:UUID(),decision:.approve,expected_revision:0,action_digest:value.action_digest,expected_grant_epoch:1),.init(operationID:UUID(),decision:.approve,expected_revision:1,action_digest:value.action_digest,expected_grant_epoch:2)] {let failure=try await rejected{_ = try await backend.decideAction(reference,actionID:value.id,request:req)};try check(failure is ConversationTaskActionDispatchFailure,"Invalid request proven unsent")}
            let wrong=ConversationTaskActionReference(scope:Profiles.demo,binding:reference.binding,subjectID:reference.subjectID,title:"Foreign");_ = try await rejected{_ = try await backend.readActions(wrong)};try check(calls==0,"No invalid HTTP");await backend.close()
        },
        Case(name:"URLSession malformed digest scope effect and wrong requested action never become authoritative") {
            let (backend,reference,_)=fixture(),original=try action(reference);defer{ActionWireProtocol.handler=nil}
            for field in 0..<4 {var value=original;switch field {case 0:value.action_digest=String(repeating:"f",count:64);case 1:value.frozen.subject_id="66666666-aaaa-4aaa-8aaa-666666666666";value.action_digest=try value.frozen.digest();case 2:value.execution_authorized=true;default:value.frozen.proposal_operation_id="66666666-aaaa-4aaa-8aaa-666666666666";value.frozen.id=try ConversationTaskActionValidation.actionID(runID:value.frozen.run_id,proposalID:value.frozen.proposal_operation_id);value.action_digest=try value.frozen.digest()};let bytes=try ConversationTaskActionJSON.encoded(ConversationTaskActionEnvelope(action:value));ActionWireProtocol.handler={_ in .init(data:bytes)};_ = try await rejected{_ = try await backend.readAction(reference,actionID:original.id)}};await backend.close()
        },
        Case(name:"URLSession original decision404 reports unknown original not found and issues no POST") {
            let (backend,reference,_)=fixture(),value=try action(reference),operation=UUID();var calls:[URLRequest]=[];ActionWireProtocol.handler={wire in calls.append(wire);return .init(status:404,data:Data(#"{"schema_version":1,"error":{"code":"not_found","reconciliation_required":false,"retryable":false}}"#.utf8))};defer{ActionWireProtocol.handler=nil}
            let failure=try await rejected{_ = try await backend.readDecision(reference,actionID:value.id,operationID:operation)};try check((failure as? ConversationTaskActionError) == .originalNotFound && calls.count==1 && calls[0].httpMethod=="GET" && calls[0].url!.path.hasSuffix(operation.uuidString.lowercased()),"Original read only, no retry POST");await backend.close()
        },
        Case(name:"URLSession409 explicit final rejection differs from retryable or reconciliation-required unknown") {
            let (backend,reference,_)=fixture(),value=try action(reference);defer{ActionWireProtocol.handler=nil}
            for (retryable,reconcile,conflict) in [(false,false,true),(true,false,false),(false,true,false),(true,true,false)] {
                ActionWireProtocol.handler={_ in .init(status:409,data:try JSONSerialization.data(withJSONObject:["schema_version":1,"error":["code":"fixture_conflict","retryable":retryable,"reconciliation_required":reconcile]]))}
                let failure=try await rejected{_ = try await backend.decideAction(reference,actionID:value.id,request:request(value))};let isConflict:Bool;if case .conflict?=failure as? CatpawError {isConflict=true}else{isConflict=false};try check(isConflict==conflict && !(failure is ConversationTaskActionDispatchFailure),"Do not infer final rejection from retryable409")
            };await backend.close()
        },
        Case(name:"URLSession redirect response is rejected without following or exposing a decision to another origin") {
            let (backend,reference,_)=fixture(),value=try action(reference);var calls:[String]=[];ActionWireProtocol.handler={wire in calls.append(wire.url!.host!);return .init(status:302,data:Data(),headers:["Content-Type":"application/json","Location":"https://other.example.invalid/capture"])};defer{ActionWireProtocol.handler=nil}
            _ = try await rejected{_ = try await backend.decideAction(reference,actionID:value.id,request:request(value))};try check(calls==["actions.example.invalid"],"No forwarded credentials or decision");await backend.close()
        }
    ]}
}
#if TASK_ACTION_TRANSPORT_PORTABLE
@main struct NativeTaskActionPortableRunner {static func main() async throws {for test in TaskActionTransportMatrix.cases {try await test.run();print("PASS: "+test.name)};print("EVIDENCE: existing URLSession adapter intercepted by named URLProtocol; live network/model/calendar effects = 0")}}
#else
final class NativeTaskActionTransportTests:XCTestCase {func testNativeActionTransportMatrix() async throws {for test in TaskActionTransportMatrix.cases {do{try await test.run()}catch{XCTFail(test.name+": "+String(describing:error));throw error}}}}
#endif
