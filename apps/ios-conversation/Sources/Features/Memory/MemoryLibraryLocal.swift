import Foundation

// NoBug P0-1/P0-2: the on-device memory library used when cloud agent-memory is 未开通 (gate off / not enrolled).
// - Persisted (Application Support, Codable JSON), so S2/S8 「写入记忆并生效」 survives a cold start.
// - Starts EMPTY. Sample memories exist only in Previews/tests (`MemoryLibraryStub.sample`).
// - When the cloud gate opens, `migrate(_:to:)` copies every local item into the real backend via `create`, and removes
//   each local item only after the backend accepted it. Items the backend refuses stay local (still labelled 本机).

@MainActor enum MemoryLibraryLocal {
    static let fileName = "catpaw-local-memory.v1.json"
    static var fileURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(fileName)
    }
    /// The single persisted on-device library (lazy; reads the file once).
    static let shared = MemoryLibraryStub(items: [], fileURL: fileURL)

    struct MigrationReport: Equatable, Sendable { var migrated = 0; var kept = 0; var stoppedBy: MemoryLibraryError? }

    /// Copy local items into `target` (oldest first, preserving order), deleting each local copy only after success.
    static func migrate(_ local: MemoryLibraryStub, to target: any MemoryLibraryBackend) async -> MigrationReport {
        var report = MigrationReport()
        guard target !== local else { return report }
        for item in local.items.reversed() {
            do {
                _ = try await target.create(kind: item.group.kind, content: item.content)
                try await local.forget(ids: [item.id]); report.migrated += 1
            } catch {
                report.stoppedBy = (error as? MemoryLibraryError) ?? .failed(String(describing: error))
                break
            }
        }
        report.kept = local.items.count
        return report
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
