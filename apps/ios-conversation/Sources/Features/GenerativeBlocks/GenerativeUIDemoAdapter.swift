#if DEBUG
import SwiftUI

/// DEBUG: drives `GenerativeBlockStore` from the scripted demo backend (`CatpawDemoConversationBackend.shared.ui`,
/// docs/demo-fixture-backend.md, enabled with `-CatpawDemoBackend`). Decisions go through the same
/// `GenerativeUIDecisionSubmitting` seam the HTTP backend will implement; returned events feed back into the store.
final class GenerativeUIDemoSubmitter: GenerativeUIDecisionSubmitting, @unchecked Sendable {
    static let conversationID = UUID(uuidString: "00000000-0000-4000-8000-0000000000d1")!
    static let turnID = UUID(uuidString: "00000000-0000-4000-8000-0000000000d2")!
    private let script: CatpawDemoUIScript
    private weak var store: GenerativeBlockStore?
    init(script: CatpawDemoUIScript = CatpawDemoConversationBackend.shared.ui, store: GenerativeBlockStore) { self.script = script; self.store = store }

    func submitUIDecision(conversationID: UUID, turnID: UUID, interruptID: String, decision: GenerativeUIDecision, argsHash: String, response: Data?, operationID: UUID) async throws {
        guard let blockID = await MainActor.run(body: { store?.blocks.values.first { $0.interruptId == interruptID }?.id }) else { throw ConversationApprovalFailure.notFound }
        let mapped: CatpawDemoUIDecision = switch decision { case .submit: .submit; case .dismiss: .dismiss; case .reportError: .reportError }
        let events: [CatpawDemoUIEvent]
        do { events = try await script.respond(blockID: blockID, decision: mapped, responseJSON: response.map { String(decoding: $0, as: UTF8.self) }, operationID: operationID) }
        catch let failure as CatpawDemoUIFailure {
            switch failure {
            case .notFound: throw ConversationApprovalFailure.notFound
            case .consumed: throw ConversationApprovalFailure.consumed
            case .conflict: throw ConversationApprovalFailure.rejected(status: 409, code: "approval_operation_conflict")
            case .invalidResponse: throw ConversationApprovalFailure.rejected(status: 422, code: "ui_response_invalid")
            }
        }
        await MainActor.run { if let store { Self.apply(events, to: store) } }
    }

    /// Route demo/wire events into the store (same mapping the turn event path should use).
    @MainActor static func apply(_ events: [CatpawDemoUIEvent], to store: GenerativeBlockStore) {
        let context = GenerativeBlockStore.Context(conversationID: conversationID, turnID: turnID)
        for event in events {
            let data = Data(event.json.utf8)
            switch event.type {
            case "ui.block": store.receive(data, context: context)
            case "ui.block.update": store.update(data)
            case "ui.block.resolve": store.resolve(data)
            default: break
            }
        }
    }

    @MainActor static func start(_ store: GenerativeBlockStore) async {
        let submitter = GenerativeUIDemoSubmitter(store: store)
        store.submitter = submitter
        apply(await submitter.script.start(), to: store)
    }
}

/// DEBUG screen: the full demo session (card, list, progress, choices → update, form, confirm, sheet).
@MainActor struct GenerativeUIDemoView: View {
    @StateObject private var store = GenerativeBlockStore(defaults: nil)
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(store.order, id: \.self) { id in
                    if let block = store.blocks[id] { GenerativeBlockView(block: block, store: store) }
                }
            }.padding(20)
        }
        .task { if store.order.isEmpty { await GenerativeUIDemoSubmitter.start(store) } }
        .accessibilityIdentifier("chat.block.demo")
    }
}

#Preview("catpaw.ui.v1 demo backend") { GenerativeUIDemoView() }
#endif
