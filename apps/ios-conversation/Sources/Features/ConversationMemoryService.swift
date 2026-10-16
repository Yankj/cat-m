import Foundation
#if canImport(os)
import os
#endif

public struct ConversationMemoryDraft:Codable,Sendable,Equatable {
    public var targetID:UUID?,base:ConversationMemoryEntry?,topic:String="",text:String="",workspaceWide=false
    public init(){}
}
public struct ConversationMemoryPending:Codable,Sendable,Equatable {
    public let request:ConversationMemoryRequest
    public var notSent=false
}
public struct ConversationMemoryLocalState:Codable,Sendable,Equatable {
    public var schemaVersion=1
    public let subjectID:UUID,serverScopeID:UUID
    public var draftEpoch:UUID
    public var latest:ConversationMemorySnapshot?,draft=ConversationMemoryDraft(),pending:ConversationMemoryPending?,lastReceipt:ConversationMemoryReceipt?
    private enum CodingKeys:String,CodingKey {case schemaVersion,subjectID,serverScopeID,draftEpoch,latest,draft,pending,lastReceipt}
    private static func initialEpoch(subject:UUID,scope:UUID)->UUID {stableID("memory-draft-initial:\(subject):\(scope)")}
    public init(reference:ConversationMemoryReference){subjectID=reference.subjectID;serverScopeID=reference.serverScopeID;draftEpoch=Self.initialEpoch(subject:reference.subjectID,scope:reference.serverScopeID)}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try c.decode(Int.self,forKey:.schemaVersion);subjectID=try c.decode(UUID.self,forKey:.subjectID);serverScopeID=try c.decode(UUID.self,forKey:.serverScopeID)
        draftEpoch=try c.decodeIfPresent(UUID.self,forKey:.draftEpoch) ?? Self.initialEpoch(subject:subjectID,scope:serverScopeID)
        latest=try c.decodeIfPresent(ConversationMemorySnapshot.self,forKey:.latest);draft=try c.decode(ConversationMemoryDraft.self,forKey:.draft);pending=try c.decodeIfPresent(ConversationMemoryPending.self,forKey:.pending);lastReceipt=try c.decodeIfPresent(ConversationMemoryReceipt.self,forKey:.lastReceipt)
    }
}
/// Durable delivery journal and local draft only. Claims, source trust, enabled
/// state and generation are always server facts, never inferred by presentation.
public actor ConversationMemoryService {
    public nonisolated let reference:ConversationMemoryReference
    private let repository:Repository,backend:any ConversationMemoryBackend
    private var generation=0,admitted=false,closed=false,fresh=false,locked=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    public init(repository:Repository,reference:ConversationMemoryReference,backend:any ConversationMemoryBackend){self.repository=repository;self.reference=reference;self.backend=backend}
    public func setAdmissionAllowed(_ allowed:Bool) async {if !allowed {generation+=1;fresh=false};admitted=allowed && !closed}
    public func invalidate() async {generation+=1;admitted=false;closed=true;fresh=false;await backend.close()}
    public func close() async {await invalidate()}
    public func localState() async throws -> ConversationMemoryLocalState {await lock();defer{unlock()};guard !closed else {throw CancellationError()};return try await load().0}
    public func saveDraft(_ draft:ConversationMemoryDraft,expectedDraftEpoch:UUID) async throws {
        try Task.checkCancellation()
        guard draft.text.utf16.count<=8000,draft.topic.utf16.count<=200 else {throw ConversationMemoryError.invalidResponse}
        await lock();defer{unlock()};try Task.checkCancellation();guard !closed else {throw CancellationError()};var (state,record)=try await load();try Task.checkCancellation()
        guard state.draftEpoch==expectedDraftEpoch else {throw ConversationMemoryError.stale}
        state.draft=draft;try await save(state,record:record);try Task.checkCancellation()
    }
    public func refresh() async throws -> ConversationMemoryLocalState {
        let epoch=generation;try ensure(epoch);fresh=false;let value=try await backend.readMemory(reference);try ensure(epoch);try value.validate(reference)
        await lock();defer{unlock()};try ensure(epoch);var (state,record)=try await load();try ensure(epoch)
        if let old=state.latest {guard value.memory_generation>=old.memory_generation else {throw ConversationMemoryError.stale}}
        if let receipt=state.lastReceipt {guard value.memory_generation>=receipt.operation.result.memory_generation else {throw ConversationMemoryError.stale}}
        state.latest=value;try await save(state,record:record);try ensure(epoch);fresh=true;return state
    }
    public func submit(_ command:ConversationMemoryCommand) async throws -> ConversationMemoryLocalState {
        let epoch=generation;try ensure(epoch);try command.validate()
        await lock();var request:ConversationMemoryRequest
        do {
            try ensure(epoch);var (state,record)=try await load();try ensure(epoch)
            guard fresh,state.pending==nil,let snapshot=state.latest else {throw ConversationMemoryError.busy}
            if [.remember,.correct,.confirm].contains(command.type) {guard snapshot.enabled else {throw ConversationMemoryError.unavailable}}
            request=try .init(generation:snapshot.memory_generation,command:command);state.pending = .init(request:request)
            try await save(state,record:record);try ensure(epoch);fresh=false;unlock()
        }catch{unlock();throw error}
        do {let receipt=try await backend.submitMemory(reference,request:request);try ensure(epoch);return try await apply(receipt,request:request,epoch:epoch)}
        catch {
            if (error as? ConversationMemoryError == .notSent || error as? ConversationMemoryError == .rejected),epoch==generation,!closed {
                await lock();defer{unlock()};var (state,record)=try await load();if state.pending?.request==request {state.pending?.notSent=true;try await save(state,record:record)}
            }
            throw error
        }
    }
    public func readOriginal() async throws -> ConversationMemoryLocalState {
        let epoch=generation;try ensure(epoch);let state=try await localState();try ensure(epoch)
        guard let pending=state.pending else {return state}
        let receipt=try await backend.readMemoryOperation(reference,request:pending.request);try ensure(epoch)
        return try await apply(receipt,request:pending.request,epoch:epoch)
    }
    public func reopenNotSent() async throws -> ConversationMemoryLocalState {
        await lock();defer{unlock()};guard !closed else {throw CancellationError()};var (state,record)=try await load()
        guard state.pending?.notSent==true else {throw ConversationMemoryError.busy};state.pending=nil;fresh=false;try await save(state,record:record);return state
    }
    public func source(_ id:UUID) async throws -> ConversationMemorySource {
        let epoch=generation;try ensure(epoch);let value=try await backend.readMemorySource(reference,id:id);try ensure(epoch);return value
    }
    private func apply(_ receipt:ConversationMemoryReceipt,request:ConversationMemoryRequest,epoch:Int) async throws -> ConversationMemoryLocalState {
        try receipt.validate(reference,request:request);await lock();defer{unlock()};try ensure(epoch);var (state,record)=try await load();try ensure(epoch)
        guard state.pending?.request==request else {throw ConversationMemoryError.invalidResponse}
        // Drop stale facts and command text before any follow-up GET. A forgotten
        // value cannot survive in this service's completed operation journal.
        state.latest=nil;state.draft = .init();state.draftEpoch=UUID();state.pending=nil;state.lastReceipt=receipt
        try await save(state,record:record);try ensure(epoch);return state
    }
    private var key:String {"conversation_memory_v1:"+reference.subjectID.uuidString.lowercased()+":"+reference.serverScopeID.uuidString.lowercased()}
    private func load() async throws -> (ConversationMemoryLocalState,StoredRecord?) {
        var record:StoredRecord
        do {record=try await repository.record(stableID(key),scope:reference.scope)}catch CatpawError.missing {return (.init(reference:reference),nil)}
        guard case .preference(let p)=record.payload,p.key==key,p.value.utf8.count<=2_000_000 else {throw ConversationMemoryError.invalidResponse}
        guard let plain=ConversationMemoryAtRest.open(p.value,subject:reference.subjectID) else {return (.init(reference:reference),record)}   // other key / shredded at sign-out: start empty
        let state=try JSONDecoder().decode(ConversationMemoryLocalState.self,from:plain)
        guard state.schemaVersion==1,state.subjectID==reference.subjectID,state.serverScopeID==reference.serverScopeID else {throw ConversationMemoryError.invalidResponse}
        if let value=state.latest {try value.validate(reference)}
        if let pending=state.pending {try pending.request.command.validate()}
        // Codex PR91 p91b-5: an old plaintext row is re-written sealed on first read (active migration).
        if !ConversationMemoryAtRest.isSealed(p.value),ConversationMemoryAtRest.sealer != nil {
            try await save(state,record:record)
            record=try await repository.record(stableID(key),scope:reference.scope)
        }
        return (state,record)
    }
    private func save(_ state:ConversationMemoryLocalState,record:StoredRecord?) async throws {
        guard !closed else {throw CancellationError()};let data=try ConversationMemoryCodec.encoded(state);guard data.count<=2_000_000 else {throw ConversationMemoryError.invalidResponse}
        let payload=Payload.preference(.init(key:key,value:try ConversationMemoryAtRest.seal(data,subject:reference.subjectID)))
        try await repository.commit(scope:reference.scope,mutations:[record.map{.update($0.id,$0.header.revision,payload)} ?? .create(stableID(key),payload)])
    }
    private func ensure(_ epoch:Int) throws {guard !closed,admitted,generation==epoch,!Task.isCancelled else {throw CancellationError()}}
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock(){if waiters.isEmpty{locked=false}else{waiters.removeFirst().resume()}}
}
public extension ConversationMemoryBackend {func close() async {}}

