import SwiftUI
import Combine

@MainActor struct RootView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var launchMarkVisible=true
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack(path: $model.path) {
            BriefView(model: model)
                .navigationTitle(ui("个人助理"))
                .compactNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .navigation) { Button { model.sidebar = true } label: { CatpawSymbol(name: "line.3.horizontal").foregroundStyle(CatpawColors.ink).touchTarget() }.accessibilityLabel(ui("打开侧栏")).accessibilityIdentifier("root.sidebar") }
                    ToolbarItem { Button { model.newConversation() } label: { CatpawSymbol(name: "square.and.pencil").foregroundStyle(CatpawColors.ink).touchTarget() }.accessibilityLabel(ui("新任务")).accessibilityIdentifier("root.newConversation") }
                }
                .navigationDestination(for: AppRoute.self) { route in destination(route) }
        }
        .id(model.scope.workspaceID)
        .tint(CatpawColors.ink)
        .environment(\.locale, Locale(identifier: model.language.rawValue))
        .preferredColorScheme(model.preference("theme", fallback: "dark") == "system" ? nil : model.preference("theme", fallback: "dark") == "light" ? .light : .dark)
        .sheet(isPresented: $model.sidebar) { SidebarView(model: model).tint(CatpawColors.ink).presentationDetents([.large]).presentationDragIndicator(.visible) }
        .alert(ui("操作未完成"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(ui("好")) { model.error = nil } } message: { Text(model.error ?? "") }
        .overlay {
            // 方块's two-stage loader: the same mark as CatpawApp's (identical geometry), held until this model has loaded.
            if launchMarkVisible {
                CatpawLaunchMark(isReady:model.loaded) {launchMarkVisible=false}
                    .zIndex(100)
            }
        }
        .task { if !model.loaded { await model.start() }; await model.tick(resumed: true) }
        .onReceive(timer) { _ in if phase == .active { Task { await model.tick(resumed: false) } } }
        .onChange(of: model.path) { _, _ in model.saveNavigation() }
        .onOpenURL { launchMarkVisible=false;model.openDeepLink($0) }
        .onChange(of: phase) { _, value in Task { if value == .active { await model.tick(resumed: true) } else { await model.suspend() } } }
    }
    @ViewBuilder private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .conversation(let id):
            if model.isGatewayOwned(id) { GatewayConversationMirrorView(model: model, id: id) }
            else { ConversationView(model: model, id: id) }
        case .projects: ProjectsView(model: model)
        case .project(let id): ProjectView(model: model, id: id)
        case .experts: CatalogView(model: model, isSkill: false)
        case .expert(let id): CatalogDetailView(model: model, id: id)
        case .skills: CatalogView(model: model, isSkill: true)
        case .skill(let id): CatalogDetailView(model: model, id: id)
        case .tasks: TasksView(model: model)
        case .task(let id): TaskDetailView(model: model, id: id)
        case .schedules: SchedulesView(model: model)
        case .document(let id, let version): DocumentView(model: model, id: id, version: version)
        case .settings: SettingsView(model: model)
        case .environments: EnvironmentsView(model: model)
        case .memories: MemoriesView(model: model)
        case .delegation(let id):
            if model.isGatewayOwned(id) { GatewayDelegationMirrorView(model: model, id: id) }
            else { DelegationView(model: model, id: id) }
        case .commands: CommandsView(model: model)
        case .trash: TrashView(model: model)
        case .localGateway: LocalGatewayView(model: model)
        case .openMuseDemo: OpenMuseDemoView(model: model)
        }
    }
}
@MainActor struct SidebarView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    var body: some View {
        Page {
            HStack { Text("Catpaw-m").font(.title2.weight(.semibold)); Spacer(); Button { model.sidebar = false } label: { CatpawSymbol(name: "xmark").touchTarget() }.accessibilityLabel(ui("关闭")) }
            Picker(ui("环境"), selection: Binding(get: { model.environmentKind }, set: { model.selectEnvironment($0) })) {
                Text(ui("本机")).tag(EnvironmentKind.local); Text(ui("云端")).tag(EnvironmentKind.cloud); Text(ui("电脑")).tag(EnvironmentKind.computer)
            }.pickerStyle(.segmented).disabled(model.switchingContext)
            VStack(alignment: .leading, spacing: 2) {
                Button { model.newConversation() } label: { ActionRow(title: ui("新任务"), symbol: "square.and.pencil") }
                link(ui("个人助理"), "sparkles", nil)
                link(ui("定时任务"), "clock", .schedules); link(ui("专家"), "brain.head.profile", .experts); link(ui("技能"), "books.vertical", .skills)
                link(ui("全部任务"), "checklist", .tasks); link(ui("项目"), "folder", .projects)
            }.buttonStyle(.plain)
            ForEach(model.projects) { r in Button { open(.project(r.id)) } label: { ActionRow(title: model.projectTitle(r), symbol: "folder") } }
            Text(ui("历史")).font(.headline).foregroundStyle(.secondary)
            ForEach(model.conversations) { r in Button { open(.conversation(r.id)) } label: { ActionRow(title: r.title, symbol: "bubble.left") } }
            Divider(); link(ui("设置"), "gearshape", .settings)
            StatusLabel(text: model.environmentKind == .local ? ui("本机保存 · 云同步关闭") : ui("{0}视图 · 服务未连接", arguments: [String(describing: (model.environmentKind == .cloud ? ui("云端") : ui("电脑")))]))
        }.background(CatpawColors.background).tint(CatpawColors.ink)
    }
    private func open(_ route: AppRoute?) { model.path = route.map { [$0] } ?? []; model.sidebar = false }
    private func link(_ title: String, _ icon: String, _ route: AppRoute?) -> some View { Button { open(route) } label: { ActionRow(title: title, symbol: icon == "sparkles" ? "person.crop.circle" : icon) }.buttonStyle(.plain).accessibilityIdentifier("sidebar.\(icon)") }
}
