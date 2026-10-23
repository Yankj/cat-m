import Foundation
import XCTest
@testable import cat

/// Deliberately synthetic codec: exercises the production persistence boundary without
/// creating Keychain entries. It is not evidence for the production cipher's security.
struct ParentingTestCipher: ParentingWorkspaceCipher {
    private struct Envelope: Codable {
        let subject: UUID
        let digest: String
        let body: Data
        let nonce: UUID
    }
    func seal(_ plain: Data, subjectID: UUID) throws -> Data {
        let masked = Data(plain.map { $0 ^ 0xA7 })
        return try JSONEncoder().encode(Envelope(subject: subjectID, digest: bytesHash(plain), body: masked, nonce: UUID()))
    }
    func open(_ sealed: Data, subjectID: UUID) throws -> Data {
        let value = try JSONDecoder().decode(Envelope.self, from: sealed)
        let plain = Data(value.body.map { $0 ^ 0xA7 })
        guard value.subject == subjectID, bytesHash(plain) == value.digest else {
            throw catError.corrupt("Synthetic parenting envelope is damaged or belongs to another subject")
        }
        return plain
    }
}

private final class ParentingFailingPersistence: SnapshotPersistence, @unchecked Sendable {
    let file: FilePersistence
    private let lock = NSLock()
    private var nextSaveFails = false
    init(url: URL) { file = FilePersistence(url: url) }
    func failNextSave() { lock.lock(); defer { lock.unlock() }; nextSaveFails = true }
    func load() throws -> StoreSnapshot { try file.load() }
    func save(_ snapshot: StoreSnapshot) throws {
        lock.lock()
        let shouldFail = nextSaveFails
        nextSaveFails = false
        lock.unlock()
        if shouldFail { throw catError.unavailable("Synthetic disk write failure") }
        try file.save(snapshot)
    }
}

private struct ParentingEpochChangingCipher: ParentingWorkspaceCipher {
    let epoch: AccountEpoch
    func seal(_ plain: Data, subjectID: UUID) throws -> Data {
        let sealed = try ParentingTestCipher().seal(plain, subjectID: subjectID)
        epoch.bump() // Account invalidates after admission, before the repository's durable write.
        return sealed
    }
    func open(_ sealed: Data, subjectID: UUID) throws -> Data {
        try ParentingTestCipher().open(sealed, subjectID: subjectID)
    }
}

