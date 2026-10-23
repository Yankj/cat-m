import Foundation

/// A dedicated encrypted conversation snapshot. No parenting input is written to the main chat repository.
/// A missing file is empty; every unreadable, unsupported or invalid existing file fails closed.
final class ParentingIntakePersistence: SnapshotPersistence, @unchecked Sendable {
    private struct Envelope: Codable {
        var schemaVersion = 1
        let scope: DataScope
        let subjectID: UUID
        let snapshot: StoreSnapshot
    }
    private static let prefix = Data("mimi.parenting-intake.sealed.v1\n".utf8)
    private static let pathLock = NSRecursiveLock()
    private static var pathGenerations: [String: UUID] = [:]
    let url: URL
    private let scope: DataScope
    private let subjectID: UUID
    private let epoch: AccountEpoch
    private let token: AccountToken?
    private let cipher: any ParentingWorkspaceCipher
    private let pathGeneration: UUID
    private let lock = NSRecursiveLock()
    private var loaded = false
    private var expectedFileHash: String?
    private var revoked = false

    init(url: URL, scope: DataScope, subjectID: UUID, epoch: AccountEpoch = .shared,
         cipher: any ParentingWorkspaceCipher = ParentingPersistentCipher()) {
        self.url = url; self.scope = scope; self.subjectID = subjectID; self.epoch = epoch
        token = epoch.capture(); self.cipher = cipher; pathGeneration = Self.generation(for: url)
    }

