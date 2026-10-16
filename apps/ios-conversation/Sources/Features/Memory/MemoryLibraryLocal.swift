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

/// Persistence for an account whose L2 store could not be opened (Keychain/disk unavailable): every write throws, so
/// `create` reports failure instead of "saved" and nothing is lost silently on restart (Codex PR91 #6).
final class UnavailableSnapshotPersistence: MemorySnapshotPersisting {
    init() {}
    func read() -> Data? { nil }
    func write(_ data: Data) throws { throw L2SecureStoreError.unavailable }
    func erase() {}
}

/// Everything account-scoped that lives outside L2 and must go at sign-out (Codex P0-2, PR91 #2).
enum AccountLocalData {
    /// Proactive inbox/dedupe ledger/ops/suggestions/attendees/server ids, undelivered device-call results and undo reports.
    static let userDefaultsKeys = ["catpaw.proactive.inbox.v1", "catpaw.proactive.ledger.v1", "catpaw.proactive.ops.v1", "catpaw.proactive.suggestions.v1",
                                   "catpaw.proactive.attendees.v1", "catpaw.proactive.serverids.v1",
                                   "catpaw.devicecall.records.v1", "catpaw.devicecall.undos.v1"]
    static func purge(defaults: UserDefaults) {
        for k in userDefaultsKeys { defaults.removeObject(forKey: k) }
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(MemoryRecallLoader.offKeyPrefix) { defaults.removeObject(forKey: k) }
    }
    /// Portable core of sign-out (the app adds notifications, widget, Live Activity, L2 wipe): first close the session
    /// generation so in-flight work cannot write back, then drop the memory cache, the local library and the keys.
    @MainActor static func signOutCore(userID: UUID?, defaults: UserDefaults) {
        AccountEpoch.shared.signOut()   // FIRST: every token captured before this is dead
        MemoryCache.shared.reset()
        ConversationMemorySwitch.useMemory = nil
        if let userID { MemoryLibraryLocal.purge(owner: .account(userID.uuidString.lowercased())) } else { MemoryLibraryLocal.purge(owner: .guest) }
        purge(defaults: defaults)
    }
}

/// Codex PR91 #3: every memory read path (leadTime, nearby search) goes through here. Fail closed: a cloud load error
/// (other than "no cloud library": not enabled / unsupported) or a local load error yields NO memories, and the last
/// known 「使用记忆」 switch is kept per account so an unknown cloud state never re-opens recall.
@MainActor enum MemoryRecallLoader {
    static let offKeyPrefix = "catpaw.memory.use-off.v1."
    static var defaults: UserDefaults = .standard
    static func offKey(_ owner: LocalMemoryOwner) -> String? {
        if case .account(let id) = owner { return offKeyPrefix + id }
        return nil
    }
    /// Owner of the signed-in account (AccountEpoch keeps the upper-case uuidString; owners use lower-case).
    static var currentOwner: LocalMemoryOwner? { AccountEpoch.shared.currentAccount.map { .account($0.lowercased()) } }
    static func persistedOff(_ owner: LocalMemoryOwner) -> Bool { offKey(owner).map { defaults.bool(forKey: $0) } ?? false }
    /// Codex PR91 p91c-4: the global switch (next turn's X-Catpaw-Use-Memory) from the stored per-account value — at
    /// launch / sign-in and whenever the cloud cannot be read, so a local off whose PATCH failed is still sent.
    static func restoreSwitch(owner: LocalMemoryOwner) {
        guard let k = offKey(owner) else { ConversationMemorySwitch.useMemory = nil; return }
        ConversationMemorySwitch.useMemory = defaults.object(forKey: k) == nil ? nil : !defaults.bool(forKey: k)
    }
    /// Codex PR91 p91d-1: true only while `token` is still the session and `owner` is still the signed-in account.
    static func stillCurrent(_ token: AccountToken?, _ owner: LocalMemoryOwner) -> Bool {
        AccountEpoch.shared.isValid(token) && currentOwner == owner
    }
    /// The user's explicit switch, bound to the owner + token taken when the toggle started. Off is written at once;
    /// on only after the server accepted it (`succeeded`). Nothing is written for an account that is gone.
    @discardableResult static func userChoice(on: Bool, owner: LocalMemoryOwner, token: AccountToken?, succeeded: Bool) -> Bool {
        guard stillCurrent(token, owner) else { return false }
        if !on { record(off: true, owner: owner); return true }
        guard succeeded else { return false }   // a failed ON keeps the sticky off
        record(off: false, owner: owner); return true
    }
    static func record(off: Bool, owner: LocalMemoryOwner) {
        if let k = offKey(owner) { defaults.set(off, forKey: k) }
        ConversationMemorySwitch.useMemory = !off   // sent to the server on the next turn (X-Catpaw-Use-Memory)
    }

