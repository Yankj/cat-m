import Foundation
import CoreFoundation

/// The dedicated namespace fails closed on servers that do not support read-only parenting intake.
public enum NativeChatPurpose: Sendable, Equatable { case conversation, parentingIntake }

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
        guard !useFrozenFixtureMetadata || (allowInjectedTestProvider && c.scheme == "http" && c.host == "127.0.0.1") else { throw catError.invalid("冻结 fixture metadata 仅允许明确 loopback 测试。") }
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
        if let edgeRegion { request.setValue(edgeRegion,forHTTPHeaderField:"x-region") }
        // catpaw.model-routes.v1: always a valid route (auto or a listed id); model only with a concrete route + allow-list.
        request.setValue(ModelRouteSelection.headerRoute,forHTTPHeaderField:"X-Catpaw-Route")
        if let model = ModelRouteSelection.headerModel { request.setValue(model,forHTTPHeaderField:"X-Catpaw-Model") }
        request.setValue("1",forHTTPHeaderField:"X-Catpaw-Route-Events")
        request.setValue("1",forHTTPHeaderField:"X-Catpaw-Reasoning-Summary") // decodes optional reasoning_summary
        return request
    }
}
/// An authenticated application session, never an OpenRouter key or client-chosen identity.
public protocol NativeChatSessionCredentials: Sendable { func authorization(scope: DataScope) async throws -> String; func rejected(scope: DataScope) async }
public extension NativeChatSessionCredentials { func rejected(scope: DataScope) async { } }
public struct MissingNativeChatSession: NativeChatSessionCredentials {
    public init() {}
    public func authorization(scope: DataScope) async throws -> String { throw ConversationSessionError.notConfigured }
}
public actor NativeChatHTTPBackend: ConversationBackend, ConversationInboxBackend {
    private let configuration: NativeChatConfiguration
    private let credentials: any NativeChatSessionCredentials
    private let session: URLSession
    private let acceptedWorkClock:@Sendable()->Date
    private let purpose: NativeChatPurpose
    private static let intakeContract = "mimi.parenting-intake.v1"
    private static let intakeUnavailable = "当前服务版本尚未支持原位整理，未发送 AI 请求；原话已保留，可以继续手动填写。"
    private var bindingCache: [UUID: [String: ConversationTaskBinding]] = [:]
    private var toolTitles: [UUID: [String: String]] = [:]
    private var continuationReceipts:[UUID:[String:ConversationTaskRevisionReceipt]]=[:]
    private var revisionWorkReceipts:[UUID:[String:ConversationRevisionWorkReceipt]]=[:]
    private var continuationSourceHashes:[UUID:String]=[:]
    private var livePreviewDropLogged: Set<UUID> = []
    public nonisolated var supportsArtifactContinuations:Bool {configuration.expectedSubjectID != nil}
    public nonisolated var artifactContinuationSubjectID:UUID? {configuration.expectedSubjectID}
    private var observedModelState: ConversationConnection.State?
    private var verifiedReplyAt:Date?
    private var verifiedModel:String?
    private struct ReplyCandidate {let model:String?}
    private var replyCandidates:[UUID:ReplyCandidate]=[:]
    public init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials = MissingNativeChatSession(),sessionConfiguration:URLSessionConfiguration?=nil,acceptedWorkClock:@escaping @Sendable()->Date={Date()},purpose:NativeChatPurpose = .conversation) {
        self.configuration = configuration; self.credentials = credentials
        self.purpose = purpose
        self.acceptedWorkClock=acceptedWorkClock
        let policy = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral; policy.urlCache = nil; policy.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: policy, delegate: NativeChatNoRedirect(), delegateQueue: nil)
    }
    public func close() { session.invalidateAndCancel(); bindingCache.removeAll(); toolTitles.removeAll(); continuationReceipts.removeAll();revisionWorkReceipts.removeAll();continuationSourceHashes.removeAll(); observedModelState = nil;verifiedReplyAt=nil;verifiedModel=nil;replyCandidates.removeAll() }
    /// Append Gemini / OpenCode disclosures + policy links from GET /catpaw/privacy/v1/model-route → `route`
    /// (not .../model-consent). `route.gemini_disclosure` (only when Gemini is enabled; free tier may train),
    /// `route.opencode_disclosure` (only when OpenCode is enabled) +
    /// `route.policy_url` / `route.policy_urls[]`. Legacy aggregator fields ignored.
    static func consentBody(_ body:String,metadata:[String:Any],ui:[String:Any]) -> String {
        _ = ui
        guard let route = metadata["route"] as? [String:Any] else { return body }
        var parts: [String] = [body]
        for key in ["gemini_disclosure", "opencode_disclosure"] {
            if let d = route[key] as? String, !d.isEmpty, !body.contains(d) { parts.append(d) }
        }
        var urls: [String] = []
        if let list = route["policy_urls"] as? [String] { urls.append(contentsOf: list) }
        if let one = route["policy_url"] as? String { urls.append(one) }
        let https = urls.filter { $0.hasPrefix("https://") && !body.contains($0) }
        var seen = Set<String>(); let ordered = https.filter { seen.insert($0).inserted }
        if !ordered.isEmpty { parts.append(ordered.joined(separator: "\n")) }
        guard parts.count > 1 else { return body }
        let joined = parts.joined(separator: "\n\n")
        return joined.utf8.count <= 12000 ? joined : body
    }
    /// GET /catpaw/model-routes/v1. nil when not deployed / unreachable (callers use `ModelRoutesFixture`).
    public func modelRoutes(scope: DataScope) async -> ModelRoutesContract? {
        guard let auth = try? await authorization(scope), let raw = try? await json("/catpaw/model-routes/v1", auth: auth, timeout: 15),
              let data = try? Self.jsonData(raw), let c = try? JSONDecoder().decode(ModelRoutesContract.self, from: data),
              c.contract == ModelRoutesContract.contractID else { return nil }
        return c
    }
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
        let ready:[String:Any]
        do { ready = try await json(base,auth:auth) } catch NativeChatHTTPFailure.status(404) { ready = try await json(scopePath+"/conversations",auth:auth,body:["conversation_id":conversationID.uuidString.lowercased()]) }
        if purpose == .parentingIntake { try validatePurpose(try Self.object(ready["conversation"])) }
        let metadata = try await json("/catpaw/privacy/v1/model-route",auth:auth),ui = try Self.object(metadata["ui"]),routeHash = try Self.sha(metadata["route_hash"])
        let path = "/catpaw/privacy/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+conversationID.uuidString.lowercased()+"/model-consent"
        let stored = try await json(path,auth:auth);let prior = stored["consent"] as? [String:Any]
        let account = AccountModelConsentMemory(subjectID: configuration.expectedSubjectID, serverScopeID: configuration.serverScopeID)
        if prior?["decision"] as? String == "allow",prior?["route_hash"] as? String == routeHash { account.remember(routeHash); return nil }
        // Acceptance #2: the server keys provider consent per (subject, conversation) (_shared/api.mjs:178/207,
        // consentId(subject_id, conversation.id)), so every NEW conversation came back without a row and the sheet re-asked.
        // The user already allowed this exact disclosure (same route_hash) for this account: record the per-chat row
        // silently. A changed route_hash, another account, or an explicit "deny" on this chat still shows the sheet.
        if prior?["decision"] as? String != "deny", account.allows(routeHash), case let revision = (prior?["revision"] as? Int) ?? 0, revision >= 0 {
            do {
                let reply = try await json(path,auth:auth,body:["decision":"allow","expected_revision":revision,"route_hash":routeHash]),row = try Self.object(reply["consent"])
                if row["decision"] as? String == "allow",row["route_hash"] as? String == routeHash,row["revision"] as? Int == revision+1 { sendDiagnostic("catpaw.send consent carried route=\(routeHash.prefix(8))"); return nil }
            } catch { sendDiagnostic("catpaw.send consent carry failed; showing sheet") }
        }
        guard let title = ui["title"] as? String,let body = ui["body"] as? String,title.utf8.count <= 512,body.utf8.count <= 12000 else { throw ConversationSessionError.invalidEvent }
        let revision = prior?["revision"] as? Int ?? 0;guard revision >= 0 else { throw ConversationSessionError.invalidEvent }
        return .init(conversationID:conversationID,title:title,body:Self.consentBody(body,metadata:metadata,ui:ui),routeHash:routeHash,expectedRevision:revision)
    }
    public func serverTranscript(scope: DataScope, conversationID: UUID) async throws -> [ConversationTranscriptMessage]? {
        guard scope == configuration.localScope, !configuration.useFrozenFixtureMetadata else { return nil }
        let auth = try await authorization(scope)
        let wrapper: [String: Any]
        do { wrapper = try await json(scopePath + "/conversations/" + conversationID.uuidString.lowercased(), auth: auth) }
        catch NativeChatHTTPFailure.status(404) { return [] }
        try Self.chatEnvelope(wrapper); let c = try Self.object(wrapper["conversation"])
        guard UUID(uuidString: c["id"] as? String ?? "") == conversationID, UUID(uuidString: c["scope_id"] as? String ?? "") == configuration.serverScopeID else { throw ConversationSessionError.invalidEvent }
        return try Self.array(c["messages"]).map { wire in
            guard let id = UUID(uuidString: wire["id"] as? String ?? ""), let role = wire["role"] as? String, role == "user" || role == "assistant",
                  let content = wire["content"] as? String, content.utf16.count <= 200_000 else { throw ConversationSessionError.invalidEvent }
            // No server timestamp: the merge orders server-only rows by server order (createdAt .distantPast is replaced there).
            return ConversationTranscriptMessage(id: id, role: role == "user" ? .user : .assistant, content: content, complete: true, createdAt: .distantPast)
        }
    }
    public func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws {
        let auth = try await authorization(scope),path = "/catpaw/privacy/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+consent.conversationID.uuidString.lowercased()+"/model-consent"
        let reply = try await json(path,auth:auth,body:["decision":"allow","expected_revision":consent.expectedRevision,"route_hash":consent.routeHash]),row = try Self.object(reply["consent"])
        guard row["decision"] as? String == "allow",row["route_hash"] as? String == consent.routeHash,row["revision"] as? Int == consent.expectedRevision+1 else { throw ConversationSessionError.invalidEvent }
        AccountModelConsentMemory(subjectID: configuration.expectedSubjectID, serverScopeID: configuration.serverScopeID).remember(consent.routeHash)
    }
    public func acceptedWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {
        guard scope==configuration.localScope else {throw catError.scopeMismatch}
        guard let subject=configuration.expectedSubjectID else {return .init()}
        try Task.checkCancellation();let auth=try await authorization(scope);try Task.checkCancellation()
        let ready=try await json("/readyz",auth:auth,strict:true);try Task.checkCancellation()
        guard Self.boolean(ready["ready"])==true,let caps=ready["chat_capabilities"] as? [String:Any],let work=caps["accepted_work"] as? [String:Any],Self.boolean(work["enabled"])==true else {return .init()}
        let route=try await json("/catpaw/privacy/v1/model-route",auth:auth,strict:true);try Task.checkCancellation()
        return try ConversationAcceptedWorkCodec.capability(readiness:Self.jsonData(ready),modelRoute:Self.jsonData(route),subjectID:subject,serverScopeID:configuration.serverScopeID)
    }
    public func revisionWorkCapability(scope:DataScope,conversationID:UUID) async throws -> ConversationAcceptedWorkCapability {
        guard scope==configuration.localScope else {throw catError.scopeMismatch}
        guard let subject=configuration.expectedSubjectID else {return .init()}
        let auth=try await authorization(scope);try Task.checkCancellation()
        let ready=try await json("/readyz",auth:auth,strict:true)
        guard Self.boolean(ready["ready"])==true,let caps=ready["chat_capabilities"] as? [String:Any],let revisions=caps["task_revisions"] as? [String:Any],let bounded=revisions["bounded_work"] as? [String:Any],bounded["contract"] as? String==ConversationRevisionWorkCodec.contract,bounded["grant_contract"] as? String==ConversationRevisionWorkCodec.grantContract,Self.boolean(bounded["enabled"])==true,Self.boolean(bounded["required_for_accepted_work"])==true else {return .init()}
        let route=try await json("/catpaw/privacy/v1/model-route",auth:auth,strict:true);try Task.checkCancellation()
        return try ConversationAcceptedWorkCodec.capability(readiness:Self.jsonData(ready),modelRoute:Self.jsonData(route),subjectID:subject,serverScopeID:configuration.serverScopeID)
    }
    public func freezeRevisionWork(_ request:ConversationTurnRequest,selection:ConversationRevisionWorkSelection) async throws -> ConversationRevisionWorkIntent {
        do {
            try continuationContext(request)
            guard request.revisionWork==nil,request.acceptedWork==nil,selection.target==request.continuation,selection.authorization.serverScopeID==configuration.serverScopeID,selection.authorization.subjectID==configuration.expectedSubjectID else {throw ConversationAcceptedWorkError.invalidSelection}
            let capability=try await revisionWorkCapability(scope:request.scope,conversationID:request.conversationID);try Task.checkCancellation();try selection.validate(capability:capability,now:acceptedWorkClock())
            let auth=try await authorization(request.scope);try Task.checkCancellation()
            try await validateRevisionWorkPolicy(request,selection:selection,auth:auth);try Task.checkCancellation()
            let conversation=try await readConversation(request,auth:auth,mayCreate:false,strict:true);try Task.checkCancellation();try validateHistory(conversation,request:request)
            let intent=try ConversationRevisionWorkIntent(request:request,selection:selection,expectedRevision:Self.positive(conversation["revision"]),expectedGrantEpoch:Self.positive(conversation["grant_epoch"]))
            try intent.validateForFirstPost(request:request,capability:capability,now:acceptedWorkClock());return intent
        } catch {throw ConversationDispatchFailure.notSent(reason:Self.friendlyTransportMessage(error))}
    }
    private func validateRevisionWorkPolicy(_ request:ConversationTurnRequest,selection:ConversationRevisionWorkSelection,auth:String) async throws {
        guard let binding=request.continuationOriginalBinding else {throw ConversationSessionError.invalidEvent}
        let goal=try await projection(binding,title:"",auth:auth);try Task.checkCancellation()
        guard goal.revisionRequiresNewWork==true,let policy=goal.revisionWorkPolicy else {throw ConversationAcceptedWorkError.invalidSelection};try policy.validate(options:selection.options)
    }
    private func revisionWorkContext(_ request:ConversationTurnRequest) throws {
        guard let intent=request.revisionWork,intent.selection.authorization.serverScopeID==configuration.serverScopeID,intent.selection.authorization.subjectID==configuration.expectedSubjectID else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        try intent.validate(request:request);try continuationContext(request)
    }
    public func ensureConversationForExplicitSend(_ request:ConversationTurnRequest) async throws {
        guard request.acceptedWork==nil,request.revisionWork==nil,configuration.expectedSubjectID != nil else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
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
        try Self.checkServerHistory(try Self.array(conversation["messages"]),request:request,strict:true,site:"validateHistory")
    }
    /// History check before admission. Strict (acceptedWork / revisionWork / continuation, validateHistory):
    /// the local wire history must equal the server's exactly. Plain turns: only locally held messages the server
    /// has confirmed (same id) take part. Every other local message, whatever its role (an unsent user message
    /// from an old client, a locally generated failed assistant notice), is local-only: it is never compared and
    /// never posted (only `history.last` is posted). The confirmed subsequence must equal the server list in
    /// order, role and content; the server holding a message we do not is still a conflict.
    /// Returns the local message ids treated as local-only.
    @discardableResult static func checkServerHistory(_ remote:[[String:Any]],request:ConversationTurnRequest,strict:Bool,site:String="prepare") throws -> [UUID] {
        let previous=Array(request.history.dropLast().filter{$0.role == .user || ($0.role == .assistant && $0.toolName==nil && $0.complete)})
        func fail(_ reason:String) -> catError { logHistoryConflict(site:site,reason:reason,remote:remote,request:request,strict:strict);return catError.conflict }
        func same(_ wire:[String:Any],_ local:ConversationTranscriptMessage) -> Bool {
            guard UUID(uuidString:wire["id"] as? String ?? "")==local.id,wire["role"] as? String==local.role.rawValue,let content=wire["content"] as? String else {return false}
            return strict ? content.utf16.elementsEqual(local.content.utf16) : content == local.content
        }
        if strict {
            guard remote.count==previous.count else {throw fail("strict count")}
            for (wire,local) in zip(remote,previous) where !same(wire,local) {throw fail("strict mismatch")}
            return []
        }
        let remoteIDs=Set(remote.compactMap{UUID(uuidString:$0["id"] as? String ?? "")})
        guard remoteIDs.count==remote.count else {throw fail("server ids invalid")}
        let local=Array(request.history.dropLast())
        let confirmed=local.filter{remoteIDs.contains($0.id)}
        let shared=remote.filter{wire in confirmed.contains{$0.id==UUID(uuidString:wire["id"] as? String ?? "")}}
        for (wire,message) in zip(shared,confirmed) where !same(wire,message) {throw fail("confirmed mismatch")}
        if shared.count<remote.count {
            // Plain turns realign on the server: its messages are the authoritative history (e.g. an earlier
            // outbox turn was admitted but its server ids were never written back). Only `history.last` is posted;
            // server-side turn idempotency (turn_id == operationID) prevents a duplicate turn for this operation.
            let unknown=remote.filter{wire in !shared.contains{($0["id"] as? String)==(wire["id"] as? String)}}
            sendDiagnostic("catpaw.send history realigned op=\(request.operationID.uuidString.prefix(8)) server=\(remote.count) local=\(local.count) confirmed=\(shared.count) serverOnly=\(unknown.count)")
            if let current=request.history.last,unknown.contains(where:{$0["role"] as? String=="user" && ($0["content"] as? String)==current.content}) {
                sendDiagnostic("catpaw.send history realigned possible resend op=\(request.operationID.uuidString.prefix(8)) len=\(current.content.utf16.count)")
            }
        }
        return local.filter{!remoteIDs.contains($0.id)}.map(\.id)
    }
    private static func logHistoryConflict(site:String,reason:String,remote:[[String:Any]],request:ConversationTurnRequest,strict:Bool) {
        let localLine=request.history.map{"\($0.role.rawValue):\($0.id.uuidString.prefix(8)):\($0.complete ? "complete" : "partial")\($0.failure == nil ? "" : "+failure")\($0.toolName == nil ? "" : "+tool"):\($0.content.utf16.count)"}.joined(separator:",")
        let remoteLine=remote.map{"\($0["role"] as? String ?? "?"):\(($0["id"] as? String ?? "?").prefix(8)):\($0["status"] as? String ?? "-"):\(($0["content"] as? String)?.utf16.count ?? -1)"}.joined(separator:",")
        sendDiagnostic("catpaw.send history conflict site=\(site) reason=\(reason) strict=\(strict) op=\(request.operationID.uuidString.prefix(8)) local=[\(localLine)] server=[\(remoteLine)]")
    }
    public func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let auth: String, grant: Int, upload: URLRequest
        do { (auth, grant, upload) = try await prepare(request) }
        catch { sendDiagnostic("catpaw.send prepare refused op=\(request.operationID.uuidString.prefix(8)) category=preflight");throw ConversationDispatchFailure.notSent(reason: Self.friendlyTransportMessage(error)) }
        // NoBug P1: the busy re-POST carries this account's Authorization; it may only go out while the same account is
        // still signed in in the same epoch (captured before the first POST).
        let principal = AccountEpoch.shared.capture()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var postInitiated = false
                do {
                    try Task.checkCancellation()
                    postInitiated = true // From here a transport error cannot prove non-admission.
                    // catpaw-api v48: 503 chat_runtime_busy (up to ~60 s after a re-consent) is a refusal before admission,
                    // whatever its `retryable` flag says. Re-POST the same operation quietly with backoff; the user's
                    // bubble keeps its in-flight spinner and no error shows unless the budget runs out.
                    let (bytes, response) = try await ChatRuntimeBusyRetry.run(post: {
                        let (wire, reply) = try await self.session.bytes(for: upload)
                        guard self.purpose == .conversation, Self.supportsResume(request), let busy = reply as? HTTPURLResponse, busy.statusCode == 503 else { return (wire, reply) }
                        var body = Data(); for try await byte in wire { guard body.count < 65536 else { break }; body.append(byte) }
                        guard ChatRuntimeBusyRetry.isBusy(body) else { throw NativeChatHTTPFailure.turnResponse(503) }
                        sendDiagnostic("catpaw.send chat_runtime_busy op=\(request.operationID.uuidString.prefix(8)) quiet retry")
                        throw ChatRuntimeBusyRetry.Busy(retryAfter: ChatRuntimeBusyRetry.retryAfter(header: busy.value(forHTTPHeaderField: "Retry-After"), body: body))
                    }, sleep: ChatRuntimeBusyRetry.sleep, stillCurrent: { ChatRuntimeBusyRetry.sameAccount(principal) },
                       exhausted: { NativeChatHTTPFailure.turnResponse(503) })   // same URLRequest → same Idempotency-Key (= turn_id)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let status=(response as? HTTPURLResponse)?.statusCode ?? 0
                        if self.purpose == .parentingIntake, [404,405].contains(status) { throw ConversationDispatchFailure.notSent(reason:Self.intakeUnavailable) }
                        if status == 401 { await self.credentials.rejected(scope: request.scope) }
                        if request.continuation != nil,(response as? HTTPURLResponse)?.mimeType == "application/json",[403,409,413,422].contains(status) {
                            var errorData=Data();for try await byte in bytes {guard errorData.count<65536 else {throw ConversationSessionError.invalidEvent};errorData.append(byte)}
                            if let envelope=try? ConversationStrictJSON.object(errorData,maxBytes:65536),(try? Self.positive(envelope["schema_version"]))==1,let problem=envelope["error"] as? [String:Any],
                               Self.boolean(problem["reconciliation_required"])==false,Self.boolean(problem["retryable"])==false,let code=problem["code"] as? String,
                               Self.continuationDenials.contains(code) {throw ConversationDispatchFailure.notSent(reason:code)}
                        }
                        // A definite quota refusal (e.g. 429 model_daily_limit) proves non-admission: report it as
                        // not sent with its code so the client shows a quota notice instead of "connection lost".
                        if request.continuation == nil,(response as? HTTPURLResponse)?.mimeType == "application/json",(400...499).contains(status) {
                            var errorData=Data();for try await byte in bytes {guard errorData.count<65536 else {break};errorData.append(byte)}
                            // 413 conversation_too_long (422 history_limit_reached on older servers): nothing was written; not sent.
                            if let code=ConversationLengthLimit.code(status:status,body:errorData) {throw ConversationDispatchFailure.notSent(reason:code)}
                            if let envelope=try? JSONSerialization.jsonObject(with:errorData) as? [String:Any] {
                                let problem=(envelope["error"] as? [String:Any]) ?? envelope
                                if let code=problem["code"] as? String,ConversationTerminalServerError.isQuota(code) {throw ConversationDispatchFailure.notSent(reason:code)}
                                if status == 422,let code=problem["code"] as? String,ModelRouteSelection.rejectionCodes.contains(code) {ModelRouteNotifications.reject(code);throw ConversationDispatchFailure.notSent(reason:code)}
                            }
                        }
                        throw NativeChatHTTPFailure.turnResponse(status)
                    }
                    if http.mimeType == "application/json" {
                        var data = Data(); for try await b in bytes { guard data.count < 2_000_000 else { throw ConversationSessionError.invalidEvent }; data.append(b) }
                        let snapshot = self.purpose == .conversation && request.continuation == nil && request.acceptedWork==nil ? try Self.object(JSONSerialization.jsonObject(with: data)) : try ConversationStrictJSON.object(data,maxBytes:2_000_000); try Self.turnEnvelope(snapshot,request:request)
                        let turn = try Self.object(snapshot["turn"]);try self.validatePurpose(turn);try Self.validateImageSnapshot(turn,request:request);try Self.validateContinuationSnapshot(turn,request:request,scope:self.configuration.serverScopeID,grant:grant)
                        try ConversationAcceptedWorkCodec.validateOriginal(turn,request:request);try validateRevisionWorkOriginal(turn,request:request)
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
                                if let wire=try Self.sseEventLine(line,strict:request.continuation != nil || request.acceptedWork != nil) {continuation.yield(try await self.decode(wire, request:request, grant:grant, auth:auth, livePreviews:true))}
                                line.removeAll(keepingCapacity:true);afterCR=byte==0x0d
                            } else {
                                guard line.count<262144 else {throw ConversationSessionError.invalidEvent};line.append(byte)
                            }
                        }
                        guard line.isEmpty else {throw ConversationSessionError.invalidEvent}
                    }
                    continuation.finish() // EOF is never synthesized into completion.
                } catch {
                    // A broken plain-chat stream after POST is resumable by GET-after-sequence (R7 §5.3).
                    let resumable = postInitiated && error is URLError && Self.supportsResume(request)
                    let failure: Error = resumable ? ConversationStreamInterrupted(reason: Self.friendlyTransportMessage(error))
                        : error is URLError
                        ? catError.unavailable(Self.friendlyTransportMessage(error) + (postInitiated ? "本轮发送结果尚未确认；请读取原请求状态，不要重新发送。" : ""))
                        : error
                    continuation.finish(throwing: postInitiated ? failure : ConversationDispatchFailure.notSent(reason: failure.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() } // detaches observation only
        }
    }
    static func supportsResume(_ r: ConversationTurnRequest) -> Bool { r.continuation == nil && r.acceptedWork == nil && r.revisionWork == nil }
    /// R7 §5.3: reattach to the original turn with `GET …/turns/{id}/events?after_sequence=N`.
    /// Idle timeout is 15 s; the Edge sends `: keepalive` every 10 s.
    public func resumeEvents(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        try await originalTurnStream(request, afterSequence: afterSequence, busyRestart: false)
    }
    /// R7 busy retry: `POST …/turns/{id}/retry-busy` restarts the SAME turn (same operationID and user
    /// message) when the Edge recorded `failed{rate_limited}` before any output; events continue the sequence.
    public func retryBusyTurn(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        try await originalTurnStream(request, afterSequence: afterSequence, busyRestart: true)
    }
    /// R2 stop: `POST …/chat/v1/…/turns/{id}/cancel` with `{}`; the caller may resend on `.transport`.
    public func cancelTurn(_ request: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt {
        let auth: String
        do { auth = try await authorization(request.scope) } catch { throw ConversationTurnCancelFailure.rejected(status: 401) }
        let route = path(request) + "/turns/" + request.operationID.uuidString.lowercased() + "/cancel"
        let reply: [String: Any]
        do { reply = try await json(route, auth: auth, body: [:], timeout: 15) }
        catch NativeChatHTTPFailure.status(let status) {
            if status == 404 { throw ConversationTurnCancelFailure.notFound }
            if status == 0 || status == 408 || status == 429 || status >= 500 { throw ConversationTurnCancelFailure.transport }
            throw ConversationTurnCancelFailure.rejected(status: status)
        }
        catch is URLError { throw ConversationTurnCancelFailure.transport }
        catch is CancellationError { throw CancellationError() }
        catch { throw ConversationTurnCancelFailure.rejected(status: 200) }
        guard (try? Self.chatEnvelope(reply)) != nil, let cancel = reply["cancel"] as? [String: Any],
              UUID(uuidString: cancel["turn_id"] as? String ?? "") == request.operationID,
              let state = cancel["state"] as? String, ["failed", "completed", "outcome_unknown", "running"].contains(state),
              let cancelled = Self.boolean(cancel["cancelled"]), let terminal = Self.boolean(cancel["already_terminal"]) else { throw ConversationTurnCancelFailure.rejected(status: 200) }
        try validatePurpose(cancel)
        return ConversationTurnCancelReceipt(turnID: request.operationID, state: state, cancelled: cancelled, alreadyTerminal: terminal)
    }
    static let approvalContract = "catpaw.approval.v1"
    static let approvalHeader = "X-Catpaw-Approval-Contract"
    static let timeZoneHeader = "X-Catpaw-Time-Zone"
    /// fix/context-window-v11x (59b5aae6): opt in to live-only `text_preview` frames on every request whose response is the
    /// plain turn SSE (POST turns, GET events, retry-busy, approval/device decisions). Servers without it ignore the header.
    static let liveTextHeader = "X-Catpaw-Live-Text"
    static func requestLiveText(_ request: inout URLRequest) { request.setValue("1", forHTTPHeaderField: liveTextHeader) }
    /// One content-free diagnostic per turn for dropped previews (reason token only; never text or ids beyond the op prefix).
    private func noteDroppedLivePreview(_ operationID: UUID, reason: String) {
        if livePreviewDropLogged.count > 256 { livePreviewDropLogged.removeAll() }
        guard livePreviewDropLogged.insert(operationID).inserted else { return }
        sendDiagnostic("catpaw.live preview dropped op=\(operationID.uuidString.prefix(8)) reason=\(reason)")
    }
    /// Model realities a preview may carry (same set as the strict check in `decode`, minus `not_configured`).
    private func acceptsLiveReality(_ reality: String?) -> Bool {
        reality == "provider_unverified" || (configuration.allowInjectedTestProvider && (reality == "injected_test_provider" || (reality == "injected_offline_only" && configuration.origin.scheme=="http" && configuration.origin.host=="127.0.0.1"))) || (configuration.useFrozenFixtureMetadata && reality == "injected_synthetic_fixture")
    }
    /// The dropped form of a preview: `ConversationSessionService.isLivePreview` discards it before the journal and the
    /// sequence checks, and it is never emitted to observers.
    static func droppedLivePreview(_ request: ConversationTurnRequest) -> ConversationTurnEvent {
        ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: 0, payload: .sideChannel(type: "text_preview", data: Data()), conversationID: request.conversationID, turnID: request.operationID)
    }
    /// 三角 (prod v53): a `text_preview` with sequence < 1, a scope/conversation/turn/grant/cursor mismatch, an unexpected
    /// model reality, a non-plain turn or bad data is DROPPED, never a turn failure. Message-id pinning (one assistant
    /// message per turn) happens in AnswerPhaseProjection.
    static func livePreviewEvent(_ wire: [String: Any], request: ConversationTurnRequest, scopeID: UUID, grant: Int, realityAccepted: Bool) -> ConversationTurnEvent {
        livePreviewDecode(wire, request: request, scopeID: scopeID, grant: grant, realityAccepted: realityAccepted).event
    }
    /// Same as `livePreviewEvent`, plus a content-free drop reason (an enum-like token, never text) for the diagnostic.
    static func livePreviewDecode(_ wire: [String: Any], request: ConversationTurnRequest, scopeID: UUID, grant: Int, realityAccepted: Bool) -> (event: ConversationTurnEvent, dropReason: String?) {
        func drop(_ reason: String) -> (event: ConversationTurnEvent, dropReason: String?) { (droppedLivePreview(request), reason) }
        guard realityAccepted else { return drop("reality") }
        guard supportsResume(request) else { return drop("not_plain_turn") }
        guard (try? chatEnvelope(wire)) != nil else { return drop("envelope") }
        guard let sequence = try? positive(wire["sequence"]) else { return drop("sequence") }
        guard UUID(uuidString: wire["scope_id"] as? String ?? "") == scopeID else { return drop("scope") }
        guard UUID(uuidString: wire["conversation_id"] as? String ?? "") == request.conversationID else { return drop("conversation") }
        guard UUID(uuidString: wire["turn_id"] as? String ?? "") == request.operationID else { return drop("turn") }
        guard (try? positive(wire["grant_epoch"])) == grant else { return drop("grant") }
        guard wire["cursor"] as? String == request.operationID.uuidString.lowercased() + ":\(sequence)" else { return drop("cursor") }
        guard let data = wire["data"] as? [String: Any], let preview = textPreview(data, sequence: sequence) else { return drop("data") }
        return (ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: sequence, payload: .textPreview(preview), conversationID: request.conversationID, turnID: request.operationID), nil)
    }
    /// `text_preview.data` → preview, or nil when the frame is not mergeable. A bad preview is dropped (no transcript
    /// effect), never a turn failure: it is advisory and the persisted `text_delta` batches carry the same text.
    static func textPreview(_ data: [String: Any], sequence: Int) -> ConversationTextPreview? {
        guard boolean(data["live"]) == true, let id = UUID(uuidString: data["message_id"] as? String ?? ""), let text = data["text"] as? String,
              let offset = data["offset"] as? NSNumber, CFGetTypeID(offset) != CFBooleanGetTypeID(), offset.doubleValue >= 0,
              offset.doubleValue.rounded() == offset.doubleValue, offset.doubleValue <= Double(Int32.max),
              let base = try? positive(data["base_sequence"]), base == sequence else { return nil }
        return ConversationTextPreview(messageID: id, offset: offset.intValue, text: text, baseSequence: base)
    }
    /// Tools that only exist on approval-negotiated plain turns (services/edge TOOL_APPROVAL).
    static let approvalToolNames: Set<String> = ["render_ui", "list_tasks", "create_task", "update_task", "create_calendar_event", "update_calendar_event", "create_reminder", "update_reminder", "external_write",
        // catpaw.device.v1 (executed on this phone; services/edge/supabase/functions/_shared/core/src/device-call.mjs)
        "calendar_list", "calendar_create", "reminder_create", "mail_compose", "sms_compose", "phone_call", "contacts_search", "maps_open", "shop_open", "alarm_set", "shortcut_run",
        // Acceptance #3: places_search (附近咖啡馆 starter) was advertised in X-cat-Device-Tools but missing here, so its
        // `tool_call` failed ConversationSessionService.apply → invalidEvent (「服务返回了不匹配的对话或工具结果」).
        // Must stay a superset of DeviceToolContract.clientTools (DeviceToolNamesContractTests).
        "places_search",
        // NoBug harness review §4.6: catpaw.agent-memory.v1 tools are server-registered gated chat tools (api.mjs gatedChatTools,
        // agent-memory/contract.mjs MEMORY_TOOLS), offered only on approval.v1 turns with memory on. Missing here, any memory
        // tool_call failed apply → invalidEvent (「服务返回了不匹配的对话或工具结果」). Server-executed; see memoryToolApproval.
        "memory_search", "memory_save", "memory_update", "memory_forget"]
    /// catpaw.approval.v1 classification of the agent-memory tools, mirroring services/…/core/src/tools.mjs TOOL_APPROVAL
    /// (true = the server suspends with `approval_requested` before executing; false = runs automatically, reversible via
    /// undo / Settings › 记忆). iOS never executes these; the approval card is driven by the server's interrupt.
    static let memoryToolApproval: [String: Bool] = ["memory_search": false, "memory_save": false, "memory_update": false, "memory_forget": true]
    /// Snapshot `pending_approvals`: kind "ui" rows are catpaw.ui.v1 blocks, everything else a tool approval card.
    public static func splitPendingApprovals(_ rows: [[String: Any]]) throws -> (tools: [ConversationApprovalRequest], ui: [ConversationUIApproval]) {
        var tools: [ConversationApprovalRequest] = [], ui: [ConversationUIApproval] = []
        for row in rows {
            if row["kind"] as? String == "device" { continue } // restored from the replayed `device_call` event, never an approval card
            if row["kind"] as? String == "ui" { ui.append(try ConversationUIApproval.decode(row)) } else { tools.append(try approval(row)) }
        }
        return (tools, ui)
    }
    static func approval(_ raw: [String: Any]) throws -> ConversationApprovalRequest {
        guard let id = raw["interrupt_id"] as? String, UUID(uuidString: id) != nil, let call = raw["call_id"] as? String, !call.isEmpty, call.utf8.count <= 256,
              let tool = raw["tool"] as? String, opaque(tool), let summary = raw["summary"] as? String, summary.count <= 240,
              let hash = try? sha(raw["args_hash"]), let expires = raw["expires_at"] as? String, let risk = raw["risk"] as? String,
              let remember = boolean(raw["remember_allowed"]) else { throw ConversationSessionError.invalidEvent }
        let arguments = String(decoding: try jsonData((raw["arguments"] as? [String: Any]) ?? [:]), as: UTF8.self)
        return ConversationApprovalRequest(interruptID: id, callID: call, tool: tool, summary: summary, arguments: arguments, argsHash: hash, expiresAt: expires, risk: risk, rememberAllowed: remember)
    }
    /// catpaw.approval.v1 decision. Idempotent on `operationID`: resend the SAME id after `.transport`.
    public func submitApproval(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationApprovalDecision, argsHash: String, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        try await decisionStream(request, interruptID: interruptID, afterSequence: afterSequence, body: ["operation_id": operationID.uuidString.lowercased(), "decision": decision.rawValue, "args_hash": argsHash])
    }
    /// catpaw.ui.v1 answer: the SAME approval.v1 decision route; `response` is the raw `ui.response` (submit) or `ui.error` (report_error) JSON object.
    public func submitUIDecision(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        var body: [String: Any] = ["operation_id": operationID.uuidString.lowercased(), "decision": decision.rawValue, "args_hash": argsHash]
        switch decision {
        case .dismiss: guard response == nil else { throw ConversationApprovalFailure.rejected(status: 422, code: "ui_response_invalid") }
        case .submit, .reportError:
            guard let response, response.count <= 32768, let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
                  object["type"] as? String == (decision == .submit ? "ui.response" : "ui.error") else { throw ConversationApprovalFailure.rejected(status: 422, code: "ui_response_invalid") }
            body["response"] = object
        }
        return try await decisionStream(request, interruptID: interruptID, afterSequence: afterSequence, body: body)
    }
    /// catpaw.device.v1 result. Idempotent on `operationID` (resend the SAME id after `.transport`); bound to the call's `args_hash`.
    public func submitDeviceResult(_ request: ConversationTurnRequest, call: ConversationDeviceCall, status: String, data: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        guard ConversationDeviceCall.statuses.contains(status) else { throw ConversationApprovalFailure.rejected(status: 422, code: "device_result_schema_invalid") }
        var body: [String: Any] = ["call_id": call.callID, "operation_id": operationID.uuidString.lowercased(), "args_hash": call.argsHash, "status": status]
        if let data {
            guard data.count <= 32000, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ConversationApprovalFailure.rejected(status: 422, code: "device_result_schema_invalid") }
            body["data"] = object
        }
        return try await decisionStream(request, interruptID: call.interruptID, afterSequence: afterSequence, body: body, deviceResult: true)
    }
    public func submitDeviceUndo(_ request: ConversationTurnRequest, callID: String, outcome: DeviceUndoOutcome, operationID: UUID) async throws {
        let auth: String
        do { auth = try await authorization(request.scope) } catch { throw ConversationApprovalFailure.rejected(status: 401, code: nil) }
        let route = path(request) + "/turns/" + request.operationID.uuidString.lowercased() + "/device-undo"
        do { _ = try await json(route, auth: auth, body: DeviceUndoRules.body(callID: callID, outcome: outcome, operationID: operationID), timeout: 15) }
        catch NativeChatHTTPFailure.status(let status) {
            if status == 0 || status == 408 || status == 429 || status >= 500 { throw ConversationApprovalFailure.transport }
            throw ConversationApprovalFailure.rejected(status: status, code: nil)
        }
        catch is URLError { throw ConversationApprovalFailure.transport }
    }
    private func decisionStream(_ request: ConversationTurnRequest, interruptID: String, afterSequence: Int, body decisionBody: [String: Any], deviceResult: Bool = false) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        guard Self.supportsResume(request), afterSequence >= 0, UUID(uuidString: interruptID) != nil else { throw ConversationApprovalFailure.unsupported }
        let auth: String
        do { auth = try await authorization(request.scope) } catch { throw ConversationApprovalFailure.rejected(status: 401, code: nil) }
        let grant: Int
        do { grant = try Self.positive(try await readConversation(request, auth: auth, mayCreate: false)["grant_epoch"]) }
        catch is URLError { throw ConversationApprovalFailure.transport }
        let route = turnPath(request) + "/" + request.operationID.uuidString.lowercased() + (deviceResult ? "/device-result" : "/interrupts/" + interruptID.lowercased() + "/decision") + "?after_sequence=\(afterSequence)"
        var post = try self.request(route, auth: auth)
        post.httpMethod = "POST"; post.timeoutInterval = ConversationReconnectPolicy.idleTimeout; post.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept"); post.setValue(TimeZone.current.identifier, forHTTPHeaderField: Self.timeZoneHeader); post.setValue(ConversationMemorySwitch.headerValue, forHTTPHeaderField: ConversationMemorySwitch.header)
        post.httpBody = try Self.jsonData(decisionBody); Self.requestLiveText(&post)
        let opened: (URLSession.AsyncBytes, URLResponse)
        do { opened = try await session.bytes(for: post) } catch is URLError { throw ConversationApprovalFailure.transport }
        let bytes = opened.0, response = opened.1
        guard let http = response as? HTTPURLResponse else { throw ConversationApprovalFailure.transport }
        guard http.statusCode == 200, http.mimeType == "text/event-stream" else {
            if http.statusCode == 401 { await credentials.rejected(scope: request.scope) }
            var data = Data(); for try await byte in bytes { guard data.count < 65536 else { break }; data.append(byte) }
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["code"] as? String }
            switch (http.statusCode, code ?? "") {
            case (404, _): throw ConversationApprovalFailure.notFound
            case (409, "approval_expired"): throw ConversationApprovalFailure.expired
            case (409, "approval_consumed"): throw ConversationApprovalFailure.consumed
            case (409, "approval_stale"): throw ConversationApprovalFailure.stale
            case (let status, _) where status == 0 || status == 408 || status == 429 || status >= 500: throw ConversationApprovalFailure.transport
            default: throw ConversationApprovalFailure.rejected(status: http.statusCode, code: code)
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var line = Data(), afterCR = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if afterCR { afterCR = false; if byte == 0x0a { continue } }
                        if byte == 0x0a || byte == 0x0d {
                            if let wire = try Self.sseEventLine(line) { continuation.yield(try await self.decode(wire, request: request, grant: grant, auth: auth, livePreviews: true)) }
                            line.removeAll(keepingCapacity: true); afterCR = byte == 0x0d
                        } else { guard line.count < 262144 else { throw ConversationSessionError.invalidEvent }; line.append(byte) }
                    }
                    continuation.finish()
                } catch {
                    // The decision is committed once the 200 arrived; a broken stream resumes by GET-after-sequence.
                    continuation.finish(throwing: error is URLError ? ConversationStreamInterrupted(reason: Self.friendlyTransportMessage(error)) : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func originalTurnStream(_ request: ConversationTurnRequest, afterSequence: Int, busyRestart: Bool) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        guard Self.supportsResume(request), afterSequence >= 0 else { throw ConversationSessionError.unresolvedOperation }
        let auth = try await authorization(request.scope)
        let grant: Int
        do { grant = try Self.positive(try await readConversation(request, auth: auth, mayCreate: false)["grant_epoch"]) }
        catch let network as URLError { throw ConversationStreamInterrupted(reason: Self.friendlyTransportMessage(network)) }
        let original = turnPath(request) + "/" + request.operationID.uuidString.lowercased()
        var get = try self.request(busyRestart ? original + "/retry-busy" : original + "/events?after_sequence=\(afterSequence)", auth: auth)
        get.httpMethod = busyRestart ? "POST" : "GET"; get.timeoutInterval = ConversationReconnectPolicy.idleTimeout; get.setValue("text/event-stream", forHTTPHeaderField: "Accept"); if Self.supportsResume(request) { Self.requestLiveText(&get) }   // plain chat turns only (also guarded above)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await self.session.bytes(for: get)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.mimeType == "text/event-stream" else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 { await self.credentials.rejected(scope: request.scope) }
                        // A definite refusal (409/429) means the original failed turn was not restarted.
                        if busyRestart, [404, 409, 429].contains(status) { throw catError.unavailable("这条消息暂时无法重试。") }
                        throw ConversationStreamInterrupted(reason: "暂时无法读取原回复。")
                    }
                    var line = Data(), afterCR = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if afterCR { afterCR = false; if byte == 0x0a { continue } }
                        if byte == 0x0a || byte == 0x0d {
                            if let wire = try Self.sseEventLine(line) { continuation.yield(try await self.decode(wire, request: request, grant: grant, auth: auth, livePreviews: true)) }
                            line.removeAll(keepingCapacity: true); afterCR = byte == 0x0d
                        } else { guard line.count < 262144 else { throw ConversationSessionError.invalidEvent }; line.append(byte) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is URLError ? ConversationStreamInterrupted(reason: Self.friendlyTransportMessage(error)) : error)
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
        if purpose == .parentingIntake {
            guard request.image == nil, !request.hasUploadedAttachments, request.continuation == nil,
                  request.acceptedWork == nil, request.revisionWork == nil, request.context.isEmpty,
                  request.history.count == 1, request.history.first?.role == .user else { throw ConversationSessionError.invalidEvent }
        }
        let auth = try await authorization(request.scope)
        try Task.checkCancellation()
        if let intent=request.acceptedWork {
            try acceptedWorkContext(request)
            let capability=try await acceptedWorkCapability(scope:request.scope,conversationID:request.conversationID);try Task.checkCancellation()
            try intent.selection.validate(capability:capability,now:acceptedWorkClock())
        }
        if let intent=request.revisionWork {
            try revisionWorkContext(request)
            let capability=try await revisionWorkCapability(scope:request.scope,conversationID:request.conversationID);try Task.checkCancellation();try intent.validateForFirstPost(request:request,capability:capability,now:acceptedWorkClock())
            try await validateRevisionWorkPolicy(request,selection:intent.selection,auth:auth);try Task.checkCancellation()
        }
        if request.continuation != nil {
            try continuationContext(request)
            if request.revisionWork==nil {guard try await continuationAvailability(request,auth:auth) else {throw ConversationArtifactContinuationError.unsupported}}
            _=try await confirmedContinuationBinding(request,auth:auth)
            continuationSourceHashes[request.operationID]=try await continuationBase(request,inspectCurrent:true)
        }
        let conversation = try await readConversation(request, auth: auth, mayCreate: request.continuation == nil && request.acceptedWork==nil,strict:request.acceptedWork != nil || request.revisionWork != nil)
        try Task.checkCancellation()
        let revision = try Self.positive(conversation["revision"]), grant = try Self.positive(conversation["grant_epoch"])
        if let intent=request.acceptedWork {guard revision==intent.expectedRevision,grant==intent.expectedGrantEpoch else {throw ConversationAcceptedWorkError.changedSnapshot};try validateHistory(conversation,request:request)}
        if let intent=request.revisionWork {guard revision==intent.expectedRevision,grant==intent.expectedGrantEpoch else {throw ConversationAcceptedWorkError.changedSnapshot};try validateHistory(conversation,request:request)}
        try Self.checkServerHistory(try Self.array(conversation["messages"]),request:request,strict:request.acceptedWork != nil || request.revisionWork != nil || request.continuation != nil)
        if let intent=request.acceptedWork {
            try intent.selection.options.validate(now:acceptedWorkClock())
            var upload=try self.request(turnPath(request),auth:auth);upload.httpMethod="POST";upload.httpBody=try intent.wrapper()
            try Task.checkCancellation();return (auth,grant,upload)
        }
        if let intent=request.revisionWork {
            try intent.selection.options.validate(now:acceptedWorkClock())
            var upload=try self.request(turnPath(request),auth:auth);upload.httpMethod="POST";upload.httpBody=try intent.wrapper();try Task.checkCancellation();return (auth,grant,upload)
        }
        guard let message = request.history.last, message.role == .user else { throw ConversationSessionError.invalidEvent }
        var body: [String: Any] = ["turn_id": request.operationID.uuidString.lowercased(), "expected_revision": revision, "expected_grant_epoch": grant,
                                 "message": ["id": message.id.uuidString.lowercased(), "text": message.content], "context": request.context.map { ["id": $0.id, "text": $0.text] }]
        guard try Self.jsonData(body).count <= 40000 else {throw catError.invalid("本轮上下文超过后台请求上限。")}
        if let image=request.image {
            guard configuration.publishableKey != nil,let imageBytes=request.imageBytes else {throw ConversationSessionError.notConfigured}
            let capability=try await imageCapabilities(scope:request.scope,conversationID:request.conversationID)
            guard capability.available,capability.liveTransmissionAvailable,capability.routeHash==image.routeHash else {throw ConversationSessionError.notConfigured}
            guard try await modelConsent(scope:request.scope,conversationID:request.conversationID)==nil else {throw ConversationSessionError.notConfigured}
            let row=try Self.imageConsentRow(try await json(imageConsentPath(request.conversationID),auth:auth)["consent"])
            guard row.scope_id==configuration.serverScopeID,row.conversation_id==request.conversationID,row.decision=="allow",row.non_sensitive_confirmed,row.route_hash==image.routeHash,row.revision==image.consentRevision else {throw ConversationSessionError.notConfigured}
            body["schema_version"]=2;body["message"]=["id":message.id.uuidString.lowercased(),"text":message.content,"attachments":[try image.wire(imageBytes,messageID:message.id)]]
        } else {guard request.imageBytes==nil else {throw ConversationSessionError.invalidEvent}}
        if let ids=request.attachmentIDs,!ids.isEmpty {
            // catpaw.chat-attachments.v1 §4: uploaded ids instead of inline bytes; plain turns only, never mixed with `attachments`.
            guard request.image==nil,request.imageBytes==nil,request.continuation==nil,request.acceptedWork==nil,request.revisionWork==nil,ids.count<=1,Set(ids).count==ids.count, // server VISION_LIMITS.max_count
                  !message.content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw ConversationSessionError.invalidEvent}
            body["schema_version"]=2;body["message"]=ChatAttachmentUploader.turnMessage(id:message.id,text:message.content,ids:ids)
        }
        let bytes=try Self.jsonData(body);guard bytes.count <= (request.image==nil ? 40000 : 7_100_000) else {throw catError.invalid("本轮上下文超过后台请求上限。")}

        let encoded:Data
        if let target=request.continuation {guard request.image==nil,request.imageBytes==nil else {throw ConversationSessionError.invalidEvent};encoded=try Self.jsonData(["turn":body,"target":target.canonicalValue]);guard encoded.count<=48000 else {throw ConversationSessionError.invalidEvent}}
        else {encoded=bytes}
        var upload = try self.request(turnPath(request), auth: auth); upload.httpMethod = "POST"; upload.httpBody = encoded
        upload.setValue(request.operationID.uuidString.lowercased(),forHTTPHeaderField:"Idempotency-Key") // #63: alias of turn_id (must match)
        if purpose == .conversation,request.image==nil,!request.hasUploadedAttachments,request.continuation==nil,request.acceptedWork==nil {upload.setValue(ConversationMemoryProposalReceipt.contractName,forHTTPHeaderField:"X-Catpaw-Memory-Proposal-Contract")}
        // catpaw.approval.v1 negotiation: only plain chat turns are offered approval-gated tools.
        if purpose == .conversation,Self.supportsResume(request),request.image==nil,!request.hasUploadedAttachments {upload.setValue(Self.approvalContract,forHTTPHeaderField:Self.approvalHeader);upload.setValue(ConversationUIEvent.contract,forHTTPHeaderField:ConversationUIEvent.header);upload.setValue(ConversationUIEvent.kindsHeaderValue,forHTTPHeaderField:ConversationUIEvent.kindsHeader);if ConversationDeviceCall.clientEnabled {upload.setValue(ConversationDeviceCall.contract,forHTTPHeaderField:ConversationDeviceCall.header);if !ConversationDeviceCall.clientTools.isEmpty {upload.setValue(ConversationDeviceCall.clientTools.joined(separator:","),forHTTPHeaderField:ConversationDeviceCall.toolsHeader)}}}
        upload.setValue(TimeZone.current.identifier,forHTTPHeaderField:Self.timeZoneHeader);upload.setValue(ConversationMemorySwitch.headerValue,forHTTPHeaderField:ConversationMemorySwitch.header) // task tools resolve local times
        if purpose == .parentingIntake {
            upload.setValue("0", forHTTPHeaderField: ConversationMemorySwitch.header)
            upload.setValue("ephemeral", forHTTPHeaderField: "X-Catpaw-Memory-Mode")
        }
        if purpose == .conversation,Self.supportsResume(request) {Self.requestLiveText(&upload)}
        try Task.checkCancellation()
        return (auth, grant, upload)
    }
    public func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        if request.acceptedWork != nil {try acceptedWorkContext(request)}
        if request.revisionWork != nil {try revisionWorkContext(request)}
        let auth = try await authorization(request.scope)
        try Task.checkCancellation()
        let conversation = try await readConversation(request, auth: auth, mayCreate: false,strict:request.acceptedWork != nil || request.revisionWork != nil)
        try Task.checkCancellation()
        let currentGrant = try Self.positive(conversation["grant_epoch"])
        if request.continuation != nil {try continuationContext(request);_=try await confirmedContinuationBinding(request,auth:auth);continuationSourceHashes[request.operationID]=try await continuationBase(request,inspectCurrent:false)}
        let wrapper = try await json(turnPath(request) + "/" + request.operationID.uuidString.lowercased(), auth: auth)
        try Self.turnEnvelope(wrapper,request:request)
        let turn = try Self.object(wrapper["turn"]);try validatePurpose(turn);try Self.validateImageSnapshot(turn,request:request);try Self.validateContinuationSnapshot(turn,request:request,scope:configuration.serverScopeID,grant:currentGrant)
        try ConversationAcceptedWorkCodec.validateOriginal(turn,request:request);try validateRevisionWorkOriginal(turn,request:request)
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
        for b in bindings where seen.insert(b.task_id).inserted { goals.append(try await projection(b, title: title(b.call_id, turnID: b.turn_id, history: request.history), auth: auth)) }
        if request.continuation != nil {try validateContinuationList(turn["continuations"],request:request,terminal:turn["state"] as? String=="completed");try validateRevisionWorkList(turn["revision_work_receipts"],request:request)}
        let rows = try (turn["pending_approvals"] as? [Any] ?? []).map { try Self.object($0) }
        let pending = try Self.splitPendingApprovals(rows)
        var observation = ConversationObservation(request: request, events: events, requestHash: try Self.sha(turn["request_hash"]), grantEpoch: currentGrant, goals: goals, pendingApprovals: pending.tools, serverState: turn["state"] as? String, pendingUIApprovals: pending.ui)
        observation.interactionOutcomes = ConversationServerOutcome.parse(conversation["interaction_outcomes"])   // P1-4
        return observation
    }
    private func readConversation(_ value: ConversationTurnRequest, auth: String, mayCreate: Bool,strict:Bool=false) async throws -> [String: Any] {
        var wrapper: [String: Any]
        do { wrapper = try await json(path(value), auth: auth,strict:strict) }
        catch NativeChatHTTPFailure.status(404) where mayCreate {
            if strict {try Task.checkCancellation()}
            wrapper = try await json(scopePath + "/conversations", auth: auth, body: ["conversation_id": value.conversationID.uuidString.lowercased()],strict:strict)
        }
        try Self.chatEnvelope(wrapper); let c = try Self.object(wrapper["conversation"])
        try validatePurpose(c)
        if strict {guard c["subject_id"] as? String==configuration.expectedSubjectID?.uuidString.lowercased() else {throw ConversationSessionError.invalidEvent}}
        guard UUID(uuidString: c["id"] as? String ?? "") == value.conversationID, UUID(uuidString: c["scope_id"] as? String ?? "") == configuration.serverScopeID,
              c["state"] as? String == "active", c["policy"] as? String == "conversation-local-output-v1" else { throw ConversationSessionError.invalidEvent }
        return c
    }
    private func decode(_ wire: [String: Any], request: ConversationTurnRequest, grant: Int, auth: String, livePreviews: Bool = false) async throws -> ConversationTurnEvent {
        try validatePurpose(wire)
        if purpose == .parentingIntake {
            guard let type = wire["type"] as? String,
                  ["turn_started", "text_delta", "turn_completed", "turn_failed", "model_route", "reasoning_summary"].contains(type) else { throw ConversationSessionError.invalidEvent }
        }
        if wire["type"] as? String == "text_preview" {
            // Previews are never stored: inside a JSON snapshot or a read-back `events` array one means a broken server.
            guard livePreviews else { throw ConversationSessionError.invalidEvent }
            // Live SSE only: bypass the strict envelope checks below (which would fail the turn); anything off is dropped.
            let decoded = Self.livePreviewDecode(wire, request: request, scopeID: configuration.serverScopeID, grant: grant, realityAccepted: acceptsLiveReality(wire["model_reality"] as? String))
            if let reason = decoded.dropReason { noteDroppedLivePreview(request.operationID, reason: reason) }
            return decoded.event
        }
        try Self.chatEnvelope(wire)
        let sequence = try Self.positive(wire["sequence"])
        guard UUID(uuidString: wire["scope_id"] as? String ?? "") == configuration.serverScopeID,
              UUID(uuidString: wire["conversation_id"] as? String ?? "") == request.conversationID,
              UUID(uuidString: wire["turn_id"] as? String ?? "") == request.operationID,
              try Self.positive(wire["grant_epoch"]) == grant,
              wire["cursor"] as? String == request.operationID.uuidString.lowercased() + ":\(sequence)" else { throw ConversationSessionError.invalidEvent }
        let reality = wire["model_reality"] as? String
        guard reality == "provider_unverified" || reality == "not_configured" || (configuration.allowInjectedTestProvider && (reality == "injected_test_provider" || (reality == "injected_offline_only" && configuration.origin.scheme=="http" && configuration.origin.host=="127.0.0.1"))) || (configuration.useFrozenFixtureMetadata && reality == "injected_synthetic_fixture") else { throw ConversationSessionError.invalidEvent }
        observedModelState = reality == "not_configured" ? .notConfigured : .providerUnverified
        let data = try Self.object(wire["data"]), type = wire["type"] as? String
        let payload: ConversationTurnEvent.Payload
        var retryAfter: Int? = nil
        switch type {
        case "turn_started":
            let receipts:[ConversationImageReceipt]?
            if let raw=data["attachment_receipts"] {receipts=try JSONDecoder().decode([ConversationImageReceipt].self,from:Self.jsonData(raw))} else {receipts=nil}
            if let image=request.image {guard receipts==[image.receipt] else {throw ConversationSessionError.invalidEvent}} else if let ids=request.attachmentIDs,!ids.isEmpty {guard let receipts,receipts.map(\.id)==ids else {throw ConversationSessionError.invalidEvent}} else {guard receipts==nil || receipts?.isEmpty==true else {throw ConversationSessionError.invalidEvent}}
            payload = .started(requestHash: try Self.sha(data["request_hash"]), conversationRevision: try Self.positive(data["conversation_revision"]), grantEpoch: grant,attachmentReceipts:receipts)
        case "text_delta":
            guard reality != "not_configured", let id = UUID(uuidString: data["message_id"] as? String ?? ""), let text = data["text"] as? String else { throw ConversationSessionError.invalidEvent }
            payload = .textDelta(messageID: id, text: text)
        case "reasoning_summary":
            guard let id = UUID(uuidString: data["message_id"] as? String ?? ""), let text = data["text"] as? String, text.utf8.count <= 8000 else { throw ConversationSessionError.invalidEvent }
            let ms = (data["thinking_ms"] as? NSNumber).map { $0.intValue }
            payload = .reasoningSummary(messageID: id, text: text, thinkingMs: ms.flatMap { $0 >= 0 ? $0 : nil })
        case "tool_call":
            guard request.image==nil,!request.hasUploadedAttachments else {throw ConversationSessionError.invalidEvent}
            guard reality != "not_configured", let name = data["name"] as? String, ((["delegate_task", "delegate_plan_v1", "delegate_sources_v1", "agent_status", "propose_memory_v1"].contains(name) && request.continuation==nil) || (Self.approvalToolNames.contains(name) && Self.supportsResume(request)) || (name==(request.revisionWork==nil ? "revise_current_report_v1":ConversationRevisionWorkCodec.toolName) && request.continuation?.intent == .reviseReport)), let id = data["call_id"] as? String, !id.isEmpty else { throw ConversationSessionError.invalidEvent }
            if ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains(name), let args = data["arguments"] as? [String: Any], let title = args["title"] as? String, title.utf16.count <= 160 { toolTitles[request.operationID, default: [:]][id] = title }
            payload = .toolStarted(callID: id, name: name, arguments: String(decoding: try Self.jsonData(Self.object(data["arguments"])), as: UTF8.self))
        case "tool_result":
            guard request.image==nil,!request.hasUploadedAttachments else {throw ConversationSessionError.invalidEvent}
            guard reality != "not_configured", let name = data["name"] as? String, let call = data["call_id"] as? String, !call.isEmpty else { throw ConversationSessionError.invalidEvent }
            let result = try Self.object(data["result"]); var goals: [ConversationGoalProjection] = []
            var memoryProposal:ConversationMemoryProposalReceipt?
            if ["delegate_task", "delegate_plan_v1", "delegate_sources_v1"].contains(name) {
                let b = try binding(result, request: request, currentTurn: true); guard b.call_id == call, b.grant_epoch == grant else { throw ConversationSessionError.invalidEvent }
                if let known = bindingCache[request.operationID]?[call] { guard known == b else { throw ConversationSessionError.invalidEvent } }
                let goal = try await projection(b, title: title(call, turnID: b.turn_id, history: request.history), auth: auth)
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
                    if let b = known.first(where: { UUID(uuidString: run["id"] as? String ?? "") == $0.run_id && run["request_hash"] as? String == $0.request_hash }) { goals.append(try await projection(b, title: title(b.call_id, turnID: b.turn_id, history: request.history), auth: auth, supplied: row)) }
                }
            } else if name=="revise_current_report_v1" || name==ConversationRevisionWorkCodec.toolName {
                let receipt:ConversationTaskRevisionReceipt
                if let intent=request.revisionWork {
                    guard name==ConversationRevisionWorkCodec.toolName else {throw ConversationSessionError.invalidEvent}
                    let outer=try ConversationRevisionWorkReceipt.decode(Self.jsonData(result));try outer.validate(request:request,intent:intent,callID:call,sourceAuthHash:continuationSourceHashes[request.operationID])
                    _=try await confirmedRevisionWorkEnvelope(outer,request:request,auth:auth)
                    if let prior=revisionWorkReceipts[request.operationID]?[call] {guard prior==outer else {throw ConversationSessionError.invalidEvent}}
                    revisionWorkReceipts[request.operationID,default:[:]][call]=outer;receipt=outer.revision
                } else {guard name=="revise_current_report_v1" else {throw ConversationSessionError.invalidEvent};receipt=try revisionReceipt(result,request:request,callID:call)}
                guard receipt.state=="accepted",let original=request.continuationOriginalBinding else {throw ConversationSessionError.invalidEvent}
                if let prior=continuationReceipts[request.operationID]?[call] {guard prior==receipt else {throw ConversationSessionError.invalidEvent}}
                var projected=try await projection(original,title:title(original.call_id,turnID:original.turn_id,history:request.history),auth:auth)
                guard receipt.permitsCurrentPlan(projected.planReference) else {throw ConversationSessionError.invalidEvent}
                if projected.state == .completed || projected.planReference != receipt.accepted_plan_reference {
                    let result=try await confirmedContinuationResult(receipt,projected:projected,request:request,auth:auth)
                    if !(projected.artifacts+projected.artifactHistory).contains(where:{$0.id==result.id && $0.version==result.version && $0.contentHash==result.contentHash}) {projected.artifactHistory.append(result)}
                }
                continuationReceipts[request.operationID,default:[:]][call]=receipt;goals.append(projected)
            } else if Self.approvalToolNames.contains(name),Self.supportsResume(request) {
                // Approval-lane tools carry no committed domain authority on the wire.
            } else { throw ConversationSessionError.invalidEvent }
            let status=data["status"] as? String
            if let status {guard ["ok","denied","error"].contains(status) else {throw ConversationSessionError.invalidEvent}}
            payload = .toolResult(ConversationToolResult(callID: call, name: name, content: String(decoding: try Self.jsonData(result), as: UTF8.self), committedGoals: goals,continuationReceipt:continuationReceipts[request.operationID]?[call],memoryProposalReceipt:memoryProposal,revisionWorkReceipt:revisionWorkReceipts[request.operationID]?[call]).withStatus(status))
        case "approval_requested":
            guard reality != "not_configured", Self.supportsResume(request), request.image==nil else { throw ConversationSessionError.invalidEvent }
            payload = .approvalRequested(try Self.approval(data))
        case "turn_suspended":
            guard let ids = data["interrupt_ids"] as? [String], !ids.isEmpty, ids.allSatisfy({ UUID(uuidString: $0) != nil }), let expires = data["expires_at"] as? String else { throw ConversationSessionError.invalidEvent }
            payload = .suspended(interruptIDs: ids, expiresAt: expires, requiresApproval: data["requires_approval"] as? Bool, waitingFor: data["waiting_for"] as? String)
        case "ui.block", "ui.block.update", "ui.block.resolve":
            // catpaw.ui.v1: plain approval-negotiated turns only; the data object is passed through for the renderer.
            guard reality != "not_configured", Self.supportsResume(request), request.image==nil, !request.hasUploadedAttachments, let raw = type else { throw ConversationSessionError.invalidEvent }
            let ui = try ConversationUIEvent.decode(type: raw, sequence: sequence, payload: try Self.jsonData(data))
            payload = ui.type == .block ? .uiBlock(ui) : ui.type == .update ? .uiBlockUpdate(ui) : .uiBlockResolve(ui)
        case "model_route":
            // Reported once per turn (opt-in X-cat-Route-Events: 1); no transcript effect.
            let body = try Self.jsonData(data)
            if let event = try? JSONDecoder().decode(ModelRouteEvent.self, from: body) { ModelRouteNotifications.report(event) }
            payload = .sideChannel(type: "model_route", data: body)
        case "memory.used", "memory.update", "memory_recalled", "proactive_suggestion", "memory_saved":
            // Side channel (#63): no transcript effect; raw data goes to MemoryEventSink / proactive store via the installed handler.
            guard let raw = type else { throw ConversationSessionError.invalidEvent }
            let body = try Self.jsonData(data)
            ConversationSideChannelEvents.deliver(type: raw, request: request, data: body)   // token bound at send, not at arrival
            payload = .sideChannel(type: raw, data: body)
        case "device_call":
            guard reality != "not_configured", Self.supportsResume(request), request.image==nil, !request.hasUploadedAttachments,
                  let id = data["interrupt_id"] as? String, UUID(uuidString: id) != nil, let call = data["call_id"] as? String, !call.isEmpty, call.count <= 160,
                  let tool = data["tool"] as? String, Self.approvalToolNames.contains(tool), let args = data["args"] as? [String: Any],
                  let confirm = data["confirm"] as? String, ["card","none"].contains(confirm), let ttl = data["ttl_sec"] as? Int, ttl > 0,
                  let hash = data["args_hash"] as? String, hash.count == 64, let expires = data["expires_at"] as? String else { throw ConversationSessionError.invalidEvent }
            payload = .deviceCall(ConversationDeviceCall(interruptID: id.lowercased(), callID: call, tool: tool, args: try Self.jsonData(args), confirm: confirm, ttlSec: ttl, argsHash: hash, expiresAt: expires))
        case "approval_resolved":
            guard let id = data["interrupt_id"] as? String, UUID(uuidString: id) != nil, let call = data["call_id"] as? String, !call.isEmpty,
                  let decision = data["decision"] as? String, ["approved","denied","expired","cancelled"].contains(decision) || (data["kind"] as? String == "ui" && ["submitted","dismissed","error"].contains(decision)) || (data["kind"] as? String == "device" && decision == "reported") else { throw ConversationSessionError.invalidEvent }
            payload = .approvalResolved(interruptID: id, callID: call, decision: decision, remember: Self.boolean(data["remember"]) ?? false)
        case "turn_completed":
            guard reality != "not_configured", let id = UUID(uuidString: data["message_id"] as? String ?? "") else { throw ConversationSessionError.invalidEvent }
            let bindings = try Self.array(data["task_bindings"]); guard bindings.count <= 1 else { throw ConversationSessionError.invalidEvent }
            if request.continuation != nil {guard bindings.isEmpty else {throw ConversationSessionError.invalidEvent};try validateContinuationList(data["continuations"],request:request);try validateRevisionWorkList(data["revision_work_receipts"],request:request)}
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
            if code == "rate_limited", let raw = data["retry_after_seconds"] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(), (0...3600).contains(raw.intValue) { retryAfter = raw.intValue }
        default:
            // Forward-compatible: unknown event types are ignored (no transcript effect).
            payload = .sideChannel(type: type ?? "unknown", data: (try? Self.jsonData(data)) ?? Data())
        }
        return ConversationTurnEvent(operationID: request.operationID, epoch: request.epoch, sequence: sequence, payload: payload, retryAfterSeconds: retryAfter, conversationID: request.conversationID, turnID: request.operationID)
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
    private func projection(_ binding: ConversationTaskBinding, title: String, auth: String, supplied: [String: Any]? = nil) async throws -> ConversationGoalProjection {
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
                artifacts.append(try await readCanonicalArtifact(binding, id:id, version:version, hash:hash, auth:auth))
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
        if let value=run["revision_requires_new_work"] {guard let required=Self.boolean(value) else {throw ConversationSessionError.invalidEvent};goal.revisionRequiresNewWork=required}
        if goal.revisionRequiresNewWork==true {
            let raw=try Self.object(run["revision_work_policy"]);guard Set(raw.keys)==["tool_policy","source_count"] else {throw ConversationSessionError.invalidEvent}
            let policy=try JSONDecoder().decode(ConversationRevisionWorkPolicy.self,from:Self.jsonData(raw));try policy.validate();goal.revisionWorkPolicy=policy
        }
        goal.binding = binding; goal.artifacts = artifacts; goal.sourceAuthorizationCurrent=authority; return goal
    }
    /// One canonical artifact decoder for conversation observations and scope-wide receipts.
    private func readCanonicalArtifact(_ binding:ConversationTaskBinding,id:String,version:Int,hash:String,auth:String) async throws -> ConversationArtifactProjection {
        let a=try await json("/catpaw/v1/scopes/\(configuration.serverScopeID.uuidString.lowercased())/artifacts/\(id)/versions/\(version)",auth:auth,strict:true)
        guard try Self.positive(a["schema_version"])==1 else {throw ConversationSessionError.invalidEvent}
        let record=try Self.object(a["artifact"])
        guard record["artifact_id"] as? String==id,try Self.positive(record["version"])==version,record["content_hash"] as? String==hash,
              UUID(uuidString:record["run_id"] as? String ?? "")==binding.run_id,record["task_id"] as? String==binding.task_id,
              let body=record["body"] as? String,body.utf8.count<=1_000_000,textHash(body)==hash else {throw ConversationSessionError.invalidEvent}
        let parsed=try ConversationStrictJSON.object(Data(body.utf8),maxBytes:1_000_000),data=try Self.object(parsed["data"])
        guard let title=parsed["title"] as? String,let summary=parsed["summary"] as? String,let content=data["content"] as? String else {throw ConversationSessionError.invalidEvent}
        return .init(id:id,version:version,contentHash:hash,body:body,title:title,summary:summary,content:content)
    }
    private func validateInboxPartition(_ reference:ConversationInboxReference) throws {
        guard reference.scope==configuration.localScope,reference.serverScopeID==configuration.serverScopeID,reference.subjectID==configuration.expectedSubjectID else {throw catError.scopeMismatch}
    }
    public func readInbox(reference:ConversationInboxReference,cursor:String?,limit:Int) async throws -> ConversationInboxPage {
        try validateInboxPartition(reference)
        guard (1...50).contains(limit),cursor.map({!$0.isEmpty && $0.utf8.count<=4096}) ?? true else {throw ConversationInboxError.invalidResponse}
        var components=URLComponents();components.queryItems=[URLQueryItem(name:"limit",value:String(limit))]
        if let cursor {components.queryItems?.append(URLQueryItem(name:"cursor",value:cursor))}
        let auth=try await authorization(reference.scope)
        do {
            let value=try await json("/catpaw/inbox/v1/scopes/"+reference.serverScopeID.uuidString.lowercased()+"/items?"+(components.percentEncodedQuery ?? ""),auth:auth,strict:true)
            return try ConversationInboxPage.decode(Self.jsonData(value),reference:reference,limit:limit)
        } catch NativeChatHTTPFailure.status(let status) where status==401 || status==403 {throw ConversationInboxError.accessDenied}
    }
    public func readReceivedTask(reference:ConversationInboxReference,item:ConversationInboxItem) async throws -> ConversationGoalProjection {
        try validateInboxPartition(reference);try item.validate(reference)
        let auth=try await authorization(reference.scope)
        do {
            var goal=try await projection(item.binding,title:item.title,auth:auth)
            // A list can contain v1 while the head has advanced to v2. Read the exact
            // selected bytes as history; never replace the current head with that v1.
            if goal.sourceAuthorizationCurrent==true {
                for ref in item.artifacts where !(goal.artifacts+goal.artifactHistory).contains(where:{$0.id==ref.artifactID && $0.version==ref.version && $0.contentHash==ref.contentHash}) {
                    goal.artifactHistory.append(try await readCanonicalArtifact(item.binding,id:ref.artifactID,version:ref.version,hash:ref.contentHash,auth:auth))
                }
            }
            try Task.checkCancellation();return goal
        } catch NativeChatHTTPFailure.status(let status) where status==401 || status==403 {throw ConversationInboxError.accessDenied}
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
        if inspectCurrent {guard (request.revisionWork != nil || Self.boolean(a["editable"])==true),Self.boolean(a["is_current"])==true else {throw ConversationSessionError.invalidEvent}}
        return try Self.sha(a["source_auth_hash"])
    }
    private func revisionReceipt(_ raw:[String:Any],request:ConversationTurnRequest,callID:String) throws -> ConversationTaskRevisionReceipt {
        guard Set(raw.keys)==ConversationTaskRevisionReceipt.immutableKeys.union(["receipt_hash","state"]),let sourceHash=continuationSourceHashes[request.operationID] else {throw ConversationSessionError.invalidEvent}
        let receipt=try JSONDecoder().decode(ConversationTaskRevisionReceipt.self,from:Self.jsonData(raw));try receipt.validate(request:request,callID:callID,sourceAuthHash:sourceHash);return receipt
    }
    private func confirmedContinuationResult(_ accepted:ConversationTaskRevisionReceipt,projected:ConversationGoalProjection,request:ConversationTurnRequest,auth:String) async throws -> ConversationArtifactProjection {
        let route="/catpaw/revisions/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+accepted.run_id+"/operations/"+accepted.operation_id
        let wrapper:[String:Any],raw:[String:Any]
        if request.revisionWork != nil {
            guard let outer=revisionWorkReceipts[request.operationID]?[accepted.call_id] else {throw ConversationSessionError.invalidEvent}
            let complete=try await confirmedRevisionWorkEnvelope(outer,request:request,auth:auth)
            raw=try Self.object(JSONSerialization.jsonObject(with:ConversationTaskActionJSON.encoded(complete.revision)))
            wrapper=["schema_version":1,"contract":"catpaw.task-revision.v1"]
        } else {wrapper=try await json(route,auth:auth);raw=try Self.object(wrapper["revision"])}
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
    private func confirmedRevisionWorkEnvelope(_ accepted:ConversationRevisionWorkReceipt,request:ConversationTurnRequest,auth:String) async throws -> ConversationRevisionWorkReceipt {
        guard let intent=request.revisionWork else {throw ConversationSessionError.invalidEvent}
        let r=accepted.revision,path="/catpaw/revision-work/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/runs/"+r.run_id+"/operations/"+r.operation_id
        let raw=try await json(path,auth:auth,strict:true);try Task.checkCancellation()
        let original=try ConversationRevisionWorkReceipt.decode(Self.jsonData(raw));try original.validate(request:request,intent:intent,callID:r.call_id,sourceAuthHash:continuationSourceHashes[request.operationID])
        guard original.receipt_hash==accepted.receipt_hash,original.revision.receipt_hash==r.receipt_hash,original.grant_reference==accepted.grant_reference,original.grant_receipt_hash==accepted.grant_receipt_hash else {throw ConversationSessionError.invalidEvent};return original
    }
    private func validateRevisionWorkList(_ raw:Any?,request:ConversationTurnRequest) throws {
        guard let intent=request.revisionWork else {return}
        let known=revisionWorkReceipts[request.operationID] ?? [:]
        if raw==nil,known.isEmpty {return}
        let values=try Self.array(raw);guard values.count==known.count,values.count<=1 else {throw ConversationSessionError.invalidEvent}
        for row in values {let receipt=try ConversationRevisionWorkReceipt.decode(Self.jsonData(row));try receipt.validate(request:request,intent:intent,callID:receipt.revision.call_id,sourceAuthHash:continuationSourceHashes[request.operationID]);guard known[receipt.revision.call_id]==receipt else {throw ConversationSessionError.invalidEvent}}
    }
    private func validateRevisionWorkOriginal(_ turn:[String:Any],request:ConversationTurnRequest) throws {
        guard let intent=request.revisionWork else {return};try revisionWorkContext(request)
        guard let frozen=turn["revision_work_intent"] as? [String:Any],let admitted=frozen["admitted_at"] as? String,let messageID=request.history.last?.id else {throw ConversationSessionError.invalidEvent}
        let at=try ConversationAcceptedWorkCodec.instant(admitted);try intent.selection.options.validate(now:at)
        guard case .object(var expected)=try intent.work else {throw ConversationSessionError.invalidEvent}
        expected["schema_version"] = .integer(1);expected["contract"] = .string(ConversationRevisionWorkCodec.contract);expected["subject_id"] = .string(intent.selection.authorization.subjectID.uuidString.lowercased());expected["scope_id"] = .string(configuration.serverScopeID.uuidString.lowercased());expected["conversation_id"] = .string(request.conversationID.uuidString.lowercased());expected["conversation_epoch"] = .integer(intent.expectedGrantEpoch);expected["turn_id"] = .string(request.operationID.uuidString.lowercased());expected["message_id"] = .string(messageID.uuidString.lowercased());expected["target_hash"] = .string(intent.targetHash);expected["admitted_at"] = .string(admitted)
        guard try ConversationCanonicalJSON.data(Self.jsonData(frozen),maxBytes:16000)==ConversationRevisionWorkCodec.data(.object(expected)) else {throw ConversationSessionError.invalidEvent}
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
        if request.revisionWork != nil {return "/catpaw/revision-work/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+request.conversationID.uuidString.lowercased()+"/turns"}
        if request.acceptedWork != nil {return "/catpaw/accepted-work/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+request.conversationID.uuidString.lowercased()+"/turns"}
        return request.continuation == nil ? path(request)+"/turns" : "/catpaw/revisions/v1/scopes/"+configuration.serverScopeID.uuidString.lowercased()+"/conversations/"+request.conversationID.uuidString.lowercased()+"/turns"
    }
    private var scopePath: String { (purpose == .parentingIntake ? "/catpaw/parenting-intake/v1/scopes/" : "/catpaw/chat/v1/scopes/") + configuration.serverScopeID.uuidString.lowercased() }
    private func validatePurpose(_ value:[String:Any]) throws {
        if purpose == .parentingIntake {
            guard value["intake_contract"] as? String == Self.intakeContract else { throw ConversationSessionError.invalidEvent }
            for key in ["task_bindings", "pending_approvals", "continuations", "revision_work_receipts"] {
                if let raw = value[key], !(raw is NSNull) { guard let list = raw as? [Any], list.isEmpty else { throw ConversationSessionError.invalidEvent } }
            }
        } else { guard value["intake_contract"] == nil else { throw ConversationSessionError.invalidEvent } }
    }
    private func path(_ r: ConversationTurnRequest) -> String { scopePath + "/conversations/" + r.conversationID.uuidString.lowercased() }
    private func authorization(_ scope: DataScope) async throws -> String {
        guard scope == configuration.localScope else { throw catError.scopeMismatch }
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
        if purpose == .parentingIntake, path.hasPrefix("/catpaw/parenting-intake/"),
           let status = (response as? HTTPURLResponse)?.statusCode, status == 405 || (status == 404 && body != nil) {
            throw catError.unavailable(Self.intakeUnavailable)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NativeChatHTTPFailure.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard data.count <= 2_000_000 else { throw ConversationSessionError.invalidEvent }
        if strict || purpose == .parentingIntake || (path.hasPrefix("/catpaw/accepted-work/v1/") || path.hasPrefix("/catpaw/revision-work/v1/")) {guard (response as? HTTPURLResponse)?.mimeType=="application/json" else {throw ConversationSessionError.invalidEvent}}
        return strict || purpose == .parentingIntake || path.hasPrefix("/catpaw/revisions/v1/") || (path.hasPrefix("/catpaw/accepted-work/v1/") || path.hasPrefix("/catpaw/revision-work/v1/")) ? try ConversationStrictJSON.object(data,maxBytes:2_000_000) : try Self.object(JSONSerialization.jsonObject(with: data))
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
        guard try positive(x["schema_version"])==1,x["contract"] as? String==(request.revisionWork != nil ? ConversationRevisionWorkCodec.contract : request.acceptedWork != nil ? ConversationAcceptedWorkCodec.contract : request.continuation == nil ? "catpaw.native-chat.v1" : "catpaw.task-revision.v1") else {throw ConversationSessionError.invalidEvent}
    }
    private static func chatEnvelope(_ x: [String: Any]) throws { guard try positive(x["schema_version"]) == 1, x["contract"] as? String == "catpaw.native-chat.v1" else { throw ConversationSessionError.invalidEvent } }
}
extension NativeChatHTTPBackend: ParentingIntakeDataDeleting {
    public func deleteIntake(scope: DataScope, conversationID: UUID) async throws {
        guard purpose == .parentingIntake, scope == configuration.localScope else { throw ConversationSessionError.invalidEvent }
        try Task.checkCancellation()
        let auth = try await authorization(scope)
        var request = try configuration.makeRequest(route: scopePath + "/conversations/" + conversationID.uuidString.lowercased(), authorization: auth)
        request.httpMethod = "DELETE"; request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ConversationSessionError.invalidEvent }
        if response.statusCode == 401 { await credentials.rejected(scope: scope) }
        guard response.statusCode == 200, response.mimeType == "application/json" else { throw catError.unavailable("云端临时整理数据尚未确认清理，可以稍后重试清理。") }
        let envelope = try ConversationStrictJSON.object(data, maxBytes: 65_536)
        try Self.chatEnvelope(envelope)
        let purge = try Self.object(envelope["purge"])
        guard UUID(uuidString: purge["conversation_id"] as? String ?? "") == conversationID,
              UUID(uuidString: purge["scope_id"] as? String ?? "") == configuration.serverScopeID,
              UUID(uuidString: purge["subject_id"] as? String ?? "") == configuration.expectedSubjectID,
              Self.boolean(purge["purged"]) == true, purge["retained"] as? String == "identity_hash_tombstone_only" else { throw ConversationSessionError.invalidEvent }
        try validatePurpose(purge)
    }
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
                if http.statusCode == 409 { sendDiagnostic("catpaw.send conflict site=plan409 path=\(wire.url?.path ?? "?")");throw catError.conflict }
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
        guard reference.scope==configuration.localScope,reference.binding.scope_id==configuration.serverScopeID else {throw catError.scopeMismatch}
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
        guard reference.scope==configuration.localScope,reference.binding.scope_id==configuration.serverScopeID else {throw catError.scopeMismatch}
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
            if http.statusCode==409,type=="application/json",(try? ConversationStrictJSON.object(data,maxBytes:limit)) != nil,let error=try? JSONDecoder().decode(NativeTaskReviewErrorEnvelope.self,from:data),error.schemaVersion==1,!error.error.reconciliationRequired,!error.error.retryable {throw catError.conflict}
            throw NativeChatHTTPFailure.status(http.statusCode)
        }
        guard type=="application/json" else {throw ConversationSessionError.invalidEvent}
        _=try ConversationStrictJSON.object(data,maxBytes:limit);return data
    }
}
extension NativeChatHTTPBackend:ConversationArtifactEditBackend {
    private func artifactEditPath(_ reference:ConversationArtifactEditReference) throws -> String {
        guard reference.scope==configuration.localScope,reference.binding.scope_id==configuration.serverScopeID else {throw catError.scopeMismatch}
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

// MARK: - catpaw.chat-attachments.v1 client (services/edge/docs/attachments-contract.md)

/// Upload progress / state for the composer chip.
public enum ChatAttachmentUploadState: Sendable, Equatable {
    case creating
    case uploading(fraction: Double)
    case completing
    case ready(attachmentID: UUID)
    case failed(message: String)
}
public enum ChatAttachmentUploadError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedType, tooLarge, rejected(String), expired, notConfigured, server(Int, String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedType: return "只支持 PNG 或 JPEG 图片。"
        case .tooLarge: return "图片超过 5 MB，请换一张或裁小后再试。"
        case .rejected: return "图片未通过校验，请重新选择。"
        case .expired: return "上传已过期，请重新添加图片。"
        case .notConfigured: return "图片上传尚未配置。"
        case .server: return "图片上传未完成，请稍后重试。"
        }
    }
}
/// A ready attachment: put `id` into the turn's `message.attachment_ids` (schema_version 2). Single use:
/// once a turn is accepted it is consumed; if that turn fails, upload the same local bytes again under a new id.
public struct ChatAttachmentReceipt: Sendable, Equatable {
    public let id: UUID
    public let mimeType: String
    public let sizeBytes: Int
    public let sha256: String
    public let width: Int?
    public let height: Int?
}
/// Minimal HTTP seam so the flow is testable without network. `progress` reports upload fractions (PUT only).
public protocol ChatAttachmentTransport: Sendable {
    func send(_ request: URLRequest, body: Data?, progress: (@Sendable (Double) -> Void)?) async throws -> (status: Int, body: Data)
}
public final class URLSessionChatAttachmentTransport: NSObject, ChatAttachmentTransport, @unchecked Sendable {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) { session = URLSession(configuration: configuration) }
    private final class Progress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
        // Signed URLs are credentials: never follow redirects.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }
    public func send(_ request: URLRequest, body: Data?, progress: (@Sendable (Double) -> Void)?) async throws -> (status: Int, body: Data) {
        let delegate = progress.map { Progress($0) }
        let (data, response): (Data, URLResponse)
        if let body { (data, response) = try await session.upload(for: request, from: body, delegate: delegate) }
        else { (data, response) = try await session.data(for: request, delegate: delegate) }
        guard let http = response as? HTTPURLResponse else { throw ChatAttachmentUploadError.server(0, "no_http_response") }
        return (http.statusCode, data)
    }
}
/// create → PUT signed URL → complete. Bytes must already be prepared by the composer encoder
/// (`SystemImageAttachmentEncoder`: transcode to PNG/JPEG, strip metadata, ≤2048 px); this layer re-checks
/// type and the 5 MiB limit and never logs the signed URL.
public actor ChatAttachmentUploader {
    public static let maxBytes = 5 * 1024 * 1024
    private let configuration: NativeChatConfiguration
    private let credentials: any NativeChatSessionCredentials
    private let transport: any ChatAttachmentTransport
    private let pause: @Sendable (Double) async -> Void
    public init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials, transport: any ChatAttachmentTransport = URLSessionChatAttachmentTransport(),
                pause: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.configuration = configuration; self.credentials = credentials; self.transport = transport; self.pause = pause
    }
    public static func mimeType(of bytes: Data) -> String? {
        let head = Array(bytes.prefix(8))
        if head == [137, 80, 78, 71, 13, 10, 26, 10] { return "image/png" }
        if head.starts(with: [255, 216, 255]) { return "image/jpeg" }
        return nil
    }
    /// Uploads `bytes` and returns a ready receipt. `attachmentID` defaults to a fresh id; pass a new id (the
    /// default) when retrying after a failed turn. One automatic restart under a new id on `410 attachment_expired`.
    public func upload(_ bytes: Data, scope: DataScope, attachmentID: UUID = UUID(), onState: @escaping @Sendable (ChatAttachmentUploadState) -> Void = { _ in }) async throws -> ChatAttachmentReceipt {
        do { return try await attempt(bytes, scope: scope, id: attachmentID, onState: onState) }
        catch ChatAttachmentUploadError.expired {
            do { return try await attempt(bytes, scope: scope, id: UUID(), onState: onState) }
            catch { onState(.failed(message: error.localizedDescription)); throw error }
        }
        catch { onState(.failed(message: error.localizedDescription)); throw error }
    }
    /// Turn message body for schema_version 2 with uploaded attachment ids.
    public static func turnMessage(id: UUID, text: String, attachments: [ChatAttachmentReceipt]) -> [String: Any] {
        turnMessage(id: id, text: text, ids: attachments.map(\.id))
    }
    public static func turnMessage(id: UUID, text: String, ids: [UUID]) -> [String: Any] {
        ["id": id.uuidString.lowercased(), "text": text, "attachment_ids": ids.map { $0.uuidString.lowercased() }]
    }
    private var base: String { "/catpaw/chat/v1/scopes/" + configuration.serverScopeID.uuidString.lowercased() + "/attachments" }
    private func attempt(_ bytes: Data, scope: DataScope, id: UUID, onState: @escaping @Sendable (ChatAttachmentUploadState) -> Void) async throws -> ChatAttachmentReceipt {
        guard let mime = Self.mimeType(of: bytes) else { throw ChatAttachmentUploadError.unsupportedType }
        guard bytes.count <= Self.maxBytes else { throw ChatAttachmentUploadError.tooLarge }
        guard configuration.publishableKey != nil, scope == configuration.localScope else { throw ChatAttachmentUploadError.notConfigured }
        let sha = bytesHash(bytes), idText = id.uuidString.lowercased()
        let auth = try await credentials.authorization(scope: scope)
        onState(.creating)
        var create = try configuration.makeRequest(route: base, authorization: auth); create.httpMethod = "POST"
        let createBody = try JSONSerialization.data(withJSONObject: ["attachment_id": idText, "mime_type": mime, "size_bytes": bytes.count, "sha256": sha], options: [.sortedKeys])
        let created = try await transport.send(create, body: createBody, progress: nil)
        let createdJSON = try Self.check(created, expect: [200, 201])
        guard let attachment = createdJSON["attachment"] as? [String: Any], attachment["id"] as? String == idText,
              attachment["sha256"] as? String == sha, attachment["size_bytes"] as? Int == bytes.count else { throw ChatAttachmentUploadError.server(created.status, "attachment_mismatch") }
        if attachment["state"] as? String == "pending" {
            guard let upload = createdJSON["upload"] as? [String: Any], upload["method"] as? String == "PUT", let urlText = upload["url"] as? String,
                  let url = URL(string: urlText), url.scheme == "https", let headers = upload["headers"] as? [String: String] else { throw ChatAttachmentUploadError.server(created.status, "upload_missing") }
            var put = URLRequest(url: url); put.httpMethod = "PUT"; put.timeoutInterval = 120
            for (key, value) in headers { put.setValue(value, forHTTPHeaderField: key) }
            onState(.uploading(fraction: 0))
            let uploaded = try await transport.send(put, body: bytes, progress: { onState(.uploading(fraction: $0)) })
            guard (200..<300).contains(uploaded.status) else { throw ChatAttachmentUploadError.server(uploaded.status, "upload_failed") }
            onState(.uploading(fraction: 1))
        }
        onState(.completing)
        var tries = 0
        while true {
            var complete = try configuration.makeRequest(route: base + "/" + idText + "/complete", authorization: auth); complete.httpMethod = "POST"
            let done = try await transport.send(complete, body: Data("{}".utf8), progress: nil)
            if done.status == 409, Self.code(done.body) == "attachment_upload_missing", tries < 3 { tries += 1; await pause(Double(tries)); continue }
            let json = try Self.check(done, expect: [200])
            guard let ready = json["attachment"] as? [String: Any], ready["id"] as? String == idText else { throw ChatAttachmentUploadError.server(done.status, "attachment_mismatch") }
            switch ready["state"] as? String {
            case "ready":
                onState(.ready(attachmentID: id))
                return ChatAttachmentReceipt(id: id, mimeType: mime, sizeBytes: bytes.count, sha256: sha, width: ready["width"] as? Int, height: ready["height"] as? Int)
            case "rejected": throw ChatAttachmentUploadError.rejected(ready["reason"] as? String ?? "rejected")
            default: throw ChatAttachmentUploadError.server(done.status, "attachment_not_ready")
            }
        }
    }
    private static func code(_ body: Data) -> String? { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["code"] as? String } }
    private static func check(_ reply: (status: Int, body: Data), expect: Set<Int>) throws -> [String: Any] {
        if reply.status == 410 { throw ChatAttachmentUploadError.expired }
        if reply.status == 413 { throw ChatAttachmentUploadError.tooLarge }
        if reply.status == 422, code(reply.body) == "image_mime_unsupported" { throw ChatAttachmentUploadError.unsupportedType }
        guard expect.contains(reply.status), let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] else { throw ChatAttachmentUploadError.server(reply.status, code(reply.body) ?? "unexpected") }
        return json
    }
}

