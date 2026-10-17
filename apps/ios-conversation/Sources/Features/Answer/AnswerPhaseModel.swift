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
    /// status-line v1.0 (requirements so generic views dispatch to the projection, defaults below).
    var statusLine: StatusLinePhase? { get }
    var usesStatusLine: Bool { get }
}

extension AnswerPhaseProviding {
    var generationSeconds: Double? { nil }
    /// status-line v1.0: nil while hidden (first 1 s of a turn, or between states). Only used when `usesStatusLine`.
    var statusLine: StatusLinePhase? { nil }
    var usesStatusLine: Bool { false }
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
    /// status-line v1.0 (min dwell 600 ms, nothing under 1 s, real events only).
    @Published private(set) var statusLine: StatusLinePhase?
    var usesStatusLine: Bool { true }
    private var statusReducer = StatusLineReducer()
    private var statusThrottle: StatusLineThrottle
    private var statusTick: Task<Void, Never>?

    init(service: ConversationSessionService? = nil, operationID: UUID? = nil,
         message: ConversationTranscriptMessage? = nil, turn: ConversationTurnRecord? = nil,
         startedAt: Date = .now, stepTitle: @escaping (String) -> String = { ToolStepCopy.title($0) }, clock: @escaping () -> Date = { .now }) {
        thinkingStartedAt = startedAt; self.stepTitle = stepTitle; self.clock = clock
        statusThrottle = StatusLineThrottle(turnStart: clock())
        if let message, let turn { reconcile(message: message, turn: turn) }
        if let service, let operationID { subscribe(to: service, operationID: operationID) }
    }

    deinit { streamTask?.cancel(); statusTick?.cancel() }

    // MARK: status line plumbing
    private func pushStatus() {
        let now = clock()
        guard let target = statusReducer.target else { statusTick?.cancel(); statusLine = nil; statusThrottle = StatusLineThrottle(turnStart: statusThrottle.turnStart); return }
        schedule(statusThrottle.submit(target, at: now))
        statusLine = statusThrottle.displayed(at: now)
    }
    private func schedule(_ delay: TimeInterval?) {
        statusTick?.cancel()
        guard let delay else { return }
        statusTick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let now = self.clock()
            self.schedule(self.statusThrottle.tick(at: now))
            self.statusLine = self.statusThrottle.displayed(at: now)
        }
    }

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
        statusReducer.apply(.failed(message: "cancelled", reconciliationRequired: false)); pushStatus()
    }

    func reconcile(message: ConversationTranscriptMessage, turn: ConversationTurnRecord) {
        if stoppedLocally { return }
        if needsResync { needsResync = false; text = message.content; snapshotInitialized = true }
        if turn.state == .failed, turn.error == "cancelled" { phase = .interrupted(reason: "已停止", reconciliationRequired: false); return }
        if !snapshotInitialized { text = message.content; snapshotInitialized = true }
        if lastSequence == 0 {
            if turn.state == .dispatched, message.content.isEmpty, statusReducer.target == nil { statusReducer.sending(); pushStatus() }
            if turn.state == .failed, turn.error == "rate_limited", message.content.isEmpty { statusReducer.busyRetry(); pushStatus() }
        }
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
        var fresh = false
        defer { if fresh { statusReducer.apply(event.payload); pushStatus() } }
        if case let .failed(message, _) = event.payload, message == "cancelled" {
            fresh = true; phase = .interrupted(reason: "已停止", reconciliationRequired: false); return
        }
        guard event.sequence > lastSequence else { return }
        lastSequence = event.sequence; fresh = true
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
            let occurrence = steps.filter { $0.kind == name }.count
            steps.append(.init(id: callID, title: occurrence == 0 ? stepTitle(name) : ToolStepCopy.title(name, occurrence: occurrence), state: .running, startedAt: clock(), kind: name))
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

// MARK: - status-line v1.0: real-event driven status row (harness-brainstorm §4.5 / §4.6)

/// One displayed state of the status row. Every case comes from a real local or server event — no fake progress.
enum StatusLinePhase: Equatable, Sendable {
    case sending                         // POST out, no turn_started yet
    case busyRetry                       // server busy / rate_limited, automatic retry pending
    case accepted(occurrence: Int)       // turn_started (or reasoning) with no tool running — the only playful slot
    case recallingMemory                 // memory_recalled / memory.used side channel
    case switchingModel                  // model_route.failover == true
    case tool(name: String, occurrence: Int)
    case awaitingUser(tool: String?)     // confirmation card / device call / suspended — static, no shimmer
    case composing(occurrence: Int)      // after the last tool_result, before the first text_delta
    case failed(reason: String)
    case stopped

    var title: String {
        switch self {
        case .sending: return "正在发送"
        case .busyRetry: return "有点忙，稍后自动重试"
        case .accepted(let n): return n % 2 == 0 ? "Catpaw 正在工作" : "正在琢磨"
        case .recallingMemory: return "正在回想相关记忆"
        case .switchingModel: return "换个模型再试"
        case .tool(let name, let n): return ToolStepCopy.title(name, occurrence: n)
        case .awaitingUser(let tool): return ToolStepCopy.confirmTitle(tool)
        case .composing(let n): return n % 2 == 0 ? "正在整理汇总" : "正在完成"
        case .failed(let reason): return "没完成：" + reason
        case .stopped: return "已停止"
        }
    }
    var symbol: String {
        switch self {
        case .tool(let name, _): return ToolStepCopy.symbol(name)
        case .awaitingUser: return "hand.tap"
        case .recallingMemory: return "brain"
        case .switchingModel: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.circle"
        case .stopped: return "stop.circle"
        default: return "sparkle"
        }
    }
    /// Shimmer only while Catpaw is actually working; waiting on the user, failures and stops are static.
    var animated: Bool {
        switch self {
        case .awaitingUser, .failed, .stopped: return false
        default: return true
        }
    }
    /// Plain, generic failure reasons only — never server messages, arguments or reasoning.
    static func failureReason(_ code: String) -> String {
        switch code {
        case "rate_limited", "chat_runtime_busy", "model_daily_limit", "daily_limit", "quota_exceeded", "model_quota_exceeded": return "模型繁忙"
        case "timeout", "pending_timeout": return "等太久了，可以重试"
        default: return "可以重试"
        }
    }
}

/// Min-dwell + under-1s gate. Pure value type, driven by an injected clock (unit-tested).
/// - Nothing is visible until the turn is `hideUnder` old: turns that finish faster show no row at all.
/// - A displayed state stays at least `minDwell` (measured from when it became visible); newer targets wait, latest wins.
struct StatusLineThrottle: Equatable {
    static let minDwell: TimeInterval = 0.6
    static let hideUnder: TimeInterval = 1.0
    let turnStart: Date
    private(set) var current: StatusLinePhase?
    private(set) var currentSince: Date?
    private(set) var pending: StatusLinePhase?
    init(turnStart: Date) { self.turnStart = turnStart }

    private var visibleFrom: Date { turnStart.addingTimeInterval(Self.hideUnder) }
    /// What the row shows at `now` (nil = nothing).
    func displayed(at now: Date) -> StatusLinePhase? { now >= visibleFrom ? current : nil }
    /// Submit a new target. Returns the delay after which `tick` must be called again (nil = nothing scheduled).
    mutating func submit(_ phase: StatusLinePhase, at now: Date) -> TimeInterval? {
        if current == nil || current == phase { if current == nil { current = phase; currentSince = now }; pending = nil; return untilVisible(now) }
        pending = phase
        return tick(at: now)
    }
    /// Promote the pending target once the current one has been visible for `minDwell`.
    mutating func tick(at now: Date) -> TimeInterval? {
        guard let next = pending else { return untilVisible(now) }
        let shownFrom = max(currentSince ?? now, visibleFrom)
        let wait = shownFrom.addingTimeInterval(Self.minDwell).timeIntervalSince(now)
        if now < visibleFrom || wait <= 0 {
            // Before the row is visible nothing has been seen yet, so the latest state simply replaces it.
            current = next; currentSince = now; pending = nil
            return untilVisible(now)
        }
        return wait
    }
    private func untilVisible(_ now: Date) -> TimeInterval? { now < visibleFrom ? visibleFrom.timeIntervalSince(now) : nil }
}

/// VoiceOver announcements at most once every 2 s.
struct StatusLineAnnouncementThrottle {
    static let interval: TimeInterval = 2
    private(set) var last: Date?
    mutating func allow(at now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) < Self.interval { return false }
        last = now; return true
    }
}

