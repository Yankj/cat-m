import SwiftUI

enum ConversationInboxReturnResult {case returned,unavailable(String)}

/// Scoped receipt browsing. Reading another conversation's work never selects
/// that conversation or changes its drafts; only onReturn owns that transition.
@MainActor struct ConversationInboxView: View {
    enum Mode: Hashable { case tasks, results }
    private let service: ConversationInboxService
    private let mode: Mode
    private let admissionAllowed: () -> Bool
    private let onReturn: (ConversationInboxItem) async -> ConversationInboxReturnResult
    @StateObject private var model: ConversationInboxPresentationModel
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scene
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: locale).ui(key, arguments: arguments) }
    private var allowed: Bool { scene == .active && admissionAllowed() }
    private var lifecycle: InboxReadLifecycle { .init(service: ObjectIdentifier(service), allowed: allowed) }

    init(service: ConversationInboxService, mode: Mode, admissionAllowed: @escaping () -> Bool,
         onReturn: @escaping (ConversationInboxItem) async -> ConversationInboxReturnResult) {
        self.service = service; self.mode = mode; self.admissionAllowed = admissionAllowed; self.onReturn = onReturn
        _model = StateObject(wrappedValue: ConversationInboxPresentationModel(service: service))
    }
    var body: some View {
        List {
            if allowed && model.matches(service: service, item: nil) {
                Text(mode == .tasks ? ui("当前工作区的待办") : ui("当前工作区的记录"))
                    .font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                    .listRowBackground(Color.clear)
                if model.loading && model.items.isEmpty { ProgressView(mode == .tasks ? ui("正在读取任务") : ui("正在读取成果")) }
                if let error = model.errorText {
                    Section {
                        Text(model.denied ? ui("当前账号无权访问这些工作。") : ui("无法读取工作列表")).font(catTypography.Role.heading.font)
                        Text(ui(error)).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(ui("重新读取")) { model.reload() }.touchTarget().disabled(model.loading)
                            .accessibilityIdentifier("inbox.retry")
                    }.accessibilityIdentifier("inbox.error")
                }
                if !model.isFresh && !model.items.isEmpty {
                    Text(ui("显示上次读取的内容；本次尚未完成更新。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
                        .accessibilityIdentifier("inbox.stale")
                }
                if mode == .tasks { ProactiveTodoSection() }   // v1.2 IA: 「待办」 = cat-found cards on top + what you asked for
                if mode == .tasks { DeviceLedgerSection() }
                if mode == .tasks {
                    ForEach(model.items) { item in
                        NavigationLink {
                            ConversationInboxDetailView(service: service, item: item, admissionAllowed: admissionAllowed, onReturn: onReturn)
                        } label: { VStack(alignment: .leading, spacing: 4) { TodoSourceTag(cat: false); receiptRow(item, artifact: nil) } }
                        .accessibilityIdentifier("inbox.item." + item.id.uuidString.lowercased())
                    }
                } else {
                    ForEach(resultRows) { row in
                        NavigationLink {
                            ConversationInboxDetailView(service: service, item: row.item, artifact: row.identity,
                                                        admissionAllowed: admissionAllowed, onReturn: onReturn)
                        } label: { receiptRow(row.item, artifact: row.identity) }
                        .accessibilityIdentifier("inbox.artifact." + row.identity.id)
                        // v1.2: one-tap jump back to the conversation that produced this result.
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { Task { _ = await onReturn(row.item) } } label: { Label(ui("回到原对话"), systemImage: "arrow.uturn.backward") }
                                .tint(catColors.ink).accessibilityIdentifier("inbox.artifact.return")
                        }
                    }
                }
                if model.didLoad && !model.loading && model.errorText == nil && visibleCount == 0 && (mode != .tasks || DeviceLedger.shared.active.isEmpty) {
                    if mode == .results && model.hasMore {
                        Text(ui("当前已读取的工作还没有成果，可以加载更多。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                    } else {
                        // v1.2: empty states say how this page fills up.
                        EmptyState(title: mode == .tasks ? ui("还没有待办") : ui("还没有记录"),
                                   detail: mode == .tasks ? ui("在对话里说「提醒我明天 9 点开会」或「帮我整理一份周报」，要办的事会出现在这里。") : ui("办完的事会记在这里：报告、回执和摘要，点开可以回到原对话。"))
                            .listRowBackground(Color.clear).accessibilityIdentifier("inbox.empty")
                    }
                }
                if model.hasMore {
                    Button { model.reload(more: true) } label: {
                        HStack { Text(ui("加载更多")); if model.loading && !model.items.isEmpty { ProgressView() } }
                            .frame(minHeight: 44)
                    }.disabled(model.loading).accessibilityIdentifier("inbox.loadMore")
                }
            } else {
                EmptyState(title: mode == .tasks ? ui("待办") : ui("记录"), detail: ui("允许网络后可读取当前工作区的任务与成果。"))
                    .listRowBackground(Color.clear).accessibilityIdentifier("inbox.unavailable")
            }
        }.font(catTypography.Role.body.font).scrollContentBackground(.hidden).background(catColors.background)
            .navigationTitle(mode == .tasks ? ui("待办") : ui("记录")).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("inbox.list")
            .refreshable { if let request = model.reload() { await request.value } }
            .task(id: lifecycle) { model.activate(service: service, item: nil, allowed: allowed) }
            .onDisappear { model.stop(clear: false) }
    }
    private var resultRows: [InboxResultRow] {
        model.items.flatMap { item in item.artifacts.map { InboxResultRow(item: item, identity: .init(artifactID: $0.artifactID, version: $0.version, contentHash: $0.contentHash)) } }
    }
    private var visibleCount: Int { mode == .tasks ? model.items.count : resultRows.count }
    private func receiptRow(_ item: ConversationInboxItem, artifact: ConversationArtifactIdentity?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let artifact {
                catAdaptiveHeader(title: item.title, detail: "v\(artifact.version)", titleRole: .body, weight: .medium)
            } else { Text(item.title).font(catTypography.Role.body.font.weight(.medium)).fixedSize(horizontal: false, vertical: true) }
            StatusLabel(text: inboxStatus(item.taskStatus,locale:locale), symbol: "circle.dotted", tone: inboxTone(item.taskStatus))
            Text(ui("原对话") + " · " + inboxOrigin(item)).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
            if item.pendingActionCount > 0 { Text(ui("待处理 {0} 项", arguments: [String(item.pendingActionCount)])).font(catTypography.Role.secondary.font).foregroundStyle(catColors.attention) }
            if item.authorizationState == .superseded {
                Text(ui("原工作授权已失效，查阅不代表可以继续执行。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention)
            }
            Text(inboxDate(item.updatedAt)).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
        }.padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).accessibilityElement(children: .combine)
    }
}

@MainActor private struct ConversationInboxDetailView: View {
    let service: ConversationInboxService
    let item: ConversationInboxItem
    var artifact: ConversationArtifactIdentity? = nil
    let admissionAllowed: () -> Bool
    let onReturn: (ConversationInboxItem) async -> ConversationInboxReturnResult
    @StateObject private var model: ConversationInboxPresentationModel
    @State private var selectedArtifact: ConversationArtifactIdentity?
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scene
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var allowed: Bool { scene == .active && admissionAllowed() }
    private var lifecycle: InboxReadLifecycle { .init(service: ObjectIdentifier(service), allowed: allowed) }
    init(service: ConversationInboxService, item: ConversationInboxItem, artifact: ConversationArtifactIdentity? = nil,
         admissionAllowed: @escaping () -> Bool, onReturn: @escaping (ConversationInboxItem) async -> ConversationInboxReturnResult) {
        self.service = service; self.item = item; self.artifact = artifact; self.admissionAllowed = admissionAllowed; self.onReturn = onReturn
        _model = StateObject(wrappedValue: ConversationInboxPresentationModel(service: service))
    }
    var body: some View {
        detailContent
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button(ui("重新读取")) { model.reload() }.disabled(!allowed || model.loading)
                    .accessibilityIdentifier("inbox.detail.refresh")
            } }
            .navigationTitle(artifact == nil ? ui("任务进展") : ui("记录")).navigationBarTitleDisplayMode(.inline)
            .background(catColors.background).accessibilityIdentifier("inbox.detail." + item.id.uuidString.lowercased())
            .safeAreaInset(edge: .bottom) { if allowed && model.matches(service: service, item: item) && model.goal != nil && !model.denied {
                ConversationInboxReturnAction(item: item, allowed: allowed, onReturn: onReturn)
            } }
            .navigationDestination(item: $selectedArtifact) { identity in
                ConversationInboxArtifactDestination(service: service, item: item, identity: identity, model: model,
                                                     admissionAllowed: admissionAllowed, onReturn: onReturn)
            }
            .task(id: lifecycle) { model.activate(service: service, item: item, allowed: allowed) }
            .onDisappear { model.stop(clear: false) }
    }
    private var artifactReadStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ui("原对话") + " · " + inboxOrigin(item)).font(catTypography.Role.secondary.font)
            if let error = model.errorText { Text(ui(error)).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention) }
            else if !model.isFresh { Text(ui("显示上次读取的内容；本次尚未完成更新。")).font(catTypography.Role.caption.font) }
        }.foregroundStyle(catColors.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).background(catColors.background)
    }
    @ViewBuilder private var detailContent: some View {
        if allowed && model.matches(service: service, item: item), let goal = model.goal, let artifact {
            ConversationArtifactReaderView(goal: goal, selectedArtifact: artifact)
                .safeAreaInset(edge: .top) { artifactReadStatus }
                .overlay(alignment: .top) { if model.loading { ProgressView().padding(8).background(.regularMaterial, in: Capsule()) } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !allowed { Text(ui("允许网络后可读取当前工作区的任务与成果。")) }
                    else if model.matches(service: service, item: item) {
                        Text(ui("原对话") + " · " + inboxOrigin(item)).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                        if model.loading { ProgressView(artifact == nil ? ui("正在读取任务") : ui("正在读取成果")) }
                        if let error = model.errorText {
                            Text(model.denied ? ui("当前账号无权访问这些工作。") : ui("无法读取这项工作")).font(catTypography.Role.heading.font)
                            Text(ui(error)).font(catTypography.Role.secondary.font).foregroundStyle(catColors.attention).fixedSize(horizontal: false, vertical: true)
                        }
                        if let goal = model.goal {
                            if !model.isFresh { Text(ui("显示上次读取的内容；本次尚未完成更新。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary) }
                            if item.authorizationState == .superseded { Text(ui("原工作授权已失效，查阅不代表可以继续执行。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.attention) }
                            ConversationGoalCard(goal: goal, busy: model.loading, refresh: { model.reload() },
                                                 openArtifact: { selectedArtifact = ConversationArtifactIdentity($0) })
                            if let plan = goal.planReference { Text(ui("计划版本") + " · v\(plan.revision)").font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary) }
                            Text(ui("请返回原对话继续修改或管理这项工作。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                        }
                        if !model.loading { Button(ui("重新读取")) { model.reload() }.touchTarget().accessibilityIdentifier("inbox.detail.retry") }
                    }
                }.font(catTypography.Role.body.font).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Reuses the already verified immutable artifact from the task read. The shared
/// presentation model clears on background/lost admission, including this child.
@MainActor private struct ConversationInboxArtifactDestination: View {
    let service: ConversationInboxService
    let item: ConversationInboxItem
    let identity: ConversationArtifactIdentity
    @ObservedObject var model: ConversationInboxPresentationModel
    let admissionAllowed: () -> Bool
    let onReturn: (ConversationInboxItem) async -> ConversationInboxReturnResult
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scene
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var allowed: Bool { scene == .active && admissionAllowed() }
    var body: some View {
        Group {
            if allowed && model.matches(service: service, item: item), let goal = model.goal {
                ConversationArtifactReaderView(goal: goal, selectedArtifact: identity)
            } else {
                VStack(spacing: 16) {
                    if model.loading { ProgressView(ui("正在读取成果")) }
                    else { Text(model.errorText.map { ui($0) } ?? ui("成果暂不可读")); Button(ui("重新读取")) { model.reload() }.touchTarget().disabled(!allowed) }
                }.font(catTypography.Role.body.font).padding(20)
            }
        }.background(catColors.background)
            .safeAreaInset(edge: .bottom) { if allowed && model.goal != nil && !model.denied { ConversationInboxReturnAction(item: item, allowed: allowed, onReturn: onReturn) } }
            .task(id: InboxReadLifecycle(service: ObjectIdentifier(service), allowed: allowed)) {
                model.activate(service: service, item: item, allowed: allowed, refreshIfLoaded: false)
            }
            .onDisappear { model.stop(clear: false) }
    }
}

@MainActor private struct ConversationInboxReturnAction: View {
    let item: ConversationInboxItem
    let allowed: Bool
    let onReturn: (ConversationInboxItem) async -> ConversationInboxReturnResult
    @Environment(\.locale) private var locale
    @State private var returning = false
    @State private var failure: String?
    @State private var request: Task<Void, Never>?
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        VStack(spacing: 8) {
            if let failure { Text(ui(failure)).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention).fixedSize(horizontal: false, vertical: true) }
            Button {
                guard allowed, !returning else { return }
                returning = true; failure = nil
                request = Task {
                    let completed = await onReturn(item)
                    guard !Task.isCancelled else { return }
                    returning = false; request = nil
                    switch completed {case .returned:failure=nil;case .unavailable(let message):failure=message}
                }
            } label: {
                HStack { if returning { ProgressView().tint(catColors.ink) }; Text(returning ? ui("正在返回原对话…") : ui("回到原对话")) }
                    .font(catTypography.Role.body.font.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(catPressButtonStyle())
                .foregroundStyle(!allowed || returning ? catColors.secondary : catColors.ink)
                .background(catColors.panel,in:RoundedRectangle(cornerRadius:catLayout.controlRadius,style:.continuous))
                .disabled(!allowed || returning).accessibilityIdentifier("inbox.return")
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.regularMaterial)
            .onChange(of: allowed) { _, value in if !value { cancel() } }
            .onDisappear { cancel() }
    }
    private func cancel() { request?.cancel(); request = nil; returning = false; failure = nil }
}

private struct InboxReadLifecycle: Hashable { let service: ObjectIdentifier; let allowed: Bool }
private struct InboxResultRow: Identifiable {
    let item: ConversationInboxItem
    let identity: ConversationArtifactIdentity
    var id: String { item.id.uuidString + ":" + identity.id }
}
private func inboxOrigin(_ item: ConversationInboxItem) -> String { String(item.binding.conversation_id.uuidString.lowercased().prefix(8)) }
private func inboxDate(_ value: String) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
}
private func inboxStatus(_ value: ConversationInboxTaskStatus,locale:Locale) -> String {
    func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    switch value {
    case .queued, .scheduled: return ui("已排队")
    case .running: return ui("正在进行")
    case .succeeded: return ui("已完成")
    case .failed: return ui("需要处理")
    case .outcomeUnknown: return ui("状态待确认")
    case .waitingInput: return ui("等待反馈")
    case .waitingApproval: return ui("等待审批")
    case .paused: return ui("已暂停")
    case .cancelled: return ui("已取消")
    case .interrupted: return ui("工作已中断")
    }
}
private func inboxTone(_ value: ConversationInboxTaskStatus) -> catTone {
    switch value {
    case .failed, .outcomeUnknown, .waitingInput, .waitingApproval, .interrupted: return .attention
    case .succeeded: return .success
    case .running: return .active
    default: return .neutral
    }
}

/// A presentation request generation supplements the service's account fence.
/// Scene/network loss cancels UI tasks and clears private projections. No view
/// may reopen the service's admission, decode HTTP or manufacture a conversation.
@MainActor private final class ConversationInboxPresentationModel: ObservableObject {
    @Published private(set) var items: [ConversationInboxItem] = []
    @Published private(set) var hasMore = false
    @Published private(set) var goal: ConversationGoalProjection?
    @Published private(set) var loading = false
    @Published private(set) var didLoad = false
    @Published private(set) var isFresh = false
    @Published private(set) var denied = false
    @Published private(set) var errorText: String?
    private var service: ConversationInboxService
    private var item: ConversationInboxItem?
    private var admitted = false
    private var generation = UUID()
    private var request: Task<Void, Never>?
    init(service: ConversationInboxService) { self.service = service }
    func matches(service: ConversationInboxService, item: ConversationInboxItem?) -> Bool { self.service === service && self.item == item }
    func activate(service: ConversationInboxService, item: ConversationInboxItem?, allowed: Bool, refreshIfLoaded: Bool = true) {
        if !matches(service: service, item: item) { stop(clear: true); self.service = service; self.item = item }
        admitted = allowed
        guard allowed else { stop(clear: true); return }
        if refreshIfLoaded || !didLoad { reload() }
    }
    @discardableResult func reload(more: Bool = false) -> Task<Void, Never>? {
        guard admitted, !loading, !more || hasMore else { return nil }
        request?.cancel(); let token = UUID(); generation = token
        let source = service, selected = item
        loading = true; errorText = nil; denied = false; isFresh = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.loading = false; self.request = nil } }
            do {
                if let selected {
                    let resolved = try await source.resolve(item: selected)
                    guard self.mayApply(token, source: source) else { return }
                    self.goal = resolved; self.isFresh = true; self.didLoad = true
                } else {
                    let value: ConversationInboxSnapshot
                    if more { value = try await source.loadMore() } else { value = try await source.refresh() }
                    guard self.mayApply(token, source: source) else { return }
                    self.items = value.items; self.hasMore = value.nextCursor != nil; self.isFresh = value.isFresh; self.didLoad = true
                }
            } catch is CancellationError { }
            catch {
                guard self.mayApply(token, source: source) else { return }
                if let error = error as? ConversationInboxError, error == .accessDenied || error == .closed {
                    self.items = []; self.goal = nil; self.hasMore = false; self.denied = true
                } else if selected == nil {
                    let saved = await source.snapshot()
                    guard self.mayApply(token, source: source) else { return }
                    self.items = saved.items; self.hasMore = saved.nextCursor != nil
                }
                self.errorText = error.localizedDescription; self.isFresh = false; self.didLoad = true
            }
        }
        request = task; return task
    }
    func stop(clear: Bool) {
        generation = UUID(); request?.cancel(); request = nil; admitted = false; loading = false
        if clear { items = []; goal = nil; hasMore = false; didLoad = false; isFresh = false; errorText = nil; denied = false }
    }
    private func mayApply(_ token: UUID, source: ConversationInboxService) -> Bool {
        admitted && generation == token && service === source && !Task.isCancelled
    }
}

/// v1.2 IA: the cat-found (proactive) part of 「待办」. Pending suggestions on top, each tagged 「cat 发现」.
@MainActor struct ProactiveTodoSection: View {
    @ObservedObject private var store = ProactiveSuggestionStore.shared
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        let rows = store.sorted(.pending).sorted { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
        Group {
            if let notice = ProactiveRules.suppressionNotice(now: Date(), deliveredToday: ProactiveEngine.shared.quota.count(on: Date())) {
                Label(ui(notice), systemImage: "moon.zzz").font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                    .listRowBackground(Color.clear).accessibilityIdentifier("proactive.inbox.suppressed")
            }
            ForEach(rows) { s in
                VStack(alignment: .leading, spacing: 6) { TodoSourceTag(cat: true); ProactiveSuggestionCard(suggestion: s) }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .task { await store.load() }
        .accessibilityIdentifier("todo.proactive")
    }
}
/// Small source tag on a 「待办」 row: 「cat 发现」 (proactive) vs 「你交代的」 (asked in chat).
struct TodoSourceTag: View {
    let cat: Bool
    @Environment(\.locale) private var locale
    var body: some View {
        Text(cat ? AppLanguage(locale: locale).ui("小咪发现") : AppLanguage(locale: locale).ui("你交代的"))
            .font(catTypography.Role.caption.font.weight(.semibold))
            .foregroundStyle(cat ? catBrand.paw : catColors.secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((cat ? catBrand.paw : catColors.secondary).opacity(0.12), in: Capsule())
            .accessibilityIdentifier(cat ? "todo.tag.catpaw" : "todo.tag.user")
    }
}
