import SwiftUI

/// 三角's scope-bound adapter (ConversationSessionService.swift, 9303a82) is the only decision submitter; it is installed
/// by `NativeAuthApplicationModel.installUIDecisionSubmitter`. `GenerativeUIDecision` is a typealias of
/// `ConversationUIDecision`, so the adapter's existing `submitUIDecision(...decision: ConversationUIDecision...)` already
/// is the protocol requirement (the rawValue-mapping body from 三角's comment would redeclare the same method).
extension ConversationUIDecisionSubmitter: GenerativeUIDecisionSubmitting {}

/// Per-turn hook in the transcript: after the turn's last message row (assistant reply + its action row; r10 §4.2
/// "与正文间距 12"), the turn's approval card (latest turn only, as before) and then its catpaw.ui.v1 blocks.
@MainActor struct ConversationTurnUIRow: View {
    @ObservedObject var model: ConversationFirstModel
    let session: ConversationSession
    let turnID: UUID
    @ObservedObject private var store = GenerativeBlockStore.shared

    /// turnID → id of that turn's last message row.
    static func tails(_ rows: [(UUID, UUID?)]) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for (id, turnID) in rows { if let turn = turnID { out[turn] = id } }
        return out
    }
    private var ids: [String] { store.blockIDs(conversationID: session.conversationID).filter { store.turnID(of: $0) == turnID } }
    private var isLatest: Bool { session.turns.last?.id == turnID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLatest { ConversationApprovalHost(model: model, session: session) }
            MemoryUsedChips(turnID: turnID) // M6: 本次用到的记忆 (memory.used)
            ForEach(ids, id: \.self) { id in
                if let block = store.blocks[id] {
                    GenerativeBlockView(block: block, store: store).transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .padding(.top, ids.isEmpty && !isLatest ? 0 : 12)
        .animation(.smooth(duration: 0.35), value: ids)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.turn.ui." + turnID.uuidString)
    }
}

/// Feed + fallback hook rendered once below the transcript (next to `ConversationApprovalHost`): feeds catpaw.ui.v1 events into
/// `GenerativeBlockStore` from three idempotent sources (live turn events, the turn journal in `session`, and
/// `pendingUIApprovals` on cold start) and renders this conversation's blocks.
@MainActor struct ConversationGenerativeUIHost: View {
    @ObservedObject var model: ConversationFirstModel
    let session: ConversationSession
    /// Turns that render their own blocks inline (`ConversationTurnUIRow`); only the rest render here.
    var inlineTurns: Set<UUID> = []
    @ObservedObject private var store = GenerativeBlockStore.shared
    @StateObject private var feed = ConversationGenerativeUIFeed()

    private var ids: [String] {
        store.blockIDs(conversationID: session.conversationID).filter { id in store.turnID(of: id).map { !inlineTurns.contains($0) } ?? true }
    }

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
        // Blocks are stored per conversation (demo interrupt ids and block ids repeat across conversations).
        let conversation = session.conversationID
        store.activate(conversationID: conversation)
        if conversationID != conversation { conversationID = conversation; lastTurnID = session.turns.last?.id }
        ingestJournal(store: store, session: session)
        // Cold start: the waiting ui interrupts of the suspended turn (snapshot pending_approvals kind "ui", else journal).
        let service = model.service, scope = model.scope
        store.queueProbe = { conversationID, interruptID in await service.queuedUIDecisions(conversationID: conversationID).contains(interruptID.lowercased()) }
        store.queueCanceller = { conversationID, interruptID in _ = await service.cancelQueuedUIDecision(conversationID: conversationID, interruptID: interruptID) }
        let turnID = session.turns.last(where: { $0.awaitingApproval })?.id
        Task { [weak store] in
            guard let turnID, let approvals = try? await service.pendingUIApprovals(scope: scope, conversationID: conversation) else { return }
            for approval in approvals { store?.restore(approval, context: .init(conversationID: conversation, turnID: turnID)) }
        }
        guard listener == nil else { return }
        listener = Task { [weak self, weak store] in
            let events = await service.turnEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self, let store, let conversation = self.conversationID else { continue }
                let ui: ConversationUIEvent
                switch event.payload {
                case .uiBlock(let e), .uiBlockUpdate(let e), .uiBlockResolve(let e): ui = e
                default: continue
                }
                // a6f9c18: events carry conversationID / turnID (turnID == operationID). Events of a turn not seen yet
                // are accepted when the conversation matches; older backends without the ids fall back to known turns.
                let turn = event.turnID ?? event.operationID
                if let owner = event.conversationID { guard owner == conversation else { continue } }
                else { guard self.knownTurns.contains(turn) else { continue } }
                store.ingest(ui, context: .init(conversationID: conversation, turnID: turn))
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
