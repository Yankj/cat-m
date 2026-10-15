import SwiftUI
import UniformTypeIdentifiers

struct ProfileExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
@MainActor struct SettingsView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    @State private var exportDocument = ProfileExport(data: Data())
    @State private var exporting = false
    @State private var reset = false
    var body: some View {
        List {
            Section {
                NavigationLink(ui("我的设备"), value: AppRoute.environments)
                NavigationLink(ui("自定义命令"), value: AppRoute.commands)
                NavigationLink(ui("本地回收站"), value: AppRoute.trash)
                Toggle(ui("演示数据分区"), isOn: Binding(get: { model.scope.profileID == Profiles.demo.profileID }, set: { model.switchProfile($0) })).disabled(model.switchingContext)
                Button(ui("导出当前 workspace 本地数据")) { model.perform { exportDocument = ProfileExport(data: try await model.repository.exportProfile(scope: model.scope)); exporting = true } }
                if model.scope.profileID == Profiles.demo.profileID { Button(ui("重置演示分区"), role: .destructive) { reset = true } }
            } header: { sectionHeader(ui("应用")) }
            Section {
                Toggle(ui("文件删除确认"), isOn: booleanPreference("delete_confirmation", fallback: "true"))
                Toggle(ui("Subagents · 仅新对话配置"), isOn: booleanPreference("subagents", fallback: "false"))
                Toggle(ui("安全屋 · 仅新对话配置"), isOn: booleanPreference("safety", fallback: "true"))
                Text(ui("尚未接执行沙箱或协作 worker。本地偏好不授予 OS 或服务权限。")).font(.system(size: 12)).foregroundStyle(CatpawColors.tertiary)
                Picker(ui("新对话模型配置"), selection: Binding(get: { model.preference("model", fallback: "Auto") }, set: { model.setPreference("model", $0) })) { ForEach(["Auto", "Lite", "Pro", "Max", "LongCat-2.0", "deepseek-v4-flash"], id: \.self) { Text($0).tag($0) } }
            } header: { sectionHeader(ui("系统设置 · 本地偏好")) }
            Section {
                Text(ui("麦克风/识别：{0}", arguments: [String(describing: (NativeVoiceController.shared.permissionDescription(language: model.language)))]))
                Text(ui("相机和相册仅在你主动选择对应入口时使用系统选择器；不会在启动时申请权限。图片只保存在当前本地项目，设备采集路径尚需真机验收。")).font(.footnote)
                Toggle(ui("成果提醒 · App 内偏好"), isOn: booleanPreference("result_notifications", fallback: "false"))
                Text(ui("系统推送与持久云调度尚未连接，不会自动申请通知权限。")).font(.footnote)
            } header: { sectionHeader(ui("权限")) }
            Section {
                Picker(ui("主题"), selection: Binding(get: { model.preference("theme", fallback: "dark") }, set: { model.setPreference("theme", $0) })) { Text(ui("深色")).tag("dark"); Text(ui("浅色 · 本地补充")).tag("light"); Text(ui("跟随系统")).tag("system") }.accessibilityIdentifier("settings.theme")
                Picker(ui("界面语言"), selection: Binding(get: { model.preference("language", fallback: "zh-Hans") }, set: { model.setPreference("language", $0) })) { Text(ui("中文")).tag("zh-Hans"); Text("English").tag("en") }
                Text(ui("主题与语言等偏好在同一用户的云端、电脑、本机视图共享；会话配置保持创建时快照。")).font(.footnote)
            } header: { sectionHeader(ui("外观")) }
            Section {
                StatusLabel(text: ui("云同步显式关闭"))
                Text(ui("真实 Provider 未配置，远端执行均标明模拟。")).font(.system(size: 12)).foregroundStyle(CatpawColors.tertiary)
            } header: { sectionHeader(ui("版本与数据")) }
            Section {
                NavigationLink(ui("本地 Gateway · 合成数据"), value: AppRoute.localGateway).accessibilityIdentifier("settings.localGateway")
                NavigationLink(ui("OpenMuse · 合成 Demo"), value: AppRoute.openMuseDemo).accessibilityIdentifier("settings.openMuseDemo")
            } header: { sectionHeader(ui("开发联调")) }
            Section {
                EmptyView()
            } footer: {
                VStack(spacing: 4) {
                    Text(ui("Catpaw-m 原生本地版 0.1.0"))
                    Text(ui("界面控件提供中英文；文档、用户内容、示例正文及系统或服务错误保留原文。英文布局与原生音频仍需设备验收。"))
                }.font(.system(size: 12)).foregroundStyle(CatpawColors.tertiary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CatpawColors.groupedBackground)
        .environment(\.defaultMinListRowHeight, 48)
        .tint(CatpawColors.ink)
        .navigationTitle(ui("设置"))
        .navigationBarTitleDisplayMode(.large)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Catpaw-workspace-export") { result in if case .failure(let error) = result { model.error = error.localizedDescription } }
        .confirmationDialog(ui("只重置全部演示环境；用户分区保留。"), isPresented: $reset) { Button(ui("重置演示"), role: .destructive) { model.perform { await model.suspendRuntimes(); NativeVoiceController.shared.interrupt(); try await model.repository.resetDemo(); model.path = []; model.drafts = [:]; model.loaded = false; await model.start() } } }
    }
    /// r9 §5: section headers are 13pt tertiary, not uppercased.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(CatpawColors.tertiary).textCase(nil)
    }
    private func booleanPreference(_ key: String, fallback: String) -> Binding<Bool> { Binding(get: { model.preference(key, fallback: fallback) == "true" }, set: { model.setPreference(key, $0 ? "true" : "false") }) }
}
@MainActor struct EnvironmentsView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    var body: some View { Page { ForEach(model.list("environment")) { r in if case .core(.environment(let e)) = r.payload { Panel { Text(e.name).font(.headline); StatusLabel(text: e.kind == .local ? ui("本机私有数据可用") : ui("服务未连接 · 状态未核验")); Button(ui("切换到{0}本地视图", arguments: [String(describing: (e.name))])) { NativeVoiceController.shared.interrupt(); model.selectEnvironment(e.kind) }.touchTarget() } } }; Text(ui("没有模拟在线设备。电脑配对、云账号和心跳接口尚未接入。")).foregroundStyle(.secondary) }.navigationTitle(ui("我的设备")) }
}
struct LocalCommandDefinition: Codable { var name: String; var prompt: String }
@MainActor struct CommandsView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    @State private var create = false; @State private var name = ""; @State private var prompt = ""
    var body: some View {
        Page {
            Text(ui("命令为本地提示词模板；创建表单是补充流程，不执行 shell。")).font(.footnote).foregroundStyle(.secondary)
            if commands.isEmpty { EmptyState(title: ui("暂无自定义命令"), detail: ui("保存常用提示词，再带入会话编辑。")) }
            ForEach(commands) { r in if case .preference(let p) = r.payload, let data = p.value.data(using: .utf8), let command = try? JSONDecoder().decode(LocalCommandDefinition.self, from: data) { Panel { Text(command.name).font(.headline); Text(command.prompt).foregroundStyle(.secondary); Button(ui("带入输入")) { if let route = model.path.dropLast().last, case .conversation(let id) = route { model.editDraft(id, text: command.prompt); _ = model.path.popLast() } else { model.newConversation(prompt: command.prompt) } }; Button(ui("删除"), role: .destructive) { model.delete(r) } } } }
            Button(ui("创建本地命令")) { create = true }.primaryAction()
        }.navigationTitle(ui("自定义命令"))
        .sheet(isPresented: $create) { NavigationStack { Form { TextField(ui("名称"), text: $name); TextEditor(text: $prompt).frame(minHeight: 180) }.navigationTitle(ui("创建本地命令")).toolbar { Button(ui("取消")) { create = false }; Button(ui("保存")) { model.perform { guard !name.isEmpty, !prompt.isEmpty else { throw CatpawError.invalid(ui("名称与提示词必填。")) }; let data = try JSONEncoder().encode(LocalCommandDefinition(name: name, prompt: prompt)); try await model.service.preference(scope: model.scope, key: "command:\(UUID())", value: String(data: data, encoding: .utf8)!); create = false; name = ""; prompt = "" } } } } }
    }
    private var commands: [StoredRecord] { model.list("preference").filter { if case .preference(let p) = $0.payload { return p.key.hasPrefix("command:") }; return false } }
}
@MainActor struct TrashView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    var body: some View { Page { let removed = model.snapshot.records.values.filter { $0.header.deletedAt != nil && $0.header.scope == model.scope }; if removed.isEmpty { EmptyState(title: ui("回收站为空"), detail: ui("这里只显示当前环境的本地删除项。")) }; ForEach(removed.sorted { $0.header.updatedAt > $1.header.updatedAt }) { r in Panel { Text(r.title); Text(ui("本地补充的恢复流程")).font(.caption).foregroundStyle(.secondary); Button(ui("恢复原 ID")) { model.perform { try await model.repository.commit(scope: model.scope, mutations: [.restore(r.id, r.header.revision)]) } }.touchTarget() } } }.navigationTitle(ui("本地回收站")) }
}
