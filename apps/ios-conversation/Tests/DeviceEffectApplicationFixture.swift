import Foundation

struct DeviceEffectApplicationFixture {
    let raw:[String:Any]
    let reference:ConversationDeviceEffectReference
    let action:ConversationApprovedDeviceAction
    let createdAt:Date
    static func read() throws -> Self {
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/device-effect-contract-v2.json")
        let raw=try ConversationStrictJSON.object(Data(contentsOf:url),maxBytes:512_000)
        let identity=raw["identity"] as! [String:Any]
        let binding=try JSONDecoder().decode(ConversationTaskBinding.self,from:json(identity["binding"]!))
        let reference=try ConversationDeviceEffectReference(scope:Profiles.user,binding:binding,subjectID:identity["subject"] as! String,actionID:identity["action_id"] as! String,actionDigest:identity["action_digest"] as! String,decisionOperationID:identity["decision_operation_id"] as! String,actionRevision:2)
        let action=try ConversationDeviceEffectsCodec.decodeApprovedAction(frozenData:json(raw["frozen"]!),decisionData:json(raw["decision"]!),reference:reference)
        return .init(raw:raw,reference:reference,action:action,createdAt:ConversationTaskActionValidation.utc(action.frozen.created_at)!)
    }
    static func json(_ value:Any) throws -> Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    func response(_ name:String,original:Bool=false) throws -> Data {
        var value=(raw["responses"] as! [String:Any])[name] as! [String:Any]
        if original {value["dispatch_permit"]=NSNull()}
        return try Self.json(value)
    }
    func record(_ name:String) throws -> ConversationDeviceEffectRecord {try ConversationDeviceEffectsCodec.decodeOriginal(response(name,original:true),reference:reference,action:action).effect}
    func request(_ kind:String) throws -> ConversationDeviceEffectDispatchRequest {try JSONDecoder().decode(ConversationDeviceEffectDispatchRequest.self,from:Self.json((raw["dispatch_requests"] as! [String:Any])[kind]!))}
    func operationIDs(_ roles:[String]) throws -> DeviceEffectIDSource {
        var values:[UUID]=[]
        for role in roles {
            let id:String
            switch role {
            case "admission":id=(raw["admission"] as! [String:Any])["operation_id"] as! String
            case "calendarDispatch":id=try request("calendar").operation_id
            case "calendarResult":id=try record("calendar_succeeded").subeffects.calendar.result_operation_id!
            case "notificationDispatch":id=try request("notification").operation_id
            case "notificationUnknown":id=try record("partial_unknown").subeffects.notification.result_operation_id!
            case "notificationResult":id=try record("succeeded").subeffects.notification.result_operation_id!
            case "stop":id=try record("stopped").stop!.operation_id
            default:throw DeviceEffectTestFailure("Unknown named operation role")
            }
            values.append(UUID(uuidString:id)!)
        }
        return DeviceEffectIDSource(values)
    }
    var readiness:Data {get throws {
        let policy=try ConversationDeviceEffectsCodec.supportedPolicy()
        let p=try JSONSerialization.jsonObject(with:ConversationTaskActionJSON.encoded(policy))
        let effect:[String:Any]=["contract":ConversationDeviceEffectsCodec.effectContract,"action_contract":ConversationDeviceEffectsCodec.actionContract,"read":true,"admit":true,"dispatch":true,"record":true,"stop":true,"registered_device":true,"verified_target":true,"verified_receipts":true,"unknown_resend":false,"policy_reference":p]
        return try Self.json(["ready":true,"chat_capabilities":["device_effects":effect]])
    }}
}
struct DeviceEffectTestFailure:Error,CustomStringConvertible {let description:String;init(_ description:String){self.description=description}}
func deviceCheck(_ value:Bool,_ message:String) throws {if !value {throw DeviceEffectTestFailure(message)}}
func deviceReject(_ body:() async throws -> Void) async throws -> Error {do{try await body()}catch{return error};throw DeviceEffectTestFailure("Expected rejection")}

