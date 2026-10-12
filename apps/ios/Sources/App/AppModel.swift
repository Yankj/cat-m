import Foundation
import SwiftUI

enum AppRoute: Hashable, Codable {
    case conversation(UUID), projects, project(UUID), experts, expert(UUID), skills, skill(UUID)
    case tasks, task(UUID), schedules, document(UUID, Int), settings, environments, memories, delegation(UUID), commands, trash, localGateway
}
@MainActor final class AppModel: ObservableObject {
    let repository: Repository
    let service: WorkspaceService
    let runtime: ChatRuntime
    let gatewayRuntime: ChatRuntime
    @Published var snapshot = StoreSnapshot()
    @Published var profilePreferences: [String: String] = [:]
    private var preferencesProfileID: UUID?
    @Published var scope = Profiles.user
    @Published var path: [AppRoute] = []
    @Published var environmentKind: EnvironmentKind = .local
    @Published var error: String?
    @Published var drafts: [UUID: String] = [:]
    @Published var sending: Set<UUID> = []
    @Published var sidebar = false
    @Published var loaded = false
    @Published private(set) var switchingContext = false
    private var subscription: Task<Void, Never>?
    private var draftTasks: [UUID: Task<Void, Never>] = [:]
    private var reconciled = false
    private var clientIDs: [UUID: UUID] = [:]
    var environmentID: UUID { service.environmentID(environmentKind, scope) }
    var configuration: ConversationConfiguration { ConversationConfiguration(model: preference("model", fallback: "Auto"), safety: preference("safety", fallback: "true") == "true", subagents: preference("subagents", fallback: "false") == "true") }
    var projects: [StoredRecord] {
        list("project").filter { r in
            guard case .preference(let p) = snapshot.records[stableID("project-env-\(r.id)")]?.payload else { return false }
            return p.value == environmentID.uuidString
        }
    }
    var conversations: [StoredRecord] {
        list("conversation").filter { $0.conversation?.environmentID == environmentID }.sorted {
            let ap = preference("pin:\($0.id)", fallback: "false") == "true"
            let bp = preference("pin:\($1.id)", fallback: "false") == "true"
            return ap != bp ? ap : $0.header.updatedAt > $1.header.updatedAt
        }
    }
    init(repository: Repository, service: WorkspaceService) {
        self.repository = repository; self.service = service; runtime = ChatRuntime(repository: repository, service: service)
        gatewayRuntime = ChatRuntime(repository: repository, service: service, provider: GatewayAgentProvider(configuration: LocalGatewayService.configuration), providerMode: .fixture)
        let kind = EnvironmentKind(rawValue: UserDefaults.standard.string(forKey: "CatpawM.lastEnvironment") ?? "local") ?? .local
        environmentKind = kind; scope = Profiles.inEnvironment(kind, profile: Profiles.user)
    }
    func list(_ kind: String) -> [StoredRecord] { snapshot.list(kind, scope: scope) }
    func record(_ id: UUID) -> StoredRecord? { guard let r = snapshot.records[id], r.header.deletedAt == nil, r.header.scope == scope else { return nil }; return r }
    func preference(_ key: String, fallback: String = "") -> String {
        if ProfilePreferences.keys.contains(key) { return preferencesProfileID == scope.profileID ? profilePreferences[key] ?? fallback : fallback }
        return list("preference").compactMap { if case .preference(let p) = $0.payload, p.key == key { return p.value }; return nil }.first ?? fallback
    }
    var language: AppLanguage { AppLanguage(rawValue: preference("language", fallback: "zh-Hans")) ?? .chinese }
    func isGatewayOwned(_ id: UUID) -> Bool { GatewayAssistantImporter.owns(id, snapshot: snapshot, scope: scope) }
    func projectTitle(_ record: StoredRecord) -> String {
        let defaultID = stableID("\(scope.profileID)-\(environmentKind.rawValue)-default-project")
        return record.id == defaultID ? language.ui("默认项目 · 本机保存") : record.title
    }
    func usesLocalGateway(_ id: UUID) -> Bool {
        guard case .preference(let value) = snapshot.records[stableID("config-\(id)")]?.payload,
              let data = value.value.data(using: .utf8), let config = try? JSONDecoder().decode(ConversationConfiguration.self, from: data) else { return false }
        return config.providerID == "catpaw.gateway.v1"
    }
    func suspendRuntimes() async { await runtime.suspend(); await gatewayRuntime.suspend() }
    func cancelOperation(_ id: UUID) async throws { try await runtime.cancel(operationID: id); try await gatewayRuntime.cancel(operationID: id) }
    func retryTask(_ id: UUID) async throws {
        let task = try await repository.record(id, scope: scope)
        guard let work = task.task else { throw CatpawError.missing }
        let saved = try await repository.record(stableID("reply-request-\(work.operationID)"), scope: scope)
        guard case .preference(let value) = saved.payload, let data = value.value.data(using: .utf8) else { throw CatpawError.missing }
        let request = try JSONDecoder().decode(ChatRequest.self, from: data)
        if request.context.providerID == "catpaw.gateway.v1" {
            guard scope == Profiles.demo else { throw CatpawError.scopeMismatch }
            try await gatewayRuntime.retry(scope: scope, taskID: id, scenario: .success)
        } else { try await runtime.retry(scope: scope, taskID: id, scenario: .success) }
    }
    func newGatewayConversation(modelID: String) async throws {
        guard scope == Profiles.demo, LocalGatewayService.modelIDs.contains(modelID) else { throw CatpawError.scopeMismatch }
        let configuration = ConversationConfiguration(model: modelID, safety: true, subagents: false, providerID: "catpaw.gateway.v1")
        let id = try await service.createConversation(scope: scope, environment: environmentID, project: projects.first?.id, configuration: configuration)
        await refresh(); drafts[id] = ""; path.append(.conversation(id))
    }
    func label(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }
    func start() async {
        do {
            if !reconciled { try await service.reconcileBlobsAtLaunch(); reconciled = true }
            try await service.bootstrap(scope: scope)
            try await runtime.recoverInterrupted(scope: scope)
            await refresh()
            environmentKind = Profiles.inEnvironment(.cloud, profile: scope) == scope ? .cloud : Profiles.inEnvironment(.computer, profile: scope) == scope ? .computer : .local
            for r in list("conversation") { drafts[r.id] = r.conversation?.draftText }
            let key = "CatpawM.route.\(scope.workspaceID)"
            if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([AppRoute].self, from: data), saved.allSatisfy(validRoute) { path = saved }
            observe(); loaded = true
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        let selected = scope
        let workspace = await repository.read(scope: selected)
        let prefs = await repository.profilePreferences(profileID: selected.profileID)
        guard scope == selected else { return }
        snapshot = workspace; profilePreferences = prefs; preferencesProfileID = selected.profileID
    }
    private func observe() {
        subscription?.cancel(); let selected = scope; let sequence = snapshot.sequence
        subscription = Task { [weak self, repository] in
            let events = await repository.changes(scope: selected, after: sequence, includeProfilePreferences: true)
            for await notice in events {
                guard let self, !Task.isCancelled, self.scope == selected else { return }
                await self.refresh()
                let changedMemory = notice.recordIDs.contains { id in
                    guard let kind = self.snapshot.records[id]?.payload.kind else { return false }
                    return kind == "memory" || kind == "suppression"
                }
                if changedMemory { NativeVoiceController.shared.stopPlayback() }
            }
        }
    }
    func perform(_ body: @escaping @MainActor () async throws -> Void) {
        Task { do { try await body(); await refresh() } catch { self.error = error.localizedDescription } }
    }
    func setPreference(_ key: String, _ value: String) { perform { try await self.service.preference(scope: self.scope, key: key, value: value) } }
    func selectEnvironment(_ kind: EnvironmentKind) {
        NativeVoiceController.shared.endForegroundSession()
        perform { try await self.changeEnvironment(to: kind) }
    }
    func changeEnvironment(to kind: EnvironmentKind) async throws {
        try await changeContext(to: Profiles.inEnvironment(kind, profile: scope), kind: kind)
    }
    func changeProfile(to demo: Bool) async throws {
        try await changeContext(to: Profiles.inEnvironment(environmentKind, profile: demo ? Profiles.demo : Profiles.user), kind: environmentKind)
    }
    // Prepare target data without exposing a new scope through an old navigation stack.
    private func changeContext(to selected: DataScope, kind: EnvironmentKind) async throws {
        guard !switchingContext else { return }
        switchingContext = true
        defer { switchingContext = false }
        try await saveDraftsBeforeLeaving()
        saveNavigation()
        try await service.bootstrap(scope: selected)
        try await runtime.recoverInterrupted(scope: selected)
        let targetSnapshot = await repository.read(scope: selected)
        let targetPreferences = await repository.profilePreferences(profileID: selected.profileID)
        await suspendRuntimes(); subscription?.cancel()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            loaded = false; sidebar = false; path = []; drafts = [:]; clientIDs = [:]
            scope = selected; environmentKind = kind; snapshot = targetSnapshot
            profilePreferences = targetPreferences; preferencesProfileID = selected.profileID
            for record in targetSnapshot.list("conversation", scope: selected) { drafts[record.id] = record.conversation?.draftText }
            loaded = true
        }
        UserDefaults.standard.set(kind.rawValue, forKey: "CatpawM.lastEnvironment")
        saveNavigation(); observe()
    }
    private func saveDraftsBeforeLeaving() async throws {
        for t in draftTasks.values { t.cancel() }; draftTasks = [:]
        let pending = drafts.filter { record($0.key) != nil }
        try await repository.saveDraftsAtomically(scope: scope, drafts: pending)
    }
    func changeProject(from id: UUID, to project: UUID?) async throws {
        draftTasks[id]?.cancel(); draftTasks[id] = nil
        let text = drafts[id] ?? record(id)?.conversation?.draftText ?? ""
        let target = try await service.selectProjectConversation(scope: scope, sourceID: id, project: project, draft: text)
        await refresh()
        drafts[target] = record(target)?.conversation?.draftText ?? ""
        if path.last == .conversation(id) { path[path.count - 1] = .conversation(target) }
        else { path.append(.conversation(target)) }
    }
    func newConversation(expert: UUID? = nil, prompt: String = "") {
        perform {
            let id = try await self.service.createConversation(scope: self.scope, environment: self.environmentID, project: self.projects.first?.id, expert: expert, configuration: self.configuration)
            self.drafts[id] = prompt
            if !prompt.isEmpty { try await self.service.saveDraft(scope: self.scope, conversationID: id, text: prompt) }
            self.path.append(.conversation(id)); self.sidebar = false
        }
    }
    func editDraft(_ id: UUID, text: String) {
        drafts[id] = text; draftTasks[id]?.cancel(); let selected = scope
        draftTasks[id] = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation()
                guard scope == selected else { return }
                try await service.saveDraft(scope: selected, conversationID: id, text: text)
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    func send(_ id: UUID, scenario: FixtureScenario) {
        guard !sending.contains(id) else { return }
        let text = drafts[id] ?? ""; let client = clientIDs[id] ?? UUID(); clientIDs[id] = client
        sending.insert(id); draftTasks[id]?.cancel()
        perform {
            defer { self.sending.remove(id) }
            let usesGateway = self.usesLocalGateway(id)
            guard !usesGateway || self.scope == Profiles.demo else { throw CatpawError.scopeMismatch }
            let selectedRuntime = usesGateway ? self.gatewayRuntime : self.runtime
            _ = try await selectedRuntime.send(scope: self.scope, conversationID: id, text: text, clientMessageID: client, scenario: scenario)
            if self.drafts[id] == text { self.drafts[id] = "" }
            self.clientIDs.removeValue(forKey: id)
        }
    }
    func switchProfile(_ demo: Bool) {
        NativeVoiceController.shared.endForegroundSession()
        perform { try await self.changeProfile(to: demo) }
    }
    func suspend() async {
        NativeVoiceController.shared.endForegroundSession()
        for t in draftTasks.values { t.cancel() }; draftTasks = [:]
        let selected = scope
        for (id, text) in drafts where record(id) != nil { do { try await service.saveDraft(scope: selected, conversationID: id, text: text) } catch { self.error = error.localizedDescription } }
        await suspendRuntimes()
    }
    func tick(resumed: Bool) async {
        do {
            let templates = try await service.claimDueSchedules(scope: scope, now: Date(), resumed: resumed)
            for template in templates {
                let id = try await service.createConversation(scope: scope, environment: template.environmentID, project: template.projectID, configuration: template.configuration)
                _ = try await runtime.send(scope: scope, conversationID: id, text: template.prompt, clientMessageID: UUID(), scenario: .success)
            }
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ r: StoredRecord) { perform { try await self.repository.commit(scope: self.scope, mutations: [.remove(r.id, r.header.revision)]) } }
    func saveNavigation() { if loaded, let data = try? JSONEncoder().encode(path) { UserDefaults.standard.set(data, forKey: "CatpawM.route.\(scope.workspaceID)") } }
    private func validRoute(_ route: AppRoute) -> Bool {
        switch route {
        case .conversation(let id), .project(let id), .expert(let id), .skill(let id), .task(let id), .delegation(let id): return record(id) != nil
        case .document(let id, let version): return record(id) != nil && record(stableID("\(id)-v\(version)")) != nil
        default: return true
        }
    }
    func openDeepLink(_ url: URL) {
        do {
            switch try DeepLinkResolver.resolve(url, snapshot: snapshot, scope: scope) {
            case .conversation(let id): path = [.conversation(id)]
            case .task(let id): path = [.task(id)]
            case .document(let id, let version): path = [.document(id, version)]
            default: throw CatpawError.invalid("链接不可用。")
            }
        } catch { self.error = error.localizedDescription }
    }
}