/// Codex PR91 #5: memory snapshots/drafts stored in the Repository (SwiftData JSON) are sealed with the subject's L2 key
/// (AES-GCM) when a sealer is installed (app: `CatpawApp`). Sign-out shreds the key, so the rows become unreadable.
/// No sealer (portable tests / previews) → plain JSON as before. Legacy plain rows are still read and re-sealed on save.
enum ConversationMemoryAtRest {
    static let prefix = "l2:"
    nonisolated(unsafe) static var sealer: ((Data, UUID) throws -> Data)?
    nonisolated(unsafe) static var opener: ((Data, UUID) throws -> Data)?
    /// Codex PR91 p91b-5: no plaintext fallback in release builds — without a sealer the write fails.
    /// Debug / fixture builds keep plaintext rows so test runners without L2 still work.
    nonisolated(unsafe) static var allowPlaintext: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()
    struct NoSealer: Error {}
    static func isSealed(_ value: String) -> Bool { value.hasPrefix(prefix) }
    static func seal(_ data: Data, subject: UUID) throws -> String {
        guard let sealer else { guard allowPlaintext else { throw NoSealer() }; return String(decoding: data, as: UTF8.self) }
        return prefix + (try sealer(data, subject)).base64EncodedString()
    }
    /// nil = sealed but cannot be opened (another account's or shredded key).
    static func open(_ value: String, subject: UUID) -> Data? {
        guard value.hasPrefix(prefix) else { return Data(value.utf8) }
        guard let opener, let raw = Data(base64Encoded: String(value.dropFirst(prefix.count))) else { return nil }
        return try? opener(raw, subject)
    }
}

