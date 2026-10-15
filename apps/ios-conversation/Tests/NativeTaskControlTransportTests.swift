import Foundation
#if !TASK_CONTROL_TRANSPORT_PORTABLE
import XCTest
@testable import CatpawM
#endif

private final class ControlWireProtocol:URLProtocol,@unchecked Sendable {
    struct Reply {var status:Int=200,data:Data;var type="application/json"}
    static var handler:((URLRequest) throws -> Reply)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){do {guard let handler=Self.handler else {throw URLError(.unsupportedURL)};let reply=try handler(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:reply.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":reply.type])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:reply.data);client?.urlProtocolDidFinishLoading(self)}catch{client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading(){}
}
private actor ControlWireCredentials:NativeChatSessionCredentials {
    var rejections=0
    func authorization(scope:DataScope) async throws -> String {"Bearer named-offline-task-control"}
    func rejected(scope:DataScope) async {rejections += 1}
    func count()->Int {rejections}
}
private enum TaskControlTransportMatrix {
    struct Failure:Error {let description:String}
    struct Case {let name:String,run:() async throws -> Void}
    static func check(_ value:@autoclosure () throws -> Bool,_ message:String) throws {if try !value(){throw Failure(description:message)}}
    static func reject(_ work:() async throws -> Void) async throws -> Error {do{try await work()}catch{return error};throw Failure(description:"Expected rejection")}
    static func body(_ wire:URLRequest) throws -> Data {
        if let bytes=wire.httpBody{return bytes};guard let stream=wire.httpBodyStream else {throw URLError(.badServerResponse)}
        stream.open();defer{stream.close()};var data=Data(),buffer=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<0 {throw stream.streamError ?? URLError(.badServerResponse)};if n==0 {break};data.append(contentsOf:buffer.prefix(n))};return data
    }
    static func backend(_ fixed:TaskControlServerFixture,subject:UUID? = nil,configured:Bool=true) throws -> (NativeChatHTTPBackend,ControlWireCredentials) {
        let session=URLSessionConfiguration.ephemeral;session.protocolClasses=[ControlWireProtocol.self]
        let credentials=ControlWireCredentials(),config=try NativeChatConfiguration(origin:URL(string:"https://task-control.example.invalid")!,localScope:Profiles.user,serverScopeID:fixed.binding.scope_id,expectedSubjectID:configured ? (subject ?? UUID(uuidString:fixed.subject_id)!) : nil)
        return (NativeChatHTTPBackend(configuration:config,credentials:credentials,sessionConfiguration:session),credentials)
    }
    static let capability:[String:Any]=["contract":"catpaw.task-control.v1","read":true,"pause":true,"resume":true,"revoke":true,"same_task":true,"pause_preserves_grant":true,"unknown_resend":false]
    static func cases(_ fixed:TaskControlServerFixture)->[Case] {[
        Case(name:"actual native HTTP adapter consumes maintained API cold-state and immutable originals with GET only") {
            let (backend,_)=try backend(fixed);var requests:[URLRequest]=[];let values=[fixed.initial,fixed.pause_read,fixed.resume_read,fixed.revoke_read]
            ControlWireProtocol.handler={wire in requests.append(wire);try check(wire.httpMethod=="GET" && wire.value(forHTTPHeaderField:"Authorization")=="Bearer named-offline-task-control","Original authenticated read only");return .init(data:try ConversationTaskActionJSON.encoded(values[requests.count-1]))};defer{ControlWireProtocol.handler=nil}
            _ = try await backend.readControl(fixed.reference)
            for request in [fixed.pause_input,fixed.resume_input,fixed.revoke_input] {_ = try await backend.readControlOperation(fixed.reference,operationID:request.operationID)}
            try check(requests.count==4 && requests.allSatisfy{$0.httpMethod=="GET" && $0.url!.path.contains(fixed.binding.run_id.uuidString.lowercased())} && requests[1].url!.path.hasSuffix("/operations/"+fixed.pause_input.operationID.uuidString.lowercased()),"All original UUID paths, zero POST")
            await backend.close()
        },
        Case(name:"explicit native pause POST contains only exact original operation and CAS fields") {
            let (backend,_)=try backend(fixed);var calls=0
            ControlWireProtocol.handler={wire in calls += 1;try check(wire.httpMethod=="POST" && wire.url!.path.hasSuffix("/control/operations"),"Additive maintained controls route");let bytes=try body(wire),json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any];try check(Set(json.keys)==Set(["operation_id","action","expected_execution_revision","expected_snapshot_hash","expected_grant_epoch","expected_plan_revision","expected_plan_hash"]) && bytes.count<=8000,"No target/account/grant override");try check(json["operation_id"] as? String==fixed.pause_input.operationID.uuidString.lowercased(),"Lower canonical UUID");try check(try JSONDecoder().decode(ConversationTaskControlRequest.self,from:bytes)==fixed.pause_input,"Exact request bytes");return .init(data:try ConversationTaskActionJSON.encoded(fixed.paused))};defer{ControlWireProtocol.handler=nil}
            let value=try await backend.submitControl(fixed.reference,request:fixed.pause_input);try value.validateApplied(reference:fixed.reference,request:fixed.pause_input,base:fixed.initial.control);try check(calls==1,"One intentional control POST");await backend.close()
        },
        Case(name:"missing or mismatched trusted subject and wrong local realm cause zero HTTP") {
            var calls=0;ControlWireProtocol.handler={_ in calls += 1;return .init(status:500,data:Data())};defer{ControlWireProtocol.handler=nil}
            for configured in [true,false] {let (backend,_)=try backend(fixed,subject:UUID(),configured:configured);_ = try await reject{_ = try await backend.readControl(fixed.reference)};let failure=try await reject{_ = try await backend.submitControl(fixed.reference,request:fixed.pause_input)};try check(failure is ConversationTaskControlDispatchFailure,"Preflight proven unsent");await backend.close()}
            let (backend,_)=try backend(fixed);let foreign=ConversationTaskControlReference(scope:Profiles.demo,binding:fixed.binding,subjectID:fixed.subject_id,title:"Foreign");_ = try await reject{_ = try await backend.readControl(foreign)};try check(calls==0,"No foreign account/scope route");await backend.close()
        },
        Case(name:"control capability requires exact readiness contract and safe semantics rather than Bool or numeric coercion") {
            let (backend,_)=try backend(fixed);defer{ControlWireProtocol.handler=nil}
            for index in 0..<9 {var cap=capability;var ready:Any=true;switch index {case 0:break;case 1:cap["unknown_resend"]=true;case 2:cap["pause_preserves_grant"]=false;case 3:cap["same_task"]=false;case 4:cap["contract"]="future";case 5:cap["resume"]=false;case 6:ready=false;case 7:cap["resume"]=1;default:ready=1}
                ControlWireProtocol.handler={wire in try check(wire.httpMethod=="GET" && wire.url!.path=="/readyz","Availability is read only");return .init(data:try JSONSerialization.data(withJSONObject:["ready":ready,"chat_capabilities":["task_controls":cap]]))};let available=try await backend.controlAvailability(fixed.reference);try check(available==(index==0),"No inferred unsafe capability")
            };await backend.close()
        },
        Case(name:"original GET404 keeps original not found without a retry POST") {
            let (backend,_)=try backend(fixed);var requests:[URLRequest]=[]
            ControlWireProtocol.handler={wire in requests.append(wire);return .init(status:404,data:Data(#"{"schema_version":1,"error":{"code":"not_found","reconciliation_required":false,"retryable":false}}"#.utf8))};defer{ControlWireProtocol.handler=nil}
            let failure=try await reject{_ = try await backend.readControlOperation(fixed.reference,operationID:fixed.pause_input.operationID)}
            try check((failure as? ConversationTaskControlError) == .originalNotFound && requests.count==1 && requests[0].httpMethod=="GET" && requests[0].url!.path.hasSuffix(fixed.pause_input.operationID.uuidString.lowercased()),"Original 404 not success or rejection");await backend.close()
        },
        Case(name:"strict native JSON rejects escaped duplicate keys boolean revisions unsafe integers and malformed identities") {
            let (backend,_)=try backend(fixed);let base=String(decoding:try ConversationTaskActionJSON.encoded(fixed.initial),as:UTF8.self);defer{ControlWireProtocol.handler=nil}
            let variants=[base.replacingOccurrences(of:"\"execution_revision\":0",with:"\"execution_revision\":0,\"execution_\\u0072evision\":0"),base.replacingOccurrences(of:"\"execution_revision\":0",with:"\"execution_revision\":true"),base.replacingOccurrences(of:"\"execution_revision\":0",with:"\"execution_revision\":9007199254740992"),base.replacingOccurrences(of:fixed.subject_id,with:UUID().uuidString.lowercased())]
            for text in variants {ControlWireProtocol.handler={_ in .init(data:Data(text.utf8))};_ = try await reject{_ = try await backend.readControl(fixed.reference)}}
            await backend.close()
        },
        Case(name:"POST401 or malformed applied receipt remain unknown rather than proven not sent") {
            let (backend,credentials)=try backend(fixed);defer{ControlWireProtocol.handler=nil}
            ControlWireProtocol.handler={_ in .init(status:401,data:Data(#"{"schema_version":1,"error":{"code":"session_revoked","reconciliation_required":true,"retryable":false}}"#.utf8))}
            let failure=try await reject{_ = try await backend.submitControl(fixed.reference,request:fixed.pause_input)};let rejected=await credentials.count();try check(!(failure is ConversationTaskControlDispatchFailure) && rejected==1,"POST began before auth rejection")
            var bad=fixed.paused;bad.operation!.receipt_hash=String(repeating:"f",count:64);ControlWireProtocol.handler={_ in .init(data:try ConversationTaskActionJSON.encoded(bad))};let invalid=try await reject{_ = try await backend.submitControl(fixed.reference,request:fixed.pause_input)};try check(!(invalid is ConversationTaskControlDispatchFailure),"Malformed receipt not inferred not sent");await backend.close()
        },
        Case(name:"POST409 only explicit final nonreconcilable rejection can be treated as rejected") {
            let (backend,_)=try backend(fixed);defer{ControlWireProtocol.handler=nil}
            for (retry,reconcile,expected) in [(false,false,true),(true,false,false),(false,true,false)] {
                ControlWireProtocol.handler={_ in .init(status:409,data:try JSONSerialization.data(withJSONObject:["schema_version":1,"error":["code":"control_snapshot_conflict","retryable":retry,"reconciliation_required":reconcile]]))}
                let error=try await reject{_ = try await backend.submitControl(fixed.reference,request:fixed.pause_input)};let rejected:Bool;if case .conflict?=error as? CatpawError {rejected=true}else{rejected=false};try check(rejected==expected && !(error is ConversationTaskControlDispatchFailure),"409 classification follows authority response")
            };await backend.close()
        }
    ]}
}
#if TASK_CONTROL_TRANSPORT_PORTABLE
@main struct TaskControlTransportPortableRunner {
    static func main() async throws {let fixed=try TaskControlServerFixture.read();for test in TaskControlTransportMatrix.cases(fixed){do{try await test.run();FileHandle.standardOutput.write(Data(("PASS: "+test.name+"\n").utf8))}catch{FileHandle.standardError.write(Data(("FAIL: "+test.name+" · "+String(describing:error)+"\n").utf8));throw error}};print("EVIDENCE: actual native URLSession adapter intercepted by named URLProtocol; live external Auth/model/SQL/phone calls = 0")}
}
#else
final class NativeTaskControlTransportTests:XCTestCase {
    func testNativeTaskControlWireAndMaintainedColdFixtureMatrix() async throws {let fixed=try TaskControlServerFixture.read();for test in TaskControlTransportMatrix.cases(fixed){do{try await test.run()}catch{XCTFail(test.name+": "+String(describing:error));throw error}}}
}
#endif
