import Foundation
import SwiftUI
import os

/// Local state for catpaw.ui.v1 blocks: latest block per id (display blocks may be patched by `ui.block.update`),
/// server resolution (`ui.block.resolve`), the user's answer, and submission state. Persisted so cold start restores
/// answered/expired cards. Interactive blocks answer through `GenerativeUIDecisionSubmitting` on the SAME turn.
@MainActor final class GenerativeBlockStore: ObservableObject {
    /// `.queued`: the service holds the decision until the running reply ends (FIFO, a6f9c18).
    enum Submission: Equatable { case idle, submitting, queued, failed(String) }
    /// Whether the service is holding this decision in its queue (installed by the chat host).
    var queueProbe: (@MainActor (_ conversationID: UUID, _ interruptID: String) async -> Bool)?
    /// Cancels a queued decision in the service (its submit task then throws CancellationError).
    var queueCanceller: (@MainActor (_ conversationID: UUID, _ interruptID: String) async -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    struct Context: Codable, Equatable { let conversationID: UUID; let turnID: UUID }

    static let shared = GenerativeBlockStore()
    @Published private(set) var blocks: [String: GenerativeBlock] = [:]
    @Published private(set) var order: [String] = []
    @Published private(set) var responses: [String: GenerativeBlockResponse] = [:]
    /// Locked blocks with their final status (submitted, dismissed, errored, expired, cancelled, or local "answered").
    @Published private(set) var resolved: [String: String] = [:]
    @Published private(set) var submissions: [String: Submission] = [:]
    var submitter: (any GenerativeUIDecisionSubmitting)?
    /// Display-only blocks (no interrupt): local answers go here, if anyone listens (e.g. a follow-up message).
    var localResponder: (@MainActor (GenerativeBlockResponse) -> Void)?
    private var contexts: [String: Context] = [:]
    /// One decision operation id per interrupt, reused on retry (idempotent per contract §5).
    private var operationIDs: [String: UUID] = [:]
    private var reported: Set<String> = []
    /// "turnID#sequence" of wire events already applied (not persisted: replays re-apply idempotently).
    private var applied: Set<String> = []
    private let defaults: UserDefaults?
    private let baseKey = "catpaw.generativeBlocks.v3"
    /// Conversation whose blocks are loaded; blocks / responses / resolution are stored per conversation + block id.
    private(set) var conversationID: UUID?
    private var key: String { baseKey + "." + (conversationID?.uuidString.lowercased() ?? "local") }
    private let log = Logger(subsystem: "catpaw", category: "generative-ui")

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        load()
    }

    /// Switches the store to one conversation's blocks (saved under their own key). Idempotent.
    func activate(conversationID id: UUID?) {
        guard id != conversationID else { return }
        save()
        conversationID = id
        blocks = [:]; order = []; responses = [:]; resolved = [:]; submissions = [:]; contexts = [:]; operationIDs = [:]; reported = []; applied = []
        load()
    }
    /// L2 (encrypted, per user) is the store of record for the shared instance; tests that inject their own
    /// UserDefaults keep using it. Without a signed-in L2 store, blocks stay in memory only.
    private var usesL2: Bool { defaults === UserDefaults.standard }
    /// Re-reads the active conversation after the L2 store changes user (called from CatpawApp).
    func reloadFromL2() {
        blocks = [:]; order = []; responses = [:]; resolved = [:]; contexts = [:]; operationIDs = [:]
        load()
    }
    private func readSnapshotData() -> Data? {
        guard usesL2 else { return defaults?.data(forKey: key) }
        guard let l2 = L2SecureStore.current else { return nil }
        if let data = l2.data(forKey: key) { return data }
        // One-time migration of the plaintext v3 key into L2, then the legacy copy is removed.
        guard let legacy = defaults?.data(forKey: key) else { return nil }
        l2.set(legacy, forKey: key); defaults?.removeObject(forKey: key)
        return legacy
    }
    private func load() {
        if let data = readSnapshotData(), let saved = try? GenerativeBlockCodec.decoder.decode(Snapshot.self, from: data) {
            blocks = saved.blocks; order = saved.order; responses = saved.responses; resolved = saved.resolved; contexts = saved.contexts; operationIDs = saved.operationIDs
        }
    }

    // MARK: Events (call from the turn event path once the network layer exposes ui.* cases)

