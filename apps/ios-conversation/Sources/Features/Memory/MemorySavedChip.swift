import SwiftUI

/// Wave 2 · V1 "🐾 已记住：…" receipt row (plan §1.1, event `memory_saved` in §6).
///
/// Two inputs feed the same view:
/// - today: a ```catpaw-card fence `{"kind":"memory_saved","memory":{"id","kind","content"},"undo_token":"…"}` rendered
///   through `MarkdownCustomBlockRegistry` (registered by `MemorySavedChipAdapter.register()` in `catApp.init`);
/// - later: the SSE `memory_saved` event once 三角's network layer surfaces it (decode with `MemorySavedEvent`).
struct MemorySavedEvent: Codable, Sendable, Equatable {
    struct Memory: Codable, Sendable, Equatable { let id: String; let kind: String?; let content: String }
    let memory: Memory
    let undo_token: String?
}

/// Where the chip finds the user's memory backend. Installed by `ConversationFirstModel` next to its memory service.
@MainActor enum MemoryLibraryHub {
    /// agent-memory.v1 (#41) when installed, else the claim-based adapter over ConversationMemoryService.
    static var backend: (any MemoryLibraryBackend)? { preferred ?? legacy }
    private static var preferred: (any MemoryLibraryBackend)?
    private static var legacy: (any MemoryLibraryBackend)?
    static func install(_ service: ConversationMemoryService?) { legacy = service.map { ConversationMemoryLibraryAdapter(service: $0) } }
    static func install(backend value: (any MemoryLibraryBackend)?) { preferred = value }
    static func reset() { preferred = nil; legacy = nil; MemorySavedChipState.shared.reset() }
    /// The persisted on-device library (cloud agent-memory 未开通). Starts empty.
    static var local: MemoryLibraryStub { MemoryLibraryLocal.shared }
    /// Backend for Settings › 记忆 pages opened from cards/debug (NoBug P0-2): the real backend, else the local
    /// library when it holds items, else an honest 未开通 state. Never sample data.
    static var pageBackend: any MemoryLibraryBackend {
        if let backend { return backend }
        return local.items.isEmpty ? MemoryLibraryNotEnabled() : local
    }
    /// After a cloud backend is installed: migrate local items into it. If it refuses (gate off → notEnabled /
    /// unsupported), surface the local library instead so the items stay visible + deletable (labelled 本机).
    /// Codex P0-2: `owner` is the account the cloud backend was built for; another owner's (or guest) items never move.
    @discardableResult static func reconcileLocal(owner: LocalMemoryOwner) async -> MemoryLibraryLocal.MigrationReport {
        // Codex PR91 #3: an empty library still carries a 「使用记忆」 off switch to the cloud.
        guard !local.items.isEmpty || !local.currentSnapshot.useMemory else { return .init() }
        guard let target = preferred, target !== local else { return .init(kept: local.items.count) }
        let report = await MemoryLibraryLocal.migrate(local, to: target, targetOwner: owner)
        if MemoryLibraryLocal.shouldSurfaceLocal(report) { install(backend: local) }   // gate off only; never replace a working cloud library
        return report
    }
}

/// Per memory id: undone / dismissed, so re-rendered transcripts keep the outcome.
@MainActor final class MemorySavedChipState: ObservableObject {
    static let shared = MemorySavedChipState()
    enum Outcome: String { case undone, edited }
    @Published private(set) var outcomes: [String: Outcome] = [:]
    @Published var edited: [String: String] = [:]
    func set(_ id: String, _ o: Outcome) { outcomes[id] = o }
    func reset() { outcomes = [:]; edited = [:] }
}

@MainActor enum MemorySavedChipAdapter {
    static let kind = "memory_saved"
    private static var registered = false
    static func register() {
        guard !registered else { return }; registered = true
        MarkdownCustomBlockRegistry.shared.register(kind: kind) { payload, closed in
            if closed, let event = try? JSONDecoder().decode(MemorySavedEvent.self, from: payload) { MemorySavedChip(event: event) }
            else { EmptyView() }   // still streaming or malformed: say nothing rather than show JSON
        }
    }
}

