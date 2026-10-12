import SwiftUI

// Test-only app entry, replacing the production entry in an ignored extracted copy.
// No NativeAuthApplicationModel, composition, credentials, HTTP, or Keychain startup.
actor QAHostBackend: ConversationBackend {
    func connection(scope:DataScope) async -> ConversationConnection { .init(state:.providerUnverified,provider:"synthetic offline QA",detail:"external_network_enabled=false") }
    func modelConsent(scope:DataScope,conversationID:UUID) async throws -> ConversationModelConsent? { try await Task.sleep(nanoseconds:60_000_000_000);return nil }
    func reply(_ r:ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent,Error> { throw CatpawError.invalid("QA host must not dispatch") }
    func observe(_ r:ConversationTurnRequest) async throws -> ConversationObservation { throw CatpawError.invalid("QA host has no remote turn") }
}
@MainActor @main struct QAHost: App {
    @StateObject var model: ConversationFirstModel
    init() {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("qa-host-"+UUID().uuidString)
        let repo=try! Repository(persistence:FilePersistence(url:dir.appendingPathComponent("synthetic.json")))
        _model=StateObject(wrappedValue:ConversationFirstModel(repository:repo,service:ConversationSessionService(repository:repo,backend:QAHostBackend())))
    }
    var body: some Scene { WindowGroup { ConversationFirstView(model:model).safeAreaInset(edge:.top) { Text("injected_synthetic_offline; external_network_enabled=false").font(.caption2).accessibilityIdentifier("qa.fixture") } } }
}