    /// `ui.block`. `context` is required for interactive blocks to be answerable.
    func receive(_ data: Data, context: Context?) {
        switch GenerativeBlockCodec.decode(data) {
        case .ready(let block): adopt(block, error: nil, context: context)
        case .fallback(let card, let error): adopt(card, error: error, context: context)
        }
    }
    /// Record a decoded block (also from onAppear for markdown fences). Invalid interactive blocks are reported once
    /// as `report_error`; invalid display blocks are only logged (nothing is waiting, contract §0.3).
    func adopt(_ block: GenerativeBlock, error: GenerativeBlockError?, context: Context? = nil) {
        if let context { contexts[block.id] = context }
        if blocks[block.id] == nil { blocks[block.id] = block; order.append(block.id) }
        if let error, reported.insert(block.id).inserted {
            if error.interruptId != nil { submit(block.id, decision: .reportError, response: try? GenerativeBlockCodec.encoder.encode(error), local: nil) }
            else { log.error("ui block \(block.id, privacy: .public) invalid: \(error.code, privacy: .public) at \(error.path ?? "-", privacy: .public)") }
        }
        save()
    }
    /// `ui.block.update`: display blocks only (interactive blocks are frozen by argsHash).
    func update(_ patch: GenerativeBlockPatch) {
        guard let b = blocks[patch.id], !b.needsAnswer else { return }
        blocks[patch.id] = b.applying(patch); save()
    }
    func update(_ data: Data) { if let patch = try? GenerativeBlockCodec.decoder.decode(GenerativeBlockPatch.self, from: data) { update(patch) } }
    /// `ui.block.resolve`: the server closed the block.
    func resolve(_ resolution: GenerativeBlockResolution) { resolved[resolution.id] = resolution.status; submissions[resolution.id] = nil; save() }
    func resolve(_ data: Data) { if let r = try? GenerativeBlockCodec.decoder.decode(GenerativeBlockResolution.self, from: data) { resolve(r) } }

    // MARK: catpaw.ui.v1 wire events (ConversationTurnEvent .uiBlock / .uiBlockUpdate / .uiBlockResolve, journal, pendingUIApprovals)

    /// Applies one wire event once (de-duplicated by turn + sequence, so the live stream, the turn journal and
    /// `pendingUIApprovals` can all feed the store safely).
    func ingest(_ event: ConversationUIEvent, context: Context) {
        guard conversationID == nil || conversationID == context.conversationID else { return }   // replayed from the journal on activate
        let key = context.turnID.uuidString + "#" + String(event.sequence)
        guard applied.insert(key).inserted else { return }
        switch event.type {
        case .block: receive(event.payload, context: context)
        case .update: update(event.payload)
        case .resolve:
            if let status = event.status { resolve(GenerativeBlockResolution(id: event.id, status: status)) } else { resolve(event.payload) }
        }
    }
    /// Cold start: a waiting ui interrupt from `pendingUIApprovals` (`block` is the full `ui.block` data). A block already
    /// present from the journal is not added twice (`adopt` keys by block id).
    func restore(_ approval: ConversationUIApproval, context: Context) {
        guard conversationID == nil || conversationID == context.conversationID, resolved[approval.blockID] == nil else { return }
        receive(approval.block, context: context)
    }
    /// Blocks received for one conversation, in arrival order.
    func blockIDs(conversationID: UUID) -> [String] { order.filter { contexts[$0]?.conversationID == conversationID } }
    func turnID(of id: String) -> UUID? { contexts[id]?.turnID }

    // MARK: User actions

    func current(_ block: GenerativeBlock) -> GenerativeBlock { blocks[block.id] ?? block }
    func isLocked(_ id: String) -> Bool { resolved[id] != nil }

    func respond(_ response: GenerativeBlockResponse) {
        guard !isLocked(response.blockId) else { return }
        let block = blocks[response.blockId]
        if block?.interruptId != nil {
            submit(response.blockId, decision: .submit, response: try? GenerativeBlockCodec.encoder.encode(response), local: response)
        } else {
            // Local-only (markdown fence / display block): editable until the next turn locks it.
            responses[response.blockId] = response; save(); localResponder?(response)
        }
    }
    func dismiss(_ id: String) { submit(id, decision: .dismiss, response: nil, local: nil) }
    /// Expired blocks lock locally (the server resolves them lazily as `expired`).
    func markExpired(_ id: String) { guard !isLocked(id), blocks[id]?.needsAnswer == true else { return }; resolved[id] = "expired"; submissions[id] = nil; save() }
    /// "可点按修改直到下一 turn" for local-only answers.
    func lockLocalAnswers(_ ids: [String]) { for id in ids where responses[id] != nil && resolved[id] == nil { resolved[id] = "answered" }; save() }
    func reopen(_ id: String) { guard !isLocked(id), blocks[id]?.interruptId == nil else { return }; responses[id] = nil; save() }

