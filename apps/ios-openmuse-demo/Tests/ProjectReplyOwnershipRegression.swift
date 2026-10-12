import Foundation

/// Standalone diagnostic for generated reply visibility in the original project's file tree.
/// Deliberately not part of app/UI targets; run against a candidate integration before promoting it.
@main struct ProjectReplyOwnershipRegression {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatpawReplyOwner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try Repository(persistence: FilePersistence(url: directory.appendingPathComponent("store.json")))
        let blobs = try BlobStore(root: directory.appendingPathComponent("blobs"))
        let service = WorkspaceService(repository: repo, blobs: blobs)
        let scope = Profiles.user
        try await service.bootstrap(scope: scope)
        let env = service.environmentID(.local, scope)
        let a = try await service.createProject(scope: scope, name: "Ownership A", environment: env)
        let b = try await service.createProject(scope: scope, name: "Ownership B", environment: env)
        let conversation = try await service.createConversation(scope: scope, environment: env, project: a, configuration: ConversationConfiguration(model: "Auto", safety: true, subagents: false))
        let runtime = ChatRuntime(repository: repo, service: service, provider: FixtureProvider(delayNanoseconds: 0))
        let operation = try await runtime.send(scope: scope, conversationID: conversation, text: "Project A result", clientMessageID: UUID(), scenario: .success)
        await runtime.awaitCompletion(operationID: operation)
        let snapshot = await repo.read(scope: scope)
        guard let task = snapshot.list("task", scope: scope).first?.task,
              task.state == .succeeded, let reference = task.results.first,
              let document = snapshot.records[reference.documentID]?.document else {
            throw CatpawError.invalid("No published reply to inspect")
        }
        guard document.ownerIDs.contains(conversation) else { throw CatpawError.invalid("Missing original conversation owner") }
        guard document.ownerIDs.contains(a) else {
            print("FAIL generated reply is absent from Project A file-tree predicate: document.ownerIDs lacks original project")
            exit(1)
        }
        guard case .core(.project(let projectA)) = snapshot.records[a]?.payload,
              projectA.documentIDs.contains(reference.documentID) else {
            print("FAIL Project A document index lacks the generated reply")
            exit(1)
        }
        guard !document.ownerIDs.contains(b), case .core(.project(let projectB)) = snapshot.records[b]?.payload,
              !projectB.documentIDs.contains(reference.documentID) else {
            throw CatpawError.invalid("Reply leaked into unrelated Project B")
        }
        print("PASS generated reply preserves conversation and Project A ownership/index, excludes Project B")
    }
}
