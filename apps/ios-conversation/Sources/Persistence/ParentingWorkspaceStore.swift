import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// Injectable only so offline tests can exercise the real repository and its failure paths.
protocol ParentingWorkspaceCipher: Sendable {
    func seal(_ plain: Data, subjectID: UUID) throws -> Data
    func open(_ sealed: Data, subjectID: UUID) throws -> Data
}

/// Reuses L2's AES-GCM implementation with a separate, persistent key namespace.
/// The ordinary L2 sign-out wipe cannot destroy this parent's local ledger key.
final class ParentingPersistentCipher: ParentingWorkspaceCipher, @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [UUID: L2SecureStore] = [:]
    private let keys: any L2KeyProviding
    private let root: URL

    init() {
        keys = ParentingKeyProvider()
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatpawM-ParentingSealing", isDirectory: true)
    }
    func seal(_ plain: Data, subjectID: UUID) throws -> Data { try store(subjectID).seal(plain) }
    func open(_ sealed: Data, subjectID: UUID) throws -> Data { try store(subjectID).openSealed(sealed) }
    private func store(_ subjectID: UUID) throws -> L2SecureStore {
        lock.lock(); defer { lock.unlock() }
        if let store = stores[subjectID] { return store }
        let store = try L2SecureStore(userID: subjectID, root: root, keys: keys)
        stores[subjectID] = store
        return store
    }
}

/// Never reads, writes or removes the ordinary L2 Keychain service.
private final class ParentingKeyProvider: L2KeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    static let service = "catpaw.parenting.v1"
    func loadOrCreateKey(account: String) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Security)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
        func load() throws -> SymmetricKey? {
            var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw L2SecureStoreError.keychain(status) }
            guard let data = item as? Data, data.count == 32 else { throw catError.corrupt("育儿账本密钥损坏，已停止读写。") }
            return SymmetricKey(data: data)
        }
        if let key = try load() { return key }
        let key = SymmetricKey(size: .bits256)
        var add = base; add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else { throw L2SecureStoreError.keychain(status) }
        return key
        #else
        throw catError.unavailable("当前平台不支持安全保存育儿账本密钥。")
        #endif
    }
    func deleteKey(account: String) {
        #if canImport(Security)
        lock.lock(); defer { lock.unlock() }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                       kSecAttrAccount as String: account] as CFDictionary)
        #endif
    }
}

