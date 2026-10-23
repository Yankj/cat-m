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

    @MainActor func testProvisionalScopeWaitsForCanonicalResolutionBeforeLedgerWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-provisional-scope-" + UUID().uuidString, isDirectory: true)
        let scope = UUID(), subject = UUID(), child = UUID()
        let configuration = try configuration(scope: nil)
        let remote = NativeAuthBoundaryRemote(issuer: configuration.issuer, subject: subject)
        let credential = await remote.candidate()
        let storage = AuthTestStorage(), cipher = ParentingTestCipher()
        try storage.save(credential)
        AccountEpoch.shared.signOut()
        let resolver = ParentingScopeResolver(subject: subject, scope: scope, expectedCredential: credential, mode: .held)
        let manager = NativeAuthSessionManager(configuration: configuration, remote: remote, vault: storage, barrier: storage)
        let app = NativeAuthApplicationModel(configuration: configuration, manager: manager, vault: storage, barrier: storage,
            root: root, workspaceResolver: resolver, parentingCipher: cipher)
        let startup = Task { @MainActor in await app.start() }
        addTeardownBlock {
            await remote.rejectUser(); await resolver.releaseHeld(); startup.cancel()
            await app.signOut(); await startup.value
        }
        try await waitUntil { await remote.pendingUser() }
        await remote.acceptUser()
        await startup.value
        try await waitUntil {
            let held = await resolver.isHolding()
            return app.state.user?.id == subject && app.chat != nil && held
        }
        let provisional = try XCTUnwrap(app.chat)
        let canonical = AuthenticatedLocalPartition(issuer: configuration.issuer, subject: subject, serverScopeID: scope)
        XCTAssertNotEqual(provisional.scope, canonical.scope)
        XCTAssertFalse(provisional.networkAdmissionAllowed)
        XCTAssertNil(app.parentingWorkspace, "Verified subject alone cannot choose a writable provisional ledger")
        let receiptURL = root.appendingPathComponent("last-local-workspace.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path), "An unresolved open must never overwrite a confirmed receipt")
        let provisionalStores = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("local.store") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(provisionalStores.count, 1)
        let provisionalStoreURL = try XCTUnwrap(provisionalStores.first)

        await resolver.releaseHeld()
        try await waitUntil { app.parentingWorkspace != nil && app.chat?.networkAdmissionAllowed == true }
        let resolved = try XCTUnwrap(app.chat)
        XCTAssertFalse(resolved === provisional)
        XCTAssertEqual(resolved.scope, canonical.scope)
        let presentation = try XCTUnwrap(app.parentingWorkspace)
        XCTAssertEqual(presentation.id.chat, ObjectIdentifier(resolved))
        let workspace = presentation.model
        await workspace.load()
        XCTAssertTrue(workspace.loaded)
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.workspace, .empty)
        let saved = await workspace.apply(.addChild(id: child, name: "Synthetic canonical child"))
        XCTAssertTrue(saved)
        let cold = try Repository(persistence: SwiftDataPersistence(url: root.appendingPathComponent(canonical.namespace).appendingPathComponent("local.store")))
        let persisted = try await ParentingWorkspaceStore(repository: cold, scope: canonical.scope, subjectID: subject, cipher: cipher).load()
        XCTAssertEqual(persisted, workspace.workspace)
        XCTAssertEqual(persisted.children.map(\.id), [child])
        let provisionalCold = try Repository(persistence: SwiftDataPersistence(url: provisionalStoreURL))
        let provisionalSnapshot = await provisionalCold.read(scope: provisional.scope)
        XCTAssertNil(provisionalSnapshot.records[ParentingWorkspaceStore.recordID(scope: provisional.scope, subjectID: subject)],
            "No parenting preference may be persisted in the discarded provisional repository")
        let receipt = try JSONDecoder().decode(LocalConversationReceipt.self, from: Data(contentsOf: receiptURL))
        XCTAssertEqual(receipt.serverScopeID, scope)
        XCTAssertEqual(receipt.canonicalScope, true)
    }

    @MainActor func testCanonicalReceiptKeepsVerifiedLedgerUsableWhileScopeDiscoveryIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-canonical-offline-" + UUID().uuidString, isDirectory: true)
        let scope = UUID(), subject = UUID(), child = UUID(), arrangement = UUID()
        let configuration = try configuration(scope: nil)
        let remote = NativeAuthBoundaryRemote(issuer: configuration.issuer, subject: subject)
        let credential = await remote.candidate()
        let storage = AuthTestStorage(), cipher = ParentingTestCipher()
        try storage.save(credential)
        let partition = AuthenticatedLocalPartition(issuer: configuration.issuer, subject: subject, serverScopeID: scope)
        let directory = root.appendingPathComponent(partition.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try Repository(persistence: SwiftDataPersistence(url: directory.appendingPathComponent("local.store")))
        AccountEpoch.shared.activate(account: subject.uuidString)
        let seedStore = ParentingWorkspaceStore(repository: repository, scope: partition.scope, subjectID: subject, cipher: cipher)
        var seeded = try await seedStore.apply(.addChild(id: child, name: "Synthetic known child"), expectedRevision: 0)
        seeded = try await seedStore.apply(.createDraft(id: arrangement, childID: child, title: "Synthetic known arrangement",
            dueAt: Date(), goalID: nil, sourceText: "Synthetic canonical source"), expectedRevision: seeded.revision)
        AccountEpoch.shared.signOut()
        struct LegacyReceipt: Codable { let issuer: String; let subject: UUID; let serverScopeID: UUID }
        let legacy = LegacyReceipt(issuer: configuration.issuer, subject: subject, serverScopeID: scope)
        let decodedLegacy = try JSONDecoder().decode(LocalConversationReceipt.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decodedLegacy.canonicalScope, "Existing three-field receipts must remain decodable")
        XCTAssertEqual(decodedLegacy.issuer, legacy.issuer)
        XCTAssertEqual(decodedLegacy.subject, legacy.subject)
        XCTAssertEqual(decodedLegacy.serverScopeID, legacy.serverScopeID)
        let marked = LocalConversationReceipt(issuer: configuration.issuer, subject: subject, serverScopeID: scope, canonicalScope: true)
        let markedBytes = try JSONEncoder().encode(marked)
        let oldReader = try JSONDecoder().decode(LegacyReceipt.self, from: markedBytes)
        XCTAssertEqual(oldReader.issuer, legacy.issuer)
        XCTAssertEqual(oldReader.subject, legacy.subject)
        XCTAssertEqual(oldReader.serverScopeID, legacy.serverScopeID)
        let receiptURL = root.appendingPathComponent("last-local-workspace.json")
        try markedBytes.write(to: receiptURL, options: .atomic)
        let resolver = ParentingScopeResolver(subject: subject, scope: scope, expectedCredential: credential, mode: .unavailable)
        let manager = NativeAuthSessionManager(configuration: configuration, remote: remote, vault: storage, barrier: storage)
        let app = NativeAuthApplicationModel(configuration: configuration, manager: manager, vault: storage, barrier: storage,
            root: root, workspaceResolver: resolver, parentingCipher: cipher)
        let startup = Task { @MainActor in await app.start() }
        addTeardownBlock {
            await remote.rejectUser(); await resolver.releaseHeld(); startup.cancel()
            await app.signOut(); await startup.value
        }
        try await waitUntil {
            let pending = await remote.pendingUser()
            return app.chat != nil && pending
        }
        let preview = try XCTUnwrap(app.chat)
        XCTAssertNil(app.parentingWorkspace, "Canonical receipt metadata does not verify the account")
        await remote.acceptUser()
        await startup.value
        try await waitUntil {
            let calls = await resolver.callCount()
            return app.parentingWorkspace != nil && calls > 0
        }
        XCTAssertTrue(app.chat === preview)
        XCTAssertFalse(preview.networkAdmissionAllowed)
        let presentation = try XCTUnwrap(app.parentingWorkspace)
        XCTAssertEqual(presentation.id.profile, partition.scope.profileID)
        XCTAssertEqual(presentation.id.workspace, partition.scope.workspaceID)
        let workspace = presentation.model
        await workspace.load()
        XCTAssertTrue(workspace.loaded)
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.workspace, seeded)
        let saved = await workspace.apply(.renameChild(id: child, name: "Synthetic offline correction"))
        XCTAssertTrue(saved, "Local canonical edits must not require network admission")
        XCTAssertFalse(preview.networkAdmissionAllowed)
        let cold = try Repository(persistence: SwiftDataPersistence(url: directory.appendingPathComponent("local.store")))
        let persisted = try await ParentingWorkspaceStore(repository: cold, scope: partition.scope, subjectID: subject, cipher: cipher).load()
        XCTAssertEqual(persisted, workspace.workspace)
        XCTAssertEqual(persisted.children.first?.name, "Synthetic offline correction")
        XCTAssertEqual(persisted.arrangements, seeded.arrangements)
        let receipt = try JSONDecoder().decode(LocalConversationReceipt.self, from: Data(contentsOf: receiptURL))
        XCTAssertEqual(receipt.serverScopeID, scope)
        XCTAssertEqual(receipt.canonicalScope, true)
    }

    #if DEBUG
    /// A delayed legacy receipt must not steal the empty attachment slot while canonical admission opens its store.
    @MainActor func testLateLegacyReceiptCannotStealCanonicalWorkspaceOpening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-scope-opening-race-" + UUID().uuidString, isDirectory: true)
        let legacyScope = UUID(), canonicalScope = UUID(), subject = UUID(), child = UUID()
        let configuration = try configuration(scope: legacyScope)
        let remote = NativeAuthBoundaryRemote(issuer: configuration.issuer, subject: subject)
        let credential = await remote.candidate()
        let storage = AuthTestStorage(), cipher = ParentingTestCipher()
        try storage.save(credential)
        AccountEpoch.shared.signOut()
        let legacyPartition = AuthenticatedLocalPartition(issuer: configuration.issuer, subject: subject, serverScopeID: legacyScope)
        let directory = root.appendingPathComponent(legacyPartition.namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try Repository(persistence: SwiftDataPersistence(url: directory.appendingPathComponent("local.store")))
        struct LegacyReceipt: Codable { let issuer: String; let subject: UUID; let serverScopeID: UUID }
        let legacyBytes = try JSONEncoder().encode(LegacyReceipt(issuer: configuration.issuer, subject: subject, serverScopeID: legacyScope))
        let receiptURL = root.appendingPathComponent("last-local-workspace.json")
        try legacyBytes.write(to: receiptURL, options: .atomic)
        let oldReceipt = try JSONDecoder().decode(LocalConversationReceipt.self, from: legacyBytes)
        XCTAssertNil(oldReceipt.canonicalScope)
        let readGate = ParentingScopeRaceGate(), canonicalGate = ParentingScopeRaceGate()
        let previousReadHook = NativeAuthApplicationModel.afterLocalReadHook
        let previousCanonicalHook = NativeAuthApplicationModel.canonicalWorkspaceOpeningForTesting
        let previousBudget = NativeAuthApplicationModel.localReadBudget
        NativeAuthApplicationModel.afterLocalReadHook = { await readGate.hold() }
        NativeAuthApplicationModel.canonicalWorkspaceOpeningForTesting = { await canonicalGate.hold() }
        NativeAuthApplicationModel.localReadBudget = 0.02
        let resolver = ParentingScopeResolver(subject: subject, scope: canonicalScope, expectedCredential: credential)
        let manager = NativeAuthSessionManager(configuration: configuration, remote: remote, vault: storage, barrier: storage)
        let app = NativeAuthApplicationModel(configuration: configuration, manager: manager, vault: storage, barrier: storage,
            root: root, workspaceResolver: resolver, parentingCipher: cipher)
        let startup = Task { @MainActor in await app.start() }
        addTeardownBlock { @MainActor in
            // Release every possible continuation before cancelling or joining any owner task.
            await readGate.release(); await canonicalGate.release(); await resolver.releaseHeld(); await remote.rejectUser()
            startup.cancel(); await app.signOut(); await startup.value
            NativeAuthApplicationModel.afterLocalReadHook = previousReadHook
            NativeAuthApplicationModel.canonicalWorkspaceOpeningForTesting = previousCanonicalHook
            NativeAuthApplicationModel.localReadBudget = previousBudget
        }
        try await waitUntil {
            let reading = await readGate.isWaiting(), validating = await remote.pendingUser()
            return reading && validating
        }
        XCTAssertNil(app.chat)
        XCTAssertNil(app.parentingWorkspace)
        await remote.acceptUser()
        await startup.value
        try await waitUntil { await canonicalGate.isWaiting() }
        XCTAssertEqual(app.state.user?.id, subject)
        XCTAssertNil(app.chat, "Canonical admission has detached any earlier provisional attachment")
        XCTAssertNil(app.parentingWorkspace)

        await readGate.release()
        try await waitUntil { app.localReadFinished }
        XCTAssertNil(app.chat, "A late receipt open cannot attach while the canonical store owns the slot")
        XCTAssertNil(app.parentingWorkspace)
        XCTAssertNil(app.error, "A storage failure must not make the late-attachment refusal pass vacuously")
        XCTAssertEqual(try Data(contentsOf: receiptURL), legacyBytes, "The rejected late local open cannot replace the receipt")

        await canonicalGate.release()
        try await waitUntil { app.chat?.networkAdmissionAllowed == true && app.parentingWorkspace != nil }
        let chat = try XCTUnwrap(app.chat), presentation = try XCTUnwrap(app.parentingWorkspace)
        let canonical = AuthenticatedLocalPartition(issuer: configuration.issuer, subject: subject, serverScopeID: canonicalScope)
        XCTAssertEqual(chat.scope, canonical.scope)
        XCTAssertNotEqual(chat.scope, legacyPartition.scope)
        XCTAssertEqual(presentation.id.chat, ObjectIdentifier(chat))
        XCTAssertTrue(AccountEpoch.shared.isValid(presentation.id.token))
        let workspace = presentation.model
        await workspace.load()
        XCTAssertTrue(workspace.loaded)
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.workspace, .empty)
        let saved = await workspace.apply(.addChild(id: child, name: "Synthetic canonical race child"))
        XCTAssertTrue(saved)
        XCTAssertEqual(workspace.workspace.children.map(\.id), [child])
        let receipt = try JSONDecoder().decode(LocalConversationReceipt.self, from: Data(contentsOf: receiptURL))
        XCTAssertEqual(receipt.issuer, configuration.issuer)
        XCTAssertEqual(receipt.subject, subject)
        XCTAssertEqual(receipt.serverScopeID, canonicalScope)
        XCTAssertEqual(receipt.canonicalScope, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("local.store").path),
            "Resolving a canonical scope must preserve the old local directory")
    }
    #endif

    @MainActor private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NativeAuthError.unavailable
    }
    private func configuration(scope: UUID?) throws -> NativeAuthConfiguration {
        try .init(projectURL: URL(string: "https://abcdefghijklmnopqrst.supabase.co")!,
            publishableKey: "sb_publishable_fixtureonly", backendOrigin: URL(string: "https://parenting-auth.example.invalid")!, serverScopeID: scope)
    }
}

