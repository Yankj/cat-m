import Foundation
import XCTest
@testable import cat

private final class InboxWireProtocol:URLProtocol,@unchecked Sendable {
    struct Reply {var status:Int=200;var data:Data;var type="application/json"}
    static var handler:((URLRequest)throws->Reply)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){do{guard let handler=Self.handler else {throw URLError(.unsupportedURL)};let reply=try handler(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:reply.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":reply.type])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:reply.data);client?.urlProtocolDidFinishLoading(self)}catch{client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading(){}
}
private struct InboxWireCredentials:NativeChatSessionCredentials {
    func authorization(scope:DataScope) async throws -> String {"Bearer named-offline-inbox-wire"}
}
final class NativeInboxTransportTests:XCTestCase {
    private func fixture() throws -> (ConversationInboxReference,[String:Any],[String:Any]) {
        let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/inbox-wire-v1.json")
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any]);XCTAssertEqual(root["synthetic_only"] as? Bool,true)
        let scope=try XCTUnwrap(UUID(uuidString:root["scope_id"] as? String ?? "")),subject=try XCTUnwrap(UUID(uuidString:root["subject_id"] as? String ?? ""))
        return (.init(scope:Profiles.user,serverScopeID:scope,subjectID:subject),try XCTUnwrap(root["page"] as? [String:Any]),try XCTUnwrap(root["responses"] as? [String:Any]))
    }
    private func backend(_ reference:ConversationInboxReference) throws -> NativeChatHTTPBackend {
        let policy=URLSessionConfiguration.ephemeral;policy.protocolClasses=[InboxWireProtocol.self]
        return NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"https://inbox.example.invalid")!,localScope:reference.scope,serverScopeID:reference.serverScopeID,expectedSubjectID:reference.subjectID),credentials:InboxWireCredentials(),sessionConfiguration:policy)
    }
    private func reply(_ request:URLRequest,page:[String:Any],responses:[String:Any]) throws -> InboxWireProtocol.Reply {
        XCTAssertEqual(request.httpMethod ?? "GET","GET");XCTAssertNil(request.httpBody);XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer named-offline-inbox-wire")
        let path=try XCTUnwrap(request.url?.path),value:Any
        if path.contains("/inbox/"){value=page}else{value=try XCTUnwrap(responses[path],"Unrecorded maintained API route: "+path)}
        return .init(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes]))
    }
    func testMaintainedInboxRunAndArtifactBytesResolveThroughActualURLSessionWithOnlyGET() async throws {
        let (reference,page,responses)=try fixture(),backend=try backend(reference);var requests:[URLRequest]=[]
        InboxWireProtocol.handler={request in requests.append(request);return try self.reply(request,page:page,responses:responses)};defer{InboxWireProtocol.handler=nil}
        let loaded=try await backend.readInbox(reference:reference,cursor:nil,limit:20),item=try XCTUnwrap(loaded.items.first(where:{!$0.artifacts.isEmpty}))
        let goal=try await backend.readReceivedTask(reference:reference,item:item);try item.validateResolved(goal,reference:reference)
        XCTAssertEqual(goal.binding,item.binding);XCTAssertTrue(requests.count>=3)
        XCTAssertTrue(requests.allSatisfy{($0.httpMethod ?? "GET")=="GET"})
        await backend.close()
    }
    func testOtherSubjectAndScopeAreRejectedBeforeTransport() async throws {
        let (reference,_,_)=try fixture(),backend=try backend(reference);var count=0
        InboxWireProtocol.handler={_ in count+=1;throw URLError(.unsupportedURL)};defer{InboxWireProtocol.handler=nil}
        for wrong in [ConversationInboxReference(scope:reference.scope,serverScopeID:UUID(),subjectID:reference.subjectID),.init(scope:reference.scope,serverScopeID:reference.serverScopeID,subjectID:UUID())] {
            do{_=try await backend.readInbox(reference:wrong,cursor:nil,limit:20);XCTFail("Foreign partition was read")}catch catError.scopeMismatch {}catch{XCTFail("Wrong error: "+String(describing:error))}
        }
        XCTAssertEqual(count,0);await backend.close()
    }
    func testChangedArtifactBodyCannotBeDisplayedUnderOriginalHash() async throws {
        let (reference,page,responses)=try fixture(),backend=try backend(reference)
        InboxWireProtocol.handler={request in
            var reply=try self.reply(request,page:page,responses:responses)
            if request.url?.path.contains("/artifacts/")==true {
                var value=try XCTUnwrap(JSONSerialization.jsonObject(with:reply.data) as? [String:Any]),artifact=try XCTUnwrap(value["artifact"] as? [String:Any]);artifact["body"]=(artifact["body"] as? String ?? "")+" ";value["artifact"]=artifact;reply.data=try JSONSerialization.data(withJSONObject:value)
            };return reply
        };defer{InboxWireProtocol.handler=nil}
        let loaded=try await backend.readInbox(reference:reference,cursor:nil,limit:20),item=try XCTUnwrap(loaded.items.first(where:{!$0.artifacts.isEmpty}))
        do{_=try await backend.readReceivedTask(reference:reference,item:item);XCTFail("Corrupt body accepted")}catch ConversationSessionError.invalidEvent {}catch{XCTFail(String(describing:error))}
        await backend.close()
    }
    func testDeniedReadRemovesPreviouslyReceivedServiceSnapshot() async throws {
        let (reference,page,responses)=try fixture(),backend=try backend(reference),service=ConversationInboxService(reference:reference,backend:backend)
        InboxWireProtocol.handler={try self.reply($0,page:page,responses:responses)};defer{InboxWireProtocol.handler=nil}
        await service.setAdmissionAllowed(true);let first=try await service.refresh();XCTAssertFalse(first.items.isEmpty)
        InboxWireProtocol.handler={_ in .init(status:403,data:Data(#"{"error":{"code":"scope_forbidden"}}"#.utf8))}
        do{_=try await service.refresh();XCTFail("Denied list accepted")}catch ConversationInboxError.accessDenied {}catch{XCTFail(String(describing:error))}
        let cleared=await service.snapshot();XCTAssertTrue(cleared.items.isEmpty);XCTAssertFalse(cleared.isFresh);await backend.close()
    }
}
