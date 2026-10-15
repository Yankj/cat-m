import SwiftUI

/// `GenerativeUIDecisionSubmitting` over 三角's service API (4454bee). The service resumes the SAME turn's SSE
/// stream after the decision; the resulting `ui.*` / approval events reach the store through the turn event path.
struct ConversationServiceUIDecisionSubmitter: GenerativeUIDecisionSubmitting {
    let service: ConversationSessionService
    let scope: DataScope

    func submitUIDecision(conversationID: UUID, turnID: UUID, interruptID: String, decision: GenerativeUIDecision, argsHash: String, response: Data?, operationID: UUID) async throws {
        try await service.submitUIDecision(scope: scope, conversationID: conversationID, turnID: turnID, interruptID: interruptID,
                                           decision: decision, argsHash: argsHash, response: response, operationID: operationID)
    }
}

/// Hook rendered once below the transcript (next to `ConversationApprovalHost`): feeds catpaw.ui.v1 events into
/// `GenerativeBlockStore` from three idempotent sources (live turn events, the turn journal in `session`, and
/// `pendingUIBlocks` on cold start) and renders this conversation's blocks.
@MainActor struct ConversationGenerativeUIHost: View {
    @ObservedObject var model: ConversationFirstModel
    let session: ConversationSession
    @ObservedObject private var store = GenerativeBlockStore.shared
    @StateObject private var feed = ConversationGenerativeUIFeed()

    private var ids: [String] { store.blockIDs(conversationID: session.conversationID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ids, id: \.self) { id in
                if let block = store.blocks[id] {
                    GenerativeBlockView(block: block, store: store)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .padding(.top, ids.isEmpty ? 0 : 12)
        .animation(.smooth(duration: 0.35), value: ids)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.generativeUI")
        .onAppear { feed.attach(model: model, store: store, session: session) }
        .onChange(of: session.conversationID) { _, _ in feed.attach(model: model, store: store, session: session) }
        .onChange(of: session.turns.last?.id) { _, _ in feed.turnChanged(store: store, session: session) }
        .onChange(of: session.turns.last?.uiEvents?.count) { _, _ in feed.ingestJournal(store: store, session: session) }
    }
}

@MainActor final class ConversationGenerativeUIFeed: ObservableObject {
    private var listener: Task<Void, Never>?
    private var conversationID: UUID?
    private var lastTurnID: UUID?
    /// Turns of the attached conversation; live events of other conversations are left to their journal.
    private var knownTurns: Set<UUID> = []

    func attach(model: ConversationFirstModel, store: GenerativeBlockStore, session: ConversationSession) {
        store.submitter = ConversationServiceUIDecisionSubmitter(service: model.service, scope: model.scope)
        let conversation = session.conversationID
        if conversationID != conversation { conversationID = conversation; lastTurnID = session.turns.last?.id }
        ingestJournal(store: store, session: session)
        // Cold start: the waiting blocks of the turn that is still suspended (journal-backed in the service).
        let service = model.service, scope = model.scope
        let turnID = session.turns.last(where: { $0.awaitingApproval })?.id
        Task { [weak store] in
            guard let turnID, let events = try? await service.pendingUIBlocks(scope: scope, conversationID: conversation) else { return }
            for event in events { store?.ingest(event, context: .init(conversationID: conversation, turnID: turnID)) }
        }
        guard listener == nil else { return }
        listener = Task { [weak self, weak store] in
            let events = await service.turnEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self, let store, let conversation = self.conversationID, self.knownTurns.contains(event.operationID) else { continue }
                let ui: ConversationUIEvent
                switch event.payload {
                case .uiBlock(let e), .uiBlockUpdate(let e), .uiBlockResolve(let e): ui = e
                default: continue
                }
                // `operationID` is the turn id on the turn event stream (same as ConversationApprovalController).
                store.ingest(ui, context: .init(conversationID: conversation, turnID: event.operationID))
            }
        }
    }

    /// Replays the journaled `uiEvents` of every turn (cheap: de-duplicated by turn + sequence).
    func ingestJournal(store: GenerativeBlockStore, session: ConversationSession) {
        knownTurns = Set(session.turns.map(\.id))
        for turn in session.turns {
            for event in turn.uiEvents ?? [] {
                store.ingest(event, context: .init(conversationID: session.conversationID, turnID: turn.id))
            }
        }
    }

    /// A new turn started: local-only answers of earlier turns become read-only (r10 §4.2 "可点按修改直到下一 turn").
    func turnChanged(store: GenerativeBlockStore, session: ConversationSession) {
        guard let current = session.turns.last?.id, current != lastTurnID else { return }
        lastTurnID = current
        let earlier = store.blockIDs(conversationID: session.conversationID).filter { store.turnID(of: $0) != current }
        store.lockLocalAnswers(earlier)
        ingestJournal(store: store, session: session)
    }

    deinit { listener?.cancel() }
}