@MainActor struct MemorySavedChip: View {
    let event: MemorySavedEvent
    var backendOverride: (any MemoryLibraryBackend)? = nil
    private var backend: (any MemoryLibraryBackend)? { backendOverride ?? MemoryLibraryHub.backend }
    @ObservedObject private var state = MemorySavedChipState.shared
    @State private var open = false
    @State private var working = false
    @State private var errorKey: String?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ui(_ k: String, _ a: [String] = []) -> String { AppLanguage(locale: locale).ui(k, arguments: a) }
    private var id: String { event.memory.id }
    private var content: String { state.edited[id] ?? event.memory.content }
    private var undone: Bool { state.outcomes[id] == .undone }
    private var canUndo: Bool { backend?.capabilities.contains(.undoSave) == true && !undone }

    var body: some View {
        Button { open = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: undone ? "arrow.uturn.backward" : "pawprint.fill")
                    .foregroundStyle(undone ? catColors.tertiary : catBrand.paw).accessibilityHidden(true)
                Text(undone ? ui("已撤销记住：{0}", [content]) : ui("已记住：{0}", [content]))
                    .font(catTypography.Role.secondary.font)
                    .foregroundStyle(undone ? catColors.tertiary : catColors.secondary)
                    .strikethrough(undone)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(undone)
        .accessibilityLabel(undone ? ui("已撤销记住：{0}", [content]) : ui("已记住：{0}", [content]))
        .accessibilityHint(undone ? "" : ui("轻点可撤销或编辑"))
        .accessibilityIdentifier("chat.memorySaved." + id)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
        .sheet(isPresented: $open) { sheet }
    }

    private var sheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label(ui("小猫记住了"), systemImage: "pawprint.fill").labelStyle(PawLabelStyle()).font(catTypography.Role.heading.font)
                Text(content).font(catTypography.Role.body.font).foregroundStyle(catColors.ink).fixedSize(horizontal: false, vertical: true)
                if let errorKey { Text(ui(errorKey)).font(catTypography.Role.secondary.font).foregroundStyle(catColors.attention) }
                if backend == nil { Text(ui("记忆服务暂时连不上，请稍后重试。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary) }
                HStack(spacing: 12) {
                    Button(role: .destructive) { Task { await undo() } } label: { Text(ui("撤销")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large).disabled(!canUndo || working).accessibilityIdentifier("chat.memorySaved.undo")
                    if backend?.capabilities.contains(.edit) == true {
                        NavigationLink { MemoryEditSheet(item: .init(id: id, group: .init(kind: event.memory.kind ?? ""), content: content)) { text in Task { await edit(text) } } }
                        label: { Text(ui("编辑")).foregroundStyle(catColors.ink).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large).disabled(working || undone).accessibilityIdentifier("chat.memorySaved.edit")
                    }
                }
                if working { ProgressView().frame(maxWidth: .infinity) }
                Spacer(minLength: 0)
            }
            .padding(20)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ui("完成")) { open = false } } }
        }
        .presentationDetents([.medium])
    }

    private func undo() async {
        guard let backend else { return }
        working = true; defer { working = false }
        do { try await backend.undoSave(memoryID: id, undoToken: event.undo_token); state.set(id, .undone); errorKey = nil; open = false
             UINotificationFeedbackGenerator().notificationOccurred(.success) }
        catch { errorKey = (error as? MemoryLibraryError)?.messageKey ?? MemoryLibraryError.unavailable.messageKey }
    }
    private func edit(_ text: String) async {
        guard let backend else { return }
        working = true; defer { working = false }
        do { _ = try await backend.load(); try await backend.update(id: id, content: text); state.edited[id] = text; state.set(id, .edited); errorKey = nil }
        catch { errorKey = (error as? MemoryLibraryError)?.messageKey ?? MemoryLibraryError.unavailable.messageKey }
    }
}

/// Orange paw icon, ink title (orange rule: claw orange only on fills and icons).
struct PawLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon.foregroundStyle(catBrand.paw); configuration.title.foregroundStyle(catColors.ink) }
    }
}

#Preview("已记住") {
    VStack(alignment: .leading) {
        MemorySavedChip(event: .init(memory: .init(id: "m2", kind: "preference", content: "你喜欢靠窗座位"), undo_token: "t"), backendOverride: MemoryLibraryStub(items: MemoryLibraryStub.sample))
    }.padding()
}