#if DEBUG
// MARK: - Demo / fixture backend (DEBUG only; see docs/demo-fixture-backend.md)
/// Enable with launch argument `-CatpawDemoBackend` or `UserDefaults` key `CatpawDemoBackend` = true. Never compiled into Release.
public enum catDemoBackendSwitch {
    public static let argument = "-CatpawDemoBackend"
    public static let defaultsKey = "CatpawDemoBackend"
    public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults = .standard) -> Bool {
        if arguments.contains(argument) { return true }
        return defaults.bool(forKey: defaultsKey)
    }
    /// Returns the demo backend when enabled, else `fallback` unchanged.
    public static func select(_ fallback: any ConversationBackend, arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults = .standard) -> any ConversationBackend {
        isEnabled(arguments: arguments, defaults: defaults) ? catDemoConversationBackend.shared : fallback
    }
}

/// One catpaw.ui.v1 wire event (`ui.block`, `ui.block.update`, `ui.block.resolve`, `turn_suspended`, `turn_completed`).
/// `json` is the event's `data` object exactly as the Edge server sends it (docs/fixtures/catpaw-ui-demo.jsonl).
public struct catDemoUIEvent: Sendable, Equatable {
    public let sequence: Int
    public let type: String
    public let json: String
}
public enum catDemoUIDecision: String, Sendable { case submit, dismiss, reportError = "report_error" }
public enum catDemoUIFailure: Error, Sendable, Equatable { case notFound, consumed, conflict, invalidResponse }

