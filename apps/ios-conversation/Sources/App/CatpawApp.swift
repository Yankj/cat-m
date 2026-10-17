import SwiftUI
#if os(iOS)
import UserNotifications
#endif
import AppIntents

@MainActor final class Bootstrap: ObservableObject {
    @Published private(set) var model: ConversationFirstModel? = nil
    @Published private(set) var error: String? = nil
    #if DEBUG
    private var p0Model:ConversationFirstModel?
    #endif
    var isP0Fixture:Bool {
        #if DEBUG
        return P0ExperienceFixture.scenario != nil
        #else
        return false
        #endif
    }
    private(set) var loginSession: SupabaseUserAccessSession?
    init() {
        #if DEBUG
        guard let test = P0ExperienceFixture.launchEnvironment["CF_UI_TEST_STORE"], UUID(uuidString:test) != nil else { model = nil; error = nil; return }
        #else
        model = nil; error = nil; return
        #endif
        #if DEBUG
        if P0ExperienceFixture.launchEnvironment["CATPAW_REVIEW_EXPIRED"] == "1" { return }
        if let scenario=P0ExperienceFixture.scenario,let id=P0ExperienceFixture.launchEnvironment["CF_UI_TEST_STORE"] {
            do {
                let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CatpawP0-qa-"+id)
                let repository=try Repository(persistence:SwiftDataPersistence(url:root.appendingPathComponent("local.store")))
                if scenario.hasPrefix("p0-ui-accepted-work") {
                    p0Model=try ConversationAcceptedWorkLoopbackFixture.make(repository:repository,root:root)
                    return
                }
                if scenario == "p0-ui-consent-handoff" {
                    p0Model=try ConversationConsentHandoffFixture.make(repository:repository,root:root)
                    return
                }
                let planBackend = ConversationTaskPlanFixtureBackend(mode:scenario == "p0-ui-plan-pending" ? .pending : (scenario == "p0-ui-plan-unknown" ? .unknown : .applied))
                let reviewSubject=stableID("P0-task-review-subject")
                let actionBackend:ConversationTaskActionFixtureBackend?=scenario.contains("task-action") ? try ConversationTaskActionFixtureBackend(url:root.appendingPathComponent("task-actions-synthetic-server.json"),mode:scenario.contains("unavailable") ? .unavailable : (scenario.contains("unknown") ? .unknown : .normal),statsUpdated:{stats in Task{@MainActor in P0ExperienceProbe.shared.recordTaskReviewStats(stats)}}) : nil
                let artifactBackend:ConversationArtifactEditFixtureBackend?=scenario.contains("artifact-edit") ? try ConversationArtifactEditFixtureBackend(url:root.appendingPathComponent("artifact-edits-synthetic-server.json"),mode:scenario.contains("unknown") ? .unknown : .applied,statsUpdated:{stats in await MainActor.run{P0ExperienceProbe.shared.recordTaskReviewStats(stats)}}) : nil
                let controlBackend:ConversationTaskControlFixtureBackend?=scenario.contains("task-control") ? try ConversationTaskControlFixtureBackend(url:root.appendingPathComponent("task-controls-synthetic-server.json"),mode:scenario.contains("unresolved") ? .unresolved : (scenario.contains("unknown") ? .unknown : .normal),statsUpdated:{stats in Task{@MainActor in P0ExperienceProbe.shared.recordTaskReviewStats(stats)}}) : nil
                let conversationBackend:any ConversationBackend
                if let controlBackend {conversationBackend=ConversationTaskControlConversationFixture(controls:controlBackend,subjectID:reviewSubject);Task{await controlBackend.publishStats()}}
                else {conversationBackend=P0ExperienceBackend(scenario:scenario)}
                if let artifactBackend {Task{await artifactBackend.publishStats()}}
                p0Model=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:conversationBackend),imageStore:try FileConversationImageByteStore(root:root.appendingPathComponent("image-bytes")),taskPlanService:scenario.hasPrefix("p0-ui-plan") ? ConversationTaskPlanService(repository:repository,scope:Profiles.user,backend:planBackend) : nil,artifactEditService:artifactBackend.map{ConversationArtifactEditService(repository:repository,scope:Profiles.user,backend:$0)},taskActionService:actionBackend.map{ConversationTaskActionService(repository:repository,scope:Profiles.user,backend:$0)},taskControlService:controlBackend.map{ConversationTaskControlService(repository:repository,scope:Profiles.user,backend:$0)},subjectID:reviewSubject)
            } catch { self.error=error.localizedDescription }
            return
        }
        #endif
        var directory = "CatpawM-ConversationFirst-r7-legacy-test"
        #if DEBUG
        if let test = P0ExperienceFixture.launchEnvironment["CF_UI_TEST_STORE"], UUID(uuidString: test) != nil { directory += "-qa-" + test }
        #endif
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(directory, isDirectory: true)
        do {
            #if os(iOS)
            let storage: any SnapshotPersistence = try SwiftDataPersistence(url: root.appendingPathComponent("local.store"))
            #else
            let storage: any SnapshotPersistence = FilePersistence(url: root.appendingPathComponent("portable-preview.json"))
            #endif
            let repo = try Repository(persistence: storage)
            let composition = try NativeChatComposition.make(localScope: Profiles.user)
            loginSession = composition.loginSession
            var backend: any ConversationBackend = composition.backend
            #if DEBUG
            if let test = P0ExperienceFixture.launchEnvironment["CF_UI_TEST_STORE"], UUID(uuidString: test) != nil,
               P0ExperienceFixture.launchEnvironment["CF_UI_TEST_SCENARIO"] == "active-followup" { backend = ConversationUITestHarness() }
            #endif
            model = ConversationFirstModel(repository: repo, service: ConversationSessionService(repository: repo, backend: backend)); error = nil
        } catch { self.model = nil; self.error = error.localizedDescription }
    }
    func startFixture() async {
        #if DEBUG
        guard let pending=p0Model,model == nil else { return }
        do {
            if P0ExperienceFixture.scenario?.hasPrefix("p0-ui-accepted-work")==true,
               let testStore=P0ExperienceFixture.launchEnvironment["CF_UI_TEST_STORE"],UUID(uuidString:testStore) != nil,
               await pending.repository.read(scope:pending.scope).list("conversation",scope:pending.scope).isEmpty {
                // A new synthetic client store owns a new conversation, not a
                // fresh local journal falsely claiming an older server history.
                _=try await pending.service.create(scope:pending.scope,id:stableID("accepted-work-test-conversation:"+testStore))
            }
            _=try await pending.service.openLatest(scope:pending.scope)
            await pending.start()
            if P0ExperienceFixture.scenario == "p0-ui-consent-handoff" {try await ConversationConsentHandoffFixture.prepare(model:pending)}
            model=pending
            if P0ExperienceFixture.scenario == "p0-ui-large-autoplay" {
                Task {
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                    pending.editDraft("Synthetic offline automatic render diagnostic")
                    P0PerformanceLog.shared.mark("synthetic_autoplay_action");pending.prepareSend()
                    try? await Task.sleep(nanoseconds:6_000_000_000)
                    P0ExperienceProbe.shared.exportMetrics()
                    if let id=P0ExperienceFixture.launchEnvironment["CF_UI_TEST_STORE"] {
                        let url=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("P0-perf-"+id+".json")
                        try? Data(P0ExperienceProbe.shared.json.utf8).write(to:url,options:.atomic)
                    }
                }
            }
        } catch { self.error=error.localizedDescription }
        #endif
    }
}
@MainActor @main struct CatpawMApp: App {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CatpawAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var bootstrap = Bootstrap()
    @StateObject private var auth = NativeAuthApplicationModel()
    @StateObject private var oauth = NativeOAuthCoordinator()   // feat/oauth-github-google
    @Environment(\.scenePhase) private var scene
    @State private var launchMarkVisible = LaunchMarkGate.shouldPlay(openedFromURLOrNotification: false)
    @State private var calendarScan: Task<Void, Never>?
    #if DEBUG
    @StateObject private var synthetic = NativeSyntheticApplicationModel()
    #endif
    /// catpaw.ui.v1 blocks render natively inside ```catpaw-card fences (r10 §4).
    init() {
        // Launch path: these are a handful of dictionary inserts (measured via LaunchTrace "adapters.registered"). They stay
        // synchronous on purpose — a chat restored from disk on the 2nd launch renders its catpaw-card fences in frame 1.
        LaunchTrace.mark("app.init")
        GenerativeBlockAdapter.registerWithMarkdown()
        MemorySavedChipAdapter.register() // wave2 V1
        DeviceStatusCardAdapter.register() // wave2 V3 receipt + permission cards
        PermissionDegradeCardAdapter.register() // proactive demo: permission-denied degrade card
        DeviceCallCardAdapter.register() // wave2 V3 device_call confirm card
        ProactiveSuggestionAdapter.register() // wave2 demo proactive_suggestion
        FollowUpChipsAdapter.register() // chat-ux #4 ```catpaw-card:followups chips
        LaunchTrace.mark("adapters.registered")
        #if DEBUG && os(iOS)
        // PR90g (QA only): ProactiveNotificationAuthUITests launches with this flag so the system prompt appears and can be
        // allowed once; simctl privacy cannot pre-grant notifications. Debug builds only; no effect without the flag.
        if CommandLine.arguments.contains("-CatpawRequestNotificationAuth") {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let model = synthetic.chat {
                    ConversationFirstView(model:model,accountLabel:synthetic.fixtureIdentity,restrictToFrozenFixture:true)
                        .safeAreaInset(edge:.top) { VStack { Text(synthetic.fixtureIdentity ?? ui("明确合成测试")).font(.caption).accessibilityIdentifier("fixture.identity"); Button(ui("运行冻结合成报告")) { Task { await synthetic.sendFrozenCase() } }.disabled(!synthetic.ready || synthetic.submitted).accessibilityIdentifier("fixture.run"); if let error = synthetic.error { Text(error).accessibilityIdentifier("fixture.error") } }.padding(8).background(CatpawColors.panel) }
                        .task { await synthetic.loadFrozenCase() }
                } else { primaryView }
                #else
                primaryView
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if launchMarkVisible {
                    LaunchMarkView(restoring: false, toOrb: auth.chat == nil || auth.needsOnboarding) { launchMarkVisible = false }
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .onOpenURL { url in launchMarkVisible = false; CatpawRouteCenter.shared.pending = CatpawAppRoute(url: url) }
            .catpawInAppBanner()
            .environment(\.catpawOAuth, oauth)
            .nativeOAuthSwitchConfirmation(oauth)
            .task { bindOAuth() }
            #if DEBUG || DEVICE_TRIAL
            .task {
                // Acceptance: `defaults write … CatpawOpenURL catpawm://tasks` or env CATPAW_ACCEPTANCE_OPEN_URL.
                let raw = ProcessInfo.processInfo.environment["CATPAW_ACCEPTANCE_OPEN_URL"]
                    ?? UserDefaults.standard.string(forKey: "CatpawOpenURL")
                if let raw, let url = URL(string: raw) {
                    UserDefaults.standard.removeObject(forKey: "CatpawOpenURL")
                    CatpawRouteCenter.shared.pending = CatpawAppRoute(url: url)
                }
                // Demo chains: pin route/model before the first turn (e.g. CATPAW_MODEL_ROUTE=gemini).
                if let route = ProcessInfo.processInfo.environment["CATPAW_MODEL_ROUTE"], !route.isEmpty {
                    let model = ProcessInfo.processInfo.environment["CATPAW_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
                    ModelRouteSelection.select(route: route, model: model)
                }
            }
            #endif
            .task { if bootstrap.isP0Fixture { await bootstrap.startFixture() } else if bootstrap.model == nil { await auth.start() } }
                .onChange(of:scene) { _, phase in if phase == .active { scheduleCalendarScan() }; if phase == .active,bootstrap.model == nil,!bootstrap.isP0Fixture { Task { await auth.foreground() } } }
        }
    }
    /// SPEC-E §7: the calendar scan never lands in the launch, landing-entrance or tap windows. It runs ≥3 s after the
    /// landing or chat is stable (landing settled / onboarding finished and the first-run transition done).
    private func scheduleCalendarScan() {
        calendarScan?.cancel()
        calendarScan = Task { @MainActor in
            // Fixture builds keep their own path; otherwise EventKit is touched only once the account is resolved and its own
            // chat is up (never for the account-neutral launch chat, the landing, or inside the tap transition).
            let busy: @MainActor () -> Bool = { bootstrap.model == nil && !bootstrap.isP0Fixture && (!auth.deviceCapabilitiesAllowed || FirstRunTransition.shared.phase == .leaving) }
            while !Task.isCancelled, busy() { try? await Task.sleep(nanoseconds: 250_000_000) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled, busy() { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            LaunchTrace.mark("calendar.scan")
            await ProactiveEngine.shared.scanCalendar(); await ProactiveEngine.shared.prescheduleNextEvent()
        }
    }
    /// Chat surface for the root gate: the account's chat, or — never a loader and never another account's data — the
    /// storage-free launch shell rendered by the SAME ConversationFirstView (NoBug B1/B2): identical nav bar, title capsule
    /// and composer frames, starter-card slots kept empty. The account chat replaces it in place; only content fades in.
    @ViewBuilder private var chatSurface: some View {
        if let model = auth.chat { accountChat(model) }
        else if let shell = auth.launchShell, !auth.isFixture {
            ConversationFirstView(model:shell,launchShell:true)
                .onAppear { LaunchTrace.mark("chat.firstFrame", "shell", once: true) }
                .overlay(alignment:.top) { LaunchStatusOverlay(auth:auth) }
                .task { await auth.ensureLaunchChat() }
        } else {
            CatpawColors.background.ignoresSafeArea()
                .overlay(alignment:.top) { LaunchStatusOverlay(auth:auth) }
                .task { await auth.ensureLaunchChat() }
        }
    }
    @ViewBuilder private func accountChat(_ model: ConversationFirstModel) -> some View {
        ConversationFirstView(model:model,accountLabel:auth.isFixture ? ui("合成登录测试 · 无真实 Auth/模型") : (auth.state.user?.isAnonymous == true ? ui("体验账号") : auth.state.user?.email),onSignOut:{ CatpawLeaveActivity.stopAll(); Task { let l2User=auth.state.user?.id; await auth.requestSignOut { AccountLocalData.signOut(userID:l2User); if let l2User { L2SecureStore.wipe(userID:l2User) } } } },isAnonymousAccount:auth.state.user?.isAnonymous == true)
            // p89i: one shared confirmation UI for parked items of the leaving account (#89/#90/#91 sources).
            .onAppear { auth.attachParkedPrompt() }
            .sheet(isPresented:Binding(get:{ !auth.parkedPrompt.isEmpty }, set:{ if !$0 && !auth.parkedPrompt.isEmpty { auth.resolveParked([:]) } })) {
                AccountParkedDecisionSheet(items:auth.parkedPrompt) { auth.resolveParked($0) }
            }
            // L2 memory: per-user encrypted store follows the signed-in user (memory-layers.md).
            .onAppear { LaunchTrace.mark("chat.firstFrame", "account", once: true); LaunchTrace.mark("chat.visible", "account", once: true) }
            // Launch-loader fix: an unrecoverable session is a small non-blocking capsule over the usable chat.
            .overlay(alignment:.top) { if auth.sessionRestartNeeded { SessionRestartCapsule(auth:auth).padding(.top,52) } }
            // Account-bound stores activate only for the account's own chat — the launch shell never reaches this view.
            .task(id:"\(auth.state.user?.id.uuidString ?? "-")|\(ObjectIdentifier(model).hashValue)") { AccountEpoch.shared.activate(account:auth.state.user?.id.uuidString); L2SecureStore.activate(userID:auth.state.user?.id); CatpawL2Sealing.install(); AtRestMigrationScheduler.shared.sealerMayBeReady(); MemoryLibraryLocal.activate(userID:auth.state.user?.id); GenerativeBlockStore.shared.reloadFromL2(); MemoryCache.shared.reloadFromL2(); await MemoryCache.shared.sync() }
            #if DEBUG
            .overlay(alignment:.topTrailing) {
                if auth.isFixture {
                    NativeAuthFixtureChatProbe(auth:auth,model:model)
                }
            }
            #endif
    }
    /// OAuth shares the exact sign-out sequence of the settings「退出此账号」(park + L2 wipe), so a provider switch
    /// goes through the same AccountEpoch parking / EventKit prompt path.
    private func bindOAuth() {
        oauth.bind(session: auth.oauthSessionManager, projectURL: auth.oauthProjectURL, signOutAndPark: {
            CatpawLeaveActivity.stopAll(); let l2User = auth.state.user?.id
            await auth.requestSignOut { AccountLocalData.signOut(userID: l2User); if let l2User { L2SecureStore.wipe(userID: l2User) } }
        }, afterSignIn: { await auth.completeOnboarding() })
    }
    @ViewBuilder private var primaryView: some View {
        if let model = bootstrap.model {
            #if DEBUG
            if let size=P0ExperienceFixture.textSizeOverride {
                ConversationFirstView(model:model).environment(\.dynamicTypeSize,size)
            } else {
                ConversationFirstView(model:model)
            }
            #else
            ConversationFirstView(model:model)
            #endif
        }
        else if bootstrap.isP0Fixture {
            #if DEBUG
            if P0ExperienceFixture.launchEnvironment["CATPAW_REVIEW_EXPIRED"] == "1" {
                ContentUnavailableView { Label(ui("本次离线体验已到期"),systemImage:"clock") } description: {
                    Text(ui("原对话与草稿仍保留。请准备下一次体验会话后继续。"))
                }.accessibilityIdentifier("review.expired")
            } else { ProgressView("Offline fixture loading").accessibilityIdentifier("qa.p0Fixture.loading") }
            #endif
        }
        // Onboarding gate (SPEC-E §5.3): the landing and the chat share one host. Chat mounts underneath the moment the
        // gate flips, the landing stays on top for the ≤1.15 s handoff. Later launches have no landing at all.
        else {
            FirstRunTransitionHost(onboarding: auth.needsOnboarding, chat: chatSurface, ctaTitle: ui("开始使用"), placeholder: ui("问问 Catpaw")) {
                NativeLoginView(auth:auth)
                    .task { await auth.prewarmEntryChat() }
                    #if DEBUG
                    .overlay(alignment:.topTrailing) { if auth.isFixture { NativeAuthFixtureLoggedOutProbe(auth:auth) } }
                    #endif
            }
        }
    }
}

/// Over the launch shell: the restart notice when the session cannot resume, else — only if the account chat has still
/// not attached after 300 ms (NoBug B2) — a small floating 「正在打开对话…」 capsule. Never blocks, never full-screen.
private struct LaunchStatusOverlay:View {
    @ObservedObject var auth:NativeAuthApplicationModel
    @Environment(\.locale) private var locale
    @State private var late=false
    private func ui(_ key:String)->String { AppLanguage(locale:locale).ui(key) }
    var body:some View {
        ZStack(alignment:.top) {
            Color.clear.frame(width:1,height:1).accessibilityElement().accessibilityIdentifier("onboarding.enteringChat")
            if auth.sessionRestartNeeded { SessionRestartCapsule(auth:auth).padding(.top,52) }
            else if late {
                HStack(spacing:8) { ProgressView().controlSize(.small); Text(ui("正在打开对话…")).font(CatpawTypography.Role.caption.font.weight(.medium)) }
                    .foregroundStyle(CatpawColors.ink)
                    .padding(.horizontal,12).padding(.vertical,8)
                    .background(CatpawColors.panel,in:Capsule())
                    .shadow(color:.black.opacity(0.08),radius:8,y:2)
                    .padding(.top,52)
                    .transition(.opacity)
                    .accessibilityIdentifier("launch.statusCapsule")
            }
        }
        .task { try? await Task.sleep(nanoseconds:300_000_000); withAnimation(.easeOut(duration:0.2)) { late=true } }
    }
}
/// Non-blocking 「这次会话需要重新开始」 notice with the explicit restart action (same semantics as the login page button).
private struct SessionRestartCapsule:View {
    @ObservedObject var auth:NativeAuthApplicationModel
    @Environment(\.locale) private var locale
    @State private var working=false
    private func ui(_ key:String)->String { AppLanguage(locale:locale).ui(key) }
    var body:some View {
        HStack(spacing:8) {
            Image(systemName:"arrow.clockwise.circle")
            Text(ui("这次会话需要重新开始，本机对话仍会保留。")).font(CatpawTypography.Role.caption.font.weight(.medium)).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:4)
            Button { working=true; Task { await auth.restartSession(); working=false } } label: {
                if working { ProgressView().controlSize(.small) } else { Text(ui("重新开始")).font(CatpawTypography.Role.caption.font.weight(.semibold)) }
            }
            .buttonStyle(.plain).disabled(working).frame(minHeight:44)
            .accessibilityIdentifier("launch.restartSession")
        }
        .foregroundStyle(CatpawColors.ink)
        .padding(.horizontal,12).padding(.vertical,4)
        .frame(maxWidth:680)
        .background(CatpawColors.panel,in:Capsule())
        .overlay(Capsule().strokeBorder(CatpawColors.controlEdge))
        .shadow(color:.black.opacity(0.08),radius:8,y:2)
        .padding(.horizontal,20)
        .accessibilityIdentifier("launch.sessionRestart")
    }
}

#if DEBUG
private struct NativeAuthFixtureChatProbe:View {
    @ObservedObject var auth:NativeAuthApplicationModel
    @ObservedObject var model:ConversationFirstModel
    var body:some View {
        NativeAuthFixtureProbeContent(value:"\(auth.state.phase)|\(model.networkAdmissionAllowed ? "admitted" : "closed")|\(auth.state.user == nil ? "unvalidated" : "validated")|turns:\(model.session?.turns.count ?? 0)")
    }
}
private struct NativeAuthFixtureLoggedOutProbe:View {
    @ObservedObject var auth:NativeAuthApplicationModel
    var body:some View { NativeAuthFixtureProbeContent(value:"\(auth.state.phase)|closed|\(auth.state.user == nil ? "unvalidated" : "validated")|turns:0") }
}
private struct NativeAuthFixtureProbeContent:View {
    let value:String
    @Environment(\.locale) private var locale
    private func ui(_ key:String)->String { AppLanguage(locale:locale).ui(key) }
    var body:some View {
        Color.clear.frame(width:1,height:1)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(Text(ui("合成登录测试 · 无真实 Auth/模型")))
            .accessibilityValue(Text(verbatim:value))
            .accessibilityIdentifier("auth.fixture.sessionState")
    }
}
#endif

/// A foreground-only entry point. Opening never creates an identity or sends a message.
struct OpenCatpawConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Catpaw Conversation"
    static var description = IntentDescription("Open Catpaw to continue a conversation or edit a message. Opening does not send messages.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

struct CatpawAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCatpawConversationIntent(),
                    phrases: ["Open a conversation in \(.applicationName)", "Open \(.applicationName)"],
                    shortTitle: "Open conversation", systemImageName: "bubble.left.and.bubble.right")
    }
}

/// Pending out-of-app route, consumed by ConversationFirstView once the chat is ready.
@MainActor @Observable final class CatpawRouteCenter {
    static let shared = CatpawRouteCenter()
    var pending: CatpawAppRoute?
}

/// Codex PR91 #5: SwiftData memory rows sealed with the signed-in subject's L2 key; no store → the save fails.
enum CatpawL2Sealing {
    static func install() {
        ConversationMemoryAtRest.sealer = { data, subject in
            guard let store = L2SecureStore.currentForSealing, store.userID == subject else { throw L2SecureStoreError.unavailable }
            return try store.seal(data)
        }
        ConversationMemoryAtRest.opener = { data, subject in
            guard let store = L2SecureStore.currentForSealing, store.userID == subject else { throw L2SecureStoreError.unavailable }
            return try store.openSealed(data)
        }
    }
}
