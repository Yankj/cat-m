import Foundation
import Combine

@MainActor
final class ParentingWorkspaceModel: ObservableObject {
    @Published private(set) var workspace: ParentingWorkspace = .empty
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var error: String?

    private let store: ParentingWorkspaceStore

    init(repository: Repository, scope: DataScope, subjectID: UUID?, cipher: any ParentingWorkspaceCipher = ParentingPersistentCipher()) {
        store = ParentingWorkspaceStore(repository: repository, scope: scope, subjectID: subjectID, cipher: cipher)
    }
    init(store: ParentingWorkspaceStore) { self.store = store }

    func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let saved = try await store.load()
            guard store.isCurrentAccount() else { throw catError.unavailable("账号已变更，请重新打开育儿账本。") }
            workspace = saved; loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func apply(_ command: ParentingCommand, operationID: UUID = UUID()) async -> Bool {
        guard !busy else { return false }
        guard loaded else { error = "请先载入育儿账本，再保存修改。"; return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            let saved = try await store.apply(command, expectedRevision: workspace.revision, operationID: operationID)
            guard store.isCurrentAccount() else { throw catError.unavailable("账号已变更，请重新打开育儿账本。") }
            workspace = saved
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
