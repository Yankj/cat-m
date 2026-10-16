import Foundation

/// R7 answer phases (conversation-states-r7.json `answerPhases`).
/// A: thinking (one line + ≤3 tool rows) → B: streaming (chip + full-width body)
/// → C: settled (sources + actions). `.interrupted` keeps the visible text and is driven by 三角's connection layer.
enum AnswerPhase: Equatable, Sendable {
    case thinking
    case streaming
    case settled
    case interrupted(reason: String, reconciliationRequired: Bool)
}

struct AnswerToolStep: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case running, done }
    let id: String          // ConversationTurnEvent callID
    var title: String       // display name, already localised by the projection
    var state: State
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    /// Raw tool name, used only to pick the step glyph (search / browse / generic).
    var kind: String = ""
}

struct AnswerSource: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var host: String
    var url: URL?
}

/// Thin seam for 三角's session/stream layer. Views only read this; they never start, retry or resend.
@MainActor protocol AnswerPhaseProviding: ObservableObject {
    var phase: AnswerPhase { get }
    /// Provider thought summary if the route supports it; nil → the row shows the latest tool step instead.
    var thinkingSummary: String? { get }
    var steps: [AnswerToolStep] { get }
    var thinkingStartedAt: Date { get }
    /// Frozen when the first textDelta arrives.
    var thoughtSeconds: Int? { get }
    var text: String { get }
    var sources: [AnswerSource] { get }
    /// Wall time from request to `.completed`, for the trailing "15.66s" in the action row.
    var generationSeconds: Double? { get }
}

extension AnswerPhaseProviding { var generationSeconds: Double? { nil } }

/// Default pure projection from the existing `ConversationTurnEvent` contract.
/// Owns no I/O; 三角's stream pump calls `apply` in sequence order (dedupe by `sequence` happens upstream,
/// but `apply` also ignores sequences ≤ the last applied one so a resumed GET cannot double-append).
@MainActor final class AnswerPhaseProjection: AnswerPhaseProviding {
    @Published private(set) var phase: AnswerPhase = .thinking
    @Published var thinkingSummary: String?
    @Published private(set) var steps: [AnswerToolStep] = []
    @Published private(set) var thinkingStartedAt: Date
    @Published private(set) var thoughtSeconds: Int?
    @Published private(set) var text = ""
    @Published var sources: [AnswerSource] = []
    @Published private(set) var generationSeconds: Double?
    private var lastSequence = 0
    private var streamTask: Task<Void, Never>?
    private var stopObserver: NSObjectProtocol?
    private var stoppedLocally = false
    static let stopNotification = Notification.Name("CatpawAnswerStoppedLocally")
    static let resumeNotification = Notification.Name("CatpawAnswerStopRaced")
    private var resumeObserver: NSObjectProtocol?
    private var needsResync = false
    private var providerThinkingMs: Int?
    private var snapshotInitialized = false
    private let stepTitle: (String) -> String
    private let clock: () -> Date

    init(service: ConversationSessionService? = nil, operationID: UUID? = nil,
         message: ConversationTranscriptMessage? = nil, turn: ConversationTurnRecord? = nil,
         startedAt: Date = .now, stepTitle: @escaping (String) -> String = { $0 }, clock: @escaping () -> Date = { .now }) {
        thinkingStartedAt = startedAt; self.stepTitle = stepTitle; self.clock = clock
        if let message, let turn { reconcile(message: message, turn: turn) }
        if let service, let operationID { subscribe(to: service, operationID: operationID) }
    }

    deinit { streamTask?.cancel() }

