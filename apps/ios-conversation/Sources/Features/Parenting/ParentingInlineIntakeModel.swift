import Foundation
import Combine

/// Built only after an explicit parenting request. The service owns a separate encrypted journal.
public typealias ParentingIntakeServiceFactory = @MainActor () throws -> ConversationSessionService

/// Owns one explicit request, a private conversation and a private journal; never mutates the parenting ledger.
@MainActor
final class ParentingInlineIntakeModel: ObservableObject {
    @Published private(set) var phase: ParentingIntakePhase = .idle
    @Published private(set) var busy = false
    @Published private(set) var candidate: ParentingIntakeDraft?
    @Published private(set) var error: String?
    @Published private(set) var consent: ConversationModelConsent?
    @Published private(set) var consentID: UUID?
    @Published private(set) var recoveryAvailable = false
    @Published private(set) var recoveredRequest: ParentingIntakeRecoveryReference?
    @Published private(set) var deletionPending = false
    @Published private(set) var deletionError: String?

    private enum Recovery: Equatable { case notSent, readOnly, terminal, blocked }
    private struct Work {
        let generation: UUID
        let request: ParentingIntakeRequest
        let reference: ParentingIntakeRecoveryReference
        let service: ConversationSessionService
        var recovery: Recovery = .notSent
    }
    private let scope: DataScope
    private let subjectID: UUID?
    private let factory: ParentingIntakeServiceFactory?
    private let admission: @MainActor () -> Bool
    private let epoch: AccountEpoch
    private let clock: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let timeZone: TimeZone
    private let recoveryStore: (any ParentingIntakeRecoveryStoring)?
    private let cleanupStore: (any ParentingIntakeCleanupStoring)?
    private let localPurge: (@MainActor () throws -> Void)?
    private var deletionTask: Task<Void, Never>?
    private var lastInput: (source: String, child: UUID, goal: UUID?, editTarget: ParentingArrangementEditTarget?)?
    private var generation = UUID()
    private var work: Work?
    private var task: Task<Void, Never>?

    init(scope: DataScope, subjectID: UUID?, factory: ParentingIntakeServiceFactory?, admission: @escaping @MainActor () -> Bool) {
        self.scope = scope; self.subjectID = subjectID; self.factory = factory; self.admission = admission
        epoch = .shared; clock = { Date() }; makeID = { UUID() }; timeZone = .current
        let recovery = subjectID.flatMap { subject in factory == nil ? nil : ParentingIntakeRecoveryFile(scope: scope, subjectID: subject) }
        recoveryStore = recovery; recoveryAvailable = recovery?.exists ?? false
        cleanupStore = subjectID.flatMap { subject in factory == nil ? nil : ParentingIntakeCleanupFile(scope: scope, subjectID: subject) }
        if let subjectID { localPurge = { try ParentingIntakePersistence.deleteTemporaryCopies(scope: scope, subjectID: subjectID) } }
        else { localPurge = nil }
        refreshRecoveryStatus()
    }
    init(scope: DataScope, subjectID: UUID?, factory: ParentingIntakeServiceFactory?, admission: @escaping @MainActor () -> Bool,
         epoch: AccountEpoch, clock: @escaping @Sendable () -> Date = { Date() }, id: @escaping @Sendable () -> UUID = { UUID() }, timeZone: TimeZone = .current,
         recoveryStore: (any ParentingIntakeRecoveryStoring)? = nil, cleanupStore: (any ParentingIntakeCleanupStoring)? = nil,
         localPurge: (@MainActor () throws -> Void)? = nil) {
        self.scope = scope; self.subjectID = subjectID; self.factory = factory; self.admission = admission
        self.epoch = epoch; self.clock = clock; makeID = id; self.timeZone = timeZone
        self.recoveryStore = recoveryStore; recoveryAvailable = recoveryStore?.exists ?? false
        self.cleanupStore = cleanupStore; self.localPurge = localPurge
        refreshRecoveryStatus()
    }
    convenience init(scope: DataScope, subjectID: UUID?, service: ConversationSessionService, admission: @escaping @MainActor () -> Bool,
                     epoch: AccountEpoch, clock: @escaping @Sendable () -> Date = { Date() }, id: @escaping @Sendable () -> UUID = { UUID() },
                     timeZone: TimeZone = .current, recoveryStore: (any ParentingIntakeRecoveryStoring)? = nil) {
        self.init(scope: scope, subjectID: subjectID, factory: { service }, admission: admission, epoch: epoch,
                  clock: clock, id: id, timeZone: timeZone, recoveryStore: recoveryStore)
    }

