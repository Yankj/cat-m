import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// Where an L2 store gets its 256-bit key. App: Keychain (ThisDeviceOnly, never synced). Tests: an injectable stand-in,
/// so the real AES-GCM sealing, files and wipe run in portable tests (Codex PR91 review: no InMemory-only evidence).
protocol L2KeyProviding: AnyObject, Sendable {
    func loadOrCreateKey(account: String) throws -> SymmetricKey
    func deleteKey(account: String)
}

/// L2 on-device memory (docs: catpaw-design/memory-layers.md).
/// Per-user directory, every record sealed with AES-GCM; the key comes from `L2KeyProviding` (Keychain in the app).
/// Files use `.completeFileProtection` (proactive records: `.completeFileProtectionUntilFirstUserAuthentication`, R2 P1-1) and are excluded from backup.
/// `wipe(userID:)` deletes the directory and the key (crypto-shred), called at sign-out.
final class L2SecureStore: @unchecked Sendable {
    /// The store of the signed-in user; `nil` while signed out or when the key/directory is unavailable
    /// (callers then refuse durable writes instead of pretending — Codex PR91 #6).
    @MainActor static private(set) var current: L2SecureStore? { didSet { sealingLock.lock(); sealingStore = current; sealingLock.unlock() } }
    /// Nonisolated mirror of `current` for off-main sealers (SwiftData memory rows).
    private static let sealingLock = NSLock()
    private static var sealingStore: L2SecureStore?
    static var currentForSealing: L2SecureStore? { sealingLock.lock(); defer { sealingLock.unlock() }; return sealingStore }
    /// Key provider used by `activate` / `wipe` (tests swap in a stand-in).
    @MainActor static var keys: any L2KeyProviding = L2SecureStore.defaultKeys
    /// Root directory used by `activate` / `wipe` (tests point it at a temp dir).
    @MainActor static var rootDirectory: URL = L2SecureStore.defaultRoot

    let userID: UUID
    private let directory: URL
    private let key: SymmetricKey
    private let lock = NSLock()

