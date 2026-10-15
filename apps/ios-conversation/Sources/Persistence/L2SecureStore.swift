import CryptoKit
import Foundation
import Security

/// L2 on-device memory (docs: catpaw-design/memory-layers.md).
/// Per-user directory, every record sealed with AES-GCM; the 256-bit key lives in the Keychain
/// (ThisDeviceOnly, never synced). Files use `.completeFileProtection` and are excluded from backup.
/// `wipe(userID:)` deletes the directory and the key (crypto-shred), called at sign-out.
final class L2SecureStore: @unchecked Sendable {
    /// The store of the signed-in user; `nil` while signed out (callers then keep data in memory only).
    @MainActor static private(set) var current: L2SecureStore?

    let userID: UUID
    private let directory: URL
    private let key: SymmetricKey
    private let lock = NSLock()

    private static let service = "catpaw.l2.v1"
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatpawM-L2", isDirectory: true)
    }
    private static func directory(for userID: UUID) -> URL {
        root.appendingPathComponent(userID.uuidString.lowercased(), isDirectory: true)
    }

    init(userID: UUID) throws {
        self.userID = userID
        self.key = try Self.loadOrCreateKey(account: userID.uuidString.lowercased())
        self.directory = Self.directory(for: userID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var url = Self.root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Activates the store for a user (or clears it with `nil`). Idempotent.
    @MainActor static func activate(userID: UUID?) {
        guard current?.userID != userID else { return }
        current = userID.flatMap { try? L2SecureStore(userID: $0) }
    }

    // MARK: Records (one sealed file per key)
    func data(forKey name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let sealed = try? Data(contentsOf: url(name)),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    func set(_ value: Data?, forKey name: String) {
        lock.lock(); defer { lock.unlock() }
        let target = url(name)
        guard let value else { try? FileManager.default.removeItem(at: target); return }
        guard let combined = try? AES.GCM.seal(value, using: key).combined else { return }
        try? combined.write(to: target, options: [.atomic, .completeFileProtection])
    }

    func get<T: Decodable>(_ type: T.Type, forKey name: String) -> T? {
        data(forKey: name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    func put<T: Encodable>(_ value: T?, forKey name: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: name)
    }

    private func url(_ name: String) -> URL {
        let safe = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(safe + ".l2")
    }

    // MARK: Sign-out
    /// Deletes the user's L2 files and Keychain key. Safe to call when nothing exists.
    @MainActor static func wipe(userID: UUID) {
        if current?.userID == userID { current = nil }
        try? FileManager.default.removeItem(at: directory(for: userID))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: userID.uuidString.lowercased()]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Keychain
    private static func loadOrCreateKey(account: String) throws -> SymmetricKey {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
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
}

enum L2SecureStoreError: Error { case keychain(OSStatus) }
