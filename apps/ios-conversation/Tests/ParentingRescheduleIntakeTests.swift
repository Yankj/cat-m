import Foundation
import XCTest
@testable import cat

/// Injects only the transport. The production request, parser, controller, session journal and recovery file run below.
private actor ParentingRescheduleBackend: ConversationBackend {
    enum Mode: Sendable, Equatable { case completed, notSentOnce, unknown, held, invalidOnce }
    private var mode: Mode
    private var submitted: [ConversationTurnRequest] = []
    private var observed: [ConversationTurnRequest] = []
    private var completeObservation = false
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    private let started: (@Sendable () -> Void)?
    private let due: String
    private let evidence: String
    init(mode: Mode = .completed, due: String = "2027-02-18T17:00:00Z", evidence: String = "2027-02-18T17:00:00Z",
         started: (@Sendable () -> Void)? = nil) {
        self.mode = mode; self.due = due; self.evidence = evidence; self.started = started
    }
    func calls() -> (submitted: [ConversationTurnRequest], observed: [ConversationTurnRequest]) { (submitted, observed) }
    func finishOnObservation() { completeObservation = true }
    func release() { released = true; held?.resume(); held = nil }
    func connection(scope: DataScope) async -> ConversationConnection {
        .init(state: .providerUnverified, provider: "Synthetic reschedule boundary", detail: "No Auth, HTTP or model")
    }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        submitted.append(request)
        if submitted.count == 1 { started?() }
        if mode == .notSentOnce, submitted.count == 1 { throw ConversationDispatchFailure.notSent(reason: "Synthetic pre-dispatch refusal") }
        if mode == .unknown { throw URLError(.networkConnectionLost) }
        if mode == .held, !released { await withCheckedContinuation { held = $0 } }
        let events = try events(request, invalid: mode == .invalidOnce && submitted.count == 1)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        observed.append(request)
        return .init(request: request, events: completeObservation ? try events(request) : [], serverState: completeObservation ? "completed" : "running")
    }
    func cancelTurn(_ request: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt {
        .init(turnID: request.operationID, state: "failed", cancelled: true, alreadyTerminal: false)
    }
    private func events(_ request: ConversationTurnRequest, invalid: Bool = false) throws -> [ConversationTurnEvent] {
        let body: [String: Any] = ["schema_version": 1, "contract": ParentingIntakeRequest.contract,
            "request_id": request.operationID.uuidString.lowercased(), "title": "Untrusted replacement title",
            "due_at": due, "time_evidence": evidence, "clarification": NSNull()]
        let text = invalid ? "Synthetic malformed response" : String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        let id = stableID("reschedule-intake-answer-\(request.operationID)")
        return [.init(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .textDelta(messageID: id, text: text)),
                .init(operationID: request.operationID, epoch: request.epoch, sequence: 2, payload: .completed(messageID: id, finalTextHash: textHash(text)))]
    }
}

private final class ParentingRescheduleIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }; nextIndex += 1
        return stableID("reschedule-intake-request-\(nextIndex)")
    }
}

