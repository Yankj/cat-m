import SwiftUI

@MainActor struct LocalGatewayView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject var model: AppModel
    @State private var modelID = LocalGatewayService.modelIDs[0]
    @State private var busy = false
    private enum Status { case idle, checking, connected, syncing, synced, unchanged, failed }
    @State private var status = Status.idle
    private var statusText: String {
        switch status {
        case .idle: return ui("尚未检查本地连接")
        case .checking: return ui("正在检查本地连接")
        case .connected: return ui("合成 Gateway 已连接 · 真实调用关闭")
        case .syncing: return ui("正在读取合成成果")
        case .synced: return ui("合成成果已保存到演示分区")
        case .unchanged: return ui("成果版本未变化")
        case .failed: return ui("联调未完成，原记录保留")
        }
    }
    var body: some View {
        Page {
            StatusLabel(text: ui("默认仍是本机 Fixture；此入口只连接 127.0.0.1:8787。"))
            Text(ui("四个模型名称均为合成测试配置，不代表真实模型质量、免费资格或在线调用。")).font(.footnote).foregroundStyle(.secondary)
            StatusLabel(text: statusText).accessibilityIdentifier("gateway.status")
            Button(ui("检查本地连接")) { run(sync: false) }.touchTarget().accessibilityIdentifier("gateway.probe")
            Picker(ui("合成模型配置"), selection: $modelID) { ForEach(LocalGatewayService.modelIDs, id: \.self) { Text($0).tag($0) } }
            if model.scope == Profiles.demo {
                Button(ui("新建 Gateway 演示会话")) { model.perform { try await model.newGatewayConversation(modelID: modelID) } }.primaryAction().accessibilityIdentifier("gateway.newConversation")
                Button(ui("同步本地成果")) { run(sync: true) }.touchTarget().accessibilityIdentifier("gateway.sync")
                Text(ui("服务端生成的委托和版本只读回流；本地输入与会话回复使用同一 Repository。")).font(.footnote).foregroundStyle(.secondary)
            } else { Text(ui("请先在设置中开启演示数据分区，并选择本机环境。用户分区不会发送给联调服务。")).foregroundStyle(.secondary) }
            Text(ui("App 不启动常驻服务；没有真实账号、模型密钥、云执行或系统推送。")).font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle(ui("本地 Gateway 联调")).disabled(busy)
    }
    private func run(sync: Bool) {
        let scope = model.scope, environment = model.environmentID
        busy = true; status = sync ? .syncing : .checking
        Task {
            defer { busy = false }
            do {
                let service = LocalGatewayService(repository: model.repository, blobs: model.service.blobs)
                if sync {
                    let changed = try await service.sync(scope: scope, environmentID: environment)
                    guard model.scope == scope else { return }
                    await model.refresh(); status = changed ? .synced : .unchanged
                } else { try await service.probe(); status = .connected }
            } catch { status = .failed; model.error = error.localizedDescription }
        }
    }
}

@MainActor struct GatewayDelegationMirrorView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject var model: AppModel; let id: UUID
    var body: some View {
        Page {
            if let record = model.record(id), let delegation = record.delegation {
                Text(record.title).font(.title.bold())
                StatusLabel(text: ui("Gateway 合成委托 · 只读回流"))
                Text(delegation.goal); Text(DelegationRequirements.decode(delegation.scopeJSON).requirements)
                Text(delegation.state.displayName(language: model.language)); Text(delegation.health).font(.footnote).foregroundStyle(.secondary)
                Text(ui("暂停、撤权、修改和新运行由服务端保存，本机镜像不授予执行权限。")).font(.footnote)
                ForEach(model.list("artifact").filter { r in
                    guard case .artifact(let artifact) = r.payload, case .run(let run) = model.record(artifact.generatedFromRunID)?.payload else { return false }
                    return run.delegationID == id
                }) { r in
                    if case .artifact(let artifact) = r.payload {
                        NavigationLink(value: AppRoute.document(artifact.documentReference.documentID, artifact.documentReference.version)) {
                            Panel { Text(artifact.title); Text(ui("阅读合成成果 v{0}", arguments: [String(artifact.documentReference.version)])) }
                        }.accessibilityIdentifier("gateway.artifact")
                    }
                }
                NavigationLink(ui("查看本地联调状态"), value: AppRoute.localGateway).touchTarget()
            }
        }.navigationTitle(ui("工作约定"))
    }
}

@MainActor struct GatewayConversationMirrorView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject var model: AppModel; let id: UUID
    var body: some View {
        Page {
            StatusLabel(text: ui("这一轮来自服务端合成运行；本机只读。"))
            ForEach(model.list("task").filter { $0.task?.conversationID == id }) { task in
                NavigationLink(task.title, value: AppRoute.task(task.id)).touchTarget()
                ForEach(task.task?.results ?? [], id: \.self) { reference in
                    NavigationLink(ui("阅读合成成果 v{0}", arguments: [String(reference.version)]), value: AppRoute.document(reference.documentID, reference.version)).touchTarget()
                }
            }
        }.navigationTitle(model.record(id)?.title ?? ui("任务"))
    }
}