/// Codex PR91 p91c-5 / p91d-4: seals EVERY plaintext memory row of `subject` in one local partition, verifies each
/// sealed row reads back identical, and sets a completion marker keyed by (version, partition, subject) only when all
/// rows passed. Any failure leaves the marker unset, so `AtRestMigrationScheduler` retries.
extension ConversationMemoryAtRest {
    static let keyPrefix = "conversation_memory_v1:"
    static let migrationVersion = 2
    static func gateKey(_ subject: UUID, partition: String) -> String {
        "catpaw.memory.atrest-sealed.v\(migrationVersion).\(partition).\(subject.uuidString.lowercased())"
    }
    struct MigrationReport: Equatable { var sealed = 0, failed = 0, complete = false }
    static func isMigrated(_ subject: UUID, partition: String, defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: gateKey(subject, partition: partition)) }
    static func migrateAll(_ repository: Repository, subject: UUID, partition: String, defaults: UserDefaults = .standard) async -> MigrationReport {
        var report = MigrationReport()
        guard !isMigrated(subject, partition: partition, defaults: defaults) else { report.complete = true; return report }
        guard sealer != nil, opener != nil else { return report }
        let mine = keyPrefix + subject.uuidString.lowercased() + ":"
        for record in await repository.preferenceRecords(keyPrefix: mine) {
            guard case .preference(let p) = record.payload, !isSealed(p.value) else { continue }
            do {
                let plain = Data(p.value.utf8)
                let sealedValue = try seal(plain, subject: subject)
                guard isSealed(sealedValue) else { throw NoSealer() }
                try await repository.commit(scope: record.header.scope, mutations: [.update(record.header.id, record.header.revision, .preference(.init(key: p.key, value: sealedValue)))])
                let back = try await repository.record(record.header.id, scope: record.header.scope)
                guard case .preference(let q) = back.payload, isSealed(q.value), open(q.value, subject: subject) == plain else { throw NoSealer() }
                report.sealed += 1
            } catch { report.failed += 1 }
        }
        // Gate: every row of this subject is sealed now (re-scan, not just the count above).
        let leftover = await repository.preferenceRecords(keyPrefix: mine).contains { if case .preference(let p) = $0.payload { return !isSealed(p.value) }; return false }
        if report.failed == 0, !leftover { defaults.set(true, forKey: gateKey(subject, partition: partition)); report.complete = true }
        return report
    }
}

