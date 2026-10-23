import Foundation
import XCTest
@testable import cat

final class ParentingAccountLifecycleTests: XCTestCase {
    /// Returning receipt first, verified Auth later: exercises the actual presentation selected by the host,
    /// not a test-only fresh Store that production never installs. Auth/cipher ports are explicitly synthetic.
    @MainActor func testParentingReceiptPreviewBindsVerifiedLedgerWithoutReplacingChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-auth-receipt-" + UUID().uuidString, isDirectory: true)
        // Keep the temporary SwiftData root until the simulator container is removed: detached saves may still finish.
        let scope = UUID(), subject = UUID(), child = UUID(), goal = UUID(), arrangement = UUID(), record = UUID()
        let configuration = try configuration(scope: scope)
        let remote = NativeAuthBoundaryRemote(issuer: configuration.issuer, subject: subject)
        let storage = AuthTestStorage()
        let credential = await remote.candidate()
        try storage.save(credential)
        let partition = AuthenticatedLocalPartition(issuer: configuration.issuer, subject: subject, serverScopeID: scope)
        let directory = root.appendingPathComponent(partition.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try Repository(persistence: SwiftDataPersistence(url: directory.appendingPathComponent("local.store")))
        let cipher = ParentingTestCipher()
        AccountEpoch.shared.activate(account: subject.uuidString)
        let priorStore = ParentingWorkspaceStore(repository: repository, scope: partition.scope, subjectID: subject, cipher: cipher)
        var seeded = try await priorStore.apply(.addChild(id: child, name: "Synthetic returning child"), expectedRevision: 0)
        seeded = try await priorStore.apply(.addGoal(id: goal, childID: child, title: "Synthetic returning goal"), expectedRevision: seeded.revision)
        seeded = try await priorStore.apply(.createDraft(id: arrangement, childID: child, title: "Synthetic returning arrangement",
            dueAt: Date(), goalID: goal, sourceText: "Synthetic prior input"), expectedRevision: seeded.revision)
        AccountEpoch.shared.signOut()
        let earlyStore = ParentingWorkspaceStore(repository: repository, scope: partition.scope, subjectID: subject, cipher: cipher)
        do { _ = try await earlyStore.load(); XCTFail("A receipt cannot authorize the ledger before Auth") } catch { }
        try JSONEncoder().encode(LocalConversationReceipt(issuer: configuration.issuer, subject: subject, serverScopeID: scope))
            .write(to: root.appendingPathComponent("last-local-workspace.json"), options: .atomic)
        let manager = NativeAuthSessionManager(configuration: configuration, remote: remote, vault: storage, barrier: storage)
        let resolver = ParentingScopeResolver(subject: subject, scope: scope, expectedCredential: credential)
        let app = NativeAuthApplicationModel(configuration: configuration, manager: manager, vault: storage, barrier: storage,
            root: root, workspaceResolver: resolver, parentingCipher: cipher)
        let startup = Task { @MainActor in await app.start() }
        addTeardownBlock {
            await remote.rejectUser(); startup.cancel(); await startup.value; await app.signOut()
        }
        try await waitUntil {
            let pending = await remote.pendingUser()
            return app.chat != nil && pending
        }
        let preview = try XCTUnwrap(app.chat)
        XCTAssertNil(app.state.user)
        XCTAssertNil(app.parentingWorkspace, "An unverified receipt must not construct the Home's account-bound model")
        XCTAssertFalse(preview.networkAdmissionAllowed)
        await remote.acceptUser()
        await startup.value
        try await waitUntil { app.chat?.networkAdmissionAllowed == true && app.parentingWorkspace != nil }
        XCTAssertTrue(app.chat === preview, "Auth recovery reuses the real receipt chat")
        let presentation = try XCTUnwrap(app.parentingWorkspace)
        XCTAssertEqual(presentation.id.chat, ObjectIdentifier(preview))
        XCTAssertEqual(presentation.id.subject, subject)
        XCTAssertTrue(AccountEpoch.shared.isValid(presentation.id.token))
        let workspace = presentation.model
        await workspace.load()
        XCTAssertTrue(workspace.loaded)
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.workspace, seeded)
        do { _ = try await earlyStore.load(); XCTFail("The captured nil Store must remain fenced") } catch { }
        do {
            _ = try await earlyStore.apply(.renameChild(id: child, name: "Blocked old writer"), expectedRevision: seeded.revision)
            XCTFail("Rebinding must never reauthorize an old Store")
        } catch { }
        let confirmed = await workspace.apply(.confirmArrangement(id: arrangement))
        XCTAssertTrue(confirmed)
        let completed = await workspace.apply(.completeArrangement(id: arrangement, recordID: record, note: "Synthetic resumed completion"))
        XCTAssertTrue(completed)
        XCTAssertEqual(workspace.workspace.records.first?.id, record)
        XCTAssertEqual(workspace.workspace.records.first?.goalID, goal)
        XCTAssertEqual(workspace.workspace.records.first?.arrangementID, arrangement)
        await app.foreground()
        XCTAssertTrue(app.parentingWorkspace?.model === workspace, "A refresh in the same valid generation preserves the mounted ledger")
        await app.signOut()
        XCTAssertNil(app.parentingWorkspace)
        let oldWrite = await workspace.apply(.renameChild(id: child, name: "Blocked after logout"))
        XCTAssertFalse(oldWrite)
    }

    @MainActor private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NativeAuthError.unavailable
    }
    private func configuration(scope: UUID) throws -> NativeAuthConfiguration {
        try .init(projectURL: URL(string: "https://abcdefghijklmnopqrst.supabase.co")!,
            publishableKey: "sb_publishable_fixtureonly", backendOrigin: URL(string: "https://parenting-auth.example.invalid")!, serverScopeID: scope)
    }
}

private actor ParentingScopeResolver: NativeApplicationScopeResolving {
    let subject: UUID
    let scope: UUID
    let expectedCredential: NativeAuthCredential
    init(subject: UUID, scope: UUID, expectedCredential: NativeAuthCredential) {
        self.subject = subject; self.scope = scope; self.expectedCredential = expectedCredential
    }
    func applicationScope(accessToken: String, subject: UUID) async throws -> UUID {
        guard subject == self.subject, accessToken == expectedCredential.accessToken else { throw NativeAuthError.invalidResponse }
        return scope
    }
}