@MainActor final class ParentingRescheduleIntakeTests: XCTestCase {
    private let subject = stableID("reschedule-intake-subject")
    private let child = stableID("reschedule-intake-child")
    private let goal = stableID("reschedule-intake-goal")
    private let requestID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let conversationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let source = "Change to 2027-02-18T17:00:00Z."
    private func instant(_ value: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: value)) }
    private var scope: DataScope {
        AuthenticatedLocalPartition(issuer: "https://reschedule-intake.invalid", subject: subject, serverScopeID: stableID("reschedule-intake-server-scope")).scope
    }
    private func target(id: String = "reschedule-intake-arrangement", revision: Int = 73) throws -> ParentingArrangementEditTarget {
        let created = try instant("2026-10-22T12:00:00Z")
        return .init(arrangement: .init(id: stableID(id), childID: child, title: "Original selected arrangement", dueAt: try instant("2026-10-23T15:00:00Z"),
            goalID: goal, state: .planned, sourceText: "Original source must remain local", createdAt: created, updatedAt: created), workspaceRevision: revision)
    }
    private func request(_ text: String? = nil, target: ParentingArrangementEditTarget? = nil,
                         zone: String = "Asia/Shanghai", now: String = "2026-10-23T16:30:00Z") throws -> ParentingIntakeRequest {
        try ParentingIntakeRequest(id: requestID, scope: scope, subjectID: subject,
            accountToken: XCTUnwrap(AccountEpoch(account: subject.uuidString).capture()), conversationID: conversationID,
            sourceText: text ?? source, childID: child, goalID: goal, now: instant(now), timeZone: XCTUnwrap(TimeZone(identifier: zone)), editTarget: target)
    }
    private func parse(_ request: ParentingIntakeRequest, due: String?, evidence: String?, title: String = "Untrusted replacement title") throws -> ParentingIntakeDraft {
        let body: [String: Any] = ["schema_version": 1, "contract": ParentingIntakeRequest.contract, "request_id": request.id.uuidString.lowercased(),
            "title": title, "due_at": due.map { $0 as Any } ?? NSNull(), "time_evidence": evidence.map { $0 as Any } ?? NSNull(), "clarification": NSNull()]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        let user = ConversationTranscriptMessage(role: .user, content: request.prompt)
        let answer = ConversationTranscriptMessage(role: .assistant, content: text, complete: true)
        let wire = ConversationTurnRequest(scope: request.scope, conversationID: request.conversationID, threadID: nil,
                                           operationID: request.id, epoch: 0, history: [user])
        var turn = ConversationTurnRecord(id: request.id, request: wire, state: .completed, lastSequence: 2, error: nil)
        turn.assistantMessageID = answer.id
        var session = ConversationSession(scope: request.scope, conversationID: request.conversationID)
        session.messages = [user, answer]; session.turns = [turn]
        return try request.parse(session: session, currentAccount: request.accountToken)
    }

    func testNilContextRetainsPinnedM1PromptAndLegacyRecoveryDecodes() throws {
        let old = try request("明天15:00合成绘本时间", zone: "GMT", now: "2026-10-23T12:00:00Z")
        // SHA-256 of the c37d82e M1 prompt with these fixed inputs, independent of the new prompt builder.
        XCTAssertEqual(textHash(old.prompt), "db7bcc3f008f3145514f443717ef25a43e9112c7293d32c449a113d69f88ec12")
        let reference = ParentingIntakeRecoveryReference(requestID: requestID, scope: scope, subjectID: subject, conversationID: conversationID,
            sourceText: old.sourceText, childID: child, goalID: goal, startedAt: try instant("2026-10-23T12:00:00Z"), timeZoneID: "GMT")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        legacy.removeValue(forKey: "editTarget")
        let restored = try JSONDecoder().decode(ParentingIntakeRecoveryReference.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.editTarget)
        XCTAssertEqual(try restored.request(accountToken: old.accountToken).prompt, old.prompt)
    }

    func testSelectedContextStaysLocalAndModelTitleCannotChangeTarget() throws {
        let frozen = try target(), value = try request(target: frozen)
        XCTAssertTrue(value.prompt.contains(frozen.arrangement.title))
        XCTAssertTrue(value.prompt.contains("本次解释时区：Asia/Shanghai"))
        for privateValue in [frozen.arrangement.id.uuidString.lowercased(), child.uuidString.lowercased(), goal.uuidString.lowercased(), frozen.arrangement.sourceText, "workspaceRevision"] {
            XCTAssertFalse(value.prompt.contains(privateValue))
        }
        let draft = try parse(value, due: "2027-02-18T17:00:00Z", evidence: "2027-02-18T17:00:00Z")
        XCTAssertEqual(draft.title, frozen.arrangement.title)
        XCTAssertEqual(draft.childID, frozen.arrangement.childID); XCTAssertEqual(draft.goalID, frozen.arrangement.goalID)
        XCTAssertEqual(draft.editTarget, frozen); XCTAssertEqual(draft.sourceText, source)
        XCTAssertEqual(draft.dueAt, try instant("2027-02-18T17:00:00Z"))
    }

    func testWrongChildOrGoalCannotBindAnEditRequest() throws {
        let frozen = try target(), token = try XCTUnwrap(AccountEpoch(account: subject.uuidString).capture())
        for pair in [(stableID("foreign-reschedule-child"), Optional(goal)), (child, nil)] {
            XCTAssertThrowsError(try ParentingIntakeRequest(scope: scope, subjectID: subject, accountToken: token, conversationID: conversationID,
                sourceText: source, childID: pair.0, goalID: pair.1, editTarget: frozen))
        }
    }

    func testNullAndOriginalContextNeverSupplyMissingTimeEvidence() throws {
        let frozen = try target(), value = try request("改到明天", target: frozen)
        let draft = try parse(value, due: nil, evidence: nil)
        XCTAssertNil(draft.dueAt); XCTAssertNotNil(draft.clarification)
        XCTAssertEqual(draft.editTarget, frozen)
        XCTAssertThrowsError(try parse(value, due: "2026-10-23T15:00:00Z", evidence: "2026-10-23T15:00:00Z")) {
            XCTAssertEqual($0 as? ParentingIntakeError, .missingTimeEvidence)
        }
    }

    func testAbsoluteISOUsesItsExplicitOffsetAcrossRequestZones() throws {
        for zone in ["America/New_York", "Pacific/Auckland", "Asia/Shanghai"] {
            let utc = try request(target: target(), zone: zone)
            XCTAssertEqual(try parse(utc, due: "2027-02-18T17:00:00Z", evidence: "2027-02-18T17:00:00Z").dueAt, try instant("2027-02-18T17:00:00Z"))
            let offset = try request("改到2027-02-18T17:00:00+08:00", target: target(), zone: zone)
            XCTAssertEqual(try parse(offset, due: "2027-02-18T09:00:00Z", evidence: "2027-02-18T17:00:00+08:00").dueAt, try instant("2027-02-18T09:00:00Z"))
        }
    }

    func testRelativeDateUsesFrozenLocalDayAndExplicitDayPeriod() throws {
        let frozen = try target()
        for text in ["改到明天下午五点", "改到明天17:00", "改到明天下午五点半"] {
            let value = try request(text, target: frozen)
            let expected = text.hasSuffix("半") ? "2026-10-25T09:30:00Z" : "2026-10-25T09:00:00Z"
            XCTAssertEqual(try parse(value, due: expected, evidence: text).dueAt, try instant(expected), text)
        }
        let yearEnd = try request("改到后天17:00", target: frozen, now: "2026-12-30T16:30:00Z")
        XCTAssertEqual(try parse(yearEnd, due: "2027-01-02T09:00:00Z", evidence: "后天17:00").dueAt, try instant("2027-01-02T09:00:00Z"))
    }

    func testLocalISOUsesFrozenZoneAndPreservesValidLeapDayAndClockBoundaries() throws {
        let cases = [("2028-02-29 17:00", "2028-02-29T09:00:00Z"),
                     ("2027-02-18 00:00", "2027-02-17T16:00:00Z"),
                     ("2027-02-18 23:59", "2027-02-18T15:59:00Z"),
                     ("2027-02-18 17:00:30", "2027-02-18T09:00:30Z")]
        for (text, expected) in cases {
            let draft = try parse(request(text, target: target()), due: expected, evidence: text)
            XCTAssertEqual(draft.dueAt, try instant(expected), text)
            XCTAssertNil(draft.clarification)
        }
    }

    func testAmbiguousInvalidUnsupportedAndMismatchedTimesStayClarifications() throws {
        let cases: [(String, String)] = [
            ("明天五点", "2026-10-25T09:00:00Z"), ("明天上午十二点", "2026-10-25T04:00:00Z"),
            ("明天晚上十二点", "2026-10-25T16:00:00Z"), ("2027-02-30 17:00", "2027-03-02T09:00:00Z"),
            ("2027-02-18 24:00", "2027-02-18T16:00:00Z"),
            ("明天17:00或后天17:00", "2026-10-25T09:00:00Z"), ("明天17:00到18:00", "2026-10-25T09:00:00Z"),
            ("大后天17:00", "2026-10-27T09:00:00Z"), ("下周五17:00", "2026-10-30T09:00:00Z"),
            ("明天17:00北京时间", "2026-10-25T09:00:00Z"), ("明天17:00以后", "2026-10-25T09:00:00Z"),
            ("不是明天17:00", "2026-10-25T09:00:00Z"), ("明天下午五点", "2026-10-24T09:00:00Z"),
            ("明天17:00", "2026-10-25T17:00:00Z"), ("明天17:00", "2026-10-25T09:00:30Z")]
        for (text, proposed) in cases {
            let draft = try parse(request(text, target: target()), due: proposed, evidence: text)
            XCTAssertNil(draft.dueAt, text); XCTAssertNotNil(draft.clarification, text)
        }
        // The unchanged v1 literal date/clock gate rejects an invalid minute before the edit verifier runs.
        XCTAssertThrowsError(try parse(request("2027-02-18 17:60", target: target()), due: "2027-02-18T10:00:00Z", evidence: "2027-02-18 17:60")) {
            XCTAssertEqual($0 as? ParentingIntakeError, .missingTimeEvidence)
        }
    }

    func testCalendarRejectsGapFoldHalfHourTransitionsAndSkippedDay() throws {
        let cases: [(String, String, String)] = [
            ("America/New_York", "2026-03-08 02:30", "2026-03-08T07:30:00Z"),
            ("America/New_York", "2026-11-01 01:30", "2026-11-01T05:30:00Z"),
            ("Australia/Lord_Howe", "2026-10-04 02:15", "2026-10-03T15:45:00Z"),
            ("Australia/Lord_Howe", "2026-04-05 01:45", "2026-04-04T14:45:00Z"),
            ("Europe/Berlin", "2026-10-25 02:30", "2026-10-25T00:30:00Z"),
            ("Pacific/Apia", "2011-12-30 12:00", "2011-12-30T22:00:00Z")]
        for (zone, text, proposed) in cases {
            let draft = try parse(request(text, target: target(), zone: zone), due: proposed, evidence: text)
            XCTAssertNil(draft.dueAt, zone + text); XCTAssertNotNil(draft.clarification)
        }
        let skipped = try request("明天12:00", target: target(), zone: "Pacific/Apia", now: "2011-12-29T22:00:00Z")
        XCTAssertNil(try parse(skipped, due: "2011-12-30T22:00:00Z", evidence: "明天12:00").dueAt)
    }

    private struct Entry { let url: URL; let repository: Repository }
    private final class Entries { var values: [Entry] = []; var failNext = false }
    private struct Harness {
        let model: ParentingInlineIntakeModel
        let backend: ParentingRescheduleBackend
        let epoch: AccountEpoch
        let directory: URL
        let entries: Entries
        let recovery: ParentingIntakeRecoveryFile?
    }
    private func make(_ backend: ParentingRescheduleBackend = .init(), recovery: Bool = false, factoryFailsOnce: Bool = false) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parenting-reschedule-intake-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let scope = self.scope, owner = subject, epoch = AccountEpoch(account: subject.uuidString), entries = Entries(), ids = ParentingRescheduleIDs()
        entries.failNext = factoryFailsOnce
        let now = try instant("2026-10-23T16:30:00Z")
        let recoveryFile = recovery ? ParentingIntakeRecoveryFile(scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher(), url: directory.appendingPathComponent("recovery.sealed")) : nil
        let factory: ParentingIntakeServiceFactory = {
            if entries.failNext { entries.failNext = false; throw ParentingInlineIntakeError.storage }
            let url = directory.appendingPathComponent("journal-\(entries.values.count).sealed")
            let repository = try Repository(persistence: ParentingIntakePersistence(url: url, scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher()))
            entries.values.append(.init(url: url, repository: repository))
            return ConversationSessionService(repository: repository, backend: ParentingIntakeConversationBackend(base: backend))
        }
        let model = ParentingInlineIntakeModel(scope: scope, subjectID: owner, factory: factory, admission: { true }, epoch: epoch,
            clock: { now }, id: { ids.next() }, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")), recoveryStore: recoveryFile)
        return .init(model: model, backend: backend, epoch: epoch, directory: directory, entries: entries, recovery: recoveryFile)
    }

    func testControllerBindsCandidateToExactEditContextAndRejectsCreateOrAnotherTarget() async throws {
        let harness = try make(), frozen = try target()
        await harness.model.request(sourceText: source, childID: child, goalID: goal, editTarget: frozen)
        XCTAssertEqual(harness.model.phase, .ready)
        let candidate = try XCTUnwrap(harness.model.candidate)
        XCTAssertTrue(harness.model.isCurrentCandidate(candidate, editTarget: frozen))
        XCTAssertFalse(harness.model.isCurrentCandidate(candidate))
        XCTAssertFalse(harness.model.isCurrentCandidate(candidate, editTarget: try target(revision: 74)))
        XCTAssertFalse(harness.model.isCurrentCandidate(candidate, editTarget: try target(id: "other-arrangement")))
        XCTAssertEqual(candidate.title, frozen.arrangement.title)
        let calls = await harness.backend.calls()
        XCTAssertEqual(calls.submitted.count, 1)
    }

    func testControllerNotSentRetryKeepsOriginalIdentityPromptAndContext() async throws {
        let harness = try make(.init(mode: .notSentOnce)), frozen = try target()
        await harness.model.request(sourceText: source, childID: child, goalID: goal, editTarget: frozen)
        XCTAssertEqual(harness.model.phase, .failed); XCTAssertTrue(harness.model.canRetry)
        await harness.model.retry()
        XCTAssertEqual(harness.model.phase, .ready); XCTAssertEqual(harness.model.candidate?.editTarget, frozen)
        let calls = await harness.backend.calls()
        XCTAssertEqual(calls.submitted.count, 2)
        XCTAssertEqual(calls.submitted[0].operationID, calls.submitted[1].operationID)
        XCTAssertEqual(calls.submitted[0].conversationID, calls.submitted[1].conversationID)
        XCTAssertEqual(calls.submitted[0].history.last?.content, calls.submitted[1].history.last?.content)
    }

    func testFailureBeforeWorkCanRetryLastInputWithItsFrozenTarget() async throws {
        let harness = try make(factoryFailsOnce: true), frozen = try target()
        await harness.model.request(sourceText: source, childID: child, goalID: goal, editTarget: frozen)
        XCTAssertEqual(harness.model.phase, .failed); XCTAssertTrue(harness.model.canRetry)
        let before = await harness.backend.calls()
        XCTAssertTrue(before.submitted.isEmpty)
        await harness.model.retry()
        XCTAssertEqual(harness.model.phase, .ready)
        XCTAssertEqual(harness.model.candidate?.editTarget, frozen)
        XCTAssertEqual(harness.model.candidate?.sourceText, source)
        let after = await harness.backend.calls()
        XCTAssertEqual(after.submitted.count, 1)
    }

    func testControllerTerminalRetryUsesNewIdentityWithSameFrozenTarget() async throws {
        let harness = try make(.init(mode: .invalidOnce)), frozen = try target()
        await harness.model.request(sourceText: source, childID: child, goalID: goal, editTarget: frozen)
        XCTAssertEqual(harness.model.phase, .failed)
        await harness.model.retry()
        XCTAssertEqual(harness.model.phase, .ready); XCTAssertEqual(harness.model.candidate?.editTarget, frozen)
        let calls = await harness.backend.calls()
        XCTAssertEqual(calls.submitted.count, 2)
        XCTAssertNotEqual(calls.submitted[0].operationID, calls.submitted[1].operationID)
        XCTAssertNotEqual(calls.submitted[0].conversationID, calls.submitted[1].conversationID)
    }

    func testUnknownRetryOnlyReadsAndColdRecoveryPreservesContextAndFrozenTime() async throws {
        let backend = ParentingRescheduleBackend(mode: .unknown, due: "2026-10-25T09:00:00Z", evidence: "明天下午五点")
        let harness = try make(backend, recovery: true), frozen = try target(), text = "改到明天下午五点"
        await harness.model.request(sourceText: text, childID: child, goalID: goal, editTarget: frozen)
        XCTAssertEqual(harness.model.phase, .unknown)
        await harness.model.retry()
        let before = await backend.calls(), original = try XCTUnwrap(before.submitted.first)
        XCTAssertEqual(before.submitted.count, 1); XCTAssertFalse(before.observed.isEmpty)
        XCTAssertEqual(try harness.recovery?.read()?.editTarget, frozen)
        harness.epoch.bump()
        let owner = subject, scope = self.scope, epoch = harness.epoch, entry = try XCTUnwrap(harness.entries.values.first)
        let recovery = ParentingIntakeRecoveryFile(scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher(), url: harness.directory.appendingPathComponent("recovery.sealed"))
        let factory: ParentingIntakeServiceFactory = {
            let repository = try Repository(persistence: ParentingIntakePersistence(url: entry.url, scope: scope, subjectID: owner, epoch: epoch, cipher: ParentingTestCipher()))
            return ConversationSessionService(repository: repository, backend: ParentingIntakeConversationBackend(base: backend))
        }
        let later = try instant("2026-10-24T15:00:00Z")
        let restored = ParentingInlineIntakeModel(scope: scope, subjectID: owner, factory: factory, admission: { true }, epoch: epoch,
            clock: { later }, timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")), recoveryStore: recovery)
        await backend.finishOnObservation()
        await restored.recover()
        XCTAssertEqual(restored.phase, .ready)
        XCTAssertEqual(restored.recoveredRequest?.editTarget, frozen)
        XCTAssertEqual(restored.recoveredRequest?.timeZoneID, "Asia/Shanghai")
        XCTAssertEqual(restored.candidate?.editTarget, frozen)
        XCTAssertEqual(restored.candidate?.dueAt, try instant("2026-10-25T09:00:00Z"))
        XCTAssertTrue(restored.isCurrentCandidate(try XCTUnwrap(restored.candidate), editTarget: frozen))
        let after = await backend.calls()
        XCTAssertEqual(after.submitted.count, 1)
        XCTAssertTrue(after.observed.allSatisfy { $0.operationID == original.operationID && $0.conversationID == original.conversationID && $0.history.last?.content == original.history.last?.content })
    }

    func testInvalidationAndNewTargetFenceHeldReplyEvenForSameSource() async throws {
        let started = expectation(description: "held transport reached")
        let backend = ParentingRescheduleBackend(mode: .held, started: { started.fulfill() })
        let harness = try make(backend), oldTarget = try target(), newTarget = try target(id: "new-selected-arrangement", revision: 74)
        let waiting = Task { await harness.model.request(sourceText: source, childID: child, goalID: goal, editTarget: oldTarget) }
        await fulfillment(of: [started], timeout: 2)
        harness.model.invalidate()
        await backend.release()
        await waiting.value
        XCTAssertNil(harness.model.candidate)
        await harness.model.request(sourceText: source, childID: child, goalID: goal, editTarget: newTarget)
        let candidate = try XCTUnwrap(harness.model.candidate)
        XCTAssertEqual(candidate.editTarget, newTarget)
        XCTAssertFalse(harness.model.isCurrentCandidate(candidate, editTarget: oldTarget))
        XCTAssertTrue(harness.model.isCurrentCandidate(candidate, editTarget: newTarget))
    }

    func testAccountChangeFencesHeldEditCandidate() async throws {
        let started = expectation(description: "held account transport reached")
        let backend = ParentingRescheduleBackend(mode: .held, started: { started.fulfill() })
        let harness = try make(backend), frozen = try target()
        let waiting = Task { await harness.model.request(sourceText: source, childID: child, goalID: goal, editTarget: frozen) }
        await fulfillment(of: [started], timeout: 2)
        harness.epoch.bump()
        await backend.release()
        await waiting.value
        XCTAssertNil(harness.model.candidate)
        XCTAssertEqual(harness.model.phase, .cancelled)
    }
}
