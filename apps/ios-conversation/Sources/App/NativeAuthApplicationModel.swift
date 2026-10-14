import Foundation
import SwiftUI

public struct AuthenticatedNativeChatCredentials: NativeChatSessionCredentials {
    let manager: NativeAuthSessionManager
    let partition: AuthenticatedLocalPartition
    public func authorization(scope: DataScope) async throws -> String {
        guard scope == partition.scope else { throw CatpawError.scopeMismatch }
        return try await manager.authorization(subject: partition.subject)
    }
    public func rejected(scope: DataScope) async { if scope == partition.scope { try? await manager.rejectAuthorization(subject: partition.subject) } }
}
@MainActor final class NativeAuthApplicationModel: ObservableObject {
    @Published private(set) var state = NativeAuthSnapshot(phase: .signedOut, user: nil, generation: 0, message: nil)
    @Published private(set) var chat: ConversationFirstModel?
    @Published private(set) var error: String?
    @Published private(set) var registrationNotice: String?
    @Published private(set) var actionBusy = false
    let isFixture: Bool
    private let configuration: NativeAuthConfiguration?
    private let manager: NativeAuthSessionManager?
    private var localVault:(any NativeAuthVault)?
    private var localBarrier:(any NativeAuthLogoutBarrier)?
    private let root: URL
    private var namespace: String?
    private var backend: NativeChatHTTPBackend?
    private var subscription: Task<Void, Never>?
    private var started = false
    private var openingAccountEpoch: Int?
    private var lifecycleEpoch=0
    private var logoutInProgress=false
    var canSignIn: Bool { manager != nil && !actionBusy && state.phase != .signingIn && state.phase != .restoring }
    var canStartExperience: Bool { canSignIn && state.phase != .storageBlocked }
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Keep the production storage/Keychain namespace stable across this fix.
        var directory = "CatpawM-ConversationFirst-r7"
        var fixture = false
        #if DEBUG
        let fixtureScenario = ProcessInfo.processInfo.environment["R7_AUTH_TEST_SCENARIO"] ?? ""
        if let id = ProcessInfo.processInfo.environment["R7_AUTH_TEST_STORE"], UUID(uuidString: id) != nil, ["account-isolation","cold-valid","cold-expired","cold-revoked"].contains(fixtureScenario) { directory = "CatpawM-ConversationFirst-r8-qa-" + id; fixture = true }
        #endif
        root = base.appendingPathComponent(directory,isDirectory:true); isFixture = fixture
        do {
            let keys = ["CatpawSupabaseProjectURL","CatpawSupabasePublishableKey","CatpawBackendOrigin","CatpawServerScopeID"]
            var values = Dictionary(uniqueKeysWithValues: keys.compactMap { k in (Bundle.main.object(forInfoDictionaryKey:k) as? String).map { (k,$0) } })
            #if DEBUG
            if fixture { values = [keys[0]:"https://abcdefghijklmnopqrst.supabase.co",keys[1]:"sb_publishable_test_public_value",keys[2]:"https://backend.example.invalid",keys[3]:"11111111-2222-4333-8444-555555555555"] }
            #endif
            configuration = try NativeAuthConfiguration.read(values)
            if let configuration {
                var vault: any NativeAuthVault = NativeAuthKeychainVault(service:"com.example.CatpawM.ConversationFirst.Auth." + directory,issuer:configuration.issuer)
                var barrier: any NativeAuthLogoutBarrier = NativeAuthFileLogoutBarrier(url:root.appendingPathComponent("auth-state"))
                var remote: any NativeAuthRemote = NativeAuthHTTPRemote(configuration:configuration)
                #if DEBUG
                if fixture {
                    remote = NativeAuthFixtureRemote(issuer:configuration.issuer,scenario:fixtureScenario)
                    if fixtureScenario.hasPrefix("cold-") {
                        let id = stableID("a.test@example.invalid")
                        let saved = NativeAuthCredential(issuer:configuration.issuer,user:.init(id:id,email:"a.test@example.invalid"),accessToken:"fixture."+id.uuidString+".signature",refreshToken:"fixture-"+id.uuidString,expiresAt:Date().addingTimeInterval(fixtureScenario == "cold-expired" ? -1 : 3600))
                        let memory = NativeAuthColdFixtureStorage(saved); vault = memory; barrier = memory
                    }
                }
                #endif
                localVault=vault;localBarrier=barrier
                manager = NativeAuthSessionManager(configuration:configuration,remote:remote,vault:vault,barrier:barrier)
            } else { manager = nil; error = "登录连接尚未配置。" }
        } catch { configuration = nil; manager = nil; self.error = "登录公开配置未通过校验。" }
    }
    // Test initializer is mock-only; production continues using the configured Keychain.
    init(configuration:NativeAuthConfiguration,manager:NativeAuthSessionManager,vault:any NativeAuthVault,barrier:any NativeAuthLogoutBarrier,root:URL) {
        self.configuration=configuration;self.manager=manager;self.localVault=vault;self.localBarrier=barrier;self.root=root;self.isFixture=true
    }
    private var receiptURL:URL { root.appendingPathComponent("last-local-workspace.json") }
    private func saveLocalReceipt(_ receipt:LocalConversationReceipt) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(receipt).write(to:receiptURL,options:.atomic)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:receiptURL.path)
        var url=receiptURL;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
    }
    private func openLocalConversation() async {
        guard let configuration,let localVault,let localBarrier,
              let bytes=try? Data(contentsOf:receiptURL),let receipt=try? JSONDecoder().decode(LocalConversationReceipt.self,from:bytes),
              let candidate=try? localVault.load(),let signedOut=try? localBarrier.isSignedOut(),
              let partition=receipt.partition(candidate:candidate,signedOut:signedOut,expectedIssuer:configuration.issuer) else { return }
        let url=root.appendingPathComponent(partition.namespace).appendingPathComponent("local.store")
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        do {
            let repository=try Repository(persistence:SwiftDataPersistence(url:url))
            // The local receipt conveys local reading only; it never authorizes HTTP.
            let backend=NativeChatHTTPBackend(configuration:try NativeChatConfiguration(origin:configuration.backendOrigin,localScope:partition.scope,serverScopeID:receipt.serverScopeID,publishableKey:configuration.publishableKey,expectedSubjectID:partition.subject),credentials:AuthenticatedNativeChatCredentials(manager:manager!,partition:partition))
            let selected:any ConversationBackend=isFixture ? UnconfiguredConversationBackend() : backend
            let preview=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:selected),scope:partition.scope,imageStore:try FileConversationImageByteStore(root:url.deletingLastPathComponent().appendingPathComponent("image-bytes")),taskPlanService:isFixture ? nil : ConversationTaskPlanService(repository:repository,scope:partition.scope,backend:backend),artifactEditService:isFixture ? nil : ConversationArtifactEditService(repository:repository,scope:partition.scope,backend:backend),taskActionService:isFixture ? nil : ConversationTaskActionService(repository:repository,scope:partition.scope,backend:backend),taskControlService:isFixture ? nil : ConversationTaskControlService(repository:repository,scope:partition.scope,backend:backend),subjectID:partition.subject)
            preview.setNetworkAdmissionAllowed(false);await preview.start();self.backend=backend;chat=preview;namespace=partition.namespace
        } catch { self.error=NativeAuthError.storage.localizedDescription }
    }
    func start() async {
        guard !started, let manager else { return }; started = true
        await openLocalConversation()
        subscription = Task { [weak self] in
            for await snapshot in await manager.changes() { guard let self, !Task.isCancelled else { return }; await self.receive(snapshot) }
        }
        do { try await manager.restore() } catch { self.error = (error as? NativeAuthError ?? .unavailable).localizedDescription }
    }
    private func receive(_ snapshot: NativeAuthSnapshot) async {
        guard let manager, !Task.isCancelled,!logoutInProgress else { return }
        let openingEpoch=lifecycleEpoch
        let current = await manager.snapshot()
        guard !Task.isCancelled,!logoutInProgress,openingEpoch==lifecycleEpoch, current.generation == snapshot.generation,
              current.phase == snapshot.phase, current.user == snapshot.user else { return }
        state = snapshot
        if snapshot.phase == .restoring { chat?.setNetworkAdmissionAllowed(false);return }
        if [.authenticated,.refreshing].contains(snapshot.phase), let user = snapshot.user, let configuration {
            if snapshot.phase == .refreshing { if chat == nil { await detachChat() };return }
            guard openingAccountEpoch != openingEpoch else { return };openingAccountEpoch=openingEpoch;defer {if openingAccountEpoch==openingEpoch {openingAccountEpoch=nil}}
            let serverScope: UUID
            do {
                if isFixture,let fixed = configuration.serverScopeID { serverScope = fixed }
                else { let token = try await manager.authorization(subject:user.id);serverScope = try await NativeAuthHTTPRemote(configuration:configuration).applicationScope(accessToken:String(token.dropFirst(7)),subject:user.id) }
            } catch {guard !logoutInProgress,openingEpoch==lifecycleEpoch else {return};await detachChat();guard !logoutInProgress,openingEpoch==lifecycleEpoch else {return};self.error = (error as? NativeApplicationSessionError)?.localizedDescription ?? "工作区连接失败，请点‘开始体验’重试。";return }
            let afterScope = await manager.snapshot();guard !logoutInProgress,openingEpoch==lifecycleEpoch,afterScope.generation == snapshot.generation,afterScope.phase == .authenticated,afterScope.user == user else { return }
            let partition = AuthenticatedLocalPartition(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope)
            if namespace == partition.namespace {
                try? saveLocalReceipt(.init(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope))
                chat?.setNetworkAdmissionAllowed(true);error=nil;return
            }
            // Refresh may retain an already opened, validated account; only a
            // fully authenticated snapshot may open a new local partition.
            guard snapshot.phase == .authenticated else { await detachChat(); return }
            await detachChat()
            let admitted = await manager.snapshot()
            guard !Task.isCancelled,!logoutInProgress,openingEpoch==lifecycleEpoch, admitted.generation == snapshot.generation,
                  admitted.phase == .authenticated, admitted.user == user else { return }
            do {
                let directory = root.appendingPathComponent(partition.namespace,isDirectory:true)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
                var excluded = directory; var resource = URLResourceValues(); resource.isExcludedFromBackup = true; try excluded.setResourceValues(resource)
                let repository = try Repository(persistence:SwiftDataPersistence(url:directory.appendingPathComponent("local.store")))
                let region = (Bundle.main.object(forInfoDictionaryKey:"CatpawEdgeRegion") as? String).flatMap { $0.isEmpty ? nil : $0 }
                let http = NativeChatHTTPBackend(configuration:try NativeChatConfiguration(origin:configuration.backendOrigin,localScope:partition.scope,serverScopeID:serverScope,publishableKey:configuration.publishableKey,edgeRegion:region,expectedSubjectID:partition.subject),credentials:AuthenticatedNativeChatCredentials(manager:manager,partition:partition))
                backend = http
                let selected: any ConversationBackend = isFixture ? UnconfiguredConversationBackend() : http
                chat = ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:selected),scope:partition.scope,imageStore:try FileConversationImageByteStore(root:directory.appendingPathComponent("image-bytes")),taskPlanService:isFixture ? nil : ConversationTaskPlanService(repository:repository,scope:partition.scope,backend:http),artifactEditService:isFixture ? nil : ConversationArtifactEditService(repository:repository,scope:partition.scope,backend:http),taskActionService:isFixture ? nil : ConversationTaskActionService(repository:repository,scope:partition.scope,backend:http),taskControlService:isFixture ? nil : ConversationTaskControlService(repository:repository,scope:partition.scope,backend:http),subjectID:partition.subject)
                namespace = partition.namespace; error = nil
                try saveLocalReceipt(.init(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope))
            } catch { self.error = "此账号的本地存储无法打开；原文件已保留。" }
        } else {
            // Transient restore failure retains an already admitted local receipt only.
            let mayReadLocally = snapshot.phase == .signedOut && snapshot.message != nil && (try? localBarrier?.isSignedOut()) == false
            if mayReadLocally { chat?.setNetworkAdmissionAllowed(false) }
            else { await detachChat() }
            if let message = snapshot.message { error = message }
        }
    }
    private func detachChat() async {
        if !(await finishDetaching(takeChat())) {error="有修改草稿未能保存，请核对此前已保存的版本。"}
    }
    private func takeChat() -> (ConversationFirstModel?,NativeChatHTTPBackend?,String?) {
        let previous = chat; chat = nil
        let previousBackend = backend; backend = nil
        let previousNamespace = namespace; namespace = nil
        previous?.setNetworkAdmissionAllowed(false)
        return (previous,previousBackend,previousNamespace)
    }
    private func finishDetaching(_ detached:(ConversationFirstModel?,NativeChatHTTPBackend?,String?)) async -> Bool {
        await detached.1?.close()
        let saved=await detached.0?.deactivate() ?? true
        if let previousNamespace=detached.2 {
            let caches = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("CatpawM-r7",isDirectory:true).appendingPathComponent(previousNamespace,isDirectory:true)
            try? FileManager.default.removeItem(at:caches)
        }
        return saved
    }
    func signUp(email: String,password: String) async {
        guard canSignIn,let manager else { return };actionBusy = true;error = nil;registrationNotice = nil;defer { actionBusy = false }
        do { if try await manager.signUp(email:email,password:password) { registrationNotice = "注册请求已受理。请在邮箱点击确认链接，再返回此处登录；若邮箱已有账号，请直接登录。" } }
        catch { self.error = (error as? NativeAuthError ?? .unavailable).localizedDescription }
    }
    func startExperience() async {
        guard canStartExperience,let manager else { return };actionBusy = true;error = nil;defer { actionBusy = false }
        do { try await manager.startExperience();await receive(await manager.snapshot()) }
        catch { self.error = (error as? NativeAuthError ?? .unavailable).localizedDescription }
    }
    func signIn(email: String, password: String) async {
        guard canSignIn, let manager else { return }; actionBusy = true; error = nil;registrationNotice = nil; defer { actionBusy = false }
        do { try await manager.signIn(email:email,password:password) } catch { self.error = (error as? NativeAuthError ?? .unavailable).localizedDescription }
    }
    func signOut() async {
        guard let manager, !actionBusy else { return };actionBusy=true;logoutInProgress=true;lifecycleEpoch += 1
        defer {logoutInProgress=false;actionBusy=false}
        let detached=takeChat()
        // Close manager admission immediately; local draining must not postpone its barrier.
        async let cleanup:Bool=finishDetaching(detached)
        try? FileManager.default.removeItem(at:receiptURL)
        do { try await manager.signOut() } catch { self.error = NativeAuthError.storage.localizedDescription }
        if !(await cleanup) {error="有修改草稿未能保存，请核对此前已保存的版本。"}
        state=await manager.snapshot()
    }
    func cancelLogin() async { guard let manager else { return }; do { try await manager.cancelLogin() } catch { self.error = NativeAuthError.storage.localizedDescription } }
    func retryStorage() async { guard let manager else { return }; do { try await manager.retryPersistence() } catch { self.error = (error as? NativeAuthError ?? .storage).localizedDescription } }
    func foreground() async {
        guard let manager, !actionBusy, started else { return }
        let current = await manager.snapshot()
        guard !Task.isCancelled, current.phase != .restoring, current.phase != .signingIn else { return }
        do { try await manager.restore() } catch { self.error = (error as? NativeAuthError ?? .unavailable).localizedDescription }
    }
}

