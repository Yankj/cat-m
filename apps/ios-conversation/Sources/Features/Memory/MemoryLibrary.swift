import Foundation

// Wave 2 · V1 memory library (plan §1.1). UI-facing model + backend seam.
// `ConversationMemoryLibraryAdapter` maps the existing server memory service (三角, NativeMemoryHTTPBackend) onto this
// seam for list / edit / forget / "使用记忆"; the plan's extra controls ("自动记住新内容", "全部清除", undo_token) are
// reported as unsupported until 三角 exposes them, so the page hides or disables them instead of faking success.

enum MemoryGroup: String, CaseIterable, Sendable, Identifiable, Codable {
    case profile, preference, person, journal
    var id: String { rawValue }
    /// Plan §1.2 kinds: profile | preference | person | fact | journal. `fact` is shown under 关于我.
    init(kind: String) {
        switch kind {
        case "profile", "fact": self = .profile
        case "person": self = .person
        case "journal": self = .journal
        default: self = .preference
        }
    }
    var titleKey: String {
        switch self {
        case .profile: "关于我"
        case .preference: "偏好"
        case .person: "人物与关系"
        case .journal: "近期日志"
        }
    }
    var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .preference: "heart"
        case .person: "person.2"
        case .journal: "book.closed"
        }
    }
}

struct MemoryLibraryItem: Identifiable, Sendable, Equatable, Codable {
    let id: String
    var group: MemoryGroup
    var content: String
    var updatedAt: Date?
}

struct MemoryLibrarySnapshot: Sendable, Equatable, Codable {
    var items: [MemoryLibraryItem]
    var useMemory: Bool
    /// nil = the backend cannot report or change it yet.
    var autoSave: Bool?
}

struct MemoryLibraryCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let edit = Self(rawValue: 1 << 0)
    static let forget = Self(rawValue: 1 << 1)
    static let toggleUse = Self(rawValue: 1 << 2)
    static let toggleAutoSave = Self(rawValue: 1 << 3)
    static let clearAll = Self(rawValue: 1 << 4)
    static let undoSave = Self(rawValue: 1 << 5)
    static let all: Self = [.edit, .forget, .toggleUse, .toggleAutoSave, .clearAll, .undoSave]
}

enum MemoryLibraryError: Error, Equatable, Sendable {
    case unsupported, unavailable, notEnabled, notFound, failed(String)
    var messageKey: String {
        switch self {
        case .unsupported: "此操作暂未开放。"
        case .unavailable: "记忆服务暂时连不上，请稍后重试。"
        case .notEnabled: "记忆功能还没为你开通。开通后，小猫记住的事会出现在这里。"
        case .notFound: "没有找到这条记忆，可能已被删除。"
        case .failed(let message): message
        }
    }
}

/// Seam for the memory page and the "已记住" chip. All calls are async and may throw `MemoryLibraryError`.
@MainActor protocol MemoryLibraryBackend: AnyObject {
    var capabilities: MemoryLibraryCapabilities { get }
    func load() async throws -> MemoryLibrarySnapshot
    func update(id: String, content: String) async throws
    func forget(ids: [String]) async throws
    func setUseMemory(_ on: Bool) async throws
    func setAutoSave(_ on: Bool) async throws
    func clearAll() async throws
    /// Undo of a `memory_saved` receipt. `undoToken` is the plan §6 token when the server sends one.
    func undoSave(memoryID: String, undoToken: String?) async throws
    /// Create a real library item (shown + deletable in Settings › 记忆). Returns the new id.
    func create(kind: String, content: String) async throws -> String
}
extension MemoryLibraryBackend {
    func create(kind: String, content: String) async throws -> String { throw MemoryLibraryError.unsupported }
}

/// Memory library kept on this device. `fileURL == nil` → in-memory only (Previews / tests).
/// With a `fileURL` (see `MemoryLibraryLocal.shared`) every mutation is written atomically, so items survive a cold start.
/// Default init is EMPTY (NoBug P0-2): pass `MemoryLibraryStub.sample` explicitly in Previews.
/// Codex P0-2: where a local library persists. The app binds it to the signed-in user's L2SecureStore (per-user
/// directory, AES-GCM, Keychain key, wiped at sign-out); `write(nil)` erases.
struct MemoryLibraryStorage {
    let read: () -> Data?
    let write: (Data?) -> Void
}

