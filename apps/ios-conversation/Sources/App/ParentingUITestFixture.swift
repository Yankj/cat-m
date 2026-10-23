#if DEBUG
import Foundation
import SwiftUI

/// Opt-in, in-process UI acceptance only. It cannot select an HTTP/Auth/model adapter.
/// A recognized request remains on the fixture error surface even when its UUID is invalid.
enum ParentingUITestFixture {
    static let successScenario = "p0-ui-parenting-success"
    static let failureScenario = "p0-ui-parenting-preparation-failure"
    static let saveRollbackScenario = "p0-ui-parenting-save-rollback"
    static let unknownScenario = "p0-ui-parenting-unknown-readback"
    static let adjustmentScenario = "p0-ui-parenting-adjustment"
    static var isRequested: Bool {
        [successScenario, failureScenario, saveRollbackScenario, unknownScenario, adjustmentScenario]
            .contains(ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] ?? "")
    }
    static func installNetworkGuard() {
        guard isRequested else { return }
        _ = URLProtocol.registerClass(ParentingUITestNoNetworkProtocol.self)
    }

    @MainActor static func make() throws -> ConversationFirstModel {
        guard isRequested,
              let raw = ProcessInfo.processInfo.environment["CF_UI_TEST_STORE"],
              let runID = UUID(uuidString: raw) else {
            throw catError.invalid("Synthetic parenting UI requires an explicit isolated store UUID.")
        }
        installNetworkGuard()
        let identity = runID.uuidString.lowercased()
        let subject = stableID("parenting-ui-subject:" + identity)
        let profile = stableID("parenting-ui-profile:" + identity)
        let scope = Profiles.inEnvironment(.local, profile: .init(profileID: profile, workspaceID: profile))
        // The real store captures its account epoch in init; activate before constructing any view/store.
        AccountEpoch.shared.activate(account: subject.uuidString)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatpawParenting-UI-qa-" + identity, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Never reset or seed this directory. A relaunch with the same UUID reads the actual saved ledger.
        let persistence = try SwiftDataPersistence(url: root.appendingPathComponent("local.store"))
        let repository = try Repository(persistence: persistence)
        if ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] == saveRollbackScenario {
            // The real SwiftData ModelContext throws immediately before save and rolls back its pending changes.
            // This scenario must cold-relaunch as successScenario to avoid arming another process's first save.
            persistence.failNextSaveForTesting()
        }
        let boundary = ParentingUITestBackend(scope: scope,
            failPreparationOnce: ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] == failureScenario,
            unknownReply: ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] == unknownScenario,
            adjustmentReply: ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] == adjustmentScenario)
        let factory: ParentingIntakeServiceFactory = {
            guard let token = AccountEpoch.shared.capture(), UUID(uuidString: token.account) == subject else {
                throw ParentingInlineIntakeError.changedContext
            }
            let directory = ParentingIntakePaths.directory(scope: scope, subjectID: subject)
            let persistence = ParentingIntakePersistence(url: directory.appendingPathComponent("journal.sealed"),
                scope: scope, subjectID: subject)
            return ConversationSessionService(repository: try Repository(persistence: persistence),
                backend: ParentingIntakeConversationBackend(base: boundary), principal: token)
        }
        let model = ConversationFirstModel(repository: repository,
            service: ConversationSessionService(repository: repository, backend: UnconfiguredConversationBackend()),
            scope: scope, subjectID: subject, parentingIntakeFactory: factory)
        model.setNetworkAdmissionAllowed(true) // Only the injected in-process boundary is reachable.
        return model
    }
}

/// Extra defense for default URL loading. Dedicated fixture composition and CI config isolation are the network boundary;
/// URLProtocol registration does not cover every custom or background URLSession configuration.
private final class ParentingUITestNoNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ParentingUITestFixture.isRequested && ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}

@MainActor struct ParentingUITestSurface: View {
    let model: ConversationFirstModel?
    let error: String?
    @Environment(\.dynamicTypeSize) private var systemTextSize
    private var syntheticColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["CATPAW_PARENTING_UI_COLOR_SCHEME"] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
    var body: some View {
        Group {
            if let model {
                ParentingHomeView(model: model, accountLabel: "Synthetic parenting UI account")
            } else if let error {
                VStack(spacing: 12) {
                    Text("Synthetic parenting UI fixture could not open").font(.headline)
                    Text(verbatim: error).textSelection(.enabled)
                }.padding().accessibilityIdentifier("parenting.fixture.error")
            } else {
                ProgressView("Opening synthetic parenting UI").accessibilityIdentifier("parenting.fixture.loading")
            }
        }
        // Explicit DEBUG display axes apply to the actual Home and all of its sheets.
        .environment(\.dynamicTypeSize, P0ExperienceFixture.textSizeOverride ?? systemTextSize)
        .preferredColorScheme(syntheticColorScheme)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("Synthetic parenting UI · in-process AI boundary")
                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                .padding(.vertical, 4).frame(maxWidth: .infinity).background(catColors.background)
                .accessibilityIdentifier("parenting.fixture.identity")
        }
    }
}

