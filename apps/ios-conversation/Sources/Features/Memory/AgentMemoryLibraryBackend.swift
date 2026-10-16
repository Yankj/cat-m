import Foundation

/// catpaw.agent-memory.v1 (PR #41, services/edge/docs/agent-memory-contract.md) behind `MemoryLibraryBackend`.
/// #41 ships no iOS client, so this is ours; it only reuses the public `NativeChatConfiguration.makeRequest` and
/// `NativeChatSessionCredentials` (no network-layer file is edited). Install (三角, one line where the memory service is built):
///     MemoryLibraryHub.installAgentMemory(configuration: configuration, credentials: credentials)
/// Gate off on the server ⇒ 404 ⇒ `.unavailable`.
@MainActor final class AgentMemoryLibraryBackend: MemoryLibraryBackend {
    private let configuration: NativeChatConfiguration
    private let credentials: any NativeChatSessionCredentials
    private let session: URLSession
    private static let base = "/catpaw/agent-memory/v1"
    var capabilities: MemoryLibraryCapabilities { .all }

    init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials) {
        self.configuration = configuration; self.credentials = credentials
        let policy = URLSessionConfiguration.ephemeral; policy.urlCache = nil; policy.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: policy)
    }

    private struct Settings: Decodable { let use_memory: Bool; let auto_save: Bool; let consented_at: String? }
    private struct SettingsEnvelope: Decodable { let settings: Settings }
    private struct Item: Decodable { let id: String; let kind: String; let content: String; let updated_at: String? }
    private struct Items: Decodable { let memories: [Item] }

    func load() async throws -> MemoryLibrarySnapshot {
        let settings = try JSONDecoder().decode(SettingsEnvelope.self, from: try await call("GET", "/settings")).settings
        let items = try JSONDecoder().decode(Items.self, from: try await call("GET", "/items")).memories
        return .init(items: items.map { .init(id: $0.id, group: MemoryGroup(kind: $0.kind), content: $0.content, updatedAt: $0.updated_at.flatMap(ConversationMemoryCodec.date)) },
                     useMemory: settings.use_memory, autoSave: settings.auto_save)
    }
    private struct Created: Decodable { let memory: Item? ; let id: String? }
    func create(kind: String, content: String) async throws -> String {
        let data = try await call("POST", "/items", ["kind": kind, "content": content])
        let c = try? JSONDecoder().decode(Created.self, from: data)
        return c?.memory?.id ?? c?.id ?? ""
    }
    func update(id: String, content: String) async throws { _ = try await call("PATCH", "/items/" + Self.path(id), ["content": content]) }
    func forget(ids: [String]) async throws { for id in ids { _ = try await call("DELETE", "/items/" + Self.path(id)) } }
    /// Contract: turning either switch on requires `consent:true` in the same PATCH.
    func setUseMemory(_ on: Bool) async throws { _ = try await call("PATCH", "/settings", on ? ["consent": true, "use_memory": true] : ["use_memory": false]) }
    func setAutoSave(_ on: Bool) async throws { _ = try await call("PATCH", "/settings", on ? ["consent": true, "auto_save": true] : ["auto_save": false]) }
    /// The page shows the second confirmation before calling this.
    func clearAll() async throws { _ = try await call("POST", "/clear", ["confirm": "delete_all"]) }
    func undoSave(memoryID: String, undoToken: String?) async throws {
        if let undoToken { _ = try await call("POST", "/undo", ["undo_token": undoToken]) } else { try await forget(ids: [memoryID]) }
    }

    private static func path(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id }

    func call(_ method: String, _ route: String, _ body: [String: Any]? = nil) async throws -> Data {
        let authorization: String
        do { authorization = try await credentials.authorization(scope: configuration.localScope) } catch { throw MemoryLibraryError.unavailable }
        var request = try configuration.makeRequest(route: Self.base + route, authorization: authorization)
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw MemoryLibraryError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw MemoryLibraryError.unavailable }
        switch http.statusCode {
        case 200..<300: return data
        case 401: await credentials.rejected(scope: configuration.localScope); throw MemoryLibraryError.unavailable
        // Feature gate off (not granted / not enrolled): not an auth failure, so never drop the session.
        case 403: throw MemoryLibraryError.notEnabled
        case 404: throw route.hasPrefix("/items/") ? MemoryLibraryError.notFound : MemoryLibraryError.notEnabled
        case 409: throw MemoryLibraryError.failed("需要先同意使用记忆。")
        case 410: throw MemoryLibraryError.failed("已超过可撤销时间。")
        default: throw MemoryLibraryError.unavailable
        }
    }
}

extension MemoryLibraryHub {
    /// Prefer catpaw.agent-memory.v1 over the claim-based adapter once 三角 installs it.
    static func installAgentMemory(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials, owner: UUID?) {
        MemoryLibraryLocal.activate(userID: owner)
        install(backend: AgentMemoryLibraryBackend(configuration: configuration, credentials: credentials))
        let ownerKey = MemoryLibraryLocal.shared.owner
        Task { @MainActor in await reconcileLocal(owner: ownerKey) }   // NoBug P0-1 + Codex P0-2: same owner only
    }
}

extension MemoryLibraryLocal {
    static let l2Key = "local-memory.v2"
    /// Codex P0-2: bind the on-device library to `userID`'s L2SecureStore (AES-GCM, per-user dir, wiped at sign-out).
    static func activate(userID: UUID?) {
        removeLegacyPlaintext()
        let previous = shared
        if let userID { L2SecureStore.activate(userID: userID) }
        if let userID, let l2 = L2SecureStore.current, l2.userID == userID {
            activate(owner: userID.uuidString.lowercased(), storage: .init(read: { l2.data(forKey: l2Key) }, write: { l2.set($0, forKey: l2Key) }))
        } else { activate(owner: nil, storage: nil) }
        if shared !== previous, MemoryLibraryHub.backend === previous { MemoryLibraryHub.install(backend: nil) }   // never keep another account's library installed
    }
}