/// Maps the real event stream to status targets (pure; the projection feeds it and owns the throttle).
struct StatusLineReducer {
    private(set) var target: StatusLinePhase? = nil
    private var toolCounts: [String: Int] = [:]
    private var acceptedCount = 0
    private var composingCount = 0
    private var running: [String: String] = [:]     // callID → tool
    private var lastTool: String?
    private var awaiting = false

    mutating func sending() { target = .sending }
    mutating func busyRetry() { target = .busyRetry }
    mutating func apply(_ payload: ConversationTurnEvent.Payload) {
        switch payload {
        case .started: running = [:]; awaiting = false; target = .accepted(occurrence: acceptedCount); acceptedCount += 1
        case .reasoningSummary:
            guard running.isEmpty, !awaiting else { break }
            switch target { case .accepted?, .composing?, .recallingMemory?, .switchingModel?: break; default: target = .accepted(occurrence: acceptedCount); acceptedCount += 1 }
        case .sideChannel(let type, let data):
            if type == "memory_recalled" || type == "memory.used" { if running.isEmpty && !awaiting { target = .recallingMemory } }
            if type == "model_route", let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], o["failover"] as? Bool == true { target = .switchingModel }
        case .toolStarted(let call, let name, _):
            running[call] = name; lastTool = name
            let n = toolCounts[name, default: 0]; toolCounts[name] = n + 1
            if !awaiting { target = .tool(name: name, occurrence: n) }
        case .deviceCall(let call):
            lastTool = call.tool
            if call.confirm == "none" || DeviceToolContract.autoRunReadOnlyTools.contains(call.tool) { break }
            awaiting = true; target = .awaitingUser(tool: call.tool)
        case .approvalRequested, .suspended:
            awaiting = true; target = .awaitingUser(tool: lastTool)
        case .uiBlock(let ui):
            if ui.waitsForDecision { awaiting = true; target = .awaitingUser(tool: "render_ui") }
        case .approvalResolved, .uiBlockResolve:
            awaiting = false
            if let tool = running.values.first { target = .tool(name: tool, occurrence: max(0, toolCounts[tool, default: 1] - 1)) } else { target = .composing(occurrence: composingCount); composingCount += 1 }
        case .toolResult(let result):
            running[result.callID] = nil
            if running.isEmpty && !awaiting { target = .composing(occurrence: composingCount); composingCount += 1 }
        case .textDelta: target = nil                       // the answer itself is now the progress
        case .completed: target = nil
        case .failed(let message, _): target = message == "cancelled" ? .stopped : .failed(reason: StatusLinePhase.failureReason(message))
        default: break
        }
    }
}
