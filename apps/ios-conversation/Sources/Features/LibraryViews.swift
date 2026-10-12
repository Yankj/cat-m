import SwiftUI

@MainActor struct ProjectsView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    @State private var create = false; @State private var name = ""
    var body: some View {
        Page {
            StatusLabel(text: ui("本机保存 · 尚未同步"))
            ForEach(model.projects) { r in NavigationLink(value: AppRoute.project(r.id)) { Panel { Label(model.projectTitle(r), systemImage: "folder"); Text(ui("会话与文件使用同一项目 ID")).font(.footnote).foregroundStyle(.secondary) } } }
            Button(ui("新建本地项目")) { create = true }.primaryAction().accessibilityIdentifier("projects.create")
        }.navigationTitle(ui("项目"))
        .alert(ui("新建本地项目"), isPresented: $create) { TextField(ui("名称"), text: $name); Button(ui("创建")) { model.perform { _ = try await model.service.createProject(scope: model.scope, name: name, environment: model.environmentID); name = "" } }; Button(ui("取消"), role: .cancel) { } }
    }
}
@MainActor struct ProjectView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let id: UUID
    @State private var expanded = true
    var body: some View {
        Page {
            if let r = model.record(id) {
                Text(model.projectTitle(r)).font(.largeTitle.bold())
                DisclosureGroup(ui("项目文件"), isExpanded: $expanded) {
                    let docs = model.list("document").filter { $0.document?.ownerIDs.contains(id) == true }
                    if docs.isEmpty { Text(ui("还没有本地文件。可从会话加号导入。")).foregroundStyle(.secondary) }
                    ForEach(docs) { d in NavigationLink(value: AppRoute.document(d.id, d.document!.currentVersion)) { Label(d.title, systemImage: "doc").touchTarget() } }
                }
                Text(ui("会话")).font(.headline)
                ForEach(model.list("conversation").filter { $0.conversation?.projectID == id }) { c in NavigationLink(c.title, value: AppRoute.conversation(c.id)).touchTarget() }
            } else { EmptyState(title: ui("项目不可用"), detail: ui("当前环境没有这项内容。")) }
        }.navigationTitle(ui("项目文件"))
    }
}
@MainActor struct CatalogView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let isSkill: Bool
    @State private var tab = 0; @State private var query = ""; @State private var category: CatalogCategory?
    var body: some View {
        Page {
            Picker(ui("目录"), selection: $tab) { Text(ui("市场")).tag(0); Text(isSkill ? ui("已安装") : ui("我的")).tag(1) }.pickerStyle(.segmented)
            TextField(isSkill ? ui("搜索技能") : ui("搜索专家"), text: $query).textFieldStyle(.roundedBorder)
            Picker(ui("分类"), selection: $category) { Text(ui("全部")).tag(CatalogCategory?.none); ForEach(CatalogCategory.allCases, id: \.self) { Text($0.title(model.language)).tag(Optional($0)) } }.pickerStyle(.menu)
            StatusLabel(text: ui("本地目录 · 执行与安装均为模拟"))
            if filtered.isEmpty { EmptyState(title: isSkill ? ui("暂无已安装技能") : ui("暂无所选专家"), detail: ui("目录中的配置与当前环境独立保存。")) }
            ForEach(filtered) { r in NavigationLink(value: isSkill ? AppRoute.skill(r.id) : AppRoute.expert(r.id)) { Panel { HStack { Image(systemName: isSkill ? "books.vertical" : "brain.head.profile").font(.title); Text(r.title).font(.headline); Spacer(); Image(systemName: "chevron.right") }; Text(summary(r)).foregroundStyle(.secondary).lineLimit(3) } } }
        }.navigationTitle(isSkill ? ui("技能") : ui("专家"))
    }
    private var filtered: [StoredRecord] {
        model.list(isSkill ? "skill" : "expert").filter { r in
            guard CatalogFilter.matches(r, category: category, query: query) else { return false }
            if tab == 0 { return true }
            if case .core(.skill(let p)) = r.payload { return p.enabledScopeIDs.contains(model.environmentID) }
            return model.list("conversation").contains { $0.conversation?.expertID == r.id }
        }
    }
    private func summary(_ r: StoredRecord) -> String { switch r.payload { case .core(.expert(let p)): return p.summary; case .core(.skill(let p)): return p.summary; default: return "" } }
}
@MainActor struct CatalogDetailView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let id: UUID
    var body: some View {
        Page {
            if let r = model.record(id) {
                Text(r.title).font(.largeTitle.bold())
                switch r.payload {
                case .core(.expert(let p)):
                    StatusLabel(text: ui("本地配置 · 执行未接真实服务"))
                    Text(ui("目录参考版本 v2.0.3")).font(.footnote).foregroundStyle(.secondary)
                    Text(p.summary); Text(ui("文档处理 · Office 文档 · PDF 处理")).font(.footnote).foregroundStyle(.secondary)
                    Panel { Text(ui("示例问法")).font(.headline); Button("帮我整理这份文档的要点") { model.newConversation(expert: id, prompt: "帮我整理这份文档的要点") }.touchTarget() }
                    Button(ui("使用专家")) { model.newConversation(expert: id) }.primaryAction()
                case .core(.skill(let p)):
                    Text(ui("版本 {0}", arguments: [String(describing: (p.version))])).foregroundStyle(.secondary); Text(p.summary)
                    let installed = p.enabledScopeIDs.contains(model.environmentID)
                    Button(installed ? ui("卸载本地模拟记录") : ui("模拟安装到当前环境")) { model.perform { try await model.service.installSkill(scope: model.scope, id: id, environment: model.environmentID, enabled: !installed) } }.primaryAction()
                    Text(ui("不会安装任何软件。能力尚未接通。")).font(.footnote).foregroundStyle(.secondary)
                default: EmptyState(title: ui("目录内容不可用"), detail: ui("类型不匹配。"))
                }
            } else { EmptyState(title: ui("内容不可用"), detail: ui("请返回当前环境目录。")) }
        }.navigationTitle(ui("详情"))
    }
}
@MainActor struct TasksView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    var body: some View { Page { if model.list("task").isEmpty { EmptyState(title: ui("还没有任务"), detail: ui("发送一条消息会建立可追踪的模拟运行。")) }; ForEach(model.list("task")) { r in NavigationLink(value: AppRoute.task(r.id)) { Panel { Text(r.title).font(.headline); StatusLabel(text: ui("{0} · 模拟", arguments: [String(describing: (r.task?.state.displayName(language: model.language) ?? ""))])) } } } }.navigationTitle(ui("任务")) }
}
@MainActor struct TaskDetailView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let id: UUID
    @State private var process = true
    var body: some View {
        Page {
            if let r = model.record(id), let task = r.task {
                Text(task.title).font(.title.bold()); StatusLabel(text: ui("{0} · 模拟", arguments: [String(describing: (task.state.displayName(language: model.language)))]))
                let done = task.steps.filter { $0.state == .succeeded }.count
                DisclosureGroup(ui("进度 {0}/{1}", arguments: [String(describing: (done)), String(describing: (task.steps.count))]), isExpanded: $process) {
                    ForEach(task.steps, id: \.id) { step in Label(step.title, systemImage: step.state == .succeeded ? "checkmark.circle" : "circle").padding(.vertical, 8) }
                }
                Text(ui("过程与进度来自当前任务记录；没有远程工具执行。")).font(.footnote).foregroundStyle(.secondary)
                ForEach(task.results, id: \.self) { ref in NavigationLink(value: AppRoute.document(ref.documentID, ref.version)) { Label(ui("打开成果 v{0}", arguments: [String(describing: (ref.version))]), systemImage: "doc.text").touchTarget() } }
                NavigationLink(ui("回到会话"), value: AppRoute.conversation(task.conversationID)).touchTarget()
                if !model.isGatewayOwned(id), [.queued, .running, .preparing].contains(task.state) { Button(ui("取消模拟运行")) { model.perform { try await model.cancelOperation(task.operationID) } }.touchTarget() }
                if !model.isGatewayOwned(id), task.state == .failed || task.state == .cancelled { Button(ui("按原请求快照重试模拟运行")) { model.perform { try await model.retryTask(id) } }.touchTarget(); Text(ui("沿用原操作 ID 与输入配置，旧失败记录单独保留。")).foregroundStyle(.secondary) }
            } else { EmptyState(title: ui("任务不可用"), detail: ui("请从当前环境的会话重新打开。")) }
        }.navigationTitle(ui("任务进度"))
    }
}
