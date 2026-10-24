import Foundation
import XCTest
@testable import cat

private final class ParentingEditFailingPersistence: SnapshotPersistence, @unchecked Sendable {
    let file: FilePersistence
    private let lock = NSLock()
    private var failurePending = false
    init(url: URL) { file = FilePersistence(url: url) }
    func failNextSave() { lock.lock(); defer { lock.unlock() }; failurePending = true }
    func load() throws -> StoreSnapshot { try file.load() }
    func save(_ snapshot: StoreSnapshot) throws {
        lock.lock()
        let fails = failurePending
        failurePending = false
        lock.unlock()
        if fails { throw catError.unavailable("Synthetic arrangement edit disk failure") }
        try file.save(snapshot)
    }
}

/// Uses the real domain, encrypted store boundary, repository CAS and file snapshot persistence.
/// ParentingTestCipher is a synthetic boundary codec, not production cryptography evidence.
final class ParentingArrangementEditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_756_800)
    private let childID = UUID(uuidString: "E2000000-0000-4000-8000-000000000001")!
    private let arrangementID = UUID(uuidString: "E3000000-0000-4000-8000-000000000001")!
    private let goalID = UUID(uuidString: "E4000000-0000-4000-8000-000000000001")!
    private let changeID = UUID(uuidString: "E5000000-0000-4000-8000-000000000001")!

    private struct Harness {
        let url: URL
        let subject: UUID
        let scope: DataScope
        let epoch: AccountEpoch
        let persistence: ParentingEditFailingPersistence
        let repository: Repository
        let store: ParentingWorkspaceStore
    }

    private func make() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-edit-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.json")
        let subject = UUID()
        let scope = AuthenticatedLocalPartition(issuer: "https://parenting-edit.invalid", subject: subject, serverScopeID: UUID()).scope
        let epoch = AccountEpoch(account: subject.uuidString)
        let persistence = ParentingEditFailingPersistence(url: url)
        let repository = try Repository(persistence: persistence)
        let instant = now
        let store = ParentingWorkspaceStore(repository: repository, scope: scope, subjectID: subject, epoch: epoch, cipher: ParentingTestCipher(), clock: { instant })
        return Harness(url: url, subject: subject, scope: scope, epoch: epoch, persistence: persistence, repository: repository, store: store)
    }

    private func reopen(_ harness: Harness) throws -> ParentingWorkspaceStore {
        let repository = try Repository(persistence: FilePersistence(url: harness.url))
        let instant = now
        return ParentingWorkspaceStore(repository: repository, scope: harness.scope, subjectID: harness.subject, epoch: harness.epoch, cipher: ParentingTestCipher(), clock: { instant })
    }

    @discardableResult private func apply(_ command: ParentingCommand, to harness: Harness, operationID: UUID = UUID()) async throws -> ParentingWorkspace {
        let current = try await harness.store.load()
        return try await harness.store.apply(command, expectedRevision: current.revision, operationID: operationID)
    }

    private func seed(_ harness: Harness, planned: Bool = true, goal: Bool = true) async throws -> ParentingWorkspace {
        try await apply(.addChild(id: childID, name: "合成小星"), to: harness)
        if goal { try await apply(.addGoal(id: goalID, childID: childID, title: "合成阅读目标"), to: harness) }
        let draft = try await apply(.createDraft(id: arrangementID, childID: childID, title: "合成绘本", dueAt: now.addingTimeInterval(3600), goalID: goal ? goalID : nil, sourceText: "合成原始安排来源"), to: harness)
        if !planned { return draft }
        return try await apply(.confirmArrangement(id: arrangementID), to: harness)
    }

    private func target(_ workspace: ParentingWorkspace) throws -> ParentingArrangementEditTarget {
        .init(arrangement: try XCTUnwrap(workspace.arrangements.first(where: { $0.id == arrangementID })), workspaceRevision: workspace.revision)
    }

    private func revision(_ workspace: ParentingWorkspace, id: UUID? = nil, dueAt: Date? = nil, acknowledged: [UUID] = []) throws -> ParentingCommand {
        let frozen = try target(workspace)
        return .reviseArrangement(id: id ?? changeID, target: frozen, title: frozen.arrangement.title, dueAt: dueAt ?? now.addingTimeInterval(7200), goalID: frozen.arrangement.goalID, sourceText: "改到明天下午五点", acknowledgedConflictIDs: acknowledged)
    }

    private func rejects(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected the product boundary to reject this action", file: file, line: line) }
        catch { }
    }

    private func assertUnchanged(_ harness: Harness, bytes: Data, workspace: ParentingWorkspace, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(try Data(contentsOf: harness.url), bytes, file: file, line: line)
        let current = try await harness.store.load()
        let cold = try await reopen(harness).load()
        XCTAssertEqual(current, workspace, file: file, line: line)
        XCTAssertEqual(cold, workspace, file: file, line: line)
    }

    func testM1WorkspaceAndFixedOperationReceiptColdDecodeWithoutRewritingFingerprint() async throws {
        let harness = try make()
        // Frozen M1 synthesized command bytes and SHA-256, independent of today's encoder.
        let oldCommand = Data(#"{"addChild":{"id":"E2000000-0000-4000-8000-000000000001","name":"Legacy child"}}"#.utf8)
        let oldFingerprint = "9f6e327fc0c54456c29ca4ebe00c2a16c78905d713a51b6142f710f88a7bae50"
        let operation = UUID()
        let command = try JSONDecoder().decode(ParentingCommand.self, from: oldCommand)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(command), oldCommand)
        XCTAssertEqual(bytesHash(try encoder.encode(command)), oldFingerprint)
        let legacyWorkspace = Data(#"{"schemaVersion":1,"revision":1,"children":[{"id":"E2000000-0000-4000-8000-000000000001","name":"Legacy child","createdAt":0}],"goals":[],"arrangements":[],"records":[],"suggestionsEnabled":false}"#.utf8)
        let scopeObject = try JSONSerialization.jsonObject(with: encoder.encode(harness.scope))
        let operations = try JSONSerialization.jsonObject(with: encoder.encode([operation: oldFingerprint]))
        let envelope: [String: Any] = ["schemaVersion": 1, "scope": scopeObject, "subjectID": harness.subject.uuidString,
                                       "workspace": try JSONSerialization.jsonObject(with: legacyWorkspace), "operations": operations]
        let plain = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let sealed = try ParentingTestCipher().seal(plain, subjectID: harness.subject)
        let key = ParentingWorkspaceStore.preferenceKey(scope: harness.scope, subjectID: harness.subject)
        let recordID = ParentingWorkspaceStore.recordID(scope: harness.scope, subjectID: harness.subject)
        try await harness.repository.commit(scope: harness.scope, mutations: [.create(recordID, .preference(.init(key: key, value: "parenting-sealed-v1:" + sealed.base64EncodedString())))])
        let bytes = try Data(contentsOf: harness.url)
        let cold = try reopen(harness)
        let loaded = try await cold.load()
        XCTAssertEqual(loaded.children.map(\.name), ["Legacy child"])
        XCTAssertEqual(loaded.revision, 1)
        XCTAssertTrue(loaded.editHistory.isEmpty)
        let retry = try await cold.apply(command, expectedRevision: 0, operationID: operation)
        XCTAssertEqual(retry, loaded)
        try await assertUnchanged(harness, bytes: bytes, workspace: loaded)
        let oldEdit = Data(#"{"editArrangement":{"dueAt":1000,"id":"E3000000-0000-4000-8000-000000000001","title":"Legacy edit"}}"#.utf8)
        XCTAssertEqual(try encoder.encode(JSONDecoder().decode(ParentingCommand.self, from: oldEdit)), oldEdit)
    }

    func testRevisionColdReadAndUndoKeepIdentitySourceAndOneHistoryWithIdempotentRetries() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let before = try target(original).arrangement
        let command = try revision(original)
        let operation = UUID()
        let revised = try await harness.store.apply(command, expectedRevision: original.revision, operationID: operation)
        let after = try XCTUnwrap(revised.arrangements.first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.childID, before.childID)
        XCTAssertEqual(after.goalID, before.goalID)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(after.sourceText, before.sourceText)
        XCTAssertEqual(after.createdAt, before.createdAt)
        XCTAssertEqual(after.dueAt, now.addingTimeInterval(7200))
        let edit = try XCTUnwrap(revised.editHistory.first)
        XCTAssertEqual(edit.id, changeID)
        XCTAssertEqual(edit.before, before)
        XCTAssertEqual(edit.after, after)
        XCTAssertEqual(edit.sourceText, "改到明天下午五点")
        XCTAssertTrue(edit.canUndo(in: revised))
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, revised)
        let retry = try await reopen(harness).apply(command, expectedRevision: 0, operationID: operation)
        XCTAssertEqual(retry, revised)
        XCTAssertEqual(retry.editHistory.count, 1)
        let undoOperation = UUID()
        let undone = try await harness.store.apply(.undoArrangementEdit(id: changeID, acknowledgedConflictIDs: []), expectedRevision: revised.revision, operationID: undoOperation)
        XCTAssertEqual(undone.arrangements.first?.dueAt, before.dueAt)
        XCTAssertEqual(undone.arrangements.first?.sourceText, before.sourceText)
        XCTAssertEqual(undone.editHistory.first?.revertedAt, now)
        XCTAssertFalse(try XCTUnwrap(undone.editHistory.first).canUndo(in: undone))
        let coldUndone = try await reopen(harness).load()
        XCTAssertEqual(coldUndone, undone)
        let undoRetry = try await reopen(harness).apply(.undoArrangementEdit(id: changeID, acknowledgedConflictIDs: []), expectedRevision: 0, operationID: undoOperation)
        XCTAssertEqual(undoRetry, undone)
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: []), expectedRevision: undone.revision) }
        try await assertUnchanged(harness, bytes: bytes, workspace: undone)
    }

    func testStaleRevisionChangedSnapshotNoChangeAndInvalidGoalRejectWithoutWrite() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let oldCommand = try revision(original)
        let changed = try await apply(.renameChild(id: childID, name: "合成已改昵称"), to: harness)
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(oldCommand, expectedRevision: original.revision) }
        await rejects { _ = try await harness.store.apply(oldCommand, expectedRevision: changed.revision) }
        var forged = try target(changed)
        forged.arrangement.sourceText = "合成伪造旧快照"
        let mismatch = ParentingCommand.reviseArrangement(id: changeID, target: forged, title: forged.arrangement.title, dueAt: now.addingTimeInterval(7200), goalID: goalID, sourceText: "明天17:00", acknowledgedConflictIDs: [])
        await rejects { _ = try await harness.store.apply(mismatch, expectedRevision: changed.revision) }
        let current = try target(changed)
        let noChange = try revision(changed, dueAt: current.arrangement.dueAt)
        await rejects { _ = try await harness.store.apply(noChange, expectedRevision: changed.revision) }
        let invalidGoal = ParentingCommand.reviseArrangement(id: changeID, target: current, title: current.arrangement.title, dueAt: now.addingTimeInterval(7200), goalID: UUID(), sourceText: "", acknowledgedConflictIDs: [])
        await rejects { _ = try await harness.store.apply(invalidGoal, expectedRevision: changed.revision) }
        try await assertUnchanged(harness, bytes: bytes, workspace: changed)
    }

    func testSameOperationDifferentContentRejectsAndConcurrentRetryPersistsOnce() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let instant = now
        let second = ParentingWorkspaceStore(repository: harness.repository, scope: harness.scope, subjectID: harness.subject, epoch: harness.epoch, cipher: ParentingTestCipher(), clock: { instant })
        let command = try revision(original)
        let operation = UUID()
        let beforeSnapshot = await harness.repository.read(scope: harness.scope)
        async let firstResult = harness.store.apply(command, expectedRevision: original.revision, operationID: operation)
        async let secondResult = second.apply(command, expectedRevision: original.revision, operationID: operation)
        let (first, other) = try await (firstResult, secondResult)
        XCTAssertEqual(first, other)
        XCTAssertEqual(first.editHistory.count, 1)
        XCTAssertEqual(first.revision, original.revision + 1)
        let snapshot = await harness.repository.read(scope: harness.scope)
        XCTAssertEqual(snapshot.journal.count, beforeSnapshot.journal.count + 1)
        let different = try revision(original, dueAt: now.addingTimeInterval(10800))
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(different, expectedRevision: first.revision, operationID: operation) }
        let repeatedChangeID = try revision(first, dueAt: now.addingTimeInterval(10800))
        await rejects { _ = try await harness.store.apply(repeatedChangeID, expectedRevision: first.revision, operationID: UUID()) }
        try await assertUnchanged(harness, bytes: bytes, workspace: first)
    }

    func testFailedRevisionAndUndoLeaveFileAndHistoryUnchangedThenSameOperationsRetry() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let command = try revision(original)
        let operation = UUID()
        let originalBytes = try Data(contentsOf: harness.url)
        harness.persistence.failNextSave()
        await rejects { _ = try await harness.store.apply(command, expectedRevision: original.revision, operationID: operation) }
        try await assertUnchanged(harness, bytes: originalBytes, workspace: original)
        let revised = try await harness.store.apply(command, expectedRevision: original.revision, operationID: operation)
        let revisedBytes = try Data(contentsOf: harness.url)
        let laterCommand = try revision(revised, id: UUID(), dueAt: now.addingTimeInterval(10800))
        harness.persistence.failNextSave()
        await rejects { _ = try await harness.store.apply(laterCommand, expectedRevision: revised.revision) }
        try await assertUnchanged(harness, bytes: revisedBytes, workspace: revised)
        XCTAssertTrue(try XCTUnwrap(revised.editHistory.first).canUndo(in: revised))
        let undoOperation = UUID()
        harness.persistence.failNextSave()
        await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: []), expectedRevision: revised.revision, operationID: undoOperation) }
        try await assertUnchanged(harness, bytes: revisedBytes, workspace: revised)
        let undone = try await harness.store.apply(.undoArrangementEdit(id: changeID, acknowledgedConflictIDs: []), expectedRevision: revised.revision, operationID: undoOperation)
        XCTAssertEqual(undone.arrangements.first?.dueAt, original.arrangements.first?.dueAt)
        XCTAssertEqual(undone.editHistory.count, 1)
        XCTAssertNotNil(undone.editHistory.first?.revertedAt)
    }

    func testSameMinuteAcrossChildrenRequiresExactCurrentAcknowledgementAndStableOrder() async throws {
        let harness = try make()
        var current = try await seed(harness)
        let otherChild = UUID(), earlier = UUID(), later = UUID(), draft = UUID(), cancelled = UUID()
        let due = now.addingTimeInterval(7200)
        current = try await apply(.addChild(id: otherChild, name: "合成另一个孩子"), to: harness)
        for (id, offset, planned) in [(later, 50.0, true), (earlier, 10.0, true), (draft, 20.0, false), (cancelled, 30.0, true)] {
            current = try await apply(.createDraft(id: id, childID: otherChild, title: "合成同刻事项", dueAt: due.addingTimeInterval(offset), goalID: nil, sourceText: ""), to: harness)
            if planned { current = try await apply(.confirmArrangement(id: id), to: harness) }
        }
        current = try await apply(.cancelArrangement(id: cancelled), to: harness)
        XCTAssertEqual(current.sameTimeConflicts(arrangementID: arrangementID, dueAt: due).map(\.id), [earlier, later])
        let frozen = current
        let bytes = try Data(contentsOf: harness.url)
        for acknowledgements in [[], [earlier], [earlier, later, later], [earlier, later, draft]] {
            let command = try revision(frozen, dueAt: due, acknowledged: acknowledgements)
            await rejects { _ = try await harness.store.apply(command, expectedRevision: frozen.revision) }
        }
        try await assertUnchanged(harness, bytes: bytes, workspace: frozen)
        let staleCommand = try revision(frozen, dueAt: due, acknowledged: [later, earlier])
        let changed = try await apply(.confirmArrangement(id: draft), to: harness)
        await rejects { _ = try await harness.store.apply(staleCommand, expectedRevision: changed.revision) }
        let changedAcknowledgements = try revision(changed, dueAt: due, acknowledged: [earlier, later])
        await rejects { _ = try await harness.store.apply(changedAcknowledgements, expectedRevision: changed.revision) }
        let accepted = try await apply(try revision(changed, dueAt: due, acknowledged: [later, draft, earlier]), to: harness)
        XCTAssertEqual(accepted.editHistory.count, 1)
        XCTAssertEqual(accepted.arrangements.first(where: { $0.id == arrangementID })?.dueAt, due)
        XCTAssertEqual(accepted.sameTimeConflicts(arrangementID: arrangementID, dueAt: due).map(\.id), [earlier, draft, later])
    }

    func testSameClockManualEditAndReturnToAfterCannotReviveUndoAndKeepsSourceHistory() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let revised = try await apply(try revision(original), to: harness)
        let after = try XCTUnwrap(revised.arrangements.first)
        try await apply(.editArrangement(id: arrangementID, title: "合成手工改名", dueAt: after.dueAt, goalID: after.goalID), to: harness)
        let restoredFields = try await apply(.editArrangement(id: arrangementID, title: after.title, dueAt: after.dueAt, goalID: after.goalID), to: harness)
        XCTAssertEqual(restoredFields.arrangements.first, after, "The fixed clock makes this an actual ABA snapshot")
        let edit = try XCTUnwrap(restoredFields.editHistory.first)
        XCTAssertEqual(edit.sourceText, "改到明天下午五点")
        XCTAssertEqual(edit.supersededAt, now)
        XCTAssertFalse(edit.canUndo(in: restoredFields))
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, restoredFields)
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: []), expectedRevision: cold.revision) }
        try await assertUnchanged(harness, bytes: bytes, workspace: cold)
    }

    func testUndoRequiresExactCurrentAcknowledgementForRestoredMinute() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let restoredDue = try XCTUnwrap(original.arrangements.first).dueAt
        let revised = try await apply(try revision(original), to: harness)
        let firstConflict = UUID(), laterConflict = UUID()
        try await apply(.createDraft(id: firstConflict, childID: childID, title: "合成后来同刻安排", dueAt: restoredDue.addingTimeInterval(30), goalID: nil, sourceText: ""), to: harness)
        let conflictAdded = try await apply(.confirmArrangement(id: firstConflict), to: harness)
        XCTAssertTrue(try XCTUnwrap(conflictAdded.editHistory.first).canUndo(in: conflictAdded))
        let bytes = try Data(contentsOf: harness.url)
        for acknowledgements in [[], [firstConflict, firstConflict], [firstConflict, UUID()]] {
            await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: acknowledgements), expectedRevision: conflictAdded.revision) }
        }
        // Even an exact old acknowledgement cannot override a frozen stale workspace revision.
        await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: [firstConflict]), expectedRevision: revised.revision) }
        try await assertUnchanged(harness, bytes: bytes, workspace: conflictAdded)
        try await apply(.createDraft(id: laterConflict, childID: childID, title: "合成再次变化的同刻安排", dueAt: restoredDue.addingTimeInterval(45), goalID: nil, sourceText: ""), to: harness)
        let latest = try await apply(.confirmArrangement(id: laterConflict), to: harness)
        await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: [firstConflict]), expectedRevision: latest.revision) }
        let undone = try await harness.store.apply(.undoArrangementEdit(id: changeID, acknowledgedConflictIDs: [laterConflict, firstConflict]), expectedRevision: latest.revision)
        XCTAssertEqual(undone.arrangements.first(where: { $0.id == arrangementID })?.dueAt, restoredDue)
        XCTAssertNotNil(undone.editHistory.first?.revertedAt)
        let cold = try await reopen(harness).load()
        XCTAssertEqual(cold, undone)
    }

    func testCompletionAndCancellationSupersedeUndoWithoutErasingCompletionFacts() async throws {
        for complete in [false, true] {
            let harness = try make()
            let original = try await seed(harness)
            let revised = try await apply(try revision(original), to: harness)
            let recordID = UUID()
            let command: ParentingCommand = complete ? .completeArrangement(id: arrangementID, recordID: recordID, note: "合成完成事实") : .cancelArrangement(id: arrangementID)
            let changed = try await apply(command, to: harness)
            XCTAssertEqual(changed.editHistory.first?.supersededAt, now)
            XCTAssertFalse(try XCTUnwrap(changed.editHistory.first).canUndo(in: changed))
            XCTAssertEqual(changed.arrangements.first?.state, complete ? .completed : .cancelled)
            XCTAssertEqual(changed.records.count, complete ? 1 : 0)
            let bytes = try Data(contentsOf: harness.url)
            await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: []), expectedRevision: changed.revision) }
            await rejects { _ = try await harness.store.apply(try self.revision(changed, id: UUID()), expectedRevision: changed.revision) }
            try await assertUnchanged(harness, bytes: bytes, workspace: changed)
            XCTAssertEqual(revised.editHistory.count, changed.editHistory.count)
        }
    }

    func testActualDraftConfirmationSupersedesUndoButPlannedNoOpDoesNot() async throws {
        for wasPlanned in [false, true] {
            let harness = try make()
            let original = try await seed(harness, planned: wasPlanned)
            let revised = try await apply(try revision(original), to: harness)
            let confirmed = try await apply(.confirmArrangement(id: arrangementID), to: harness)
            let edit = try XCTUnwrap(confirmed.editHistory.first)
            XCTAssertEqual(edit.canUndo(in: confirmed), wasPlanned)
            XCTAssertEqual(edit.supersededAt == nil, wasPlanned)
            if wasPlanned {
                let undone = try await apply(.undoArrangementEdit(id: changeID, acknowledgedConflictIDs: []), to: harness)
                XCTAssertEqual(undone.arrangements.first?.dueAt, original.arrangements.first?.dueAt)
            } else {
                await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: []), expectedRevision: confirmed.revision) }
            }
            XCTAssertEqual(revised.editHistory.count, confirmed.editHistory.count)
        }
    }

    func testLaterRevisionAndUndoNeverReviveEarlierHistoryAtSameClock() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let first = try await apply(try revision(original), to: harness)
        let secondID = UUID()
        let second = try await apply(try revision(first, id: secondID, dueAt: now.addingTimeInterval(10800)), to: harness)
        XCTAssertEqual(second.editHistory.count, 2)
        XCTAssertEqual(second.editHistory.first?.supersededAt, now)
        let undone = try await apply(.undoArrangementEdit(id: secondID, acknowledgedConflictIDs: []), to: harness)
        XCTAssertEqual(undone.arrangements, first.arrangements)
        XCTAssertFalse(try XCTUnwrap(undone.editHistory.first).canUndo(in: undone))
        let bytes = try Data(contentsOf: harness.url)
        await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: []), expectedRevision: undone.revision) }
        try await assertUnchanged(harness, bytes: bytes, workspace: undone)
    }

    func testDeleteArrangementChildOrGoalCleansHistoryAndCannotResurrectDeletedReferences() async throws {
        for deletion in [ParentingCommand.deleteArrangement(id: arrangementID), .deleteChild(id: childID), .deleteGoal(id: goalID)] {
            let harness = try make()
            let original = try await seed(harness)
            try await apply(try revision(original), to: harness)
            let deleted = try await apply(deletion, to: harness)
            XCTAssertTrue(deleted.editHistory.isEmpty)
            let cold = try await reopen(harness).load()
            XCTAssertEqual(cold, deleted)
            let bytes = try Data(contentsOf: harness.url)
            await rejects { _ = try await harness.store.apply(.undoArrangementEdit(id: self.changeID, acknowledgedConflictIDs: []), expectedRevision: cold.revision) }
            try await assertUnchanged(harness, bytes: bytes, workspace: cold)
        }
    }

    func testHistoryValidationRejectsCorruptionWithoutRequiringCurrentArrangementEqualAfter() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let revised = try await apply(try revision(original), to: harness)
        var invalid = revised
        invalid.editHistory.append(invalid.editHistory[0])
        XCTAssertThrowsError(try invalid.validate())
        invalid = revised; invalid.editHistory[0].after.childID = UUID()
        XCTAssertThrowsError(try invalid.validate())
        invalid = revised; invalid.editHistory[0].after.sourceText = "合成被替换的原始来源"
        XCTAssertThrowsError(try invalid.validate())
        invalid = revised; invalid.editHistory[0].after.state = .completed
        XCTAssertThrowsError(try invalid.validate())
        invalid = revised; invalid.editHistory[0].after.createdAt = now.addingTimeInterval(-1)
        XCTAssertThrowsError(try invalid.validate())
        invalid = revised; invalid.editHistory[0].before.goalID = UUID()
        XCTAssertThrowsError(try invalid.validate())
        invalid = revised; invalid.editHistory[0].revertedAt = now.addingTimeInterval(-1)
        XCTAssertThrowsError(try invalid.validate())
        invalid = revised; invalid.editHistory[0].supersededAt = now.addingTimeInterval(-1)
        XCTAssertThrowsError(try invalid.validate())
        let manual = try await apply(.editArrangement(id: arrangementID, title: "合成后续手改", dueAt: now.addingTimeInterval(14400), goalID: nil), to: harness)
        XCTAssertNoThrow(try manual.validate())
        XCTAssertEqual(manual.editHistory.count, 1)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(revised)) as? [String: Any])
        encoded["editHistory"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(ParentingWorkspace.self, from: JSONSerialization.data(withJSONObject: encoded)))
        var editObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(revised.editHistory[0])) as? [String: Any])
        editObject.removeValue(forKey: "supersededAt")
        let compatible = try JSONDecoder().decode(ParentingArrangementEdit.self, from: JSONSerialization.data(withJSONObject: editObject))
        XCTAssertNil(compatible.supersededAt)
    }

    @MainActor func testModelUsesFrozenExpectedRevisionAndPublishesOnlyDurableSuccess() async throws {
        let harness = try make()
        let original = try await seed(harness)
        let model = ParentingWorkspaceModel(store: harness.store)
        await model.load()
        let later = try await apply(.renameChild(id: childID, name: "合成后来昵称"), to: harness)
        await model.load()
        XCTAssertEqual(model.workspace, later)
        let oldFormCommand = ParentingCommand.editArrangement(id: arrangementID, title: "合成过时表单", dueAt: now.addingTimeInterval(7200), goalID: goalID)
        let acceptedOldForm = await model.apply(oldFormCommand, expectedRevision: original.revision)
        XCTAssertFalse(acceptedOldForm)
        XCTAssertEqual(model.workspace, later)
        let command = try revision(later)
        let operation = UUID()
        let bytes = try Data(contentsOf: harness.url)
        harness.persistence.failNextSave()
        let failed = await model.apply(command, operationID: operation, expectedRevision: later.revision)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.workspace, later)
        XCTAssertNotNil(model.error)
        try await assertUnchanged(harness, bytes: bytes, workspace: later)
        let retried = await model.apply(command, operationID: operation, expectedRevision: later.revision)
        XCTAssertTrue(retried)
        XCTAssertEqual(model.workspace.editHistory.count, 1)
        XCTAssertNil(model.error)
    }
}