    var canRetry: Bool {
        guard !busy, !deletionPending, phase == .failed, admission(), factory != nil, let subjectID,
              let token = epoch.capture(), UUID(uuidString: token.account) == subjectID else { return false }
        if let work { return isCurrent(work) && [.notSent, .terminal].contains(work.recovery) }
        return lastInput != nil
    }
    var canReconcile: Bool { !busy && phase == .unknown && work.map { isCurrent($0) && $0.recovery == .readOnly } == true }

    func request(sourceText: String, childID: UUID, goalID: UUID?, editTarget: ParentingArrangementEditTarget? = nil) async {
        guard !Task.isCancelled, !busy, phase != .awaitingConsent, phase != .unknown else { return }
        guard !deletionPending else { deletionError = Self.cleanupMessage; return }
        stop(publish: .idle)
        let owner = generation
        lastInput = (sourceText, childID, goalID, editTarget)
        do {
            // A new explicit request replaces an unclaimed cold recovery record as well.
            if recoveryAvailable, let previous = try recoveryStore?.read() {
                try enqueueCleanup(previous, pending: true); try purgeLocalCopies()
                let deletionScope = previous.scope, conversationID = previous.conversationID
                deletionTask = Task { await self.deleteRemote(scope: deletionScope, conversationID: conversationID) }
            }
        } catch { phase = .failed; self.error = ParentingInlineIntakeError.storage.localizedDescription; return }
        if let deletionTask { busy = true; phase = .preparing; await deletionTask.value; busy = false }
        guard generation == owner, !Task.isCancelled else { return }
        guard !deletionPending else { phase = .failed; deletionError = Self.cleanupMessage; return }
        guard let subjectID, let token = epoch.capture(), UUID(uuidString: token.account) == subjectID,
              admission(), let factory else { phase = .failed; error = ParentingInlineIntakeError.unavailable.localizedDescription; return }
        do {
            let requestID = makeID(), conversationID = makeID()
            guard requestID != conversationID else { throw ParentingInlineIntakeError.changedContext }
            let reference = ParentingIntakeRecoveryReference(requestID: requestID, scope: scope, subjectID: subjectID,
                conversationID: conversationID, sourceText: sourceText, childID: childID, goalID: goalID, startedAt: clock(), timeZoneID: timeZone.identifier, editTarget: editTarget)
            let request = try reference.request(accountToken: token)
            let service = try factory()
            let context = Work(generation: generation, request: request, reference: reference, service: service)
            work = context; phase = .preparing; busy = true
            await launch { await self.prepare(context) }
        } catch {
            phase = .failed; busy = false; self.error = visibleError(error)
        }
    }

    func retry() async {
        guard !Task.isCancelled, !busy else { return }
        guard let context = work else {
            if canRetry, let input = lastInput { await request(sourceText: input.source, childID: input.child, goalID: input.goal, editTarget: input.editTarget) }
            return
        }
        guard accept(context) else { return }
        switch context.recovery {
        case .readOnly: await reconcile()
        case .blocked: return
        case .terminal:
            guard phase == .failed else { return }
            await request(sourceText: context.request.sourceText, childID: context.request.childID, goalID: context.request.goalID, editTarget: context.request.editTarget)
        case .notSent:
            guard phase == .failed else { return }
            phase = .preparing; busy = true; error = nil
            await launch { await self.prepare(context) }
        }
    }

    /// GET/readback only. A result with unknown admission never becomes a new provider send.
    func reconcile() async {
        guard !Task.isCancelled, !busy, let context = work, accept(context), context.recovery == .readOnly else { return }
        busy = true; error = nil
        await launch {
            do {
                try self.check(context)
                try await context.service.observe(scope: self.scope, conversationID: context.request.conversationID)
                try self.check(context)
                await self.project(context, fallback: ParentingInlineIntakeError.unknown)
            } catch {
                guard self.accept(context) else { return }
                self.phase = .unknown; self.busy = false; self.error = ParentingInlineIntakeError.unknown.localizedDescription
            }
        }
    }