final class ParentingWorkspaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_756_800) // 2026-10-23T12:00:00Z
    private let subject = UUID(uuidString: "C1000000-0000-4000-8000-000000000001")!
    private let childID = UUID(uuidString: "C2000000-0000-4000-8000-000000000001")!
    private let itemID = UUID(uuidString: "C3000000-0000-4000-8000-000000000001")!
    private let goalID = UUID(uuidString: "C4000000-0000-4000-8000-000000000001")!
    private let recordID = UUID(uuidString: "C5000000-0000-4000-8000-000000000001")!

    private struct Harness {
        let url: URL
        let subject: UUID
        let scope: DataScope
        let epoch: AccountEpoch
        let persistence: ParentingFailingPersistence
        let repository: Repository
        let store: ParentingWorkspaceStore
    }

    private func make(subject selected: UUID? = nil) throws -> Harness {
        let selected = selected ?? subject
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-synthetic-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.json")
        let scope = AuthenticatedLocalPartition(issuer: "https://parenting-fixture.invalid", subject: selected, serverScopeID: stableID("parenting-test-server-scope")).scope
        let epoch = AccountEpoch(account: selected.uuidString)
        let persistence = ParentingFailingPersistence(url: url)
        let repository = try Repository(persistence: persistence)
        let instant = now
        let store = ParentingWorkspaceStore(repository: repository, scope: scope, subjectID: selected, epoch: epoch, cipher: ParentingTestCipher(), clock: { instant })
        return Harness(url: url, subject: selected, scope: scope, epoch: epoch, persistence: persistence, repository: repository, store: store)
    }

    /// A new Repository reads the saved file; this cannot pass using the old actor's memory.
    private func reopen(_ harness: Harness) throws -> ParentingWorkspaceStore {
        let repository = try Repository(persistence: FilePersistence(url: harness.url))
        let instant = now
        return ParentingWorkspaceStore(repository: repository, scope: harness.scope, subjectID: harness.subject, epoch: harness.epoch, cipher: ParentingTestCipher(), clock: { instant })
    }

    private func rejects(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected the production boundary to reject this action", file: file, line: line) }
        catch { }
    }

    @discardableResult private func apply(_ command: ParentingCommand, to harness: Harness, operationID: UUID = UUID()) async throws -> ParentingWorkspace {
        let current = try await harness.store.load()
        return try await harness.store.apply(command, expectedRevision: current.revision, operationID: operationID)
    }

    @discardableResult private func seedDraft(_ harness: Harness, linkedGoal: Bool = false) async throws -> ParentingWorkspace {
        try await apply(.addChild(id: childID, name: "合成小星"), to: harness)
        if linkedGoal { try await apply(.addGoal(id: goalID, childID: childID, title: "合成阅读目标"), to: harness) }
        return try await apply(.createDraft(id: itemID, childID: childID, title: "合成绘本时间", dueAt: now.addingTimeInterval(3600), goalID: linkedGoal ? goalID : nil, sourceText: "合成原始输入，尚未确认"), to: harness)
    }

    private func assertDiskUnchanged(_ harness: Harness, data: Data, workspace: ParentingWorkspace, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(try Data(contentsOf: harness.url), data, file: file, line: line)
        let inMemory = try await harness.store.load()
        let cold = try await reopen(harness).load()
        XCTAssertEqual(inMemory, workspace, file: file, line: line)
        XCTAssertEqual(cold, workspace, file: file, line: line)
    }

    func testEmptyLoadHasNoSeededChildOrImplicitWrite() async throws {
        let harness = try make()
        let empty = try await harness.store.load()
        XCTAssertEqual(empty, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
    }

    func testDraftConfirmEditCompleteCreatesIndependentRecordAndColdReopens() async throws {
        let harness = try make()
        let draft = try await seedDraft(harness, linkedGoal: true)
        XCTAssertEqual(draft.arrangements.first?.state, .draft)
        XCTAssertTrue(draft.records.isEmpty)
        let coldDraft = try await reopen(harness).load()
        XCTAssertEqual(coldDraft, draft)

        let confirmed = try await apply(.confirmArrangement(id: itemID), to: harness)
        XCTAssertEqual(confirmed.arrangements.first?.state, .planned)
        let revisedDue = now.addingTimeInterval(7200)
        let edited = try await apply(.editArrangement(id: itemID, title: "合成绘本改到下午", dueAt: revisedDue, goalID: goalID), to: harness)
        XCTAssertEqual(edited.arrangements.first?.id, itemID)
        XCTAssertEqual(edited.arrangements.first?.dueAt, revisedDue)
        let completed = try await apply(.completeArrangement(id: itemID, recordID: recordID, note: "合成观察：主动选了故事"), to: harness)
        XCTAssertEqual(completed.arrangements.first?.state, .completed)
        XCTAssertEqual(completed.records.count, 1)
        let record = try XCTUnwrap(completed.records.first)
        XCTAssertEqual(record.id, recordID)
        XCTAssertNotEqual(record.id, itemID)
        XCTAssertEqual(record.arrangementID, itemID)
        XCTAssertEqual(record.childID, childID)
        XCTAssertEqual(record.goalID, goalID)
        XCTAssertEqual(record.kind, .completion)
        XCTAssertEqual(record.text, "合成观察：主动选了故事")
        let coldCompleted = try await reopen(harness).load()
        XCTAssertEqual(coldCompleted, completed)
        XCTAssertFalse(String(decoding: try Data(contentsOf: harness.url), as: UTF8.self).contains("合成小星"), "This checks the injected codec boundary, not production cryptography")
    }

    func testOperationRetryAfterLaterEditReturnsLatestWorkspaceWithoutDuplicate() async throws {
        let harness = try make()
        let operation = stableID("parenting-test-retry")
        let command = ParentingCommand.addChild(id: childID, name: "合成小星")
        let first = try await harness.store.apply(command, expectedRevision: 0, operationID: operation)
        let edited = try await apply(.renameChild(id: childID, name: "合成新昵称"), to: harness)
        let bytes = try Data(contentsOf: harness.url)
        let retry = try await harness.store.apply(command, expectedRevision: first.revision, operationID: operation)
        let coldRetry = try await reopen(harness).apply(command, expectedRevision: 0, operationID: operation)
        XCTAssertEqual(retry, edited)
        XCTAssertEqual(coldRetry, edited)
        XCTAssertEqual(retry.children.count, 1)
        try await assertDiskUnchanged(harness, data: bytes, workspace: edited)
    }

    func testSameOperationWithDifferentCommandIsRejectedWithoutMutation() async throws {
        let harness = try make()
        let operation = stableID("parenting-test-mismatch")
        let first = try await harness.store.apply(.addChild(id: childID, name: "合成小星"), expectedRevision: 0, operationID: operation)
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(.renameChild(id: self.childID, name: "合成误重试"), expectedRevision: first.revision, operationID: operation) }
        try await assertDiskUnchanged(harness, data: bytes, workspace: first)
    }

    func testConcurrentSameOperationWithDistinctSealedBytesHasOneDurableResult() async throws {
        let harness = try make()
        let instant = now
        let second = ParentingWorkspaceStore(repository: harness.repository, scope: harness.scope, subjectID: harness.subject, epoch: harness.epoch, cipher: ParentingTestCipher(), clock: { instant })
        let command = ParentingCommand.addChild(id: childID, name: "合成并发重试")
        let operation = stableID("parenting-test-concurrent-retry")
        async let firstResult = harness.store.apply(command, expectedRevision: 0, operationID: operation)
        async let secondResult = second.apply(command, expectedRevision: 0, operationID: operation)
        let (first, other) = try await (firstResult, secondResult)
        XCTAssertEqual(first, other)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.children.count, 1)
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, first)
        let snapshot = await harness.repository.read(scope: harness.scope)
        XCTAssertEqual(snapshot.journal.count, 1)
    }

    func testSaveFailureDoesNotChangeMemoryOrDiskAndSameOperationCanRetry() async throws {
        let harness = try make()
        let original = try await seedDraft(harness)
        let bytes = try Data(contentsOf: harness.url)
        let operation = stableID("parenting-test-disk-failure")
        harness.persistence.failNextSave()
        await rejects { _ = try await harness.store.apply(.confirmArrangement(id: self.itemID), expectedRevision: original.revision, operationID: operation) }
        try await assertDiskUnchanged(harness, data: bytes, workspace: original)
        let retry = try await harness.store.apply(.confirmArrangement(id: itemID), expectedRevision: original.revision, operationID: operation)
        XCTAssertEqual(retry.arrangements.first?.state, .planned)
        XCTAssertEqual(retry.revision, original.revision + 1)
    }

    func testUnconfirmedAndCancelledDraftCannotBecomeCompletedOrRevive() async throws {
        let harness = try make()
        let draft = try await seedDraft(harness)
        await rejects { _ = try await harness.store.apply(.completeArrangement(id: self.itemID, recordID: self.recordID, note: "合成未获确认"), expectedRevision: draft.revision) }
        let cancelled = try await apply(.cancelArrangement(id: itemID), to: harness)
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(.completeArrangement(id: self.itemID, recordID: self.recordID, note: "合成迟到结果"), expectedRevision: cancelled.revision) }
        await rejects { _ = try await harness.store.apply(.confirmArrangement(id: self.itemID), expectedRevision: cancelled.revision) }
        XCTAssertEqual(cancelled.arrangements.first?.state, .cancelled)
        XCTAssertTrue(cancelled.records.isEmpty)
        try await assertDiskUnchanged(harness, data: bytes, workspace: cancelled)
    }

    func testRepeatedCompletionCreatesOnlyOneRecordAndBlankNoteUsesTitle() async throws {
        let harness = try make()
        try await seedDraft(harness)
        try await apply(.confirmArrangement(id: itemID), to: harness)
        let completed = try await apply(.completeArrangement(id: itemID, recordID: recordID, note: "  "), to: harness)
        let again = try await apply(.completeArrangement(id: itemID, recordID: stableID("parenting-test-second-completion"), note: "合成重复点击"), to: harness)
        XCTAssertEqual(completed.records.first?.text, completed.arrangements.first?.title)
        XCTAssertEqual(completed.records.first?.sourceText, "  ")
        XCTAssertEqual(again.records, completed.records)
        XCTAssertEqual(again.records.count, 1)
    }

    func testDeletingGoalClearsReferencesAndKeepsArrangementAndObservation() async throws {
        let harness = try make()
        try await seedDraft(harness, linkedGoal: true)
        try await apply(.addObservation(id: recordID, childID: childID, goalID: goalID, text: "合成成长观察"), to: harness)
        let removed = try await apply(.deleteGoal(id: goalID), to: harness)
        XCTAssertTrue(removed.goals.isEmpty)
        XCTAssertEqual(removed.arrangements.count, 1)
        XCTAssertNil(removed.arrangements.first?.goalID)
        XCTAssertEqual(removed.records.count, 1)
        XCTAssertNil(removed.records.first?.goalID)
        try removed.validate()
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, removed)
    }

    func testDeletingChildRemovesOnlyThatChildsReferencesAndSurvivesReopen() async throws {
        let harness = try make()
        try await seedDraft(harness, linkedGoal: true)
        try await apply(.addObservation(id: recordID, childID: childID, goalID: goalID, text: "合成将删除观察"), to: harness)
        let otherChild = stableID("parenting-test-other-child")
        let otherRecord = stableID("parenting-test-other-observation")
        try await apply(.addChild(id: otherChild, name: "合成小月"), to: harness)
        try await apply(.addObservation(id: otherRecord, childID: otherChild, goalID: nil, text: "合成保留观察"), to: harness)
        let removed = try await apply(.deleteChild(id: childID), to: harness)
        XCTAssertEqual(removed.children.map(\.id), [otherChild])
        XCTAssertTrue(removed.goals.isEmpty)
        XCTAssertTrue(removed.arrangements.isEmpty)
        XCTAssertEqual(removed.records.map(\.id), [otherRecord])
        try removed.validate()
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, removed)
    }

    func testDeletingArrangementPreservesIndependentEditableCompletionRecord() async throws {
        let harness = try make()
        try await seedDraft(harness)
        try await apply(.confirmArrangement(id: itemID), to: harness)
        try await apply(.completeArrangement(id: itemID, recordID: recordID, note: "合成完成观察"), to: harness)
        let removed = try await apply(.deleteArrangement(id: itemID), to: harness)
        XCTAssertTrue(removed.arrangements.isEmpty)
        XCTAssertEqual(removed.records.count, 1)
        XCTAssertEqual(removed.records.first?.id, recordID)
        XCTAssertNil(removed.records.first?.arrangementID)
        let edited = try await apply(.editRecord(id: recordID, text: "合成更正后的观察"), to: harness)
        XCTAssertEqual(edited.records.first?.text, "合成更正后的观察")
        XCTAssertEqual(edited.records.first?.sourceText, "合成完成观察")
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, edited)
        let deleted = try await apply(.deleteRecord(id: recordID), to: harness)
        XCTAssertTrue(deleted.records.isEmpty)
    }

    func testStaleRevisionAndWrongChildGoalRejectWithoutChangingSavedDraft() async throws {
        let harness = try make()
        let draft = try await seedDraft(harness, linkedGoal: true)
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(.confirmArrangement(id: self.itemID), expectedRevision: draft.revision - 1) }
        await rejects { _ = try await harness.store.apply(.createDraft(id: stableID("parenting-test-invalid-ref"), childID: stableID("parenting-test-missing-child"), title: "合成无效关联", dueAt: self.now, goalID: self.goalID, sourceText: ""), expectedRevision: draft.revision) }
        try await assertDiskUnchanged(harness, data: bytes, workspace: draft)
    }

    func testSuggestionsChoicePersistsWithoutChangingExistingArrangement() async throws {
        let harness = try make()
        let draft = try await seedDraft(harness)
        let enabled = try await apply(.setSuggestionsEnabled(true), to: harness)
        let paused = try await apply(.setSuggestionsEnabled(false), to: harness)
        XCTAssertTrue(enabled.suggestionsEnabled)
        XCTAssertFalse(paused.suggestionsEnabled)
        XCTAssertEqual(paused.arrangements, draft.arrangements)
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, paused)
    }

    func testOldEpochCannotReadOrWriteAfterSameSubjectSignsInAgain() async throws {
        let harness = try make()
        let draft = try await seedDraft(harness)
        let bytes = try Data(contentsOf: harness.url)
        harness.epoch.signOut()
        harness.epoch.activate(account: harness.subject.uuidString)
        await rejects { _ = try await harness.store.load() }
        await rejects { _ = try await harness.store.apply(.confirmArrangement(id: self.itemID), expectedRevision: draft.revision) }
        XCTAssertEqual(try Data(contentsOf: harness.url), bytes)
        let fresh = try await reopen(harness).load()
        XCTAssertEqual(fresh, draft)
    }

    func testEpochChangeDuringSealPreventsRepositoryCommit() async throws {
        let harness = try make()
        let instant = now
        let store = ParentingWorkspaceStore(repository: harness.repository, scope: harness.scope, subjectID: harness.subject, epoch: harness.epoch, cipher: ParentingEpochChangingCipher(epoch: harness.epoch), clock: { instant })
        await rejects { _ = try await store.apply(.addChild(id: self.childID, name: "合成过期操作"), expectedRevision: 0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
        let saved = await harness.repository.read(scope: harness.scope)
        XCTAssertTrue(saved.records.isEmpty)
        XCTAssertTrue(saved.journal.isEmpty)
    }

    func testTwoSubjectPartitionsInSameRepositoryNeverReadEachOthersLedger() async throws {
        let harness = try make()
        let original = try await seedDraft(harness)
        let other = stableID("parenting-test-other-subject")
        let otherScope = AuthenticatedLocalPartition(issuer: "https://parenting-fixture.invalid", subject: other, serverScopeID: stableID("parenting-test-server-scope")).scope
        let otherEpoch = AccountEpoch(account: other.uuidString)
        let instant = now
        let otherStore = ParentingWorkspaceStore(repository: harness.repository, scope: otherScope, subjectID: other, epoch: otherEpoch, cipher: ParentingTestCipher(), clock: { instant })
        let empty = try await otherStore.load()
        XCTAssertEqual(empty, .empty)
        let otherSaved = try await otherStore.apply(.addChild(id: childID, name: "合成独立家庭"), expectedRevision: 0)
        XCTAssertEqual(otherSaved.children.first?.name, "合成独立家庭")
        let stillOriginal = try await harness.store.load()
        XCTAssertEqual(stillOriginal, original)
        let coldRepository = try Repository(persistence: FilePersistence(url: harness.url))
        let coldOther = ParentingWorkspaceStore(repository: coldRepository, scope: otherScope, subjectID: other, epoch: otherEpoch, cipher: ParentingTestCipher(), clock: { instant })
        let coldOtherValue = try await coldOther.load()
        XCTAssertEqual(coldOtherValue, otherSaved)
        XCTAssertNotEqual(ParentingWorkspaceStore.recordID(scope: harness.scope, subjectID: harness.subject), ParentingWorkspaceStore.recordID(scope: otherScope, subjectID: other))
    }

    func testSubjectAndEpochMismatchCannotCreateLedger() async throws {
        let harness = try make()
        let instant = now
        let wrongSubject = ParentingWorkspaceStore(repository: harness.repository, scope: harness.scope, subjectID: stableID("parenting-test-wrong-subject"), epoch: harness.epoch, cipher: ParentingTestCipher(), clock: { instant })
        let missingSubject = ParentingWorkspaceStore(repository: harness.repository, scope: harness.scope, subjectID: nil, epoch: harness.epoch, cipher: ParentingTestCipher(), clock: { instant })
        for store in [wrongSubject, missingSubject] {
            await rejects { _ = try await store.load() }
            await rejects { _ = try await store.apply(.addChild(id: self.childID, name: "合成未授权输入"), expectedRevision: 0) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
    }

    private func corruptStoredPreference(_ harness: Harness, transform: (String) throws -> String) async throws {
        let id = ParentingWorkspaceStore.recordID(scope: harness.scope, subjectID: harness.subject)
        let record = try await harness.repository.record(id, scope: harness.scope)
        guard case .preference(var preference) = record.payload else { return XCTFail("Expected real parenting preference") }
        preference.value = try transform(preference.value)
        try await harness.repository.commit(scope: harness.scope, mutations: [.update(id, record.header.revision, .preference(preference))])
    }

    private func assertCorruptStorageBlocksOverwrite(_ harness: Harness) async throws {
        let bytes = try Data(contentsOf: harness.url)
        let cold = try reopen(harness)
        await rejects { _ = try await cold.load() }
        await rejects { _ = try await cold.apply(.addChild(id: stableID("parenting-test-must-not-overwrite"), name: "合成覆盖尝试"), expectedRevision: 0) }
        XCTAssertEqual(try Data(contentsOf: harness.url), bytes, "Corrupt data must remain available for recovery")
    }

    func testCorruptCiphertextIsNotTreatedAsEmptyAndCannotBeOverwritten() async throws {
        let harness = try make()
        try await seedDraft(harness)
        try await corruptStoredPreference(harness) { _ in "parenting-sealed-v1:" + Data("synthetic-damaged-envelope".utf8).base64EncodedString() }
        try await assertCorruptStorageBlocksOverwrite(harness)
    }

    func testUnsupportedSavedEnvelopeSchemaIsNotTreatedAsEmpty() async throws {
        let harness = try make()
        try await seedDraft(harness)
        let owner = harness.subject
        try await corruptStoredPreference(harness) { stored in
            let prefix = "parenting-sealed-v1:"
            let sealed = try XCTUnwrap(Data(base64Encoded: String(stored.dropFirst(prefix.count))))
            let plain = try ParentingTestCipher().open(sealed, subjectID: owner)
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
            envelope["schemaVersion"] = 999
            let invalid = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            return prefix + (try ParentingTestCipher().seal(invalid, subjectID: owner)).base64EncodedString()
        }
        try await assertCorruptStorageBlocksOverwrite(harness)
    }

    func testInvalidDecodedWorkspaceReferencesAreRejectedBeforeMutation() throws {
        let child = ParentingChild(id: childID, name: "合成小星", createdAt: now)
        let goal = ParentingGoal(id: goalID, childID: stableID("parenting-test-missing-owner"), title: "合成孤立目标", createdAt: now)
        let corrupt = ParentingWorkspace(revision: 1, children: [child], goals: [goal])
        XCTAssertThrowsError(try corrupt.validate())
        XCTAssertThrowsError(try corrupt.applying(.renameChild(id: childID, name: "合成不能覆盖"), now: now))
        XCTAssertEqual(corrupt.children.first?.name, "合成小星")
    }

    @MainActor func testModelPublishesOnlyDurableSuccessAndKeepsPriorWorkspaceOnFailure() async throws {
        let harness = try make()
        let draft = try await seedDraft(harness)
        let model = ParentingWorkspaceModel(store: harness.store)
        await model.load()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.workspace, draft)
        harness.persistence.failNextSave()
        let failed = await model.apply(.confirmArrangement(id: itemID))
        XCTAssertFalse(failed)
        XCTAssertEqual(model.workspace, draft)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.busy)
        let retried = await model.apply(.confirmArrangement(id: itemID))
        XCTAssertTrue(retried)
        XCTAssertEqual(model.workspace.arrangements.first?.state, .planned)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy)
    }
}

