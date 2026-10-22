#if canImport(XCTest)
import Foundation
import XCTest
@testable import cat

private final class ArtifactEditWireProtocol:URLProtocol,@unchecked Sendable {
    static var handler:((URLRequest) throws -> (Int,Data,String?))?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            let (status,data,mime)=try Self.handler!(request)
            let headers=mime.map{["Content-Type":$0]} ?? [:]
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
private actor ArtifactEditWireCredentials:NativeChatSessionCredentials {
    let value:String?
    private(set) var rejections=0
    init(_ value:String?="Bearer synthetic-artifact-edit-session"){self.value=value}
    func authorization(scope:DataScope) async throws -> String {guard let value else {throw ConversationSessionError.notConfigured};return value}
    func rejected(scope:DataScope) async {rejections += 1}
}
final class NativeArtifactEditTransportTests:XCTestCase {
    private func backend(_ reference:ConversationArtifactEditReference,credentials:any NativeChatSessionCredentials=ArtifactEditWireCredentials()) throws -> NativeChatHTTPBackend {
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[ArtifactEditWireProtocol.self]
        return NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"https://artifact.example.invalid/functions/v1/catpaw-api")!,localScope:reference.scope,serverScopeID:reference.binding.scope_id),credentials:credentials,sessionConfiguration:configuration)
    }
    private func data<T:Encodable>(_ value:T) throws -> Data {try JSONEncoder().encode(value)}
    private func requestBody(_ wire:URLRequest)->Data {
        if let data=wire.httpBody {return data};guard let stream=wire.httpBodyStream else {return Data()}
        stream.open();defer{stream.close()};var data=Data(),chunk=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {let count=stream.read(&chunk,maxLength:chunk.count);if count<=0 {break};data.append(contentsOf:chunk.prefix(count))};return data
    }
    private func rejectUnknown(_ work:() async throws -> Void,file:StaticString=#filePath,line:UInt=#line) async {
        do {try await work();XCTFail("Wire failure accepted",file:file,line:line)} catch {XCTAssertFalse(error is ConversationDispatchFailure,"Dispatched POST became notSent",file:file,line:line);if case .conflict?=error as? catError {XCTFail("Ambiguous response became definitive conflict",file:file,line:line)}}
    }
    @MainActor func testExactServerScopeVersionOperationAndRequestBytesUseActualAdapter() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove();ArtifactEditWireProtocol.handler=nil}
        let base=try await c.backend.readArtifact(c.reference,version:nil),request=try ArtifactEditTestSupport.request(base.artifact),applied=try await c.backend.amendArtifact(c.reference,request:request),http=try backend(c.reference)
        let baseData=try data(base),appliedData=try data(applied);var routes:[String]=[]
        ArtifactEditWireProtocol.handler={wire in
            routes.append(wire.url!.path);XCTAssertNil(wire.url?.query)
            XCTAssertEqual(wire.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-artifact-edit-session")
            XCTAssertEqual(wire.value(forHTTPHeaderField:"Accept"),"application/json")
            if wire.httpMethod=="POST" {let bytes=self.requestBody(wire);XCTAssertEqual(try JSONDecoder().decode(ConversationArtifactEditAmendRequest.self,from:bytes),request);XCTAssertEqual((try JSONSerialization.jsonObject(with:bytes) as! [String:Any])["operation_id"] as? String,request.operationID.uuidString.lowercased())}
            return (200,wire.url!.path.contains("amendments") ? appliedData : baseData,"application/json; charset=utf-8")
        }
        XCTAssertNotEqual(c.reference.scope.workspaceID,c.reference.binding.scope_id)
        let current=try await http.readArtifact(c.reference,version:nil),historical=try await http.readArtifact(c.reference,version:2)
        let committed=try await http.amendArtifact(c.reference,request:request),recovered=try await http.readAmendment(c.reference,operationID:request.operationID)
        XCTAssertEqual(current,base);XCTAssertEqual(historical,base);XCTAssertEqual(committed,applied);XCTAssertEqual(recovered,applied)
        let prefix="/functions/v1/catpaw-api/catpaw/artifacts/v1/scopes/"+c.reference.binding.scope_id.uuidString.lowercased()+"/runs/"+c.reference.binding.run_id.uuidString.lowercased()+"/artifacts/"+c.reference.artifact.id
        XCTAssertEqual(routes,[prefix,prefix+"/versions/2",prefix+"/amendments",prefix+"/amendments/"+request.operationID.uuidString.lowercased()]);await http.close()
    }
    @MainActor func testCrossScopeMissingCredentialsAndInvalidInputFailBeforePost() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove();ArtifactEditWireProtocol.handler=nil}
        let base=try await c.backend.readArtifact(c.reference,version:nil),request=try ArtifactEditTestSupport.request(base.artifact),http=try backend(c.reference)
        var calls=0;ArtifactEditWireProtocol.handler={_ in calls += 1;return (500,Data(),"application/json")}
        let foreign=ConversationArtifactEditReference(scope:Profiles.demo,binding:c.reference.binding,subjectID:c.reference.subjectID,artifact:c.reference.artifact)
        var binding=try ArtifactEditTestSupport.object(c.reference.binding);binding["scope_id"]=UUID().uuidString
        let otherServer=ConversationArtifactEditReference(scope:c.reference.scope,binding:try ArtifactEditTestSupport.decode(ConversationTaskBinding.self,binding),subjectID:c.reference.subjectID,artifact:c.reference.artifact)
        let brokenArtifact=ConversationArtifactProjection(id:c.reference.artifact.id,version:2,contentHash:textHash("wrong"),body:c.reference.artifact.body,title:c.reference.artifact.title,summary:c.reference.artifact.summary,content:c.reference.artifact.content)
        let badBody=ConversationArtifactEditReference(scope:c.reference.scope,binding:c.reference.binding,subjectID:c.reference.subjectID,artifact:brokenArtifact)
        for ref in [foreign,otherServer,badBody] {
            do {_=try await http.readArtifact(ref,version:nil);XCTFail("Unbound GET dispatched")}catch {}
            do {_=try await http.amendArtifact(ref,request:request);XCTFail("Unbound POST dispatched")}catch {XCTAssertTrue(error is ConversationDispatchFailure)}
        }
        let invalid=ConversationArtifactEditAmendRequest(operationID:UUID(),expectedVersion:2,expectedContentHash:base.artifact.contentHash,expectedGrantEpoch:1,expectedPlanRevision:1,expectedPlanHash:base.artifact.planReference.planHash,content:.init(title:"\u{FEFF}",summary:"s",content:"c"))
        do {_=try await http.amendArtifact(c.reference,request:invalid);XCTFail("Invalid content dispatched")}catch {XCTAssertTrue(error is ConversationDispatchFailure)}
        for token in [nil,"invalid scheme","Bearer synthetic\rinjected","Bearer synthetic\ninjected","Bearer synthetic\r\ninjected","Bearer "+String(repeating:"x",count:8185)] as [String?] {
            let denied=try backend(c.reference,credentials:ArtifactEditWireCredentials(token))
            do {_=try await denied.amendArtifact(c.reference,request:request);XCTFail("Preflight admission dispatched")}catch {XCTAssertTrue(error is ConversationDispatchFailure)};await denied.close()
        }
        XCTAssertEqual(calls,0);await http.close()
    }
    @MainActor func testKnownConflictIsDistinctFromAmbiguousHTTPAndLostResponse() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove();ArtifactEditWireProtocol.handler=nil}
        let base=try await c.backend.readArtifact(c.reference,version:nil),request=try ArtifactEditTestSupport.request(base.artifact),credentials=ArtifactEditWireCredentials(),http=try backend(c.reference,credentials:credentials)
        let explicit=Data(#"{"schema_version":1,"error":{"code":"artifact_version_conflict","retryable":false,"reconciliation_required":false}}"#.utf8)
        ArtifactEditWireProtocol.handler={_ in (409,explicit,"application/json")}
        do {_=try await http.amendArtifact(c.reference,request:request);XCTFail("Known conflict accepted")}catch {if case .conflict?=error as? catError {}else {XCTFail("Known conflict was not classified")}}
        let ambiguous=[#"{"schema_version":1,"error":{"code":"fixture_unknown","reconciliation_required":false}}"#,#"{"schema_version":1,"error":{"code":"fixture_unknown","retryable":false,"reconciliation_required":true}}"#,#"{"schema_version":1,"error":{"code":"fixture_unknown","retryable":true,"reconciliation_required":false}}"#,#"{"schema_version":1,"error":{"code":"fixture_unknown","retryable":false,"reconciliation_required":false,"reconciliation_required":false}}"#]
        for body in ambiguous {ArtifactEditWireProtocol.handler={_ in (409,Data(body.utf8),"application/json")};await rejectUnknown{_=try await http.amendArtifact(c.reference,request:request)}}
        for status in [401,403,429,500,302] {ArtifactEditWireProtocol.handler={_ in (status,explicit,"application/json")};await rejectUnknown{_=try await http.amendArtifact(c.reference,request:request)}}
        ArtifactEditWireProtocol.handler={_ in throw URLError(.networkConnectionLost)};await rejectUnknown{_=try await http.amendArtifact(c.reference,request:request)}
        let rejected=await credentials.rejections;XCTAssertEqual(rejected,1);await http.close()
    }
    @MainActor func testMalformedSuccessHashVersionMimeAndOriginalReceiptCannotBeAccepted() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove();ArtifactEditWireProtocol.handler=nil}
        let base=try await c.backend.readArtifact(c.reference,version:nil),request=try ArtifactEditTestSupport.request(base.artifact),applied=try await c.backend.amendArtifact(c.reference,request:request),http=try backend(c.reference)
        var malformed:[[String:Any]]=[]
        for (key,value) in [("schema_version",2),("contract","future-artifact-v2")] as [(String,Any)] {var o=try ArtifactEditTestSupport.object(base);o[key]=value;malformed.append(o)}
        for (key,value) in [("content_hash",textHash("wrong body")),("mime_type","text/html"),("created_at","2026-02-30T00:00:00.000Z"),("grant_epoch",true)] as [(String,Any)] {var o=try ArtifactEditTestSupport.object(base),a=o["artifact"] as! [String:Any];a[key]=value;o["artifact"]=a;malformed.append(o)}
        for o in malformed {let bytes=try JSONSerialization.data(withJSONObject:o);ArtifactEditWireProtocol.handler={_ in (200,bytes,"application/json")};do {_=try await http.readArtifact(c.reference,version:nil);XCTFail("Malformed GET accepted")}catch {}}
        var old=try ArtifactEditTestSupport.object(base),oldArtifact=old["artifact"] as! [String:Any],current=oldArtifact["current_reference"] as! [String:Any]
        current["version"]=3;current["content_hash"]=textHash("future head");oldArtifact["is_current"]=false;oldArtifact["editable"]=false;oldArtifact["current_reference"]=current;old["artifact"]=oldArtifact
        let oldBytes=try JSONSerialization.data(withJSONObject:old);ArtifactEditWireProtocol.handler={_ in (200,oldBytes,"application/json")}
        do {_=try await http.readArtifact(c.reference,version:nil);XCTFail("Current GET returned older version")}catch {}
        // A specific historical version is legitimate, but must exactly match the requested version.
        let historical=try await http.readArtifact(c.reference,version:2);XCTAssertEqual(historical.artifact.version,2)
        do {_=try await http.readArtifact(c.reference,version:1);XCTFail("Historical GET followed another version")}catch {}
        for kind in ["missing","operation","base"] {
            var o=try ArtifactEditTestSupport.object(applied)
            if kind=="missing" {o.removeValue(forKey:"amendment")}
            else {var r=o["amendment"] as! [String:Any];if kind=="operation" {r["operation_id"]=UUID().uuidString}else {var b=r["base_reference"] as! [String:Any];b["content_hash"]=textHash("wrong base");r["base_reference"]=b};o["amendment"]=r}
            let bytes=try JSONSerialization.data(withJSONObject:o);ArtifactEditWireProtocol.handler={_ in (200,bytes,"application/json")};await rejectUnknown{_=try await http.amendArtifact(c.reference,request:request)}
            if kind != "base" {do {_=try await http.readAmendment(c.reference,operationID:request.operationID);XCTFail("Original operation GET accepted wrong receipt")}catch {}}
        }
        let validBytes=try data(base);ArtifactEditWireProtocol.handler={_ in (200,validBytes,"text/plain")};do {_=try await http.readArtifact(c.reference,version:nil);XCTFail("Wrong Content-Type accepted")}catch {}
        let raw=String(decoding:validBytes,as:UTF8.self),duplicate=raw.replacingOccurrences(of:"\"schema_version\":1",with:"\"schema_version\":1,\"schema_version\":1")
        XCTAssertNotEqual(raw,duplicate);ArtifactEditWireProtocol.handler={_ in (200,Data(duplicate.utf8),"application/json")};do {_=try await http.readArtifact(c.reference,version:nil);XCTFail("Duplicate wire object key accepted")}catch {}
        await http.close()
    }
    @MainActor func testLegalLongBodyIsLosslessAndWireBudgetRemainsFinite() async throws {
        let c=try await ArtifactEditTestSupport.fixture();defer{c.remove();ArtifactEditWireProtocol.handler=nil}
        let base=try await c.backend.readArtifact(c.reference,version:nil),http=try backend(c.reference)
        var object=try ArtifactEditTestSupport.object(base),artifact=object["artifact"] as! [String:Any],body=try ConversationArtifactEditCodec.object(base.artifact.body),payload=body["data"] as! [String:Any]
        body["summary"]=String(repeating:"料",count:8000);payload["content"]=String(repeating:"文",count:16000);body["data"]=payload
        let exactBody=try ConversationArtifactEditCodec.canonicalString(body),hash=textHash(exactBody);artifact["body"]=exactBody;artifact["content_hash"]=hash
        var current=artifact["current_reference"] as! [String:Any];current["content_hash"]=hash;artifact["current_reference"]=current;object["artifact"]=artifact
        let bytes=try JSONSerialization.data(withJSONObject:object);XCTAssertGreaterThan(bytes.count,65536);XCTAssertLessThan(exactBody.utf8.count,256000)
        ArtifactEditWireProtocol.handler={_ in (200,bytes,"application/json")};let read=try await http.readArtifact(c.reference,version:nil)
        XCTAssertEqual(read.artifact.body,exactBody);XCTAssertEqual(try read.artifact.document().content,String(repeating:"文",count:16000));XCTAssertEqual(read.artifact.contentHash,hash)
        var oversized=bytes;oversized.append(Data(repeating:32,count:1_500_001-bytes.count))
        ArtifactEditWireProtocol.handler={_ in (200,oversized,"application/json")};do {_=try await http.readArtifact(c.reference,version:nil);XCTFail("Unbounded artifact wire response accepted")}catch {}
        await http.close()
    }
}
#endif
