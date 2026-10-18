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
    /// Codex PR91 v3-2: `use_memory_seq` lets the server reject an older choice that arrives late (last writer by sequence).
    func setUseMemory(_ on: Bool, seq: Int64) async throws -> Bool {
        let body: [String: Any] = on ? ["consent": true, "use_memory": true, "use_memory_seq": seq] : ["use_memory": false, "use_memory_seq": seq]
        let data = try await call("PATCH", "/settings", body)
        struct Reply: Decodable { struct S: Decodable { let use_memory: Bool }; let settings: S }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw MemoryLibraryError.unavailable }   // unknown → fail closed
        return reply.settings.use_memory
    }
    func setAutoSave(_ on: Bool) async throws { _ = try await call("PATCH", "/settings", on ? ["consent": true, "auto_save": true] : ["auto_save": false]) }
    /// The page shows the second confirmation before calling this.
    func clearAll() async throws { _ = try await call("POST", "/clear", ["confirm": "delete_all"]) }
    func undoSave(memoryID: String, undoToken: String?) async throws {
        if let undoToken { _ = try await call("POST", "/undo", ["undo_token": undoToken]) } else { try await forget(ids: [memoryID]) }
    }

    private static func path(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id }

    /// Launch-loader follow-up: a server with the agent-memory gate off answers every read with 404. Remember that per
    /// origin for a while so launch/foreground reads stop hammering it; writes always go through (and reset the window).
    static var notEnabledBackoff: TimeInterval = 120
    private static var notEnabledUntil: [String: Date] = [:]
    static func resetNotEnabledBackoff() { notEnabledUntil = [:] }
    func call(_ method: String, _ route: String, _ body: [String: Any]? = nil) async throws -> Data {
        let gateKey = configuration.origin.absoluteString
        if method == "GET", !route.hasPrefix("/items/"), let until = Self.notEnabledUntil[gateKey], until > Date() { throw MemoryLibraryError.notEnabled }
        if method != "GET" { Self.notEnabledUntil[gateKey] = nil }
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
        case 404:
            if route.hasPrefix("/items/") { throw MemoryLibraryError.notFound }
            Self.notEnabledUntil[gateKey] = Date().addingTimeInterval(Self.notEnabledBackoff)
            throw MemoryLibraryError.notEnabled
        case 409: throw MemoryLibraryError.failed("需要先同意使用记忆。")
        case 410: throw MemoryLibraryError.failed("已超过可撤销时间。")
        default: throw MemoryLibraryError.unavailable
        }
    }
}

extension MemoryLibraryHub {
    /// Prefer catpaw.agent-memory.v1 over the claim-based adapter once 三角 installs it.
    static func installAgentMemory(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials) {
        install(backend: AgentMemoryLibraryBackend(configuration: configuration, credentials: credentials))
        // NoBug P0-1 + Codex P0-2: local → cloud only for the account this backend authenticates as.
        guard let subject = configuration.expectedSubjectID else { return }
        let owner = LocalMemoryOwner.account(subject.uuidString.lowercased())
        Task { @MainActor in
            // Codex PR91 #2: a backend built for A must not re-bind A's library once B's session has started.
            let current = AccountEpoch.shared.currentAccount
            guard current == nil || current == subject.uuidString else { return }
            MemoryLibraryLocal.activate(userID: subject)
            await reconcileLocal(owner: owner)
        }
    }
}
