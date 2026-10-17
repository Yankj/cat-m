import SwiftUI

@MainActor struct BriefView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject var model: AppModel
    @State private var create = false
    @State private var approval: IdentifiedID?

    var body: some View {
        Page {
            if !needsConfirmation { introduction }

            if needsConfirmation {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: ui("需要你确认"))
                    Panel {
                        ForEach(pendingActions) { record in
                            if case .action(let action) = record.payload {
                                Button { approval = IdentifiedID(id: record.id) } label: {
                                    ActionRow(title: ui("预览并确认这一次操作"), detail: action.destination, symbol: "hand.raised")
                                }.buttonStyle(.plain)
                            }
                        }
                        ForEach(waitingTasks) { record in
                            NavigationLink(value: AppRoute.task(record.id)) {
                                ActionRow(title: record.title, detail: ui("等待本次确认"), symbol: "hand.raised")
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            if needsConfirmation { introduction }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: ui("最新成果"))
                if let latest = sortedArtifacts.first, case .artifact(let artifact) = latest.payload {
                    NavigationLink(value: AppRoute.document(artifact.documentReference.documentID, artifact.documentReference.version)) {
                        Panel {
                            HStack(alignment: .firstTextBaseline) {
                                Label(ui("成果已准备好"), systemImage: "doc.text").font(.caption.weight(.medium)).foregroundStyle(CatpawColors.secondary)
                                Spacer()
                                Text(model.snapshot.isViewed(scope: model.scope, reference: artifact.documentReference) ? ui("此版本已读") : ui("此版本未读"))
                                    .font(.caption.weight(.medium)).foregroundStyle(CatpawColors.ink)
                            }
                            Text(artifact.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            StatusLabel(text: ui("本地模拟成果 · v{0}", arguments: [String(artifact.documentReference.version)]), symbol: "info.circle")
                            Divider()
                            HStack { Text(model.isGatewayOwned(latest.id) ? ui("阅读合成成果 v{0}", arguments: [String(artifact.documentReference.version)]) : ui("阅读与修改")).font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: "arrow.right").accessibilityHidden(true) }.foregroundStyle(CatpawColors.ink).frame(minHeight: 32)
                        }
                    }.buttonStyle(.plain)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        CatpawSymbol(name: "doc.text").foregroundStyle(CatpawColors.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ui("还没有准备好的成果")).font(.subheadline.weight(.medium))
                            Text(ui("从一件事开始，准备好的内容会出现在这里。"))
                                .font(.subheadline).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 14)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: ui("继续在跟进"), detail: ui("{0} 项", arguments: [String(model.list("delegation").filter { $0.delegation?.state == .active }.count)]))
                if model.list("delegation").isEmpty {
                    Text(ui("你可以随时调整目标、暂停或结束跟进。"))
                        .font(.subheadline).foregroundStyle(CatpawColors.secondary).padding(.vertical, 12)
                }
                ForEach(model.list("delegation")) { record in
                    NavigationLink(value: AppRoute.delegation(record.id)) {
                        ActionRow(title: record.title, detail: record.delegation?.state.displayName(language: model.language), symbol: "arrow.triangle.branch")
                    }.buttonStyle(.plain).accessibilityIdentifier("assistant.delegation.\(record.id.uuidString)")
                    Divider()
                }
            }
            NavigationLink(value: AppRoute.memories) {
                ActionRow(title: ui("查看工作记忆"), symbol: "bookmark")
            }.buttonStyle(.plain)
            StatusLabel(text: ui("本地模拟 · 真实研究与后台执行未连接"), symbol: "info.circle")
        }
        .sheet(isPresented: $create) { DelegationForm(model: model).presentationDetents([.large]) }
        .sheet(item: $approval) { item in ActionPreviewSheet(model: model, id: item.id).presentationDetents([.large]) }
    }
    private var needsConfirmation: Bool { !pendingActions.isEmpty || !waitingTasks.isEmpty }
    private var introduction: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(ui("让重要的事，继续向前。")).font(.title2.weight(.semibold))
                    .foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
                Text(ui("聊一件事，或建立持续跟进的工作约定。"))
                    .font(.subheadline).foregroundStyle(CatpawColors.secondary)
                Button { create = true } label: {
                    HStack { Text(ui("建立持续委托")); Spacer(); CatpawSymbol(name: "plus") }
                }.primaryAction().accessibilityIdentifier("assistant.createDelegation")
                Button { model.newConversation() } label: {
                    Label(ui("先聊一件事"), systemImage: "bubble.left").frame(maxWidth: .infinity).touchTarget()
                }.font(.subheadline.weight(.medium))
            }
    }
    private var pendingActions: [StoredRecord] {
        model.list("action").filter { if case .action(let action) = $0.payload { return action.status == .pending }; return false }
    }
    private var waitingTasks: [StoredRecord] { model.list("task").filter { $0.task?.state == .waitingApproval } }
    private var sortedArtifacts: [StoredRecord] { model.list("artifact").sorted { a, b in
        guard case .artifact(let x) = a.payload, case .artifact(let y) = b.payload else { return a.header.updatedAt > b.header.updatedAt }
        let av = model.snapshot.isViewed(scope: model.scope, reference: x.documentReference), bv = model.snapshot.isViewed(scope: model.scope, reference: y.documentReference)
        return av != bv ? !av : a.header.updatedAt > b.header.updatedAt
    } }
}
@MainActor struct DelegationForm: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    let id: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""; @State private var stop = ""; @State private var saving = false
    @State private var requirements = ""; @State private var baseRevision: Int?
    init(model: AppModel, id: UUID? = nil) { self.model = model; self.id = id }
    var body: some View {
        NavigationStack { Form {
            Section(ui("持续约定")) { TextEditor(text: $goal).frame(minHeight: 160).accessibilityLabel(ui("工作目标")).accessibilityIdentifier("delegation.goal"); TextField(ui("本次要求"), text: $requirements, axis: .vertical); TextField(ui("停止条件"), text: $stop) }
            Section { Text(ui("普通进展留在 App 内。只在有成果或重要变化时提示。跨任务记忆默认关闭。")); Text(ui("当前持续执行来自本地模拟，App 关闭期间不会运行。")) }
        }.navigationTitle(id == nil ? ui("建立持续委托") : ui("编辑工作约定")).toolbar { ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button(ui("保存约定")) { model.perform { saving = true; defer { saving = false }; if let id, let baseRevision { try await model.service.editDelegation(scope: model.scope, id: id, expectedRevision: baseRevision, goal: goal, requirements: requirements, stop: stop) } else { let created = try await model.service.createDelegation(scope: model.scope, goal: goal, stop: stop, requirements: requirements); model.path.append(.delegation(created)) }; dismiss() } }.disabled(saving) } } }
        .task { if let id, let r = model.record(id), let d = r.delegation { goal = d.goal; requirements = DelegationRequirements.decode(d.scopeJSON).requirements; stop = d.stopConditions.joined(separator: "\n"); baseRevision = r.header.revision } else if id == nil, stop.isEmpty { stop = ui("本周结束或我主动结束时停止") } }
    }
}
@MainActor struct DelegationView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject var model: AppModel
    let id: UUID
    @State private var sourceURL = ""
    @State private var memory = ""
    @State private var destination = "me@example.invalid"
    @State private var actionID: UUID?
    @State private var sourceEdit: IdentifiedID?
    @State private var sourceText = ""
    @State private var editingAgreement = false

    var body: some View {
        Page {
            if let record = model.record(id), let delegation = record.delegation {
                VStack(alignment: .leading, spacing: 12) {
                    Text(delegation.title).font(.title2.weight(.semibold)).foregroundStyle(CatpawColors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusLabel(text: delegation.state.displayName(language: model.language), symbol: stateSymbol(delegation.state), tone: stateTone(delegation.state))
                    Text(ui("本地模拟 · 关闭 App 后不会继续运行"))
                        .font(.caption).foregroundStyle(CatpawColors.secondary)
                    if [.active, .paused].contains(delegation.state) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { controlButtons(record, delegation) }
                            VStack(alignment: .leading, spacing: 8) { controlButtons(record, delegation) }
                        }
                    }
                }

                if !actions.isEmpty { actionSection }
                if !runs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: ui("最近进展"))
                        ForEach(runs.prefix(3)) { record in
                            if case .run(let run) = record.payload {
                                NavigationLink(value: AppRoute.task(run.taskID)) {
                                    ActionRow(title: run.state.displayName(language: model.language), detail: ui("查看进度与恢复操作"), symbol: run.state == .failed ? "exclamationmark.circle" : "checklist")
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: ui("成果"))
                    if artifacts.isEmpty {
                        Text(ui("准备好后，你可以在这里阅读、修改和确认下一步。"))
                            .font(.subheadline).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(artifacts) { record in
                        if case .artifact(let artifact) = record.payload {
                            Panel {
                                NavigationLink(value: AppRoute.document(artifact.documentReference.documentID, artifact.documentReference.version)) {
                                    ActionRow(title: artifact.title, detail: ui("阅读与修改") + " · v\(artifact.documentReference.version)", symbol: "doc.text")
                                }.buttonStyle(.plain).accessibilityIdentifier("阅读与修改")
                                DisclosureGroup(ui("单次模拟操作")) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        TextField(ui("模拟目的地"), text: $destination).textFieldStyle(.roundedBorder)
                                        Button(ui("预览单次模拟外发")) { model.perform { actionID = try await model.service.prepareAction(scope: model.scope, document: artifact.documentReference, destination: destination) } }.touchTarget()
                                    }.padding(.top, 10)
                                }.font(.subheadline)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: ui("工作约定"))
                    Panel {
                        agreementField(ui("工作目标"), delegation.goal)
                        let requirements = DelegationRequirements.decode(delegation.scopeJSON).requirements
                        if !requirements.isEmpty { agreementField(ui("本次要求"), requirements) }
                        agreementField(ui("停止条件"), delegation.stopConditions.joined(separator: "\n"))
                        if [.active, .paused].contains(delegation.state) {
                            Divider()
                            Button { editingAgreement = true } label: {
                                Label(ui("编辑目标、要求与停止条件"), systemImage: "pencil").font(.subheadline.weight(.medium)).touchTarget()
                            }
                        }
                    }
                    if delegation.state == .active {
                        Button { model.perform { _ = try await model.service.runDelegation(scope: model.scope, id: id) } } label: {
                            HStack { Text(ui("模拟准备一轮")); Spacer(); CatpawSymbol(name: "arrow.right") }
                        }.primaryAction().accessibilityIdentifier("delegation.runFixture")
                    }
                }
                sourcesSection
                memorySection
            } else { EmptyState(title: ui("委托不可用"), detail: ui("当前环境没有该委托。")) }
        }.navigationTitle(ui("工作约定")).compactNavigationTitle()
        .sheet(item: Binding(get: { actionID.map { IdentifiedID(id: $0) } }, set: { actionID = $0?.id })) { item in ActionPreviewSheet(model: model, id: item.id).presentationDetents([.large]) }
        .sheet(item: $sourceEdit) { item in TextEntrySheet(title: ui("替换来源 · 保留现有权限"), text: $sourceText) { model.perform { try await model.service.replaceSource(scope: model.scope, id: item.id, url: sourceText); sourceEdit = nil } } }
        .sheet(isPresented: $editingAgreement) { DelegationForm(model: model, id: id) }
    }

    @ViewBuilder private func controlButtons(_ record: StoredRecord, _ delegation: Delegation) -> some View {
        if delegation.state == .active {
            Button { change(record, .paused) } label: { Label(ui("暂停"), systemImage: "pause").touchTarget() }.buttonStyle(.bordered)
        }
        if delegation.state == .paused {
            Button { change(record, .active) } label: { Label(ui("恢复"), systemImage: "play").touchTarget() }.buttonStyle(.bordered)
        }
        Button { change(record, .completed) } label: { Label(ui("结束委托"), systemImage: "stop").touchTarget() }
            .buttonStyle(.bordered).tint(CatpawColors.ink)
    }
    private func agreementField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(CatpawColors.secondary)
            Text(value).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private var sourcesSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.list("source").filter { $0.payload.parentID == id }) { record in
                    if case .source(let source) = record.payload {
                        Text(source.url).font(.subheadline).textSelection(.enabled)
                        Toggle(ui("允许用于后续模拟准备"), isOn: Binding(get: { source.allowed }, set: { allowed in model.perform { try await model.service.sourcePermission(scope: model.scope, id: record.id, allowed: allowed) } }))
                        Text(ui("来源版本 {0} · URL 尚未实际读取", arguments: [String(source.revision)])).font(.caption).foregroundStyle(CatpawColors.secondary)
                        Button(ui("替换来源")) { sourceText = source.url; sourceEdit = IdentifiedID(id: record.id) }.touchTarget()
                        Divider()
                    }
                }
                TextField(ui("http(s) 来源"), text: $sourceURL).textFieldStyle(.roundedBorder)
                Button(ui("添加来源配置")) { model.perform { try await model.service.addSource(scope: model.scope, delegationID: id, url: sourceURL); sourceURL = "" } }.touchTarget()
            }.padding(.top, 12)
        } label: { Label(ui("来源与分项权限"), systemImage: "link").font(.subheadline.weight(.medium)).touchTarget() }
    }
    private var memorySection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.list("memory").filter { if case .memory(let item) = $0.payload { return item.scopeID == id && item.status == .active }; return false }) { item in Text(item.title).padding(.vertical, 8) }
                TextField(ui("明确记住的要求"), text: $memory).textFieldStyle(.roundedBorder)
                Button(ui("仅为这件事记住")) { model.perform { _ = try await model.service.addMemory(scope: model.scope, content: memory, scopeID: id); memory = "" } }.touchTarget()
                NavigationLink(ui("编辑与删除记忆"), value: AppRoute.memories).touchTarget()
            }.padding(.top, 12)
        } label: { Label(ui("这件事的记忆"), systemImage: "bookmark").font(.subheadline.weight(.medium)).touchTarget() }
    }
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: ui("操作与确认"))
            ForEach(actions) { record in
                if case .action(let action) = record.payload {
                    Panel {
                        StatusLabel(text: action.status.displayName(language: model.language), symbol: action.status == .pending ? "hand.raised" : "checkmark.circle", tone: action.status == .pending ? .attention : .neutral)
                        Text(action.destination).font(.subheadline.weight(.medium))
                        StatusLabel(text: ui("{0} · 模拟", arguments: [action.receipt.displayName(language: model.language)]), symbol: "info.circle", tone: action.receipt == .unknown ? .attention : .neutral)
                        if action.status == .pending {
                            Button(ui("预览并确认这一次操作")) { actionID = record.id }.primaryAction()
                        }
                        if [.accepted, .unknown].contains(action.receipt) {
                            Button(ui("模拟核验原记录")) { model.perform { try await model.service.queryAction(scope: model.scope, id: record.id) } }.touchTarget()
                            Button(ui("模拟结果未知")) { model.perform { try await model.service.queryAction(scope: model.scope, id: record.id, unknown: true) } }.touchTarget()
                        }
                        DisclosureGroup(ui("操作记录")) {
                            Text(ui("单次模拟操作 · v{0}", arguments: [String(action.document.version)])).font(.caption)
                            Text(ui("历史：{0}", arguments: [action.history.map { $0.displayName(language: model.language) }.joined(separator: " → ")])).font(.caption)
                            Text(ui("核验 {0} 次", arguments: [String(action.queryCount)])).font(.caption)
                        }.font(.caption)
                    }
                }
            }
        }
    }
    private func stateSymbol(_ state: DelegationState) -> String {
        switch state { case .active: "clock"; case .paused: "pause.circle"; case .completed: "checkmark.circle"; case .cancelled: "xmark.circle"; case .draft: "pencil.circle"; case .expired: "clock.badge.exclamationmark" }
    }
    private func stateTone(_ state: DelegationState) -> CatpawTone {
        switch state { case .active: .active; case .paused, .expired: .attention; case .completed: .success; case .cancelled, .draft: .neutral }
    }
    private var runs: [StoredRecord] { model.list("run").filter { $0.payload.parentID == id }.sorted { $0.header.updatedAt > $1.header.updatedAt } }
    private var artifacts: [StoredRecord] { model.list("artifact").filter { if case .artifact(let artifact) = $0.payload, case .run(let run) = model.record(artifact.generatedFromRunID)?.payload { return run.delegationID == id }; return false } }
    private var actions: [StoredRecord] { let docs = Set(artifacts.compactMap { if case .artifact(let a) = $0.payload { return a.documentReference.documentID }; return nil }); return model.list("action").filter { if case .action(let a) = $0.payload { return docs.contains(a.document.documentID) }; return false } }
    private func change(_ record: StoredRecord, _ state: DelegationState) { model.perform { try await model.service.changeDelegation(scope: model.scope, id: record.id, state: state, expectedRevision: record.header.revision) } }
}
struct IdentifiedID: Identifiable { let id: UUID }
@MainActor struct ActionPreviewSheet: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    var body: some View {
        NavigationStack {
            Page {
                if let r = model.record(id), case .action(let a) = r.payload {
                    Text(ui("确认这一次模拟操作")).font(.title.bold()); Text(ui("目的地：{0}", arguments: [String(describing: (a.destination))])); Text(ui("版本 v{0} · 附件：无 · 仅此一次", arguments: [String(describing: (a.document.version))])).foregroundStyle(CatpawColors.secondary)
                    Text(ui("不会向外部应用发送内容。")).font(.footnote).foregroundStyle(CatpawColors.secondary)
                    Panel { Text(content).textSelection(.enabled) }
                    Text(ui("确认状态：{0}", arguments: [String(describing: (a.status.displayName(language: model.language)))])).font(.footnote)
                    Button(ui("确认模拟受理")) { model.perform { try await model.service.approveAction(scope: model.scope, id: id, expectedRevision: r.header.revision); dismiss() } }.primaryAction().disabled(a.status != .pending)
                }
            }.toolbar { Button(ui("取消")) { dismiss() } }
        }.task { if let r = model.record(id), case .action(let a) = r.payload { do { let (_, data) = try await model.service.readDocument(scope: model.scope, id: a.document.documentID, version: a.document.version); content = String(data: data, encoding: .utf8) ?? "" } catch { model.error = error.localizedDescription } } }
    }
}
@MainActor struct MemoriesView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    @State private var edit: IdentifiedID?; @State private var text = ""
    var body: some View {
        Page {
            Text(ui("记忆只来自你明确保存的要求，作用于对应委托。")).foregroundStyle(.secondary)
            let memories = model.list("memory").filter { if case .memory(let m) = $0.payload { return m.status == .active }; return false }
            if memories.isEmpty { EmptyState(title: ui("没有工作记忆"), detail: ui("跨任务记忆默认关闭。")) }
            ForEach(memories) { r in Panel { Text(r.title); Text(ui("用户明确要求 · revision {0}", arguments: [String(describing: (r.header.revision))])).font(.caption).foregroundStyle(.secondary); if model.isGatewayOwned(r.id) { Text(ui("服务端记忆 · 本机只读")).font(.caption).foregroundStyle(.secondary) } else { HStack { Button(ui("修改")) { text = r.title; edit = IdentifiedID(id: r.id) }; Button(ui("忘记"), role: .destructive) { model.perform { try await model.service.forgetMemory(scope: model.scope, id: r.id) } } } } } }
        }.navigationTitle(ui("工作记忆"))
        .sheet(item: $edit) { item in TextEntrySheet(title: ui("修改记忆"), text: $text) { if let r = model.record(item.id) { model.perform { try await model.service.editMemory(scope: model.scope, id: item.id, text: text, expectedRevision: r.header.revision); edit = nil } } } }
    }
}
@MainActor struct TextEntrySheet: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    let title: String; @Binding var text: String; let save: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { Form { TextEditor(text: $text).frame(minHeight: 180) }.navigationTitle(title).toolbar { ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button(ui("保存"), action: save) } } } }
}