/// Only transport outcomes are synthetic. The real session service, strict parser, consent controller,
/// AES journal, workspace store and SwiftUI actions remain in the acceptance path.
private actor ParentingUITestBackend: ConversationBackend, ParentingIntakeDataDeleting {
    private let scope: DataScope
    private var failPreparationOnce: Bool
    private var failDeletionOnce: Bool
    private var grantedConversations = Set<UUID>()
    private let unknownReply: Bool
    private let adjustmentReply: Bool
    private var receivedUnknownReply = false
    private var violatedOriginalRequest = false
    private var originalRequest: ConversationTurnRequest?
    private var originalRequestBytes: Data?
    private let routeHash = textHash("parenting-native-ui-synthetic-only")
    init(scope: DataScope, failPreparationOnce: Bool, unknownReply: Bool = false, adjustmentReply: Bool = false) {
        self.scope = scope
        self.failPreparationOnce = failPreparationOnce
        self.failDeletionOnce = failPreparationOnce
        self.unknownReply = unknownReply
        self.adjustmentReply = adjustmentReply
    }
    func connection(scope: DataScope) async -> ConversationConnection {
        .init(state: .providerUnverified, provider: "Synthetic parenting UI boundary", detail: "In-process only; no HTTP/Auth/model")
    }
    func modelConsent(scope: DataScope, conversationID: UUID) async throws -> ConversationModelConsent? {
        guard scope == self.scope else { throw catError.scopeMismatch }
        if failPreparationOnce {
            failPreparationOnce = false
            throw URLError(.notConnectedToInternet) // Explicit refusal before remote preparation/create.
        }
        if grantedConversations.contains(conversationID) { return nil }
        return .init(conversationID: conversationID, title: "Synthetic parenting UI consent",
            body: "This request stays in the app's injected transport boundary. No Auth, HTTP, model provider or family data is contacted.",
            routeHash: routeHash, expectedRevision: 0)
    }
    func allowModelConsent(scope: DataScope, consent: ConversationModelConsent) async throws {
        guard scope == self.scope, consent.routeHash == routeHash, consent.expectedRevision == 0 else {
            throw ConversationSessionError.invalidEvent
        }
        grantedConversations.insert(consent.conversationID)
    }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        if unknownReply, receivedUnknownReply {
            // Latch every second submission, including a fresh cid/op, so a later readback cannot hide a resend.
            violatedOriginalRequest = true
            throw ConversationSessionError.invalidEvent
        }
        guard request.scope == scope, grantedConversations.contains(request.conversationID) else {
            throw ConversationDispatchFailure.notSent(reason: "Synthetic UI consent has not been allowed")
        }
        if unknownReply {
            receivedUnknownReply = true
            originalRequest = request
            originalRequestBytes = try Self.encodedRequest(request)
            return AsyncThrowingStream { continuation in
                // No event was delivered, so readback must start from sequence zero.
                continuation.finish(throwing: ConversationStreamInterrupted(reason: "Synthetic response lost after submission"))
            }
        }
        if adjustmentReply {
            let supplied = request.history.last?.content ?? ""
            guard supplied.contains("Change to 2027-02-18T17:00:00Z."),
                  !supplied.contains("Synthetic Reschedule Child"),
                  !supplied.contains("Synthetic retained growth goal") else {
                throw ConversationSessionError.invalidEvent
            }
        }
        let events = try Self.completedEvents(request, adjustment: adjustmentReply)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func resumeEvents(_ request: ConversationTurnRequest, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        guard unknownReply else { throw ConversationSessionError.unresolvedOperation }
        _ = try checkedOriginal(request)
        guard afterSequence == 0 else {
            violatedOriginalRequest = true
            throw ConversationSessionError.invalidEvent
        }
        // The real service then falls back to observe() inside the user's explicit reconcile action.
        throw ConversationSessionError.unresolvedOperation
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        guard unknownReply else { throw ConversationSessionError.unresolvedOperation }
        let original = try checkedOriginal(request)
        return ConversationObservation(request: original, events: try Self.completedEvents(original), serverState: "completed")
    }
    private func checkedOriginal(_ request: ConversationTurnRequest) throws -> ConversationTurnRequest {
        guard !violatedOriginalRequest, let original = originalRequest, let bytes = originalRequestBytes,
              request.scope == scope, request.scope == original.scope,
              request.conversationID == original.conversationID, request.operationID == original.operationID,
              request.epoch == original.epoch, try Self.encodedRequest(request) == bytes else {
            violatedOriginalRequest = true
            throw ConversationSessionError.invalidEvent
        }
        return original
    }
    private static func encodedRequest(_ request: ConversationTurnRequest) throws -> Data {
        // Codable intentionally excludes the ephemeral accountToken; the real controller checks that epoch separately.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }
    private static func completedEvents(_ request: ConversationTurnRequest, adjustment: Bool = false) throws -> [ConversationTurnEvent] {
        var body: [String: Any] = ["schema_version": 1, "contract": ParentingIntakeRequest.contract,
            "request_id": request.operationID.uuidString.lowercased(), "title": "Synthetic reading together",
            "due_at": NSNull(), "time_evidence": NSNull(), "clarification": "Choose an explicit time before saving."]
        if adjustment {
            body["due_at"] = "2027-02-18T17:00:00Z"
            body["time_evidence"] = "2027-02-18T17:00:00Z"
            body["clarification"] = NSNull()
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        let messageID = stableID("parenting-ui-answer:" + request.operationID.uuidString)
        return [.init(operationID: request.operationID, epoch: request.epoch, sequence: 1,
                      payload: .textDelta(messageID: messageID, text: text),
                      conversationID: request.conversationID, turnID: request.operationID),
                .init(operationID: request.operationID, epoch: request.epoch, sequence: 2,
                      payload: .completed(messageID: messageID, finalTextHash: textHash(text)),
                      conversationID: request.conversationID, turnID: request.operationID)]
    }
    func deleteIntake(scope: DataScope, conversationID: UUID) async throws {
        guard scope == self.scope else { throw catError.scopeMismatch }
        if failDeletionOnce {
            failDeletionOnce = false
            throw URLError(.networkConnectionLost)
        }
        grantedConversations.remove(conversationID)
        if originalRequest?.conversationID == conversationID {
            // The synthetic server holds raw prompt bytes only in memory until the real cleanup action arrives.
            originalRequest = nil; originalRequestBytes = nil
        }
    }
}
#endif
