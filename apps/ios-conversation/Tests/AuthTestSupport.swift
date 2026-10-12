import Foundation
#if canImport(CatpawM)
@testable import CatpawM
#endif
final class AuthTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}
final class AuthTestStorage: NativeAuthVault, NativeAuthLogoutBarrier, @unchecked Sendable {
    private let lock = NSLock(); private var credential: NativeAuthCredential?; private var signedOut = false
    private var failSave = false; private var failClear = false
    func failures(save: Bool = false, clear: Bool = false) { lock.lock(); defer { lock.unlock() }; failSave = save; failClear = clear }
    func load() throws -> NativeAuthCredential? { lock.lock(); defer { lock.unlock() }; return credential }
    func save(_ value: NativeAuthCredential) throws { lock.lock(); defer { lock.unlock() }; if failSave { throw NativeAuthError.storage }; credential = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; if failClear { throw NativeAuthError.storage }; credential = nil }
    func isSignedOut() throws -> Bool { lock.lock(); defer { lock.unlock() }; return signedOut }
    func setSignedOut(_ value: Bool) throws { lock.lock(); defer { lock.unlock() }; signedOut = value }
}
actor AuthTestRemote: NativeAuthRemote {
    let issuer: String; let id: UUID; let clock: AuthTestClock; private var logins = 0; private var refreshes = 0
    private var failRefresh = false; private var lateLogin = false
    func behavior(failRefresh: Bool = false, lateLogin: Bool = false) { self.failRefresh = failRefresh; self.lateLogin = lateLogin }
    init(issuer: String, id: UUID, clock: AuthTestClock = AuthTestClock()) { self.issuer = issuer; self.id = id; self.clock = clock }
    func signIn(email: String, password: String) async throws -> NativeAuthCredential { logins += 1; if lateLogin { try? await Task.sleep(nanoseconds:100_000_000) }; return .init(issuer: issuer, user: .init(id: id), accessToken: "test.access.signature", refreshToken: "synthetic-refresh-only", expiresAt: clock.now().addingTimeInterval(3600)) }
    func refresh(refreshToken: String) async throws -> NativeAuthCredential { refreshes += 1; try await Task.sleep(nanoseconds:100_000_000); if failRefresh { throw NativeAuthError.unavailable }; return .init(issuer: issuer, user: .init(id: id), accessToken: "test.rotated.signature", refreshToken: "synthetic-rotated-only", expiresAt: clock.now().addingTimeInterval(3600)) }
    func user(accessToken: String) async throws -> NativeAuthUser { .init(id: id) }
    func signOut(accessToken: String) async throws { }
    func counts() -> Int { logins }
    func refreshCount() -> Int { refreshes }
}
func authCheck(_ good: Bool, _ text: String) throws { guard good else { throw NativeAuthError.invalidResponse }; print("PASS: " + text) }
actor NativeAuthBoundaryRemote: NativeAuthRemote {
    let issuer: String; let subject: UUID
    private var userWait: CheckedContinuation<NativeAuthUser, Error>?
    private var refreshWait: CheckedContinuation<NativeAuthCredential, Error>?
    init(issuer:String,subject:UUID) { self.issuer = issuer; self.subject = subject }
    func signIn(email:String,password:String) async throws -> NativeAuthCredential { candidate() }
    func candidate() -> NativeAuthCredential { .init(issuer:issuer,user:.init(id:subject),accessToken:"boundary.access.signature",refreshToken:"synthetic-boundary-only",expiresAt:Date().addingTimeInterval(3600)) }
    func user(accessToken:String) async throws -> NativeAuthUser { try await withCheckedThrowingContinuation { userWait = $0 } }
    func refresh(refreshToken:String) async throws -> NativeAuthCredential { try await withCheckedThrowingContinuation { refreshWait = $0 } }
    func signOut(accessToken:String) async throws { }
    func pendingUser() -> Bool { userWait != nil }
    func pendingRefresh() -> Bool { refreshWait != nil }
    func rejectUser() { userWait?.resume(throwing:NativeAuthError.loginRequired); userWait = nil }
    func rejectRefresh() { refreshWait?.resume(throwing:NativeAuthError.loginRequired); refreshWait = nil }
    func acceptUser() { userWait?.resume(returning:.init(id:subject)); userWait = nil }
}
actor AuthTestHTTPTransport: NativeAuthHTTPTransport {
    let id: UUID
    private var requests: [URLRequest] = []
    private var status = 200; private var anonymous = false
    init(id:UUID) { self.id = id }
    func response(status:Int = 200, anonymous:Bool = false) { self.status = status; self.anonymous = anonymous }
    func captured() -> [URLRequest] { requests }
    func send(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request)
        let user: [String:Any] = ["id":id.uuidString,"email":"synthetic@example.invalid","is_anonymous":anonymous]
        let object: [String:Any] = status != 200 ? ["error":"never-show-sensitive-body"] : (request.url!.path.hasSuffix("user") ? user : ["access_token":"fixture.http.signature","refresh_token":"synthetic-refresh-only","token_type":"bearer","expires_in":3600,"user":user])
        let code = request.url!.path.hasSuffix("logout") && status == 200 ? 204 : status
        return (try JSONSerialization.data(withJSONObject:object),HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!)
    }
}