    /// Explicit cold recovery opens the encrypted journal and reads the old identity; it never sends a model request.
    func recover() async {
        if work != nil { if canReconcile { await reconcile() }; return }
        guard !Task.isCancelled, !busy, !deletionPending, phase != .awaitingConsent, admission(), let subjectID,
              let token = epoch.capture(), UUID(uuidString: token.account) == subjectID,
              let factory, let recoveryStore else { return }
        stop(publish: .preparing); busy = true
        do {
            guard let reference = try recoveryStore.read(), reference.scope == scope, reference.subjectID == subjectID else {
                throw ParentingInlineIntakeError.storage
            }
            guard clock().timeIntervalSince(reference.startedAt) < ParentingIntakeRecoveryReference.maximumAge else {
                try enqueueCleanup(reference, pending: true); try purgeLocalCopies()
                recoveryAvailable = false; deletionPending = true
                throw ParentingInlineIntakeError.storage
            }
            let request = try reference.request(accountToken: token)
            let service = try factory()
            let context = Work(generation: generation, request: request, reference: reference, service: service, recovery: .readOnly)
            work = context; recoveredRequest = reference; lastInput = (reference.sourceText, reference.childID, reference.goalID, reference.editTarget)
            recoveryAvailable = true
            await launch {
                do {
                    try self.check(context)
                    let saved = try await service.read(scope: self.scope, conversationID: request.conversationID)
                    try self.check(context)
                    if let turn = saved.turns.first(where: { $0.id == request.id }), turn.state != .completed {
                        try await service.observe(scope: self.scope, conversationID: request.conversationID)
                    }
                    try self.check(context)
                    await self.project(context, fallback: ParentingInlineIntakeError.unknown)
                } catch {
                    guard self.accept(context) else { return }
                    self.phase = .unknown; self.busy = false; self.error = ParentingInlineIntakeError.unknown.localizedDescription
                }
            }
        } catch {
            phase = .failed; busy = false; self.error = ParentingInlineIntakeError.storage.localizedDescription
        }
    }

    func allowConsent() async { if let consentID { await allowConsent(matchingID: consentID) } }
    func allowConsent(matchingID: UUID) async {
        guard !Task.isCancelled, !busy, phase == .awaitingConsent, consentID == matchingID,
              let frozen = consent, let context = work, isCurrent(context), frozen.conversationID == context.request.conversationID else { return }
        busy = true; error = nil
        // Consume this exact review before awaiting. A dismissed or superseded sheet cannot allow a later request.
        consent = nil; consentID = nil
        await launch {
            do {
                try self.check(context)
                try await context.service.allowModelConsent(scope: self.scope, consent: frozen)
                try self.check(context)
                await self.prepare(context)
            } catch {
                guard self.accept(context) else { return }
                self.phase = .failed; self.busy = false; self.error = self.visibleError(error)
            }
        }
    }
    func deferConsent() { if let consentID { deferConsent(matchingID: consentID) } }
    func deferConsent(matchingID: UUID) {
        guard consentID == matchingID else { return }
        stop(publish: .cancelled)
    }
    func cancel() { stop(publish: .cancelled) }
    func invalidate() { stop(publish: .idle) }

    func isCurrentCandidate(_ value: ParentingIntakeDraft, editTarget: ParentingArrangementEditTarget? = nil) -> Bool {
        guard phase == .ready, candidate == value, let context = work, isCurrent(context) else { return false }
        return value.sourceText == context.request.sourceText && value.childID == context.request.childID && value.goalID == context.request.goalID &&
            value.editTarget == context.request.editTarget && value.editTarget == editTarget
    }