@MainActor final class MemoryLibraryStub: MemoryLibraryBackend {
    var capabilities: MemoryLibraryCapabilities = .all
    private var snapshot: MemoryLibrarySnapshot
    let fileURL: URL?
    private let storage: MemoryLibraryStorage?
    /// Codex P0-2: account that owns these items (nil = unowned guest / legacy / preview).
    let owner: String?
    init(items: [MemoryLibraryItem] = [], useMemory: Bool = true, autoSave: Bool = true, fileURL: URL? = nil, storage: MemoryLibraryStorage? = nil, owner: String? = nil) {
        self.fileURL = fileURL; self.storage = storage; self.owner = owner
        let data = storage?.read() ?? fileURL.flatMap { try? Data(contentsOf: $0) }
        if let data, let saved = try? JSONDecoder().decode(MemoryLibrarySnapshot.self, from: data) { snapshot = saved }
        else { snapshot = .init(items: items, useMemory: useMemory, autoSave: autoSave) }
    }
    /// Sign-out: erase the persisted copy and the in-memory items.
    func erase() { snapshot.items = []; storage?.write(nil); if let fileURL { try? FileManager.default.removeItem(at: fileURL) } }
    /// Synchronous view for routing decisions (e.g. show local items vs 未开通).
    var items: [MemoryLibraryItem] { snapshot.items }
    var isPersistent: Bool { fileURL != nil || storage != nil }
    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        if let storage { storage.write(data); return }
        guard let fileURL else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
    func load() async throws -> MemoryLibrarySnapshot { snapshot }
    func update(id: String, content: String) async throws {
        guard let i = snapshot.items.firstIndex(where: { $0.id == id }) else { throw MemoryLibraryError.notFound }
        snapshot.items[i].content = content; snapshot.items[i].updatedAt = .now; save()
    }
    func forget(ids: [String]) async throws { snapshot.items.removeAll { ids.contains($0.id) }; save() }
    func setUseMemory(_ on: Bool) async throws { snapshot.useMemory = on; save() }
    func setAutoSave(_ on: Bool) async throws { snapshot.autoSave = on; save() }
    func clearAll() async throws { snapshot.items = []; save() }
    func undoSave(memoryID: String, undoToken: String?) async throws { try await forget(ids: [memoryID]) }
    func create(kind: String, content: String) async throws -> String {
        let id = "local-" + UUID().uuidString.lowercased()
        snapshot.items.insert(.init(id: id, group: MemoryGroup(kind: kind), content: content, updatedAt: .now), at: 0); save(); return id
    }

    /// Previews / tests only — never the default.
    static let sample: [MemoryLibraryItem] = [
        .init(id: "m1", group: .profile, content: "住在北京望京", updatedAt: .now),
        .init(id: "m2", group: .preference, content: "喜欢靠窗座位", updatedAt: .now),
        .init(id: "m3", group: .preference, content: "咖啡只喝燕麦拿铁", updatedAt: .now),
        .init(id: "m4", group: .person, content: "张三是合作方的项目负责人", updatedAt: .now),
        .init(id: "m5", group: .journal, content: "周三整理了第二波开发计划", updatedAt: .now),
    ]
}

/// Maps 三角's existing `ConversationMemoryService` (claims, forget, set_enabled, correct) onto the seam.
/// Does not touch the network layer; only calls the public service API.
@MainActor final class ConversationMemoryLibraryAdapter: MemoryLibraryBackend {
    private let service: ConversationMemoryService
    private var entries: [String: ConversationMemoryEntry] = [:]
    init(service: ConversationMemoryService) { self.service = service }

    // Needs 三角: auto_save setting, clear-all, and undo_token (plan §1.2 memory_settings, §6 memory_saved).
    var capabilities: MemoryLibraryCapabilities { [.edit, .forget, .toggleUse, .undoSave] }

    func load() async throws -> MemoryLibrarySnapshot {
        let state: ConversationMemoryLocalState
        do { state = try await service.refresh() } catch { throw Self.map(error) }
        guard let latest = state.latest else { throw MemoryLibraryError.unavailable }
        entries = Dictionary(latest.claims.map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let items = latest.claims.map { entry in
            MemoryLibraryItem(id: entry.id.uuidString.lowercased(), group: MemoryGroup(kind: entry.kind), content: entry.displayValue,
                       updatedAt: ConversationMemoryCodec.date(entry.recorded_at))
        }
        return .init(items: items, useMemory: latest.enabled, autoSave: nil)
    }

    func update(id: String, content: String) async throws {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = entries[id], !text.isEmpty else { throw MemoryLibraryError.notFound }
        var command = ConversationMemoryCommand(type: .correct)
        command.conversation_id = base.conversation_id; command.source_text = text
        command.allow_relearn = false; command.sensitive_consent = false
        command.target_id = base.id; command.expected_version = base.version
        var value: ConversationMemoryValue = .string(text)
        if case .object(let values) = base.value, let topic = values["topic"] { value = .object(["topic": topic, "text": .string(text)]) }
        command.claim = .init(kind: base.kind, predicate: base.predicate, value: value, conditions: base.conditions,
                              evidence: .init(span_start: 0, span_end: text.utf16.count), valid_from: base.valid_from,
                              valid_until: base.valid_until, expires_at: base.expires_at)
        try await submit(command)
    }

    func forget(ids: [String]) async throws {
        for id in ids {
            guard let entry = entries[id] else { throw MemoryLibraryError.notFound }
            var command = ConversationMemoryCommand(type: .forget)
            command.target_id = entry.id; command.expected_version = entry.version; command.no_relearn = true
            try await submit(command)
            entries[id] = nil
            _ = try? await load()   // the service requires a fresh snapshot before the next command
        }
    }

    func setUseMemory(_ on: Bool) async throws {
        var command = ConversationMemoryCommand(type: .set_enabled); command.enabled = on
        try await submit(command)
    }
    func setAutoSave(_ on: Bool) async throws { throw MemoryLibraryError.unsupported }
    func clearAll() async throws { throw MemoryLibraryError.unsupported }

    /// Until 三角 ships undo_token: undo = forget the saved claim by id (read fresh first for its version).
    func undoSave(memoryID: String, undoToken: String?) async throws {
        _ = try await load()
        try await forget(ids: [memoryID.lowercased()])
    }

    private func submit(_ command: ConversationMemoryCommand) async throws {
        do { _ = try await service.submit(command); _ = try? await service.refresh() } catch { throw Self.map(error) }
    }
    private static func map(_ error: Error) -> MemoryLibraryError {
        if error is CancellationError { return .unavailable }
        if let e = error as? ConversationMemoryError { return e == .unavailable ? .unavailable : .failed(e.localizedDescription) }
        return .failed(error.localizedDescription)
    }
}