actor AnonymousTestRemote: NativeAuthRemote {
    let issuer: String; let id = UUID(); let clock: AuthTestClock
    private var creations = 0; private var refreshes = 0; private var users = 0
    private var unavailable = false;private var holdCreation = false
    private var creationWait: CheckedContinuation<NativeAuthCredential,Error>?
    init(issuer:String,clock:AuthTestClock = AuthTestClock()) { self.issuer = issuer;self.clock = clock }
    func behavior(unavailable:Bool = false,hold:Bool = false) { self.unavailable = unavailable;holdCreation = hold }
    func candidate(expired:Bool = false) -> NativeAuthCredential { .init(issuer:issuer,user:.init(id:id,isAnonymous:true),accessToken:"synthetic.anon.signature",refreshToken:"synthetic-anon-only",expiresAt:clock.now().addingTimeInterval(expired ? -1 : 3600)) }
    func signInAnonymously() async throws -> NativeAuthCredential { creations += 1;if holdCreation { return try await withCheckedThrowingContinuation { creationWait = $0 } };return candidate() }
    func signIn(email:String,password:String) async throws -> NativeAuthCredential { throw NativeAuthError.invalidCredentials }
    func refresh(refreshToken:String) async throws -> NativeAuthCredential { refreshes += 1;if unavailable { throw NativeAuthError.unavailable };return candidate() }
    func user(accessToken:String) async throws -> NativeAuthUser { users += 1;if unavailable { throw NativeAuthError.unavailable };return .init(id:id,isAnonymous:true) }
    func signOut(accessToken:String) async throws { }
    func revokeApplicationSession(accessToken:String) async throws { }
    func counts() -> (Int,Int,Int) { (creations,refreshes,users) }
    func waiting() -> Bool { creationWait != nil }
    func release() { creationWait?.resume(returning:candidate());creationWait = nil }
}
enum AnonymousAuthScenarios {
    static func run() async throws {
        let config = try NativeAuthConfiguration(projectURL:URL(string:"https://abcdefghijklmnopqrst.supabase.co")!,publishableKey:"sb_publishable_synthetic_public_123",backendOrigin:URL(string:"https://backend.example.invalid")!)
        let remote = AnonymousTestRemote(issuer:config.issuer),storage = AuthTestStorage()
        let manager = NativeAuthSessionManager(configuration:config,remote:remote,vault:storage,barrier:storage)
        try await manager.restore();let initially = await remote.counts(),initialState = await manager.snapshot()
        try authCheck(initially.0 == 0 && initialState.phase == .signedOut,"startup never creates an anonymous identity")
        try await manager.startExperience();let first = await manager.snapshot();let firstCounts = await remote.counts()
        try authCheck(first.phase == .authenticated && first.user?.isAnonymous == true && firstCounts.0 == 1 && firstCounts.2 == 1 && storage.load()?.user == first.user,"explicit entrance verifies and persists one real-shaped anonymous identity")
        let reopened = NativeAuthSessionManager(configuration:config,remote:remote,vault:storage,barrier:storage)
        try await reopened.restore();try await reopened.startExperience();let restored = await reopened.snapshot();let after = await remote.counts()
        try authCheck(restored.user == first.user && after.0 == 1 && after.2 == 2,"cold restore and entrance reuse the verified identity without another signup")
        let expiredRemote = AnonymousTestRemote(issuer:config.issuer),expiredStorage = AuthTestStorage();try expiredStorage.save(await expiredRemote.candidate(expired:true))
        let expired = NativeAuthSessionManager(configuration:config,remote:expiredRemote,vault:expiredStorage,barrier:expiredStorage)
        try await expired.startExperience();let rotated = await expiredRemote.counts(),rotatedState = await expired.snapshot()
        try authCheck(rotated.0 == 0 && rotated.1 == 1 && rotatedState.user?.id == expiredStorage.load()?.user.id,"expired anonymous credential refreshes the same subject")
        let failedRemote = AnonymousTestRemote(issuer:config.issuer),failedStore = AuthTestStorage();try failedStore.save(await failedRemote.candidate(expired:true));await failedRemote.behavior(unavailable:true)
        let failed = NativeAuthSessionManager(configuration:config,remote:failedRemote,vault:failedStore,barrier:failedStore)
        do { try await failed.startExperience();throw NativeAuthError.invalidResponse } catch NativeAuthError.unavailable { }
        do { try await failed.startExperience();throw NativeAuthError.invalidResponse } catch NativeAuthError.sessionRecoveryRequired { }
        let failedCount = await failedRemote.counts()
        try authCheck(failedCount.0 == 0 && failedStore.load() != nil,"failed and uncertain restore never substitutes a new identity")
        let slowRemote = AnonymousTestRemote(issuer:config.issuer),slowStore = AuthTestStorage();await slowRemote.behavior(hold:true)
        let slow = NativeAuthSessionManager(configuration:config,remote:slowRemote,vault:slowStore,barrier:slowStore)
        let active = Task { try await slow.startExperience() }
        while !(await slowRemote.waiting()) { await Task.yield() }
        do { try await slow.startExperience();throw NativeAuthError.invalidResponse } catch NativeAuthError.busy { }
        try await slow.cancelLogin();await slowRemote.release()
        do { try await active.value;throw NativeAuthError.invalidResponse } catch NativeAuthError.cancelled { }
        let late = await slow.snapshot(),slowCounts = await slowRemote.counts()
        try authCheck(slowCounts.0 == 1 && late.phase == .signedOut && late.user == nil && slowStore.load() == nil,"double taps create once and cancelled late response cannot reauthenticate")
        let saveRemote = AnonymousTestRemote(issuer:config.issuer),saveStore = AuthTestStorage();saveStore.failures(save:true)
        let save = NativeAuthSessionManager(configuration:config,remote:saveRemote,vault:saveStore,barrier:saveStore)
        do { try await save.startExperience();throw NativeAuthError.invalidResponse } catch NativeAuthError.storage { }
        do { try await save.startExperience();throw NativeAuthError.invalidResponse } catch NativeAuthError.storage { }
        saveStore.failures();try await save.retryPersistence();let saveCount = await saveRemote.counts(),savedState = await save.snapshot()
        try authCheck(saveCount.0 == 1 && savedState.phase == .authenticated,"save retry persists the pending identity without another anonymous signup")
        try await reopened.signOut();let signedOut = NativeAuthSessionManager(configuration:config,remote:remote,vault:storage,barrier:storage);try await signedOut.restore()
        try authCheck((await signedOut.snapshot()).phase == .signedOut && storage.load() == nil,"explicit logout barrier survives restart without restoring old anonymous credential")
        let transport = AuthTestHTTPTransport(id:UUID());await transport.response(anonymous:true)
        let http = NativeAuthHTTPRemote(configuration:config,transport:transport),candidate = try await http.signInAnonymously()
        _ = try await http.user(accessToken:candidate.accessToken);_ = try await http.refresh(refreshToken:candidate.refreshToken)
        let requests = await transport.captured(),body = try JSONSerialization.jsonObject(with:requests[0].httpBody!) as! [String:String]
        try authCheck(candidate.user.isAnonymous && requests.count == 3 && requests[0].httpMethod == "POST" && requests[0].url?.path == "/auth/v1/signup" && requests[0].url?.query == nil && body.isEmpty && requests[0].value(forHTTPHeaderField:"apikey") == config.publishableKey,"official anonymous HTTP contract uses POST signup empty body and modern public key")
        try authCheck(requests[1].httpMethod == "GET" && requests[1].url?.path == "/auth/v1/user" && requests[2].url?.query == "grant_type=refresh_token","anonymous identity still requires official user verification and refresh contract")
        let subject = UUID(),scope = UUID(),scopeTransport = ApplicationScopeTestTransport(subject:subject,scope:scope)
        let scoped = NativeAuthHTTPRemote(configuration:config,transport:scopeTransport)
        let admitted = try await scoped.applicationScope(accessToken:"synthetic.scope.signature",subject:subject)
        try authCheck(admitted == scope,"account bootstrap reads the deployed permissions.local_output wire contract")
        await scopeTransport.denied()
        do { _ = try await scoped.applicationScope(accessToken:"synthetic.scope.signature",subject:subject);throw NativeAuthError.unavailable } catch NativeAuthError.invalidResponse { }
        try authCheck(true,"top-level local_output cannot override a denied nested server permission")
        await scopeTransport.unavailable()
        do { _ = try await scoped.applicationScope(accessToken:"synthetic.scope.signature",subject:subject);throw NativeAuthError.invalidResponse }
        catch let error as NativeApplicationSessionError { try authCheck(error.httpStatus == 503 && error.code == "scope_store_unavailable" && !error.localizedDescription.contains("never_export"),"workspace failure exposes only validated HTTP status and safe error code") }

    }
}

