import Foundation
#if !ACCEPTED_WORK_PORTABLE
import XCTest
@testable import cat
#endif

private struct AcceptedWireFixture {
    let raw:[String:Any],request:ConversationTurnRequest,capability:ConversationAcceptedWorkCapability,selection:ConversationAcceptedWorkSelection,intent:ConversationAcceptedWorkIntent,clock:Date
    static func read() throws -> Self {
        let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/accepted-work-wire-v3.json")
        let raw=try ConversationStrictJSON.object(Data(contentsOf:path),maxBytes:2_000_000),wrapper=raw["request"] as! [String:Any],turn=wrapper["turn"] as! [String:Any],work=wrapper["work"] as! [String:Any],message=turn["message"] as! [String:Any],limits=work["limits"] as! [String:Int],scope=raw["scope"] as! [String:String]
        let body=ConversationTurnRequest(scope:Profiles.user,conversationID:UUID(uuidString:(raw["binding"] as! [String:Any])["conversation_id"] as! String)!,threadID:nil,operationID:UUID(uuidString:turn["turn_id"] as! String)!,epoch:1,history:[.init(id:UUID(uuidString:message["id"] as! String)!,role:.user,content:message["text"] as! String)],context:(turn["context"] as! [[String:String]]).map{.init(id:$0["id"]!,text:$0["text"]!)})
        let cap=try ConversationAcceptedWorkCodec.capability(readiness:json(raw["readyz"]!),modelRoute:json(raw["model_route"]!),subjectID:UUID(uuidString:raw["subject_id"] as! String)!,serverScopeID:UUID(uuidString:scope["scope_id"]!)!)
        let options=ConversationAcceptedWorkOptions(notAfter:try ConversationAcceptedWorkCodec.instant(work["not_after"] as! String),executionBudgetMilliseconds:work["execution_budget_ms"] as! Int,modelLimit:limits["model"]!,sourceLimit:limits["source"]!,toolPolicy:ConversationAcceptedWorkToolPolicy(rawValue:work["tool_policy"] as! String)!)
        let selection=try ConversationAcceptedWorkSelection(decisionID:UUID(uuidString:work["decision_id"] as! String)!,options:options,capability:cap)
        let intent=try ConversationAcceptedWorkIntent(request:body,selection:selection,expectedRevision:turn["expected_revision"] as! Int,expectedGrantEpoch:turn["expected_grant_epoch"] as! Int)
        let clock=try ConversationAcceptedWorkCodec.instant(((raw["accepted_turn"] as! [String:Any])["turn"] as! [String:Any])["work_intent"].flatMap{($0 as? [String:Any])?["admitted_at"]} as! String)
        return .init(raw:raw,request:try body.withAcceptedWork(intent),capability:cap,selection:selection,intent:intent,clock:clock)
    }
    static func json(_ v:Any) throws -> Data {try JSONSerialization.data(withJSONObject:v,options:[.sortedKeys,.withoutEscapingSlashes])}
    var provisional:ConversationTurnRequest {.init(scope:request.scope,conversationID:request.conversationID,threadID:nil,operationID:request.operationID,epoch:1,history:request.history,context:request.context)}
    var conversation:[String:Any] {["schema_version":1,"contract":"catpaw.native-chat.v1","conversation":["id":request.conversationID.uuidString.lowercased(),"scope_id":selection.serverScopeID.uuidString.lowercased(),"subject_id":selection.subjectID.uuidString.lowercased(),"state":"active","policy":"conversation-local-output-v1","grant_epoch":intent.expectedGrantEpoch,"revision":intent.expectedRevision,"messages":[]]]}
    func native(host:String,subject:UUID?=nil,clock:Date?=nil) throws -> NativeChatHTTPBackend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[DeviceEffectWireProtocol.self]
        let clock=clock ?? self.clock
        return NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"https://"+host)!,localScope:Profiles.user,serverScopeID:selection.serverScopeID,allowInjectedTestProvider:true,expectedSubjectID:subject ?? selection.subjectID),credentials:DeviceEffectWireCredentials(),sessionConfiguration:config,acceptedWorkClock:{clock})
    }
}
private enum AcceptedWorkMatrix {
    struct Case {let name:String;let run:() async throws -> Void}
    static var cases:[Case] {[
        .init(name:"actual Node turn wrapper hash and optional journal remain exact") {
            let f=try AcceptedWireFixture.read()
            try deviceCheck(f.intent.inputHash==f.raw["input_hash"] as? String,"Node canonical turn SHA matches Swift")
            try deviceCheck(try ConversationDeviceEffectsCodec.canonicalHashJSON(f.intent.wrapper())==ConversationDeviceEffectsCodec.canonicalHashJSON(AcceptedWireFixture.json(f.raw["request"]!)),"Actual maintained wrapper unchanged")
            let restored=try JSONDecoder().decode(ConversationTurnRequest.self,from:JSONEncoder().encode(f.request));try restored.acceptedWork!.validate(request:restored)
            try deviceCheck(restored.operationID==f.request.operationID && restored.acceptedWork==f.intent,"Disk codec keeps original decision/body/UUID")
            let legacy=try JSONDecoder().decode(ConversationTurnRequest.self,from:JSONEncoder().encode(f.provisional));try deviceCheck(legacy.acceptedWork==nil,"Existing v1 journal does not acquire finite authority")
            try ConversationAcceptedWorkCodec.validateOriginal((f.raw["accepted_turn"] as! [String:Any])["turn"] as! [String:Any],request:restored)
        },
        .init(name:"capability requires exact bool contract route and never installation evidence") {
            let f=try AcceptedWireFixture.read()
            try deviceCheck(f.capability.available,"native_producer:false is historical evidence, not a new grant")
            for (key,value) in [("enabled",1 as Any),("single_run",1),("unknown_resend",true),("limits_explicit",false),("grant_contract","old-contract")] {
                var ready=f.raw["readyz"] as! [String:Any],caps=ready["chat_capabilities"] as! [String:Any],work=caps["accepted_work"] as! [String:Any];work[key]=value;caps["accepted_work"]=work;ready["chat_capabilities"]=caps
                let cap=try ConversationAcceptedWorkCodec.capability(readiness:AcceptedWireFixture.json(ready),modelRoute:AcceptedWireFixture.json(f.raw["model_route"]!),subjectID:f.selection.subjectID,serverScopeID:f.selection.serverScopeID)
                try deviceCheck(!cap.available,"Malformed "+key+" cannot authorize")
            }
            var route=f.raw["model_route"] as! [String:Any];route["route_hash"]=textHash("different-route")
            try deviceCheck(try !ConversationAcceptedWorkCodec.capability(readiness:AcceptedWireFixture.json(f.raw["readyz"]!),modelRoute:AcceptedWireFixture.json(route),subjectID:f.selection.subjectID,serverScopeID:f.selection.serverScopeID).available,"Route hash must bind actual model route")
            _=try await deviceReject{_=try ConversationAcceptedWorkSelection(decisionID:UUID(),options:f.selection.options,capability:.init())}
        },
        .init(name:"explicit zero budgets ceilings deadline and public source policy remain bounded") {
            let f=try AcceptedWireFixture.read();try f.selection.validate(capability:f.capability,now:f.clock)
            for field in ["model","source","budget","expired","lifetime","window"] {
                var options=f.selection.options
                switch field {case "model":options.modelLimit=21;case "source":options.sourceLimit=1;case "budget":options.executionBudgetMilliseconds=300001;case "expired":options.notAfter=f.clock;case "lifetime":options.notAfter=f.clock.addingTimeInterval(86401);default:options.notAfter=f.clock.addingTimeInterval(1)}
                _=try await deviceReject{try options.validate(now:f.clock)}
            }
            var zero=f.selection.options;zero.modelLimit=0;try zero.validate(now:f.clock)
            let explicit=try ConversationAcceptedWorkSelection(decisionID:UUID(),options:zero,capability:f.capability);try deviceCheck(explicit.options.modelLimit==0,"No automatic model budget from existing consent")
            var publicOptions=f.selection.options;publicOptions.toolPolicy = .publicSources;publicOptions.sourceLimit=1
            _=try await deviceReject{_=try ConversationAcceptedWorkSelection(decisionID:UUID(),options:publicOptions,capability:f.capability)}
        },
        .init(name:"fresh native freeze only GETs and wrong captured subject causes zero HTTP") {
            let f=try AcceptedWireFixture.read(),host="accepted-freeze-"+UUID().uuidString.lowercased()+".invalid",calls=DeviceEffectCounter(),backend=try f.native(host:host)
            DeviceEffectWireProtocol.register(host){request in
                try deviceCheck(request.httpMethod=="GET","Capability/freeze never creates conversation or model consent")
                calls.increment()
                let value:Any=request.url!.path=="/readyz" ? f.raw["readyz"]! : request.url!.path=="/catpaw/privacy/v1/model-route" ? f.raw["model_route"]! : f.conversation
                return .init(data:try AcceptedWireFixture.json(value))
            }
            do {
                let cap=try await backend.acceptedWorkCapability(scope:Profiles.user,conversationID:f.request.conversationID);try deviceCheck(cap==f.capability,"Strict native readiness uses same configured subject")
                let frozen=try await backend.freezeAcceptedWork(f.provisional,selection:f.selection);try deviceCheck(frozen==f.intent,"Readonly preparation freezes actual original body")
                let foreign=try f.native(host:host,subject:UUID()),before=calls.count()
                _=try await deviceReject{_=try await foreign.freezeAcceptedWork(f.provisional,selection:f.selection)}
                try deviceCheck(calls.count()==before,"Client cannot supply another subject")
                await foreign.close();await backend.close();DeviceEffectWireProtocol.remove(host)
            } catch {await backend.close();DeviceEffectWireProtocol.remove(host);throw error}
        },
        .init(name:"cold original404 is GET only and preserves frozen decision and operation") {
            let f=try AcceptedWireFixture.read(),host="accepted-cold-"+UUID().uuidString.lowercased()+".invalid",posts=DeviceEffectCounter(),reads=DeviceEffectCounter(),backend=try f.native(host:host)
            let expected="/catpaw/accepted-work/v1/scopes/"+f.selection.serverScopeID.uuidString.lowercased()+"/conversations/"+f.request.conversationID.uuidString.lowercased()+"/turns/"+f.request.operationID.uuidString.lowercased()
            DeviceEffectWireProtocol.register(host){request in
                if request.httpMethod != "GET" {posts.increment();throw DeviceEffectTestFailure("Blind original redispatch")};reads.increment()
                if request.url!.path==expected {return .init(status:404,data:Data(#"{"schema_version":1,"error":{"code":"not_found","retryable":false,"reconciliation_required":true}}"#.utf8))}
                return .init(data:try AcceptedWireFixture.json(f.conversation))
            }
            do {
                let restored=try JSONDecoder().decode(ConversationTurnRequest.self,from:JSONEncoder().encode(f.request))
                _=try await deviceReject{_=try await backend.observe(restored)}
                try deviceCheck(posts.count()==0 && reads.count()==2 && restored.acceptedWork==f.intent,"Missing original never remints or POSTs")
                await backend.close();DeviceEffectWireProtocol.remove(host)
            } catch {await backend.close();DeviceEffectWireProtocol.remove(host);throw error}
        },
        .init(name:"changed intent or live conversation snapshot cannot reach first POST") {
            let f=try AcceptedWireFixture.read(),host="accepted-stale-"+UUID().uuidString.lowercased()+".invalid",posts=DeviceEffectCounter(),backend=try f.native(host:host)
            var changed=f.conversation,c=changed["conversation"] as! [String:Any];c["revision"]=2;changed["conversation"]=c
            let changedData=try AcceptedWireFixture.json(changed)
            DeviceEffectWireProtocol.register(host){request in
                if request.httpMethod != "GET" {posts.increment();throw DeviceEffectTestFailure("Stale POST")}
                if request.url!.path=="/readyz" {return .init(data:try AcceptedWireFixture.json(f.raw["readyz"]!))}
                if request.url!.path=="/catpaw/privacy/v1/model-route" {return .init(data:try AcceptedWireFixture.json(f.raw["model_route"]!))}
                return .init(data:changedData)
            }
            do {
                let error=try await deviceReject{_=try await backend.reply(f.request)};try deviceCheck(error is ConversationDispatchFailure && posts.count()==0,"No rehash of a newer server version")
                var turn=(f.raw["accepted_turn"] as! [String:Any])["turn"] as! [String:Any],work=turn["work_intent"] as! [String:Any];work["not_after"]=ConversationAcceptedWorkCodec.utc(f.selection.options.notAfter.addingTimeInterval(1));turn["work_intent"]=work
                _=try await deviceReject{try ConversationAcceptedWorkCodec.validateOriginal(turn,request:f.request)}
                await backend.close();DeviceEffectWireProtocol.remove(host)
            } catch {await backend.close();DeviceEffectWireProtocol.remove(host);throw error}
        },
        .init(name:"actual native first POST preserves wrapper and stream acceptance stays queued") {
            let f=try AcceptedWireFixture.read(),host="accepted-post-"+UUID().uuidString.lowercased()+".invalid",posts=DeviceEffectCounter(),backend=try f.native(host:host)
            let bytes=try f.intent.wrapper(),folder=FileManager.default.temporaryDirectory.appendingPathComponent("catpaw-accepted-turn-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let journal=folder.appendingPathComponent("original-request.json");try JSONEncoder().encode(f.request).write(to:journal,options:.atomic)
            DeviceEffectWireProtocol.register(host){request in
                let path=request.url!.path
                if request.httpMethod=="POST" {
                    posts.increment();try deviceCheck(path.contains("/catpaw/accepted-work/v1/") && path.hasSuffix("/turns"),"Exact new admission endpoint")
                    let restored=try JSONDecoder().decode(ConversationTurnRequest.self,from:Data(contentsOf:journal));try restored.acceptedWork!.validate(request:restored)
                    try deviceCheck(restored.acceptedWork==f.intent,"Original frozen decision/body is on disk before HTTP")
                    try deviceCheck(try ConversationDeviceEffectsCodec.canonicalHashJSON(DeviceEffectWireProtocol.body(request))==ConversationDeviceEffectsCodec.canonicalHashJSON(bytes),"POST original wrapper, no new snapshot/hash/UUID")
                    return .init(data:Data(((f.raw["acceptance_sse"] as! [String:Any])["raw"] as! String).utf8),type:"text/event-stream")
                }
                if path=="/readyz" {return .init(data:try AcceptedWireFixture.json(f.raw["readyz"]!))}
                if path=="/catpaw/privacy/v1/model-route" {return .init(data:try AcceptedWireFixture.json(f.raw["model_route"]!))}
                if path==((f.raw["binding"] as! [String:Any])["projection_url"] as! String) {return .init(data:try AcceptedWireFixture.json(f.raw["accepted_projection"]!))}
                return .init(data:try AcceptedWireFixture.json(f.conversation))
            }
            do {
                var started=false,queued=false,completed=false
                for try await event in try await backend.reply(f.request) {switch event.payload {
                case .started:started=true
                case .toolResult(let result):queued=result.committedGoals.count==1 && result.committedGoals[0].state == .queued
                case .completed:completed=true
                default:break
                }}
                try deviceCheck(started && queued && completed && posts.count()==1,"Durable turn/chat completion cannot declare task completion")
                await backend.close();DeviceEffectWireProtocol.remove(host);try FileManager.default.removeItem(at:folder)
            } catch {await backend.close();DeviceEffectWireProtocol.remove(host);try? FileManager.default.removeItem(at:folder);throw error}
        },
        .init(name:"expired original GET recovers exact terms without readiness or any POST") {
            let f=try AcceptedWireFixture.read(),host="accepted-expired-"+UUID().uuidString.lowercased()+".invalid",posts=DeviceEffectCounter(),ready=DeviceEffectCounter(),backend=try f.native(host:host,clock:f.selection.options.notAfter.addingTimeInterval(86401))
            DeviceEffectWireProtocol.register(host){request in
                let path=request.url!.path
                if request.httpMethod != "GET" {posts.increment();throw DeviceEffectTestFailure("Blind cold POST")}
                if path=="/readyz" {ready.increment();throw DeviceEffectTestFailure("Restore requires old live capability")}
                if path.contains("/catpaw/accepted-work/v1/") {return .init(data:try AcceptedWireFixture.json(f.raw["accepted_turn"]!))}
                if path==((f.raw["binding"] as! [String:Any])["projection_url"] as! String) {return .init(data:try AcceptedWireFixture.json(f.raw["accepted_projection"]!))}
                return .init(data:try AcceptedWireFixture.json(f.conversation))
            }
            do {
                let restored=try JSONDecoder().decode(ConversationTurnRequest.self,from:JSONEncoder().encode(f.request)),observation=try await backend.observe(restored)
                try deviceCheck(posts.count()==0 && ready.count()==0 && observation.request.acceptedWork==f.intent && observation.goals.contains{$0.state == .queued},"Read historical accepted terms; no extension or receipt remint")
                let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/accepted-work-wire-v1.json"),old=try ConversationStrictJSON.object(Data(contentsOf:path),maxBytes:2_000_000)
                _=try await deviceReject{try ConversationAcceptedWorkCodec.validateOriginal((old["accepted_turn"] as! [String:Any])["turn"] as! [String:Any],request:restored)}
                await backend.close();DeviceEffectWireProtocol.remove(host)
            } catch {await backend.close();DeviceEffectWireProtocol.remove(host);throw error}
        }
    ]}
}
#if ACCEPTED_WORK_PORTABLE
@main struct AcceptedWorkPortableRunner {
    static func emit(_ value:String) {FileHandle.standardOutput.write(Data((value+"\n").utf8))}
    static func main() async throws {for test in AcceptedWorkMatrix.cases {do{try await test.run();emit("PASS: "+test.name)}catch{emit("FAIL: "+test.name+": "+String(describing:error));throw error}};emit("LIMIT actual Native URLSession mocked and actual maintained Node wire synthetic; no live Auth/model/SQL/OS/Simulator")}
}
#else
final class ConversationAcceptedWorkTests:XCTestCase {func testExplicitFrozenAcceptedWorkAndNativeRecoveryMatrix() async throws {for test in AcceptedWorkMatrix.cases {do{try await test.run()}catch{XCTFail(test.name+": "+String(describing:error));throw error}}}}
#endif
