import Foundation
#if !TASK_CONTROL_PROJECTION_PORTABLE
import XCTest
@testable import cat
#endif

private final class ControlProjectionWire:URLProtocol,@unchecked Sendable {
    static var handler:((URLRequest)throws->[String:Any])?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){do{guard let handler=Self.handler else {throw URLError(.badServerResponse)};let value=try handler(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]));client?.urlProtocolDidFinishLoading(self)}catch{client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading(){}
}
private struct ControlProjectionCredentials:NativeChatSessionCredentials {
    func authorization(scope:DataScope) async throws -> String {"Bearer named-offline-control-projection"}
}
private enum ControlProjectionScenarios {
    struct Failure:Error {let message:String}
    static func check(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    struct Fixture {
        let backend:NativeChatHTTPBackend,request:ConversationTurnRequest,binding:ConversationTaskBinding
        var projection:[String:Any]
    }
    static func fixture(runState:String,taskStatus:String) throws -> Fixture {
        let server=UUID(),conversation=UUID(),run=UUID(),subject=UUID()
        let binding=ConversationTaskBinding(scope_id:server,conversation_id:conversation,turn_id:UUID(),call_id:"named-control-projection",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash("Named offline stopped task"),request_hash:textHash("Named offline original admission"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/"+server.uuidString.lowercased()+"/runs/"+run.uuidString.lowercased())
        let request=ConversationTurnRequest(scope:Profiles.user,conversationID:conversation,threadID:conversation.uuidString,operationID:UUID(),epoch:2,history:[.init(role:.tool,content:String(decoding:try JSONEncoder().encode(binding),as:UTF8.self),toolCallID:binding.call_id,toolName:"delegate_task"),.init(role:.user,content:"Named later ordinary request")])
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ControlProjectionWire.self]
        let backend=NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"https://task-control-projection.example.invalid")!,localScope:Profiles.user,serverScopeID:server,expectedSubjectID:subject),credentials:ControlProjectionCredentials(),sessionConfiguration:config)
        let projection:[String:Any]=["schema_version":1,"run":["id":run.uuidString.lowercased(),"operation_id":binding.operation_id.uuidString.lowercased(),"delegation_id":binding.delegation_id.uuidString.lowercased(),"task_id":binding.task_id,"request_hash":binding.request_hash,"grant_epoch":1,"delegation_revision":1,"authorization_state":"superseded","state":runState,"artifact_references":[["artifact_id":textHash("Preserved historical artifact"),"version":1,"content_hash":textHash("Not read after source revocation")]]],"task":["id":binding.task_id,"status":taskStatus]]
        return .init(backend:backend,request:request,binding:binding,projection:projection)
    }
    static func observe(_ f:Fixture) async throws -> (ConversationObservation,[String]) {
        var paths:[String]=[];let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(f.binding))
        ControlProjectionWire.handler={wire in
            guard wire.httpMethod=="GET" else {throw Failure(message:"Projection recovery must not POST")}
            let path=wire.url!.path;paths.append(path)
            if path==f.binding.projection_url {return f.projection}
            if path.hasSuffix("/turns/"+f.binding.turn_id.uuidString.lowercased()){return ["schema_version":1,"contract":"catpaw.native-chat.v1","turn":["task_bindings":[encoded]]]}
            if path.hasSuffix("/turns/"+f.request.operationID.uuidString.lowercased()){return ["schema_version":1,"contract":"catpaw.native-chat.v1","turn":["id":f.request.operationID.uuidString.lowercased(),"conversation_id":f.request.conversationID.uuidString.lowercased(),"scope_id":f.binding.scope_id.uuidString.lowercased(),"grant_epoch":1,"events":[],"request_hash":textHash("Named later ordinary request")]]}
            if path.contains("/artifacts/"){throw Failure(message:"Withdrawn source must not fetch a historical artifact")}
            return ["schema_version":1,"contract":"catpaw.native-chat.v1","conversation":["id":f.request.conversationID.uuidString.lowercased(),"scope_id":f.binding.scope_id.uuidString.lowercased(),"state":"active","policy":"conversation-local-output-v1","grant_epoch":1]]
        };defer{ControlProjectionWire.handler=nil}
        let observation=try await f.backend.observe(f.request);return (observation,paths)
    }
    static func cancellationIsIndependentOfArtifactAuthority() async throws {
        for runState in ["cancelled","outcome_unknown"] {
            let f=try fixture(runState:runState,taskStatus:"cancelled"),result=try await observe(f);await f.backend.close()
            guard let goal=result.0.goals.first else {throw Failure(message:"Missing original task projection")}
            try check(goal.binding==f.binding && goal.state == .cancelled && goal.sourceAuthorizationCurrent==false && goal.artifacts.isEmpty,"Confirmed same-binding cancellation was replaced by authority uncertainty")
            try check(result.1.count==4 && !result.1.contains(where:{$0.contains("/artifacts/")}),"Only current conversation, both original turns and original task GETs")
        }
    }
    static func withdrawnCompletionNeverGrantsAResult() async throws {
        let f=try fixture(runState:"succeeded",taskStatus:"succeeded"),result=try await observe(f);await f.backend.close()
        guard let goal=result.0.goals.first else {throw Failure(message:"Missing hidden original task")}
        try check(goal.state == .unknown && goal.sourceAuthorizationCurrent==false && goal.artifacts.isEmpty && !result.1.contains(where:{$0.contains("/artifacts/")}),"Superseded success became completion or artifact authority")
    }
    static func contradictoryTaskAndRunCannotConfirmCancellation() async throws {
        let f=try fixture(runState:"failed",taskStatus:"cancelled");defer{Task{await f.backend.close()}}
        do {let result=try await observe(f);try check(result.0.goals.allSatisfy{$0.state != .cancelled && $0.artifacts.isEmpty},"Contradictory failure/cancellation was reported as confirmed cancellation")}
        catch is ConversationSessionError { }
    }
    static func unrecognizedAuthorityCannotConfirmCancellation() async throws {
        for authority in [nil,"unexpected_authority"] as [String?] {
            var f=try fixture(runState:"cancelled",taskStatus:"cancelled"),run=f.projection["run"] as! [String:Any]
            if let authority {run["authorization_state"]=authority}else{run.removeValue(forKey:"authorization_state")};f.projection["run"]=run
            let result=try await observe(f);await f.backend.close()
            try check(result.0.goals.allSatisfy{$0.state == .unknown && $0.artifacts.isEmpty && $0.sourceAuthorizationCurrent==false},"Missing or garbage authorization was treated as a confirmed cancellation")
        }
    }
    static func wrongBindingNeverChangesTheOriginalTask() async throws {
        for field in ["id","task_id","request_hash","grant_epoch"] {
            var f=try fixture(runState:"cancelled",taskStatus:"cancelled"),run=f.projection["run"] as! [String:Any]
            if field=="grant_epoch" {run[field]=2}else if field=="id" {run[field]=UUID().uuidString.lowercased()}else {run[field]=textHash("Different scoped binding")}
            f.projection["run"]=run
            do {_=try await observe(f);throw Failure(message:"Wrong binding was accepted")}
            catch is ConversationSessionError { }
            await f.backend.close()
        }
    }
    static func runAll() async throws {
        try await cancellationIsIndependentOfArtifactAuthority();try await withdrawnCompletionNeverGrantsAResult();try await contradictoryTaskAndRunCannotConfirmCancellation();try await unrecognizedAuthorityCannotConfirmCancellation();try await wrongBindingNeverChangesTheOriginalTask()
    }
}
#if TASK_CONTROL_PROJECTION_PORTABLE
@main struct ControlProjectionPortable {
    static func main() async throws {try await ControlProjectionScenarios.runAll();print("PASS 5 native URLSession projection scenario groups; explicit offline wire fixtures, live Auth/model/SQL/phone = 0")}
}
#else
final class NativeTaskControlProjectionTests:XCTestCase {
    func testOriginalCancellationAndWithdrawnSourceRemainSeparateThroughActualHTTPAdapter() async throws {try await ControlProjectionScenarios.runAll()}
}
#endif
