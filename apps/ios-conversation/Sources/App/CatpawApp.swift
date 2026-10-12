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
                p0Model=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:P0ExperienceBackend(scenario:scenario)))
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
                        .safeAreaInset(edge:.top) { VStack { Text(synthetic.fixtureIdentity ?? "明确合成测试").font(.caption).accessibilityIdentifier("fixture.identity"); Button("运行冻结合成报告") { Task { await synthetic.sendFrozenCase() } }.disabled(!synthetic.ready || synthetic.submitted).accessibilityIdentifier("fixture.run"); if let error = synthetic.error { Text(error).accessibilityIdentifier("fixture.error") } }.padding(8).background(CatpawColors.panel) }
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
            ConversationFirstView(model:model).environment(\.dynamicTypeSize,P0ExperienceFixture.scenario == "p0-ui-large" ? .accessibility5 : .large)
            #else
            ConversationFirstView(model:model)
            #endif
        }
        else if bootstrap.isP0Fixture { ProgressView("Offline fixture loading").accessibilityIdentifier("qa.p0Fixture.loading") }
        else if let model = auth.chat { ConversationFirstView(model:model,accountLabel:auth.isFixture ? "合成登录测试 · 无真实 Auth/模型" : (auth.state.user?.isAnonymous == true ? "体验账号" : auth.state.user?.email),onSignOut:{ Task { await auth.signOut() } },isAnonymousAccount:auth.state.user?.isAnonymous == true) }
        else { NativeLoginView(auth:auth) }
    }
}

/// A foreground-only entry point. Opening never creates an identity or sends a message.
struct OpenCatpawConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 Catpaw 对话"
    static var description = IntentDescription("打开 Catpaw，继续对话或编辑消息。不会自动发送消息。")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

struct CatpawAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCatpawConversationIntent(),
                    phrases: ["在 \(.applicationName) 打开对话", "打开 \(.applicationName)"],
                    shortTitle: "打开对话", systemImageName: "bubble.left.and.bubble.right")
    }
}
