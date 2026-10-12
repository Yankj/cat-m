#if os(iOS)
import Foundation
import SwiftData

enum CatpawSchemaV1: VersionedSchema {
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
enum CatpawMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CatpawSchemaV1.self] }
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
    finished.wait()
    return try result.get()
}
final class SwiftDataPersistence: SnapshotPersistence {
    private let store: SnapshotModelActor
    init(url: URL) throws {
        store = try waitForPersistence {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let schema = Schema(CatpawSchemaV1.models)
            let config = ModelConfiguration("CatpawLocal", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: CatpawMigration.self, configurations: [config])
            return SnapshotModelActor(modelContainer: container)
        }
    }
    func load() throws -> StoreSnapshot { try waitForPersistence { [store] in try await store.load() } }
    func save(_ snapshot: StoreSnapshot) throws { try waitForPersistence { [store] in try await store.save(snapshot) } }
    #if DEBUG
    func failNextSaveForTesting() { try? waitForPersistence { [store] in await store.failNextSaveForTesting() } }
    #endif
}
@ModelActor private actor SnapshotModelActor {
    #if DEBUG
    private var failNextCommit = false
    func failNextSaveForTesting() { failNextCommit = true }
    #endif
    func load() throws -> StoreSnapshot {
        modelContext.autosaveEnabled = false
        return try loadOnQueue()
    }
    private func loadOnQueue() throws -> StoreSnapshot {
        var state = StoreSnapshot()
        let meta = try modelContext.fetch(FetchDescriptor<CatpawSchemaV1.StoreMeta>())
        if let data = meta.first(where: { $0.key == "metadata" })?.data { state = try JSONDecoder().decode(StoreSnapshot.self, from: data) }
        for row in try modelContext.fetch(FetchDescriptor<CatpawSchemaV1.EntityRow>()) {
            let r = try JSONDecoder().decode(StoredRecord.self, from: row.recordData)
            guard r.id == row.id, r.header.scope.profileID == row.profileID, r.payload.kind == row.kind else { throw CatpawError.corrupt("存储索引与内容不一致。") }
            state.records[r.id] = r
        }
        return state
    }
    func save(_ snapshot: StoreSnapshot) throws { modelContext.autosaveEnabled = false; try saveOnQueue(snapshot) }
    private func saveOnQueue(_ snapshot: StoreSnapshot) throws {
        do {
            let rows = try modelContext.fetch(FetchDescriptor<CatpawSchemaV1.EntityRow>())
            var existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            for r in snapshot.records.values {
                if let row = existing.removeValue(forKey: r.id) {
                    row.profileID = r.header.scope.profileID; row.workspaceID = r.header.scope.workspaceID
                    row.kind = r.payload.kind; row.parentID = r.payload.parentID; row.revision = r.header.revision
                    row.updatedAt = r.header.updatedAt; row.recordData = try JSONEncoder().encode(r)
                } else { modelContext.insert(try CatpawSchemaV1.EntityRow(r)) }
            }
            for row in existing.values { modelContext.delete(row) }
            var metadata = snapshot; metadata.records = [:]
            let data = try JSONEncoder().encode(metadata)
            let metas = try modelContext.fetch(FetchDescriptor<CatpawSchemaV1.StoreMeta>())
            if let old = metas.first(where: { $0.key == "metadata" }) { old.data = data }
            else { modelContext.insert(CatpawSchemaV1.StoreMeta(key: "metadata", data: data)) }
            #if DEBUG
            if failNextCommit { failNextCommit = false; throw CatpawError.unavailable("injected_swiftdata_save_failure") }
            #endif
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
#endif
