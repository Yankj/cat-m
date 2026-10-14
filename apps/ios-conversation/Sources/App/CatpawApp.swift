import SwiftUI
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
        guard let test = ProcessInfo.processInfo.environment["CF_UI_TEST_STORE"], UUID(uuidString:test) != nil else { model = nil; error = nil; return }
        #else
        model = nil; error = nil; return
        #endif
        #if DEBUG
        if let scenario=P0ExperienceFixture.scenario,let id=ProcessInfo.processInfo.environment["CF_UI_TEST_STORE"] {
            do {
                let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CatpawP0-qa-"+id)
                let repository=try Repository(persistence:SwiftDataPersistence(url:root.appendingPathComponent("local.store")))
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
        if let test = ProcessInfo.processInfo.environment["CF_UI_TEST_STORE"], UUID(uuidString: test) != nil { directory += "-qa-" + test }
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
            if let test = ProcessInfo.processInfo.environment["CF_UI_TEST_STORE"], UUID(uuidString: test) != nil,
               ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] == "active-followup" { backend = ConversationUITestHarness() }
            #endif
            model = ConversationFirstModel(repository: repo, service: ConversationSessionService(repository: repo, backend: backend)); error = nil
        } catch { self.model = nil; self.error = error.localizedDescription }
    }
    func startFixture() async {
        #if DEBUG
        guard let pending=p0Model,model == nil else { return }
        do {
            let id=try await pending.service.openLatest(scope:pending.scope),record=try await pending.repository.record(id,scope:pending.scope)
            if record.conversation?.draftText.isEmpty == true,try await pending.service.read(scope:pending.scope,conversationID:id).messages.isEmpty {
                try await pending.service.saveDraft(scope:pending.scope,conversationID:id,text:"Saved local draft")
            }
            await pending.start();model=pending
            if P0ExperienceFixture.scenario == "p0-ui-large-autoplay" {
                Task {
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                    pending.editDraft("Synthetic offline automatic render diagnostic")
                    P0PerformanceLog.shared.mark("synthetic_autoplay_action");pending.prepareSend()
                    try? await Task.sleep(nanoseconds:6_000_000_000)
                    P0ExperienceProbe.shared.exportMetrics()
                    if let id=ProcessInfo.processInfo.environment["CF_UI_TEST_STORE"] {
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
    @StateObject private var bootstrap = Bootstrap()
    @StateObject private var auth = NativeAuthApplicationModel()
    @Environment(\.scenePhase) private var scene
    #if DEBUG
    @StateObject private var synthetic = NativeSyntheticApplicationModel()
    #endif
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
            }.task { if bootstrap.isP0Fixture { await bootstrap.startFixture() } else if bootstrap.model == nil { await auth.start() } }
                .onChange(of:scene) { _, phase in if phase == .active,bootstrap.model == nil,!bootstrap.isP0Fixture { Task { await auth.foreground() } } }
        }
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
        else if bootstrap.isP0Fixture { ProgressView("Offline fixture loading").accessibilityIdentifier("qa.p0Fixture.loading") }
        else if let model = auth.chat {
            ConversationFirstView(model:model,accountLabel:auth.isFixture ? ui("合成登录测试 · 无真实 Auth/模型") : (auth.state.user?.isAnonymous == true ? ui("体验账号") : auth.state.user?.email),onSignOut:{ Task { await auth.signOut() } },isAnonymousAccount:auth.state.user?.isAnonymous == true)
                #if DEBUG
                .overlay(alignment:.topTrailing) {
                    if auth.isFixture {
                        NativeAuthFixtureChatProbe(auth:auth,model:model)
                    }
                }
                #endif
        }
        else {
            NativeLoginView(auth:auth)
                #if DEBUG
                .overlay(alignment:.topTrailing) { if auth.isFixture { NativeAuthFixtureLoggedOutProbe(auth:auth) } }
                #endif
        }
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
