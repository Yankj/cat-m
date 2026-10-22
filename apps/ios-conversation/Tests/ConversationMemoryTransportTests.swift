import Foundation
#if !MEMORY_TRANSPORT_PORTABLE
import XCTest
@testable import cat
#endif

private enum MemoryTransportFailure:Error {case assertion(String)}
private func memoryTransportCheck(_ condition:Bool,_ detail:String) throws {if !condition {throw MemoryTransportFailure.assertion(detail)}}
private struct MemoryTransportFixture {
    let request:ConversationMemoryRequest,receipt:ConversationMemoryReceipt,state:ConversationMemorySnapshot,reference:ConversationMemoryReference
    static func read() throws -> Self {
        let file=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/memory-wire-v2.json")
        let root=try ConversationStrictJSON.object(Data(contentsOf:file),maxBytes:2_000_000)
        func decode<T:Decodable>(_ key:String,_ type:T.Type) throws -> T {try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:root[key]!))}
        let request=try decode("request",ConversationMemoryRequest.self),receipt=try decode("receipt",ConversationMemoryReceipt.self),state=try decode("state",ConversationMemorySnapshot.self)
        return .init(request:request,receipt:receipt,state:state,reference:.init(scope:Profiles.user,serverScopeID:state.scope_id,subjectID:state.subject_id))
    }
    func backend(host:String) throws -> NativeMemoryHTTPBackend {
        let policy=URLSessionConfiguration.ephemeral;policy.protocolClasses=[DeviceEffectWireProtocol.self]
        return try NativeMemoryHTTPBackend(configuration:.init(origin:URL(string:"https://"+host)!,localScope:reference.scope,serverScopeID:reference.serverScopeID,expectedSubjectID:reference.subjectID),credentials:DeviceEffectWireCredentials(),sessionConfiguration:policy)
    }
}
private actor MemoryTransportServer {
    enum ReplyMode:Sendable {case accepted,definite409,plain409,wrongContract,unknown409,retryable409,inventedCode,duplicateKey,operationConflict}
    let f:MemoryTransportFixture,mode:ReplyMode
    var conversationExists:Bool,conversationPosts=0,memoryPosts=0,originalReads=0,conversationReads=0
    var saved:Data?
    init(_ f:MemoryTransportFixture,mode:ReplyMode = .accepted,exists:Bool=false){self.f=f;self.mode=mode;conversationExists=exists}
    func counters()->[Int] {[conversationPosts,memoryPosts,originalReads,conversationReads]}
    func response(_ request:URLRequest) async throws -> DeviceEffectWireProtocol.Reply {
        let path=request.url!.path,base="/catpaw/memory/v1/scopes/"+f.reference.serverScopeID.uuidString.lowercased()
        if path==base+"/state" {return .init(data:try ConversationMemoryCodec.encoded(f.state))}
        if path.contains("/catpaw/chat/v1/") {
            if request.httpMethod=="POST" {
                conversationPosts+=1;let raw=try ConversationStrictJSON.object(DeviceEffectWireProtocol.body(request));try memoryTransportCheck(Set(raw.keys)==["conversation_id"],"Empty conversation ensure included message/model/grant data");conversationExists=true
            }else{conversationReads+=1;if !conversationExists{return .init(status:404,data:Data("{}".utf8))}}
            let conversation:[String:Any]=["id":f.request.command.conversation_id!.uuidString.lowercased(),"subject_id":f.reference.subjectID.uuidString.lowercased(),"scope_id":f.reference.serverScopeID.uuidString.lowercased(),"state":"active","policy":"conversation-local-output-v1","revision":1,"grant_epoch":1,"messages":[]]
            return .init(data:try JSONSerialization.data(withJSONObject:["schema_version":1,"contract":"catpaw.native-chat.v1","conversation":conversation]))
        }
        if path.hasPrefix(base+"/commands/"){originalReads+=1;return .init(data:try saved ?? ConversationMemoryCodec.encoded(f.receipt))}
        guard path==base+"/commands",request.httpMethod=="POST" else {throw MemoryTransportFailure.assertion("Unexpected memory request")}
        memoryPosts+=1
        let input=try JSONDecoder().decode(ConversationMemoryRequest.self,from:DeviceEffectWireProtocol.body(request))
        var root=try JSONSerialization.jsonObject(with:ConversationMemoryCodec.encoded(f.receipt)) as! [String:Any],operation=root["operation"] as! [String:Any],result=operation["result"] as! [String:Any]
        operation["operation_id"]=input.id.uuidString.lowercased();operation["request_hash"]=try input.requestHash();operation["expected_memory_generation"]=input.expected_memory_generation;operation["command_type"]=input.command.type.rawValue
        result["memory_generation"]=input.expected_memory_generation+1;result["enabled"]=input.command.enabled ?? true
        if input.command.type == .set_enabled {result["status"]="applied";result["claim_id"]=NSNull();result["version"]=NSNull();result["source_id"]=NSNull()}
        operation["result"]=result;root["operation"]=operation;saved=try JSONSerialization.data(withJSONObject:root)
        if mode == .accepted {return .init(data:saved!)}
        var envelope:[String:Any]=["schema_version":1,"contract":ConversationMemoryCodec.contract,"error":["code":"memory_generation_conflict","retryable":false,"reconciliation_required":false]]
        switch mode {
        case .plain409:return .init(status:409,data:Data("upstream response lost".utf8),type:"text/plain")
        case .wrongContract:envelope["contract"]="unknown.error.v1"
        case .unknown409:envelope["error"]=["code":"memory_generation_conflict","retryable":false,"reconciliation_required":true]
        case .retryable409:envelope["error"]=["code":"memory_generation_conflict","retryable":true,"reconciliation_required":false]
        case .inventedCode:envelope["error"]=["code":"invented_ack","retryable":false,"reconciliation_required":false]
        case .operationConflict:envelope["error"]=["code":"memory_operation_conflict","retryable":false,"reconciliation_required":false]
        case .duplicateKey:return .init(status:409,data:Data(#"{"schema_version":1,"contract":"catpaw.memory.v1","error":{"code":"memory_generation_conflict","retryable":false,"retryable":false,"reconciliation_required":false}}"#.utf8))
        default:break
        }
        return .init(status:409,data:try JSONSerialization.data(withJSONObject:envelope))
    }
}
private enum MemoryTransportMatrix {
    static func run() async throws {
        let f=try MemoryTransportFixture.read()
        // Real Native HTTP adapter's initial empty conversation, and exact request/receipt.
        for exists in [false,true] {
            let host="memory-ensure-"+UUID().uuidString.lowercased()+".invalid",server=MemoryTransportServer(f,exists:exists),backend=try f.backend(host:host)
            DeviceEffectWireProtocol.register(host){try await server.response($0)}
            let result=try await backend.submitMemory(f.reference,request:f.request);try result.validate(f.reference,request:f.request)
            _=try await backend.readMemoryOperation(f.reference,request:f.request)
            try memoryTransportCheck(await server.counters()==[exists ? 0:1,1,1,1],"Ensure renewed/duplicated existing conversation or original GET repeated a write")
            await backend.close();DeviceEffectWireProtocol.remove(host)
        }
        // Uncertain/malformed responses may follow durable acceptance. Keep original
        // identity and recover via GET; never mark these cases safe to reissue.
        for mode in [MemoryTransportServer.ReplyMode.plain409,.wrongContract,.unknown409,.retryable409,.inventedCode,.duplicateKey,.operationConflict] {
            let host="memory-unknown-"+UUID().uuidString.lowercased()+".invalid",server=MemoryTransportServer(f,mode:mode),backend=try f.backend(host:host)
            DeviceEffectWireProtocol.register(host){try await server.response($0)}
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("memory-wire-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
            let file=FilePersistence(url:root.appendingPathComponent("store.json")),service=ConversationMemoryService(repository:try Repository(persistence:file),reference:f.reference,backend:backend)
            await service.setAdmissionAllowed(true);_=try await service.refresh();var command=ConversationMemoryCommand(type:.set_enabled);command.enabled=true
            do{_=try await service.submit(command);throw MemoryTransportFailure.assertion("Uncertain denial became applied")}catch MemoryTransportFailure.assertion(let reason){throw MemoryTransportFailure.assertion(reason)}catch{}
            let pending=try await service.localState().pending;try memoryTransportCheck(pending != nil && pending?.notSent==false,"Uncertain HTTP denial discarded original unknown")
            do{_=try await service.reopenNotSent();throw MemoryTransportFailure.assertion("Uncertain denial allowed fresh operation")}catch ConversationMemoryError.busy{}
            let cold=ConversationMemoryService(repository:try Repository(persistence:file),reference:f.reference,backend:backend);await cold.setAdmissionAllowed(true);let restored=try await cold.readOriginal()
            try memoryTransportCheck(restored.pending==nil && restored.lastReceipt?.operation.operation_id==pending?.request.id,"Original HTTP GET failed to apply same operation")
            try memoryTransportCheck(await server.counters()==[0,1,1,0],"Uncertain response recovery performed ensure or repeated POST")
            await backend.close();DeviceEffectWireProtocol.remove(host)
        }
        let rejectionHost="memory-denial-"+UUID().uuidString.lowercased()+".invalid",rejectionServer=MemoryTransportServer(f,mode:.definite409),rejectionBackend=try f.backend(host:rejectionHost)
        DeviceEffectWireProtocol.register(rejectionHost){try await rejectionServer.response($0)}
        var enabled=ConversationMemoryCommand(type:.set_enabled);enabled.enabled=true
        let rejectedRequest=try ConversationMemoryRequest(generation:f.state.memory_generation,command:enabled)
        do{_=try await rejectionBackend.submitMemory(f.reference,request:rejectedRequest);throw MemoryTransportFailure.assertion("Typed known denial was not rejected")}catch ConversationMemoryError.rejected{}
        await rejectionBackend.close();DeviceEffectWireProtocol.remove(rejectionHost)
        // A wrong account/scope cannot reach credentials or even an ensure GET.
        let host="memory-scope-"+UUID().uuidString.lowercased()+".invalid",counter=DeviceEffectCounter(),backend=try f.backend(host:host)
        DeviceEffectWireProtocol.register(host){_ in counter.increment();throw MemoryTransportFailure.assertion("Foreign identity reached HTTP")}
        let wrong=ConversationMemoryReference(scope:f.reference.scope,serverScopeID:f.reference.serverScopeID,subjectID:UUID())
        do{_=try await backend.submitMemory(wrong,request:f.request);throw MemoryTransportFailure.assertion("Foreign submit accepted")}catch ConversationMemoryError.notSent{}
        try memoryTransportCheck(counter.count()==0,"Foreign identity sent HTTP");await backend.close();DeviceEffectWireProtocol.remove(host)
        print("PASS memory transport: initial ensure/existing no renewal; uncertain 4xx/operation conflict keeps original unknown; cold GET no POST; wrong subject zero HTTP")
    }
}
#if MEMORY_TRANSPORT_PORTABLE
@main struct MemoryTransportPortableRunner {static func main() async throws {
    if CommandLine.arguments.count>1 {let root=try ConversationStrictJSON.object(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),maxBytes:16000);let request=try JSONDecoder().decode(ConversationMemoryRequest.self,from:JSONSerialization.data(withJSONObject:root["request"]!));FileHandle.standardOutput.write(Data(("swift_bytes="+String(decoding:try ConversationMemoryCodec.encoded(request),as:UTF8.self)+"\nnative="+(try request.requestHash())+"\nnode="+(root["request_hash"] as! String)+"\n").utf8));try memoryTransportCheck(try request.requestHash()==root["request_hash"] as? String,"JS/native numeric canonical hash differs");return}
    try await MemoryTransportMatrix.run()
}}
#else
final class ConversationMemoryTransportTests:XCTestCase {func testActualHTTPMemoryUnknownRecoveryAndScope() async throws {try await MemoryTransportMatrix.run()}}
#endif
