import Foundation
import os

/// L2 memory cache + incremental sync (memory-layers.md §1/§3, PR #63 S2).
/// - `GET /catpaw/agent-memory/v1/memories?since=` → `{cursor, memories, deleted[]}`; cursor is the next `since`.
/// - Live: `memory.update {op, ids, memories}` and `memory.used {ids, memories}` arrive via `MemoryEventSink`.
/// - Stored sealed in `L2SecureStore` (per user); wiped with it at sign-out.
struct CachedMemory: Codable, Sendable, Equatable, Identifiable {
    enum Source: String, Codable, Sendable { case userStated, inferred, deviceSignal, task, cloud
        /// #63 wire values: user → userStated, agent → inferred, cloud/unknown → cloud.
        init(wire: String?) {
            switch wire { case "user": self = .userStated; case "agent": self = .inferred; default: self = .cloud }
        }
    }
    let id: String
    var kind: String
    var content: String
    var source: Source
    var confidence: Double
    var expiresAt: Date?
    /// Server `updated_at` (ISO 8601) — the version; ISO strings in one format compare lexicographically.
    var version: String
    /// Local edit not yet confirmed by the server; wins until a server version ≥ this arrives.
    var pendingLocalVersion: String?
    var deleted: Bool = false

    var isLive: Bool { !deleted && (expiresAt.map { $0 > Date() } ?? true) }
    var libraryItem: MemoryLibraryItem { .init(id: id, group: MemoryGroup(kind: kind), content: content, updatedAt: ConversationMemoryCodec.date(version)) }
}

@MainActor final class MemoryCache: ObservableObject {
    static let shared = MemoryCache()
    @Published private(set) var items: [String: CachedMemory] = [:]
    /// turnID → memory ids the server reported as used for that turn (`memory.used`).
    @Published private(set) var usedByTurn: [UUID: [String]] = [:]
    private(set) var cursor: String?
    private var syncing = false
    private let log = Logger(subsystem: "catpaw", category: "memory-sync")
    private static let key = "memory.cache.v1"

    private struct Snapshot: Codable { var items: [String: CachedMemory]; var cursor: String?; var usedByTurn: [UUID: [String]] }

    // MARK: L2
    /// Re-reads the cache of the active L2 user (call after `L2SecureStore.activate`).
    func reloadFromL2() {
        let saved = L2SecureStore.current?.get(Snapshot.self, forKey: Self.key)
        items = saved?.items ?? [:]; cursor = saved?.cursor; usedByTurn = saved?.usedByTurn ?? [:]
    }
    private func persist() {
        // Keep the per-turn index bounded (most recent 200 turns is plenty for chips).
        if usedByTurn.count > 200 { usedByTurn = Dictionary(uniqueKeysWithValues: Array(usedByTurn).suffix(200)) }
        L2SecureStore.current?.put(Snapshot(items: items, cursor: cursor, usedByTurn: usedByTurn), forKey: Self.key)
    }

    // MARK: Conflict rules (memory-layers.md §3): tombstone wins; newer server version wins;
    // a pending local edit wins until the server catches up to it.
    func merge(_ incoming: CachedMemory) {
        guard var current = items[incoming.id] else { items[incoming.id] = incoming; return }
        if current.deleted { return }
        if let pending = current.pendingLocalVersion, incoming.version < pending { return }
        guard incoming.version >= current.version else { return }
        let keepSource = current.source == .userStated && incoming.source != .userStated
        current.kind = incoming.kind; current.content = incoming.content; current.version = incoming.version
        current.expiresAt = incoming.expiresAt; current.pendingLocalVersion = nil
        if !keepSource { current.source = incoming.source; current.confidence = incoming.confidence }
        items[incoming.id] = current
    }
    func tombstone(_ id: String) {
        var value = items[id] ?? CachedMemory(id: id, kind: "", content: "", source: .cloud, confidence: 0, version: "")
        value.deleted = true; value.content = ""; items[id] = value
    }

    // MARK: Local corrections (from chips / memory page); the backend call is the caller's.
    func localEdit(id: String, content: String) {
        guard var value = items[id] else { return }
        value.content = content; value.source = .userStated; value.confidence = 1
        value.pendingLocalVersion = ISO8601DateFormatter().string(from: Date()); items[id] = value; persist()
    }
    func localForget(id: String) { tombstone(id); persist() }