    func load() throws -> StoreSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try fenced {
            guard FileManager.default.fileExists(atPath: url.path) else { loaded = true; expectedFileHash = nil; return StoreSnapshot() }
            let bytes = try Data(contentsOf: url)
            guard bytes.starts(with: Self.prefix), bytes.count > Self.prefix.count else { throw ParentingInlineIntakeError.storage }
            let plain = try cipher.open(Data(bytes.dropFirst(Self.prefix.count)), subjectID: subjectID)
            let envelope: Envelope
            do { envelope = try JSONDecoder().decode(Envelope.self, from: plain) }
            catch { throw ParentingInlineIntakeError.storage }
            guard envelope.schemaVersion == 1, envelope.scope == scope, envelope.subjectID == subjectID else { throw ParentingInlineIntakeError.storage }
            try validate(envelope.snapshot)
            loaded = true; expectedFileHash = bytesHash(bytes)
            return envelope.snapshot
        }
    }

    func save(_ snapshot: StoreSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        try checkAccount(); try validate(snapshot)
        if !loaded { _ = try load() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(Envelope(scope: scope, subjectID: subjectID, snapshot: snapshot))
        try fenced {
            let currentHash: String?
            if FileManager.default.fileExists(atPath: url.path) { currentHash = bytesHash(try Data(contentsOf: url)) }
            else { currentHash = nil }
            guard currentHash == expectedFileHash else { throw ParentingInlineIntakeError.storage }
            let sealed = try cipher.seal(plain, subjectID: subjectID)
            // Injectable ciphers may invalidate the epoch while sealing. Recheck before touching disk.
            try checkAccount()
            guard Self.pathGenerations[url.standardizedFileURL.path] == pathGeneration, !revoked else { throw ParentingInlineIntakeError.storage }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var output = Self.prefix; output.append(sealed)
            #if os(iOS)
            try output.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try output.write(to: url, options: .atomic)
            #endif
            #if canImport(Darwin)
            var directory = url.deletingLastPathComponent(); var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            #endif
            expectedFileHash = bytesHash(output); loaded = true
        }
    }

    private func checkAccount() throws {
        guard let token, UUID(uuidString: token.account) == subjectID, epoch.isValid(token) else { throw ParentingInlineIntakeError.changedContext }
    }
    func delete(revoke: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        if revoked { return }
        try fenced {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            expectedFileHash = nil; loaded = true; revoked = revoke
            if revoke { Self.pathGenerations[url.standardizedFileURL.path] = UUID() }
        }
    }
    static func deleteTemporaryCopies(scope: DataScope, subjectID: UUID, epoch: AccountEpoch = .shared) throws {
        let token = epoch.capture()
        guard let token, UUID(uuidString: token.account) == subjectID else { throw ParentingInlineIntakeError.changedContext }
        guard try epoch.commit(token, { () throws -> Bool in
            Self.pathLock.lock(); defer { Self.pathLock.unlock() }
            let directory = ParentingIntakePaths.directory(scope: scope, subjectID: subjectID)
            for name in ["journal.sealed", "recovery.sealed"] {
                let url = directory.appendingPathComponent(name)
                if name == "journal.sealed" { Self.pathGenerations[url.standardizedFileURL.path] = UUID() }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            return true
        }) == true else { throw ParentingInlineIntakeError.changedContext }
    }
    static func deleteJournal(at url: URL, subjectID: UUID, epoch: AccountEpoch = .shared) throws {
        let token = epoch.capture()
        guard let token, UUID(uuidString: token.account) == subjectID else { throw ParentingInlineIntakeError.changedContext }
        guard try epoch.commit(token, { () throws -> Bool in
            Self.pathLock.lock(); defer { Self.pathLock.unlock() }
            Self.pathGenerations[url.standardizedFileURL.path] = UUID()
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return true
        }) == true else { throw ParentingInlineIntakeError.changedContext }
    }
    var isCurrentGeneration: Bool { Self.generation(for: url) == pathGeneration }
    private static func generation(for url: URL) -> UUID {
        pathLock.lock(); defer { pathLock.unlock() }
        let path = url.standardizedFileURL.path
        if let current = pathGenerations[path] { return current }
        let value = UUID(); pathGenerations[path] = value; return value
    }
    /// All paths use the same lock order: account epoch, then path generation, then the short I/O.
    private func fenced<T>(_ action: () throws -> T) throws -> T {
        guard let value = try epoch.commit(token, { () throws -> T in
            Self.pathLock.lock(); defer { Self.pathLock.unlock() }
            try checkAccount()
            guard !revoked, Self.pathGenerations[url.standardizedFileURL.path] == pathGeneration else { throw ParentingInlineIntakeError.storage }
            return try action()
        }) else { throw ParentingInlineIntakeError.changedContext }
        return value
    }
    private func validate(_ snapshot: StoreSnapshot) throws {
        guard snapshot.schemaVersion == 1,
              snapshot.records.values.allSatisfy({ $0.header.scope == scope }),
              snapshot.journal.values.allSatisfy({ $0.scope == scope }) else { throw ParentingInlineIntakeError.storage }
    }
}

enum ParentingIntakePaths {
    static func directory(scope: DataScope, subjectID: UUID) -> URL {
        let partition = textHash("\(scope.profileID):\(scope.workspaceID):\(subjectID)")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatpawM-ParentingIntake", isDirectory: true).appendingPathComponent(partition, isDirectory: true)
    }
}

/// Uses the same fail-closed envelope and account barrier as the dedicated conversation journal.
final class ParentingIntakeRecoveryFile: ParentingIntakeRecoveryStoring, @unchecked Sendable {
    private let persistence: ParentingIntakePersistence
    private let scope: DataScope
    private let subjectID: UUID
    private let recordID = stableID("parenting-intake-recovery-reference-v1")
    var exists: Bool { FileManager.default.fileExists(atPath: persistence.url.path) }
    init(scope: DataScope, subjectID: UUID, epoch: AccountEpoch = .shared, cipher: any ParentingWorkspaceCipher = ParentingPersistentCipher(), url: URL? = nil) {
        self.scope = scope; self.subjectID = subjectID
        persistence = ParentingIntakePersistence(url: url ?? ParentingIntakePaths.directory(scope: scope, subjectID: subjectID).appendingPathComponent("recovery.sealed"),
            scope: scope, subjectID: subjectID, epoch: epoch, cipher: cipher)
    }
    func read() throws -> ParentingIntakeRecoveryReference? {
        let snapshot = try persistence.load()
        guard !snapshot.records.isEmpty else { return nil }
        guard snapshot.records.count == 1, let record = snapshot.records[recordID], record.header.deletedAt == nil,
              case .preference(let preference) = record.payload, preference.key == "parenting_inline_recovery:v1",
              let data = preference.value.data(using: .utf8) else { throw ParentingInlineIntakeError.storage }
        let value = try JSONDecoder().decode(ParentingIntakeRecoveryReference.self, from: data)
        guard value.schemaVersion == 1, value.scope == scope, value.subjectID == subjectID else { throw ParentingInlineIntakeError.storage }
        return value
    }
    func save(_ reference: ParentingIntakeRecoveryReference) throws {
        guard reference.schemaVersion == 1, reference.scope == scope, reference.subjectID == subjectID else { throw ParentingInlineIntakeError.storage }
        var snapshot = try persistence.load()
        let old = snapshot.records[recordID]
        let header = RecordHeader(id: recordID, scope: scope, revision: (old?.header.revision ?? 0) + 1,
            createdAt: old?.header.createdAt ?? reference.startedAt, updatedAt: reference.startedAt, deletedAt: nil,
            origin: .userLocal, providerID: nil, providerObjectID: nil, evidenceIDs: [])
        snapshot.records[recordID] = StoredRecord(header: header, payload: .preference(.init(key: "parenting_inline_recovery:v1",
            value: String(decoding: try JSONEncoder().encode(reference), as: UTF8.self))))
        snapshot.sequence += 1
        try persistence.save(snapshot)
    }
    func delete() throws { try persistence.delete(revoke: false) }
}

/// Durable retry queue containing only account partition and conversation identifiers, never source/prompt/token.
final class ParentingIntakeCleanupFile: ParentingIntakeCleanupStoring, @unchecked Sendable {
    private let persistence: ParentingIntakePersistence
    private let scope: DataScope
    private let subjectID: UUID
    private let recordID = stableID("parenting-intake-cleanup-reference-v1")
    var exists: Bool { FileManager.default.fileExists(atPath: persistence.url.path) }
    init(scope: DataScope, subjectID: UUID, epoch: AccountEpoch = .shared, cipher: any ParentingWorkspaceCipher = ParentingPersistentCipher(), url: URL? = nil) {
        self.scope = scope; self.subjectID = subjectID
        persistence = ParentingIntakePersistence(url: url ?? ParentingIntakePaths.directory(scope: scope, subjectID: subjectID).appendingPathComponent("cleanup.sealed"),
            scope: scope, subjectID: subjectID, epoch: epoch, cipher: cipher)
    }
    func read() throws -> [ParentingIntakeCleanupReference] {
        let snapshot = try persistence.load()
        guard !snapshot.records.isEmpty else { return [] }
        guard snapshot.records.count == 1, let record = snapshot.records[recordID], record.header.deletedAt == nil,
              case .preference(let preference) = record.payload, preference.key == "parenting_inline_cleanup:v1" else { throw ParentingInlineIntakeError.storage }
        let values = try JSONDecoder().decode([ParentingIntakeCleanupReference].self, from: Data(preference.value.utf8))
        guard Set(values.map(\.id)).count == values.count, values.allSatisfy({ $0.scope == scope && $0.subjectID == subjectID }) else { throw ParentingInlineIntakeError.storage }
        return values
    }
    func save(_ references: [ParentingIntakeCleanupReference]) throws {
        guard references.allSatisfy({ $0.scope == scope && $0.subjectID == subjectID }) else { throw ParentingInlineIntakeError.storage }
        if references.isEmpty { try persistence.delete(revoke: false); return }
        var snapshot = try persistence.load()
        let old = snapshot.records[recordID]
        let now = Date()
        let header = RecordHeader(id: recordID, scope: scope, revision: (old?.header.revision ?? 0) + 1,
            createdAt: old?.header.createdAt ?? now, updatedAt: now, deletedAt: nil, origin: .userLocal,
            providerID: nil, providerObjectID: nil, evidenceIDs: [])
        snapshot.records[recordID] = StoredRecord(header: header, payload: .preference(.init(key: "parenting_inline_cleanup:v1",
            value: String(decoding: try JSONEncoder().encode(references), as: UTF8.self))))
        snapshot.sequence += 1; try persistence.save(snapshot)
    }
}