/// Scripted catpaw.ui.v1 session mirroring the recorded server run:
/// round 1 = card, list, progress (display) + choices (waits); round 2 = progress update + form, confirm, sheet (wait);
/// after the last answer the turn completes. Decisions are idempotent per `operationID` (same body replays, other body = conflict).
public actor catDemoUIScript {
    public static let interactive = ["demo-choices", "demo-form", "demo-confirm", "demo-sheet"]
    private static let expiresAt = "2026-10-16T00:20:00.000Z"
    private var sequence = 0
    private var round = 0
    private var resolved: [String: (operation: UUID, body: String, events: [catDemoUIEvent])] = [:]
    private var completed = false
    public init() {}
    private func next(_ type: String, _ json: String) -> catDemoUIEvent { sequence += 1; return catDemoUIEvent(sequence: sequence, type: type, json: json) }
    public static func interruptID(_ blockID: String) -> String { stableID("catpaw-demo-interrupt-\(blockID)").uuidString.lowercased() }
    private static func interrupt(_ id: String) -> String { "\"interruptId\":\"\(interruptID(id))\",\"argsHash\":\"\(String(repeating: "0", count: 64))\",\"expiresAt\":\"\(expiresAt)\"" }
    /// Round 1. Calling again returns nothing (the script runs once per instance).
    public func start() -> [catDemoUIEvent] {
        guard round == 0 else { return [] }
        round = 1
        return [
            next("ui.block", #"{"id":"demo-card","kind":"card","schemaVersion":1,"title":"今天","body":"**三件事**：写周报、买菜、跑步"}"#),
            next("ui.block", #"{"id":"demo-list","kind":"list","schemaVersion":1,"title":"待办","items":[{"id":"a","label":"写周报"},{"id":"b","label":"买菜"},{"id":"c","label":"跑步"}]}"#),
            next("ui.block", #"{"id":"demo-progress","kind":"progress","schemaVersion":1,"title":"整理今天","steps":[{"id":"read","label":"读取日程","state":"running"},{"id":"plan","label":"排优先级","state":"pending"}]}"#),
            next("ui.block", #"{"id":"demo-choices","kind":"choices","schemaVersion":1,"title":"先做哪件？","selection":"single","allowOther":true,"items":[{"id":"a","label":"写周报"},{"id":"b","label":"买菜"}],"# + Self.interrupt("demo-choices") + "}"),
            next("turn_suspended", "{\"interrupt_ids\":[\"\(Self.interruptID("demo-choices"))\"],\"expires_at\":\"\(Self.expiresAt)\"}"),
        ]
    }
    private func round2() -> [catDemoUIEvent] {
        round = 2
        return [
            next("ui.block.update", #"{"id":"demo-progress","steps":[{"id":"read","label":"读取日程","state":"done"},{"id":"plan","label":"排优先级","state":"running"}]}"#),
            next("ui.block", #"{"id":"demo-form","kind":"form","schemaVersion":1,"title":"跑步计划","fields":[{"id":"km","label":"公里","type":"number","required":true},{"id":"at","label":"时间","type":"time"}],"# + Self.interrupt("demo-form") + "}"),
            next("ui.block", #"{"id":"demo-confirm","kind":"confirm","schemaVersion":1,"title":"创建提醒？","body":"18:30 提醒跑步","actions":[{"id":"approve","label":"创建"},{"id":"deny","label":"取消"}],"# + Self.interrupt("demo-confirm") + "}"),
            next("ui.block", #"{"id":"demo-sheet","kind":"sheet","schemaVersion":1,"title":"弹窗","body":"这是一个原生弹窗（不是代码）","actions":[{"id":"ok","label":"好的"}],"# + Self.interrupt("demo-sheet") + "}"),
            next("turn_suspended", "{\"interrupt_ids\":[\"\(Self.interruptID("demo-form"))\",\"\(Self.interruptID("demo-confirm"))\",\"\(Self.interruptID("demo-sheet"))\"],\"expires_at\":\"\(Self.expiresAt)\"}"),
        ]
    }
    /// `POST …/interrupts/{interruptId}/decision` with `{operation_id, decision, args_hash, response?}`.
    /// `responseJSON` is the `ui.response` (submit) or `ui.error` (report_error) object; nil for dismiss.
    public func respond(blockID: String, decision: catDemoUIDecision, responseJSON: String?, operationID: UUID) throws -> [catDemoUIEvent] {
        let open = round == 1 ? ["demo-choices"] : round == 2 ? ["demo-form", "demo-confirm", "demo-sheet"] : []
        let body = decision.rawValue + "|" + (responseJSON ?? "")
        if let prior = resolved[blockID] {
            guard prior.operation == operationID else { throw catDemoUIFailure.consumed }
            guard prior.body == body else { throw catDemoUIFailure.conflict }
            return prior.events
        }
        guard open.contains(blockID) else { throw catDemoUIFailure.notFound }
        switch decision {
        case .submit, .reportError:
            guard let responseJSON, let data = responseJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["blockId"] as? String == blockID,
                  object["type"] as? String == (decision == .submit ? "ui.response" : "ui.error") else { throw catDemoUIFailure.invalidResponse }
            if blockID == "demo-confirm", decision == .submit { guard object["actionId"] is String else { throw catDemoUIFailure.invalidResponse } }
        case .dismiss:
            guard responseJSON == nil else { throw catDemoUIFailure.invalidResponse }
        }
        let status = decision == .submit ? "submitted" : decision == .dismiss ? "dismissed" : "error"
        var events = [
            next("approval_resolved", "{\"interrupt_id\":\"\(Self.interruptID(blockID))\",\"call_id\":\"call-\(blockID)\",\"kind\":\"ui\",\"decision\":\"\(status)\"}"),
            next("ui.block.resolve", "{\"id\":\"\(blockID)\",\"status\":\"\(status)\"}"),
        ]
        resolved[blockID] = (operationID, body, [])
        if open.allSatisfy({ resolved[$0] != nil }) {
            if round == 1 { events += round2() }
            else if !completed { completed = true; events.append(next("turn_completed", "{\"text\":\"都安排好了。\"}")) }
        }
        resolved[blockID] = (operationID, body, events)
        return events
    }
}

/// DEBUG demo `ConversationBackend`, on the same domain path as the HTTP backend:
/// - reply: turn_started → text_delta → tool_call(create_task) → approval_requested → turn_suspended
/// - submitApproval: approval_resolved → tool_result(create_task, ok|denied) → catpaw.ui.v1 round 1
///   (ui.block card/list/progress/choices) → turn_suspended
/// - submitUIDecision (choices): approval_resolved(kind ui) → ui.block.resolve → round 2 (ui.block.update progress,
///   ui.block form/confirm/sheet) → turn_suspended; after the last of form/confirm/sheet: text_delta → turn_completed.
public actor catDemoConversationBackend: ConversationBackend {
    public static let shared = catDemoConversationBackend()
    public static let demoTaskCallID = "call-demo-create-task"
    private struct Turn { var sequence: Int; var messageID: UUID; var text: String; var interruptID: String; var decided: (UUID, ConversationApprovalDecision)?; var resolvedEvents: [ConversationTurnEvent]; var ui: catDemoUIScript; var uiReplies: [String: (UUID, [ConversationTurnEvent])] }
    private var turns: [UUID: Turn] = [:]
    public init() {}
    public func connection(scope: DataScope) async -> ConversationConnection {
        ConversationConnection(state: .connected, provider: "Demo", detail: "演示后端（DEBUG）：审批、create_task 与 catpaw.ui.v1 全部块类型均为脚本回放。")
    }
    private func event(_ request: ConversationTurnRequest, _ payload: ConversationTurnEvent.Payload) -> ConversationTurnEvent {
        var turn = turns[request.operationID]!
        turn.sequence += 1; turns[request.operationID] = turn
        return ConversationTurnEvent(operationID: request.operationID, epoch: 1, sequence: turn.sequence, payload: payload, conversationID: request.conversationID, turnID: request.operationID)
    }
    private func nextSequence(_ request: ConversationTurnRequest) -> Int { turns[request.operationID]!.sequence + 1 }
    private static func stream(_ events: [ConversationTurnEvent]) -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        AsyncThrowingStream { continuation in for event in events { continuation.yield(event) }; continuation.finish() }
    }
    /// Script wire events → domain events with this turn's continuous sequence (same `ConversationUIEvent.decode` as HTTP).
    private func domain(_ request: ConversationTurnRequest, _ script: [catDemoUIEvent]) throws -> [ConversationTurnEvent] {
        var out: [ConversationTurnEvent] = []
        for wire in script {
            let data = Data(wire.json.utf8)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            switch wire.type {
            case "ui.block", "ui.block.update", "ui.block.resolve":
                let sequence = nextSequence(request)
                let ui = try ConversationUIEvent.decode(type: wire.type, sequence: sequence, payload: data)
                out.append(event(request, ui.type == .block ? .uiBlock(ui) : ui.type == .update ? .uiBlockUpdate(ui) : .uiBlockResolve(ui)))
            case "turn_suspended":
                out.append(event(request, .suspended(interruptIDs: object["interrupt_ids"] as? [String] ?? [], expiresAt: object["expires_at"] as? String ?? "", requiresApproval: object["requires_approval"] as? Bool, waitingFor: object["waiting_for"] as? String)))
            case "approval_resolved":
                out.append(event(request, .approvalResolved(interruptID: object["interrupt_id"] as? String ?? "", callID: object["call_id"] as? String ?? "", decision: object["decision"] as? String ?? "", remember: false)))
            case "turn_completed":
                let turn = turns[request.operationID]!, tail = "都安排好了。"
                out.append(event(request, .textDelta(messageID: turn.messageID, text: tail)))
                out.append(event(request, .completed(messageID: turn.messageID, finalTextHash: textHash(turn.text + tail))))
            default: throw ConversationSessionError.invalidEvent
            }
        }
        return out
    }
    public func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        guard turns[request.operationID] == nil else { throw ConversationSessionError.unresolvedOperation }
        let interruptID = UUID().uuidString.lowercased(), messageID = UUID(), opening = "好的，我先帮你建一个任务。"
        turns[request.operationID] = Turn(sequence: 0, messageID: messageID, text: opening, interruptID: interruptID, decided: nil, resolvedEvents: [], ui: catDemoUIScript(), uiReplies: [:])
        let arguments = #"{"due":"2026-10-16","title":"跑步 5 公里"}"#
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        let approval = ConversationApprovalRequest(interruptID: interruptID, callID: Self.demoTaskCallID, tool: "create_task", summary: "创建任务「跑步 5 公里」（2026-10-16）", arguments: arguments, argsHash: String(repeating: "a", count: 64), expiresAt: expires, risk: "local_write", rememberAllowed: true)
        let hash = textHash(request.operationID.uuidString.lowercased())
        var events: [ConversationTurnEvent] = []
        events.append(event(request, .started(requestHash: hash, conversationRevision: 1, grantEpoch: 1)))
        events.append(event(request, .textDelta(messageID: messageID, text: opening)))
        events.append(event(request, .toolStarted(callID: Self.demoTaskCallID, name: "create_task", arguments: arguments)))
        events.append(event(request, .approvalRequested(approval)))
        events.append(event(request, .suspended(interruptIDs: [interruptID], expiresAt: expires)))
        return Self.stream(events)
    }
    public func submitApproval(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationApprovalDecision, argsHash: String, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        guard let turn = turns[request.operationID], turn.interruptID == interruptID else { throw ConversationApprovalFailure.notFound }
        guard argsHash == String(repeating: "a", count: 64) else { throw ConversationApprovalFailure.stale }
        if let decided = turn.decided {
            // Idempotent replay of the same operation; anything else is consumed.
            guard decided.0 == operationID, decided.1 == decision else { throw ConversationApprovalFailure.consumed }
            return Self.stream(turn.resolvedEvents.filter { $0.sequence > afterSequence })
        }
        let approved = decision != .deny
        let content = approved ? #"{"status":"ok","task":{"id":"demo-task","title":"跑步 5 公里","due":"2026-10-16"}}"# : #"{"status":"denied"}"#
        var events: [ConversationTurnEvent] = []
        events.append(event(request, .approvalResolved(interruptID: interruptID, callID: Self.demoTaskCallID, decision: approved ? "approved" : "denied", remember: decision == .approveAlways)))
        events.append(event(request, .toolResult(ConversationToolResult(callID: Self.demoTaskCallID, name: "create_task", content: content).withStatus(approved ? "ok" : "denied"))))
        let round1 = await turn.ui.start()
        events += try domain(request, round1)
        var saved = turns[request.operationID]!
        saved.decided = (operationID, decision); saved.resolvedEvents = events; turns[request.operationID] = saved
        return Self.stream(events)
    }
    public func submitUIDecision(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let key = interruptID.lowercased()
        guard let turn = turns[request.operationID], let blockID = catDemoUIScript.interactive.first(where: { catDemoUIScript.interruptID($0) == key }) else { throw ConversationApprovalFailure.notFound }
        guard argsHash == String(repeating: "0", count: 64) else { throw ConversationApprovalFailure.stale }
        let script: [catDemoUIEvent]
        let responseText = response.map { String(decoding: $0, as: UTF8.self) }
        do { script = try await turn.ui.respond(blockID: blockID, decision: catDemoUIDecision(rawValue: decision.rawValue) ?? .dismiss, responseJSON: responseText, operationID: operationID) }
        catch catDemoUIFailure.notFound { throw ConversationApprovalFailure.notFound }
        catch catDemoUIFailure.consumed { throw ConversationApprovalFailure.consumed }
        catch catDemoUIFailure.conflict { throw ConversationApprovalFailure.rejected(status: 409, code: "approval_operation_conflict") }
        catch catDemoUIFailure.invalidResponse { throw ConversationApprovalFailure.rejected(status: 422, code: "ui_response_invalid") }
        // Same operation and body: replay what was already streamed after `afterSequence`.
        if let prior = turns[request.operationID]!.uiReplies[key] { return Self.stream(prior.1.filter { $0.sequence > afterSequence }) }
        let events = try domain(request, script)
        var saved = turns[request.operationID]!
        saved.uiReplies[key] = (operationID, events); turns[request.operationID] = saved
        return Self.stream(events)
    }
    public func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation { throw ConversationSessionError.unresolvedOperation }
    public func cancelTurn(_ request: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt {
        guard turns[request.operationID] != nil else { throw ConversationTurnCancelFailure.notFound }
        turns[request.operationID] = nil
        return ConversationTurnCancelReceipt(turnID: request.operationID, state: "failed", cancelled: true, alreadyTerminal: false)
    }
}
#endif

/// Keeps the composer's local image bytes for a turn until `turn_completed`, and re-uploads them under NEW
/// attachment ids when that turn failed (the server consumed the old ids when it accepted the turn;
/// catpaw.chat-attachments.v1 §4). Bytes never leave memory except through the uploader.
public actor ChatAttachmentSendCoordinator {
    public typealias Upload = @Sendable (_ bytes: Data, _ attachmentID: UUID) async throws -> ChatAttachmentReceipt
    private let upload: Upload
    private var kept: [UUID: [Data]] = [:]
    private var receipts: [UUID: [ChatAttachmentReceipt]] = [:]
    public init(upload: @escaping Upload) { self.upload = upload }
    public init(uploader: ChatAttachmentUploader, scope: DataScope) {
        self.init(upload: { bytes, id in try await uploader.upload(bytes, scope: scope, attachmentID: id) })
    }
    /// Uploads each image under a fresh id, keeps the bytes for `request.operationID`, and returns the request
    /// carrying `attachmentIDs`. Calling again for the same operation reuses the ready ids (no second upload).
    public func attach(_ images: [Data], to request: ConversationTurnRequest) async throws -> ConversationTurnRequest {
        guard !images.isEmpty else { return request.withAttachmentIDs(nil) }
        if let ready = receipts[request.operationID], kept[request.operationID] == images { return request.withAttachmentIDs(ready.map(\.id)) }
        var uploaded: [ChatAttachmentReceipt] = []
        for bytes in images {
            let receipt = try await upload(bytes, UUID())
            uploaded.append(receipt)
        }
        kept[request.operationID] = images; receipts[request.operationID] = uploaded
        return request.withAttachmentIDs(uploaded.map(\.id))
    }
    /// The local copy for a turn (for the bubble preview and for a retry). nil once completed.
    public func localImages(for operationID: UUID) -> [Data]? { kept[operationID] }
    public func attachmentIDs(for operationID: UUID) -> [UUID]? { receipts[operationID]?.map(\.id) }
    /// `turn_completed`: the server has used the image; drop the local bytes.
    public func turnCompleted(_ operationID: UUID) { kept[operationID] = nil; receipts[operationID] = nil }
    /// User discarded the draft/turn without retrying.
    public func discard(_ operationID: UUID) { turnCompleted(operationID) }
    /// The turn `failed` after the server accepted it: upload the kept bytes again under NEW ids for the retry
    /// turn `retry` (a new operationID), and move the local copy to it. Throws if nothing was kept.
    public func reattach(after failedOperationID: UUID, to retry: ConversationTurnRequest) async throws -> ConversationTurnRequest {
        guard let images = kept[failedOperationID], !images.isEmpty else { throw ChatAttachmentUploadError.expired }
        let old = Set(receipts[failedOperationID]?.map(\.id) ?? [])
        var uploaded: [ChatAttachmentReceipt] = []
        for bytes in images {
            var id = UUID()
            while old.contains(id) { id = UUID() }
            let receipt = try await upload(bytes, id)
            uploaded.append(receipt)
        }
        kept[failedOperationID] = nil; receipts[failedOperationID] = nil
        kept[retry.operationID] = images; receipts[retry.operationID] = uploaded
        return retry.withAttachmentIDs(uploaded.map(\.id))
    }
}

/// catpaw-api `503 chat_runtime_busy` (JSON, before the SSE stream starts): always retryable on the client — prod v48
/// still sends `retryable:false`; the coming backend fix sends `retryable:true` + `Retry-After: 1–60`. Matched on the code
/// string only. A Retry-After header (or retry_after_seconds) wins, clamped 0.5–60 s; otherwise quiet exponential backoff
/// 1, 2, 4, 8, 16 s. At most 5 re-POSTs within a 60 s total budget, each the SAME URLRequest (same Idempotency-Key =
/// turn_id). When exhausted, the existing 503 message (「尚未确认…不要重新发送」) is the final fallback.
enum ChatRuntimeBusyRetry {
    static let code = "chat_runtime_busy"
    static let budget: TimeInterval = 60
    static let maxRetries = 5
    struct Busy: Error { let retryAfter: TimeInterval? }
    nonisolated(unsafe) static var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    private static func problem(_ body: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return (object["error"] as? [String: Any]) ?? object
    }
    /// True for the busy code regardless of `retryable`.
    static func isBusy(_ body: Data) -> Bool { problem(body)?["code"] as? String == code }
    static func retryAfter(header: String?, body: Data) -> TimeInterval? {
        if let raw = header?.trimmingCharacters(in: .whitespaces), let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return seconds }
        guard let problem = problem(body) else { return nil }
        for key in ["retry_after_seconds", "retry_after_sec", "retry_after"] {
            if let n = problem[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 { return n.doubleValue }
        }
        return nil
    }
    static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 0.5), 60) }
        return min(pow(2, Double(max(1, attempt) - 1)), 16)
    }
    /// The account that started the send is still the signed-in one, same epoch (no sign-out / switch / restart since).
    static func sameAccount(_ principal: AccountToken?, epoch: AccountEpoch = .shared) -> Bool {
        principal.map { epoch.isValid($0) } ?? (epoch.capture() == nil)
    }
    /// Shown when a quiet retry is dropped because its account left: a busy refusal proves the turn was never admitted.
    static let leftAccountMessage = "已退出该账号，这条消息没有发送。"
    /// `post` throws `Busy` for a busy refusal; any other result or error passes through unchanged. After every sleep and
    /// before every re-POST: cancellation, then `stillCurrent` (AccountEpoch) — a stale account's turn is never re-sent.
    static func run<R>(post: () async throws -> R, sleep: (TimeInterval) async throws -> Void, stillCurrent: () -> Bool = { true }, exhausted: () -> Error) async throws -> R {
        var waited: TimeInterval = 0, attempt = 0
        while true {
            do { return try await post() }
            catch let busy as Busy {
                attempt += 1
                let wait = delay(attempt: attempt, retryAfter: busy.retryAfter)
                guard attempt <= maxRetries, waited + wait <= budget else { throw exhausted() }
                try Task.checkCancellation()
                try await sleep(wait); waited += wait
                try Task.checkCancellation()
                guard stillCurrent() else { throw ConversationDispatchFailure.notSent(reason: leftAccountMessage) }
            }
        }
    }
}

/// Acceptance #2: the account-level record of "this user allowed model route `route_hash`". The server stores consent per
/// conversation; this lets a new conversation of the SAME account inherit the decision until the disclosure changes.
/// Keyed by subject + server scope (never shared across accounts); stores only the public route hash, no content.
struct AccountModelConsentMemory {
    let subjectID: UUID?
    let serverScopeID: UUID
    var defaults: UserDefaults = .standard
    var key: String? { subjectID.map { "catpaw.modelConsent.v1.\($0.uuidString.lowercased()).\(serverScopeID.uuidString.lowercased())" } }
    func allows(_ routeHash: String) -> Bool { guard let key, !routeHash.isEmpty else { return false }; return defaults.string(forKey: key) == routeHash }
    func remember(_ routeHash: String) { guard let key, !routeHash.isEmpty else { return }; defaults.set(routeHash, forKey: key) }
    func forget() { if let key { defaults.removeObject(forKey: key) } }
}
