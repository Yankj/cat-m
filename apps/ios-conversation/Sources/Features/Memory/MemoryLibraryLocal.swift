import Foundation

// NoBug P0-1/P0-2: the on-device memory library used when cloud agent-memory is 未开通 (gate off / not enrolled).
// - Persisted (Application Support, Codable JSON), so S2/S8 「写入记忆并生效」 survives a cold start.
// - Starts EMPTY. Sample memories exist only in Previews/tests (`MemoryLibraryStub.sample`).
// - When the cloud gate opens, `migrate(_:to:)` copies every local item into the real backend via `create`, and removes
//   each local item only after the backend accepted it. Items the backend refuses stay local (still labelled 本机).

// Codex P0-2: the library is per account. Signed in → persisted in that user's L2SecureStore (encrypted, per-user
// directory); signed out → an empty in-memory guest library. Migration only moves items into the SAME owner's cloud.
@MainActor enum MemoryLibraryLocal {
    /// Pre-fix global plaintext file (no owner). Deleted on activation; never migrated to any account.
    static let legacyFileName = "catpaw-local-memory.v1.json"
    static var legacyFileURL: URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?.appendingPathComponent(legacyFileName)
    }
    static func removeLegacyPlaintext() { if let url = legacyFileURL { try? FileManager.default.removeItem(at: url) } }
    /// The active account's on-device library.
    static private(set) var shared = MemoryLibraryStub()
    /// Bind the library to `owner` (nil = guest, memory only). Idempotent for the same owner.
    static func activate(owner: String?, storage: MemoryLibraryStorage?) {
        if owner != nil, shared.owner == owner { return }
        shared = owner == nil ? MemoryLibraryStub() : MemoryLibraryStub(storage: storage, owner: owner)
    }
    /// Sign-out: erase the account's copy and fall back to an empty guest library.
    static func signOut() { shared.erase(); shared = MemoryLibraryStub() }

    struct MigrationReport: Equatable, Sendable { var migrated = 0; var kept = 0; var deduped = 0; var stoppedBy: MemoryLibraryError? }

    /// Copy local items into `target` (oldest first), idempotently:
    /// - content dedupe: an item whose text already exists in the target is not created again (a crash between create and
    ///   local forget therefore never duplicates on the next run);
    /// - an empty id from `create` counts as failure (local copy kept);
    /// - local 「使用记忆」 off is carried over (`setUseMemory(false)` after all creates; unsupported is ignored).
    static func migrate(_ local: MemoryLibraryStub, to target: any MemoryLibraryBackend, owner: String? = nil) async -> MigrationReport {
        var report = MigrationReport()
        // Codex P0-2: items move only into the cloud library of the account that wrote them.
        guard local.owner == owner else { report.kept = local.items.count; report.stoppedBy = .failed("owner_mismatch"); return report }
        guard target !== local, !local.items.isEmpty else { report.kept = local.items.count; return report }
        var existing: Set<String>
        do { existing = Set(try await target.load().items.map { normalize($0.content) }) }
        catch { report.stoppedBy = (error as? MemoryLibraryError) ?? .failed(String(describing: error)); report.kept = local.items.count; return report }
        // 「使用记忆」 off is applied LAST: the server rejects POST /items with 409 memory_consent_required while off.
        let carryOff = (try? await local.load()).map { !$0.useMemory } ?? false
        for item in local.items.reversed() {
            do {
                let key = normalize(item.content)
                if !existing.contains(key) {
                    let id = try await target.create(kind: item.group.kind, content: item.content)
                    guard !id.trimmingCharacters(in: .whitespaces).isEmpty else { throw MemoryLibraryError.failed("empty id from create") }
                    existing.insert(key)
                } else { report.deduped += 1 }
                try await local.forget(ids: [item.id]); report.migrated += 1
            } catch {
                report.stoppedBy = (error as? MemoryLibraryError) ?? .failed(String(describing: error))
                break
            }
        }
        if carryOff { try? await target.setUseMemory(false) }
        report.kept = local.items.count
        return report
    }
    static func normalize(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "") }
    /// Install the local library as the page backend only when the cloud is not usable at all (gate off) and accepted
    /// nothing; a partial failure keeps the cloud library in place (local leftovers retry next launch).
    static func shouldSurfaceLocal(_ r: MigrationReport) -> Bool {
        guard r.kept > 0, r.migrated == 0, let e = r.stoppedBy else { return false }
        return e == .notEnabled || e == .unsupported
    }
}

/// Settings › 记忆 when no backend is installed and nothing is stored locally: honest 未开通, never sample data.
@MainActor final class MemoryLibraryNotEnabled: MemoryLibraryBackend {
    var capabilities: MemoryLibraryCapabilities { [] }
    func load() async throws -> MemoryLibrarySnapshot { throw MemoryLibraryError.notEnabled }
    func update(id: String, content: String) async throws { throw MemoryLibraryError.notEnabled }
    func forget(ids: [String]) async throws { throw MemoryLibraryError.notEnabled }
    func setUseMemory(_ on: Bool) async throws { throw MemoryLibraryError.notEnabled }
    func setAutoSave(_ on: Bool) async throws { throw MemoryLibraryError.notEnabled }
    func clearAll() async throws { throw MemoryLibraryError.notEnabled }
    func undoSave(memoryID: String, undoToken: String?) async throws { throw MemoryLibraryError.notEnabled }
}

extension MemoryGroup {
    /// Kind written back to a backend on migration (`fact` is folded into profile on read).
    var kind: String { rawValue }
}
