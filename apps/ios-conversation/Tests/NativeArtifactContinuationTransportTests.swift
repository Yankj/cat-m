import Foundation
import XCTest
@testable import CatpawM

private final class ContinuationWireProtocol:URLProtocol,@unchecked Sendable {
    static var handler:((URLRequest)throws->(Int,[String:Any]))?
    static var mimeType="application/json"
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){do {
        let (status,value)=try Self.handler!(request)
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":Self.mimeType])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes]))
        client?.urlProtocolDidFinishLoading(self)
    }catch{client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading(){}
}
private struct ContinuationWireCredentials:NativeChatSessionCredentials {
    func authorization(scope:DataScope) async throws -> String {"Bearer synthetic-report-continuation-only"}
}
final class NativeArtifactContinuationTransportTests:XCTestCase {
    private func requestBody(_ wire:URLRequest) throws -> Data {
        if let body=wire.httpBody {return body};guard let stream=wire.httpBodyStream else {throw URLError(.badServerResponse)}
        stream.open();defer{stream.close()};var bytes=Data(),buffer=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<0 {throw stream.streamError ?? URLError(.badServerResponse)};if count==0 {break};bytes.append(contentsOf:buffer.prefix(count))}
        return bytes
    }
    private func fixture(subjectConfigured:Bool) throws -> (NativeChatHTTPBackend,ConversationTurnRequest,[String:Any]) {
        let subject=UUID(),server=UUID(),conversation=UUID(),run=UUID(),body="{\"data\":{\"content\":\"Immutable original report\"},\"kind\":\"report\"}"
        let binding=ConversationTaskBinding(scope_id:server,conversation_id:conversation,turn_id:UUID(),call_id:"original-call",delegation_id:UUID(),operation_id:UUID(),run_id:run,task_id:textHash("task"),request_hash:textHash("original request"),delegation_revision:1,grant_epoch:1,projection_url:"/catpaw/v1/scopes/\(server.uuidString.lowercased())/runs/\(run.uuidString.lowercased())")
        let artifact=ConversationArtifactVersionReference(artifactID:textHash("artifact"),version:1,contentHash:textHash(body)),planHash=textHash("plan")
        let intent=ConversationArtifactContinuationIntent(intent:.reviseReport,runID:run,taskID:binding.task_id,artifactReference:artifact,expectedGrantEpoch:1,expectedPlanRevision:1,expectedPlanHash:planHash)
        let original=ConversationTranscriptMessage(role:.tool,content:String(decoding:try JSONEncoder().encode(binding),as:UTF8.self),toolCallID:binding.call_id,toolName:"delegate_plan_v1")
        let request=ConversationTurnRequest(scope:Profiles.user,conversationID:conversation,threadID:conversation.uuidString,operationID:UUID(),epoch:2,history:[original,.init(role:.user,content:"Modify conclusion two")],continuation:intent,continuationOriginalBinding:binding,continuationSubjectID:subject)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ContinuationWireProtocol.self]
        let backend=NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"http://127.0.0.1:8123")!,localScope:Profiles.user,serverScopeID:server,expectedSubjectID:subjectConfigured ? subject : nil),credentials:ContinuationWireCredentials(),sessionConfiguration:config)
        let selected:[String:Any]=["artifact_id":artifact.artifactID,"scope_id":server.uuidString.lowercased(),"subject_id":subject.uuidString.lowercased(),"run_id":run.uuidString.lowercased(),"task_id":binding.task_id,"conversation_id":conversation.uuidString.lowercased(),"run_request_hash":binding.request_hash,"delegation_id":binding.delegation_id.uuidString.lowercased(),"delegation_revision":1,"grant_epoch":1,"version":1,"content_hash":artifact.contentHash,"body":body,"source_auth_hash":textHash("original source"),"plan_reference":["revision":1,"plan_hash":planHash],"editable":false,"is_current":true]
        return (backend,request,selected)
    }
    func testClientSelectedSubjectCannotReplaceMissingTrustedCompositionSubject() async throws {
        let (backend,request,_)=try fixture(subjectConfigured:false);var calls=0
        ContinuationWireProtocol.handler={_ in calls += 1;throw URLError(.badServerResponse)};defer{ContinuationWireProtocol.handler=nil}
        do {_=try await backend.reply(request);XCTFail("Missing trusted subject must reject before POST")}catch {guard case ConversationDispatchFailure.notSent=error else {throw error}}
        XCTAssertEqual(calls,0);await backend.close()
    }
    func testColdUnknownUsesExactFreshTurnGETAndNeverPostsAgain() async throws {
        let (backend,request,selected)=try fixture(subjectConfigured:true),binding=request.continuationOriginalBinding!
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(binding));var paths:[String]=[],methods:[String]=[]
        ContinuationWireProtocol.handler={wire in
            let path=wire.url!.path;paths.append(path);methods.append(wire.httpMethod ?? "GET")
            if path.contains("/artifacts/"){return (200,["schema_version":1,"contract":"catpaw.task-artifact.v1","artifact":selected])}
            if path.hasSuffix("/turns/"+binding.turn_id.uuidString.lowercased()){return (200,["schema_version":1,"contract":"catpaw.native-chat.v1","turn":["id":binding.turn_id.uuidString.lowercased(),"conversation_id":request.conversationID.uuidString.lowercased(),"scope_id":binding.scope_id.uuidString.lowercased(),"task_bindings":[encoded]]])}
            if path.hasSuffix("/turns/"+request.operationID.uuidString.lowercased()){return (404,["schema_version":1,"error":["code":"not_found","retryable":false,"reconciliation_required":false]])}
            return (200,["schema_version":1,"contract":"catpaw.native-chat.v1","conversation":["id":request.conversationID.uuidString.lowercased(),"scope_id":binding.scope_id.uuidString.lowercased(),"state":"active","policy":"conversation-local-output-v1","grant_epoch":1,"revision":3,"messages":[]]])
        };defer{ContinuationWireProtocol.handler=nil}
        do {_=try await backend.observe(request);XCTFail("404 must remain unconfirmed")}catch {XCTAssertEqual(error.localizedDescription,"后台读取返回 HTTP 404，保留原请求。")}
        XCTAssertTrue(paths.contains("/catpaw/revisions/v1/scopes/"+binding.scope_id.uuidString.lowercased()+"/conversations/"+request.conversationID.uuidString.lowercased()+"/turns/"+request.operationID.uuidString.lowercased()))
        XCTAssertFalse(methods.contains("POST"));XCTAssertTrue(methods.allSatisfy{$0=="GET"});await backend.close()
    }
    func testOnlyVersionedJSONDenialProvesNonAdmissionAndTargetKeepsOriginalRawBytes() async throws {
        for variant in 0..<3 {
            let (backend,request,selected)=try fixture(subjectConfigured:true),binding=request.continuationOriginalBinding!
            let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(binding));var posts=0
            ContinuationWireProtocol.mimeType="application/json"
            ContinuationWireProtocol.handler={wire in
                if wire.httpMethod=="POST" {
                    posts += 1
                    XCTAssertTrue(wire.url!.path.contains("/catpaw/revisions/v1/"))
                    let body=try ConversationStrictJSON.object(self.requestBody(wire),maxBytes:48000),turn=body["turn"] as! [String:Any]
                    XCTAssertEqual(Set(body.keys),["turn","target"])
                    XCTAssertEqual(Set(turn.keys),["turn_id","expected_revision","expected_grant_epoch","message","context"])
                    XCTAssertEqual((turn["message"] as? [String:Any])?["text"] as? String,request.history.last?.content)
                    XCTAssertEqual(body["target"] as? NSDictionary,request.continuation!.canonicalValue as NSDictionary)
                    if variant==2 {ContinuationWireProtocol.mimeType="text/plain"}
                    return (409,["schema_version":variant==1 ? 2 : 1,"error":["code":"revision_artifact_conflict","retryable":false,"reconciliation_required":false]])
                }
                if wire.url!.path=="/readyz" {return (200,["chat_capabilities":["task_revisions":["contract":"catpaw.task-revision.v1","same_task":true,"immutable_target":true,"revise":true,"explain":true]]])}
                if wire.url!.path.contains("/artifacts/") {var a=selected;a["editable"]=true;return (200,["schema_version":1,"contract":"catpaw.task-artifact.v1","artifact":a])}
                if wire.url!.path.hasSuffix("/turns/"+binding.turn_id.uuidString.lowercased()) {return (200,["schema_version":1,"contract":"catpaw.native-chat.v1","turn":["id":binding.turn_id.uuidString.lowercased(),"conversation_id":request.conversationID.uuidString.lowercased(),"scope_id":binding.scope_id.uuidString.lowercased(),"task_bindings":[encoded]]])}
                return (200,["schema_version":1,"contract":"catpaw.native-chat.v1","conversation":["id":request.conversationID.uuidString.lowercased(),"scope_id":binding.scope_id.uuidString.lowercased(),"state":"active","policy":"conversation-local-output-v1","grant_epoch":1,"revision":3,"messages":[]]])
            }
            do {let stream=try await backend.reply(request);for try await _ in stream {};XCTFail("Denied request cannot complete")}
            catch {if variant==0 {guard case ConversationDispatchFailure.notSent=error else {throw error}}else {XCTAssertFalse(error is ConversationDispatchFailure);XCTAssertTrue(error.localizedDescription.contains("HTTP 409"));XCTAssertTrue(error.localizedDescription.contains("尚未确认"))}}
            XCTAssertEqual(posts,1);await backend.close();ContinuationWireProtocol.handler=nil;ContinuationWireProtocol.mimeType="application/json"
        }
    }
    func testColdOriginalRevisionReadsMaintenanceResultAfterAnotherClientCompletesNextVersion() async throws {
        // Captured from createCloudRuntime, both same-task worker executions and
        // immutable operation GETs; every provider/store/source port was offline.
        let file=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/report-continuation-cold.json")
        let captured=try ConversationStrictJSON.object(Data(contentsOf:file),maxBytes:100000)
        XCTAssertEqual(captured["fixture_reality"] as? String,"actual_maintenance_runtime_with_injected_offline_model_store_reader_only")
        let binding=try JSONDecoder().decode(ConversationTaskBinding.self,from:JSONSerialization.data(withJSONObject:captured["binding"]!)),input=captured["input"] as! [String:Any],turn=input["turn"] as! [String:Any],message=turn["message"] as! [String:Any]
        let intent=try JSONDecoder().decode(ConversationArtifactContinuationIntent.self,from:JSONSerialization.data(withJSONObject:input["target"]!)),subject=UUID(uuidString:captured["subject_id"] as! String)!
        let history:[ConversationTranscriptMessage]=[.init(role:.tool,content:String(decoding:try JSONEncoder().encode(binding),as:UTF8.self),toolCallID:binding.call_id,toolName:"delegate_plan_v1"),.init(role:.user,content:message["text"] as! String)]
        let request=ConversationTurnRequest(scope:Profiles.user,conversationID:binding.conversation_id,threadID:binding.conversation_id.uuidString,operationID:UUID(uuidString:turn["turn_id"] as! String)!,epoch:2,history:history,continuation:intent,continuationOriginalBinding:binding,continuationSubjectID:subject)
        let responses=captured["responses"] as! [String:[String:Any]],session=URLSessionConfiguration.ephemeral;session.protocolClasses=[ContinuationWireProtocol.self]
        let backend=NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"http://127.0.0.1:8123")!,localScope:Profiles.user,serverScopeID:binding.scope_id,allowInjectedTestProvider:true,expectedSubjectID:subject),credentials:ContinuationWireCredentials(),sessionConfiguration:session)
        var paths:[String]=[],posts=0;ContinuationWireProtocol.mimeType="application/json"
        ContinuationWireProtocol.handler={wire in
            if wire.httpMethod=="POST" {posts += 1;throw URLError(.badServerResponse)}
            let path=wire.url!.path;paths.append(path)
            guard let value=responses[path] else {XCTFail("Recovery requested an uncaptured route: \(path)");throw URLError(.badServerResponse)}
            return (200,value)
        };defer{ContinuationWireProtocol.handler=nil}
        let observation=try await backend.observe(request)
        XCTAssertTrue(observation.events.contains{if case .completed=$0.payload{return true};return false})
        let result=try JSONDecoder().decode(ConversationArtifactVersionReference.self,from:JSONSerialization.data(withJSONObject:captured["first_result"]!))
        let projected=try XCTUnwrap(observation.goals.first(where:{$0.artifactHistory.contains(where:{ConversationArtifactVersionReference(ConversationArtifactIdentity($0))==result})}))
        XCTAssertEqual(projected.binding,binding);XCTAssertEqual(projected.planReference?.revision,3);XCTAssertEqual(projected.artifacts.first?.version,3);XCTAssertEqual(result.version,2)
        XCTAssertTrue(paths.contains("/catpaw/v1/scopes/"+binding.scope_id.uuidString.lowercased()+"/artifacts/"+result.artifactID+"/versions/2"),"Recovery reads the immutable result of the original operation, independently of the newer current head")
        XCTAssertTrue(paths.contains(where:{$0.contains("/operations/")}));XCTAssertEqual(posts,0);await backend.close()
    }
}
