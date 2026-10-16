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

protocol NativeWorkspaceRetryClock: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}
struct NativeWorkspaceSystemClock: NativeWorkspaceRetryClock {
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}
struct NativeWorkspaceRetrySchedule: Sendable {
    let nominalSeconds: [Double]
    let jitter: @Sendable (Double) -> Double
    static let production = NativeWorkspaceRetrySchedule(
        nominalSeconds: [1, 2, 4, 8, 16],
        jitter: { $0 * Double.random(in: 0.8...1.0) }
    )
    func nanoseconds(attempt: Int) -> UInt64 {
        guard let last = nominalSeconds.last else { return 0 }
        let base = nominalSeconds[min(max(0, attempt), nominalSeconds.count - 1)]
        let seconds = min(last, max(0, jitter(base)))
        return UInt64(seconds * 1_000_000_000)
    }
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
    @Published private(set) var requiresSessionRestart = false
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
    private var reachabilitySubscription: Task<Void, Never>?
    private var started = false
    private var lifecycleEpoch=0
    private var logoutInProgress=false
    private var sessionRecoveryActive=false
    private var recoveryPathWait:Task<Void,Never>?
    /// p89g-2: the offline-trial "upgrade when the network returns" task; owned, cancelled by logout, bound to its lifecycleEpoch.
    private(set) var offlineRecoveryTask:Task<Void,Never>?
    /// p89g-2 test seams (nil in production): run after the first detached local read returns / right before the offline
    /// recovery task would start an experience.
    static var afterLocalReadHook:(@MainActor () async -> Void)?
    static var offlineRecoveryWillStartExperience:(@MainActor () -> Void)?
    private var recoveryImpossible=false
    private struct WorkspaceKey:Equatable {let lifecycleEpoch:Int;let generation:Int;let subject:UUID}
    private var workspaceFlight:(id:UUID,key:WorkspaceKey,task:Task<Void,Never>)?
    private var workspaceReadyKey:WorkspaceKey?
    private var retryDelayTask:Task<Void,Never>?
    private var retryWaiter:(id:UUID,continuation:CheckedContinuation<Void,Never>)?
    private var workspaceResolver:(any NativeApplicationScopeResolving)?
    private var connectionMonitor:ConnectionMonitor
    private var retryClock:any NativeWorkspaceRetryClock
    private var retrySchedule:NativeWorkspaceRetrySchedule
    var canSignIn: Bool { manager != nil && !actionBusy && state.phase != .signingIn && state.phase != .restoring }
    var canStartExperience: Bool { canSignIn && state.phase != .storageBlocked }
    init() {
        connectionMonitor = .shared
        retryClock = NativeWorkspaceSystemClock()
        retrySchedule = .production
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
                values = CatpawDebugPublicConfig.remember(values)
            }
            if fixture { values = [keys[0]:"https://abcdefghijklmnopqrst.supabase.co",keys[1]:"sb_publishable_test_public_value",keys[2]:"https://backend.example.invalid",keys[3]:"11111111-2222-4333-8444-555555555555"] }
            #endif
            configuration = try NativeAuthConfiguration.read(values)
            if let configuration {
                var vault: any NativeAuthVault = NativeAuthKeychainVault(service:"com.example.CatpawM.ConversationFirst.Auth." + directory,issuer:configuration.issuer)
                var barrier: any NativeAuthLogoutBarrier = NativeAuthFileLogoutBarrier(url:root.appendingPathComponent("auth-state"))
                let http = NativeAuthHTTPRemote(configuration:configuration)
                workspaceResolver = http
                var remote: any NativeAuthRemote = http
                #if DEBUG
                if fixture {
                    remote = NativeAuthFixtureRemote(issuer:configuration.issuer,scenario:fixtureScenario)
                    workspaceResolver = nil
                    if fixtureScenario.hasPrefix("cold-") {
                        let id = stableID("a.test@example.invalid")
                        let saved = NativeAuthCredential(issuer:configuration.issuer,user:.init(id:id,email:"a.test@example.invalid"),accessToken:"fixture."+id.uuidString+".signature",refreshToken:"fixture-"+id.uuidString,expiresAt:Date().addingTimeInterval(fixtureScenario == "cold-expired" ? -1 : 3600))
                        let memory = NativeAuthColdFixtureStorage(saved); vault = memory; barrier = memory
                    }
                }
                #endif
                localVault=vault;localBarrier=barrier
                manager = NativeAuthSessionManager(configuration:configuration,remote:remote,vault:vault,barrier:barrier,accountBarrier:.shared)   // p89d-3: passive invalidation closes AccountEpoch at the source
            } else { manager = nil; error = "登录连接尚未配置。" }
        } catch { configuration = nil; manager = nil; self.error = "登录公开配置未通过校验。" }
        let gate = CatpawOnboarding.initialState(fixture: fixture); onboarding = gate; needsOnboarding = gate.needsOnboarding
    }
    // Test initializer is mock-only; production continues using the configured Keychain.
    init(configuration:NativeAuthConfiguration,manager:NativeAuthSessionManager,vault:any NativeAuthVault,barrier:any NativeAuthLogoutBarrier,root:URL,workspaceResolver:(any NativeApplicationScopeResolving)? = nil,connectionMonitor:ConnectionMonitor? = nil,retryClock:any NativeWorkspaceRetryClock = NativeWorkspaceSystemClock(),retrySchedule:NativeWorkspaceRetrySchedule = .production) {
        self.configuration=configuration;self.manager=manager;self.localVault=vault;self.localBarrier=barrier;self.root=root;self.isFixture=true
        self.workspaceResolver=workspaceResolver;self.connectionMonitor=connectionMonitor ?? ConnectionMonitor(start:false);self.retryClock=retryClock;self.retrySchedule=retrySchedule
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
        let openEpoch=lifecycleEpoch   // p89g-2: lifecycle snapshot at ENTRY, before the first await (detached read)
        let found:(LocalConversationReceipt,AuthenticatedLocalPartition)? = await Task.detached(priority:.userInitiated) {
            guard let bytes=try? Data(contentsOf:receiptURL),let receipt=try? JSONDecoder().decode(LocalConversationReceipt.self,from:bytes),
                  let candidate=try? localVault.load(),let signedOut=try? localBarrier.isSignedOut(),
                  let partition=receipt.partition(candidate:candidate,signedOut:signedOut,expectedIssuer:issuer),
                  FileManager.default.fileExists(atPath:root.appendingPathComponent(partition.namespace).appendingPathComponent("local.store").path) else { return nil }
            return (receipt,partition)
        }.value
        if let hook=Self.afterLocalReadHook { await hook() }
        // p89g-2: a logout (or session restart) that completed while the read was suspended ends this open here.
        guard let found=found,chat == nil,!Task.isCancelled,!logoutInProgress,openEpoch == lifecycleEpoch else { return }
        let (receipt,partition)=found
        let openToken=Self.principal(for:partition.subject)
        let url=root.appendingPathComponent(partition.namespace).appendingPathComponent("local.store")
        do {
            let (repository,imageStore)=try await Self.openStores(directory:url.deletingLastPathComponent(),prepare:false)
            guard chat == nil,!logoutInProgress,!Task.isCancelled,openEpoch == lifecycleEpoch else { return }
            // The local receipt conveys local reading only; it never authorizes HTTP.
            let chatConfiguration=try NativeChatConfiguration(origin:configuration.backendOrigin,localScope:partition.scope,serverScopeID:receipt.serverScopeID,publishableKey:configuration.publishableKey,expectedSubjectID:partition.subject)
            let credentials=AuthenticatedNativeChatCredentials(manager:manager!,partition:partition)
            Task { await CatpawPushTokenUploader.shared.setAuthorization { try await credentials.authorization(scope: partition.scope) } }
            let backend=NativeChatHTTPBackend(configuration:chatConfiguration,credentials:credentials)
            if !isFixture { let routeScope=partition.scope; ModelRouteCatalog.shared.install { await backend.modelRoutes(scope:routeScope) } }
            let memory=isFixture ? nil : try NativeMemoryComposition.service(repository:repository,configuration:chatConfiguration,credentials:credentials)
            if !isFixture { MemoryLibraryHub.installAgentMemory(configuration:chatConfiguration,credentials:credentials); MemoryEventSink.installSideChannel() }
            if !isFixture, let uid=state.user?.id { Task { _ = await ConversationMemoryAtRest.migrateAll(repository, subject: uid) } }   // Codex PR91 p91c-5: all rows, gated, retried each launch
            var selected:any ConversationBackend=isFixture ? UnconfiguredConversationBackend() : backend
            #if DEBUG
            selected=CatpawDemoBackendSwitch.select(selected)
            #endif
            let preview=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:selected,resilience:ConnectionMonitorResilience(),outbox:ConversationOutbox(fileURL:url.deletingLastPathComponent().appendingPathComponent("conversation-outbox.json")),principalAccount:partition.subject.uuidString),scope:partition.scope,imageStore:imageStore,taskPlanService:isFixture ? nil : ConversationTaskPlanService(repository:repository,scope:partition.scope,backend:backend),artifactEditService:isFixture ? nil : ConversationArtifactEditService(repository:repository,scope:partition.scope,backend:backend),taskActionService:isFixture ? nil : ConversationTaskActionService(repository:repository,scope:partition.scope,backend:backend),taskControlService:isFixture ? nil : ConversationTaskControlService(repository:repository,scope:partition.scope,backend:backend),memoryService:memory,inboxService:isFixture ? nil : ConversationInboxService(reference:.init(scope:partition.scope,serverScopeID:chatConfiguration.serverScopeID,subjectID:partition.subject),backend:backend),subjectID:partition.subject)
            preview.setNetworkAdmissionAllowed(false);await preview.start()
            guard !Task.isCancelled else { Task { await preview.deactivate() }; return }
            guard attachIfCurrent(preview,openEpoch:openEpoch,token:openToken) else { return }
            self.backend=backend;namespace=partition.namespace
            installUIDecisionSubmitter(preview.service,scope:partition.scope)
        } catch { self.error=NativeAuthError.storage.localizedDescription }
    }
    /// catpaw.ui.v1 decisions for the chat just built (scope-bound; #36's protocol has no scope).
    private(set) var uiDecisionSubmitter: ConversationUIDecisionSubmitter?
    private static var deviceReportObserver: NSObjectProtocol?
    private func installUIDecisionSubmitter(_ service: ConversationSessionService, scope: DataScope) {
        let submitter = ConversationUIDecisionSubmitter(service: service, scope: scope)
        uiDecisionSubmitter = submitter
        // #36 merge: add the GenerativeUIDecisionSubmitting conformance (see ConversationUIDecisionSubmitter) and uncomment:
        GenerativeBlockStore.shared.submitter = submitter
        // catpaw.device.v1 (#49/#44): device results go back into the same suspended turn.
        DeviceCallHub.submitter = ConversationDeviceResultSubmitter(service: service, scope: scope)
        ConversationDeviceCall.clientEnabled = true
        ConversationDeviceCall.clientTools = DeviceToolContract.clientTools   // NoBug P0-4: advertise what we execute
        DeviceCallHub.recorder = { DeviceLedger.shared.record(call: $0, result: $1, token: $2) }
        AccountEpoch.shared.activate(account: state.user?.id.uuidString); Self.lastBarrierAccount = state.user?.id.uuidString   // shared account barrier (grants, memory, proactive)
        DeviceCallGate.installLifecycle()   // Codex PR #89: grants/revocations come from the session service's SSE boundary
        // NoBug P1-4: unacknowledged device results are re-sent on relaunch and whenever the app returns to foreground.
        // Codex PR91 #7: queued proactive feedback is drained at the same moments (ids survive restart).
        Task { @MainActor in
            await DeviceCallStore.shared.retryPendingReports()
            await ProactiveFeedbackSync.shared.retryPending(serverIDs: ProactiveEngine.shared.serverIDs)
        }
        if Self.deviceReportObserver == nil {
            Self.deviceReportObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    await DeviceCallStore.shared.retryPendingReports()
                    await ProactiveFeedbackSync.shared.retryPending(serverIDs: ProactiveEngine.shared.serverIDs)
                }
            }
        }
    }
    /// Starts the background warm-up (local preview, restore, anonymous experience identity).
    /// Safe to call from `.task`: the warm-up is an unstructured task, so the gate can await it.
    func start() async {
        guard !started, let manager else { return }; started = true
        let changes=connectionMonitor.pathChanges()
        reachabilitySubscription=Task { [weak self] in
            for await satisfied in changes {guard let self,!Task.isCancelled else{return};if satisfied {self.wakeRetry()}}
        }
        let task = Task { [weak self] in guard let self else { return }; await self.warmUp(manager) }
        warmup = task; await task.value
    }
    private func warmUp(_ manager: NativeAuthSessionManager) async {
        await openLocalConversation()
        subscription = Task { [weak self] in
            for await snapshot in await manager.changes() { guard let self, !Task.isCancelled else { return }; await self.receive(snapshot) }
        }
        await restoreSession(manager,allowAutomaticExperience:true)
    }
    /// Cold validation is a read-only request and can safely retry while the logout barrier remains open.
    /// An expired-token rotation writes the barrier first; a failed rotation is therefore terminal here and
    /// is never silently replayed.
    private func restoreSession(_ manager:NativeAuthSessionManager,allowAutomaticExperience:Bool) async {
        guard !sessionRecoveryActive else{return}
        let epoch=lifecycleEpoch
        sessionRecoveryActive=true;defer{sessionRecoveryActive=false}
        var attempt=0
        while !Task.isCancelled,!logoutInProgress,epoch == lifecycleEpoch {
            if !connectionMonitor.pathSatisfied,await hasSafelyRecoverableCredential() {await waitForRecoveryPath();continue}
            do {
                try await manager.restore()
                guard !Task.isCancelled,!logoutInProgress,epoch == lifecycleEpoch else{return}
                let restored=await manager.snapshot()
                if restored.phase == .authenticated {recoveryImpossible=false;requiresSessionRestart=false;error=nil;await receive(restored)}
                else if allowAutomaticExperience,!isFixture,restored.phase == .signedOut,restored.user == nil,restored.message == nil,autoAnonymousSession {
                    // Offline: do not block entry waiting for path — provisional chat opens from completeOnboarding.
                    if !connectionMonitor.pathSatisfied {return}
                    await startExperience()
                    if !recoveryImpossible,await hasSafelyRecoverableCredential(),(await manager.snapshot()).phase != .authenticated {
                        await waitForRetry(attempt:attempt);attempt += 1;continue
                    }
                }
                return
            } catch {
                guard !Task.isCancelled,!logoutInProgress,epoch == lifecycleEpoch else{return}
                let safe=error as? NativeAuthError ?? .unavailable
                if [.unavailable,.rateLimited].contains(safe),await hasSafelyRecoverableCredential() {
                    self.error=nil;chat?.setNetworkAdmissionAllowed(false)
                    if connectionMonitor.pathSatisfied {await waitForRetry(attempt:attempt);attempt += 1}
                    continue
                }
                recoveryImpossible=true
                let ambiguous=await hasAmbiguousCredential()
                requiresSessionRestart = [.loginRequired,.invalidResponse,.sessionRecoveryRequired].contains(safe) || ambiguous
                self.error=requiresSessionRestart ? NativeAuthError.sessionRecoveryRequired.localizedDescription : friendlyAuthFailure(safe)
                chat?.error=self.error
                return
            }
        }
    }
    /// Info.plist `CatpawAutoAnonymousSession` = NO disables the automatic experience identity.
    /// "开启" joins the pre-warmed lifecycle. Entry never waits on model/provider health —
    /// a local (possibly offline) chat is enough; routes/workspace keep retrying in the background.
    func completeOnboarding() async {
        guard onboarding != .entering, onboarding != .completed else { return }
        onboarding = .entering
        if warmup == nil { await start() } else { await warmup?.value }
        // Only terminal session/storage/config blocks entry — never model API reachability.
        if manager == nil || (error.map { NativeAuthApplicationModel.configurationMessages.contains($0) } == true) {
            onboarding = .failed(error ?? NativeAuthError.notConfigured.localizedDescription); return
        }
        if recoveryImpossible, requiresSessionRestart {
            onboarding = .failed(error ?? NativeAuthError.sessionRecoveryRequired.localizedDescription); return
        }
        await retryWarmup()
        await ensureEntryChat()
        if chat != nil {
            error = nil
            CatpawOnboarding.markCompleted(); onboarding = .completed
            return
        }
        // Last resort: still do not cite model health — storage/config only.
        onboarding = .failed(error ?? NativeAuthError.storage.localizedDescription)
    }
    /// Soft reachability / provider failures — never used as the onboarding door lock.
    static func isTransientConnectFailure(_ message: String) -> Bool {
        message == NativeAuthError.unavailable.localizedDescription
            || message == NativeAuthError.rateLimited.localizedDescription
            || message == NativeAuthError.anonymousUnavailable.localizedDescription
            || message == "暂时连不上服务，请稍后重试。"
    }
    private static let configurationMessages: Set<String> = [
        NativeAuthError.notConfigured.localizedDescription,
        NativeAuthError.invalidConfiguration.localizedDescription,
        "登录连接尚未配置。",
        "登录公开配置未通过校验。",
    ]
    /// Open a usable chat for entry without requiring live workspace/model APIs.
    private func ensureEntryChat() async {
        if chat != nil { return }
        guard let configuration else { return }
        if let manager {
            let snap = await manager.snapshot()
            if let user = snap.user, snap.phase == .authenticated {
                await admitProvisionalChat(user: user, configuration: configuration)
                return
            }
        }
        // Auth unreachable: local trial identity (no model key, no network admission).
        await openOfflineTrialChat(configuration: configuration)
    }
    private func retryWarmup() async {
        guard let manager else { return }
        wakeRetry()
        let current = await manager.snapshot()
        if current.phase == .signedOut, current.user == nil { error = nil; await startExperience() }
        else if current.phase == .authenticated { error = nil;recoveryImpossible=false;await receive(current) }
        else { await foreground() }
    }
    /// Retryable workspace failures stay in the background flight; only a terminal safety/configuration
    /// result ends the onboarding wait.
    private func waitForChat() async -> Bool {
        while chat == nil,!Task.isCancelled {
            if recoveryImpossible || (workspaceFlight == nil && !sessionRecoveryActive && !actionBusy && ![.restoring,.signingIn,.refreshing,.authenticated].contains(state.phase)) {return false}
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return chat != nil
    }
    private var autoAnonymousSession: Bool { (Bundle.main.object(forInfoDictionaryKey:"CatpawAutoAnonymousSession") as? Bool) ?? true }
    private func receive(_ snapshot: NativeAuthSnapshot) async {
        // Codex p89c-c: passive invalidation (loginRequired / signedOut / storageBlocked from the session manager) closes the
        // shared account barrier synchronously on arrival — before any await and without waiting for a SwiftUI `.task`.
        Self.applyAccountBarrier(snapshot, fresh: false)
        guard let manager, !Task.isCancelled,!logoutInProgress else { return }
        let openingEpoch=lifecycleEpoch
        let current = await manager.snapshot()
        guard !Task.isCancelled,!logoutInProgress,openingEpoch==lifecycleEpoch, current.generation == snapshot.generation,
              current.phase == snapshot.phase, current.user == snapshot.user else { return }
        Self.applyAccountBarrier(snapshot, fresh: true)   // verified-current snapshot may (re)activate an account
        state = snapshot
        if snapshot.phase == .restoring { chat?.setNetworkAdmissionAllowed(false);return }
        if [.authenticated,.refreshing].contains(snapshot.phase), let user = snapshot.user, let configuration {
            if snapshot.phase == .refreshing {
                chat?.setNetworkAdmissionAllowed(false)
                if let flight=workspaceFlight {flight.task.cancel();workspaceFlight=nil;wakeRetry()}
                workspaceReadyKey=nil;return
            }
            let key=WorkspaceKey(lifecycleEpoch:openingEpoch,generation:snapshot.generation,subject:user.id)
            beginWorkspaceResolution(key:key,user:user,configuration:configuration)
        } else {
            // A locally opened receipt remains read-only. Logout owns detachment and invalid-session
            // recovery owns the explicit restart action; neither path grants network admission.
            chat?.setNetworkAdmissionAllowed(false)
            if let flight=workspaceFlight {flight.task.cancel();workspaceFlight=nil;wakeRetry()}
            workspaceReadyKey=nil
            if snapshot.phase == .loginRequired {
                recoveryImpossible=true;requiresSessionRestart=true;error=NativeAuthError.sessionRecoveryRequired.localizedDescription
                chat?.error=error
            } else if snapshot.phase == .storageBlocked {
                recoveryImpossible=true;error=NativeAuthError.storage.localizedDescription
                chat?.error=error
            }
            if snapshot.message == nil,chat == nil {await detachChat()}
            if snapshot.phase == .signedOut,snapshot.message != nil,!sessionRecoveryActive,!actionBusy,await hasSafelyRecoverableCredential() {
                Task { [weak self] in
                    guard let self,!self.logoutInProgress,self.lifecycleEpoch == openingEpoch else{return}
                    let latest=await manager.snapshot()
                    guard latest.generation == snapshot.generation,latest.phase == .signedOut else{return}
                    await self.restoreSession(manager,allowAutomaticExperience:false)
                }
            }
        }
    }

    private func beginWorkspaceResolution(key:WorkspaceKey,user:NativeAuthUser,configuration:NativeAuthConfiguration) {
        if workspaceReadyKey == key,chat?.networkAdmissionAllowed == true {return}
        if workspaceFlight?.key == key {return}
        workspaceFlight?.task.cancel();wakeRetry();workspaceReadyKey=nil
        // Open local chat immediately — do not gate UI on workspace/model reachability.
        Task { [weak self] in await self?.admitProvisionalChat(user: user, configuration: configuration) }
        let id=UUID()
        let task=Task { [weak self] in
            guard let self else{return}
            await self.resolveWorkspace(key:key,user:user,configuration:configuration)
            self.finishWorkspaceFlight(id)
        }
        workspaceFlight=(id,key,task)
    }
    private func resolveWorkspace(key:WorkspaceKey,user:NativeAuthUser,configuration:NativeAuthConfiguration) async {
        guard let manager else{return}
        var attempt=0
        while !Task.isCancelled,await workspaceKeyIsCurrent(key,user:user) {
            if !connectionMonitor.pathSatisfied {await connectionMonitor.waitForPath();continue}
            do {
                let serverScope:UUID
                if isFixture,workspaceResolver == nil,let fixed=configuration.serverScopeID {serverScope=fixed}
                else {
                    guard let workspaceResolver else {throw NativeAuthError.notConfigured}
                    let authorization=try await manager.authorization(subject:user.id)
                    guard authorization.hasPrefix("Bearer ") else {throw NativeAuthError.invalidResponse}
                    serverScope=try await workspaceResolver.applicationScope(accessToken:String(authorization.dropFirst(7)),subject:user.id)
                }
                guard await workspaceKeyIsCurrent(key,user:user) else{return}
                await admitWorkspace(serverScope:serverScope,key:key,user:user,configuration:configuration)
                return
            } catch {
                guard !Task.isCancelled,await workspaceKeyIsCurrent(key,user:user) else{return}
                if workspaceFailureIsRetryable(error) {
                    chat?.setNetworkAdmissionAllowed(false);self.error=nil;recoveryImpossible=false;requiresSessionRestart=false
                    await admitProvisionalChat(user: user, configuration: configuration)
                    if !connectionMonitor.pathSatisfied {await connectionMonitor.waitForPath()}
                    else {await waitForRetry(attempt:attempt);attempt += 1}
                    continue
                }
                // Terminal workspace failure. Product decision (coordinator, p89g-5 / :116): a REJECTED workspace (needs a
                // session restart) drops its provisional chat — restart is set FIRST so no in-flight admit can reattach, and
                // the network stays closed. Non-restart terminal failures keep the local chat usable.
                chat?.setNetworkAdmissionAllowed(false)
                requiresSessionRestart=workspaceFailureNeedsRestart(error)
                recoveryImpossible=requiresSessionRestart
                if requiresSessionRestart {
                    self.error=friendlyWorkspaceFailure(error)
                    if chat != nil { _ = await finishDetaching(takeChat()) }
                } else {
                    await admitProvisionalChat(user: user, configuration: configuration)
                    self.error=nil; chat?.error=nil
                }
                return
            }
        }
    }
    /// Every local chat open re-validates AFTER its last await (`start()`), so a logout / account switch / session-restart
    /// that completed while the open was suspended can never reattach a chat. With an account token captured at open start,
    /// the attach itself runs inside AccountEpoch.commit(token) (atomic with signOut / activate).
    private func attachIfCurrent(_ opened: ConversationFirstModel, openEpoch: Int, token: AccountToken?, provisional: Bool = false) -> Bool {
        let current = chat == nil && !logoutInProgress && lifecycleEpoch == openEpoch && !(provisional && requiresSessionRestart)
        let attached = current && (token.map { t in AccountEpoch.shared.commit(t) { chat = opened; return true } ?? false } ?? { chat = opened; return true }())
        if !attached { Task { await opened.deactivate() } }
        return attached
    }
    private func workspaceKeyIsCurrent(_ key:WorkspaceKey,user:NativeAuthUser) async -> Bool {
        guard let manager,!logoutInProgress,key.lifecycleEpoch == lifecycleEpoch else{return false}
        let current=await manager.snapshot()
        return !Task.isCancelled && !logoutInProgress && key.lifecycleEpoch == lifecycleEpoch && current.generation == key.generation && current.user == user && current.phase == .authenticated
    }
    /// Local chat for entry/offline. Network stays closed until resolveWorkspace admits for real.
    private func admitProvisionalChat(user: NativeAuthUser, configuration: NativeAuthConfiguration) async {
        guard chat == nil, !logoutInProgress, !requiresSessionRestart else { return }
        let openEpoch = lifecycleEpoch, openToken = Self.principal(for: user.id)   // captured at open start
        let serverScope = configuration.serverScopeID
            ?? provisionalScope(for: user.id)
        do {
            let partition = AuthenticatedLocalPartition(issuer: configuration.issuer, subject: user.id, serverScopeID: serverScope)
            let directory = root.appendingPathComponent(partition.namespace, isDirectory: true)
            let (repository, imageStore) = try await Self.openStores(directory: directory, prepare: true)
            guard chat == nil, !logoutInProgress else { return }
            let region = (Bundle.main.object(forInfoDictionaryKey: "CatpawEdgeRegion") as? String).flatMap { $0.isEmpty ? nil : $0 }
            let chatConfiguration = try NativeChatConfiguration(origin: configuration.backendOrigin, localScope: partition.scope, serverScopeID: serverScope, publishableKey: configuration.publishableKey, edgeRegion: region, expectedSubjectID: partition.subject)
            let credentials = AuthenticatedNativeChatCredentials(manager: manager!, partition: partition)
            let http = NativeChatHTTPBackend(configuration: chatConfiguration, credentials: credentials)
            if !isFixture { let routeScope = partition.scope; ModelRouteCatalog.shared.install { await http.modelRoutes(scope: routeScope) } }
            let memory = isFixture ? nil : try? NativeMemoryComposition.service(repository: repository, configuration: chatConfiguration, credentials: credentials)
            if !isFixture { MemoryLibraryHub.installAgentMemory(configuration: chatConfiguration, credentials: credentials); MemoryEventSink.installSideChannel() }
            backend = http
            var selected: any ConversationBackend = isFixture ? UnconfiguredConversationBackend() : http
            #if DEBUG
            selected = CatpawDemoBackendSwitch.select(selected)
            #endif
            let opened = ConversationFirstModel(repository: repository, service: ConversationSessionService(repository: repository, backend: selected, resilience: ConnectionMonitorResilience(), outbox: ConversationOutbox(fileURL: directory.appendingPathComponent("conversation-outbox.json")),principalAccount:partition.subject.uuidString), scope: partition.scope, imageStore: imageStore, taskPlanService: isFixture ? nil : ConversationTaskPlanService(repository: repository, scope: partition.scope, backend: http), artifactEditService: isFixture ? nil : ConversationArtifactEditService(repository: repository, scope: partition.scope, backend: http), taskActionService: isFixture ? nil : ConversationTaskActionService(repository: repository, scope: partition.scope, backend: http), taskControlService: isFixture ? nil : ConversationTaskControlService(repository: repository, scope: partition.scope, backend: http), memoryService: memory, inboxService: isFixture ? nil : ConversationInboxService(reference: .init(scope: partition.scope, serverScopeID: chatConfiguration.serverScopeID, subjectID: partition.subject), backend: http), subjectID: partition.subject)
            try? await saveLocalReceipt(.init(issuer: configuration.issuer, subject: user.id, serverScopeID: serverScope))
            guard chat == nil, !logoutInProgress else { return }
            opened.setNetworkAdmissionAllowed(false)
            await opened.start()
            guard attachIfCurrent(opened, openEpoch: openEpoch, token: openToken, provisional: true) else { return }
            installUIDecisionSubmitter(opened.service, scope: partition.scope)
            namespace = partition.namespace
            // Do not clear workspaceFlight — real admit still runs in background.
            error = nil
        } catch {
            // Leave chat nil; completeOnboarding may fall through to offline trial.
        }
    }
    private func provisionalScope(for subject: UUID) -> UUID {
        stableID("catpaw-provisional-scope-" + subject.uuidString.lowercased())
    }
    /// First-launch / auth-unreachable: local trial store, no network admission, no fake cloud credential.
    func openOfflineTrialChat(configuration: NativeAuthConfiguration) async {
        guard chat == nil, !logoutInProgress else { return }
        let openEpoch = lifecycleEpoch
        let subject = offlineTrialSubject()
        let serverScope = configuration.serverScopeID ?? provisionalScope(for: subject)
        let issuer = configuration.issuer + "|offline-trial"
        do {
            let partition = AuthenticatedLocalPartition(issuer: issuer, subject: subject, serverScopeID: serverScope)
            let directory = root.appendingPathComponent(partition.namespace, isDirectory: true)
            let (repository, imageStore) = try await Self.openStores(directory: directory, prepare: true)
            guard chat == nil, !logoutInProgress else { return }
            let opened = ConversationFirstModel(repository: repository, service: ConversationSessionService(repository: repository, backend: UnconfiguredConversationBackend(), resilience: ConnectionMonitorResilience(), outbox: ConversationOutbox(fileURL: directory.appendingPathComponent("conversation-outbox.json"))), scope: partition.scope, imageStore: imageStore, subjectID: subject)
            opened.setNetworkAdmissionAllowed(false)
            await opened.start()
            guard attachIfCurrent(opened, openEpoch: openEpoch, token: nil) else { return }
            namespace = partition.namespace
            installUIDecisionSubmitter(opened.service, scope: partition.scope)
            error = nil
            recoveryImpossible = false
            requiresSessionRestart = false
            // When path returns, upgrade to a real anonymous session without blocking entry.
            // p89g-2: owned + cancelled by logout; re-validated against openEpoch after EVERY await.
            offlineRecoveryTask?.cancel()
            offlineRecoveryTask = Task { [weak self] in
                guard let self else { return }
                await self.connectionMonitor.waitForPath()
                guard !Task.isCancelled, !self.logoutInProgress, openEpoch == self.lifecycleEpoch, let manager = self.manager else { return }
                let phase = (await manager.snapshot()).phase
                guard !Task.isCancelled, !self.logoutInProgress, openEpoch == self.lifecycleEpoch else { return }
                if phase == .signedOut || phase == .loginRequired { Self.offlineRecoveryWillStartExperience?(); await self.startExperience() }
            }
        } catch {
            self.error = NativeAuthError.storage.localizedDescription
        }
    }
    private func offlineTrialSubject() -> UUID {
        let key = "catpaw.offlineTrial.subject.v1"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    private func admitWorkspace(serverScope:UUID,key:WorkspaceKey,user:NativeAuthUser,configuration:NativeAuthConfiguration) async {
        guard let manager else{return}
        let partition=AuthenticatedLocalPartition(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope)
        if namespace == partition.namespace,let chat {
            try? await saveLocalReceipt(.init(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope))
            guard await workspaceKeyIsCurrent(key,user:user) else{return}
            if chat.error == error {chat.error=nil}
            chat.setNetworkAdmissionAllowed(true);workspaceReadyKey=key;error=nil;recoveryImpossible=false;requiresSessionRestart=false;return
        }
        await detachChat()
        guard await workspaceKeyIsCurrent(key,user:user) else{return}
        do {
            let directory=root.appendingPathComponent(partition.namespace,isDirectory:true)
            let (repository,imageStore)=try await Self.openStores(directory:directory,prepare:true)
            guard await workspaceKeyIsCurrent(key,user:user),chat == nil else{return}
            let region=(Bundle.main.object(forInfoDictionaryKey:"CatpawEdgeRegion") as? String).flatMap{$0.isEmpty ? nil : $0}
            let chatConfiguration=try NativeChatConfiguration(origin:configuration.backendOrigin,localScope:partition.scope,serverScopeID:serverScope,publishableKey:configuration.publishableKey,edgeRegion:region,expectedSubjectID:partition.subject)
            let credentials=AuthenticatedNativeChatCredentials(manager:manager,partition:partition)
            Task {await CatpawPushTokenUploader.shared.setAuthorization {try await credentials.authorization(scope:partition.scope)}}
            let http=NativeChatHTTPBackend(configuration:chatConfiguration,credentials:credentials)
            if !isFixture { let routeScope=partition.scope; ModelRouteCatalog.shared.install { await http.modelRoutes(scope:routeScope) } }
            let memory=isFixture ? nil : try NativeMemoryComposition.service(repository:repository,configuration:chatConfiguration,credentials:credentials)
            if !isFixture {MemoryLibraryHub.installAgentMemory(configuration:chatConfiguration,credentials:credentials);MemoryEventSink.installSideChannel()}
            backend=http
            var selected:any ConversationBackend=isFixture ? UnconfiguredConversationBackend() : http
            #if DEBUG
            selected=CatpawDemoBackendSwitch.select(selected)
            #endif
            let opened=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:selected,resilience:ConnectionMonitorResilience(),outbox:ConversationOutbox(fileURL:directory.appendingPathComponent("conversation-outbox.json")),principalAccount:partition.subject.uuidString),scope:partition.scope,imageStore:imageStore,taskPlanService:isFixture ? nil : ConversationTaskPlanService(repository:repository,scope:partition.scope,backend:http),artifactEditService:isFixture ? nil : ConversationArtifactEditService(repository:repository,scope:partition.scope,backend:http),taskActionService:isFixture ? nil : ConversationTaskActionService(repository:repository,scope:partition.scope,backend:http),taskControlService:isFixture ? nil : ConversationTaskControlService(repository:repository,scope:partition.scope,backend:http),memoryService:memory,inboxService:isFixture ? nil : ConversationInboxService(reference:.init(scope:partition.scope,serverScopeID:chatConfiguration.serverScopeID,subjectID:partition.subject),backend:http),subjectID:partition.subject)
            try await saveLocalReceipt(.init(issuer:configuration.issuer,subject:user.id,serverScopeID:serverScope))
            guard await workspaceKeyIsCurrent(key,user:user),chat == nil else{return}
            opened.setNetworkAdmissionAllowed(true);chat=opened;installUIDecisionSubmitter(opened.service,scope:partition.scope);namespace=partition.namespace
            workspaceReadyKey=key;error=nil;recoveryImpossible=false;requiresSessionRestart=false
        } catch {chat?.setNetworkAdmissionAllowed(false);self.error="此账号的本地存储无法打开；原文件已保留。";recoveryImpossible=true}
    }
    private func finishWorkspaceFlight(_ id:UUID) {if workspaceFlight?.id == id {workspaceFlight=nil;wakeRetry()}}
    private func workspaceFailureIsRetryable(_ error:Error)->Bool {
        if let failure=error as? NativeApplicationSessionError {return failure.isRetryable}
        if let failure=error as? NativeAuthError {return [.unavailable,.rateLimited].contains(failure)}
        return false
    }
    private func workspaceFailureNeedsRestart(_ error:Error)->Bool {
        if let failure=error as? NativeApplicationSessionError {return [401,403].contains(failure.httpStatus)}
        if let failure=error as? NativeAuthError {return [.loginRequired,.sessionRecoveryRequired].contains(failure)}
        return false
    }
    private func friendlyWorkspaceFailure(_ error:Error)->String {
        workspaceFailureNeedsRestart(error) ? NativeAuthError.sessionRecoveryRequired.localizedDescription : "暂时无法打开工作区，本机对话仍会保留。"
    }
    private func friendlyAuthFailure(_ error:NativeAuthError)->String {
        switch error {
        case .loginRequired,.invalidResponse,.sessionRecoveryRequired:return NativeAuthError.sessionRecoveryRequired.localizedDescription
        case .storage:return NativeAuthError.storage.localizedDescription
        case .notConfigured,.invalidConfiguration:return error.localizedDescription
        default:return "暂时连不上服务，请稍后重试。"
        }
    }
    private func hasSafelyRecoverableCredential() async ->Bool {
        (try? await manager?.canRetryRecovery()) == true
    }
    private func hasAmbiguousCredential() async ->Bool {
        guard let localVault,let localBarrier else{return false}
        return await Task.detached(priority:.userInitiated) {(try? localBarrier.isSignedOut()) == true && (try? localVault.load()) != nil}.value
    }
    private func waitForRecoveryPath() async {
        let monitor=connectionMonitor
        let wait=Task {await monitor.waitForPath()}
        recoveryPathWait=wait;await wait.value;recoveryPathWait=nil
    }
    private func waitForRetry(attempt:Int) async {
        let delay=retrySchedule.nanoseconds(attempt:attempt),clock=retryClock
        if delay == 0 {await Task.yield();return}
        let id=UUID()
        await withTaskCancellationHandler(operation:{
            await withCheckedContinuation {continuation in
                guard !Task.isCancelled else{continuation.resume();return}
                retryWaiter=(id,continuation)
                retryDelayTask=Task { [weak self] in
                    do {try await clock.sleep(nanoseconds:delay)} catch{return}
                    guard !Task.isCancelled else{return}
                    self?.finishRetry(id)
                }
            }
        },onCancel:{Task {@MainActor [weak self] in self?.finishRetry(id)}})
    }
    private func finishRetry(_ id:UUID) {if retryWaiter?.id == id {wakeRetry()}}
    private func wakeRetry() {
        retryDelayTask?.cancel();retryDelayTask=nil
        let waiter=retryWaiter;retryWaiter=nil;waiter?.continuation.resume()
    }
    private func detachChat() async {
        if !(await finishDetaching(takeChat())) {error="有修改草稿未能保存，请核对此前已保存的版本。"}
    }
    private func takeChat() -> (ConversationFirstModel?,NativeChatHTTPBackend?,String?) {
        let previous = chat; chat = nil
        uiDecisionSubmitter = nil
        GenerativeBlockStore.shared.submitter = nil
        DeviceCallHub.submitter = nil
        DeviceCallGate.reset()
        GenerativeBlockStore.shared.activate(conversationID: nil)
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
        guard canStartExperience,let manager else { return };actionBusy = true;error = nil;recoveryImpossible=false;requiresSessionRestart=false;defer { actionBusy = false }
        let epoch=lifecycleEpoch
        do { try await manager.startExperience();await receive(await manager.snapshot()) }
        catch {
            guard !Task.isCancelled,!logoutInProgress,epoch == lifecycleEpoch else{return}
            let failure=error as? NativeAuthError ?? .unavailable
            if [.unavailable,.rateLimited].contains(failure),await hasSafelyRecoverableCredential() {
                if !sessionRecoveryActive {await restoreSession(manager,allowAutomaticExperience:false)}
                return
            }
            let ambiguous=await hasAmbiguousCredential()
            requiresSessionRestart=[.loginRequired,.invalidResponse,.sessionRecoveryRequired].contains(failure) || ambiguous
            // Network blips must not poison entry — provisional/offline trial still opens.
            if [.unavailable,.rateLimited].contains(failure), !requiresSessionRestart {
                recoveryImpossible=false; self.error=nil; return
            }
            recoveryImpossible=true
            self.error=requiresSessionRestart ? NativeAuthError.sessionRecoveryRequired.localizedDescription : friendlyAuthFailure(failure)
        }
    }
    func signIn(email: String, password: String) async {
        guard canSignIn, let manager else { return }; actionBusy = true; error = nil;recoveryImpossible=false;requiresSessionRestart=false;registrationNotice = nil; defer { actionBusy = false }
        do { try await manager.signIn(email:email,password:password) } catch {let failure=error as? NativeAuthError ?? .unavailable;recoveryImpossible=true;self.error=friendlyAuthFailure(failure)}
    }
    /// Synchronous AccountEpoch update for an auth snapshot. Any phase without a usable session signs the barrier out
    /// (fail closed, also for not-yet-verified snapshots); only a verified-current authenticated snapshot activates.
    /// p89d-4: the AccountEpoch token of `subject` iff it is the signed-in account right now (else nil → no device grants).
    static func principal(for subject: UUID, epoch: AccountEpoch = .shared) -> AccountToken? {
        guard let t = epoch.capture(), t.account == subject.uuidString else { return nil }
        return t
    }
    /// The account this barrier last activated. The session manager may already have closed AccountEpoch itself (passive
    /// invalidation at the source), so `epoch.currentAccount` can be nil here while that account's ledger still needs clearing.
    private static var lastBarrierAccount: String?
    static func applyAccountBarrier(_ snapshot: NativeAuthSnapshot, fresh: Bool, epoch: AccountEpoch = .shared) {
        let usable: [NativeAuthSnapshot.Phase] = [.authenticated, .refreshing, .restoring]
        if !usable.contains(snapshot.phase) || snapshot.user == nil {
            guard let gone = epoch.currentAccount ?? lastBarrierAccount else { return }   // captured BEFORE signOut()
            lastBarrierAccount = nil
            epoch.signOut(); DeviceCallGate.reset()
            // p89i: passive invalidation can't ask → parked items default to keep (logged), then observers, in that order.
            Task { @MainActor in registerDeviceParkedSources(); await AccountParkedItems.resolve(account: gone, decider: nil); await AccountChangeObservers.notify(previous: gone, current: nil) }
        } else if fresh, snapshot.phase == .authenticated, let id = snapshot.user?.id.uuidString, id != epoch.currentAccount {
            let previous = epoch.currentAccount ?? lastBarrierAccount
            epoch.activate(account: id); DeviceCallGate.reset(); lastBarrierAccount = id
            // p89i: switch → previous account's parked items default to keep (hidden, logged), then observers.
            Task { @MainActor in
                if let previous, previous != id { registerDeviceParkedSources(); await AccountParkedItems.resolve(account: previous, decider: nil) }
                await AccountChangeObservers.notify(previous: previous, current: id)
            }
        }
    }
    /// p89i: generic parked-item decision (AccountParkedItems). The UI sets `parkedDecider`'s answer through
    /// `parkedPrompt` + `resolveParked`; with no UI attached (tests, background) the default is keep — logged.
    @Published private(set) var parkedPrompt: [AccountParkedItem] = []
    private var parkedAnswer: CheckedContinuation<[String: AccountParkedDecision], Never>?
    var parkedDecider: AccountParkedItems.Decider?
    /// Installs the shared confirmation UI decider (CatpawApp).
    func attachParkedPrompt() {
        parkedDecider = { [weak self] items in
            guard let self else { return [:] }
            return await withCheckedContinuation { c in self.parkedAnswer = c; self.parkedPrompt = items }
        }
    }
    /// Per-item answers; items without an answer are kept. Dismissing the sheet = keep all.
    func resolveParked(_ answers: [String: AccountParkedDecision]) {
        parkedPrompt = []; let c = parkedAnswer; parkedAnswer = nil; c?.resume(returning: answers)
    }
    static func registerDeviceParkedSources() {
        if !AccountParkedItems.registeredKeys.contains(DeviceCallParkedSource.key) { AccountParkedItems.register(DeviceCallParkedSource.key, DeviceCallParkedSource()) }
        if !AccountParkedItems.registeredKeys.contains(DeviceLedgerParkedSource.key) { AccountParkedItems.register(DeviceLedgerParkedSource.key, DeviceLedgerParkedSource()) }
        ProactiveEngine.registerParkedSource()   // #90 wiring (one line): EventKit items Catpaw created, cold start → sign-out
    }
    func requestSignOut(after: (@MainActor () async -> Void)? = nil) async { await signOut(); await after?() }
    func signOut() async {
        guard let manager, !actionBusy else { return };actionBusy=true;logoutInProgress=true;lifecycleEpoch += 1
        let leaving = AccountEpoch.shared.currentAccount ?? Self.lastBarrierAccount   // captured BEFORE the barrier closes
        Self.lastBarrierAccount = nil
        // p89i deterministic order: 1 sync epoch bump → 2 collect parked → 3 user decision → 4 apply → 5 observers.
        AccountEpoch.shared.signOut()   // 1. synchronous barrier FIRST: every in-flight account-bound write is refused from here
        DeviceCallGate.reset()          //    Codex p89b-4: grants/taps/credentials die synchronously, before any await
        CatpawLeaveActivity.stopAll()   // Codex PR91 p91c-3: Live Activities + pending work-activity timers, before the first await
        warmup?.cancel();recoveryPathWait?.cancel();recoveryPathWait=nil
        offlineRecoveryTask?.cancel();offlineRecoveryTask=nil   // p89g-2
        workspaceFlight?.task.cancel();workspaceFlight=nil;workspaceReadyKey=nil;wakeRetry()
        defer {logoutInProgress=false;actionBusy=false;recoveryImpossible=false;requiresSessionRestart=false}
        Self.registerDeviceParkedSources()
        await AccountParkedItems.resolve(account: leaving, decider: parkedDecider)   // 2–4 (no silent clear, default keep)
        await CatpawPushTokenUploader.shared.clearAuthorization()
        let detached=takeChat()
        // Close manager admission immediately; local draining must not postpone its barrier.
        async let cleanup:Bool=finishDetaching(detached)
        try? FileManager.default.removeItem(at:receiptURL)
        AccountLocalData.signOut(userID: state.user?.id)   // Codex P0-2: local memory, proactive items, pending reports
        if let uid = state.user?.id { L2SecureStore.wipe(userID: uid) }
        error=nil
        do { try await manager.signOut() } catch { self.error = NativeAuthError.storage.localizedDescription }
        // #90 hook (ProactiveEngine.accountDidChange). The epoch was bumped synchronously at the top; observers run only after
        // the chat is detached and token authority is closed, so a slow observer can never delay logout's barriers.
        await AccountChangeObservers.notify(previous: leaving, current: nil)
        if !(await cleanup) {error="有修改草稿未能保存，请核对此前已保存的版本。"}
        state=await manager.snapshot()
    }
    func cancelLogin() async { guard let manager else { return }; do { try await manager.cancelLogin() } catch { self.error = NativeAuthError.storage.localizedDescription } }
    func retryStorage() async { guard let manager else { return }; do { try await manager.retryPersistence() } catch { self.error = (error as? NativeAuthError ?? .storage).localizedDescription } }
    func foreground() async {
        guard let manager, !actionBusy, started else { return }
        wakeRetry()
        if sessionRecoveryActive {return}
        let current = await manager.snapshot()
        guard !Task.isCancelled, current.phase != .restoring, current.phase != .signingIn else { return }
        if recoveryImpossible,requiresSessionRestart {return}
        if current.phase == .authenticated {await receive(current);return}
        await restoreSession(manager,allowAutomaticExperience:false)
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