/// Exercises the production intake parser against synthetic conversation records only.
final class ParentingIntakeTests: XCTestCase {
    private let subject = stableID("parenting-intake-synthetic-subject")
    private let child = stableID("parenting-intake-synthetic-child")
    private let goal = stableID("parenting-intake-synthetic-goal")
    private let conversation = stableID("parenting-intake-synthetic-conversation")
    private let instant = Date(timeIntervalSince1970: 1_792_756_800)

    private func makeRequest(source: String = "明天15:00合成绘本时间", known: Set<UUID> = []) throws -> ParentingIntakeRequest {
        let scope = AuthenticatedLocalPartition(issuer: "https://parenting-intake.invalid", subject: subject, serverScopeID: stableID("parenting-intake-scope")).scope
        let token = try XCTUnwrap(AccountEpoch(account: subject.uuidString).capture())
        return try ParentingIntakeRequest(id: stableID("parenting-intake-synthetic-nonce"), scope: scope, subjectID: subject, accountToken: token, conversationID: conversation, sourceText: source, childID: child, goalID: goal, knownTurnIDs: known, now: instant, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
    }

    private func object(_ request: ParentingIntakeRequest) -> [String: Any] {
        ["schema_version": 1, "contract": ParentingIntakeRequest.contract, "request_id": request.id.uuidString.lowercased(),
         "title": "合成绘本时间", "due_at": NSNull(), "time_evidence": NSNull(), "clarification": "请核对时间"]
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func makeSession(_ request: ParentingIntakeRequest, body: String, turnID: UUID? = nil,
                         state: ConversationTurnRecord.State = .completed, prompt: String? = nil,
                         operationID: UUID? = nil, assistantComplete: Bool = true, assistantFailure: String? = nil,
                         assistantRole: ConversationTranscriptMessage.Role = .assistant,
                         toolName: String? = nil) -> ConversationSession {
        let turnID = turnID ?? request.id
        let user = ConversationTranscriptMessage(id: stableID("parenting-intake-user-\(turnID)"), role: .user, content: prompt ?? request.prompt, createdAt: instant)
        var assistant = ConversationTranscriptMessage(id: stableID("parenting-intake-answer-\(turnID)"), role: assistantRole, content: body, toolName: toolName, complete: assistantComplete, createdAt: instant)
        assistant.failure = assistantFailure
        let wire = ConversationTurnRequest(scope: request.scope, conversationID: request.conversationID, threadID: nil, operationID: operationID ?? turnID, epoch: 0, history: [user])
        var turn = ConversationTurnRecord(id: turnID, request: wire, state: state, lastSequence: 2, error: nil)
        turn.assistantMessageID = assistant.id
        var value = ConversationSession(scope: request.scope, conversationID: request.conversationID)
        value.messages = [user, assistant]; value.turns = [turn]
        return value
    }

    private func assertError(_ expected: ParentingIntakeError, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? ParentingIntakeError, expected, file: file, line: line)
        }
    }

    func testCompletedReplyKeepsSelectedIdentityAndUnknownDateWithoutGuessing() throws {
        let request = try makeRequest(source: "合成原话：找一天读绘本")
        let value = makeSession(request, body: try json(object(request)))
        let draft = try request.parse(session: value, currentAccount: request.accountToken)
        XCTAssertEqual(draft.childID, child)
        XCTAssertEqual(draft.goalID, goal)
        XCTAssertEqual(draft.sourceText, request.sourceText)
        XCTAssertNil(draft.dueAt)
        XCTAssertEqual(draft.clarification, "请核对时间")
    }

    func testExplicitDateWithLiteralSourceEvidenceCanBecomeEditableCandidate() throws {
        let request = try makeRequest()
        var body = object(request)
        body["due_at"] = "2026-10-24T15:00:00Z"
        body["time_evidence"] = "明天15:00"
        body["clarification"] = NSNull()
        let draft = try request.parse(session: makeSession(request, body: try json(body)), currentAccount: request.accountToken)
        XCTAssertEqual(draft.dueAt, ISO8601DateFormatter().date(from: "2026-10-24T15:00:00Z"))
        XCTAssertEqual(draft.sourceText, request.sourceText)
    }

    func testKnownTurnsOtherTopicsAndMismatchedOperationsAreNotImported() throws {
        let turn = stableID("parenting-intake-synthetic-nonce")
        let knownRequest = try makeRequest(known: [turn])
        let known = makeSession(knownRequest, body: try json(object(knownRequest)))
        assertError(.noReply) { _ = try knownRequest.parse(session: known, currentAccount: knownRequest.accountToken) }
        let request = try makeRequest()
        let body = try json(object(request))
        for value in [makeSession(request, body: body, prompt: request.prompt + "\n"),
                      makeSession(request, body: body, prompt: "合成其他话题"),
                      makeSession(request, body: body, turnID: stableID("parenting-intake-wrong-turn")),
                      makeSession(request, body: body, operationID: stableID("parenting-intake-wrong-operation"))] {
            assertError(.noReply) { _ = try request.parse(session: value, currentAccount: request.accountToken) }
        }
    }

    func testStreamingFailedUnknownAndIncompleteRepliesCannotBecomeDrafts() throws {
        let request = try makeRequest()
        let body = try json(object(request))
        for state in [ConversationTurnRecord.State.dispatched, .running, .failed, .unknown, .notSent, .cancelledBeforeSend] {
            let value = makeSession(request, body: body, state: state)
            assertError(.unfinishedReply) { _ = try request.parse(session: value, currentAccount: request.accountToken) }
        }
        for value in [makeSession(request, body: body, assistantComplete: false), makeSession(request, body: body, assistantFailure: "synthetic_failure"),
                      makeSession(request, body: body, assistantRole: .tool), makeSession(request, body: body, toolName: "synthetic_tool")] {
            assertError(.unfinishedReply) { _ = try request.parse(session: value, currentAccount: request.accountToken) }
        }
    }

    func testChangedAccountConversationAndAmbiguousMatchesAreRejected() throws {
        let request = try makeRequest()
        let body = try json(object(request))
        let value = makeSession(request, body: body)
        assertError(.changedAccount) { _ = try request.parse(session: value, currentAccount: nil) }
        let newer = AccountEpoch(account: subject.uuidString); newer.bump()
        assertError(.changedAccount) { _ = try request.parse(session: value, currentAccount: newer.capture()) }
        let wrongConversation = ConversationSession(scope: request.scope, conversationID: stableID("parenting-intake-other-conversation"))
        assertError(.changedConversation) { _ = try request.parse(session: wrongConversation, currentAccount: request.accountToken) }
        let wrongScope = ConversationSession(scope: Profiles.demo, conversationID: request.conversationID)
        assertError(.changedConversation) { _ = try request.parse(session: wrongScope, currentAccount: request.accountToken) }
        var ambiguous = value
        let extra = makeSession(request, body: body)
        ambiguous.messages += extra.messages; ambiguous.turns += extra.turns
        assertError(.ambiguousReply) { _ = try request.parse(session: ambiguous, currentAccount: request.accountToken) }
    }

