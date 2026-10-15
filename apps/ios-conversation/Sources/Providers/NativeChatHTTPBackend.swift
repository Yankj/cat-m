import Foundation
import CoreFoundation

public struct NativeChatConfiguration: Sendable {
    public let origin: URL
    public let localScope: DataScope
    public let serverScopeID: UUID
    public let expectedSubjectID: UUID?
    public let allowInjectedTestProvider: Bool
    public let useFrozenFixtureMetadata: Bool
    public let fixtureExpectedReality: String
    public let publishableKey: String?
    public let edgeRegion: String?
    public init(origin: URL, localScope: DataScope, serverScopeID: UUID, allowInjectedTestProvider: Bool = false, useFrozenFixtureMetadata: Bool = false, fixtureExpectedReality: String = "injected_synthetic_fixture", publishableKey: String? = nil, edgeRegion: String? = nil, expectedSubjectID: UUID? = nil) throws {
        try NativeAPIBase.validate(origin,allowLoopback:true)
        let c = URLComponents(url:origin,resolvingAgainstBaseURL:false)!
        guard publishableKey == nil || publishableKey?.range(of:"^sb_publishable_[A-Za-z0-9_-]{10,2000}$",options:.regularExpression) != nil else { throw NativeAuthError.invalidConfiguration }
        guard !useFrozenFixtureMetadata || (allowInjectedTestProvider && c.scheme == "http" && c.host == "127.0.0.1") else { throw CatpawError.invalid("冻结 fixture metadata 仅允许明确 loopback 测试。") }
        guard ["injected_synthetic_fixture","provider_unverified"].contains(fixtureExpectedReality) else { throw ConversationSessionError.invalidEvent }
        if let edgeRegion { guard edgeRegion.utf8.count <= 40,edgeRegion.range(of:"^[a-z]{2}(?:-[a-z]+){1,3}-[0-9]+$",options:.regularExpression) != nil else { throw NativeAuthError.invalidConfiguration } }
        // Pin only this application's confirmed Edge API. Auth and other origins
        // retain default routing. Explicit region routing has no automatic failover.
        let currentEdge = c.scheme == "https" && (c.port == nil || c.port == 443) && c.host?.lowercased() == "dbyklgxdvjbutxzsjeth.supabase.co" && ["/functions/v1/catpaw-api","/functions/v1/catpaw-api/"].contains(c.path)
        self.edgeRegion = currentEdge ? (edgeRegion ?? "us-east-1") : nil
        self.expectedSubjectID=expectedSubjectID; self.origin = origin; self.localScope = localScope; self.serverScopeID = serverScopeID; self.allowInjectedTestProvider = allowInjectedTestProvider; self.useFrozenFixtureMetadata = useFrozenFixtureMetadata; self.fixtureExpectedReality = fixtureExpectedReality; self.publishableKey = publishableKey
    }
    public func makeRequest(route: String, authorization: String) throws -> URLRequest {
        guard authorization.hasPrefix("Bearer "),authorization.count > 7,authorization.utf8.count < 8192,!authorization.utf8.contains(13),!authorization.utf8.contains(10) else { throw ConversationSessionError.notConfigured }
        var request = URLRequest(url:try NativeAPIBase.endpoint(base:origin,route:route));request.timeoutInterval = 60
        request.setValue(authorization,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("text/event-stream, application/json",forHTTPHeaderField:"Accept")
        if let publishableKey { request.setValue(publishableKey,forHTTPHeaderField:"apikey") }
        if let edgeRegion { request.setValue(edgeRegion,forHTTPHeaderField:"x-region") };return request
    }
}
/// An authenticated application session, never an OpenRouter key or client-chosen identity.
public protocol NativeChatSessionCredentials: Sendable { func authorization(scope: DataScope) async throws -> String; func rejected(scope: DataScope) async }
public extension NativeChatSessionCredentials { func rejected(scope: DataScope) async { } }
public struct MissingNativeChatSession: NativeChatSessionCredentials {
    public init() {}
    public func authorization(scope: DataScope) async throws -> String { throw ConversationSessionError.notConfigured }
}
public actor NativeChatHTTPBackend: ConversationBackend {
    private let configuration: NativeChatConfiguration
    private let credentials: any NativeChatSessionCredentials
    private let session: URLSession
    private let acceptedWorkClock:@Sendable()->Date
    private var bindingCache: [UUID: [String: ConversationTaskBinding]] = [:]
    private var toolTitles: [UUID: [String: String]] = [:]
    private var continuationReceipts:[UUID:[String:ConversationTaskRevisionReceipt]]=[:]
    private var continuationSourceHashes:[UUID:String]=[:]
    public nonisolated var supportsArtifactContinuations:Bool {configuration.expectedSubjectID != nil}
    public nonisolated var artifactContinuationSubjectID:UUID? {configuration.expectedSubjectID}
    private var observedModelState: ConversationConnection.State?
    private var verifiedReplyAt:Date?
    private var verifiedModel:String?
    private struct ReplyCandidate {let model:String?}
    private var replyCandidates:[UUID:ReplyCandidate]=[:]
    public init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials = MissingNativeChatSession(),sessionConfiguration:URLSessionConfiguration?=nil,acceptedWorkClock:@escaping @Sendable()->Date={Date()}) {
        self.configuration = configuration; self.credentials = credentials
        self.acceptedWorkClock=acceptedWorkClock
        let policy = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral; policy.urlCache = nil; policy.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: policy, delegate: NativeChatNoRedirect(), delegateQueue: nil)
    }
    public func close() { session.invalidateAndCancel(); bindingCache.removeAll(); toolTitles.removeAll(); continuationReceipts.removeAll();continuationSourceHashes.removeAll(); observedModelState = nil;verifiedReplyAt=nil;verifiedModel=nil;replyCandidates.removeAll() }
    public func connection(scope: DataScope) async -> ConversationConnection {
        let auth: String
        do { auth = try await authorization(scope) }
        catch { return ConversationConnection(state: .notConfigured, provider: "OpenRouter", detail: "缺少有效后台登录会话；模型 key 由服务端管理。") }
        do {
            if configuration.useFrozenFixtureMetadata {
                let metadata = try await json("/catpaw/testing/v1/fixture", auth: auth)
                guard metadata["authentication"] as? String == "explicit_test_fixture_session", metadata["model_reality"] as? String == configuration.fixtureExpectedReality, metadata["real_supabase_login_verified"] as? Bool == false else { throw ConversationSessionError.invalidEvent }
                let live = configuration.fixtureExpectedReality == "provider_unverified"
                return ConversationConnection(state: .providerUnverified, provider: live ? "OpenRouter free synthetic" : "scripted_ios_fixture", detail: live ? "明确的合成测试身份；免费真实模型链路待验，正式登录未验。" : "明确的合成测试身份；无真实 Auth 或模型调用。")
            }
            let readiness = try await json("/readyz", auth: auth,timeout:6)
            guard readiness["ready"] as? Bool == true else { return ConversationConnection(state: .unavailable, provider: "OpenRouter", detail: "后台有界执行入口尚未准备好，未发送模型请求。") }
            if let evidence=await recordedReplyEvidence(scope:scope) {return evidence}
            return ConversationConnection(state: .providerUnverified, provider: "OpenRouter", detail: "服务与登录状态可用；确认处理方式后即可发送消息。")
        } catch { return ConversationConnection(state: .unavailable, provider: "OpenRouter", detail: Self.friendlyTransportMessage(error) + "原请求与输入保留。") }
    }
    public func recordCommittedReply(_ request:ConversationTurnRequest) async {
        guard request.scope==configuration.localScope,!configuration.useFrozenFixtureMetadata,!configuration.allowInjectedTestProvider,
              let candidate=replyCandidates.removeValue(forKey:request.operationID) else{return}
        verifiedReplyAt=Date();verifiedModel=candidate.model;observedModelState = .connected
    }
    public func recordedReplyEvidence(scope:DataScope) async -> ConversationConnection? {
        guard scope==configuration.localScope,let at=verifiedReplyAt else{return nil}
        return .init(state:.connected,provider:"OpenRouter",model:verifiedModel,detail:"已收到并保存完整回复。",verifiedReplyAt:at)
    }
    public func imageCapabilities(scope:DataScope,conversationID:UUID) async throws -> ConversationImageCapability {
        let auth=try await authorization(scope),ready=try await json("/readyz",auth:auth)
        let advertised=try ConversationImageReadiness.decode(Self.jsonData(ready))
        guard advertised.available else {return .init(state:advertised.state)}
        let route=try await json("/catpaw/privacy/v1/image-model-route",auth:auth)
        guard route["live_transmission_available"] as? Bool == true,let hash=route["route_hash"] as? String,hash.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else {return .init(state:"route_unavailable")}
        return .init(available:true,liveTransmissionAvailable:true,routeHash:hash,state:"requires_image_consent",detail:"Image route available; separate image consent required")
    }
    private func imageConsentPath(_ id:UUID)->String {"/catpaw/privacy/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+id.uuidString.lowercased()+"/image-model-consent"}
    public func imageConsent(scope:DataScope,conversationID:UUID,previewID:UUID,previewHash:String) async throws -> ConversationImageConsent {
        guard configuration.publishableKey != nil,ConversationImageReceipt.isSHA(previewHash) else {throw ConversationSessionError.notConfigured}
        let capability=try await imageCapabilities(scope:scope,conversationID:conversationID)
        guard capability.available,capability.liveTransmissionAvailable,let routeHash=capability.routeHash else {throw ConversationSessionError.notConfigured}
        let auth=try await authorization(scope),metadata=try await json("/catpaw/privacy/v1/image-model-route",auth:auth)
        try Self.validateImageRoute(metadata,hash:routeHash)
        let ui=try Self.object(metadata["ui"]),stored=try await json(imageConsentPath(conversationID),auth:auth)
        let revision:Int
        if let raw=stored["consent"],!(raw is NSNull) {let row=try Self.imageConsentRow(raw);guard row.scope_id==configuration.serverScopeID,row.conversation_id==conversationID else {throw ConversationSessionError.invalidEvent};revision=row.revision} else {revision=0}
        func label(_ key:String,max:Int=512) throws -> String {guard let v=ui[key] as? String,!v.isEmpty,v.utf8.count<=max else {throw ConversationSessionError.invalidEvent};return v}
        return try .init(conversationID:conversationID,previewID:previewID,previewHash:previewHash,routeHash:routeHash,expectedRevision:revision,title:label("title"),body:label("body",max:12000),confirmation:label("content_confirmation"),allowLabel:label("allow"),denyLabel:label("deny"))
    }
    public func allowImageConsent(scope:DataScope,consent:ConversationImageConsent,nonSensitiveConfirmed:Bool) async throws -> Int {
        guard nonSensitiveConfirmed,ConversationImageReceipt.isSHA(consent.previewHash),consent.expectedRevision>=0 else {throw ConversationSessionError.invalidEvent}
        let auth=try await authorization(scope),metadata=try await json("/catpaw/privacy/v1/image-model-route",auth:auth)
        try Self.validateImageRoute(metadata,hash:consent.routeHash)
        let response=try await json(imageConsentPath(consent.conversationID),auth:auth,body:["decision":"allow","expected_revision":consent.expectedRevision,"route_hash":consent.routeHash,"non_sensitive_confirmed":true])
        let row=try Self.imageConsentRow(response["consent"])
        guard row.scope_id==configuration.serverScopeID,row.conversation_id==consent.conversationID,row.decision=="allow",row.non_sensitive_confirmed,row.route_hash==consent.routeHash,row.revision==consent.expectedRevision+1 else {throw ConversationSessionError.invalidEvent}
        return row.revision
    }
    private static func imageConsentRow(_ raw:Any?) throws -> NativeImageConsentRow {
        let row=try JSONDecoder().decode(NativeImageConsentRow.self,from:jsonData(object(raw)))
        guard ["allow","deny"].contains(row.decision),row.revision>=0,ConversationImageReceipt.isSHA(row.route_hash) else {throw ConversationSessionError.invalidEvent};return row
    }
    private static func validateImageRoute(_ metadata:[String:Any],hash:String) throws {
        guard metadata["route_hash"] as? String==hash,metadata["consent_default"] as? String=="deny",metadata["live_transmission_available"] as? Bool==true,metadata["non_sensitive_confirmation_required"] as? Bool==true else {throw ConversationSessionError.notConfigured}
        let route=try JSONDecoder().decode(NativeFixedVisionRoute.self,from:jsonData(object(metadata["route"])))
        guard route.matchesSupportedNotice else {throw ConversationSessionError.invalidEvent}
    }
    private static func validateImageSnapshot(_ turn:[String:Any],request:ConversationTurnRequest) throws {
        if let image=request.image {
            guard let raw=turn["image_attachments"] else {throw ConversationSessionError.invalidEvent}
            let receipts=try JSONDecoder().decode([ConversationImageReceipt].self,from:jsonData(raw))
            guard receipts==[image.receipt] else {throw ConversationSessionError.invalidEvent}
        }
    }
    public func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? {
        guard configuration.publishableKey != nil else { return nil }
        let auth = try await authorization(scope),base = scopePath+"/conversations/"+conversationID.uuidString.lowercased()
        do { _ = try await json(base,auth:auth) } catch NativeChatHTTPFailure.status(404) { _ = try await json(scopePath+"/conversations",auth:auth,body:["conversation_id":conversationID.uuidString.lowercased()]) }
        let metadata = try await json("/catpaw/privacy/v1/model-route",auth:auth),ui = try Self.object(metadata["ui"]),routeHash = try Self.sha(metadata["route_hash"])
        let path = "/catpaw/privacy/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+conversationID.uuidString.lowercased()+"/model-consent"
        let stored = try await json(path,auth:auth);let prior = stored["consent"] as? [String:Any]
        if prior?["decision"] as? String == "allow",prior?["route_hash"] as? String == routeHash { return nil }
        guard let title = ui["title"] as? String,let body = ui["body"] as? String,title.utf8.count <= 512,body.utf8.count <= 12000 else { throw ConversationSessionError.invalidEvent }
        let revision = prior?["revision"] as? Int ?? 0;guard revision >= 0 else { throw ConversationSessionError.invalidEvent }
        return .init(conversationID:conversationID,title:title,body:body,routeHash:routeHash,expectedRevision:revision)
    }
    public func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws {
        let auth = try await authorization(scope),path = "/catpaw/privacy/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+consent.conversationID.uuidString.lowercased()+"/model-consent"
        let reply = try await json(path,auth:auth,body:["decision":"allow","expected_revision":consent.expectedRevision,"route_hash":consent.routeHash]),row = try Self.object(reply["consent"])
        guard row["decision"] as? String == "allow",row["route_hash"] as? String == consent.routeHash,row["revision"] as? Int == consent.expectedRevision+1 else { throw ConversationSessionError.invalidEvent }
    }
    public func acceptedWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {
        guard scope==configuration.localScope else {throw CatpawError.scopeMismatch}
        guard let subject=configuration.expectedSubjectID else {return .init()}
        try Task.checkCancellation();let auth=try await authorization(scope);try Task.checkCancellation()
        let ready=try await json("/readyz",auth:auth,strict:true);try Task.checkCancellation()
        guard Self.boolean(ready["ready"])==true,let caps=ready["chat_capabilities"] as? [String:Any],let work=caps["accepted_work"] as? [String:Any],Self.boolean(work["enabled"])==true else {return .init()}
        let route=try await json("/catpaw/privacy/v1/model-route",auth:auth,strict:true);try Task.checkCancellation()
        return try ConversationAcceptedWorkCodec.capability(readiness:Self.jsonData(ready),modelRoute:Self.jsonData(route),subjectID:subject,serverScopeID:configuration.serverScopeID)
    }
    public func ensureConversationForExplicitSend(_ request:ConversationTurnRequest) async throws {
        guard request.acceptedWork==nil,configuration.expectedSubjectID != nil else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        _=try ConversationAcceptedWorkCodec.turn(request,revision:1,grant:1)
        try Task.checkCancellation();let auth=try await authorization(request.scope);try Task.checkCancellation()
        _=try await readConversation(request,auth:auth,mayCreate:true,strict:true);try Task.checkCancellation()
    }
    public func freezeAcceptedWork(_ request:ConversationTurnRequest,selection:ConversationAcceptedWorkSelection) async throws -> ConversationAcceptedWorkIntent {
        do {
            guard request.acceptedWork==nil,request.scope==configuration.localScope,selection.serverScopeID==configuration.serverScopeID,selection.subjectID==configuration.expectedSubjectID else {throw ConversationAcceptedWorkError.invalidSelection}
            _=try ConversationAcceptedWorkCodec.turn(request,revision:1,grant:1)
            let capability=try await acceptedWorkCapability(scope:request.scope,conversationID:request.conversationID);try Task.checkCancellation()
            try selection.validate(capability:capability,now:acceptedWorkClock())
            let auth=try await authorization(request.scope);try Task.checkCancellation()
            let conversation=try await readConversation(request,auth:auth,mayCreate:false,strict:true);try Task.checkCancellation()
            try validateHistory(conversation,request:request)
            let result=try ConversationAcceptedWorkIntent(request:request,selection:selection,expectedRevision:Self.positive(conversation["revision"]),expectedGrantEpoch:Self.positive(conversation["grant_epoch"]))
            try result.validate(request:request);try selection.options.validate(now:acceptedWorkClock());return result
        } catch {throw ConversationDispatchFailure.notSent(reason:Self.friendlyTransportMessage(error))}
    }
    private func acceptedWorkContext(_ request:ConversationTurnRequest) throws {
        guard let intent=request.acceptedWork,request.scope==configuration.localScope,intent.selection.serverScopeID==configuration.serverScopeID,intent.selection.subjectID==configuration.expectedSubjectID else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        try intent.validate(request:request)
    }
    private func validateHistory(_ conversation:[String:Any],request:ConversationTurnRequest) throws {
        let remote=try Self.array(conversation["messages"]),previous=request.history.dropLast().filter{$0.role == .user || ($0.role == .assistant && $0.toolName==nil && $0.complete)}
        guard remote.count==previous.count else {throw CatpawError.conflict}
        for (wire,local) in zip(remote,previous) {
            guard UUID(uuidString:wire["id"] as? String ?? "")==local.id,wire["role"] as? String==local.role.rawValue,let content=wire["content"] as? String,content.utf16.elementsEqual(local.content.utf16) else {throw CatpawError.conflict}
        }
    }
    public func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let auth: String, grant: Int, upload: URLRequest
        do { (auth, grant, upload) = try await prepare(request) }
        catch { throw ConversationDispatchFailure.notSent(reason: Self.friendlyTransportMessage(error)) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var postInitiated = false
                do {
                    try Task.checkCancellation()
                    postInitiated = true // From here a transport error cannot prove non-admission.
                    let (bytes, response) = try await self.session.bytes(for: upload)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let status=(response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 { await self.credentials.rejected(scope: request.scope) }
                        if request.continuation != nil,(response as? HTTPURLResponse)?.mimeType == "application/json",[403,409,413,422].contains(status) {
                            var errorData=Data();for try await byte in bytes {guard errorData.count<65536 else {throw ConversationSessionError.invalidEvent};errorData.append(byte)}
                            if let envelope=try? ConversationStrictJSON.object(errorData,maxBytes:65536),(try? Self.positive(envelope["schema_version"]))==1,let problem=envelope["error"] as? [String:Any],
                               Self.boolean(problem["reconciliation_required"])==false,Self.boolean(problem["retryable"])==false,let code=problem["code"] as? String,
                               Self.continuationDenials.contains(code) {throw ConversationDispatchFailure.notSent(reason:code)}
                        }
                        throw NativeChatHTTPFailure.turnResponse(status)
                    }
                    if http.mimeType == "application/json" {
                        var data = Data(); for try await b in bytes { guard data.count < 2_000_000 else { throw ConversationSessionError.invalidEvent }; data.append(b) }
                        let snapshot = request.continuation == nil && request.acceptedWork==nil ? try Self.object(JSONSerialization.jsonObject(with: data)) : try ConversationStrictJSON.object(data,maxBytes:2_000_000); try Self.turnEnvelope(snapshot,request:request)
                        let turn = try Self.object(snapshot["turn"]);try Self.validateImageSnapshot(turn,request:request);try Self.validateContinuationSnapshot(turn,request:request,scope:self.configuration.serverScopeID,grant:grant)
                        try ConversationAcceptedWorkCodec.validateOriginal(turn,request:request)
                        for event in try Self.array(turn["events"]) { continuation.yield(try await self.decode(event, request: request, grant: grant, auth: auth)) }
                    } else {
                        guard http.mimeType == "text/event-stream" else { throw ConversationSessionError.invalidEvent }
                        // SSE framing uses ASCII CR/LF. AsyncBytes.lines also splits
                        // Unicode NEL in valid JSON text, losing the original event bytes.
                        var line=Data(),afterCR=false
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if afterCR {afterCR=false;if byte==0x0a {continue}}
                            if byte==0x0a || byte==0x0d {
                                if let wire=try Self.sseEventLine(line,strict:request.continuation != nil || request.acceptedWork != nil) {continuation.yield(try await self.decode(wire, request:request, grant:grant, auth:auth))}
                                line.removeAll(keepingCapacity:true);afterCR=byte==0x0d
                            } else {
                                guard line.count<262144 else {throw ConversationSessionError.invalidEvent};line.append(byte)
                            }
                        }
                        guard line.isEmpty else {throw ConversationSessionError.invalidEvent}
                    }
                    continuation.finish() // EOF is never synthesized into completion.
                } catch {
                    let failure: Error = error is URLError
                        ? CatpawError.unavailable(Self.friendlyTransportMessage(error) + (postInitiated ? "本轮发送结果尚未确认；请读取原请求状态，不要重新发送。" : ""))
                        : error
                    continuation.finish(throwing: postInitiated ? failure : ConversationDispatchFailure.notSent(reason: failure.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() } // detaches observation only
        }
    }
    private static func sseEventLine(_ line:Data,strict:Bool=false) throws -> [String:Any]? {
        if line.isEmpty || line.first==0x3a {return nil}
        guard line.starts(with:[0x64,0x61,0x74,0x61,0x3a,0x20]) else {throw ConversationSessionError.invalidEvent}
        return strict ? try ConversationStrictJSON.object(Data(line.dropFirst(6)),maxBytes:262144) : try object(JSONSerialization.jsonObject(with:Data(line.dropFirst(6))))
    }
    private static func friendlyTransportMessage(_ error: Error) -> String {
        guard let network = error as? URLError else { return error.localizedDescription }
        switch network.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "网络连接已中断。请检查网络后再读取进展。"
        case .timedOut:
            return "连接超时。请稍后读取进展。"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "暂时无法连接服务。请检查网络后再试。"
        default: return "网络请求未完成。请检查连接后再读取进展。"
        }
    }
    private func prepare(_ request: ConversationTurnRequest) async throws -> (String, Int, URLRequest) {
        try Task.checkCancellation()
        let auth = try await authorization(request.scope)
        try Task.checkCancellation()
        if let intent=request.acceptedWork {
            try acceptedWorkContext(request)
            let capability=try await acceptedWorkCapability(scope:request.scope,conversationID:request.conversationID);try Task.checkCancellation()
            try intent.selection.validate(capability:capability,now:acceptedWorkClock())
        }
        if request.continuation != nil {
            try continuationContext(request)
            guard try await continuationAvailability(request,auth:auth) else {throw ConversationArtifactContinuationError.unsupported}
            _=try await confirmedContinuationBinding(request,auth:auth)
            continuationSourceHashes[request.operationID]=try await continuationBase(request,inspectCurrent:true)
        }
        let conversation = try await readConversation(request, auth: auth, mayCreate: request.continuation == nil && request.acceptedWork==nil,strict:request.acceptedWork != nil)
        try Task.checkCancellation()
        let revision = try Self.positive(conversation["revision"]), grant = try Self.positive(conversation["grant_epoch"])
        if let intent=request.acceptedWork {guard revision==intent.expectedRevision,grant==intent.expectedGrantEpoch else {throw ConversationAcceptedWorkError.changedSnapshot};try validateHistory(conversation,request:request)}
        let remote = try Self.array(conversation["messages"])
        let previous = request.history.dropLast().filter { $0.role == .user || ($0.role == .assistant && $0.toolName == nil && $0.complete) }
        guard remote.count == previous.count else { throw CatpawError.conflict }
        for (wire, local) in zip(remote, previous) {
            guard UUID(uuidString: wire["id"] as? String ?? "") == local.id, wire["role"] as? String == local.role.rawValue, wire["content"] as? String == local.content else { throw CatpawError.conflict }
        }
        if let intent=request.acceptedWork {
            try intent.selection.options.validate(now:acceptedWorkClock())
            var upload=try self.request(turnPath(request),auth:auth);upload.httpMethod="POST";upload.httpBody=try intent.wrapper()
            try Task.checkCancellation();return (auth,grant,upload)
        }
        guard let message = request.history.last, message.role == .user else { throw ConversationSessionError.invalidEvent }
        var body: [String: Any] = ["turn_id": request.operationID.uuidString.lowercased(), "expected_revision": revision, "expected_grant_epoch": grant,
                                 "message": ["id": message.id.uuidString.lowercased(), "text": message.content], "context": request.context.map { ["id": $0.id, "text": $0.text] }]
        guard try Self.jsonData(body).count <= 40000 else {throw CatpawError.invalid("本轮上下文超过后台请求上限。")}
        if let image=request.image {
            guard configuration.publishableKey != nil,let imageBytes=request.imageBytes else {throw ConversationSessionError.notConfigured}
            let capability=try await imageCapabilities(scope:request.scope,conversationID:request.conversationID)
            guard capability.available,capability.liveTransmissionAvailable,capability.routeHash==image.routeHash else {throw ConversationSessionError.notConfigured}
            guard try await modelConsent(scope:request.scope,conversationID:request.conversationID)==nil else {throw ConversationSessionError.notConfigured}
            let row=try Self.imageConsentRow(try await json(imageConsentPath(request.conversationID),auth:auth)["consent"])
            guard row.scope_id==configuration.serverScopeID,row.conversation_id==request.conversationID,row.decision=="allow",row.non_sensitive_confirmed,row.route_hash==image.routeHash,row.revision==image.consentRevision else {throw ConversationSessionError.notConfigured}
            body["schema_version"]=2;body["message"]=["id":message.id.uuidString.lowercased(),"text":message.content,"attachments":[try image.wire(imageBytes,messageID:message.id)]]
        } else {guard request.imageBytes==nil else {throw ConversationSessionError.invalidEvent}}
        let bytes=try Self.jsonData(body);guard bytes.count <= (request.image==nil ? 40000 : 7_100_000) else {throw CatpawError.invalid("本轮上下文超过后台请求上限。")}

        let encoded:Data
        if let target=request.continuation {guard request.image==nil,request.imageBytes==nil else {throw ConversationSessionError.invalidEvent};encoded=try Self.jsonData(["turn":body,"target":target.canonicalValue]);guard encoded.count<=48000 else {throw ConversationSessionError.invalidEvent}}
        else {encoded=bytes}
        var upload = try self.request(turnPath(request), auth: auth); upload.httpMethod = "POST"; upload.httpBody = encoded
        if request.image==nil,request.continuation==nil,request.acceptedWork==nil {upload.setValue(ConversationMemoryProposalReceipt.contractName,forHTTPHeaderField:"X-Catpaw-Memory-Proposal-Contract")}
        try Task.checkCancellation()
        return (auth, grant, upload)
    }
    public func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        if request.acceptedWork != nil {try acceptedWorkContext(request)}
        let auth = try await authorization(request.scope)
        try Task.checkCancellation()
        let conversation = try await readConversation(request, auth: auth, mayCreate: false,strict:request.acceptedWork != nil)
        try Task.checkCancellation()
        let currentGrant = try Self.positive(conversation["grant_epoch"])
        if request.continuation != nil {try continuationContext(request);_=try await confirmedContinuationBinding(request,auth:auth);continuationSourceHashes[request.operationID]=try await continuationBase(request,inspectCurrent:false)}
        let wrapper = try await json(turnPath(request) + "/" + request.operationID.uuidString.lowercased(), auth: auth)
        try Self.turnEnvelope(wrapper,request:request)
        let turn = try Self.object(wrapper["turn"]);try Self.validateImageSnapshot(turn,request:request);try Self.validateContinuationSnapshot(turn,request:request,scope:configuration.serverScopeID,grant:currentGrant)
        try ConversationAcceptedWorkCodec.validateOriginal(turn,request:request)
        guard UUID(uuidString: turn["id"] as? String ?? "") == request.operationID,
              UUID(uuidString: turn["conversation_id"] as? String ?? "") == request.conversationID,
              UUID(uuidString: turn["scope_id"] as? String ?? "") == configuration.serverScopeID,
              try Self.positive(turn["grant_epoch"]) == currentGrant else { throw ConversationSessionError.invalidEvent }
        var events: [ConversationTurnEvent] = [], goals: [ConversationGoalProjection] = []
        for wire in try Self.array(turn["events"]) {
            let event = try await decode(wire, request: request, grant: currentGrant, auth: auth); events.append(event)
            if case .toolResult(let result) = event.payload { goals += result.committedGoals }
        }
        // Read original bindings before their projection; never create a task to recover it.
        var bindings = Array(bindingCache[request.operationID, default: [:]].values)
        for message in request.history where message.role == .tool && ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains(message.toolName ?? "") {
            if let data = message.content.data(using: .utf8), let candidate = try? JSONSerialization.jsonObject(with: data), let binding = try? binding(candidate, request: request, currentTurn: false) {
                let original = try await json(path(request) + "/turns/" + binding.turn_id.uuidString.lowercased(), auth: auth)
                try Self.chatEnvelope(original); let prior = try Self.object(original["turn"])
                let confirmed = try Self.array(prior["task_bindings"]).compactMap { try? self.binding($0, request: request, currentTurn: false) }
                guard confirmed.contains(binding) else { throw ConversationSessionError.invalidEvent }
                bindings.append(binding)
            }
        }
        if let original=request.continuationOriginalBinding,request.continuation != nil {bindings.append(original)}
        var seen: Set<String> = []
        for b in bindings where seen.insert(b.task_id).inserted { goals.append(try await projection(b, title: title(b.call_id, turnID: b.turn_id, history: request.history), request: request, auth: auth)) }
        if request.continuation != nil {try validateContinuationList(turn["continuations"],request:request,terminal:turn["state"] as? String=="completed")}
        return ConversationObservation(request: request, events: events, requestHash: try Self.sha(turn["request_hash"]), grantEpoch: currentGrant, goals: goals)
    }
    private func readConversation(_ value: ConversationTurnRequest, auth: String, mayCreate: Bool,strict:Bool=false) async throws -> [String: Any] {
        var wrapper: [String: Any]
        do { wrapper = try await json(path(value), auth: auth,strict:strict) }
        catch NativeChatHTTPFailure.status(404) where mayCreate {
            if strict {try Task.checkCancellation()}
            wrapper = try await json(scopePath + "/conversations", auth: auth, body: ["conversation_id": value.conversationID.uuidString.lowercased()],strict:strict)
        }
        try Self.chatEnvelope(wrapper); let c = try Self.object(wrapper["conversation"])
        if strict {guard c["subject_id"] as? String==configuration.expectedSubjectID?.uuidString.lowercased() else {throw ConversationSessionError.invalidEvent}}
        guard UUID(uuidString: c["id"] as? String ?? "") == value.conversationID, UUID(uuidString: c["scope_id"] as? String ?? "") == configuration.serverScopeID,
              c["state"] as? String == "active", c["policy"] as? String == "conversation-local-output-v1" else { throw ConversationSessionError.invalidEvent }
        return c
    }
    private func decode(_ wire: [String: Any], request: ConversationTurnRequest, grant: Int, auth: String) async throws -> ConversationTurnEvent {
        try Self.chatEnvelope(wire)
        let sequence = try Self.positive(wire["sequence"])
        guard UUID(uuidString: wire["scope_id"] as? String ?? "") == configuration.serverScopeID,
              UUID(uuidString: wire["conversation_id"] as? String ?? "") == request.conversationID,
              UUID(uuidString: wire["turn_id"] as? String ?? "") == request.operationID,
              try Self.positive(wire["grant_epoch"]) == grant,
              wire["cursor"] as? String == request.operationID.uuidString.lowercased() + ":\(sequence)" else { throw ConversationSessionError.invalidEvent }
        let reality = wire["model_reality"] as? String
        guard reality == "provider_unverified" || reality == "not_configured" || (configuration.allowInjectedTestProvider && reality == "injected_test_provider") || (configuration.useFrozenFixtureMetadata && reality == "injected_synthetic_fixture") else { throw ConversationSessionError.invalidEvent }
        observedModelState = reality == "not_configured" ? .notConfigured : .providerUnverified
        let data = try Self.object(wire["data"]), type = wire["type"] as? String
        let payload: ConversationTurnEvent.Payload
        switch type {
        case "turn_started":
            let receipts:[ConversationImageReceipt]?
            if let raw=data["attachment_receipts"] {receipts=try JSONDecoder().decode([ConversationImageReceipt].self,from:Self.jsonData(raw))} else {receipts=nil}
            if let image=request.image {guard receipts==[image.receipt] else {throw ConversationSessionError.invalidEvent}} else {guard receipts==nil || receipts?.isEmpty==true else {throw ConversationSessionError.invalidEvent}}
            payload = .started(requestHash: try Self.sha(data["request_hash"]), conversationRevision: try Self.positive(data["conversation_revision"]), grantEpoch: grant,attachmentReceipts:receipts)
        case "text_delta":
            guard reality != "not_configured", let id = UUID(uuidString: data["message_id"] as? String ?? ""), let text = data["text"] as? String else { throw ConversationSessionError.invalidEvent }
            payload = .textDelta(messageID: id, text: text)
        case "tool_call":
            guard request.image==nil else {throw ConversationSessionError.invalidEvent}
            guard reality != "not_configured", let name = data["name"] as? String, ((["delegate_task", "delegate_plan_v1", "delegate_sources_v1", "agent_status", "propose_memory_v1"].contains(name) && request.continuation==nil) || (name=="revise_current_report_v1" && request.continuation?.intent == .reviseReport)), let id = data["call_id"] as? String, !id.isEmpty else { throw ConversationSessionError.invalidEvent }
            if ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains(name), let args = data["arguments"] as? [String: Any], let title = args["title"] as? String, title.utf16.count <= 160 { toolTitles[request.operationID, default: [:]][id] = title }
            payload = .toolStarted(callID: id, name: name, arguments: String(decoding: try Self.jsonData(Self.object(data["arguments"])), as: UTF8.self))
        case "tool_result":
            guard request.image==nil else {throw ConversationSessionError.invalidEvent}
            guard reality != "not_configured", let name = data["name"] as? String, let call = data["call_id"] as? String, !call.isEmpty else { throw ConversationSessionError.invalidEvent }
            let result = try Self.object(data["result"]); var goals: [ConversationGoalProjection] = []
            var memoryProposal:ConversationMemoryProposalReceipt?
            if ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains(name) {
                let b = try binding(result, request: request, currentTurn: true); guard b.call_id == call, b.grant_epoch == grant else { throw ConversationSessionError.invalidEvent }
                if let known = bindingCache[request.operationID]?[call] { guard known == b else { throw ConversationSessionError.invalidEvent } }
                let goal = try await projection(b, title: title(call, turnID: b.turn_id, history: request.history), request: request, auth: auth)
                // Commit only verified projections; replay the same binding without duplication.
                bindingCache[request.operationID, default: [:]][call] = b
                goals.append(goal)
            } else if name == "propose_memory_v1" {
                memoryProposal=try ConversationMemoryProposalReceipt.decode(Self.jsonData(result),request:request,serverScopeID:configuration.serverScopeID)
            } else if name == "agent_status" {
                var known = Array(bindingCache[request.operationID, default: [:]].values)
                for message in request.history where message.role == .tool && ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains(message.toolName ?? "") {
                    if let raw = try? JSONSerialization.jsonObject(with: Data(message.content.utf8)), let b = try? binding(raw, request: request, currentTurn: false) { known.append(b) }
                }
                for row in try Self.array(result["tasks"]) {
                    let run = try Self.object(row["run"])
                    if let b = known.first(where: { UUID(uuidString: run["id"] as? String ?? "") == $0.run_id && run["request_hash"] as? String == $0.request_hash }) { goals.append(try await projection(b, title: title(b.call_id, turnID: b.turn_id, history: request.history), request: request, auth: auth, supplied: row)) }
                }
            } else if name=="revise_current_report_v1" {
                let receipt=try revisionReceipt(result,request:request,callID:call)
                guard receipt.state=="accepted",let original=request.continuationOriginalBinding else {throw ConversationSessionError.invalidEvent}
                if let prior=continuationReceipts[request.operationID]?[call] {guard prior==receipt else {throw ConversationSessionError.invalidEvent}}
                var projected=try await projection(original,title:title(original.call_id,turnID:original.turn_id,history:request.history),request:request,auth:auth)
                guard receipt.permitsCurrentPlan(projected.planReference) else {throw ConversationSessionError.invalidEvent}
                if projected.state == .completed || projected.planReference != receipt.accepted_plan_reference {
                    let result=try await confirmedContinuationResult(receipt,projected:projected,request:request,auth:auth)
                    if !(projected.artifacts+projected.artifactHistory).contains(where:{$0.id==result.id && $0.version==result.version && $0.contentHash==result.contentHash}) {projected.artifactHistory.append(result)}
                }
                continuationReceipts[request.operationID,default:[:]][call]=receipt;goals.append(projected)
            } else { throw ConversationSessionError.invalidEvent }
            payload = .toolResult(ConversationToolResult(callID: call, name: name, content: String(decoding: try Self.jsonData(result), as: UTF8.self), committedGoals: goals,continuationReceipt:continuationReceipts[request.operationID]?[call],memoryProposalReceipt:memoryProposal))
        case "turn_completed":
            guard reality != "not_configured", let id = UUID(uuidString: data["message_id"] as? String ?? "") else { throw ConversationSessionError.invalidEvent }
            let bindings = try Self.array(data["task_bindings"]); guard bindings.count <= 1 else { throw ConversationSessionError.invalidEvent }
            if request.continuation != nil {guard bindings.isEmpty else {throw ConversationSessionError.invalidEvent};try validateContinuationList(data["continuations"],request:request)}
            let confirmed = try bindings.map { try binding($0, request: request, currentTurn: true) }
            let known = bindingCache[request.operationID, default: [:]]
            guard confirmed.count == known.count, Set(confirmed.map(\.call_id)).count == confirmed.count,
                  confirmed.allSatisfy({ $0.grant_epoch == grant && known[$0.call_id] == $0 }) else { throw ConversationSessionError.invalidEvent }
            let receipt:ConversationVisionProviderReceipt?
            if let image=request.image {let value=try JSONDecoder().decode(ConversationVisionProviderReceipt.self,from:Self.jsonData(Self.object(data["provider_receipt"])));guard value.matches(image) else {throw ConversationSessionError.invalidEvent};receipt=value} else {receipt=nil}
            payload = .completed(messageID: id, finalTextHash: try Self.sha(data["final_text_hash"]),visionReceipt:receipt)
            replyCandidates[request.operationID] = .init(model:receipt?.actual_model)
            if replyCandidates.count>64,let oldest=replyCandidates.keys.first {replyCandidates.removeValue(forKey:oldest)}
        case "turn_failed":
            guard let code = data["code"] as? String, let reconciliation = data["reconciliation_required"] as? Bool else { throw ConversationSessionError.invalidEvent }
            payload = .failed(message: code, reconciliationRequired: reconciliation)
        default: throw ConversationSessionError.invalidEvent
        }
        return ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: sequence, payload: payload)
    }
    private func binding(_ raw: Any, request: ConversationTurnRequest, currentTurn: Bool) throws -> ConversationTaskBinding {
        let b = try JSONDecoder().decode(ConversationTaskBinding.self, from: Self.jsonData(raw))
        guard b.scope_id == configuration.serverScopeID, b.conversation_id == request.conversationID, !currentTurn || b.turn_id == request.operationID,
              Set([b.conversation_id, b.turn_id, b.delegation_id, b.operation_id, b.run_id]).count == 5,
              !b.call_id.isEmpty, Self.opaque(b.task_id), b.delegation_revision > 0, b.grant_epoch > 0,
              try Self.sha(b.request_hash) == b.request_hash,
              b.projection_url == "/catpaw/v1/scopes/\(configuration.serverScopeID.uuidString.lowercased())/runs/\(b.run_id.uuidString.lowercased())" else { throw ConversationSessionError.invalidEvent }
        return b
    }
    private func projection(_ binding: ConversationTaskBinding, title: String, request: ConversationTurnRequest, auth: String, supplied: [String: Any]? = nil) async throws -> ConversationGoalProjection {
        let wrapper: [String: Any]
        if let supplied { wrapper = supplied } else { wrapper = try await json(binding.projection_url, auth: auth) }
        guard try Self.positive(wrapper["schema_version"]) == 1 else { throw ConversationSessionError.invalidEvent }
        let run = try Self.object(wrapper["run"]), task = try Self.object(wrapper["task"])
        guard UUID(uuidString: run["id"] as? String ?? "") == binding.run_id, UUID(uuidString: run["operation_id"] as? String ?? "") == binding.operation_id,
              UUID(uuidString: run["delegation_id"] as? String ?? "") == binding.delegation_id,
              run["task_id"] as? String == binding.task_id, task["id"] as? String == binding.task_id,
              run["request_hash"] as? String == binding.request_hash, try Self.positive(run["grant_epoch"]) == binding.grant_epoch,
              try Self.positive(run["delegation_revision"]) == binding.delegation_revision else { throw ConversationSessionError.invalidEvent }
        let authorizationState = run["authorization_state"] as? String
        let authority = authorizationState == "current"
        let runState = run["state"] as? String
        // A scoped GET can confirm that work stopped while outcome reconciliation
        // and artifact-read authority remain separate. A revoked grant does not
        // make an already confirmed cancellation unknown or undo an external effect.
        let cancellationConfirmed = ["current", "superseded"].contains(authorizationState ?? "") && task["status"] as? String == "cancelled" && ["cancelled", "outcome_unknown"].contains(runState ?? "")
        let projectedState = cancellationConfirmed ? "cancelled" : (authority ? runState : nil)
        let state: ConversationGoalProjection.State
        switch projectedState { case "queued", "scheduled": state = .queued; case "running": state = .working; case "waiting_input": state = .waitingInput; case "succeeded": state = .completed; case "failed": state = .failed; case "paused": state = .paused; case "cancelled": state = .cancelled; default: state = .unknown }
        var artifacts: [ConversationArtifactProjection] = []
        if authority {
            for ref in try Self.array(run["artifact_references"]) {
                guard let id = ref["artifact_id"] as? String, Self.opaque(id) else { throw ConversationSessionError.invalidEvent }
                let version = try Self.positive(ref["version"]), hash = try Self.sha(ref["content_hash"])
                let a = try await json("/catpaw/v1/scopes/\(configuration.serverScopeID.uuidString.lowercased())/artifacts/\(id)/versions/\(version)", auth: auth)
                guard try Self.positive(a["schema_version"]) == 1 else { throw ConversationSessionError.invalidEvent }
                let record = try Self.object(a["artifact"])
                guard record["artifact_id"] as? String == id, try Self.positive(record["version"]) == version, record["content_hash"] as? String == hash,
                      UUID(uuidString: record["run_id"] as? String ?? "") == binding.run_id, record["task_id"] as? String == binding.task_id,
                      let body = record["body"] as? String, body.utf8.count <= 1_000_000, textHash(body) == hash else { throw ConversationSessionError.invalidEvent }
                let parsed = try Self.object(JSONSerialization.jsonObject(with: Data(body.utf8))), data = try Self.object(parsed["data"])
                guard let title = parsed["title"] as? String, let summary = parsed["summary"] as? String, let content = data["content"] as? String else { throw ConversationSessionError.invalidEvent }
                artifacts.append(ConversationArtifactProjection(id: id, version: version, contentHash: hash, body: body, title: title, summary: summary, content: content))
            }
        }
        guard state != .completed || !artifacts.isEmpty else { throw ConversationSessionError.invalidEvent }
        var goal = ConversationGoalProjection(id: binding.task_id, revision: binding.delegation_revision, title: artifacts.first?.title ?? title, state: state,
            summary: artifacts.first?.summary ?? (state == .cancelled ? "工作已取消；已发出的操作仍需核对。" : authority ? "任务已保存；进展来自原任务读取。" : "授权已变更；当前状态待核验。"), updatedAt: Date())
        if let plan=wrapper["plan"] as? [String:Any] {
            let applied=try Self.positive(plan["applied_revision"]),accepted=try Self.positive(plan["accepted_revision"])
            guard accepted>=applied else {throw ConversationSessionError.invalidEvent}
            goal.planReference = .init(revision:applied,planHash:try Self.sha(plan["applied_plan_hash"]))
        }
        goal.binding = binding; goal.artifacts = artifacts; goal.sourceAuthorizationCurrent=authority; return goal
    }
    private func title(_ call: String, turnID: UUID, history: [ConversationTranscriptMessage]) -> String {
        if let current = toolTitles[turnID]?[call] { return current }
        if let message = history.last(where: { $0.role == .assistant && ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains($0.toolName ?? "") && $0.id == stableID("conversation-call-\(turnID)-\(call)") }),
           let object = try? JSONSerialization.jsonObject(with: Data(message.content.utf8)) as? [String: Any], let title = object["title"] as? String { return title }
        return "进行中的目标"
    }
    private func continuationContext(_ request:ConversationTurnRequest) throws {
        guard let target=request.continuation,let subject=configuration.expectedSubjectID,request.continuationSubjectID==subject,
              let original=request.continuationOriginalBinding,original.scope_id==configuration.serverScopeID,original.conversation_id==request.conversationID,
              original.run_id==target.runID,original.task_id==target.taskID,original.grant_epoch==target.expectedGrantEpoch,
              request.scope==configuration.localScope,request.image==nil,request.imageBytes==nil,
              original.turn_id != request.operationID else {throw ConversationSessionError.invalidEvent}
        try target.validate()
    }
    private func continuationAvailability(_ request:ConversationTurnRequest,auth:String) async throws -> Bool {
        let ready=try await json("/readyz",auth:auth)
        guard let caps=ready["chat_capabilities"] as? [String:Any],let value=caps["task_revisions"] as? [String:Any],
              value["contract"] as? String=="catpaw.task-revision.v1",Self.boolean(value["same_task"])==true,Self.boolean(value["immutable_target"])==true else {return false}
        return Self.boolean(value[request.continuation?.intent == .reviseReport ? "revise" : "explain"]) == true
    }
    private func confirmedContinuationBinding(_ request:ConversationTurnRequest,auth:String) async throws -> ConversationTaskBinding {
        try continuationContext(request);let original=request.continuationOriginalBinding!
        guard request.history.contains(where:{message in
            guard message.role == .tool,["delegate_task","delegate_plan_v1","delegate_sources_v1"].contains(message.toolName ?? ""),
                  let data=message.content.data(using:.utf8),let known=try? JSONDecoder().decode(ConversationTaskBinding.self,from:data) else {return false};return known==original
        }) else {throw ConversationSessionError.invalidEvent}
        let response=try await json(path(request)+"/turns/"+original.turn_id.uuidString.lowercased(),auth:auth);try Self.chatEnvelope(response)
        let old=try Self.object(response["turn"])
        guard UUID(uuidString:old["id"] as? String ?? "")==original.turn_id,
              UUID(uuidString:old["conversation_id"] as? String ?? "")==request.conversationID,
              UUID(uuidString:old["scope_id"] as? String ?? "")==configuration.serverScopeID,
              try Self.array(old["task_bindings"]).contains(where:{(try? binding($0,request:request,currentTurn:false))==original}) else {throw ConversationSessionError.invalidEvent}
        return original
    }
    private func continuationBase(_ request:ConversationTurnRequest,inspectCurrent:Bool) async throws -> String {
        try continuationContext(request);let target=request.continuation!,b=request.continuationOriginalBinding!,subject=configuration.expectedSubjectID!
        let route="/catpaw/artifacts/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+b.run_id.uuidString.lowercased()+"/artifacts/"+target.artifactReference.artifactID+"/versions/\(target.artifactReference.version)"
        let bytes=try await taskReviewWire(route,scope:request.scope,limit:1_500_000),wrapper=try ConversationStrictJSON.object(bytes,maxBytes:1_500_000),a=try Self.object(wrapper["artifact"])
        guard try Self.positive(wrapper["schema_version"])==1,wrapper["contract"] as? String=="catpaw.task-artifact.v1",
              a["scope_id"] as? String==b.scope_id.uuidString.lowercased(),a["subject_id"] as? String==subject.uuidString.lowercased(),a["conversation_id"] as? String==request.conversationID.uuidString.lowercased(),
              a["run_id"] as? String==b.run_id.uuidString.lowercased(),a["task_id"] as? String==b.task_id,a["run_request_hash"] as? String==b.request_hash,
              a["delegation_id"] as? String==b.delegation_id.uuidString.lowercased(),try Self.positive(a["delegation_revision"])==b.delegation_revision,
              try Self.positive(a["grant_epoch"])==target.expectedGrantEpoch,a["artifact_id"] as? String==target.artifactReference.artifactID,
              try Self.positive(a["version"])==target.artifactReference.version,a["content_hash"] as? String==target.artifactReference.contentHash,
              let body=a["body"] as? String,body.utf8.count<=512000,textHash(body)==target.artifactReference.contentHash else {throw ConversationSessionError.invalidEvent}
        let plan=try Self.object(a["plan_reference"]);guard try Self.positive(plan["revision"])==target.expectedPlanRevision,try Self.sha(plan["plan_hash"])==target.expectedPlanHash else {throw ConversationSessionError.invalidEvent}
        if inspectCurrent {guard Self.boolean(a["editable"])==true,Self.boolean(a["is_current"])==true else {throw ConversationSessionError.invalidEvent}}
        return try Self.sha(a["source_auth_hash"])
    }
    private func revisionReceipt(_ raw:[String:Any],request:ConversationTurnRequest,callID:String) throws -> ConversationTaskRevisionReceipt {
        guard Set(raw.keys)==ConversationTaskRevisionReceipt.immutableKeys.union(["receipt_hash","state"]),let sourceHash=continuationSourceHashes[request.operationID] else {throw ConversationSessionError.invalidEvent}
        let receipt=try JSONDecoder().decode(ConversationTaskRevisionReceipt.self,from:Self.jsonData(raw));try receipt.validate(request:request,callID:callID,sourceAuthHash:sourceHash);return receipt
    }
    private func confirmedContinuationResult(_ accepted:ConversationTaskRevisionReceipt,projected:ConversationGoalProjection,request:ConversationTurnRequest,auth:String) async throws -> ConversationArtifactProjection {
        let route="/catpaw/revisions/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+accepted.run_id+"/operations/"+accepted.operation_id
        let wrapper=try await json(route,auth:auth),raw=try Self.object(wrapper["revision"])
        guard try Self.positive(wrapper["schema_version"])==1,wrapper["contract"] as? String=="catpaw.task-revision.v1",
              Set(raw.keys)==ConversationTaskRevisionReceipt.immutableKeys.union(["receipt_hash","state","result_reference","result_receipt_hash"]) else {throw ConversationSessionError.invalidEvent}
        let completed=try JSONDecoder().decode(ConversationTaskRevisionReceipt.self,from:Self.jsonData(raw))
        try completed.validate(request:request,callID:accepted.call_id,sourceAuthHash:continuationSourceHashes[request.operationID])
        guard completed.state=="completed",completed.receipt_hash==accepted.receipt_hash,let result=completed.result_reference else {throw ConversationSessionError.invalidEvent}
        if let cached=(projected.artifacts+projected.artifactHistory).first(where:{ConversationArtifactVersionReference(ConversationArtifactIdentity($0))==result && completed.matchesModelArtifact($0)}) {return cached}
        // The current task may already have advanced in another client. Read only
        // the immutable result named by this operation, never an inferred latest.
        let version=try await json("/catpaw/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/artifacts/"+result.artifactID+"/versions/\(result.version)",auth:auth),record=try Self.object(version["artifact"])
        guard try Self.positive(version["schema_version"])==1,record["artifact_id"] as? String==result.artifactID,try Self.positive(record["version"])==result.version,
              record["content_hash"] as? String==result.contentHash,record["run_id"] as? String==accepted.run_id,record["task_id"] as? String==accepted.task_id,
              let body=record["body"] as? String,body.utf8.count<=1_000_000,textHash(body)==result.contentHash else {throw ConversationSessionError.invalidEvent}
        let object=try ConversationStrictJSON.object(Data(body.utf8),maxBytes:1_000_000),data=try Self.object(object["data"])
        guard let title=object["title"] as? String,let summary=object["summary"] as? String,let content=data["content"] as? String else {throw ConversationSessionError.invalidEvent}
        let artifact=ConversationArtifactProjection(id:result.artifactID,version:result.version,contentHash:result.contentHash,body:body,title:title,summary:summary,content:content)
        guard completed.matchesModelArtifact(artifact) else {throw ConversationSessionError.invalidEvent};return artifact
    }
    private func validateContinuationList(_ raw:Any?,request:ConversationTurnRequest,terminal:Bool=true) throws {
        let values=try Self.array(raw),known=continuationReceipts[request.operationID] ?? [:]
        if request.continuation?.intent == .reviseReport {
            // A clarification/prose reply may finish without accepting a revision.
            // It cannot populate a task link, change a result or claim modification.
            if values.isEmpty,known.isEmpty {return}
            guard values.count==1,known.count==1,let call=values[0]["call_id"] as? String,let prior=known[call],try revisionReceipt(values[0],request:request,callID:call)==prior else {throw ConversationSessionError.invalidEvent}
        } else {guard values.isEmpty,known.isEmpty else {throw ConversationSessionError.invalidEvent}}
    }
    private func turnPath(_ request:ConversationTurnRequest) -> String {
        if request.acceptedWork != nil {return "/catpaw/accepted-work/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+request.conversationID.uuidString.lowercased()+"/turns"}
        return request.continuation == nil ? path(request)+"/turns" : "/catpaw/revisions/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+request.conversationID.uuidString.lowercased()+"/turns"
    }
    private var scopePath: String { "/catpaw/chat/v1/scopes/" + configuration.serverScopeID.uuidString.lowercased() }
    private func path(_ r: ConversationTurnRequest) -> String { scopePath + "/conversations/" + r.conversationID.uuidString.lowercased() }
    private func authorization(_ scope: DataScope) async throws -> String {
        guard scope == configuration.localScope else { throw CatpawError.scopeMismatch }
        let value = try await credentials.authorization(scope: scope)
        guard value.hasPrefix("Bearer "), value.count > 7, value.utf8.count < 8192, !value.utf8.contains(10), !value.utf8.contains(13) else { throw ConversationSessionError.notConfigured }
        return value
    }
    private func request(_ path: String, auth: String) throws -> URLRequest {
        try configuration.makeRequest(route:path,authorization:auth)
    }
    private func json(_ path: String, auth: String, body: [String: Any]? = nil,timeout:TimeInterval=60,strict:Bool=false) async throws -> [String: Any] {
        if strict {try Task.checkCancellation()}
        var request = try request(path, auth: auth)
        request.timeoutInterval=timeout
        if let body { request.httpMethod = "POST"; request.httpBody = try Self.jsonData(body) }
        let (data, response) = try await session.data(for: request)
        if strict {try Task.checkCancellation()}
        if (response as? HTTPURLResponse)?.statusCode == 401 { await credentials.rejected(scope: configuration.localScope) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NativeChatHTTPFailure.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard data.count <= 2_000_000 else { throw ConversationSessionError.invalidEvent }
        if strict || path.hasPrefix("/catpaw/accepted-work/v1/") {guard (response as? HTTPURLResponse)?.mimeType=="application/json" else {throw ConversationSessionError.invalidEvent}}
        return strict || path.hasPrefix("/catpaw/revisions/v1/") || path.hasPrefix("/catpaw/accepted-work/v1/") ? try ConversationStrictJSON.object(data,maxBytes:2_000_000) : try Self.object(JSONSerialization.jsonObject(with: data))
    }
    private static func object(_ raw: Any?) throws -> [String: Any] { guard let x = raw as? [String: Any] else { throw ConversationSessionError.invalidEvent }; return x }
    private static func array(_ raw: Any?) throws -> [[String: Any]] { guard let x = raw as? [[String: Any]] else { throw ConversationSessionError.invalidEvent }; return x }
    private static func positive(_ raw: Any?) throws -> Int { guard let x = raw as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(), x.doubleValue > 0, x.doubleValue.rounded() == x.doubleValue, x.doubleValue <= 9007199254740991 else { throw ConversationSessionError.invalidEvent }; return x.intValue }
    private static func sha(_ raw: Any?) throws -> String { guard let x = raw as? String, x.count == 64, x.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ConversationSessionError.invalidEvent }; return x }
    private static func opaque(_ x: String) -> Bool { x.range(of: "^[A-Za-z0-9._-]{1,256}$", options: .regularExpression) != nil }
    private static func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    private static let continuationDenials:Set<String>=["revision_target_binding_conflict","revision_task_binding_conflict","revision_plan_binding_conflict","revision_plan_conflict","revision_artifact_conflict","revision_artifact_binding_conflict","revision_artifact_corrupt","revision_task_not_editable","revision_original_outcome_unknown","revision_consent_conflict","revision_source_not_current","revision_schema_invalid","revision_request_too_large","grant_conflict","memory_generation_superseded","provider_consent_required","sensitive_input_consent_required","revision_frozen_conflict"]
    private static func boolean(_ raw:Any?) -> Bool? {guard let value=raw as? NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() else {return nil};return value.boolValue}
    private static func validateContinuationSnapshot(_ turn:[String:Any],request:ConversationTurnRequest,scope:UUID,grant:Int) throws {
        guard let target=request.continuation else {return}
        guard UUID(uuidString:turn["id"] as? String ?? "")==request.operationID,UUID(uuidString:turn["conversation_id"] as? String ?? "")==request.conversationID,
              UUID(uuidString:turn["scope_id"] as? String ?? "")==scope,try positive(turn["grant_epoch"])==grant,
              try array(turn["task_bindings"]).isEmpty,let raw=turn["revision_target"] as? [String:Any],
              try ConversationArtifactEditCodec.canonicalString(raw)==ConversationArtifactEditCodec.canonicalString(target.canonicalValue) else {throw ConversationSessionError.invalidEvent}
    }
    private static func turnEnvelope(_ x:[String:Any],request:ConversationTurnRequest) throws {
        guard try positive(x["schema_version"])==1,x["contract"] as? String==(request.acceptedWork != nil ? ConversationAcceptedWorkCodec.contract : request.continuation == nil ? "catpaw.native-chat.v1" : "catpaw.task-revision.v1") else {throw ConversationSessionError.invalidEvent}
    }
    private static func chatEnvelope(_ x: [String: Any]) throws { guard try positive(x["schema_version"]) == 1, x["contract"] as? String == "catpaw.native-chat.v1" else { throw ConversationSessionError.invalidEvent } }
}
extension NativeChatHTTPBackend: ConversationTaskPlanBackend {
    public func readPlan(_ reference: ConversationTaskPlanReference) async throws -> ConversationTaskPlanEnvelope {
        try await planRequest(reference, suffix: "")
    }
    public func readAmendment(_ reference: ConversationTaskPlanReference, operationID: UUID) async throws -> ConversationTaskPlanEnvelope {
        try await planRequest(reference, suffix: "/amendments/" + operationID.uuidString.lowercased())
    }
    public func amendPlan(_ reference: ConversationTaskPlanReference, request: ConversationTaskPlanAmendRequest) async throws -> ConversationTaskPlanEnvelope {
        let bytes: Data
        do {
            try request.content.validate()
            guard request.expectedRevision > 0, request.expectedGrantEpoch == reference.binding.grant_epoch,
                  request.expectedPlanHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ConversationTaskPlanError.invalidResponse }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            bytes = try encoder.encode(request)
        } catch { throw ConversationDispatchFailure.notSent(reason: error.localizedDescription) }
        return try await planRequest(reference, suffix: "/amendments", body: bytes)
    }
    private func planRequest(_ reference: ConversationTaskPlanReference, suffix: String, body: Data? = nil) async throws -> ConversationTaskPlanEnvelope {
        let wire: URLRequest
        do {
            guard reference.scope == configuration.localScope, reference.binding.scope_id == configuration.serverScopeID,
                  reference.binding.grant_epoch > 0, reference.binding.delegation_revision > 0 else { throw ConversationTaskPlanError.invalidResponse }
            let auth = try await authorization(reference.scope)
            let path = "/catpaw/plans/v1/scopes/" + configuration.serverScopeID.uuidString.lowercased() + "/runs/" + reference.binding.run_id.uuidString.lowercased() + "/plan" + suffix
            var prepared = try request(path, auth: auth); prepared.timeoutInterval = 20
            prepared.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { guard body.count <= 48000 else { throw ConversationTaskPlanError.invalidResponse }; prepared.httpMethod = "POST"; prepared.httpBody = body }
            wire = prepared
        } catch {
            if body != nil { throw ConversationDispatchFailure.notSent(reason: error.localizedDescription) }
            throw error
        }
        let (bytes, response) = try await session.data(for: wire)
        // The envelope contains both accepted and applied content; escaped bounded fields
        // can exceed 64 KiB even when each version is valid. Keep a finite wire limit.
        guard let http = response as? HTTPURLResponse, bytes.count <= 512_000 else { throw ConversationTaskPlanError.invalidResponse }
        if http.statusCode == 401 { await credentials.rejected(scope: reference.scope) }
        guard (200..<300).contains(http.statusCode) else {
            if body != nil, let error = try? JSONDecoder().decode(NativeTaskPlanErrorEnvelope.self, from: bytes), error.schemaVersion == 1, !error.error.reconciliationRequired {
                if http.statusCode == 409 { throw CatpawError.conflict }
                if [400,401,403,404,405,413,422,429].contains(http.statusCode) {
                    throw ConversationDispatchFailure.notSent(reason: "计划修改未被受理（HTTP \(http.statusCode)）。草稿已保留。")
                }
            }
            throw NativeChatHTTPFailure.status(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(ConversationTaskPlanEnvelope.self, from: bytes)
        guard envelope.schemaVersion == 1, envelope.contract == "catpaw.task-plan.v1" else { throw ConversationTaskPlanError.invalidResponse }
        try envelope.plan.validate(reference: reference)
        return envelope
    }
}
extension NativeChatHTTPBackend:ConversationTaskControlBackend {
    private static func controlBoolean(_ value:Any?)->Bool? {
        guard let number=value as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else {return nil}
        return number.boolValue
    }
    private func taskControlPath(_ reference:ConversationTaskControlReference) throws -> String {
        try reference.validate()
        guard reference.scope==configuration.localScope,reference.binding.scope_id==configuration.serverScopeID else {throw CatpawError.scopeMismatch}
        guard configuration.expectedSubjectID?.uuidString.lowercased()==reference.subjectID else {throw ConversationTaskControlError.notConfigured}
        return "/catpaw/controls/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+reference.binding.run_id.uuidString.lowercased()+"/control"
    }
    public func controlAvailability(_ reference:ConversationTaskControlReference) async throws -> Bool {
        _=try taskControlPath(reference)
        let data=try await taskReviewWire("/readyz",scope:reference.scope,limit:128_000)
        let ready=try Self.object(JSONSerialization.jsonObject(with:data))
        guard Self.controlBoolean(ready["ready"])==true,let caps=ready["chat_capabilities"] as? [String:Any],let controls=caps["task_controls"] as? [String:Any],controls["contract"] as? String=="catpaw.task-control.v1",Self.controlBoolean(controls["read"])==true,Self.controlBoolean(controls["same_task"])==true,Self.controlBoolean(controls["pause_preserves_grant"])==true,Self.controlBoolean(controls["unknown_resend"])==false else {return false}
        return ["pause","resume","revoke"].allSatisfy{Self.controlBoolean(controls[$0])==true}
    }
    public func readControl(_ reference:ConversationTaskControlReference) async throws -> ConversationTaskControlEnvelope {
        let result=try await controlEnvelope(taskControlPath(reference),reference:reference)
        guard result.operation==nil else {throw ConversationTaskControlError.invalidResponse};return result
    }
    public func readControlOperation(_ reference:ConversationTaskControlReference,operationID:UUID) async throws -> ConversationTaskControlEnvelope {
        do {
            let result=try await controlEnvelope(taskControlPath(reference)+"/operations/"+operationID.uuidString.lowercased(),reference:reference)
            guard result.operation?.operation_id==operationID.uuidString.lowercased() else {throw ConversationTaskControlError.invalidResponse};return result
        } catch NativeChatHTTPFailure.status(404) {throw ConversationTaskControlError.originalNotFound}
    }
    public func submitControl(_ reference:ConversationTaskControlReference,request:ConversationTaskControlRequest) async throws -> ConversationTaskControlEnvelope {
        let path:String,body:Data
        do {path=try taskControlPath(reference)+"/operations";try request.validate(reference:reference);body=try ConversationTaskActionJSON.encoded(request);guard body.count<=8000 else {throw ConversationTaskControlError.invalidResponse}}
        catch {throw ConversationTaskControlDispatchFailure.notSent}
        do {
            let result=try await controlEnvelope(path,reference:reference,body:body)
            guard let receipt=result.operation,receipt.operation_id==request.operationID.uuidString.lowercased(),receipt.action==request.action,receipt.base_execution_revision==request.expected_execution_revision,receipt.base_snapshot_hash==request.expected_snapshot_hash,receipt.grant_epoch==request.expected_grant_epoch,receipt.plan_reference.revision==request.expected_plan_revision,receipt.plan_reference.plan_hash==request.expected_plan_hash else {throw ConversationTaskControlError.invalidResponse};return result
        } catch is NativeTaskReviewPreflightFailure {throw ConversationTaskControlDispatchFailure.notSent}
    }
    private func controlEnvelope(_ path:String,reference:ConversationTaskControlReference,body:Data?=nil) async throws -> ConversationTaskControlEnvelope {
        let data=try await taskReviewWire(path,scope:reference.scope,body:body,limit:256_000)
        let result=try JSONDecoder().decode(ConversationTaskControlEnvelope.self,from:data);try result.validate(reference:reference);return result
    }
}

extension NativeChatHTTPBackend:ConversationTaskActionBackend {
    private func taskActionPath(_ reference:ConversationTaskActionReference) throws -> String {
        guard reference.scope==configuration.localScope,reference.binding.scope_id==configuration.serverScopeID else {throw CatpawError.scopeMismatch}
        return "/catpaw/actions/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+reference.binding.run_id.uuidString.lowercased()+"/actions"
    }
    public func decisionAvailability(_ reference:ConversationTaskActionReference) async throws -> Bool {
        _=try taskActionPath(reference)
        let data=try await taskReviewWire("/readyz",scope:reference.scope,limit:128_000)
        let ready=try Self.object(JSONSerialization.jsonObject(with:data))
        guard ready["ready"] as? Bool==true,let caps=ready["chat_capabilities"] as? [String:Any],let actions=caps["task_actions"] as? [String:Any],actions["contract"] as? String=="catpaw.task-action.v1",actions["review"] as? Bool==true else {return false}
        return actions["decision"] as? Bool==true
    }
    public func readActions(_ reference:ConversationTaskActionReference) async throws -> ConversationTaskActionCatalog {
        let data=try await taskReviewWire(taskActionPath(reference),scope:reference.scope,limit:1_000_000)
        let result=try JSONDecoder().decode(ConversationTaskActionCatalog.self,from:data);try result.validate(reference:reference);return result
    }
    public func readAction(_ reference:ConversationTaskActionReference,actionID:String) async throws -> ConversationTaskActionEnvelope {
        guard ConversationTaskActionValidation.uuid(actionID) else {throw ConversationTaskActionError.invalidResponse}
        let result=try await actionEnvelope(taskActionPath(reference)+"/"+actionID,reference:reference)
        guard result.action.id==actionID,result.decision==nil else {throw ConversationTaskActionError.invalidResponse};return result
    }
    public func decideAction(_ reference:ConversationTaskActionReference,actionID:String,request:ConversationTaskActionDecisionRequest) async throws -> ConversationTaskActionEnvelope {
        let path:String,body:Data
        do {guard ConversationTaskActionValidation.uuid(actionID),ConversationTaskActionValidation.hash(request.action_digest),request.expected_revision>0,request.expected_revision<=9_007_199_254_740_991,request.expected_grant_epoch==reference.binding.grant_epoch,request.expected_grant_epoch>0 else {throw ConversationTaskActionError.invalidResponse};path=try taskActionPath(reference)+"/"+actionID+"/decisions";body=try ConversationTaskActionJSON.encoded(request);guard body.count<=16384 else {throw ConversationTaskActionError.invalidResponse}}
        catch {throw ConversationTaskActionDispatchFailure.notSent}
        do {
            let result=try await actionEnvelope(path,reference:reference,body:body)
            try validateActionReceipt(result,actionID:actionID,operationID:request.operationID)
            guard result.decision?.decision==request.decision,result.action.action_digest==request.action_digest,result.action.revision>request.expected_revision else {throw ConversationTaskActionError.invalidResponse};return result
        }
        catch is NativeTaskReviewPreflightFailure {throw ConversationTaskActionDispatchFailure.notSent}
    }
    public func readDecision(_ reference:ConversationTaskActionReference,actionID:String,operationID:UUID) async throws -> ConversationTaskActionEnvelope {
        guard ConversationTaskActionValidation.uuid(actionID) else {throw ConversationTaskActionError.invalidResponse}
        do {let result=try await actionEnvelope(taskActionPath(reference)+"/"+actionID+"/decisions/"+operationID.uuidString.lowercased(),reference:reference);try validateActionReceipt(result,actionID:actionID,operationID:operationID);return result}
        catch NativeChatHTTPFailure.status(404) {throw ConversationTaskActionError.originalNotFound}
    }
    private func actionEnvelope(_ path:String,reference:ConversationTaskActionReference,body:Data?=nil) async throws -> ConversationTaskActionEnvelope {
        let data=try await taskReviewWire(path,scope:reference.scope,body:body,limit:128_000)
        let result=try JSONDecoder().decode(ConversationTaskActionEnvelope.self,from:data)
        guard result.schema_version==1,result.contract=="catpaw.task-action.v1" else {throw ConversationTaskActionError.invalidResponse}
        try result.action.validate(reference:reference);return result
    }
    private func validateActionReceipt(_ result:ConversationTaskActionEnvelope,actionID:String,operationID:UUID) throws {
        guard result.action.id==actionID,let receipt=result.decision,receipt.operation_id==operationID.uuidString.lowercased(),receipt.action_id==actionID,receipt.state=="accepted",receipt.action_digest==result.action.action_digest,result.action.decision_operation_id==receipt.operation_id,
              let committed=ConversationTaskActionValidation.utc(receipt.committed_at),let created=ConversationTaskActionValidation.utc(result.action.frozen.created_at),let expiry=ConversationTaskActionValidation.utc(result.action.frozen.expires_at),committed>=created,committed<expiry,
              (receipt.decision == .approve && result.action.approval_status=="approved") || (receipt.decision == .deny && result.action.approval_status=="denied") else {throw ConversationTaskActionError.invalidResponse}
    }
    /// Authentication/encoding failures before URLSession starts are distinct from a lost POST response.
    /// Reuse this backend's scoped credentials/session. Typed effect decoding and
    /// durable delivery belong to the application service, never this wire bridge.
    private func deviceEffectPath(_ reference:ConversationDeviceEffectReference) throws -> String {
        guard reference.scope==configuration.localScope,reference.binding.scope_id==configuration.serverScopeID,
              configuration.expectedSubjectID?.uuidString.lowercased()==reference.subjectID else {throw ConversationDeviceEffectError.referenceMismatch}
        return "/catpaw/device-effects/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+reference.binding.run_id.uuidString.lowercased()+"/actions/"+reference.actionID+"/effects/"+(try reference.effectID)
    }
    func deviceEffectReadinessWire(reference:ConversationDeviceEffectReference) async throws -> Data {
        _=try deviceEffectPath(reference)
        return try await taskReviewWire("/readyz",scope:reference.scope,limit:128_000)
    }
    func deviceEffectWire(reference:ConversationDeviceEffectReference,suffix:String,body:Data?=nil,limit:Int=512_000) async throws -> Data {
        let path:String
        do {
            let allowed = body == nil ? suffix.isEmpty : ["admissions","dispatches","results","stop"].contains(suffix)
            guard allowed,limit>0,limit<=512_000 else {throw ConversationDeviceEffectError.referenceMismatch}
            path=try deviceEffectPath(reference)+(suffix.isEmpty ? "" : "/"+suffix)
        } catch {if body != nil {throw ConversationDeviceEffectDispatchFailure.notSent};throw error}
        do {return try await taskReviewWire(path,scope:reference.scope,body:body,limit:limit)}
        catch is NativeTaskReviewPreflightFailure {throw ConversationDeviceEffectDispatchFailure.notSent}
        catch NativeChatHTTPFailure.status(404) {if body == nil {throw ConversationDeviceEffectServiceError.originalNotFound};throw NativeChatHTTPFailure.status(404)}
    }
    private func taskReviewWire(_ path:String,scope:DataScope,body:Data?=nil,limit:Int) async throws -> Data {
        let wire:URLRequest
        do {
            var value=try configuration.makeRequest(route:path,authorization:await authorization(scope));value.setValue("application/json",forHTTPHeaderField:"Accept")
            if let body {value.httpMethod="POST";value.httpBody=body};wire=value
        } catch {if body != nil {throw NativeTaskReviewPreflightFailure()};throw error}
        let (data,response)=try await session.data(for:wire)
        guard let http=response as? HTTPURLResponse,data.count<=limit else {throw ConversationSessionError.invalidEvent}
        if http.statusCode==401 {await credentials.rejected(scope:scope)}
        let type=(http.value(forHTTPHeaderField:"Content-Type") ?? "").split(separator:";").first?.trimmingCharacters(in:.whitespaces).lowercased()
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode==409,type=="application/json",(try? ConversationStrictJSON.object(data,maxBytes:limit)) != nil,let error=try? JSONDecoder().decode(NativeTaskReviewErrorEnvelope.self,from:data),error.schemaVersion==1,!error.error.reconciliationRequired,!error.error.retryable {throw CatpawError.conflict}
            throw NativeChatHTTPFailure.status(http.statusCode)
        }
        guard type=="application/json" else {throw ConversationSessionError.invalidEvent}
        _=try ConversationStrictJSON.object(data,maxBytes:limit);return data
    }
}
extension NativeChatHTTPBackend:ConversationArtifactEditBackend {
    private func artifactEditPath(_ reference:ConversationArtifactEditReference) throws -> String {
        guard reference.scope==configuration.localScope,reference.binding.scope_id==configuration.serverScopeID else {throw CatpawError.scopeMismatch}
        guard ConversationArtifactEditCodec.isHash(reference.artifact.id),reference.artifact.version>0,textHash(reference.artifact.body)==reference.artifact.contentHash else {throw ConversationArtifactEditError.invalidResponse}
        return "/catpaw/artifacts/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+reference.binding.run_id.uuidString.lowercased()+"/artifacts/"+reference.artifact.id
    }
    public func readArtifact(_ reference:ConversationArtifactEditReference,version:Int?) async throws -> ConversationArtifactEditEnvelope {
        var path=try artifactEditPath(reference)
        if let version {guard ConversationArtifactEditCodec.validInteger(version) else {throw ConversationArtifactEditError.invalidResponse};path += "/versions/\(version)"}
        let result=try await artifactEditEnvelope(path,reference:reference)
        guard result.amendment==nil,version.map({result.artifact.version==$0}) ?? result.artifact.isCurrent else {throw ConversationArtifactEditError.invalidResponse};return result
    }
    public func amendArtifact(_ reference:ConversationArtifactEditReference,request:ConversationArtifactEditAmendRequest) async throws -> ConversationArtifactEditEnvelope {
        let path:String,body:Data
        do {
            path=try artifactEditPath(reference)+"/amendments";try request.content.validate()
            guard ConversationArtifactEditCodec.validInteger(request.expectedVersion),ConversationArtifactEditCodec.isHash(request.expectedContentHash),request.expectedGrantEpoch==reference.binding.grant_epoch,ConversationArtifactEditCodec.validInteger(request.expectedGrantEpoch),ConversationArtifactEditCodec.validInteger(request.expectedPlanRevision),ConversationArtifactEditCodec.isHash(request.expectedPlanHash) else {throw ConversationArtifactEditError.invalidResponse}
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];body=try encoder.encode(request)
            guard body.count<=96000 else {throw ConversationArtifactEditError.invalidResponse}
        } catch {throw ConversationDispatchFailure.notSent(reason:"成果修改尚未发送，草稿已保留。")}
        do {
            let result=try await artifactEditEnvelope(path,reference:reference,body:body)
            guard let receipt=result.amendment,receipt.operationID==request.operationID,receipt.baseReference.version==request.expectedVersion,receipt.baseReference.contentHash==request.expectedContentHash,receipt.content==request.content else {throw ConversationArtifactEditError.invalidResponse};return result
        } catch is NativeTaskReviewPreflightFailure {throw ConversationDispatchFailure.notSent(reason:"成果修改尚未发送，草稿已保留。")}
    }
    public func readAmendment(_ reference:ConversationArtifactEditReference,operationID:UUID) async throws -> ConversationArtifactEditEnvelope {
        let result=try await artifactEditEnvelope(artifactEditPath(reference)+"/amendments/"+operationID.uuidString.lowercased(),reference:reference)
        guard result.amendment?.operationID==operationID else {throw ConversationArtifactEditError.invalidResponse};return result
    }
    private func artifactEditEnvelope(_ path:String,reference:ConversationArtifactEditReference,body:Data?=nil) async throws -> ConversationArtifactEditEnvelope {
        let data=try await taskReviewWire(path,scope:reference.scope,body:body,limit:1_500_000)
        let result=try JSONDecoder().decode(ConversationArtifactEditEnvelope.self,from:data)
        try result.validate(reference:reference);return result
    }
}
private struct NativeTaskReviewPreflightFailure:Error {}
private struct NativeTaskReviewErrorEnvelope:Decodable {
    struct Failure:Decodable {let code:String,retryable:Bool,reconciliationRequired:Bool;private enum CodingKeys:String,CodingKey {case code,retryable;case reconciliationRequired="reconciliation_required"}}
    let schemaVersion:Int,error:Failure
    private enum CodingKeys:String,CodingKey {case error;case schemaVersion="schema_version"}
}
private struct NativeTaskPlanErrorEnvelope: Decodable {
    struct Failure: Decodable {
        let code: String
        let reconciliationRequired: Bool
        private enum CodingKeys: String, CodingKey { case code; case reconciliationRequired = "reconciliation_required" }
    }
    let schemaVersion: Int
    let error: Failure
    private enum CodingKeys: String, CodingKey { case error; case schemaVersion = "schema_version" }
}
private enum NativeChatHTTPFailure: Error, LocalizedError {
    case status(Int), turnResponse(Int)
    var errorDescription: String? {
        switch self {
        case .status(let code): return "后台读取返回 HTTP \(code)，保留原请求。"
        case .turnResponse(let code):
            let reason = code == 401 ? "登录状态需要复核" : (code == 429 ? "服务繁忙" : "服务响应异常")
            return "\(reason)（HTTP \(code)）。本轮发送结果尚未确认；请读取原请求状态，不要重新发送。"
        }
    }
}
private final class NativeChatNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private struct NativeImageConsentRow:Decodable {let scope_id:UUID;let conversation_id:UUID;let decision:String;let route_hash:String;let revision:Int;let non_sensitive_confirmed:Bool}
private struct NativeFixedVisionRoute:Decodable {
 struct Retention:Decodable {let days:Int;let human_review_possible:Bool}
 struct Policy:Decodable {let only:[String];let allow_fallbacks:Bool;let require_parameters:Bool;let data_collection:String;let max_price:[String:Double]}
 let provider:String;let downstream_provider:String;let model:String;let free:Bool;let zero_retention_claim:Bool;let privacy_notice_version:Int;let retention:Retention;let routing_policy:Policy
 var matchesSupportedNotice:Bool {provider=="OpenRouter" && downstream_provider=="Google AI Studio" && model=="google/gemma-4-31b-it:free" && free && !zero_retention_claim && privacy_notice_version==1 && retention.days==55 && retention.human_review_possible && routing_policy.only==["google-ai-studio"] && !routing_policy.allow_fallbacks && routing_policy.require_parameters && routing_policy.data_collection=="deny" && routing_policy.max_price==["prompt":0,"completion":0,"request":0,"image":0]}
}
