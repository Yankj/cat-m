import Foundation

@MainActor enum NativeParentingIntakeComposition {
    private final class CachedRepository {
        weak var repository: Repository?
        let persistence: ParentingIntakePersistence
        init(_ repository: Repository, persistence: ParentingIntakePersistence) { self.repository = repository; self.persistence = persistence }
    }
    // Cache identity only weakly: consumed/cancelled requests must not retain a plaintext snapshot here.
    private static var repositories: [String: CachedRepository] = [:]
    /// Composition itself performs no I/O. The closure runs only for an explicit request.
    static func factory(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials,
                        subjectID: UUID) -> ParentingIntakeServiceFactory {
        return {
            guard configuration.expectedSubjectID == subjectID,
                  let token = AccountEpoch.shared.capture(), UUID(uuidString: token.account) == subjectID else {
                throw ParentingInlineIntakeError.changedContext
            }
            let root = ParentingIntakePaths.directory(scope: configuration.localScope, subjectID: subjectID)
            let cacheKey = root.path + ":\(token.epoch)"
            let repository: Repository
            if let cached = repositories[cacheKey], cached.persistence.isCurrentGeneration, let existing = cached.repository,
               FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.sealed").path) {
                _ = try cached.persistence.load() // Existing bytes must still authenticate before a recovery service opens.
                repository = existing
            }
            else {
                let persistence = ParentingIntakePersistence(url: root.appendingPathComponent("journal.sealed"), scope: configuration.localScope, subjectID: subjectID)
                repository = try Repository(persistence: persistence); repositories[cacheKey] = CachedRepository(repository, persistence: persistence)
            }
            let http = NativeChatHTTPBackend(configuration: configuration, credentials: credentials, purpose: .parentingIntake)
            return ConversationSessionService(repository: repository, backend: ParentingIntakeConversationBackend(base: http),
                resilience: nil, outbox: nil, principal: token)
        }
    }
}

/// Stops the generic conversation pump's automatic reconnect path. Recovery is explicit readback only.
struct ParentingIntakeConversationBackend: ConversationBackend, ParentingIntakeDataDeleting {
    let base: any ConversationBackend
    func connection(scope: DataScope) async -> ConversationConnection { await base.connection(scope: scope) }
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? {
        try await base.modelConsent(scope: scope, conversationID: conversationID)
    }
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws { try await base.allowModelConsent(scope: scope, consent: consent) }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        do { return restricted(try await base.reply(request)) }
        catch is ConversationStreamInterrupted { throw ParentingInlineIntakeError.unknown }
    }
    func resumeEvents(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        do { return restricted(try await base.resumeEvents(request, afterSequence: afterSequence)) }
        catch is ConversationStreamInterrupted { throw ParentingInlineIntakeError.unknown }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        let response = try await base.observe(request)
        guard response.goals.isEmpty, response.pendingApprovals.isEmpty, response.pendingUIApprovals.isEmpty else { throw ParentingInlineIntakeError.invalidResponse }
        for event in response.events { try Self.validate(event) }
        return response
    }
    func cancelTurn(_ request: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt { try await base.cancelTurn(request) }
    func deleteIntake(scope: DataScope, conversationID: UUID) async throws {
        guard let deleting = base as? any ParentingIntakeDataDeleting else { throw ParentingInlineIntakeError.unavailable }
        try await deleting.deleteIntake(scope: scope, conversationID: conversationID)
    }
    private func restricted(_ stream: AsyncThrowingStream<ConversationTurnEvent, Error>) -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in stream { try Task.checkCancellation(); try Self.validate(event); continuation.yield(event) }
                    continuation.finish()
                } catch is ConversationStreamInterrupted { continuation.finish(throwing: ParentingInlineIntakeError.unknown) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func validate(_ event: ConversationTurnEvent) throws {
        switch event.payload {
        case .thread, .started, .textDelta, .completed, .failed, .reasoningSummary, .textPreview: return
        default: throw ParentingInlineIntakeError.invalidResponse
        }
    }
}