    func testNonceExtraIdentityDuplicateKeysAndMalformedJSONAreRejected() throws {
        let request = try makeRequest()
        let valid = object(request)
        var wrongNonce = valid; wrongNonce["request_id"] = stableID("parenting-intake-wrong-nonce").uuidString.lowercased()
        var extraIdentity = valid; extraIdentity["child_id"] = stableID("parenting-intake-untrusted-child").uuidString.lowercased()
        var booleanVersion = valid; booleanVersion["schema_version"] = true
        let duplicate = "{\"schema_version\":1,\"contract\":\"\(ParentingIntakeRequest.contract)\",\"request_id\":\"\(request.id.uuidString.lowercased())\",\"title\":\"合成甲\",\"title\":\"合成乙\",\"due_at\":null,\"time_evidence\":null,\"clarification\":null}"
        for body in [try json(wrongNonce), try json(extraIdentity), try json(booleanVersion), duplicate, "not JSON", "```json\n\(try json(valid))\n```"] {
            assertError(.invalidReply) { _ = try request.parse(session: makeSession(request, body: body), currentAccount: request.accountToken) }
        }
    }

    func testDatesWithoutLiteralDateAndClockEvidenceAreRejected() throws {
        let request = try makeRequest()
        for evidence in [NSNull(), "后天15:00", "明天"] as [Any] {
            var body = object(request); body["due_at"] = "2026-10-24T15:00:00Z"; body["time_evidence"] = evidence
            assertError(.missingTimeEvidence) { _ = try request.parse(session: makeSession(request, body: try json(body)), currentAccount: request.accountToken) }
        }
        var body = object(request); body["time_evidence"] = "明天15:00"
        assertError(.invalidReply) { _ = try request.parse(session: makeSession(request, body: try json(body)), currentAccount: request.accountToken) }
    }

    func testInterveningUserOrToolMessageCannotBeReadAsThisIntakeAnswer() throws {
        let request = try makeRequest()
        let body = try json(object(request))
        for role in [ConversationTranscriptMessage.Role.user, .tool] {
            var value = makeSession(request, body: body)
            value.messages.insert(.init(role: role, content: "合成插入话题", createdAt: instant), at: 1)
            assertError(.invalidReply) { _ = try request.parse(session: value, currentAccount: request.accountToken) }
        }
    }
}

/// A controllable transport boundary for the real inline controller and session service.
/// It does not implement the controller, parser, consent flow or persistence state machine.
private actor ParentingInlineTestBackend: ConversationBackend, ParentingIntakeDataDeleting {
    enum ReplyMode: Sendable, Equatable { case completed, notSentOnce, transportUnknown, held, invalidOutput, forbiddenSideChannel }
    struct Calls: Sendable {
        var prepared: [UUID] = []
        var submitted: [ConversationTurnRequest] = []
        var observed: [ConversationTurnRequest] = []
        var cancelled: [ConversationTurnRequest] = []
        var deleted: [UUID] = []
        var consentGrants = 0
    }
    private var calls = Calls()
    private var mode: ReplyMode
    private var needsConsent: Bool
    private var preparationFailsOnce: Bool
    private var heldReplies: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var replyReleased = false
    private var observationCompletes = false
    private var cancelledIDs = Set<UUID>()
    private var deletionFails = false
    private let replyStarted: (@Sendable () -> Void)?
    private let cancelStarted: (@Sendable () -> Void)?
    private let routeHash = textHash("parenting-inline-synthetic-route")

    init(mode: ReplyMode = .completed, needsConsent: Bool = false, preparationFailsOnce: Bool = false, replyStarted: (@Sendable () -> Void)? = nil, cancelStarted: (@Sendable () -> Void)? = nil) {
        self.mode = mode; self.needsConsent = needsConsent; self.preparationFailsOnce = preparationFailsOnce
        self.replyStarted = replyStarted; self.cancelStarted = cancelStarted
    }
    func captured() -> Calls { calls }
    func completeOnObservation() { observationCompletes = true }
    func setDeletionFailure(_ value: Bool) { deletionFails = value }
    func releaseReply() {
        replyReleased = true
        let pending = Array(heldReplies.values); heldReplies.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func connection(scope: DataScope) async -> ConversationConnection {
        .init(state: .providerUnverified, provider: "Synthetic inline test boundary", detail: "No HTTP, Auth or model")
    }
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? {
        calls.prepared.append(conversationID)
        if preparationFailsOnce {
            preparationFailsOnce = false
            // The real HTTP adapter prepares its remote conversation at this boundary.
            // Refuse before that remote create; no server lifecycle is implemented by this mock.
            throw URLError(.notConnectedToInternet)
        }
        return needsConsent ? .init(conversationID: conversationID, title: "Synthetic model consent", body: "Injected reply only; no production service", routeHash: routeHash, expectedRevision: 0) : nil
    }
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws {
        guard needsConsent, consent.routeHash == routeHash, consent.expectedRevision == 0 else { throw ConversationSessionError.invalidEvent }
        calls.consentGrants += 1; needsConsent = false
    }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        calls.submitted.append(request); replyStarted?()
        if mode == .notSentOnce, calls.submitted.count == 1 {
            throw ConversationDispatchFailure.notSent(reason: "Synthetic refusal before dispatch")
        }
        if mode == .transportUnknown { throw URLError(.networkConnectionLost) }
        if mode == .held, !replyReleased { await withCheckedContinuation { heldReplies[request.operationID] = $0 } }
        if mode == .forbiddenSideChannel {
            return AsyncThrowingStream { continuation in
                continuation.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .sideChannel(type: "memory.update", data: Data("{}".utf8))))
                continuation.finish()
            }
        }
        let events = try Self.completedEvents(request, invalidOutput: mode == .invalidOutput)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        calls.observed.append(request)
        if cancelledIDs.contains(request.operationID) {
            return .init(request: request, events: [.init(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .failed(message: "cancelled", reconciliationRequired: false))], serverState: "failed")
        }
        let events: [ConversationTurnEvent]
        if observationCompletes { events = try Self.completedEvents(request) }
        else { events = [] }
        return .init(request: request, events: events, serverState: observationCompletes ? "completed" : "running")
    }
    func cancelTurn(_ request: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt {
        calls.cancelled.append(request); cancelledIDs.insert(request.operationID); cancelStarted?()
        return .init(turnID: request.operationID, state: "failed", cancelled: true, alreadyTerminal: false)
    }
    func deleteIntake(scope: DataScope, conversationID: UUID) async throws {
        calls.deleted.append(conversationID)
        if deletionFails { throw URLError(.networkConnectionLost) }
    }
    private static func completedEvents(_ request: ConversationTurnRequest, invalidOutput: Bool = false) throws -> [ConversationTurnEvent] {
        let prompt = request.history.last?.content ?? ""
        let regex = try NSRegularExpression(pattern: #""request_id"\s*:\s*"([0-9a-f-]{36})""#)
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = regex.firstMatch(in: prompt, range: range), let idRange = Range(match.range(at: 1), in: prompt) else { throw ConversationSessionError.invalidEvent }
        let body: [String: Any] = ["schema_version": 1, "contract": ParentingIntakeRequest.contract, "request_id": String(prompt[idRange]), "title": "合成原位绘本草稿", "due_at": NSNull(), "time_evidence": NSNull(), "clarification": "请补充明确日期和钟点"]
        let text = invalidOutput ? "Synthetic malformed reply" : String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        let message = stableID("parenting-inline-answer-\(request.operationID)")
        return [.init(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .textDelta(messageID: message, text: text)),
                .init(operationID: request.operationID, epoch: request.epoch, sequence: 2, payload: .completed(messageID: message, finalTextHash: textHash(text)))]
    }
}

private final class ParentingInlineTestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let prefix: String
    init(prefix: String = "parenting-inline-synthetic-id") { self.prefix = prefix }
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }
        index += 1
        return stableID("\(prefix)-\(index)")
    }
}

private final class ParentingInlineReplyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

private struct ParentingInlineRejectingCipher: ParentingWorkspaceCipher {
    func seal(_ plain: Data, subjectID: UUID) throws -> Data { throw ParentingInlineIntakeError.storage }
    func open(_ sealed: Data, subjectID: UUID) throws -> Data { try ParentingTestCipher().open(sealed, subjectID: subjectID) }
}

private struct ParentingInlineDeletingCipher: ParentingWorkspaceCipher {
    let url: URL
    let epoch: AccountEpoch
    func seal(_ plain: Data, subjectID: UUID) throws -> Data {
        let sealed = try ParentingTestCipher().seal(plain, subjectID: subjectID)
        try ParentingIntakePersistence.deleteJournal(at: url, subjectID: subjectID, epoch: epoch)
        return sealed
    }
    func open(_ sealed: Data, subjectID: UUID) throws -> Data { try ParentingTestCipher().open(sealed, subjectID: subjectID) }
}

