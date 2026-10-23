import SwiftUI
import UniformTypeIdentifiers

@MainActor struct ConversationView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel
    let id: UUID
    @State private var scenario = FixtureScenario.success
    @State private var rename = false
    @State private var name = ""
    @State private var deleteConfirm = false
    @State private var importer = false
    @State private var voice = false
    @State private var contextSheet = false
    @State private var approval: IdentifiedID?
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    @State private var mediaPicker = false; @State private var useCamera = false
    #endif
    var body: some View {
        Group {
            if let r = model.record(id), let c = r.conversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            StatusLabel(text: model.usesLocalGateway(id) ? ui("本机合成 Gateway · 非真实模型") : ui("模拟回复 · 未连接真实模型"), symbol: "info.circle")
                                .padding(.top, 4)
                            if messages.isEmpty {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text(ui("想一起完成什么？")).font(.title2.weight(.semibold)).foregroundStyle(CatpawColors.ink)
                                    Text(ui("从一个问题、一份资料，或一个想法开始。"))
                                        .font(.body).foregroundStyle(CatpawColors.secondary)
                                    VStack(spacing: 0) {
                                        ForEach(suggestions, id: \.title) { suggestion in
                                            Button { model.editDraft(id, text: suggestion.title + "："); composerFocused = true } label: {
                                                ActionRow(title: suggestion.title, symbol: suggestion.symbol)
                                            }.buttonStyle(.plain)
                                            if suggestion.title != suggestions.last?.title { Divider() }
                                        }
                                    }
                                }.padding(.vertical, 28)
                            }
                            ForEach(messages) { message in messageRow(message) }
                            if !pendingActions.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionHeading(title: ui("需要你确认"))
                                    ForEach(pendingActions) { record in
                                        if case .action(let action) = record.payload {
                                            Button { approval = IdentifiedID(id: record.id) } label: {
                                                ActionRow(title: ui("预览并确认这一次操作"), detail: action.destination, symbol: "hand.raised")
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            ForEach(tasks) { task in
                                if let work = task.task {
                                    VStack(alignment: .leading, spacing: 8) {
                                        NavigationLink(value: AppRoute.task(task.id)) {
                                            ActionRow(title: ui("进度 · {0}", arguments: [work.state.displayName(language: model.language)]), symbol: work.state == .waitingApproval ? "hand.raised" : "checklist")
                                        }.buttonStyle(.plain)
                                        if !model.isGatewayOwned(task.id), [.queued, .running, .preparing].contains(work.state) {
                                            Button(ui("取消模拟运行")) { model.perform { try await model.cancelOperation(work.operationID) } }.font(.subheadline).touchTarget()
                                        }
                                        if !model.isGatewayOwned(task.id), work.state == .failed || work.state == .cancelled {
                                            Button(ui("按原请求快照重试模拟运行")) { model.perform { try await model.retryTask(task.id) } }.font(.subheadline.weight(.medium)).touchTarget()
                                        }
                                    }
                                }
                            }
                            ForEach(model.list("document").filter { $0.document?.ownerIDs.contains(id) == true }) { document in
                                NavigationLink(value: AppRoute.document(document.id, document.document!.currentVersion)) {
                                    ActionRow(title: document.title, detail: "v\(document.document!.currentVersion)", symbol: "doc.text")
                                }.buttonStyle(.plain).accessibilityIdentifier("conversation.document")
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(.horizontal, CatpawLayout.pageInset).padding(.vertical, 16)
                            .frame(maxWidth: CatpawLayout.readableWidth).frame(maxWidth: .infinity)
                    }.scrollDismissesKeyboard(.interactively)
                        .onChange(of: messages.last?.header.revision) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                        .onChange(of: messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                        .safeAreaInset(edge: .bottom, spacing: 0) { composer(c) }
                }.background(CatpawColors.background)
                .navigationTitle(r.title)
                .compactNavigationTitle()
                .toolbar { ToolbarItem {
                    Menu {
                        #if DEBUG
                        if !model.usesLocalGateway(id) { Menu(ui("调试：模拟回复场景")) { ForEach(FixtureScenario.allCases, id: \.self) { item in Button(scenarioTitle(item)) { scenario = item }.accessibilityIdentifier("conversation.scenario.\(item.rawValue)") } }.accessibilityIdentifier("conversation.scenarios") }
                        #endif
                        Button(model.preference("pin:\(id)", fallback: "false") == "true" ? ui("取消置顶") : ui("置顶")) { model.setPreference("pin:\(id)", model.preference("pin:\(id)", fallback: "false") == "true" ? "false" : "true") }
                        Button(ui("重命名")) { name = r.title; rename = true }
                        if let project = c.projectID { Button(ui("项目文件")) { model.path.append(.project(project)) } }
                        ShareLink(item: ui("cat 本地会话 {0}\n", arguments: [String(describing: (id))]) + messages.compactMap { $0.message?.blocks.textValue }.joined(separator: "\n\n")) { Text(ui("分享本地文本")) }
                        Button(ui("复制会话 ID")) { copyText(id.uuidString) }
                        Button(ui("删除"), role: .destructive) { deleteConfirm = true }
                    } label: { CatpawSymbol(name: "ellipsis").foregroundStyle(CatpawColors.ink).touchTarget() }.accessibilityLabel(ui("更多操作")).accessibilityIdentifier("conversation.more")
                } }
                .alert(ui("重命名"), isPresented: $rename) { TextField(ui("名称"), text: $name); Button(ui("保存")) { model.perform { try await model.service.rename(scope: model.scope, id: id, name: name, expectedRevision: r.header.revision) } }; Button(ui("取消"), role: .cancel) { } }
                .confirmationDialog(ui("移到本地回收站？消息和 ID 可恢复。"), isPresented: $deleteConfirm) { Button(ui("删除会话"), role: .destructive) { model.delete(r); _ = model.path.popLast() } }
                .fileImporter(isPresented: $importer, allowedContentTypes: [.plainText, .commaSeparatedText, .pdf, .image], allowsMultipleSelection: false) { result in
                    model.perform {
                        guard let url = try result.get().first else { return }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 20 * 1024 * 1024 else { throw CatpawError.invalid(ui("文件超过本地导入上限 20 MB。")) }
                        let mime = mimeForExtension(url.pathExtension)
                        let reference = try await model.service.createDocument(scope: model.scope, title: url.lastPathComponent, mime: mime, data: Data(contentsOf: url), owners: [id] + [c.projectID].compactMap { $0 }, source: "user_import")
                        model.path.append(.document(reference.documentID, reference.version))
                    }
                }
                .sheet(item: $approval) { item in ActionPreviewSheet(model: model, id: item.id).presentationDetents([.large]) }
                .sheet(isPresented: $contextSheet) { ConversationContextSheet(model: model, id: id).presentationDetents([.medium, .large]) }
                .sheet(isPresented: $voice) { VoiceInputSheet { text in model.editDraft(id, text: text) }.presentationDetents([.large]) }
                #if os(iOS)
                .sheet(isPresented: $mediaPicker) { NativeMediaPicker(camera: useCamera) { bytes in mediaPicker = false; if let bytes { model.perform { let ref = try await model.service.createDocument(scope: model.scope, title: ui("选定图片-{0}.jpg", arguments: [String(describing: (UUID().uuidString.prefix(8)))]), mime: "image/jpeg", data: bytes, owners: [id] + [c.projectID].compactMap { $0 }, source: "user_selected_image"); model.path.append(.document(ref.documentID, ref.version)) } } } }
                #endif
            } else { EmptyState(title: ui("会话不可用"), detail: ui("内容已删除或不属于当前环境。")) }
        }
    }
    private var messages: [StoredRecord] { model.list("message").filter { $0.message?.conversationID == id }.sorted { $0.message!.sequence < $1.message!.sequence } }
    private var tasks: [StoredRecord] { model.list("task").filter { $0.task?.conversationID == id } }
    private func scenarioTitle(_ scenario: FixtureScenario) -> String {
        switch scenario {
        case .success: return ui("成功完成")
        case .failure: return ui("明确失败")
        case .unexpectedEOF: return ui("缺少完成事件")
        case .cancelled: return ui("已取消")
        case .unknown: return ui("结果未知")
        }
    }
    private var suggestions: [(title: String, symbol: String)] {
        [(ui("写文章"), "square.and.pencil"), (ui("看资讯"), "globe"), (ui("做总结"), "text.alignleft"), (ui("翻译"), "character.bubble")]
    }
    private var pendingActions: [StoredRecord] {
        model.list("action").filter { record in
            guard case .action(let action) = record.payload, action.status == .pending else { return false }
            return model.record(action.document.documentID)?.document?.ownerIDs.contains(id) == true
        }
    }
    private func composer(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(ui("想问什么？"), text: Binding(get: { model.drafts[id] ?? conversation.draftText }, set: { model.editDraft(id, text: $0) }), prompt: Text(ui("想问什么？")).foregroundColor(CatpawColors.secondary), axis: .vertical)
                    .font(.body).foregroundStyle(CatpawColors.ink).lineLimit(1...6)
                    .focused($composerFocused).padding(.horizontal, 8).padding(.top, 6)
                    .accessibilityIdentifier("conversation.input")
                HStack(spacing: 4) {
                    Menu {
                        #if os(iOS)
                        Button { if UIImagePickerController.isSourceTypeAvailable(.camera) { useCamera = true; mediaPicker = true } else { model.error = ui("当前设备没有可用相机。可从文件导入图片。") } } label: { Label(ui("拍照 · 主动开启系统相机"), systemImage: "camera") }
                        Button { useCamera = false; mediaPicker = true } label: { Label(ui("从相册选择一张图片"), systemImage: "photo") }
                        #endif
                        Button { importer = true } label: { Label(ui("导入文件"), systemImage: "doc") }
                        Button { contextSheet = true } label: { Label(ui("专家、技能与项目"), systemImage: "slider.horizontal.3") }
                        Button { model.path.append(.commands) } label: { Label(ui("自定义命令"), systemImage: "terminal") }
                    } label: { CatpawSymbol(name: "plus").foregroundStyle(CatpawColors.ink).touchTarget() }
                        .accessibilityLabel(ui("添加内容"))
                    Button(ui("配置")) { contextSheet = true }.font(.caption.weight(.medium)).touchTarget()
                    Spacer(minLength: 4)
                    Button { voice = true } label: { CatpawSymbol(name: "waveform").foregroundStyle(CatpawColors.ink).touchTarget() }.accessibilityLabel(ui("口述输入"))
                    Button { composerFocused = false; model.send(id, scenario: scenario) } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold))
                            .foregroundStyle(canSend(conversation) ? CatpawColors.onInk : CatpawColors.secondary)
                            .frame(minWidth: 36, minHeight: 36).background(canSend(conversation) ? CatpawColors.ink : CatpawColors.input, in: Circle()).touchTarget()
                    }.buttonStyle(.plain).disabled(!canSend(conversation))
                        .accessibilityLabel(ui("发送并运行模拟回复")).accessibilityIdentifier("conversation.send")
                }
            }.padding(10)
                .background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(CatpawColors.separator, lineWidth: 1) }
            Text(model.usesLocalGateway(id) ? ui("Gateway · 本地合成") : ui("模拟回复 · 本机保存"))
                .font(.caption2).foregroundStyle(CatpawColors.secondary).padding(.top, 8)
        }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .frame(maxWidth: CatpawLayout.readableWidth).frame(maxWidth: .infinity)
            .background(CatpawColors.background)
    }
    private func canSend(_ conversation: Conversation) -> Bool {
        !model.sending.contains(id) && !(model.drafts[id] ?? conversation.draftText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @ViewBuilder private func messageRow(_ record: StoredRecord) -> some View {
        if let message = record.message {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 36)
                    Text(message.blocks.textValue).font(.body).lineSpacing(4).textSelection(.enabled)
                        .foregroundStyle(CatpawColors.ink).padding(.horizontal, 16).padding(.vertical, 12)
                        .background(CatpawColors.input, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }.accessibilityElement(children: .combine).accessibilityLabel(ui("你") + ": " + message.blocks.textValue)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.usesLocalGateway(id) ? ui("Gateway · 本地合成") : ui("助理 · 模拟回复"))
                        .font(.caption.weight(.medium)).foregroundStyle(CatpawColors.secondary)
                    Text(message.blocks.textValue.isEmpty ? ui("正在等待模拟回复…") : message.blocks.textValue)
                        .textSelection(.enabled).font(.body).lineSpacing(6).foregroundStyle(CatpawColors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if message.state != .completed {
                        StatusLabel(text: message.state.displayName(language: model.language), symbol: message.state == .failed ? "exclamationmark.circle" : "clock", tone: message.state == .failed ? .failure : .neutral)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

}
@MainActor struct ConversationContextSheet: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }

    @ObservedObject var model: AppModel; let id: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { Form {
            if let r = model.record(id), let c = r.conversation {
                Section(ui("当前会话上下文")) {
                    Text(ui("环境已固定，后续切换侧栏不会改变这件任务。"))
                    Picker(ui("项目"), selection: Binding(get: { c.projectID }, set: { project in model.perform { try await model.changeProject(from: id, to: project); dismiss() } })) { Text(ui("无项目")).tag(UUID?.none); ForEach(model.projects) { Text(model.projectTitle($0)).tag(Optional($0.id)) } }
                    Text(ui("切换项目会打开该项目的独立会话，原会话的历史与草稿保留。")).font(.footnote).foregroundStyle(.secondary)
                    Picker(ui("专家"), selection: Binding(get: { c.expertID }, set: { update(c, project: c.projectID, expert: $0, skills: c.skillIDs, revision: r.header.revision) })) { Text(ui("无专家")).tag(UUID?.none); ForEach(model.list("expert")) { Text($0.title).tag(Optional($0.id)) } }
                    ForEach(model.list("skill")) { skill in Toggle(skill.title, isOn: Binding(get: { c.skillIDs.contains(skill.id) }, set: { enabled in var ids = c.skillIDs.filter { $0 != skill.id }; if enabled { ids.append(skill.id) }; update(c, project: c.projectID, expert: c.expertID, skills: ids, revision: r.header.revision) })) }
                    Text(ui("选择是本地配置；不会授予工具权限或下载技能。")).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(ui("会话配置")).toolbar { Button(ui("完成")) { dismiss() } } }
    }
    private func update(_ c: Conversation, project: UUID?, expert: UUID?, skills: [UUID], revision: Int) { model.perform { try await model.service.configureConversation(scope: model.scope, id: id, project: project, expert: expert, skills: skills, expectedRevision: revision) } }
}
func copyText(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    #endif
}
func mimeForExtension(_ ext: String) -> String { switch ext.lowercased() { case "pdf": return "application/pdf"; case "csv": return "text/csv"; case "md": return "text/markdown"; case "png": return "image/png"; case "jpg", "jpeg": return "image/jpeg"; case "heic": return "image/heic"; case "txt", "json": return "text/plain"; default: return "application/octet-stream" } }
