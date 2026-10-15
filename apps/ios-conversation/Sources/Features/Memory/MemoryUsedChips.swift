import SwiftUI

/// 「本次用到的记忆」: chips under the assistant reply of the turn whose `memory.used` arrived (#63 S2).
/// Tap → sheet with the memory, 编辑 (MemoryEditSheet from #42) and 忘记. Orange only on the paw icon; text is ink/secondary.
@MainActor struct MemoryUsedChips: View {
    let turnID: UUID
    @ObservedObject private var cache = MemoryCache.shared
    @State private var selected: CachedMemory?
    @Environment(\.locale) private var locale
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var used: [CachedMemory] { cache.used(turnID: turnID) }

    var body: some View {
        if !used.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(ui("本次用到的记忆")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(used) { chip($0) } }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.memoryUsed." + turnID.uuidString)
            .sheet(item: $selected) { MemoryUsedSheet(memory: $0) }
        }
    }

    private func chip(_ m: CachedMemory) -> some View {
        Button { if m.isLive { selected = m } } label: {
            HStack(spacing: 4) {
                (m.isLive ? AnyView(CategoryPaw(category: .memory)) : AnyView(PawMark(size: 14, color: CatpawColors.tertiary.opacity(0.5), shadow: false))).accessibilityHidden(true)
                Text(m.isLive ? m.content : ui("已遗忘的记忆"))
                    .font(CatpawTypography.Role.secondary.font)
                    .foregroundStyle(m.isLive ? CatpawColors.ink : CatpawColors.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(Capsule().fill(CatpawColors.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!m.isLive)
        .accessibilityHint(m.isLive ? ui("轻点可编辑或忘记") : "")
        .accessibilityIdentifier("chat.memoryUsed.chip." + m.id)
    }
}

@MainActor private struct MemoryUsedSheet: View {
    let memory: CachedMemory
    @State private var working = false
    @State private var errorKey: String?
    @State private var confirmForget = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private var backend: (any MemoryLibraryBackend)? { MemoryLibraryHub.backend }
    private var content: String { MemoryCache.shared.items[memory.id]?.content ?? memory.content }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(content).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).fixedSize(horizontal: false, vertical: true)
                if let errorKey { Text(ui(errorKey)).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention) }
                HStack(spacing: 12) {
                    if backend?.capabilities.contains(.edit) == true {
                        NavigationLink { MemoryEditSheet(item: memory.libraryItem) { text in Task { await edit(text) } } }
                        label: { Text(ui("编辑")).foregroundStyle(CatpawColors.ink).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large).disabled(working).accessibilityIdentifier("chat.memoryUsed.edit")
                    }
                    Button(role: .destructive) { confirmForget = true } label: { Text(ui("忘记")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large).disabled(working || backend == nil).accessibilityIdentifier("chat.memoryUsed.forget")
                }
                if working { ProgressView().frame(maxWidth: .infinity) }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle(ui("本次用到的记忆")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ui("完成")) { dismiss() } } }
            .confirmationDialog(ui("忘记这条记忆？"), isPresented: $confirmForget, titleVisibility: .visible) {
                Button(ui("忘记"), role: .destructive) { Task { await forget() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func edit(_ text: String) async {
        guard let backend else { return }
        working = true; defer { working = false }
        do { try await backend.update(id: memory.id, content: text); MemoryCache.shared.localEdit(id: memory.id, content: text); errorKey = nil }
        catch { errorKey = (error as? MemoryLibraryError)?.messageKey ?? MemoryLibraryError.unavailable.messageKey }
    }
    private func forget() async {
        guard let backend else { return }
        working = true; defer { working = false }
        do { try await backend.forget(ids: [memory.id]); MemoryCache.shared.localForget(id: memory.id); dismiss() }
        catch { errorKey = (error as? MemoryLibraryError)?.messageKey ?? MemoryLibraryError.unavailable.messageKey }
    }
}