#if DEBUG
private actor NativeAuthFixtureRemote: NativeAuthRemote {
    let issuer: String
    let scenario: String
    init(issuer: String, scenario: String) { self.issuer = issuer; self.scenario = scenario }
    func signIn(email: String,password: String) async throws -> NativeAuthCredential {
        guard ["a.test@example.invalid","b.test@example.invalid"].contains(email),password == "fixture-only" else { throw NativeAuthError.invalidCredentials }
        return credential(id:stableID(email),email:email)
    }
    private func credential(id:UUID,email:String?) -> NativeAuthCredential { .init(issuer:issuer,user:.init(id:id,email:email),accessToken:"fixture."+id.uuidString+".signature",refreshToken:"fixture-"+id.uuidString,expiresAt:Date().addingTimeInterval(3600)) }
    func refresh(refreshToken:String) async throws -> NativeAuthCredential {
        if scenario == "cold-expired" { try? await Task.sleep(nanoseconds:8_000_000_000) }
        guard refreshToken.hasPrefix("fixture-"),let id = UUID(uuidString:String(refreshToken.dropFirst(8))) else { throw NativeAuthError.loginRequired }; return credential(id:id,email:nil)
    }
    func user(accessToken:String) async throws -> NativeAuthUser {
        if ["cold-valid","cold-revoked"].contains(scenario) { try? await Task.sleep(nanoseconds:8_000_000_000) }
        if scenario == "cold-revoked" { throw NativeAuthError.loginRequired }
        let parts = accessToken.split(separator:"."); guard parts.count == 3,let id = UUID(uuidString:String(parts[1])) else { throw NativeAuthError.loginRequired }; return .init(id:id)
    }
    func signOut(accessToken:String) async throws { }
}
private final class NativeAuthColdFixtureStorage: NativeAuthVault, NativeAuthLogoutBarrier, @unchecked Sendable {
    private let lock = NSLock()
    private var candidate: NativeAuthCredential?
    private var signedOut = false
    init(_ candidate: NativeAuthCredential) { self.candidate = candidate }
    func load() throws -> NativeAuthCredential? { lock.lock(); defer { lock.unlock() }; return candidate }
    func save(_ value: NativeAuthCredential) throws { lock.lock(); defer { lock.unlock() }; candidate = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; candidate = nil }
    func isSignedOut() throws -> Bool { lock.lock(); defer { lock.unlock() }; return signedOut }
    func setSignedOut(_ value: Bool) throws { lock.lock(); defer { lock.unlock() }; signedOut = value }
}
#endif