    // MARK: Live events
    func applyUpdate(op: String, ids: [String], memories: [MemoryEventSink.Memory]) {
        if op == "forgotten" { ids.forEach(tombstone) }
        else {
            // Live events carry no server version: update content in place, keep the version so the next sync decides.
            for m in memories {
                if m.version != nil { merge(m.cached(version: "")) }
                else if var value = items[m.id] { if !value.deleted { value.content = m.content; value.kind = m.kind ?? value.kind; items[m.id] = value } }
                else { items[m.id] = m.cached(version: "") }
            }
        }
        persist()
    }
    func recordUsed(turnID: UUID, ids: [String], memories: [MemoryEventSink.Memory]) {
        for m in memories where items[m.id] == nil { items[m.id] = m.cached(version: "") }
        usedByTurn[turnID] = ids; persist()
    }
    func used(turnID: UUID) -> [CachedMemory] { (usedByTurn[turnID] ?? []).compactMap { items[$0] } }

    // MARK: Incremental sync
    private struct Wire: Decodable {
        struct Item: Decodable { let id: String; let kind: String; let content: String; let expires_at: String?; let updated_at: String?
            let source: String?; let confidence: Double?; let version: String? }
        struct Gone: Decodable { let id: String }
        let cursor: String?; let memories: [Item]; let deleted: [Gone]?
    }
    /// Pulls changes since `cursor` (everything on first run). No-op without the agent-memory backend or L2 user.
    func sync() async {
        guard !syncing, L2SecureStore.current != nil, let backend = MemoryLibraryHub.backend as? AgentMemoryLibraryBackend else { return }
        syncing = true; defer { syncing = false }
        var route = "/memories"
        if let cursor, let q = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) { route += "?since=" + q }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: try await backend.call("GET", route))
            for m in wire.memories {
                merge(.init(id: m.id, kind: m.kind, content: m.content, source: .init(wire: m.source), confidence: m.confidence ?? 1,
                            expiresAt: m.expires_at.flatMap(ConversationMemoryCodec.date), version: m.version ?? m.updated_at ?? ""))
            }
            (wire.deleted ?? []).forEach { tombstone($0.id) }
            if let next = wire.cursor { cursor = next }
            persist()
        } catch { log.info("memory sync skipped: \(String(describing: error), privacy: .public)") }
    }

    func reset() { items = [:]; usedByTurn = [:]; cursor = nil }
}

/// Client entry point for the #63 SSE events. The stream parser lives in the network layer (三角); it forwards the raw
/// `data` JSON here. One line per event in NativeChatHTTPBackend's event switch:
///     case "memory.used":   MemoryEventSink.used(turnID: turnID, data: data)
///     case "memory.update": MemoryEventSink.update(data: data)
enum MemoryEventSink {
    struct Memory: Decodable, Sendable { let id: String; let kind: String?; let content: String
        let source: String?; let confidence: Double?; let version: String?
        func cached(version fallback: String) -> CachedMemory {
            .init(id: id, kind: kind ?? "fact", content: content, source: .init(wire: source), confidence: confidence ?? 1, version: version ?? fallback)
        }
    }
    private struct Used: Decodable { let ids: [String]; let memories: [Memory]? }
    private struct Update: Decodable { let op: String; let ids: [String]; let memories: [Memory]? }

    static func used(turnID: UUID, data: Data) {
        guard let v = try? JSONDecoder().decode(Used.self, from: data) else { return }
        Task { @MainActor in MemoryCache.shared.recordUsed(turnID: turnID, ids: v.ids, memories: v.memories ?? []) }
    }
    static func update(data: Data) {
        guard let v = try? JSONDecoder().decode(Update.self, from: data) else { return }
        Task { @MainActor in MemoryCache.shared.applyUpdate(op: v.op, ids: v.ids, memories: v.memories ?? []) }
    }
}

extension MemoryEventSink {
    /// Routes the network layer's side-channel events here. Call once where the memory service is created.
    static func installSideChannel() {
        ConversationSideChannelEvents.handler = { type, turnID, data in
            switch type {
            case "memory.used": MemoryEventSink.used(turnID: turnID, data: data)
            case "memory.update": MemoryEventSink.update(data: data)
            default: break
            }
        }
    }
}