/// Codex PR91 p91d-4: runs the at-rest migration for every opened account repository once the sealer for that subject
/// is ready (cold start opens the store before the L2 key / signed-in user exist), consumes the report, and retries
/// with backoff until the marker is set. Dropped when the account changes (AccountEpoch).
@MainActor final class AtRestMigrationScheduler {
    static let shared = AtRestMigrationScheduler()
    var sealerReady: @MainActor (UUID) -> Bool = { subject in
        ConversationMemoryAtRest.sealer != nil && L2SecureStore.currentForSealing?.userID == subject
    }
    var defaults: UserDefaults = .standard
    var delays: [UInt64] = [1, 2, 5, 10, 30, 60, 120, 300].map { $0 * 1_000_000_000 }
    var sleep: @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    private var running: [String: Task<Void, Never>] = [:]
    private(set) var reports: [String: ConversationMemoryAtRest.MigrationReport] = [:]
    private(set) var attempts: [String: Int] = [:]
    /// Unfinished partitions (marker not set), so `sealerMayBeReady()` can restart them after backoff gave up.
    private var waiting: [String: (Repository, UUID, String)] = [:]
    /// Codex PR91 v2-1: verifiable trace of the production path. No subject / partition / content in the text.
    /// Production: unified log, subsystem "catpaw.ios", category "atrest" (`log stream --predicate 'category == "atrest"'`).
    var log: (String) -> Void = { message in
        #if canImport(os)
        Logger(subsystem: "catpaw.ios", category: "atrest").notice("\(message, privacy: .public)")
        #endif
    }
    /// Tests: observe the same lines.
    var trace: ((String) -> Void)?
    private func emit(_ message: String) { log("catpaw.atrest " + message); trace?(message) }

    func repositoryOpened(_ repository: Repository, subject: UUID, partition: String) {
        let key = ConversationMemoryAtRest.gateKey(subject, partition: partition)
        guard !defaults.bool(forKey: key) else { emit("already-complete"); return }
        waiting[key] = (repository, subject, partition)
        guard running[key] == nil else { emit("already-running"); return }
        emit("scheduled")
        let token = AccountEpoch.shared.capture()
        running[key] = Task { [weak self] in await self?.drive(repository, subject, partition, key, token) }
    }
    /// Called when the L2 key for the signed-in user is installed (CatpawApp): restart partitions still waiting.
    func sealerMayBeReady() {
        for (_, w) in waiting { repositoryOpened(w.0, subject: w.1, partition: w.2) }
    }
    /// Tests: wait for every scheduled migration to finish.
    func waitIdle() async { while let task = running.values.first { await task.value } }

    private func drive(_ repository: Repository, _ subject: UUID, _ partition: String, _ key: String, _ token: AccountToken?) async {
        defer { running[key] = nil }
        var attempt = 0
        while !Task.isCancelled {
            if token != nil, !AccountEpoch.shared.isValid(token) { emit("dropped account-changed"); return }
            let ready = sealerReady(subject)
            if ready {
                attempts[key, default: 0] += 1
                let report = await ConversationMemoryAtRest.migrateAll(repository, subject: subject, partition: partition, defaults: defaults)
                reports[key] = report
                if report.complete { waiting[key] = nil; emit("complete sealed=\(report.sealed)"); return }
                emit("incomplete sealed=\(report.sealed) failed=\(report.failed)")
            } else { emit("waiting sealer attempt=\(attempt)") }
            guard attempt < delays.count else { emit("gave-up until sealerMayBeReady"); return }
            await sleep(delays[attempt]); attempt += 1
        }
    }
}
