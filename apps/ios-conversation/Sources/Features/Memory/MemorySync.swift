import Foundation
#if canImport(os)
import os
#endif

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
    #if canImport(os)
    private let log = Logger(subsystem: "catpaw", category: "memory-sync")
    #endif
    private static let key = "memory.cache.v1"
    /// Codex PR91 #1: the cache is bound to ONE account's L2 store + session generation. Every write path (sync
    /// response, SSE event, local edit) must still match both, so A's late response can never land in B's store.
    private(set) weak var boundStore: L2SecureStore?
    private(set) var boundToken: AccountToken?
    private func note(_ text: String) {
        #if canImport(os)
        log.info("\(text, privacy: .public)")
        #endif
    }
    /// True while the cache still belongs to the account/session that `token` was taken in.
    func admits(_ token: AccountToken) -> Bool {
        guard let store = boundStore, boundToken == token, AccountEpoch.shared.isValid(token) else { return false }
        return store.userID.uuidString == token.account && L2SecureStore.current === store
    }

    private struct Snapshot: Codable { var items: [String: CachedMemory]; var cursor: String?; var usedByTurn: [UUID: [String]] }

    // MARK: L2
    /// Re-reads the cache of the active L2 user (call after `L2SecureStore.activate`).
    func reloadFromL2() {
        let store = L2SecureStore.current
        let saved = store?.get(Snapshot.self, forKey: Self.key)
        items = saved?.items ?? [:]; cursor = saved?.cursor; usedByTurn = saved?.usedByTurn ?? [:]
        let token = AccountEpoch.shared.capture()
        // Bound only when the store belongs to the signed-in account of this epoch.
        if let store, let token, store.userID.uuidString == token.account { boundStore = store; boundToken = token } else { boundStore = nil; boundToken = nil }
    }
    private func persist() {
        // Keep the per-turn index bounded (most recent 200 turns is plenty for chips).
        if usedByTurn.count > 200 { usedByTurn = Dictionary(uniqueKeysWithValues: Array(usedByTurn).suffix(200)) }
        // Only into the store this cache was loaded from, and only while it is still the active one.
        guard let store = boundStore, let token = boundToken, admits(token) else { note("memory cache persist skipped: account changed"); return }
        let snapshot = Snapshot(items: items, cursor: cursor, usedByTurn: usedByTurn)
        let wrote: Bool? = AccountEpoch.shared.commit(token) {
            do { try store.put(snapshot, forKey: Self.key); return true } catch { return false }
        }
        if wrote != true { note(wrote == nil ? "memory cache persist refused: account epoch changed" : "memory cache persist failed") }
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
    func applyUpdate(op: String, ids: [String], memories: [MemoryEventSink.Memory], token: AccountToken? = nil) {
        if let token, !admits(token) { note("memory.update dropped: other account/session"); return }
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
    func recordUsed(turnID: UUID, ids: [String], memories: [MemoryEventSink.Memory], token: AccountToken? = nil) {
        if let token, !admits(token) { note("memory.used dropped: other account/session"); return }
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
    #if !MEMORY_PORTABLE
    func sync() async {
        guard let backend = MemoryLibraryHub.backend as? AgentMemoryLibraryBackend else { return }
        await sync { route in try await backend.call("GET", route) }
    }
    #endif
    /// Core of `sync()` with the transport injected (portable tests). The account + generation are captured BEFORE the
    /// request; a response that comes back after sign-out / account switch is dropped, never merged or persisted.
    func sync(fetch: (String) async throws -> Data) async {
        guard !syncing, let store = L2SecureStore.current, boundStore === store, let token = boundToken, admits(token) else { return }
        syncing = true; defer { syncing = false }
        var route = "/memories"
        if let cursor, let q = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) { route += "?since=" + q }
        do {
            let raw = try await fetch(route)
            guard admits(token) else { note("memory sync response dropped: account changed while in flight"); return }
            let wire = try JSONDecoder().decode(Wire.self, from: raw)
            for m in wire.memories {
                merge(.init(id: m.id, kind: m.kind, content: m.content, source: .init(wire: m.source), confidence: m.confidence ?? 1,
                            expiresAt: m.expires_at.flatMap(ConversationMemoryCodec.date), version: m.version ?? m.updated_at ?? ""))
            }
            (wire.deleted ?? []).forEach { tombstone($0.id) }
            if let next = wire.cursor { cursor = next }
            persist()
        } catch { note("memory sync skipped: \(String(describing: error))") }
    }

    /// Sign-out: forget everything in memory and unbind from the store (the L2 files go with `L2SecureStore.wipe`).
    func reset() { items = [:]; usedByTurn = [:]; cursor = nil; boundStore = nil; boundToken = nil }
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
        guard let token = AccountEpoch.shared.capture() else { return }   // taken on arrival; a sign-out before the hop drops it
        Task { @MainActor in MemoryCache.shared.recordUsed(turnID: turnID, ids: v.ids, memories: v.memories ?? [], token: token) }
    }
    static func update(data: Data) {
        guard let v = try? JSONDecoder().decode(Update.self, from: data) else { return }
        guard let token = AccountEpoch.shared.capture() else { return }
        Task { @MainActor in MemoryCache.shared.applyUpdate(op: v.op, ids: v.ids, memories: v.memories ?? [], token: token) }
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
