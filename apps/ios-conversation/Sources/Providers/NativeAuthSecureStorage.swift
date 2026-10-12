import Foundation
import Security

/// One project session, iOS Keychain only. No account password, sync or shared group.
public final class NativeAuthKeychainVault: NativeAuthVault, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()
    public init(service: String, issuer: String) { self.service = service; account = textHash(issuer) }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false] }
    public func load() throws -> NativeAuthCredential? {
        lock.lock(); defer { lock.unlock() }
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count < 32768 else { throw NativeAuthError.storage }
        do { return try JSONDecoder().decode(NativeAuthCredential.self, from: data) } catch { throw NativeAuthError.storage }
    }
    public func save(_ credential: NativeAuthCredential) throws {
        lock.lock(); defer { lock.unlock() }
        let data: Data
        do { data = try JSONEncoder().encode(credential) } catch { throw NativeAuthError.storage }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NativeAuthError.storage }
        guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw NativeAuthError.storage }
    }
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeAuthError.storage }
    }
}
/// Durable public logout marker fences a failed Keychain deletion across restart.
public final class NativeAuthFileLogoutBarrier: NativeAuthLogoutBarrier, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }
    public func isSignedOut() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) { return false }
        guard let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8), ["signed_out", "signed_in"].contains(value) else { throw NativeAuthError.storage }
        return value == "signed_out"
    }
    public func setSignedOut(_ value: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((value ? "signed_out" : "signed_in").utf8).write(to: url, options: .atomic)
        } catch { throw NativeAuthError.storage }
    }
}