    private func prepare(_ context: Work) async {
        do {
            try check(context)
            do { _ = try await context.service.read(scope: scope, conversationID: context.request.conversationID) }
            catch catError.missing { _ = try await context.service.create(scope: scope, id: context.request.conversationID) }
            try check(context)
            try enqueueCleanup(context.reference, pending: false)
            try recoveryStore?.save(context.reference)
            recoveryAvailable = recoveryStore?.exists ?? false
            let notice = try await context.service.modelConsent(scope: scope, conversationID: context.request.conversationID)
            try check(context)
            if let notice {
                guard notice.conversationID == context.request.conversationID else { throw ParentingInlineIntakeError.invalidResponse }
                consent = notice; consentID = UUID(); phase = .awaitingConsent; busy = false
                return
            }
            phase = .sending
            _ = try await context.service.send(scope: scope, conversationID: context.request.conversationID,
                text: context.request.prompt, operationID: context.request.id)
            try check(context)
            await project(context, fallback: ParentingInlineIntakeError.unknown)
        } catch {
            guard accept(context) else { return }
            await project(context, fallback: error)
        }
    }

    private func project(_ context: Work, fallback: Error) async {
        guard accept(context) else { return }
        var confirmedCompletion = false
        do {
            let session = try await context.service.read(scope: scope, conversationID: context.request.conversationID)
            try check(context)
            if let turn = session.turns.first(where: { $0.id == context.request.id }) {
                switch turn.state {
                case .completed:
                    confirmedCompletion = true
                    let value = try context.request.parse(session: session, currentAccount: epoch.capture())
                    try check(context)
                    candidate = value; phase = .ready; error = nil; busy = false; work?.recovery = .terminal
                    return
                case .notSent:
                    work?.recovery = context.recovery == .readOnly ? .readOnly : .notSent
                case .dispatched, .running, .unknown:
                    work?.recovery = .readOnly
                case .failed, .cancelledBeforeSend:
                    let localUnknown = [ConversationSessionService.outcomeUnverified, ConversationSessionService.unknownTurnGaveUp].contains(turn.error ?? "")
                    work?.recovery = localUnknown ? .readOnly : .terminal
                }
            } else {
                // No local turn means send never reached its journal/admission step.
                work?.recovery = context.recovery == .readOnly ? .readOnly : .notSent
            }
            candidate = nil; busy = false
            if work?.recovery == .readOnly { phase = .unknown; error = ParentingInlineIntakeError.unknown.localizedDescription }
            else { phase = .failed; error = work?.recovery == .notSent ? ParentingInlineIntakeError.notSent.localizedDescription : visibleError(fallback) }
        } catch {
            guard accept(context) else { return }
            candidate = nil; busy = false
            if !confirmedCompletion, context.recovery == .readOnly || work?.recovery == .readOnly {
                phase = .unknown; work?.recovery = .readOnly; self.error = ParentingInlineIntakeError.unknown.localizedDescription
            } else if confirmedCompletion {
                phase = .failed; work?.recovery = .terminal; self.error = visibleError(error)
            } else if let failure = error as? catError, case .missing = failure {
                phase = .failed; work?.recovery = .notSent; self.error = ParentingInlineIntakeError.notSent.localizedDescription
            } else {
                phase = .failed; work?.recovery = .blocked; self.error = ParentingInlineIntakeError.storage.localizedDescription
            }
        }
    }

    private func launch(_ action: @escaping @MainActor () async -> Void) async {
        let owner = generation
        let running = Task { await action() }; task = running
        await running.value
        if generation == owner { task = nil }
    }
    private func isCurrent(_ context: Work) -> Bool {
        generation == context.generation && work?.generation == context.generation && admission() &&
        epoch.isValid(context.request.accountToken) && subjectID == context.request.subjectID
    }
    private func check(_ context: Work) throws {
        try Task.checkCancellation()
        guard isCurrent(context) else { throw ParentingInlineIntakeError.changedContext }
    }
    private func accept(_ context: Work) -> Bool {
        guard generation == context.generation, work?.generation == context.generation else { return false }
        guard isCurrent(context) else {
            stop(publish: .cancelled); error = ParentingInlineIntakeError.changedContext.localizedDescription
            return false
        }
        return true
    }
    private func stop(publish: ParentingIntakePhase) {
        let previous = work
        generation = UUID(); work = nil; task?.cancel(); task = nil
        consent = nil; consentID = nil; candidate = nil; recoveredRequest = nil; lastInput = nil; error = nil; busy = false; phase = publish
        if let previous {
            if cleanupStore != nil || localPurge != nil {
                do { try enqueueCleanup(previous.reference, pending: true); try purgeLocalCopies() }
                catch { deletionPending = true; deletionError = Self.cleanupMessage }
                let deletionScope = previous.request.scope, conversationID = previous.request.conversationID
                deletionTask = Task { await self.deleteRemote(scope: deletionScope, conversationID: conversationID) }
            } else {
                // Offline test compositions can omit the production cleanup stores.
                Task { _ = try? await previous.service.cancelCurrentTurn(scope: previous.request.scope, conversationID: previous.request.conversationID) }
            }
        }
    }