actor ApplicationScopeTestTransport: NativeAuthHTTPTransport {
    let subject: UUID;let scope: UUID
    private var allow = true;private var status = 200
    init(subject:UUID,scope:UUID) { self.subject = subject;self.scope = scope }
    func denied() { allow = false }
    func unavailable() { status = 503 }
    func send(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        let row:[String:Any] = ["scope_id":scope.uuidString,"profile_id":UUID().uuidString,"workspace_id":UUID().uuidString,"permissions":["local_output":allow],"local_output":true]
        let body:[String:Any] = status == 200 ? ["schema_version":1,"subject_id":subject.uuidString,"scopes":[row]] : ["schema_version":1,"error":["code":"scope_store_unavailable","sensitive_body":"never_export_or_show"]]
        return (try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
    }
}

actor SceneObservationRaceBackend: ConversationBackend {
 private var reads=0;private var posts=0;private let message=UUID()
 private var waits:[Int:CheckedContinuation<Void,Never>]=[:]
 private var pending:[Int:(ConversationTurnRequest,CheckedContinuation<ConversationObservation,Never>)]=[:]
 func connection(scope:DataScope) async -> ConversationConnection { .init(state:.connected,provider:"Explicit scene race fixture",detail:"No network/model") }
 func reply(_ request:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> {
  posts += 1
  return AsyncThrowingStream { c in c.yield(.init(operationID:request.operationID,epoch:request.epoch,sequence:1,payload:.textDelta(messageID:message,text:"partial")));c.finish() }
 }
 func observe(_ request:ConversationTurnRequest) async throws -> ConversationObservation {
  reads += 1;let number=reads
  return await withCheckedContinuation { c in pending[number]=(request,c);waits.removeValue(forKey:number)?.resume() }
 }
 func waitForRead(_ number:Int) async { if pending[number] != nil { return };await withCheckedContinuation { waits[number]=$0 } }
 func resolve(_ number:Int) { guard let (r,c)=pending.removeValue(forKey:number) else { return };c.resume(returning:.init(request:r,events:[.init(operationID:r.operationID,epoch:r.epoch,sequence:2,payload:.completed(messageID:message,finalTextHash:textHash("partial")))])) }
 func postCount() -> Int { posts }
}
func verifySceneObservationReplacement() async throws {
 let folder=FileManager.default.temporaryDirectory.appendingPathComponent("SceneEpoch-"+UUID().uuidString);defer { try? FileManager.default.removeItem(at:folder) }
 let repo=try Repository(persistence:FilePersistence(url:folder.appendingPathComponent("store.json"))),backend=SceneObservationRaceBackend(),service=ConversationSessionService(repository:repo,backend:backend)
 let id=try await service.create(scope:Profiles.user)
 do { _=try await service.send(scope:Profiles.user,conversationID:id,text:"synthetic scene race",operationID:UUID()) } catch ConversationSessionError.unresolvedOperation { }
 let old=Task { try await service.observe(scope:Profiles.user,conversationID:id) };await backend.waitForRead(1)
 try await service.stopObserving(scope:Profiles.user,conversationID:id)
 let fresh=Task { try await service.observe(scope:Profiles.user,conversationID:id) };await backend.waitForRead(2)
 await backend.resolve(1)
 var oldRejected=false
 do { try await old.value } catch is CancellationError { oldRejected=true }
 let afterOld=try await service.read(scope:Profiles.user,conversationID:id)
 await backend.resolve(2);var freshAccepted=true
 do { try await fresh.value } catch { freshAccepted=false }
 let final=try await service.read(scope:Profiles.user,conversationID:id),posts=await backend.postCount()
 guard oldRejected,afterOld.turns.last?.state != .completed,freshAccepted,final.turns.last?.state == .completed,posts==1 else { throw CatpawError.invalid("Late stopped observer replaced the fresh observer: oldRejected=\(oldRejected),afterOld=\(afterOld.turns.last!.state.rawValue),freshAccepted=\(freshAccepted),posts=\(posts)") }
 print("PASS: stopped old observer cannot clear or complete a replacement; same request recovered once, POST count1")
}