final class DeviceEffectIDSource:@unchecked Sendable {
    private let lock=NSLock();private var values:[UUID]
    init(_ values:[UUID]){self.values=values}
    func next()->UUID {lock.lock();defer{lock.unlock()};return values.isEmpty ? UUID() : values.removeFirst()}
}
final class DeviceEffectCounter:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    func increment(){lock.lock();value += 1;lock.unlock()}
    func count()->Int {lock.lock();defer{lock.unlock()};return value}
}
final class DeviceEffectMonotonic:@unchecked Sendable {
    private let lock=NSLock();private var value:TimeInterval=0
    func set(_ value:TimeInterval){lock.lock();self.value=value;lock.unlock()}
    func read()->TimeInterval {lock.lock();defer{lock.unlock()};return value}
}
actor DeviceEffectTestGate {
    private var started=false,continuation:CheckedContinuation<Void,Never>?
    func pause() async {started=true;await withCheckedContinuation{continuation=$0}}
    func waitForStart() async throws {for _ in 0..<1000 {if started{return};try await Task.sleep(nanoseconds:1_000_000)};throw DeviceEffectTestFailure("Gate did not begin")}
    func release(){continuation?.resume();continuation=nil}
}
final class DeviceEffectFailingPersistence:SnapshotPersistence,@unchecked Sendable {
    let base:FilePersistence
    private let lock=NSLock();private var failing=false
    init(url:URL){base=FilePersistence(url:url)}
    func setFailure(_ failing:Bool){lock.lock();self.failing=failing;lock.unlock()}
    func load() throws -> StoreSnapshot {try base.load()}
    func save(_ value:StoreSnapshot) throws {lock.lock();let fail=failing;lock.unlock();if fail {throw DeviceEffectTestFailure("Named disk failure")};try base.save(value)}
}
actor DeviceEffectWireCredentials:NativeChatSessionCredentials {
    private var rejectedCount=0
    func authorization(scope:DataScope) async throws -> String {"Bearer named-offline-device-effect"}
    func rejected(scope:DataScope) async {rejectedCount += 1}
    func rejections()->Int {rejectedCount}
}
final class DeviceEffectWireProtocol:URLProtocol,@unchecked Sendable {
    struct Reply:Sendable {var status:Int=200;let data:Data;var type="application/json"}
    typealias Handler=@Sendable(URLRequest) async throws -> Reply
    private static let lock=NSLock()
    private static var handlers:[String:Handler]=[:]
    private var work:Task<Void,Never>?
    static func register(_ host:String,handler:@escaping Handler){lock.lock();handlers[host]=handler;lock.unlock()}
    static func remove(_ host:String){lock.lock();handlers[host]=nil;lock.unlock()}
    private static func handler(_ host:String)->Handler? {lock.lock();defer{lock.unlock()};return handlers[host]}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let wire=request
        work=Task{[weak self] in
            guard let self else {return}
            do {
                guard let handler=Self.handler(wire.url?.host ?? "") else {throw URLError(.unsupportedURL)}
                let value=try await handler(wire);guard !Task.isCancelled else {return}
                self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:wire.url!,statusCode:value.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":value.type])!,cacheStoragePolicy:.notAllowed)
                self.client?.urlProtocol(self,didLoad:value.data);self.client?.urlProtocolDidFinishLoading(self)
            } catch {if !Task.isCancelled {self.client?.urlProtocol(self,didFailWithError:error)}}
        }
    }
    override func stopLoading(){work?.cancel()}
    static func body(_ request:URLRequest) throws -> Data {
        if let data=request.httpBody {return data}
        guard let stream=request.httpBodyStream else {throw DeviceEffectTestFailure("POST body missing")}
        stream.open();defer{stream.close()};var data=Data(),buffer=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<0 {throw stream.streamError ?? URLError(.badServerResponse)};if n==0 {break};data.append(contentsOf:buffer.prefix(n))}
        return data
    }
}
actor DeviceEffectMockServer {
    let fixture:DeviceEffectApplicationFixture
    var current:String?
    var reads=0,posts=0,readinessReads=0
    var lostSuffix:String?
    var gateSuffix:String?,gate:DeviceEffectTestGate?
    var afterPost:(@Sendable()->Void)?
    var postObserver:(@Sendable(Data) throws -> Void)?
    init(_ fixture:DeviceEffectApplicationFixture,current:String?=nil){self.fixture=fixture;self.current=current}
    func configure(lost:String?=nil,gateSuffix:String?=nil,gate:DeviceEffectTestGate?=nil,afterPost:(@Sendable()->Void)?=nil,observer:(@Sendable(Data) throws -> Void)?=nil){lostSuffix=lost;self.gateSuffix=gateSuffix;self.gate=gate;self.afterPost=afterPost;postObserver=observer}
    func setCurrent(_ value:String?){current=value}
    func counters()->(Int,Int,Int){(reads,posts,readinessReads)}
    func handle(_ request:URLRequest) async throws -> DeviceEffectWireProtocol.Reply {
        let path=request.url!.path
        if path=="/readyz" {readinessReads += 1;return .init(data:try fixture.readiness)}
        let expected="/catpaw/device-effects/v1/scopes/"+fixture.reference.binding.scope_id.uuidString.lowercased()+"/runs/"+fixture.reference.binding.run_id.uuidString.lowercased()+"/actions/"+fixture.reference.actionID+"/effects/"+(try fixture.reference.effectID)
        guard path.hasPrefix(expected) else {throw DeviceEffectTestFailure("Native request escaped original effect path")}
        if request.httpMethod=="GET" {reads += 1;if let current {return .init(data:try fixture.response(current,original:true))};return .init(status:404,data:Data(#"{"schema_version":1,"error":{"code":"not_found","retryable":false,"reconciliation_required":false}}"#.utf8))}
        posts += 1
        let body=try DeviceEffectWireProtocol.body(request);try postObserver?(body)
        let data=try ConversationStrictJSON.object(body),suffix=path.split(separator:"/").last.map(String.init) ?? ""
        let reply:String
        switch suffix {
        case "admissions":
            let expected=try DeviceEffectApplicationFixture.json(fixture.raw["admission"]!)
            try deviceCheck(try ConversationDeviceEffectsCodec.canonicalHashJSON(body)==ConversationDeviceEffectsCodec.canonicalHashJSON(expected),"Exact original admission UUID/body");reply="admitted"
        case "dispatches":
            let kind=data["subeffect"] as! String,expected=try fixture.request(kind)
            try deviceCheck(try ConversationDeviceEffectsCodec.canonicalHashJSON(body)==ConversationDeviceEffectsCodec.canonicalHash(expected),"Exact durable dispatch UUID/body")
            reply=kind+"_permit"
        case "results":
            let kind=data["subeffect"] as! String,outcome=data["outcome"] as! String
            reply=kind=="calendar" ? "calendar_succeeded" : outcome=="unknown" ? "partial_unknown" : "succeeded"
        case "stop":reply="stopped"
        default:throw DeviceEffectTestFailure("Unexpected write route")
        }
        current=reply;afterPost?()
        if suffix==gateSuffix,let gate {await gate.pause()}
        if suffix==lostSuffix {throw URLError(.networkConnectionLost)}
        return .init(data:try fixture.response(reply))
    }
}
struct DeviceEffectDiskFixture {
    let directory:URL,url:URL,repository:Repository,source:DeviceEffectApplicationFixture,backend:NativeChatHTTPBackend,credentials:DeviceEffectWireCredentials,server:DeviceEffectMockServer,host:String
    static func make(_ roles:[String],persistence:DeviceEffectFailingPersistence?=nil,current:String?=nil) async throws -> (Self,ConversationDeviceEffectService) {
        let source=try DeviceEffectApplicationFixture.read()
        let directory=persistence?.base.url.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory.appendingPathComponent("catpaw-device-service-"+UUID().uuidString)
        let url=persistence?.base.url ?? directory.appendingPathComponent("local.json")
        let repository=try Repository(persistence:persistence.map{$0 as any SnapshotPersistence} ?? FilePersistence(url:url))
        let session=ConversationSessionService(repository:repository)
        _=try await session.create(scope:Profiles.user,id:source.reference.binding.conversation_id)
        let host="device-effect-"+UUID().uuidString.lowercased()+".invalid",server=DeviceEffectMockServer(source,current:current),credentials=DeviceEffectWireCredentials()
        DeviceEffectWireProtocol.register(host){request in try await server.handle(request)}
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[DeviceEffectWireProtocol.self]
        let native=NativeChatHTTPBackend(configuration:try .init(origin:URL(string:"https://"+host)!,localScope:Profiles.user,serverScopeID:source.reference.binding.scope_id,expectedSubjectID:UUID(uuidString:source.reference.subjectID)!),credentials:credentials,sessionConfiguration:config)
        let ids=try source.operationIDs(roles),clock=source.createdAt
        let service=ConversationDeviceEffectService(repository:repository,subjectID:UUID(uuidString:source.reference.subjectID),backend:native,clock:{clock},operationID:{ids.next()})
        await service.setAdmissionAllowed(true)
        return (Self(directory:directory,url:url,repository:repository,source:source,backend:native,credentials:credentials,server:server,host:host),service)
    }
    func reopened() throws -> ConversationDeviceEffectService {let repository=try Repository(persistence:FilePersistence(url:url)),clock=source.createdAt;return ConversationDeviceEffectService(repository:repository,subjectID:UUID(uuidString:source.reference.subjectID),backend:backend,clock:{clock})}
    func journal() async throws -> StoredRecord {
        let snapshot=await repository.read(scope:Profiles.user)
        guard let record=snapshot.records.values.first(where:{if case .preference(let p)=$0.payload {return p.key.hasPrefix("conversation_device_effects:")};return false}) else {throw DeviceEffectTestFailure("Durable device journal missing")}
        return record
    }
    func close() async {await backend.close();DeviceEffectWireProtocol.remove(host);try? FileManager.default.removeItem(at:directory)}
}