    func consumeCandidate() { stop(publish: .idle) }
    func deleteLocalRecord() {
        if work != nil { stop(publish: .idle); return }
        do {
            if let reference = try recoveryStore?.read() { try enqueueCleanup(reference, pending: true) }
            try purgeLocalCopies()
            recoveryAvailable = false; recoveredRequest = nil; candidate = nil
        } catch { deletionPending = true; deletionError = Self.cleanupMessage }
        deletionTask = Task { await self.retryDeletion() }
    }
    func retryDeletion() async {
        guard !Task.isCancelled, admission(), let factory, let subjectID,
              let token = epoch.capture(), UUID(uuidString: token.account) == subjectID else { return }
        do {
            try purgeLocalCopies()
            let pending = try cleanupStore?.read().filter(\.pending) ?? []
            guard !pending.isEmpty else { deletionPending = false; deletionError = nil; return }
            let service = try factory()
            for reference in pending {
                guard epoch.isValid(token), admission() else { throw ParentingInlineIntakeError.changedContext }
                try await service.deleteParentingIntake(scope: reference.scope, conversationID: reference.conversationID)
                guard epoch.isValid(token) else { throw ParentingInlineIntakeError.changedContext }
                try removeCleanup(reference.conversationID)
            }
            deletionPending = false; deletionError = nil
        } catch { deletionPending = true; deletionError = Self.cleanupMessage }
    }
    private static let cleanupMessage = "临时整理记录尚未清理完成。现有表单内容不变，请重试清理后再开始新的整理。"
    private func enqueueCleanup(_ reference: ParentingIntakeRecoveryReference, pending: Bool) throws {
        guard let cleanupStore else { return }
        var entries = try cleanupStore.read()
        entries.removeAll { $0.conversationID == reference.conversationID }
        entries.append(.init(scope: reference.scope, subjectID: reference.subjectID, conversationID: reference.conversationID, pending: pending))
        try cleanupStore.save(entries)
        deletionPending = entries.contains(where: \.pending)
    }
    private func removeCleanup(_ conversationID: UUID) throws {
        guard let cleanupStore else { return }
        let entries = try cleanupStore.read().filter { $0.conversationID != conversationID }
        try cleanupStore.save(entries); deletionPending = entries.contains(where: \.pending)
    }
    private func purgeLocalCopies() throws {
        try localPurge?(); try recoveryStore?.delete()
        recoveryAvailable = false; recoveredRequest = nil
    }
    private func deleteRemote(scope: DataScope, conversationID: UUID) async {
        do {
            guard let factory else { throw ParentingInlineIntakeError.unavailable }
            let service = try factory()
            try await service.deleteParentingIntake(scope: scope, conversationID: conversationID)
            try removeCleanup(conversationID)
            if !deletionPending { deletionError = nil }
        } catch { deletionPending = true; deletionError = Self.cleanupMessage }
    }
    private func refreshRecoveryStatus() {
        do {
            deletionPending = try cleanupStore?.read().contains(where: \.pending) ?? false
            if let reference = try recoveryStore?.read(), clock().timeIntervalSince(reference.startedAt) >= ParentingIntakeRecoveryReference.maximumAge {
                try enqueueCleanup(reference, pending: true); try purgeLocalCopies(); deletionPending = true
            }
        } catch {
            if cleanupStore?.exists == true { deletionPending = true; deletionError = Self.cleanupMessage }
        }
    }
    private func visibleError(_ error: Error) -> String {
        if let value = error as? ParentingIntakeError { return value.localizedDescription }
        if let value = error as? ParentingInlineIntakeError { return value.localizedDescription }
        if error is ConversationDispatchFailure { return ParentingInlineIntakeError.notSent.localizedDescription }
        return ParentingInlineIntakeError.failed.localizedDescription
    }
}