/// All ledger fields and operation receipts are encrypted together inside one repository preference.
/// Record revision provides repository CAS; workspace revision is the parent's edit revision.
actor ParentingWorkspaceStore {
    private struct Envelope: Codable {
        var schemaVersion = 1
        let scope: DataScope
        let subjectID: UUID
        var workspace: ParentingWorkspace
        var operations: [UUID: String]
    }
    private struct ReadState {
        var envelope: Envelope
        let record: StoredRecord?
    }
    private let repository: Repository
    private let scope: DataScope
    private let subjectID: UUID?
    private let epoch: AccountEpoch
    private let token: AccountToken?
    private let cipher: any ParentingWorkspaceCipher
    private let clock: @Sendable () -> Date
    private static let sealedPrefix = "parenting-sealed-v1:"

    init(repository: Repository, scope: DataScope, subjectID: UUID?, epoch: AccountEpoch = .shared,
         cipher: any ParentingWorkspaceCipher = ParentingPersistentCipher(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository; self.scope = scope; self.subjectID = subjectID; self.epoch = epoch
        self.token = epoch.capture(); self.cipher = cipher; self.clock = clock
    }

    static func preferenceKey(scope: DataScope, subjectID: UUID) -> String {
        "parenting_workspace:v1:" + textHash("\(scope.profileID.uuidString.lowercased()):\(scope.workspaceID.uuidString.lowercased()):\(subjectID.uuidString.lowercased())")
    }
    static func recordID(scope: DataScope, subjectID: UUID) -> UUID {
        stableID("preference-\(scope.workspaceID)-\(preferenceKey(scope: scope, subjectID: subjectID))")
    }

    nonisolated func isCurrentAccount() -> Bool {
        guard let subjectID, let token, UUID(uuidString: token.account) == subjectID else { return false }
        return epoch.isValid(token)
    }

    func load() async throws -> ParentingWorkspace {
        let subject = try authorizedSubject()
        let state = try await read(subject: subject)
        _ = try authorizedSubject()
        return state.envelope.workspace
    }

    func apply(_ command: ParentingCommand, expectedRevision: Int, operationID: UUID = UUID()) async throws -> ParentingWorkspace {
        let subject = try authorizedSubject()
        var state = try await read(subject: subject)
        _ = try authorizedSubject()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = bytesHash(try encoder.encode(command))
        if let prior = state.envelope.operations[operationID] {
            guard prior == fingerprint else { throw catError.invalid("重复操作的内容不一致。") }
            return state.envelope.workspace
        }
        guard state.envelope.workspace.revision == expectedRevision else { throw catError.conflict }
        state.envelope.workspace = try state.envelope.workspace.applying(command, now: clock())
        state.envelope.operations[operationID] = fingerprint
        let plain = try encoder.encode(state.envelope)
        // Key creation and sealing are account-bound persistent work as well.
        guard let sealed = try epoch.commit(token, { try cipher.seal(plain, subjectID: subject) }) else { throw Self.staleAccount() }
        let key = Self.preferenceKey(scope: scope, subjectID: subject)
        let id = Self.recordID(scope: scope, subjectID: subject)
        let payload = Payload.preference(Preference(key: key, value: Self.sealedPrefix + sealed.base64EncodedString()))
        let mutation: Mutation = state.record.map { .update(id, $0.header.revision, payload) } ?? .create(id, payload)
        let repositoryOperationID = stableID("parenting-operation:\(key):\(operationID.uuidString.lowercased())")
        // The final barrier and the synchronous durable save run together inside the Repository actor.
        do {
            try await repository.commitParentingWorkspace(operationID: repositoryOperationID, scope: scope, mutations: [mutation], token: token, epoch: epoch)
        } catch {
            let failure = error
            // Two stores can submit the same operation concurrently. AES-GCM produces fresh bytes,
            // so reconcile the encrypted command receipt instead of comparing repository ciphertext.
            if let latest = try? await read(subject: subject), latest.envelope.operations[operationID] == fingerprint {
                return latest.envelope.workspace
            }
            throw failure
        }
        _ = try authorizedSubject()
        return state.envelope.workspace
    }

    private func read(subject: UUID) async throws -> ReadState {
        let record: StoredRecord
        do { record = try await repository.record(Self.recordID(scope: scope, subjectID: subject), scope: scope) }
        catch catError.missing {
            _ = try authorizedSubject()
            // Empty is legitimate only when no record exists. Unreadable bytes never take this branch.
            return ReadState(envelope: Envelope(scope: scope, subjectID: subject, workspace: .empty, operations: [:]), record: nil)
        }
        _ = try authorizedSubject()
        guard record.header.scope == scope, case .preference(let preference) = record.payload,
              preference.key == Self.preferenceKey(scope: scope, subjectID: subject), preference.value.hasPrefix(Self.sealedPrefix),
              let sealed = Data(base64Encoded: String(preference.value.dropFirst(Self.sealedPrefix.count))), !sealed.isEmpty else {
            throw catError.corrupt("育儿账本存储格式损坏，已保留原数据并停止写入。")
        }
        let plain: Data
        do {
            guard let value = try epoch.commit(token, { try cipher.open(sealed, subjectID: subject) }) else { throw Self.staleAccount() }
            plain = value
        } catch {
            throw catError.corrupt("育儿账本暂时无法解密，已保留原数据并停止写入。")
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: plain) }
        catch { throw catError.corrupt("育儿账本内容损坏，已保留原数据并停止写入。") }
        guard envelope.schemaVersion == 1, envelope.scope == scope, envelope.subjectID == subject,
              envelope.operations.values.allSatisfy({ $0.count == 64 && $0.allSatisfy { $0.isHexDigit } }) else {
            throw catError.corrupt("育儿账本版本或账号分区不符，已停止写入。")
        }
        try envelope.workspace.validate()
        return ReadState(envelope: envelope, record: record)
    }

    private func authorizedSubject() throws -> UUID {
        guard let subjectID, isCurrentAccount() else {
            throw Self.staleAccount()
        }
        return subjectID
    }
    private static func staleAccount() -> catError { .unavailable("当前账号不可用，请重新打开育儿账本。") }
}

extension Repository {
    /// Actor-isolated and synchronous: no suspension can occur between epoch validation and durable save.
    @discardableResult
    func commitParentingWorkspace(operationID: UUID, scope: DataScope, mutations: [Mutation], token: AccountToken?, epoch: AccountEpoch) throws -> CommitNotice {
        guard let notice = try epoch.commit(token, { try self.commit(operationID: operationID, scope: scope, mutations: mutations) }) else {
            throw catError.unavailable("账号已变更，育儿账本未写入。")
        }
        return notice
    }
}
