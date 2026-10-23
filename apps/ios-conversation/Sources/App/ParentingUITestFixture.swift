#if DEBUG
import Foundation
import SwiftUI

/// Opt-in, in-process UI acceptance only. It cannot select an HTTP/Auth/model adapter.
/// A recognized request remains on the fixture error surface even when its UUID is invalid.
enum ParentingUITestFixture {
    static let successScenario = "p0-ui-parenting-success"
    static let failureScenario = "p0-ui-parenting-preparation-failure"
    static var isRequested: Bool {
        [successScenario, failureScenario].contains(ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] ?? "")
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
        let repository = try Repository(persistence: SwiftDataPersistence(url: root.appendingPathComponent("local.store")))
        let boundary = ParentingUITestBackend(scope: scope,
            failPreparationOnce: ProcessInfo.processInfo.environment["CF_UI_TEST_SCENARIO"] == failureScenario)
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
    private let routeHash = textHash("parenting-native-ui-synthetic-only")
    init(scope: DataScope, failPreparationOnce: Bool) {
        self.scope = scope
        self.failPreparationOnce = failPreparationOnce
        self.failDeletionOnce = failPreparationOnce
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
        guard request.scope == scope, grantedConversations.contains(request.conversationID) else {
            throw ConversationDispatchFailure.notSent(reason: "Synthetic UI consent has not been allowed")
        }
        let body: [String: Any] = ["schema_version": 1, "contract": ParentingIntakeRequest.contract,
            "request_id": request.operationID.uuidString.lowercased(), "title": "Synthetic reading together",
            "due_at": NSNull(), "time_evidence": NSNull(), "clarification": "Choose an explicit time before saving."]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        let messageID = stableID("parenting-ui-answer:" + request.operationID.uuidString)
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 1,
                payload: .textDelta(messageID: messageID, text: text)))
            continuation.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 2,
                payload: .completed(messageID: messageID, finalTextHash: textHash(text))))
            continuation.finish()
        }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        // These journeys never recover remote work. Refuse readback rather than inventing server evidence.
        throw ConversationSessionError.unresolvedOperation
    }
    func deleteIntake(scope: DataScope, conversationID: UUID) async throws {
        guard scope == self.scope else { throw catError.scopeMismatch }
        if failDeletionOnce {
            failDeletionOnce = false
            throw URLError(.networkConnectionLost)
        }
        grantedConversations.remove(conversationID)
    }
}
#endif
