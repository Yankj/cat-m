import SwiftUI

/// Wave 2 · V1 设置 › 记忆 (plan §1.1): grouped list, search, edit, swipe "忘记", the two master switches and
/// "全部清除" with a second confirmation. Controls the backend cannot serve yet are hidden, never faked.
@MainActor final class MemoryLibraryModel: ObservableObject {
    @Published private(set) var snapshot: MemoryLibrarySnapshot?
    @Published private(set) var busy = false
    @Published var errorKey: String?
    @Published var query = ""
    let backend: any MemoryLibraryBackend
    init(backend: any MemoryLibraryBackend) { self.backend = backend }
    var can: MemoryLibraryCapabilities { backend.capabilities }

    func grouped() -> [(MemoryGroup, [MemoryItem])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = (snapshot?.items ?? []).filter { q.isEmpty || $0.content.localizedCaseInsensitiveContains(q) }
        return MemoryGroup.allCases.compactMap { g in
            let rows = items.filter { $0.group == g }
            return rows.isEmpty ? nil : (g, rows)
        }
    }
    func load() async { await run { self.snapshot = try await self.backend.load() } }
    func forget(_ item: MemoryItem) async {
        let prior = snapshot
        snapshot?.items.removeAll { $0.id == item.id }   // optimistic, restored on failure
        await run(restore: prior) { try await self.backend.forget(ids: [item.id]) }
    }
    func update(_ item: MemoryItem, content: String) async {
        await run { try await self.backend.update(id: item.id, content: content); self.snapshot = try await self.backend.load() }
    }
    func setUse(_ on: Bool) async {
        let prior = snapshot; snapshot?.useMemory = on
        await run(restore: prior) { try await self.backend.setUseMemory(on) }
    }
    func setAutoSave(_ on: Bool) async {
        let prior = snapshot; snapshot?.autoSave = on
        await run(restore: prior) { try await self.backend.setAutoSave(on) }
    }
    func clearAll() async {
        let prior = snapshot; snapshot?.items = []
        await run(restore: prior) { try await self.backend.clearAll() }
    }
    private func run(restore: MemoryLibrarySnapshot?? = nil, _ work: @escaping @MainActor () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await work(); errorKey = nil }
        catch {
            if let restore { snapshot = restore }
            errorKey = (error as? MemoryLibraryError)?.messageKey ?? MemoryLibraryError.unavailable.messageKey
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

@MainActor struct MemoryLibraryView: View {
    @StateObject private var model: MemoryLibraryModel
    @State private var editing: MemoryItem?
    @State private var confirmClear = false
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    /// Optional "advanced" destination, e.g. the existing reviewed-command page (`ConversationMemoryView`).
    private let advanced: AnyView?

    init(backend: any MemoryLibraryBackend, advanced: AnyView? = nil) {
        _model = StateObject(wrappedValue: MemoryLibraryModel(backend: backend)); self.advanced = advanced
    }

    var body: some View {
        List {
            switchesSection
            if let snapshot = model.snapshot {
                if snapshot.items.isEmpty {
                    Section { emptyState }
                } else {
                    let groups = model.grouped()
                    if groups.isEmpty { Section { Text(ui("没有匹配的记忆")).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.secondary) } }
                    ForEach(groups, id: \.0) { group, rows in
                        Section { ForEach(rows) { row($0) } } header: {
                            Label(ui(group.titleKey), systemImage: group.symbol).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                        }
                    }
                }
                if model.can.contains(.clearAll), !snapshot.items.isEmpty {
                    Section { Button(ui("全部清除"), role: .destructive) { confirmClear = true }.touchTarget().accessibilityIdentifier("memory.library.clearAll") }
                }
            } else if model.errorKey == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let errorKey = model.errorKey {
                Section {
                    Text(ui(errorKey)).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memory.library.error")
                    Button(ui("重试")) { Task { await model.load() } }.touchTarget()
                }
            }
            if let advanced {
                Section { NavigationLink(ui("记忆核对与来源")) { advanced }.accessibilityIdentifier("memory.library.advanced") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(CatpawColors.background)
        .font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
        .searchable(text: $model.query, prompt: Text(ui("搜索记忆")))
        .navigationTitle(ui("记忆")).navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy && model.snapshot == nil)
        .refreshable { await model.load() }
        .task { await model.load() }
        .confirmationDialog(ui("清除全部记忆？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(ui("全部清除"), role: .destructive) { Task { await model.clearAll() } }
            Button(ui("取消"), role: .cancel) {}
        } message: { Text(ui("小猫会忘掉所有记住的内容，此操作无法撤销。")) }
        .sheet(item: $editing) { item in MemoryEditSheet(item: item) { text in Task { await model.update(item, content: text) } } }
        .accessibilityIdentifier("memory.library")
    }

    @ViewBuilder private var switchesSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.snapshot?.useMemory ?? false }, set: { v in Task { await model.setUse(v) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui("使用记忆")).font(CatpawTypography.Role.body.font)
                    Text(ui("回复时参考已记住的内容")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                }
            }
            .tint(CatpawBrand.paw)
            .disabled(model.snapshot == nil || !model.can.contains(.toggleUse))
            .accessibilityIdentifier("memory.library.use")
            if model.can.contains(.toggleAutoSave), let auto = model.snapshot?.autoSave {
                Toggle(isOn: Binding(get: { auto }, set: { v in Task { await model.setAutoSave(v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ui("自动记住新内容")).font(CatpawTypography.Role.body.font)
                        Text(ui("关闭后只在你明确要求时记住")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                }
                .tint(CatpawBrand.paw)
                .disabled(model.snapshot?.useMemory != true)
                .accessibilityIdentifier("memory.library.autoSave")
            }
        } footer: {
            Text(ui("临时对话不会读取或写入记忆。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "pawprint.fill").font(.title2).foregroundStyle(CatpawBrand.paw).accessibilityHidden(true)
            Text(ui("还没有记住任何内容")).font(CatpawTypography.Role.heading.font)
            Text(ui("聊天时说“记住……”，小猫就会把它放在这里。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16).accessibilityElement(children: .combine).accessibilityIdentifier("memory.library.empty")
    }

    private func row(_ item: MemoryItem) -> some View {
        Button { if model.can.contains(.edit) { editing = item } } label: {
            Text(item.content).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if model.can.contains(.forget) {
                Button(role: .destructive) { Task { await model.forget(item) } } label: { Label(ui("忘记"), systemImage: "trash") }
            }
        }
        .contextMenu {
            if model.can.contains(.edit) { Button { editing = item } label: { Label(ui("编辑"), systemImage: "pencil") } }
            if model.can.contains(.forget) { Button(role: .destructive) { Task { await model.forget(item) } } label: { Label(ui("忘记"), systemImage: "trash") } }
        }
        .accessibilityHint(model.can.contains(.edit) ? ui("轻点编辑，左滑忘记") : "")
        .accessibilityIdentifier("memory.library.item." + item.id)
    }
}

@MainActor struct MemoryEditSheet: View {
    let item: MemoryItem
    let save: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    init(item: MemoryItem, save: @escaping (String) -> Void) { self.item = item; self.save = save; _text = State(initialValue: item.content) }
    var body: some View {
        NavigationStack {
            Form { TextField(ui("记忆内容"), text: $text, axis: .vertical).font(CatpawTypography.Role.body.font).lineLimit(3...8).accessibilityIdentifier("memory.edit.text") }
                .navigationTitle(ui("编辑记忆")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(ui("保存")) { save(text); dismiss() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == item.content)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("记忆页") { NavigationStack { MemoryLibraryView(backend: MemoryLibraryStub()) } }
#Preview("记忆页 · 空") { NavigationStack { MemoryLibraryView(backend: MemoryLibraryStub(items: [])) } }
