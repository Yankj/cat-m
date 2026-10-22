#if os(iOS)
import Foundation
import SwiftData

enum catSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [EntityRow.self, StoreMeta.self] }
    @Model final class EntityRow {
        @Attribute(.unique) var id: UUID
        var profileID: UUID
        var workspaceID: UUID
        var kind: String
        var parentID: UUID?
        var revision: Int
        var updatedAt: Date
        var recordData: Data
        init(_ record: StoredRecord) throws {
            id = record.id; profileID = record.header.scope.profileID; workspaceID = record.header.scope.workspaceID
            kind = record.payload.kind; parentID = record.payload.parentID; revision = record.header.revision
            updatedAt = record.header.updatedAt; recordData = try JSONEncoder().encode(record)
        }
    }
    @Model final class StoreMeta {
        @Attribute(.unique) var key: String
        var data: Data
        init(key: String, data: Data) { self.key = key; self.data = data }
    }
}
enum catMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [catSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
// SwiftData models and ModelContext remain confined to the generated ModelActor executor.
// The legacy SnapshotPersistence contract is synchronous; its narrow bridge returns values only.
private final class PersistenceResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?
    func set(_ result: Result<Value, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() throws -> Value { lock.lock(); defer { lock.unlock() }; return try value!.get() }
}
private func waitForPersistence<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) throws -> Value {
    let finished = DispatchSemaphore(value: 0)
    let result = PersistenceResult<Value>()
    Task.detached(priority: .userInitiated) {
        do { result.set(.success(try await body())) } catch { result.set(.failure(error)) }
        finished.signal()
    }
    #if DEBUG
    let waitStart=ProcessInfo.processInfo.systemUptime
    defer {P0PerformanceLog.shared.record("swiftdata_bridge_wait",start:waitStart,end:ProcessInfo.processInfo.systemUptime,main:Thread.isMainThread)}
    #endif
    finished.wait()
    return try result.get()
}
/// Canonical key for one on-disk store, so `/private/var/...` and `/var/...` spellings share an entry.
func canonicalStorePath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
/// Crash fix (cat 0.3.0 (41), 2026-10-17 20:36, `_PFFaultHandlerLookupRow` under `saveOnQueue`):
/// every `SwiftDataPersistence(url:)` used to build its own `ModelContainer`. Two containers on one SQLite file have
/// two coordinators that never see each other's deletes, and each save rewrites the full snapshot (deleting rows the
/// other writer just added), so a setter on a row the other coordinator deleted throws `NSObjectInaccessibleException`.
/// One process-wide `SnapshotModelActor` per file makes every save and load for that file run serially on one context.
/// Entries are weak: the container closes when the last persistence for the file is released.
private final class SnapshotStoreRegistry: @unchecked Sendable {
    static let shared = SnapshotStoreRegistry()
    private final class Entry { weak var store: SnapshotModelActor?; init(_ store: SnapshotModelActor) { self.store = store } }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func store(for url: URL) throws -> SnapshotModelActor {
        let key = canonicalStorePath(url)
        lock.lock(); defer { lock.unlock() }
        if let live = entries[key]?.store { return live }
        entries = entries.filter { $0.value.store != nil }
        // Opening inside the lock is intentional: two callers racing on one file must not both build a container.
        // The opener runs on a detached task that never takes this lock, so it cannot deadlock.
        let opened = try waitForPersistence {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let schema = Schema(catSchemaV1.models)
            let config = ModelConfiguration("CatpawLocal", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: catMigration.self, configurations: [config])
            return SnapshotModelActor(modelContainer: container)
        }
        entries[key] = Entry(opened)
        return opened
    }
}
/// Account stores are opened from several lifecycle paths (local receipt, provisional sign-in, workspace admit, offline
/// trial) that can overlap. Each `Repository` keeps a full in-memory snapshot and saves it whole, so two repositories
/// on one file silently drop each other's commits. All openers of the same file share one live `Repository`.
final class SharedRepositoryRegistry: @unchecked Sendable {
    static let shared = SharedRepositoryRegistry()
    private final class Entry { weak var repository: Repository?; init(_ repository: Repository) { self.repository = repository } }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func repository(at storeURL: URL, open: () throws -> Repository) throws -> Repository {
        let key = canonicalStorePath(storeURL)
        lock.lock(); defer { lock.unlock() }
        if let live = entries[key]?.repository { return live }
        entries = entries.filter { $0.value.repository != nil }
        let opened = try open()
        entries[key] = Entry(opened)
        return opened
    }
}
final class SwiftDataPersistence: SnapshotPersistence {
    private let store: SnapshotModelActor
    init(url: URL) throws {
        store = try SnapshotStoreRegistry.shared.store(for: url)
    }
    func load() throws -> StoreSnapshot { try waitForPersistence { [store] in try await store.load() } }
    func save(_ snapshot: StoreSnapshot) throws { try waitForPersistence { [store] in try await store.save(snapshot) } }
    #if DEBUG
    func failNextSaveForTesting() { try? waitForPersistence { [store] in await store.failNextSaveForTesting() } }
    /// Identity of the shared store actor, for the one-container-per-file regression test.
    var storeIdentityForTesting: ObjectIdentifier { ObjectIdentifier(store) }
    #endif
}
@ModelActor private actor SnapshotModelActor {
    #if DEBUG
    private var failNextCommit = false
    func failNextSaveForTesting() { failNextCommit = true }
    #endif
    /// Highest snapshot sequence known durable in this file. A save at or below it comes from a writer whose snapshot
    /// predates another writer's commit; writing it would delete that commit's rows, so it is refused (`.conflict`).
    private var durableSequence: Int64?
    func load() throws -> StoreSnapshot {
        modelContext.autosaveEnabled = false
        let state = try loadOnQueue()
        if state.sequence > (durableSequence ?? -1) { durableSequence = state.sequence }
        return state
    }
    private func loadOnQueue() throws -> StoreSnapshot {
        var state = StoreSnapshot()
        let meta = try modelContext.fetch(FetchDescriptor<catSchemaV1.StoreMeta>())
        if let data = meta.first(where: { $0.key == "metadata" })?.data { state = try JSONDecoder().decode(StoreSnapshot.self, from: data) }
        for row in try modelContext.fetch(FetchDescriptor<catSchemaV1.EntityRow>()) {
            let r = try JSONDecoder().decode(StoredRecord.self, from: row.recordData)
            guard r.id == row.id, r.header.scope.profileID == row.profileID, r.payload.kind == row.kind else { throw catError.corrupt("存储索引与内容不一致。") }
            state.records[r.id] = r
        }
        return state
    }
    func save(_ snapshot: StoreSnapshot) throws { modelContext.autosaveEnabled = false; try saveOnQueue(snapshot) }
    private func saveOnQueue(_ snapshot: StoreSnapshot) throws {
        #if DEBUG
        let saveStart=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("swiftdata_save",start:saveStart,end:ProcessInfo.processInfo.systemUptime,main:Thread.isMainThread,count:snapshot.records.count)}
        #endif
        if let durable = durableSequence, snapshot.sequence <= durable { throw catError.conflict }
        do {
            // Rows are re-fetched on this context for every save; models never outlive the save or leave the actor.
            // A row already deleted (or detached from this context) is never written through: its setter would fire a
            // fault on a missing row. It is skipped, so the record is inserted as a fresh row (the unique id upserts).
            let rows = try modelContext.fetch(FetchDescriptor<catSchemaV1.EntityRow>())
            var existing: [UUID: catSchemaV1.EntityRow] = [:]
            for row in rows where !row.isDeleted && row.modelContext != nil { existing[row.id] = row }
            for r in snapshot.records.values {
                if let row = existing.removeValue(forKey: r.id) {
                    row.profileID = r.header.scope.profileID; row.workspaceID = r.header.scope.workspaceID
                    row.kind = r.payload.kind; row.parentID = r.payload.parentID; row.revision = r.header.revision
                    row.updatedAt = r.header.updatedAt; row.recordData = try JSONEncoder().encode(r)
                } else { modelContext.insert(try catSchemaV1.EntityRow(r)) }
            }
            for row in existing.values { modelContext.delete(row) }
            var metadata = snapshot; metadata.records = [:]
            let data = try JSONEncoder().encode(metadata)
            let metas = try modelContext.fetch(FetchDescriptor<catSchemaV1.StoreMeta>())
            if let old = metas.first(where: { $0.key == "metadata" && !$0.isDeleted && $0.modelContext != nil }) { old.data = data }
            else { modelContext.insert(catSchemaV1.StoreMeta(key: "metadata", data: data)) }
            #if DEBUG
            if failNextCommit { failNextCommit = false; throw catError.unavailable("injected_swiftdata_save_failure") }
            #endif
            try modelContext.save()
            durableSequence = snapshot.sequence
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
#endif
