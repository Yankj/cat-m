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
    /// Intro gate. Anonymous warm-up runs in the background regardless; the UI stays on the intro
    /// until `completeOnboarding()` succeeds. Key: `CatpawOnboarding.completedKey`.
    @Published private(set) var onboarding: OnboardingGateState = .needsOnboarding { didSet { needsOnboarding = onboarding.needsOnboarding } }
    @Published private(set) var needsOnboarding = true
    private var warmup: Task<Void, Never>?
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
            // Debug (simulator) builds keep an unconfigured Info.plist for the review scripts; a developer
            // may supply the PUBLIC Supabase/Edge values via the Xcode scheme environment instead.
            if values.values.allSatisfy(\.isEmpty), !fixture {
                let env = ProcessInfo.processInfo.environment
                let fromEnv = ["CatpawSupabaseProjectURL":"CATPAW_SUPABASE_PROJECT_URL","CatpawSupabasePublishableKey":"CATPAW_SUPABASE_PUBLISHABLE_KEY","CatpawBackendOrigin":"CATPAW_BACKEND_ORIGIN","CatpawServerScopeID":"CATPAW_SERVER_SCOPE_ID"]
                for (key,name) in fromEnv { if let value = env[name], !value.isEmpty { values[key] = value } }
            }
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
        let gate = CatpawOnboarding.initialState(fixture: fixture); onboarding = gate; needsOnboarding = gate.needsOnboarding
    }
    // Test initializer is mock-only; production continues using the configured Keychain.
    init(configuration:NativeAuthConfiguration,manager:NativeAuthSessionManager,vault:any NativeAuthVault,barrier:any NativeAuthLogoutBarrier,root:URL) {
        self.configuration=configuration;self.manager=manager;self.localVault=vault;self.localBarrier=barrier;self.root=root;self.isFixture=true
        onboarding = .completed; needsOnboarding = false
    }
    private var receiptURL:URL { root.appendingPathComponent("last-local-workspace.json") }
    /// File/Keychain/SwiftData work never runs on the main actor (launch white-screen fix):
    /// SwiftDataPersistence blocks its caller on a semaphore, Keychain and protected-file reads can stall.
    private func saveLocalReceipt(_ receipt:LocalConversationReceipt) async throws {
        let root=root,receiptURL=receiptURL
        try await Task.detached(priority:.utility) {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try JSONEncoder().encode(receipt).write(to:receiptURL,options:.atomic)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:receiptURL.path)
            var url=receiptURL;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
        }.value
    }
    /// Opens the account partition stores off the main actor. `prepare` creates the protected, backup-excluded directory.
    nonisolated private static func openStores(directory:URL,prepare:Bool) async throws -> (Repository,FileConversationImageByteStore) {
        try await Task.detached(priority:.userInitiated) {
            if prepare {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
                var excluded = directory; var resource = URLResourceValues(); resource.isExcludedFromBackup = true; try excluded.setResourceValues(resource)
            }
            let repository=try Repository(persistence:SwiftDataPersistence(url:directory.appendingPathComponent("local.store")))
            return (repository,try FileConversationImageByteStore(root:directory.appendingPathComponent("image-bytes")))
        }.value
    }
    private func openLocalConversation() async {
        guard let configuration,let localVault,let localBarrier else { return }
        let receiptURL=receiptURL,root=root,issuer=configuration.issuer
        let found:(LocalConversationReceipt,AuthenticatedLocalPartition)? = await Task.detached(priority:.userInitiated) {
            guard let bytes=try? Data(contentsOf:receiptURL),let receipt=try? JSONDecoder().decode(LocalConversationReceipt.self,from:bytes),
                  let candidate=try? localVault.load(),let signedOut=try? localBarrier.isSignedOut(),
                  let partition=receipt.partition(candidate:candidate,signedOut:signedOut,expectedIssuer:issuer),
                  FileManager.default.fileExists(atPath:root.appendingPathComponent(partition.namespace).appendingPathComponent("local.store").path) else { return nil }
            return (receipt,partition)
        }.value
        guard let found=found,chat == nil else { return }
        let (receipt,partition)=found
        let url=root.appendingPathComponent(partition.namespace).appendingPathComponent("local.store")
        do {
            let (repository,imageStore)=try await Self.openStores(directory:url.deletingLastPathComponent(),prepare:false)
            guard chat == nil,!logoutInProgress else { return }
            // The local receipt conveys local reading only; it never authorizes HTTP.
            let chatConfiguration=try NativeChatConfiguration(origin:configuration.backendOrigin,localScope:partition.scope,serverScopeID:receipt.serverScopeID,publishableKey:configuration.publishableKey,expectedSubjectID:partition.subject)
            let credentials=AuthenticatedNativeChatCredentials(manager:manager!,partition:partition)
            Task { await CatpawPushTokenUploader.shared.setAuthorization { try await credentials.authorization(scope: partition.scope) } }
            let backend=NativeChatHTTPBackend(configuration:chatConfiguration,credentials:credentials)
            let memory=isFixture ? nil : try NativeMemoryComposition.service(repository:repository,configuration:chatConfiguration,credentials:credentials)
            var selected:any ConversationBackend=isFixture ? UnconfiguredConversationBackend() : backend
            #if DEBUG
            selected=CatpawDemoBackendSwitch.select(selected)
            #endif
            let preview=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:selected,resilience:ConnectionMonitorResilience(),outbox:ConversationOutbox(fileURL:url.deletingLastPathComponent().appendingPathComponent("conversation-outbox.json"))),scope:partition.scope,imageStore:imageStore,taskPlanService:isFixture ? nil : ConversationTaskPlanService(repository:repository,scope:partition.scope,backend:backend),artifactEditService:isFixture ? nil : ConversationArtifactEditService(repository:repository,scope:partition.scope,backend:backend),taskActionService:isFixture ? nil : ConversationTaskActionService(repository:repository,scope:partition.scope,backend:backend),taskControlService:isFixture ? nil : ConversationTaskControlService(repository:repository,scope:partition.scope,backend:backend),memoryService:memory,inboxService:isFixture ? nil : ConversationInboxService(reference:.init(scope:partition.scope,serverScopeID:chatConfiguration.serverScopeID,subjectID:partition.subject),backend:backend),subjectID:partition.subject)
            preview.setNetworkAdmissionAllowed(false);await preview.start();self.backend=backend;chat=preview;namespace=partition.namespace
        } catch { self.error=NativeAuthError.storage.localizedDescription }
    }
    /// Starts the background warm-up (local preview, restore, anonymous experience identity).
    /// Safe to call from `.task`: the warm-up is an unstructured task, so the gate can await it.
    func start() async {
        guard !started, let manager else { return }; started = true
        let task = Task { [weak self] in guard let self else { return }; await self.warmUp(manager) }
        warmup = task; await task.value
    }
    private func warmUp(_ manager: NativeAuthSessionManager) async {
        await openLocalConversation()
        subscription = Task { [weak self] in
            for await snapshot in await manager.changes() { guard let self, !Task.isCancelled else { return }; await self.receive(snapshot) }
        }
        do { try await manager.restore() } catch { self.error = (error as? NativeAuthError ?? .unavailable).localizedDescription }
        // Normal launch goes straight into the conversation: with no saved session, open the
        // existing anonymous experience identity (Supabase signInAnonymously) instead of a login wall.
        let restored = await manager.snapshot()
        if !isFixture, restored.phase == .signedOut, restored.user == nil, restored.message == nil, autoAnonymousSession { await startExperience() }
    }
    /// Info.plist `CatpawAutoAnonymousSession` = NO disables the automatic experience identity.
    /// "开启" button. Persists the intro flag, waits for the background warm-up, retries once, then
    /// either enters the conversation (`.completed`) or exposes `.failed(message)`; calling again retries.
    func completeOnboarding() async {
        guard onboarding != .entering, onboarding != .completed else { return }
        CatpawOnboarding.markCompleted(); onboarding = .entering
        if warmup == nil { await start() } else { await warmup?.value }
        if await waitForChat() { onboarding = .completed; return }
        await retryWarmup()
        if await waitForChat() { onboarding = .completed; return }
        onboarding = .failed(error ?? (manager == nil ? "登录连接尚未配置。" : "暂时连不上服务，请稍后重试。"))
    }
    private func retryWarmup() async {
        guard let manager else { return }
        let current = await manager.snapshot()
        if current.phase == .signedOut, current.user == nil { error = nil; await startExperience() }
        else if current.phase == .authenticated, chat == nil { error = nil; await receive(current) }
        else { await foreground() }
    }
    /// Waits while auth/workspace opening is in flight; gives up ~1s after it goes idle without a chat.
    private func waitForChat() async -> Bool {
        let deadline = Date().addingTimeInterval(30); var idleTicks = 0
        while chat == nil, Date() < deadline, !Task.isCancelled {
            let inFlight = actionBusy || openingAccountEpoch != nil || [.restoring,.signingIn,.refreshing].contains(state.phase)
            idleTicks = inFlight ? 0 : idleTicks + 1
            if idleTicks > 10 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return chat != nil
    }
    private var autoAnonymousSession: Bool { (Bundle.main.object(forInfoDictionaryKey:"CatpawAutoAnonymousSession") as? Bool) ?? true }
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
                try? await saveLocalReceipt(.init(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope))
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
                let (repository,imageStore) = try await Self.openStores(directory:directory,prepare:true)
                let reopened = await manager.snapshot()
                guard !Task.isCancelled,!logoutInProgress,openingEpoch==lifecycleEpoch,chat == nil,reopened.generation == snapshot.generation,
                      reopened.phase == .authenticated,reopened.user == user else { return }
                let region = (Bundle.main.object(forInfoDictionaryKey:"CatpawEdgeRegion") as? String).flatMap { $0.isEmpty ? nil : $0 }
                let chatConfiguration=try NativeChatConfiguration(origin:configuration.backendOrigin,localScope:partition.scope,serverScopeID:serverScope,publishableKey:configuration.publishableKey,edgeRegion:region,expectedSubjectID:partition.subject)
                let credentials=AuthenticatedNativeChatCredentials(manager:manager,partition:partition)
                Task { await CatpawPushTokenUploader.shared.setAuthorization { try await credentials.authorization(scope: partition.scope) } }
                let http=NativeChatHTTPBackend(configuration:chatConfiguration,credentials:credentials)
                let memory=isFixture ? nil : try NativeMemoryComposition.service(repository:repository,configuration:chatConfiguration,credentials:credentials)
                backend = http
                var selected: any ConversationBackend = isFixture ? UnconfiguredConversationBackend() : http
                #if DEBUG
                selected = CatpawDemoBackendSwitch.select(selected)
                #endif
                chat = ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:selected,resilience:ConnectionMonitorResilience(),outbox:ConversationOutbox(fileURL:directory.appendingPathComponent("conversation-outbox.json"))),scope:partition.scope,imageStore:imageStore,taskPlanService:isFixture ? nil : ConversationTaskPlanService(repository:repository,scope:partition.scope,backend:http),artifactEditService:isFixture ? nil : ConversationArtifactEditService(repository:repository,scope:partition.scope,backend:http),taskActionService:isFixture ? nil : ConversationTaskActionService(repository:repository,scope:partition.scope,backend:http),taskControlService:isFixture ? nil : ConversationTaskControlService(repository:repository,scope:partition.scope,backend:http),memoryService:memory,inboxService:isFixture ? nil : ConversationInboxService(reference:.init(scope:partition.scope,serverScopeID:chatConfiguration.serverScopeID,subjectID:partition.subject),backend:http),subjectID:partition.subject)
                namespace = partition.namespace; error = nil
                try await saveLocalReceipt(.init(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope))
            } catch { self.error = "此账号的本地存储无法打开；原文件已保留。" }
        } else {
            // Transient restore failure retains an already admitted local receipt only.
            let barrier = localBarrier
            var mayReadLocally = false
            if snapshot.phase == .signedOut && snapshot.message != nil {
                mayReadLocally = await Task.detached(priority:.userInitiated) { (try? barrier?.isSignedOut()) == false }.value
            }
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
        await CatpawPushTokenUploader.shared.clearAuthorization()
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