    static let service = "catpaw.l2.v1"
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatpawM-L2", isDirectory: true)
    }
    static var defaultKeys: any L2KeyProviding {
        #if canImport(Security)
        KeychainL2KeyProvider()
        #else
        EphemeralL2KeyProvider()
        #endif
    }
    static func directory(for userID: UUID, root: URL) -> URL {
        root.appendingPathComponent(userID.uuidString.lowercased(), isDirectory: true)
    }

    init(userID: UUID, root: URL = L2SecureStore.defaultRoot, keys: any L2KeyProviding = L2SecureStore.defaultKeys) throws {
        self.userID = userID
        self.key = try keys.loadOrCreateKey(account: userID.uuidString.lowercased())
        self.directory = Self.directory(for: userID, root: root)
        #if os(iOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])   // R2 P1-1: every record sets its own class on write (memory: .complete); the directory default only must not block background writes of .untilFirstUnlock records while locked
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)   // directories created by 4094ad94 builds
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
        #if canImport(Darwin)
        var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }

    /// Activates the store for a user (or clears it with `nil`). Idempotent.
    @MainActor static func activate(userID: UUID?) {
        guard current?.userID != userID else { return }
        current = userID.flatMap { try? L2SecureStore(userID: $0, root: rootDirectory, keys: keys) }
    }

    // MARK: Records (one sealed file per key)
    func data(forKey name: String) -> Data? {
        if case .value(let d) = read(forKey: name) { return d }
        return nil
    }

    /// v1.1 R2 (NoBug P1-1): tells "no record" apart from "a record exists but can't be read right now" (device locked
    /// before first unlock / Data Protection, permissions, I/O error). Callers must not write or delete on `.unreadable`,
    /// or a read-modify-write would replace (or an empty value delete) data it never saw.
    /// A record that reads but no longer opens with this key (crypto-shredded / corrupt) is reported `.missing`: it is
    /// unrecoverable, so it must not block new writes forever.
    func read(forKey name: String) -> L2ReadResult {
        lock.lock(); defer { lock.unlock() }
        let target = url(name)
        let sealed: Data
        do { sealed = try Data(contentsOf: target) } catch {
            return FileManager.default.fileExists(atPath: target.path) ? .unreadable : .missing
        }
        guard let plain = try? openSealed(sealed) else { return .missing }
        return .value(plain)
    }

    /// Writes (or deletes with `nil`) one sealed record. Throws when sealing or the disk write fails (Codex PR91 #7).
    /// `protection`: `.complete` (default; memory) or `.untilFirstUnlock` for records that background work (BGAppRefresh,
    /// lock-screen notification actions) must read and write while the device is locked (proactive, NoBug P1-1).
    func write(_ value: Data?, forKey name: String, protection: L2Protection = .complete) throws {
        lock.lock(); defer { lock.unlock() }
        let target = url(name)
        guard let value else {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            return
        }
        let combined = try seal(value)
        #if os(iOS)
        let fileClass: Data.WritingOptions = protection == .untilFirstUnlock ? .completeFileProtectionUntilFirstUserAuthentication : .completeFileProtection
        try combined.write(to: target, options: [.atomic, fileClass])
        #else
        try combined.write(to: target, options: [.atomic])
        #endif
    }
    /// Test seam: the on-disk file of one record (to simulate an unreadable record).
    func fileURL(forKey name: String) -> URL { url(name) }
    /// Best-effort write for caches that can be rebuilt (generative blocks); durable data uses `write` / `put`.
    func set(_ value: Data?, forKey name: String) { try? write(value, forKey: name) }

    func get<T: Decodable>(_ type: T.Type, forKey name: String) -> T? {
        data(forKey: name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    /// Encodes and writes; throws on encode or write failure (never swallowed).
    func put<T: Encodable>(_ value: T?, forKey name: String) throws {
        try write(try value.map { try JSONEncoder().encode($0) }, forKey: name)
    }

    /// AES-GCM with this user's key, for records kept outside the L2 directory (e.g. SwiftData memory snapshots).
    func seal(_ plain: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw L2SecureStoreError.sealFailed }
        return combined
    }
    func openSealed(_ sealed: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: key)
    }

    private func url(_ name: String) -> URL {
        let safe = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(safe + ".l2")
    }

    // MARK: Sign-out
    /// Deletes the user's L2 files and key. Safe to call when nothing exists.
    @MainActor static func wipe(userID: UUID) {
        if current?.userID == userID { current = nil }
        try? FileManager.default.removeItem(at: directory(for: userID, root: rootDirectory))
        keys.deleteKey(account: userID.uuidString.lowercased())
    }
}

enum L2SecureStoreError: Error, Equatable { case keychain(Int32), sealFailed, unavailable }
/// Result of `L2SecureStore.read`: a value, no record, or a record that exists but can't be read now (never treat as empty).
enum L2ReadResult: Equatable { case value(Data), missing, unreadable }
/// File protection class of one record. The Keychain key is already AfterFirstUnlock, so `.untilFirstUnlock` adds no
/// exposure beyond the key itself; it lets background work read/write after the first unlock since boot.
enum L2Protection: Equatable { case complete, untilFirstUnlock }

/// Test / non-Apple stand-in: keys live in memory only (a "keychain" that forgets on process exit).
final class EphemeralL2KeyProvider: L2KeyProviding, @unchecked Sendable {
    private var keys: [String: SymmetricKey] = [:]
    private let lock = NSLock()
    var failNext = false
    init() {}
    func loadOrCreateKey(account: String) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; throw L2SecureStoreError.keychain(-25308) }
        if let k = keys[account] { return k }
        let k = SymmetricKey(size: .bits256); keys[account] = k; return k
    }
    func deleteKey(account: String) { lock.lock(); keys[account] = nil; lock.unlock() }
}

#if canImport(Security)
final class KeychainL2KeyProvider: L2KeyProviding, @unchecked Sendable {
    init() {}
    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: L2SecureStore.service, kSecAttrAccount as String: account]
    }
    func loadOrCreateKey(account: String) throws -> SymmetricKey {
        let base = base(account)
        var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        var add = base
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(base as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw L2SecureStoreError.keychain(status) }
        return key
    }
    func deleteKey(account: String) { SecItemDelete(base(account) as CFDictionary) }
}
#endif
