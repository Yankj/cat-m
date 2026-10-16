import Foundation
#if os(iOS) && !MEMORY_PORTABLE
import UserNotifications
#endif

/// Who a local memory library belongs to (Codex P0-2). Never shared between accounts.
enum LocalMemoryOwner: Equatable, Hashable, Codable, Sendable {
    /// Lower-cased auth user id.
    case account(String)
    /// Explicit guest (no session): in-memory only, never persisted, never uploaded.
    case guest
}

/// Where a library's snapshot is stored. App: sealed L2 record (AES-GCM, per-user key); tests: in memory.
protocol MemorySnapshotPersisting: AnyObject {
    func read() -> Data?
    func write(_ data: Data) throws
    func erase()
}
final class InMemorySnapshotPersistence: MemorySnapshotPersisting {
    private var data: Data?
    init() {}
    func read() -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func erase() { data = nil }
}
/// Plain file (tests / legacy init only — the app never uses it for account data).
final class FileSnapshotPersistence: MemorySnapshotPersisting {
    let url: URL
    init(url: URL) { self.url = url }
    func read() -> Data? { try? Data(contentsOf: url) }
    func write(_ data: Data) throws { try data.write(to: url, options: [.atomic]) }
    func erase() { try? FileManager.default.removeItem(at: url) }
}

/// Everything account-scoped that lives outside L2 and must go at sign-out (Codex P0-2).
enum AccountLocalData {
    /// Proactive inbox/dedupe ledger/ops/suggestions, undelivered device-call results and undo reports.
    static let userDefaultsKeys = ["catpaw.proactive.inbox.v1", "catpaw.proactive.ledger.v1", "catpaw.proactive.ops.v1", "catpaw.proactive.suggestions.v1",
                                   "catpaw.devicecall.records.v1", "catpaw.devicecall.undos.v1"]
    static func purge(defaults: UserDefaults) { for k in userDefaultsKeys { defaults.removeObject(forKey: k) } }
}

// NoBug P0-1 + Codex P0-2: the on-device memory library used when cloud agent-memory is 未开通 (gate off / not enrolled).
// - One library per account (sealed L2 record), or the explicit in-memory guest; switching accounts switches libraries.
// - Starts EMPTY. Sample memories exist only in Previews/tests (`MemoryLibraryStub.sample`).
// - When the cloud gate opens, `migrate(_:to:targetOwner:)` copies local items into the SAME account's backend only.
@MainActor enum MemoryLibraryLocal {
    /// Pre-P0-2 global file. Its owner is unknown, so it is deleted, never migrated.
    static let legacyFileName = "catpaw-local-memory.v1.json"
    /// The active account's library (guest, in memory, while signed out).
    static private(set) var shared = MemoryLibraryStub(owner: .guest)

    /// Bind the local library to `owner`. Same owner → no-op; another owner → a different library (B never sees A).
    static func activate(owner: LocalMemoryOwner, persistence: (any MemorySnapshotPersisting)?) {
        guard shared.owner != owner || (persistence != nil && shared.persistence !== persistence) else { return }
        shared = MemoryLibraryStub(owner: owner, persistence: owner == .guest ? nil : persistence)
    }
    /// Sign-out: erase that account's local memory and fall back to an empty guest.
    static func purge(owner: LocalMemoryOwner) {
        if shared.owner == owner { shared.erase() }
        shared = MemoryLibraryStub(owner: .guest)
    }

    struct MigrationReport: Equatable, Sendable { var migrated = 0; var kept = 0; var deduped = 0; var stoppedBy: MemoryLibraryError? }

    /// Copy local items into `target` (oldest first), idempotently:
    /// - content dedupe: an item whose text already exists in the target is not created again (a crash between create and
    ///   local forget therefore never duplicates on the next run);
    /// - an empty id from `create` counts as failure (local copy kept);
    /// - local 「使用记忆」 off is carried over (`setUseMemory(false)` after all creates; unsupported is ignored).
    static func migrate(_ local: MemoryLibraryStub, to target: any MemoryLibraryBackend, targetOwner: LocalMemoryOwner) async -> MigrationReport {
        var report = MigrationReport()
        guard target !== local, !local.items.isEmpty else { report.kept = local.items.count; return report }
        // Codex P0-2: only the original owner's own cloud library may receive these items; guest data is never uploaded.
        guard case .account = targetOwner, local.owner == targetOwner else { report.stoppedBy = .failed("owner_mismatch"); report.kept = local.items.count; return report }
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

#if !MEMORY_PORTABLE
/// Sealed per-account record in the signed-in user's L2 store (AES-GCM, Keychain key, wiped at sign-out).
final class L2MemorySnapshotPersistence: MemorySnapshotPersisting {
    static let recordKey = "memory.local-library.v2"
    let store: L2SecureStore
    init(store: L2SecureStore) { self.store = store }
    func read() -> Data? { store.data(forKey: Self.recordKey) }
    func write(_ data: Data) throws {
        store.set(data, forKey: Self.recordKey)
        guard store.data(forKey: Self.recordKey) == data else { throw CocoaError(.fileWriteUnknown) }
    }
    func erase() { store.set(nil, forKey: Self.recordKey) }
}

extension MemoryLibraryLocal {
    /// App entry (after `L2SecureStore.activate`): account → its sealed library; nil → in-memory guest.
    static func activate(userID: UUID?) {
        removeLegacyFile()
        guard let userID else { activate(owner: .guest, persistence: nil); return }
        let owner = LocalMemoryOwner.account(userID.uuidString.lowercased())
        let store = L2SecureStore.current?.userID == userID ? L2SecureStore.current : nil
        // A page backend still pointing at another account's local library must not survive the switch.
        if let stub = MemoryLibraryHub.backend as? MemoryLibraryStub, stub.owner != owner { MemoryLibraryHub.install(backend: nil) }
        if shared.owner == owner && (shared.isPersistent || store == nil) { return }
        let previous = shared
        activate(owner: owner, persistence: store.map(L2MemorySnapshotPersistence.init(store:)))
        // Same account, L2 became ready after the cloud backend: keep what was written in memory meanwhile.
        if previous.owner == owner, !previous.isPersistent, !previous.items.isEmpty, shared.items.isEmpty {
            try? shared.adopt(previous.currentSnapshot)
        }
    }
    static func removeLegacyFile() {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(legacyFileName))
    }
}

extension AccountLocalData {
    /// Sign-out (Codex P0-2): local memory, proactive items + scheduled notifications, undelivered device reports.
    @MainActor static func signOut(userID: UUID?) {
        if let userID { MemoryLibraryLocal.purge(owner: .account(userID.uuidString.lowercased())) } else { MemoryLibraryLocal.purge(owner: .guest) }
        MemoryLibraryHub.reset()
        DeviceCallStore.shared.reset()
        purge(defaults: .standard)
        ProactiveSuggestionStore.shared.clearForSignOut()
        #if os(iOS)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        CatpawWidgetSnapshotWriter.write([])
        #endif
    }
}
#endif