    /// `cloud`: the installed backend (nil = none). `local`: the on-device library when it is not the cloud backend.
    static func snapshots(cloud: (any MemoryLibraryBackend)?, local: (any MemoryLibraryBackend)?, owner: LocalMemoryOwner) async -> [MemoryLibrarySnapshot] {
        // Codex PR91 p91d-1: owner + token bound when the recall starts; every write-back below re-checks them.
        let token = AccountEpoch.shared.capture()
        guard token != nil else { return [] }
        var snaps: [MemoryLibrarySnapshot] = []
        var cloudState: Bool? = nil   // nil = no cloud library / unknown
        if let cloud {
            do { let s = try await cloud.load(); snaps.append(s); cloudState = s.useMemory }
            // Codex PR91 p91b-4: a cloud library that is not enabled / unsupported does NOT fall back to local memories.
            // p91c-4: the switch is still restored from the stored value before the fail-closed return.
            // p91d-1: a late failure never overwrites (or clears) the global; only a still-current sticky off is re-applied.
            catch { if stillCurrent(token, owner), persistedOff(owner) { ConversationMemorySwitch.useMemory = false }; return [] }
        }
        if let local {
            do { snaps.append(try await local.load()) } catch { return [] }
        }
        guard stillCurrent(token, owner) else { return [] }   // signed out / switched meanwhile: no write-back
        // p91d-2: an explicit user off is sticky until an explicit user on succeeds — it wins over any cloud snapshot.
        if persistedOff(owner) { ConversationMemorySwitch.useMemory = false; return [] }
        let off = snaps.contains { !$0.useMemory }
        // A cloud/local snapshot only drives the global for this turn; it never writes (or clears) the user's choice.
        if cloudState != nil || cloud == nil { ConversationMemorySwitch.useMemory = !off }
        return MemoryRecallGate.effective(snaps)
    }
}

/// Codex PR91 #4: the pre-P0-2 global plaintext library has no known owner. It is sealed into a device vault (its own
/// AES-GCM key, not any account's, never merged or uploaded) and the plaintext file is deleted ONLY after the sealed copy
/// reads back identical. Any failure keeps the file for the next launch.
enum LegacyMemoryQuarantine {
    static let recordKey = "memory.legacy-quarantine.v1"
    /// Reserved L2 "user" id for the vault (not an auth user; not wiped at sign-out).
    static let vaultID = UUID(uuidString: "00000000-0000-0000-0000-00000000c0de")!
    enum Outcome: Equatable { case nothing, quarantined(Int), failed(String) }
    static func run(legacyFile: URL, vault: (any MemorySnapshotPersisting)?) -> Outcome {
        guard FileManager.default.fileExists(atPath: legacyFile.path) else { return .nothing }
        guard let vault else { return .failed("vault_unavailable") }
        guard let raw = try? Data(contentsOf: legacyFile) else { return .failed("unreadable") }
        var kept: [Data] = []
        if let existing = vault.read() {
            guard let decoded = try? JSONDecoder().decode([Data].self, from: existing) else { return .failed("vault_unreadable") }
            kept = decoded
        }
        if !kept.contains(raw) { kept.append(raw) }
        do {
            let encoded = try JSONEncoder().encode(kept)
            try vault.write(encoded)
            guard vault.read() == encoded else { return .failed("verify_failed") }
            try FileManager.default.removeItem(at: legacyFile)
        } catch { return .failed(String(describing: error)) }
        return .quarantined(kept.count)
    }
    /// Sealed copies kept in the vault (for a future, explicit "restore" flow; never shown to another account).
    static func kept(in vault: any MemorySnapshotPersisting) -> [Data] {
        vault.read().flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? []
    }
}

/// Sealed record in an L2 store (AES-GCM, per-user key, wiped at sign-out). Default key: the per-account local library.
final class L2MemorySnapshotPersistence: MemorySnapshotPersisting {
    static let recordKey = "memory.local-library.v2"
    let store: L2SecureStore
    let key: String
    init(store: L2SecureStore, key: String = L2MemorySnapshotPersistence.recordKey) { self.store = store; self.key = key }
    func read() -> Data? { store.data(forKey: key) }
    func write(_ data: Data) throws {
        try store.write(data, forKey: key)
        guard store.data(forKey: key) == data else { throw CocoaError(.fileWriteUnknown) }
    }
    func erase() { try? store.write(nil, forKey: key) }
}

