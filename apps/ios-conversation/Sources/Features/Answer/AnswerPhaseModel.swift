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
}

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
    private var lastSequence = 0
    private let stepTitle: (String) -> String
    private let clock: () -> Date

    init(startedAt: Date = .now, stepTitle: @escaping (String) -> String = { $0 }, clock: @escaping () -> Date = { .now }) {
        thinkingStartedAt = startedAt; self.stepTitle = stepTitle; self.clock = clock
    }

    func apply(_ event: ConversationTurnEvent) {
        guard event.sequence > lastSequence else { return }
        lastSequence = event.sequence
        switch event.payload {
        case .thread, .started:
            break
        case let .toolStarted(callID, name, _):
            guard !steps.contains(where: { $0.id == callID }) else { return }
            steps.append(.init(id: callID, title: stepTitle(name), state: .running))
        case let .toolResult(result):
            if let i = steps.firstIndex(where: { $0.id == result.callID }) { steps[i].state = .done }
        case let .textDelta(_, delta):
            // Phase switch and first batch land in the same transaction (mapping §2 B) so there's no blank jump.
            if phase == .thinking {
                thoughtSeconds = max(1, Int(clock().timeIntervalSince(thinkingStartedAt).rounded()))
                phase = .streaming
            }
            text += delta
        case .completed:
            if thoughtSeconds == nil { thoughtSeconds = max(0, Int(clock().timeIntervalSince(thinkingStartedAt).rounded())) }
            phase = .settled
        case let .failed(message, reconciliation):
            phase = .interrupted(reason: message, reconciliationRequired: reconciliation)
        }
    }

    /// Visible rows while thinking: running first, newest last, max 3.
    var visibleThinkingSteps: [AnswerToolStep] { Array(steps.suffix(3)) }
}