    /// The live stream is authoritative for phase transitions and tool progress.
    /// The persisted snapshot only restores display state when a row is recreated.
    func subscribe(to service: ConversationSessionService, operationID: UUID) {
        streamTask?.cancel()
        if stopObserver == nil {
            stopObserver = NotificationCenter.default.addObserver(forName: Self.stopNotification, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?["operationIDs"] as? Set<UUID>)?.contains(operationID) == true else { return }
                MainActor.assumeIsolated { self?.markStopped() }
            }
            resumeObserver = NotificationCenter.default.addObserver(forName: Self.resumeNotification, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?["operationID"] as? UUID) == operationID else { return }
                MainActor.assumeIsolated { self?.stoppedLocally = false; self?.snapshotInitialized = false; self?.needsResync = true }
            }
        }
        streamTask = Task { [weak self] in
            let events = await service.turnEvents()
            for await event in events where event.operationID == operationID {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    /// User tapped stop: local observation ends; server work is not cancelled (see stopObserving).
    func markStopped() {
        guard !stoppedLocally else { return }
        stoppedLocally = true
        // Keep the stream: the server cancel arrives as failed(cancelled) or, if it raced, completed.
        phase = .interrupted(reason: "已停止接收此轮回复", reconciliationRequired: false)
    }

    func reconcile(message: ConversationTranscriptMessage, turn: ConversationTurnRecord) {
        if stoppedLocally { return }
        if needsResync { needsResync = false; text = message.content; snapshotInitialized = true }
        if turn.state == .failed, turn.error == "cancelled" { phase = .interrupted(reason: "已停止", reconciliationRequired: false); return }
        if !snapshotInitialized { text = message.content; snapshotInitialized = true }
        if let summary = turn.reasoningSummary { thinkingSummary = summary }
        applyThinkingDuration(turn.thinkingMs)
        switch turn.state {
        case .completed:
            phase = .settled
        case .failed:
            phase = .interrupted(reason: turn.error ?? "此轮回复未完成", reconciliationRequired: false)
        case .unknown:
            phase = .interrupted(reason: turn.error ?? "原请求状态待确认", reconciliationRequired: true)
        case .dispatched, .running:
            phase = message.content.isEmpty ? .thinking : .streaming
        case .notSent, .cancelledBeforeSend:
            break
        }
    }

    func apply(_ event: ConversationTurnEvent) {
        if stoppedLocally { return }
        if case let .failed(message, _) = event.payload, message == "cancelled" {
            phase = .interrupted(reason: "已停止", reconciliationRequired: false); return
        }
        guard event.sequence > lastSequence else { return }
        lastSequence = event.sequence
        switch event.payload {
        case .thread:
            break
        case .started:
            thinkingStartedAt = clock()
            providerThinkingMs = nil
            thoughtSeconds = nil
            thinkingSummary = nil
            steps = []
            text = ""
            phase = .thinking
        case let .toolStarted(callID, name, _):
            guard !steps.contains(where: { $0.id == callID }) else { return }
            steps.append(.init(id: callID, title: stepTitle(name), state: .running, startedAt: clock(), kind: name))
        case let .toolResult(result):
            if let i = steps.firstIndex(where: { $0.id == result.callID }) { steps[i].state = .done; steps[i].endedAt = clock() }
        case let .textDelta(_, delta):
            // Phase switch and first batch land in the same transaction (mapping §2 B) so there's no blank jump.
            if phase == .thinking {
                thoughtSeconds = providerThinkingMs.map { max(0, Int(ceil(Double($0) / 1_000))) }
                    ?? max(1, Int(clock().timeIntervalSince(thinkingStartedAt).rounded()))
                phase = .streaming
            }
            text += delta
        case .completed:
            if thoughtSeconds == nil { thoughtSeconds = max(0, Int(clock().timeIntervalSince(thinkingStartedAt).rounded())) }
            generationSeconds = max(0, clock().timeIntervalSince(thinkingStartedAt))
            phase = .settled
        case let .failed(message, reconciliation):
            phase = .interrupted(reason: message, reconciliationRequired: reconciliation)
        case let .reasoningSummary(_, text, thinkingMs):
            thinkingSummary = text
            applyThinkingDuration(thinkingMs)
        case .approvalRequested, .suspended, .approvalResolved, .uiBlock, .uiBlockUpdate, .uiBlockResolve, .deviceCall, .sideChannel:
            break // catpaw.approval.v1 / catpaw.ui.v1: presentation is owned by the UI lane (A2, generative UI renderer).
        }
    }

    private func applyThinkingDuration(_ milliseconds: Int?) {
        guard let milliseconds else { return }
        providerThinkingMs = milliseconds
        let seconds = Double(milliseconds) / 1_000
        thinkingStartedAt = clock().addingTimeInterval(-seconds)
        thoughtSeconds = max(0, Int(ceil(seconds)))
    }

    /// Visible rows while thinking: running first, newest last, max 3.
    var visibleThinkingSteps: [AnswerToolStep] { Array(steps.suffix(3)) }
}
