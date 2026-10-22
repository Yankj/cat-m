import Foundation

public protocol SnapshotPersistence: Sendable {
    func load() throws -> StoreSnapshot
    func save(_ snapshot: StoreSnapshot) throws
}
public struct FilePersistence: SnapshotPersistence {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> StoreSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return StoreSnapshot() }
        let s = try JSONDecoder().decode(StoreSnapshot.self, from: Data(contentsOf: url))
        guard s.schemaVersion == 1 else { throw catError.corrupt("数据版本不支持，已保留原文件。") }
        return s
    }
    public func save(_ snapshot: StoreSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
public actor Repository {
    private let persistence: any SnapshotPersistence
    private var snapshot: StoreSnapshot
    private var observers: [UUID: (Set<DataScope>, AsyncStream<CommitNotice>.Continuation)] = [:]
    public init(persistence: any SnapshotPersistence) throws {
        self.persistence = persistence
        let loaded = try persistence.load()
        try Self.validate(loaded)
        snapshot = loaded
    }
    public func read(scope: DataScope) -> StoreSnapshot {
        var scoped = snapshot
        scoped.records = snapshot.records.filter { $0.value.header.scope == scope }
        scoped.journal = snapshot.journal.filter { $0.value.scope == scope }
        return scoped
    }
    /// Live preference records whose key starts with `prefix`, across scopes (at-rest migration only).
    public func preferenceRecords(keyPrefix prefix: String) -> [StoredRecord] {
        snapshot.records.values.filter { r in
            guard r.header.deletedAt == nil, case .preference(let p) = r.payload else { return false }
            return p.key.hasPrefix(prefix)
        }.sorted { $0.header.id.uuidString < $1.header.id.uuidString }
    }
    public func record(_ id: UUID, scope: DataScope) throws -> StoredRecord {
        guard let r = snapshot.records[id], r.header.deletedAt == nil else { throw catError.missing }
        guard r.header.scope == scope else { throw catError.scopeMismatch }
        return r
    }
    @discardableResult public func commit(operationID: UUID = UUID(), scope: DataScope, mutations: [Mutation], now: Date = Date()) throws -> CommitNotice {
        let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
        let fingerprint = bytesHash(try canonical.encode(mutations))
        if let old = snapshot.journal[operationID] {
            guard old.scope == scope, old.fingerprint == fingerprint else { throw catError.invalid("重复操作的内容不一致。") }
            return CommitNotice(operationID: operationID, scope: scope, sequence: old.sequence, recordIDs: old.recordIDs)
        }
        var candidate = snapshot
        var ids: [UUID] = []
        for m in mutations {
            switch m {
            case .requireRevision(let id, let revision):
                let record = try checked(id, revision, scope, candidate)
                guard record.header.deletedAt == nil else { throw catError.conflict }
            case .create(let id, let payload):
                guard candidate.records[id] == nil else { throw catError.conflict }
                let h = RecordHeader(id: id, scope: scope, revision: 1, createdAt: now, updatedAt: now, deletedAt: nil, origin: scope.profileID == Profiles.demo.profileID ? .fixtureSeed : .userLocal, providerID: nil, providerObjectID: nil, evidenceIDs: [])
                candidate.records[id] = StoredRecord(header: h, payload: payload); ids.append(id)
            case .update(let id, let revision, let payload):
                var r = try checked(id, revision, scope, candidate)
                guard r.header.deletedAt == nil, r.payload.kind == payload.kind else { throw catError.conflict }
                r.payload = payload; r.header.revision += 1; r.header.updatedAt = now
                candidate.records[id] = r; ids.append(id)
            case .remove(let id, let revision):
                var r = try checked(id, revision, scope, candidate)
                r.header.deletedAt = now; r.header.updatedAt = now; r.header.revision += 1
                candidate.records[id] = r; ids.append(id)
            case .restore(let id, let revision):
                var r = try checked(id, revision, scope, candidate)
                r.header.deletedAt = nil; r.header.updatedAt = now; r.header.revision += 1
                candidate.records[id] = r; ids.append(id)
            }
        }
        try Self.validate(candidate)
        candidate.sequence += 1
        candidate.journal[operationID] = JournalEntry(scope: scope, fingerprint: fingerprint, sequence: candidate.sequence, recordIDs: ids)
        // Candidate value is discarded on any storage error. Only durable save emits a notice.
        try persistence.save(candidate)
        snapshot = candidate
        let notice = CommitNotice(operationID: operationID, scope: scope, sequence: candidate.sequence, recordIDs: ids)
        for (_, pair) in observers where pair.0.contains(scope) { pair.1.yield(notice) }
        return notice
    }
    private func checked(_ id: UUID, _ revision: Int, _ scope: DataScope, _ state: StoreSnapshot) throws -> StoredRecord {
        guard let r = state.records[id] else { throw catError.missing }
        guard r.header.scope == scope else { throw catError.scopeMismatch }
        guard r.header.revision == revision else { throw catError.conflict }
        return r
    }
    private static func validate(_ s: StoreSnapshot) throws {
        guard s.schemaVersion == 1 else { throw catError.corrupt("未知数据版本；保留存储，停止写入。") }
        for r in s.records.values {
            var refs: [UUID] = []
            if let parent = r.payload.parentID { refs.append(parent) }
            switch r.payload {
            case .core(.conversation(let c)):
                refs += [c.environmentID] + [c.projectID, c.expertID].compactMap { $0 } + c.skillIDs
                if let environment = s.records[c.environmentID], case .core(.environment(let e)) = environment.payload {
                    guard Profiles.inEnvironment(e.kind, profile: r.header.scope) == r.header.scope else { throw catError.scopeMismatch }
                }
            case .core(.project(let p)): refs += p.documentIDs + [p.defaultExpertID].compactMap { $0 } + p.skillIDs
            case .core(.task(let t)): refs += [t.environmentID] + t.results.map(\.documentID)
            case .core(.document(let d)): refs += d.ownerIDs
            case .delegation(let d): refs += d.sourceIDs
            case .memory(let m): refs += [m.scopeID] + [m.sourceUserMessageID].compactMap { $0 }
            case .requestConfiguration(let c): refs += [c.userMessageID, c.environmentID] + [c.projectID].compactMap { $0 } + Array(c.expertRevisions.keys) + Array(c.skillRevisions.keys)
            case .artifact(let a): refs += [a.documentReference.documentID, a.generatedFromRunID]
            case .run(let run): refs += [run.taskID] + run.artifactIDs
            case .action(let a): refs += [a.document.documentID]
            case .viewReceipt(let receipt):
                guard receipt.userID == r.header.scope.profileID,
                      let version = s.records[stableID("\(receipt.document.documentID)-v\(receipt.document.version)")],
                      case .core(.documentVersion(let value)) = version.payload,
                      value.contentHash == receipt.document.contentHash else { throw catError.scopeMismatch }
                refs += [receipt.document.documentID, version.id]
            case .voiceEdit(let receipt):
                guard receipt.turn.scope == r.header.scope, case .document(let target) = receipt.turn.target,
                      target.documentID == receipt.result.documentID, receipt.result.version == target.version + 1,
                      textHash(receipt.turn.transcript.submittedText) == receipt.turn.transcript.submittedTextHash,
                      let old = s.records[stableID("\(target.documentID)-v\(target.version)")], case .core(.documentVersion(let original)) = old.payload, original.contentHash == target.contentHash,
                      let next = s.records[stableID("\(receipt.result.documentID)-v\(receipt.result.version)")], case .core(.documentVersion(let revised)) = next.payload, revised.contentHash == receipt.result.contentHash,
                      receipt.draftHash == revised.contentHash else { throw catError.scopeMismatch }
                refs += [target.documentID, stableID("\(target.documentID)-v\(target.version)"), stableID("\(receipt.result.documentID)-v\(receipt.result.version)")]
            default: break
            }
            for id in refs {
                guard let p = s.records[id], p.header.scope == r.header.scope else { throw catError.scopeMismatch }
            }
            if let parent = r.payload.parentID {
                let expected = r.payload.kind == "message" || r.payload.kind == "task" || r.payload.kind == "requestConfiguration" ? "conversation" : r.payload.kind == "documentVersion" ? "document" : "delegation"
                guard s.records[parent]?.payload.kind == expected else { throw catError.invalid("关联记录类型不匹配。") }
            }
            if case .memory(let memory) = r.payload, memory.scopeKind == .delegation {
                guard s.records[memory.scopeID]?.payload.kind == "delegation" else { throw catError.invalid("记忆必须属于当前分区的委托。") }
            }
            if case .core(.task(let task)) = r.payload {
                guard s.records[task.conversationID]?.conversation?.environmentID == task.environmentID else { throw catError.scopeMismatch }
            }
        }
        var unresolved: [String: Int] = [:]
        for r in s.records.values where r.header.deletedAt == nil {
            if case .action(let a) = r.payload, [.accepted, .unknown, .dispatchCommitted].contains(a.receipt) {
                let key = "\(r.header.scope.workspaceID):\(a.document.documentID)"
                unresolved[key, default: 0] += 1
                guard unresolved[key] == 1 else { throw catError.invalid("该成果已有待核验操作，不能重复受理。") }
            }
        }
    }
    public func changes(scope: DataScope, after sequence: Int64, includeProfilePreferences: Bool = false) -> AsyncStream<CommitNotice> {
        let id = UUID()
        let scopes: Set<DataScope> = includeProfilePreferences ? [scope, ProfilePreferences.scope(scope.profileID)] : [scope]
        return AsyncStream { c in
            observers[id] = (scopes, c)
            for (op, j) in snapshot.journal.filter({ scopes.contains($0.value.scope) && $0.value.sequence > sequence }).sorted(by: { $0.value.sequence < $1.value.sequence }) {
                c.yield(CommitNotice(operationID: op, scope: j.scope, sequence: j.sequence, recordIDs: j.recordIDs))
            }
            c.onTermination = { [weak self] _ in
                guard let repository = self else { return }
                Task { await repository.removeObserver(id) }
            }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    public func resetDemo() throws {
        var candidate = snapshot
        candidate.records = candidate.records.filter { $0.value.header.scope.profileID != Profiles.demo.profileID }
        candidate.journal = candidate.journal.filter { $0.value.scope.profileID != Profiles.demo.profileID }
        candidate.sequence += 1
        try persistence.save(candidate); snapshot = candidate
    }
    public func exportProfile(scope: DataScope) throws -> Data { try JSONEncoder().encode(read(scope: scope)) }
    public func referencedBlobs() -> Set<String> { Set(snapshot.records.values.compactMap { if case .core(.documentVersion(let v)) = $0.payload { return v.privateBlobReference }; return nil }) }
    public func setPreference(scope: DataScope, key: String, value: String) throws {
        let scope = ProfilePreferences.destination(scope, key: key)
        if key == "language", AppLanguage(rawValue: value) == nil { throw catError.invalid("界面语言不支持。") }
        let id = stableID("preference-\(scope.workspaceID)-\(key)")
        let payload = Payload.preference(Preference(key: key, value: value))
        if let old = snapshot.records[id] { try commit(scope: scope, mutations: [.update(id, old.header.revision, payload)]) }
        else { try commit(scope: scope, mutations: [.create(id, payload)]) }
    }
    public func profilePreferences(profileID: UUID) -> [String: String] {
        let canonical = ProfilePreferences.scope(profileID)
        // Compatibility read: a canonical value wins; otherwise newest legacy workspace value wins.
        // Old bytes are retained and conversation snapshots are never rewritten.
        let records = snapshot.records.values.filter { $0.header.scope.profileID == profileID && $0.header.deletedAt == nil }.sorted {
            let a = $0.header.scope == canonical, b = $1.header.scope == canonical
            if a != b { return a }
            if $0.header.updatedAt != $1.header.updatedAt { return $0.header.updatedAt > $1.header.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [String: String] = [:]
        for record in records { if case .preference(let p) = record.payload, ProfilePreferences.keys.contains(p.key), result[p.key] == nil { result[p.key] = p.value } }
        return result
    }
    public func saveDraftsAtomically(scope: DataScope, drafts: [UUID: String]) throws {
        var mutations: [Mutation] = []
        for id in drafts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let r = try record(id, scope: scope)
            guard var conversation = r.conversation else { throw catError.missing }
            conversation.draftText = drafts[id]!
            mutations.append(.update(id, r.header.revision, .core(.conversation(conversation))))
        }
        if !mutations.isEmpty { try commit(scope: scope, mutations: mutations) }
    }
}