/// Intercepts every request in the injected URLSession, including unexpected URLs.
/// Replies are fixed wire fixtures; no server deletion or tombstone algorithm lives here.
private final class ParentingIntakeDeleteWireProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case response(status: Int, body: Data), offline }
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var captured: [String: [URLRequest]] = [:]

    static func install(_ reply: Reply, host: String) {
        lock.lock(); defer { lock.unlock() }
        replies[host] = reply; captured[host] = []
    }
    static func requests(host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return captured[host] ?? []
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }; replies.removeValue(forKey: host); captured.removeValue(forKey: host)
    }
    private static func receive(_ request: URLRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        guard let host = request.url?.host else { return nil }
        captured[host, default: []].append(request)
        return replies[host]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.receive(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        switch reply {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .response(let status, let body):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private actor ParentingIntakeDeleteWireCredentials: NativeChatSessionCredentials {
    let expectedScope: DataScope
    private var rejections = 0
    init(scope: DataScope) { expectedScope = scope }
    func authorization(scope: DataScope) async throws -> String {
        guard scope == expectedScope else { throw catError.scopeMismatch }
        return "Bearer explicit-parenting-delete-fixture"
    }
    func rejected(scope: DataScope) async { if scope == expectedScope { rejections += 1 } }
    func rejectionCount() -> Int { rejections }
}

@MainActor final class ParentingInlineIntakeTests: XCTestCase {
    private let subject = stableID("parenting-inline-test-subject")
    private let child = stableID("parenting-inline-test-child")
    private let goal = stableID("parenting-inline-test-goal")
    private let instant = Date(timeIntervalSince1970: 1_792_756_800)

    private struct Entry {
        let url: URL
        let storage: ParentingIntakePersistence
        let repository: Repository
        let service: ConversationSessionService
    }
    @MainActor private final class Entries {
        var values: [Entry] = []
        var rejectSealing = false
    }
    @MainActor private final class Admission { var allowed = true }
    private struct Harness {
        let model: ParentingInlineIntakeModel
        let backend: ParentingInlineTestBackend
        let scope: DataScope
        let epoch: AccountEpoch
        let entries: Entries
        let admission: Admission
        let recovery: ParentingIntakeRecoveryFile?
        let cleanup: ParentingIntakeCleanupFile?
        let directory: URL
    }

    private func make(backend: ParentingInlineTestBackend = .init(), rejectSealing: Bool = false, withRecovery: Bool = false) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-inline-synthetic-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let scope = AuthenticatedLocalPartition(issuer: "https://parenting-inline.invalid", subject: subject, serverScopeID: stableID("parenting-inline-scope")).scope
        let epoch = AccountEpoch(account: subject.uuidString)
        let entries = Entries(); entries.rejectSealing = rejectSealing
        let admission = Admission(), ids = ParentingInlineTestIDs(), owner = subject, now = instant
        let recovery = withRecovery ? ParentingIntakeRecoveryFile(scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher(), url: directory.appendingPathComponent("recovery.sealed")) : nil
        let cleanup = withRecovery ? ParentingIntakeCleanupFile(scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher(), url: directory.appendingPathComponent("cleanup.sealed")) : nil
        let factory: ParentingIntakeServiceFactory = {
            let url = directory.appendingPathComponent("request-\(entries.values.count).sealed")
            let cipher: any ParentingWorkspaceCipher = entries.rejectSealing ? ParentingInlineRejectingCipher() : ParentingTestCipher()
            let persistence = ParentingIntakePersistence(url: url, scope: scope, subjectID: owner, epoch: epoch, cipher: cipher)
            let repository = try Repository(persistence: persistence)
            let service = ConversationSessionService(repository: repository, backend: ParentingIntakeConversationBackend(base: backend))
            entries.values.append(.init(url: url, storage: persistence, repository: repository, service: service))
            return service
        }
        let purge: (@MainActor () throws -> Void)?
        if withRecovery {
            purge = { for entry in entries.values { try entry.storage.delete() } }
        } else {
            purge = nil
        }
        let model = ParentingInlineIntakeModel(scope: scope, subjectID: subject, factory: factory, admission: { admission.allowed }, epoch: epoch, clock: { now }, id: { ids.next() }, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)), recoveryStore: recovery, cleanupStore: cleanup, localPurge: purge)
        return .init(model: model, backend: backend, scope: scope, epoch: epoch, entries: entries, admission: admission, recovery: recovery, cleanup: cleanup, directory: directory)
    }

    private func coldModel(_ harness: Harness, at now: Date? = nil) throws -> ParentingInlineIntakeModel {
        let entry = try XCTUnwrap(harness.entries.values.first)
        let owner = subject, scope = harness.scope, epoch = harness.epoch, backend = harness.backend
        let instant = now ?? self.instant, admission = harness.admission
        let urls = harness.entries.values.map(\.url)
        let recovery = ParentingIntakeRecoveryFile(scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher(), url: harness.directory.appendingPathComponent("recovery.sealed"))
        let cleanup = ParentingIntakeCleanupFile(scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher(), url: harness.directory.appendingPathComponent("cleanup.sealed"))
        let factory: ParentingIntakeServiceFactory = {
            let storage = ParentingIntakePersistence(url: entry.url, scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher())
            let repository = try Repository(persistence: storage)
            return ConversationSessionService(repository: repository, backend: ParentingIntakeConversationBackend(base: backend))
        }
        let ids = ParentingInlineTestIDs(prefix: "parenting-inline-cold-id")
        return ParentingInlineIntakeModel(scope: scope, subjectID: owner, factory: factory, admission: { admission.allowed }, epoch: epoch, clock: { instant }, id: { ids.next() }, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)), recoveryStore: recovery, cleanupStore: cleanup, localPurge: {
            for url in urls { try ParentingIntakePersistence(url: url, scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher()).delete() }
        })
    }

    func testInlineSuccessUsesPrivateSealedJournalAndOnlyProducesCandidate() async throws {
        let harness = try make()
        let source = "合成原位输入：找一天读绘本，暂不确定时间"
        await harness.model.request(sourceText: source, childID: child, goalID: goal)
        XCTAssertEqual(harness.model.phase, .ready)
        XCTAssertFalse(harness.model.busy)
        let candidate = try XCTUnwrap(harness.model.candidate)
        XCTAssertEqual(candidate.sourceText, source)
        XCTAssertEqual(candidate.childID, child)
        XCTAssertEqual(candidate.goalID, goal)
        XCTAssertNil(candidate.dueAt)
        XCTAssertTrue(harness.model.isCurrentCandidate(candidate))
        let calls = await harness.backend.captured()
        let sent = try XCTUnwrap(calls.submitted.first)
        XCTAssertEqual(calls.submitted.count, 1)
        XCTAssertNotEqual(sent.operationID, sent.conversationID)
        XCTAssertTrue(sent.context.isEmpty)
        let entry = try XCTUnwrap(harness.entries.values.first)
        let bytes = try Data(contentsOf: entry.url)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(source))
        let coldPersistence = ParentingIntakePersistence(url: entry.url, scope: harness.scope, subjectID: subject, epoch: harness.epoch, cipher: ParentingTestCipher())
        let coldRepository = try Repository(persistence: coldPersistence)
        let coldService = ConversationSessionService(repository: coldRepository, backend: harness.backend)
        let cold = try await coldService.read(scope: harness.scope, conversationID: sent.conversationID)
        XCTAssertEqual(cold.turns.map(\.id), [sent.operationID])
        XCTAssertEqual(cold.turns.first?.state, .completed)
        let ledger = ParentingWorkspaceStore(repository: coldRepository, scope: harness.scope, subjectID: subject, epoch: harness.epoch, cipher: ParentingTestCipher())
        let workspace = try await ledger.load()
        XCTAssertEqual(workspace, .empty, "An AI candidate must not confirm or save an arrangement")
    }

    func testInlineAdmissionRefusalCreatesNoServiceAndSendsNothing() async throws {
        let harness = try make()
        harness.admission.allowed = false
        await harness.model.request(sourceText: "合成未准许输入", childID: child, goalID: nil)
        XCTAssertEqual(harness.model.phase, .failed)
        XCTAssertNil(harness.model.candidate)
        XCTAssertTrue(harness.entries.values.isEmpty)
        let calls = await harness.backend.captured()
        XCTAssertTrue(calls.submitted.isEmpty)
        XCTAssertEqual(calls.consentGrants, 0)
    }

    func testInlineConsentIsRequiredBeforeSendAndOnlyMatchingReviewCanAllow() async throws {
        let backend = ParentingInlineTestBackend(needsConsent: true)
        let harness = try make(backend: backend)
        await harness.model.request(sourceText: "合成许可待核对输入", childID: child, goalID: nil)
        XCTAssertEqual(harness.model.phase, .awaitingConsent)
        let review = try XCTUnwrap(harness.model.consentID)
        let waiting = await backend.captured()
        XCTAssertTrue(waiting.submitted.isEmpty)
        await harness.model.allowConsent(matchingID: stableID("parenting-inline-wrong-review"))
        XCTAssertEqual(harness.model.phase, .awaitingConsent)
        await harness.model.allowConsent(matchingID: review)
        XCTAssertEqual(harness.model.phase, .ready)
        let allowed = await backend.captured()
        XCTAssertEqual(allowed.consentGrants, 1)
        XCTAssertEqual(allowed.submitted.count, 1)
        await harness.model.allowConsent(matchingID: review)
        let duplicate = await backend.captured()
        XCTAssertEqual(duplicate.consentGrants, 1)
        XCTAssertEqual(duplicate.submitted.count, 1)
    }

    func testInlineDeferredOrSupersededConsentCannotAuthorizeLaterRequest() async throws {
        let backend = ParentingInlineTestBackend(needsConsent: true)
        let harness = try make(backend: backend)
        await harness.model.request(sourceText: "合成第一份许可输入", childID: child, goalID: nil)
        let oldReview = try XCTUnwrap(harness.model.consentID)
        harness.model.deferConsent(matchingID: oldReview)
        XCTAssertEqual(harness.model.phase, .cancelled)
        await harness.model.request(sourceText: "合成第二份许可输入", childID: child, goalID: goal)
        let newReview = try XCTUnwrap(harness.model.consentID)
        XCTAssertNotEqual(oldReview, newReview)
        await harness.model.allowConsent(matchingID: oldReview)
        harness.model.deferConsent(matchingID: oldReview)
        XCTAssertEqual(harness.model.phase, .awaitingConsent)
        let calls = await backend.captured()
        XCTAssertEqual(calls.consentGrants, 0)
        XCTAssertTrue(calls.submitted.isEmpty)
        await harness.model.allowConsent(matchingID: newReview)
        XCTAssertEqual(harness.model.phase, .ready)
    }

    func testInlineNotSentRetryUsesOriginalConversationTurnAndPrompt() async throws {
        let backend = ParentingInlineTestBackend(mode: .notSentOnce)
        let harness = try make(backend: backend)
        await harness.model.request(sourceText: "合成明确未发送输入", childID: child, goalID: nil)
        XCTAssertEqual(harness.model.phase, .failed)
        XCTAssertNil(harness.model.candidate)
        await harness.model.retry()
        XCTAssertEqual(harness.model.phase, .ready)
        let calls = await backend.captured()
        XCTAssertEqual(calls.submitted.count, 2)
        let first = try XCTUnwrap(calls.submitted.first), last = try XCTUnwrap(calls.submitted.last)
        XCTAssertEqual(last.operationID, first.operationID)
        XCTAssertEqual(last.conversationID, first.conversationID)
        XCTAssertEqual(last.history.last?.content, first.history.last?.content)
        XCTAssertEqual(harness.entries.values.count, 1)
        let entry = try XCTUnwrap(harness.entries.values.first)
        let saved = try await entry.service.read(scope: harness.scope, conversationID: first.conversationID)
        XCTAssertEqual(saved.turns.count, 1)
        XCTAssertEqual(saved.messages.filter { $0.role == .user }.count, 1)
    }

    func testInlineUnknownRetryOnlyReadsOriginalRequestAndCanReconcile() async throws {
        let backend = ParentingInlineTestBackend(mode: .transportUnknown)
        let harness = try make(backend: backend)
        await harness.model.request(sourceText: "合成响应丢失输入", childID: child, goalID: goal)
        XCTAssertEqual(harness.model.phase, .unknown)
        await harness.model.request(sourceText: "合成不能替换未知请求的新输入", childID: stableID("parenting-inline-other-child"), goalID: nil)
        XCTAssertEqual(harness.model.phase, .unknown)
        let afterDirectRequest = await backend.captured()
        XCTAssertEqual(afterDirectRequest.submitted.count, 1)
        XCTAssertEqual(harness.entries.values.count, 1)
        await harness.model.retry()
        XCTAssertEqual(harness.model.phase, .unknown)
        let unresolved = await backend.captured()
        XCTAssertEqual(unresolved.submitted.count, 1)
        XCTAssertFalse(unresolved.observed.isEmpty)
        await backend.completeOnObservation()
        await harness.model.reconcile()
        XCTAssertEqual(harness.model.phase, .ready)
        let calls = await backend.captured()
        let original = try XCTUnwrap(calls.submitted.first)
        XCTAssertEqual(calls.submitted.count, 1)
        XCTAssertTrue(calls.observed.allSatisfy { $0.operationID == original.operationID && $0.conversationID == original.conversationID })
        XCTAssertEqual(harness.entries.values.count, 1)
        XCTAssertEqual(harness.model.candidate?.sourceText, "合成响应丢失输入")
    }

    func testInlineCancellationTargetsOwnRequestAndLateReplyCannotRefill() async throws {
        let started = expectation(description: "Synthetic inline request reached the injected backend")
        let cancelled = expectation(description: "Cancellation reached the original request handle")
        let backend = ParentingInlineTestBackend(mode: .held, replyStarted: { started.fulfill() }, cancelStarted: { cancelled.fulfill() })
        let harness = try make(backend: backend)
        let pending = Task { await harness.model.request(sourceText: "合成取消输入", childID: self.child, goalID: nil) }
        await fulfillment(of: [started], timeout: 2)
        harness.model.cancel()
        XCTAssertEqual(harness.model.phase, .cancelled)
        XCTAssertFalse(harness.model.busy)
        await fulfillment(of: [cancelled], timeout: 2)
        await backend.releaseReply()
        await pending.value
        XCTAssertEqual(harness.model.phase, .cancelled)
        XCTAssertNil(harness.model.candidate)
        let calls = await backend.captured()
        let original = try XCTUnwrap(calls.submitted.first), stop = try XCTUnwrap(calls.cancelled.first)
        XCTAssertEqual(stop.operationID, original.operationID)
        XCTAssertEqual(stop.conversationID, original.conversationID)
    }

    func testInlineChangedSourceAndChildFenceEarlierLateCandidate() async throws {
        let started = expectation(description: "Both independent synthetic requests reached the backend")
        started.expectedFulfillmentCount = 2
        let firstStarted = expectation(description: "First synthetic request started")
        let counter = ParentingInlineReplyCounter()
        let backend = ParentingInlineTestBackend(mode: .held, replyStarted: {
            if counter.mark() == 1 { firstStarted.fulfill() }
            started.fulfill()
        })
        let harness = try make(backend: backend)
        // This notification waits on an actual transport call rather than a timer.
        let first = Task { await harness.model.request(sourceText: "合成旧原话", childID: self.child, goalID: nil) }
        await fulfillment(of: [firstStarted], timeout: 2)
        harness.model.invalidate() // The editor invalidates its frozen request when input or child changes.
        let otherChild = stableID("parenting-inline-second-child")
        let second = Task { await harness.model.request(sourceText: "合成新原话", childID: otherChild, goalID: self.goal) }
        await fulfillment(of: [started], timeout: 2)
        await backend.releaseReply()
        await second.value; await first.value
        XCTAssertEqual(harness.model.phase, .ready)
        XCTAssertEqual(harness.model.candidate?.sourceText, "合成新原话")
        XCTAssertEqual(harness.model.candidate?.childID, otherChild)
        XCTAssertEqual(harness.model.candidate?.goalID, goal)
        let calls = await backend.captured()
        XCTAssertEqual(calls.submitted.count, 2)
        XCTAssertEqual(Set(calls.submitted.map(\.operationID)).count, 2)
        XCTAssertEqual(Set(calls.submitted.map(\.conversationID)).count, 2)
        XCTAssertEqual(harness.entries.values.count, 2)
    }

    func testInlineEpochChangeRejectsLateCandidateAndInvalidationClearsIt() async throws {
        let started = expectation(description: "Synthetic request admitted before epoch change")
        let backend = ParentingInlineTestBackend(mode: .held, replyStarted: { started.fulfill() })
        let harness = try make(backend: backend)
        let pending = Task { await harness.model.request(sourceText: "合成旧账号原话", childID: self.child, goalID: nil) }
        await fulfillment(of: [started], timeout: 2)
        harness.epoch.bump()
        await backend.releaseReply(); await pending.value
        XCTAssertNil(harness.model.candidate)
        XCTAssertEqual(harness.model.phase, .cancelled)
        XCTAssertFalse(harness.model.busy)
        harness.model.invalidate()
        XCTAssertEqual(harness.model.phase, .idle)
        XCTAssertFalse(harness.model.busy)
    }

    func testInlineMalformedCompletedReplyIsNotAReadyCandidate() async throws {
        let backend = ParentingInlineTestBackend(mode: .invalidOutput)
        let harness = try make(backend: backend)
        await harness.model.request(sourceText: "合成格式错误回复输入", childID: child, goalID: nil)
        XCTAssertEqual(harness.model.phase, .failed)
        XCTAssertNil(harness.model.candidate)
        XCTAssertNotNil(harness.model.error)
        XCTAssertFalse(harness.model.busy)
    }

    func testInlineRestrictedBackendRejectsMemorySideChannelInsteadOfImporting() async throws {
        let harness = try make(backend: ParentingInlineTestBackend(mode: .forbiddenSideChannel))
        await harness.model.request(sourceText: "合成不允许记忆副通道的原话", childID: child, goalID: nil)
        XCTAssertNotEqual(harness.model.phase, .ready)
        XCTAssertNil(harness.model.candidate)
        let entry = try XCTUnwrap(harness.entries.values.first)
        let snapshot = await entry.repository.read(scope: harness.scope)
        XCTAssertFalse(snapshot.records.values.contains { if case .memory = $0.payload { return true }; return false })
    }

    func testInlineExplicitRetryAfterTerminalFailureUsesNewIdentity() async throws {
        let backend = ParentingInlineTestBackend(mode: .invalidOutput)
        let harness = try make(backend: backend)
        await harness.model.request(sourceText: "合成明确终态失败原话", childID: child, goalID: goal)
        XCTAssertEqual(harness.model.phase, .failed)
        XCTAssertTrue(harness.model.canRetry)
        await harness.model.retry()
        let calls = await backend.captured()
        XCTAssertEqual(calls.submitted.count, 2)
        XCTAssertEqual(Set(calls.submitted.map(\.operationID)).count, 2)
        XCTAssertEqual(Set(calls.submitted.map(\.conversationID)).count, 2)
        XCTAssertTrue(calls.submitted.allSatisfy { $0.history.last?.content.contains("合成明确终态失败原话") == true })
        XCTAssertNil(harness.model.candidate)
    }

    func testInlineDuplicateTapWhileBusyDoesNotCreateAnotherRequest() async throws {
        let started = expectation(description: "Original synthetic request is waiting at transport")
        let duplicateReturned = expectation(description: "Second explicit tap returned through the busy guard")
        let backend = ParentingInlineTestBackend(mode: .held, replyStarted: { started.fulfill() })
        let harness = try make(backend: backend)
        let first = Task { await harness.model.request(sourceText: "合成重复点击原话", childID: self.child, goalID: nil) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(harness.model.busy)
        let duplicate = Task {
            await harness.model.request(sourceText: "合成重复点击原话", childID: self.child, goalID: nil)
            duplicateReturned.fulfill()
        }
        await fulfillment(of: [duplicateReturned], timeout: 2)
        await backend.releaseReply()
        await first.value; await duplicate.value
        let calls = await backend.captured()
        XCTAssertEqual(calls.submitted.count, 1)
        XCTAssertEqual(harness.entries.values.count, 1)
    }

    func testInlineSealingFailurePreventsAnyBackendSendOrPlaintextFallback() async throws {
        let harness = try make(rejectSealing: true)
        await harness.model.request(sourceText: "合成不能明文落盘的原话", childID: child, goalID: nil)
        XCTAssertEqual(harness.model.phase, .failed)
        XCTAssertNil(harness.model.candidate)
        let calls = await harness.backend.captured()
        XCTAssertTrue(calls.submitted.isEmpty)
        for entry in harness.entries.values { XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path)) }
    }

    func testInlineCorruptSealedJournalCannotBeReopenedOrOverwrittenAsEmpty() async throws {
        let harness = try make()
        await harness.model.request(sourceText: "合成损坏前原话", childID: child, goalID: nil)
        let entry = try XCTUnwrap(harness.entries.values.first)
        let damaged = Data("synthetic damaged sealed journal".utf8)
        try damaged.write(to: entry.url, options: .atomic)
        let storage = ParentingIntakePersistence(url: entry.url, scope: harness.scope, subjectID: subject, epoch: harness.epoch, cipher: ParentingTestCipher())
        XCTAssertThrowsError(try Repository(persistence: storage))
        XCTAssertEqual(try Data(contentsOf: entry.url), damaged)
    }

    func testInlineLiveRepositoryRefusesToOverwriteChangedOrRemovedJournal() async throws {
        for remove in [false, true] {
            let harness = try make()
            await harness.model.request(sourceText: "合成已确认写盘的原话", childID: child, goalID: nil)
            let entry = try XCTUnwrap(harness.entries.values.first)
            let before = await entry.repository.read(scope: harness.scope)
            let damaged = Data("synthetic externally changed journal".utf8)
            if remove { try FileManager.default.removeItem(at: entry.url) }
            else { try damaged.write(to: entry.url, options: .atomic) }
            do {
                try await entry.repository.setPreference(scope: harness.scope, key: "parenting-inline-synthetic-probe", value: "must not overwrite")
                XCTFail("Changed or removed persistent bytes must block the old live writer")
            } catch { }
            let after = await entry.repository.read(scope: harness.scope)
            XCTAssertEqual(after.sequence, before.sequence)
            XCTAssertEqual(after.records.count, before.records.count)
            if remove { XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path)) }
            else { XCTAssertEqual(try Data(contentsOf: entry.url), damaged) }
        }
    }

    func testInlineDeletionBeforeFirstWriteRevokesOldWriterAndAllowsFreshGeneration() throws {
        let harness = try make()
        let url = harness.directory.appendingPathComponent("first-write.sealed")
        let old = ParentingIntakePersistence(url: url, scope: harness.scope, subjectID: subject, epoch: harness.epoch, cipher: ParentingTestCipher())
        _ = try old.load() // A valid missing-file read must not authorize resurrection after deletion.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try ParentingIntakePersistence.deleteJournal(at: url, subjectID: subject, epoch: harness.epoch)
        XCTAssertThrowsError(try old.save(StoreSnapshot()))
        XCTAssertThrowsError(try old.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let fresh = ParentingIntakePersistence(url: url, scope: harness.scope, subjectID: subject, epoch: harness.epoch, cipher: ParentingTestCipher())
        try fresh.save(StoreSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try fresh.load().records.isEmpty)
        XCTAssertThrowsError(try old.save(StoreSnapshot()))
    }

    func testInlineDeletionDuringSealCannotRecreateFirstJournal() throws {
        let harness = try make()
        let url = harness.directory.appendingPathComponent("seal-window.sealed")
        let storage = ParentingIntakePersistence(url: url, scope: harness.scope, subjectID: subject, epoch: harness.epoch,
            cipher: ParentingInlineDeletingCipher(url: url, epoch: harness.epoch))
        _ = try storage.load()
        XCTAssertThrowsError(try storage.save(StoreSnapshot()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let fresh = ParentingIntakePersistence(url: url, scope: harness.scope, subjectID: subject, epoch: harness.epoch, cipher: ParentingTestCipher())
        try fresh.save(StoreSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testInlineRecoveryReferenceFreezesPromptAndContainsNoLoginToken() throws {
        let harness = try make()
        let reference = ParentingIntakeRecoveryReference(requestID: stableID("parenting-inline-recover-request"), scope: harness.scope, subjectID: subject,
            conversationID: stableID("parenting-inline-recover-conversation"), sourceText: "合成恢复原话：明天15:00读绘本\n保留引号“原文”", childID: child, goalID: goal,
            startedAt: instant, timeZoneID: "GMT")
        let oldToken = try XCTUnwrap(harness.epoch.capture())
        let original = try reference.request(accountToken: oldToken)
        harness.epoch.bump()
        let freshToken = try XCTUnwrap(harness.epoch.capture())
        let restored = try reference.request(accountToken: freshToken)
        XCTAssertNotEqual(oldToken, freshToken)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.conversationID, original.conversationID)
        XCTAssertEqual(restored.prompt, original.prompt)
        XCTAssertEqual(restored.sourceText, original.sourceText)
        XCTAssertEqual(restored.accountToken, freshToken)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        XCTAssertNil(metadata["accountToken"])
        XCTAssertNil(metadata["accessToken"])
        XCTAssertNil(metadata["refreshToken"])
        XCTAssertNil(metadata["epoch"])
        let other = try XCTUnwrap(AccountEpoch(account: stableID("parenting-inline-foreign-subject").uuidString).capture())
        XCTAssertThrowsError(try reference.request(accountToken: other))
    }

    func testInlineColdRecoverWithFreshEpochOnlyObservesOriginalRequest() async throws {
        let backend = ParentingInlineTestBackend(mode: .transportUnknown)
        let harness = try make(backend: backend, withRecovery: true)
        let source = "合成冷恢复原话：明天15:00读绘本"
        await harness.model.request(sourceText: source, childID: child, goalID: goal)
        XCTAssertEqual(harness.model.phase, .unknown)
        let before = await backend.captured(), sent = try XCTUnwrap(before.submitted.first)
        harness.epoch.bump() // A cold process/re-login receives a fresh account generation.
        await backend.completeOnObservation()
        let restored = try coldModel(harness)
        XCTAssertTrue(restored.recoveryAvailable)
        let beforeRecovery = await backend.captured()
        XCTAssertEqual(beforeRecovery.submitted.count, 1)
        XCTAssertTrue(beforeRecovery.observed.isEmpty)
        await restored.recover()
        XCTAssertEqual(restored.phase, .ready)
        XCTAssertEqual(restored.recoveredRequest?.requestID, sent.operationID)
        XCTAssertEqual(restored.recoveredRequest?.conversationID, sent.conversationID)
        XCTAssertEqual(restored.recoveredRequest?.sourceText, source)
        XCTAssertEqual(restored.candidate?.sourceText, source)
        XCTAssertEqual(restored.candidate?.childID, child)
        XCTAssertEqual(restored.candidate?.goalID, goal)
        let calls = await backend.captured()
        XCTAssertEqual(calls.submitted.count, 1)
        XCTAssertFalse(calls.observed.isEmpty)
        XCTAssertTrue(calls.observed.allSatisfy { $0.operationID == sent.operationID && $0.conversationID == sent.conversationID })
    }

    func testInlineColdRecoverOfNotSentRequestNeverPostsImplicitly() async throws {
        let backend = ParentingInlineTestBackend(mode: .notSentOnce)
        let harness = try make(backend: backend, withRecovery: true)
        await harness.model.request(sourceText: "合成尚未发送的冷恢复原话", childID: child, goalID: nil)
        XCTAssertEqual(harness.model.phase, .failed)
        harness.epoch.bump()
        let restored = try coldModel(harness)
        await restored.recover()
        await restored.retry()
        XCTAssertNil(restored.candidate)
        XCTAssertEqual(restored.phase, .unknown)
        XCTAssertFalse(restored.canRetry)
        let calls = await backend.captured()
        XCTAssertEqual(calls.submitted.count, 1, "Cold recovery must not turn an old reference into a fresh POST")
    }

    func testInlineExpiredRecoveryPurgesSourceAndQueuesIdentifiersOnly() async throws {
        let harness = try make(withRecovery: true)
        let source = "合成超过保留期的原话"
        await harness.model.request(sourceText: source, childID: child, goalID: nil)
        let expiredAt = instant.addingTimeInterval(ParentingIntakeRecoveryReference.maximumAge + 1)
        let restored = try coldModel(harness, at: expiredAt)
        XCTAssertFalse(restored.recoveryAvailable)
        XCTAssertTrue(restored.deletionPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("recovery.sealed").path))
        for entry in harness.entries.values { XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path)) }
        let cleanup = ParentingIntakeCleanupFile(scope: harness.scope, subjectID: subject, epoch: harness.epoch, cipher: ParentingTestCipher(), url: harness.directory.appendingPathComponent("cleanup.sealed"))
        let pending = try cleanup.read()
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending.allSatisfy(\.pending))
        let metadata = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        XCTAssertFalse(metadata.contains(source))
        XCTAssertFalse(metadata.contains("sourceText"))
        XCTAssertFalse(metadata.contains("accountToken"))
        await restored.retryDeletion()
        XCTAssertFalse(restored.deletionPending)
        let calls = await harness.backend.captured()
        XCTAssertEqual(calls.submitted.count, 1)
        XCTAssertFalse(calls.deleted.isEmpty)
    }

    func testInlineDeleteWhileWaitingPreventsLateReplyAndFileResurrection() async throws {
        let started = expectation(description: "Synthetic request waiting before deletion")
        let backend = ParentingInlineTestBackend(mode: .held, replyStarted: { started.fulfill() })
        let harness = try make(backend: backend, withRecovery: true)
        let pending = Task { await harness.model.request(sourceText: "合成删除中的原话", childID: self.child, goalID: nil) }
        await fulfillment(of: [started], timeout: 2)
        harness.model.deleteLocalRecord()
        await harness.model.retryDeletion()
        await backend.releaseReply(); await pending.value
        XCTAssertNil(harness.model.candidate)
        XCTAssertFalse(harness.model.recoveryAvailable)
        XCTAssertFalse(harness.model.deletionPending)
        for entry in harness.entries.values { XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("recovery.sealed").path))
        let calls = await backend.captured(), sent = try XCTUnwrap(calls.submitted.first)
        XCTAssertFalse(calls.deleted.isEmpty)
        XCTAssertTrue(calls.deleted.allSatisfy { $0 == sent.conversationID })
    }

    func testInlineRemoteDeletionFailureStaysPendingUntilExplicitRetry() async throws {
        let backend = ParentingInlineTestBackend()
        let harness = try make(backend: backend, withRecovery: true)
        await harness.model.request(sourceText: "合成需要重试清理的原话", childID: child, goalID: nil)
        await backend.setDeletionFailure(true)
        harness.model.deleteLocalRecord()
        await harness.model.retryDeletion()
        XCTAssertTrue(harness.model.deletionPending)
        XCTAssertNotNil(harness.model.deletionError)
        await harness.model.request(sourceText: "合成清理前不能再发", childID: child, goalID: nil)
        let blocked = await backend.captured()
        XCTAssertEqual(blocked.submitted.count, 1)
        await backend.setDeletionFailure(false)
        await harness.model.retryDeletion()
        XCTAssertFalse(harness.model.deletionPending)
        XCTAssertNil(harness.model.deletionError)
        XCTAssertNil(harness.model.candidate)
    }

    func testInlinePreparationFailureCleanupSurvivesReopenAndUnblocksNewRequest() async throws {
        let backend = ParentingInlineTestBackend(preparationFailsOnce: true)
        let harness = try make(backend: backend, withRecovery: true)
        let originalSource = "合成远端创建前失败的原话，不应进入清理引用"
        await harness.model.request(sourceText: originalSource, childID: child, goalID: goal)
        XCTAssertEqual(harness.model.phase, .failed)
        XCTAssertNil(harness.model.candidate)
        let original = try XCTUnwrap(harness.recovery?.read())
        let failed = await backend.captured()
        XCTAssertEqual(failed.prepared, [original.conversationID])
        XCTAssertTrue(failed.submitted.isEmpty, "Preparation failed before any model submission")

        await backend.setDeletionFailure(true)
        harness.model.cancel()
        await harness.model.retryDeletion()
        XCTAssertEqual(harness.model.phase, .cancelled)
        XCTAssertTrue(harness.model.deletionPending)
        XCTAssertNotNil(harness.model.deletionError)
        XCTAssertFalse(harness.model.recoveryAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("recovery.sealed").path))
        for entry in harness.entries.values { XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path)) }
        let savedPending = try XCTUnwrap(harness.cleanup).read()
        XCTAssertEqual(savedPending.map(\.conversationID), [original.conversationID])
        XCTAssertTrue(savedPending.allSatisfy(\.pending))
        let pendingJSON = String(decoding: try JSONEncoder().encode(savedPending), as: UTF8.self)
        XCTAssertFalse(pendingJSON.contains(originalSource))
        for forbidden in ["sourceText", "prompt", "candidate", "accountToken", "accessToken"] {
            XCTAssertFalse(pendingJSON.contains(forbidden))
        }
        let firstDeleteAttempts = await backend.captured()
        XCTAssertFalse(firstDeleteAttempts.deleted.isEmpty)
        XCTAssertTrue(firstDeleteAttempts.deleted.allSatisfy { $0 == original.conversationID })

        harness.epoch.bump() // Fresh wrappers capture the new account generation; old cleanup writers are fenced.
        let reopened = try coldModel(harness)
        let coldCleanup = ParentingIntakeCleanupFile(scope: harness.scope, subjectID: subject, epoch: harness.epoch,
            cipher: ParentingTestCipher(), url: harness.directory.appendingPathComponent("cleanup.sealed"))
        XCTAssertEqual(try coldCleanup.read().map(\.conversationID), [original.conversationID])
        XCTAssertTrue(reopened.deletionPending)
        XCTAssertFalse(reopened.recoveryAvailable)
        await reopened.request(sourceText: "合成待清理时不得提交的新原话", childID: child, goalID: nil)
        let blocked = await backend.captured()
        XCTAssertEqual(blocked.prepared, [original.conversationID])
        XCTAssertTrue(blocked.submitted.isEmpty)
        XCTAssertTrue(reopened.deletionPending)

        await backend.setDeletionFailure(false)
        await reopened.retryDeletion()
        XCTAssertFalse(reopened.deletionPending)
        XCTAssertNil(reopened.deletionError)
        XCTAssertTrue(try coldCleanup.read().isEmpty)
        let cleaned = await backend.captured()
        XCTAssertTrue(cleaned.submitted.isEmpty)
        XCTAssertTrue(cleaned.deleted.allSatisfy { $0 == original.conversationID })

        let newSource = "合成清理完成后主动发起的新安排"
        await reopened.request(sourceText: newSource, childID: child, goalID: goal)
        XCTAssertEqual(reopened.phase, .ready)
        XCTAssertEqual(reopened.candidate?.sourceText, newSource)
        let resumed = await backend.captured(), sent = try XCTUnwrap(resumed.submitted.first)
        XCTAssertEqual(resumed.submitted.count, 1)
        XCTAssertEqual(resumed.prepared, [original.conversationID, sent.conversationID])
        XCTAssertNotEqual(sent.conversationID, original.conversationID)
        XCTAssertNotEqual(sent.operationID, original.requestID)
        XCTAssertTrue(resumed.observed.isEmpty)
        let newReferences = try coldCleanup.read()
        XCTAssertEqual(newReferences.map(\.conversationID), [sent.conversationID])
        XCTAssertFalse(newReferences.contains(where: \.pending))
        let newReferenceJSON = String(decoding: try JSONEncoder().encode(newReferences), as: UTF8.self)
        XCTAssertFalse(newReferenceJSON.contains(originalSource))
        XCTAssertFalse(newReferenceJSON.contains(newSource))
    }

    func testInlineNativeDeleteRequiresBoundTombstoneReceiptAndRejectsTransportFailures() async throws {
        let local = AuthenticatedLocalPartition(issuer: "https://parenting-delete-fixture.invalid", subject: subject,
            serverScopeID: stableID("parenting-delete-fixture-server")).scope
        let server = stableID("parenting-delete-fixture-server"), conversation = stableID("parenting-delete-fixture-conversation")
        let exactPurge: [String: Any] = [
            "conversation_id": conversation.uuidString.lowercased(), "scope_id": server.uuidString.lowercased(),
            "subject_id": subject.uuidString.lowercased(), "intake_contract": ParentingIntakeRequest.contract,
            "purged": true, "already_purged": true, "retained": "identity_hash_tombstone_only"
        ]
        func receipt(_ overrides: [String: Any] = [:]) throws -> Data {
            var purge = exactPurge; purge.merge(overrides) { _, replacement in replacement }
            return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "contract": "catpaw.native-chat.v1", "purge": purge], options: [.sortedKeys])
        }
        struct WireCase {
            let name: String
            let reply: ParentingIntakeDeleteWireProtocol.Reply
            let accepts: Bool
            var credentialRejections = 0
        }
        let exact = try receipt()
        let cases: [WireCase] = [
            .init(name: "404 is not a confirmed deletion", reply: .response(status: 404, body: exact), accepts: false),
            .init(name: "401 rejects the authenticated session", reply: .response(status: 401, body: exact), accepts: false, credentialRejections: 1),
            .init(name: "offline has no deletion receipt", reply: .offline, accepts: false),
            .init(name: "wrong conversation", reply: .response(status: 200, body: try receipt(["conversation_id": stableID("parenting-delete-wrong-conversation").uuidString.lowercased()])), accepts: false),
            .init(name: "wrong server scope", reply: .response(status: 200, body: try receipt(["scope_id": stableID("parenting-delete-wrong-scope").uuidString.lowercased()])), accepts: false),
            .init(name: "wrong subject", reply: .response(status: 200, body: try receipt(["subject_id": stableID("parenting-delete-wrong-subject").uuidString.lowercased()])), accepts: false),
            .init(name: "wrong purpose", reply: .response(status: 200, body: try receipt(["intake_contract": "catpaw.native-chat.v1"])), accepts: false),
            .init(name: "purged false", reply: .response(status: 200, body: try receipt(["purged": false])), accepts: false),
            .init(name: "wrong retention claim", reply: .response(status: 200, body: try receipt(["retained": "raw_content_retained"])), accepts: false),
            .init(name: "exact bound tombstone", reply: .response(status: 200, body: exact), accepts: true)
        ]
        for fixture in cases {
            let host = "parenting-delete-" + UUID().uuidString.lowercased() + ".invalid"
            ParentingIntakeDeleteWireProtocol.install(fixture.reply, host: host)
            defer { ParentingIntakeDeleteWireProtocol.remove(host: host) }
            let policy = URLSessionConfiguration.ephemeral
            policy.protocolClasses = [ParentingIntakeDeleteWireProtocol.self]
            let credentials = ParentingIntakeDeleteWireCredentials(scope: local)
            let configuration = try NativeChatConfiguration(origin: try XCTUnwrap(URL(string: "https://" + host)),
                localScope: local, serverScopeID: server, expectedSubjectID: subject)
            let backend = NativeChatHTTPBackend(configuration: configuration, credentials: credentials,
                sessionConfiguration: policy, purpose: .parentingIntake)
            var accepted = false
            do { try await backend.deleteIntake(scope: local, conversationID: conversation); accepted = true }
            catch { if fixture.accepts { XCTFail("Exact bound receipt must be accepted: \(error)") } }
            await backend.close()
            XCTAssertEqual(accepted, fixture.accepts, fixture.name)
            let rejected = await credentials.rejectionCount()
            XCTAssertEqual(rejected, fixture.credentialRejections, fixture.name)
            let requests = ParentingIntakeDeleteWireProtocol.requests(host: host)
            XCTAssertEqual(requests.count, 1, "No fallback, create or resend after DELETE: " + fixture.name)
            let wire = try XCTUnwrap(requests.first)
            XCTAssertEqual(wire.url?.host, host)
            XCTAssertEqual(wire.httpMethod, "DELETE")
            XCTAssertEqual(wire.url?.path, "/catpaw/parenting-intake/v1/scopes/" + server.uuidString.lowercased() + "/conversations/" + conversation.uuidString.lowercased())
            XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer explicit-parenting-delete-fixture")
            XCTAssertNil(wire.httpBody)
            XCTAssertNil(wire.httpBodyStream)
        }
    }

    func testInlineConsumeClearsTemporaryCopiesAndAllowsNewExplicitRequest() async throws {
        let harness = try make(withRecovery: true)
        await harness.model.request(sourceText: "合成已带回表单的原话", childID: child, goalID: nil)
        XCTAssertEqual(harness.model.phase, .ready)
        harness.model.consumeCandidate()
        await harness.model.retryDeletion()
        XCTAssertNil(harness.model.candidate)
        XCTAssertFalse(harness.model.recoveryAvailable)
        await harness.model.request(sourceText: "合成随后主动提交的新原话", childID: child, goalID: goal)
        XCTAssertEqual(harness.model.phase, .ready)
        XCTAssertEqual(harness.model.candidate?.sourceText, "合成随后主动提交的新原话")
        let calls = await harness.backend.captured()
        XCTAssertEqual(calls.submitted.count, 2)
        XCTAssertEqual(Set(calls.submitted.map(\.operationID)).count, 2)
    }
}