    private func submit(_ id: String, decision: GenerativeUIDecision, response: Data?, local: GenerativeBlockResponse?) {
        guard let block = blocks[id], let interrupt = block.interruptId, let hash = block.argsHash, !isLocked(id), submissions[id] != .submitting, submissions[id] != .queued else { return }
        guard let submitter, let context = contexts[id] else { submissions[id] = .failed("暂时无法提交，请稍后重试。"); return }
        let operation = operationIDs[interrupt] ?? UUID(); operationIDs[interrupt] = operation; save()
        submissions[id] = .submitting
        let owner = conversationID
        // Shortly after starting, ask whether the service queued it behind the running reply.
        if let probe = queueProbe {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.submissions[id] == .submitting, owner == self.conversationID else { return }
                if await probe(context.conversationID, interrupt), self.submissions[id] == .submitting { self.submissions[id] = .queued }
            }
        }
        tasks[id]?.cancel()
        tasks[id] = Task {
            defer { tasks[id] = nil }
            defer { if owner == conversationID { save() } }
            do {
                try await submitter.submitUIDecision(conversationID: context.conversationID, turnID: context.turnID, interruptID: interrupt,
                                                     decision: decision, argsHash: hash, response: response, operationID: operation)
                guard owner == conversationID else { return }   // user switched conversation meanwhile
                if let local { responses[id] = local }
                resolved[id] = resolved[id] ?? (decision == .submit ? "submitted" : decision == .dismiss ? "dismissed" : "errored")
                submissions[id] = nil
            } catch let failure as ConversationApprovalFailure {
                guard owner == conversationID else { return }
                switch failure {
                case .transport: submissions[id] = .failed(failure.friendlyMessage)   // same operationID on retry
                case .expired: resolved[id] = "expired"; submissions[id] = nil
                case .consumed, .noPendingApproval: resolved[id] = resolved[id] ?? "submitted"; submissions[id] = nil
                case .notFound: resolved[id] = "cancelled"; submissions[id] = nil
                case .stale: resolved[id] = "errored"; submissions[id] = .failed(failure.friendlyMessage)
                case .unsupported: submissions[id] = .failed(failure.friendlyMessage)
                case .rejected(_, let code):
                    if code == "approval_operation_conflict" { operationIDs[interrupt] = nil }
                    submissions[id] = .failed(failure.friendlyMessage)
                }
            } catch is CancellationError {
                // Cancelled while queued (user tapped 取消 or the turn moved on): back to answerable, quietly.
                if owner == conversationID { submissions[id] = nil }
            } catch {
                guard owner == conversationID else { return }
                submissions[id] = .failed(ConversationApprovalFailure.transport.friendlyMessage)
            }
        }
    }

    /// Withdraws a decision still waiting in the service queue.
    func cancelQueued(_ id: String) {
        guard submissions[id] == .queued, let interrupt = blocks[id]?.interruptId, let context = contexts[id] else { return }
        let canceller = queueCanceller
        Task { [weak self] in
            await canceller?(context.conversationID, interrupt)
            self?.tasks[id]?.cancel()
        }
    }

    private struct Snapshot: Codable {
        var blocks: [String: GenerativeBlock]; var order: [String]; var responses: [String: GenerativeBlockResponse]
        var resolved: [String: String]; var contexts: [String: Context]; var operationIDs: [String: UUID]
    }
    private func save() {
        guard let data = try? GenerativeBlockCodec.encoder.encode(Snapshot(blocks: blocks, order: order, responses: responses, resolved: resolved, contexts: contexts, operationIDs: operationIDs)) else { return }
        if usesL2 { L2SecureStore.current?.set(data, forKey: key) } else { defaults?.set(data, forKey: key) }
    }
}

/// Plug-in adapter for the markdown renderer registry (feat/ios-markdown-render, `MarkdownCustomBlockRegistry`)
/// (#34, now in integration-v2). `registerWithMarkdown()` is called from `CatpawMApp.init`; `register(into:)` stays
/// generic so other hosts can plug the same builders in.
///
/// Fence blocks have no interrupt: they render and answer locally (display semantics).
@MainActor enum GenerativeBlockAdapter {
    typealias Builder = @MainActor (Data, Bool) -> AnyView
    /// Grounded kinds (place/event) are server-filled from tool results only; a model-written fence never renders them.
    static var kinds: [String] { GenerativeBlock.Kind.allCases.filter { !$0.isGrounded }.map(\.rawValue) }

    private static var registered = false
    /// Registers every kind with the markdown renderer (`MarkdownCustomBlockRegistry`, #34). Idempotent.
    static func registerWithMarkdown(store: GenerativeBlockStore = .shared) {
        guard !registered else { return }; registered = true
        register(store: store) { kind, build in MarkdownCustomBlockRegistry.shared.register(kind: kind) { payload, closed in build(payload, closed) } }
    }
    static func register(store: GenerativeBlockStore = .shared, into register: (_ kind: String, _ build: @escaping Builder) -> Void) {
        for kind in kinds { register(kind) { payload, closed in view(payload: payload, closed: closed, store: store) } }
    }
    /// While the fence is still streaming the JSON is incomplete: show a quiet placeholder, never raw JSON.
    static func view(payload: Data, closed: Bool, store: GenerativeBlockStore = .shared) -> AnyView {
        guard closed else { return AnyView(GenerativeBlockPlaceholder()) }
        switch GenerativeBlockCodec.decode(payload) {
        case .ready(let block): return AnyView(GenerativeBlockView(block: block, store: store))
        case .fallback(let card, let error): return AnyView(GenerativeBlockView(block: card, store: store, validationError: error))
        }
    }
}