private actor ParentingScopeResolver: NativeApplicationScopeResolving {
    enum Mode: Sendable { case standard, held, unavailable }
    let subject: UUID
    let scope: UUID
    let expectedCredential: NativeAuthCredential
    private var mode: Mode
    private var calls = 0
    private var held: CheckedContinuation<UUID, Error>?
    init(subject: UUID, scope: UUID, expectedCredential: NativeAuthCredential, mode: Mode = .standard) {
        self.subject = subject; self.scope = scope; self.expectedCredential = expectedCredential; self.mode = mode
    }
    func applicationScope(accessToken: String, subject: UUID) async throws -> UUID {
        guard subject == self.subject, accessToken == expectedCredential.accessToken else { throw NativeAuthError.invalidResponse }
        calls += 1
        switch mode {
        case .standard: return scope
        case .held: return try await withCheckedThrowingContinuation { held = $0 }
        case .unavailable: throw NativeApplicationSessionError(httpStatus: 503, code: "auth_key_service_unavailable")
        }
    }
    func callCount() -> Int { calls }
    func isHolding() -> Bool { held != nil }
    func releaseHeld() {
        mode = .standard
        held?.resume(returning: scope); held = nil
    }
}

private actor ParentingScopeRaceGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func isWaiting() -> Bool { entered && !released }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