// NoBug P0-1 + Codex P0-2: the on-device memory library used when cloud agent-memory is 未开通 (gate off / not enrolled).
// - One library per account (sealed L2 record), or the explicit in-memory guest; switching accounts switches libraries.
// - Starts EMPTY. Sample memories exist only in Previews/tests (`MemoryLibraryStub.sample`).
// - When the cloud gate opens, `migrate(_:to:targetOwner:)` copies local items into the SAME account's backend only.
@MainActor enum MemoryLibraryLocal {
    /// Pre-P0-2 global file. Its owner is unknown: sealed into the device vault, never migrated (Codex PR91 #4).
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
        guard target !== local else { report.kept = local.items.count; return report }
        // Codex P0-2: only the original owner's own cloud library may receive these items; guest data is never uploaded.
        guard case .account = targetOwner, local.owner == targetOwner else { report.stoppedBy = .failed("owner_mismatch"); report.kept = local.items.count; return report }
        // Codex PR91 #3: an empty library whose 「使用记忆」 is off still carries the off switch to the cloud.
        if local.items.isEmpty {
            if !local.currentSnapshot.useMemory {
                do { try await target.setUseMemory(false) } catch { report.stoppedBy = (error as? MemoryLibraryError) ?? .failed(String(describing: error)) }
            }
            return report
        }
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
        // Codex PR91 p91b-4: a failed off-carry is reported (local copy of the switch stays, retried next launch).
        if carryOff {
            do { try await target.setUseMemory(false) }
            catch { if report.stoppedBy == nil { report.stoppedBy = (error as? MemoryLibraryError) ?? .failed(String(describing: error)) } }
        }
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
extension MemoryLibraryLocal {
    /// App entry (after `AccountEpoch.shared.activate` + `L2SecureStore.activate`): account → its sealed library (or a library whose
    /// writes fail honestly when L2 is unavailable); nil → in-memory guest.
    static func activate(userID: UUID?) {
        quarantineLegacyFile()
        guard let userID else { activate(owner: .guest, persistence: nil); return }
        let owner = LocalMemoryOwner.account(userID.uuidString.lowercased())
        MemoryRecallLoader.restoreSwitch(owner: owner)   // Codex PR91 p91c-4: header right from launch
        let store = L2SecureStore.current?.userID == userID ? L2SecureStore.current : nil
        // A page backend still pointing at another account's local library must not survive the switch.
        if let stub = MemoryLibraryHub.backend as? MemoryLibraryStub, stub.owner != owner { MemoryLibraryHub.install(backend: nil) }
        if shared.owner == owner, shared.persistence is L2MemorySnapshotPersistence { return }
        if shared.owner == owner, store == nil, shared.persistence is UnavailableSnapshotPersistence { return }
        activate(owner: owner, persistence: store.map { L2MemorySnapshotPersistence(store: $0) } ?? UnavailableSnapshotPersistence())
    }
    /// Codex PR91 p91b-5: export entry for the quarantined pre-P0-2 library (Settings › 记忆 › 旧版记忆).
    /// Returns the kept raw records as text; nil when there is nothing quarantined. Never merged or uploaded.
    static func legacyExportText() -> String? {
        guard let store = try? L2SecureStore(userID: LegacyMemoryQuarantine.vaultID, root: L2SecureStore.rootDirectory, keys: L2SecureStore.keys) else { return nil }
        let kept = LegacyMemoryQuarantine.kept(in: L2MemorySnapshotPersistence(store: store, key: LegacyMemoryQuarantine.recordKey))
        guard !kept.isEmpty else { return nil }
        return kept.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n\n")
    }
    /// Codex PR91 #4: seal the unowned legacy file into the device vault, then delete it (kept on any failure).
    @discardableResult static func quarantineLegacyFile() -> LegacyMemoryQuarantine.Outcome {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return .nothing }
        let file = dir.appendingPathComponent(legacyFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return .nothing }
        let vault = (try? L2SecureStore(userID: LegacyMemoryQuarantine.vaultID, root: L2SecureStore.rootDirectory, keys: L2SecureStore.keys))
            .map { L2MemorySnapshotPersistence(store: $0, key: LegacyMemoryQuarantine.recordKey) }
        return LegacyMemoryQuarantine.run(legacyFile: file, vault: vault)
    }
}

extension AccountLocalData {
    /// Sign-out (Codex P0-2): local memory, proactive items + scheduled notifications, undelivered device reports.
    @MainActor static func signOut(userID: UUID?) {
        // Live Activities are keyed by suggestion id: read the inbox before it is purged.
        for id in ProactiveLocalBackend.load().keys { CatpawLeaveActivity.stop(suggestionID: id) }
        CatpawLeaveActivity.stopAll()
        signOutCore(userID: userID, defaults: .standard)   // generation first, then memory cache + library + keys
        MemoryLibraryHub.reset()
        DeviceCallStore.shared.reset()
        ProactiveFeedbackSync.shared.reset()
        ProactiveEngine.shared.clearForSignOut()           // in-memory log + server ids
        ProactiveLocalBackend.clearForSignOut()            // sealed inbox
        ProactiveSuggestionStore.shared.clearForSignOut()
        #if os(iOS)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        CatpawWidgetSnapshotWriter.write([])
        #endif
    }
}
#endif
