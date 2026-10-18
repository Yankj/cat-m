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
    /// Live text (fix/context-window-v11x `text_preview`): `persistedText` is the authoritative text_delta sum (or the
    /// journal snapshot); `livePreview` is the latest live-only tail. `text` = merged display, never journaled.
    private var persistedText = ""
    private var livePreview: ConversationTextPreview?
    private var previewMessageID: UUID?
    private let liveOperationID: UUID?
    /// Server sends a preview at most every ~100 ms; coalesce bursts so the bubble re-renders at most this often.
    private let previewInterval: TimeInterval
    private var lastPreviewPublish = Date.distantPast
    private var previewFlush: Task<Void, Never>?

    init(service: ConversationSessionService? = nil, operationID: UUID? = nil,
         message: ConversationTranscriptMessage? = nil, turn: ConversationTurnRecord? = nil,
         startedAt: Date = .now, stepTitle: @escaping (String) -> String = { ToolStepCopy.title($0) }, clock: @escaping () -> Date = { .now },
         previewInterval: TimeInterval = 0.08) {
        thinkingStartedAt = startedAt; self.stepTitle = stepTitle; self.clock = clock
        self.previewInterval = previewInterval; liveOperationID = operationID ?? turn?.id
        statusThrottle = StatusLineThrottle(turnStart: clock())
        if let message, let turn { reconcile(message: message, turn: turn) }
        restoreLivePreview(message: message, turn: turn)
        if let service, let operationID { subscribe(to: service, operationID: operationID) }
    }

    deinit { streamTask?.cancel(); statusTick?.cancel(); previewFlush?.cancel() }

    // MARK: live text preview (merge with persisted text; dropped on every terminal state)
    /// A row rebuilt mid-turn (PendingThinkingRow → LivePhasedAnswerView at the first DB batch) keeps the live tail.
    private func restoreLivePreview(message: ConversationTranscriptMessage?, turn: ConversationTurnRecord?) {
        guard let liveOperationID, let cached = LiveTextPreviewCache.preview(for: liveOperationID) else { return }
        if let turn, ![.dispatched, .running].contains(turn.state) { LiveTextPreviewCache.drop(liveOperationID); return }
        if let message, message.id != cached.messageID { return }
        previewMessageID = cached.messageID; livePreview = cached; publishText()
    }
    private func applyPreview(_ preview: ConversationTextPreview) {
        switch phase { case .settled, .interrupted: return; case .thinking, .streaming: break }
        if let known = previewMessageID, known != preview.messageID { return }
        previewMessageID = preview.messageID; livePreview = preview
        if let liveOperationID { LiveTextPreviewCache.store(preview, for: liveOperationID) }
        let wait = previewInterval - clock().timeIntervalSince(lastPreviewPublish)
        if wait <= 0 { publishText(); return }
        guard previewFlush == nil else { return }   // latest preview wins at the trailing edge
        previewFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, wait) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.publishText()
        }
    }
    /// Recompute `text` from persisted + preview. Persisted text_delta always wins (the overlap is skipped).
    private func publishText() {
        previewFlush?.cancel(); previewFlush = nil
        let display = livePreview?.display(persisted: persistedText) ?? persistedText
        if livePreview != nil { lastPreviewPublish = clock() }
        guard display != text else { return }
        if livePreview != nil, display.utf16.count > persistedText.utf16.count {
            // First live text: same phase switch as the first text_delta; the answer itself is now the progress.
            enterStreaming()
            if let livePreview, statusReducer.target != nil { statusReducer.apply(.textPreview(livePreview)); pushStatus() }
        }
        text = display
    }
    private func setPersisted(_ value: String) { persistedText = value; publishText() }
    /// turn_completed (all text persisted) / turn_failed / cancel / stop: the unsaved tail is dropped.
    private func dropPreview() {
        previewFlush?.cancel(); previewFlush = nil
        if let liveOperationID { LiveTextPreviewCache.drop(liveOperationID) }
        livePreview = nil
        if text != persistedText { text = persistedText }
    }
    private func enterStreaming() {
        guard phase == .thinking else { return }
        thoughtSeconds = providerThinkingMs.map { max(0, Int(ceil(Double($0) / 1_000))) }
            ?? max(1, Int(clock().timeIntervalSince(thinkingStartedAt).rounded()))
        phase = .streaming
    }

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
        dropPreview()
        // Keep the stream: the server cancel arrives as failed(cancelled) or, if it raced, completed.
        phase = .interrupted(reason: "已停止接收此轮回复", reconciliationRequired: false)
        statusReducer.apply(.failed(message: "cancelled", reconciliationRequired: false)); pushStatus()
    }

    func reconcile(message: ConversationTranscriptMessage, turn: ConversationTurnRecord) {
        if stoppedLocally { return }
        if previewMessageID == nil { previewMessageID = message.id } else if previewMessageID != message.id { previewMessageID = message.id; dropPreview() }
        if ![.dispatched, .running].contains(turn.state) { dropPreview() }
        if needsResync { needsResync = false; setPersisted(message.content); snapshotInitialized = true }
        if turn.state == .failed, turn.error == "cancelled" { phase = .interrupted(reason: "已停止", reconciliationRequired: false); return }
        if !snapshotInitialized { setPersisted(message.content); snapshotInitialized = true }
        if lastSequence == 0 {
            if turn.state == .dispatched, message.content.isEmpty, statusReducer.target == nil { statusReducer.sending(); pushStatus() }
            if turn.state == .failed, turn.error == "rate_limited", message.content.isEmpty { statusReducer.busyRetry(); pushStatus() }
            if message.content.isEmpty { restoreStatus(turn: turn) }
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
            phase = message.content.isEmpty && text.isEmpty ? .thinking : .streaming   // text: live preview may lead the snapshot
        case .notSent, .cancelledBeforeSend:
            break
        }
    }

    /// P1-1: restore from the snapshot so a rebuilt row (cold start, session switch) is never empty. Later server events
    /// (sequence-deduped) take over. Also called by PendingThinkingRow, which has no message to reconcile.
    func restoreStatus(turn: ConversationTurnRecord) {
        guard !stoppedLocally, lastSequence == 0, turn.state == .running else { return }
        if let tool = Self.answerableTool(turn) {
            if statusReducer.target?.kind == .waiting { return }
            statusReducer.restoreAwaiting(tool: tool.isEmpty ? nil : tool)
        } else if statusReducer.target == nil { statusReducer.restoreAccepted() } else { return }
        pushStatus()
    }
    /// Tool of the first pending item that needs the user ("" = answerable with no tool), nil = nothing to answer.
    static func answerableTool(_ turn: ConversationTurnRecord) -> String? {
        guard turn.awaitingApproval else { return nil }
        if let a = turn.pendingApprovals?.first { return a.tool }
        if let d = turn.pendingDeviceCalls?.first(where: { !StatusLineReducer.autoRuns($0) }) { return d.tool }
        if !turn.pendingUIBlocks.isEmpty || !(turn.pendingUIApprovals ?? []).isEmpty { return "render_ui" }
        return nil
    }

    func apply(_ event: ConversationTurnEvent) {
        if stoppedLocally { return }
        // Live-only: sequence == last persisted event, so it is handled before the sequence dedupe and never moves it.
        if case let .textPreview(preview) = event.payload { applyPreview(preview); return }
        var fresh = false
        defer { if fresh { statusReducer.apply(event.payload); pushStatus() } }
        if case let .failed(message, _) = event.payload, message == "cancelled" {
            dropPreview()
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
            dropPreview(); previewMessageID = nil; persistedText = ""; text = ""
            phase = .thinking
        case let .toolStarted(callID, name, _):
            guard !steps.contains(where: { $0.id == callID }) else { return }
            let occurrence = steps.filter { $0.kind == name }.count
            steps.append(.init(id: callID, title: occurrence == 0 ? stepTitle(name) : ToolStepCopy.title(name, occurrence: occurrence), state: .running, startedAt: clock(), kind: name))
        case let .toolResult(result):
            if let i = steps.firstIndex(where: { $0.id == result.callID }) { steps[i].state = .done; steps[i].endedAt = clock() }
        case let .textDelta(id, delta):
            // One assistant message per turn: the persisted batch's message_id is authoritative for preview pinning.
            if previewMessageID != id { if let stale = livePreview, stale.messageID != id { livePreview = nil; if let liveOperationID { LiveTextPreviewCache.drop(liveOperationID) } }; previewMessageID = id }
            // Phase switch and first batch land in the same transaction (mapping §2 B) so there's no blank jump.
            enterStreaming()
            persistedText += delta; publishText()   // persisted batch wins; a live tail beyond it stays visible
        case .completed:
            dropPreview()
            if thoughtSeconds == nil { thoughtSeconds = max(0, Int(clock().timeIntervalSince(thinkingStartedAt).rounded())) }
            generationSeconds = max(0, clock().timeIntervalSince(thinkingStartedAt))
            phase = .settled
        case let .failed(message, reconciliation):
            dropPreview()   // previewed-only text was never saved
            phase = .interrupted(reason: message, reconciliationRequired: reconciliation)
        case let .reasoningSummary(_, text, thinkingMs):
            thinkingSummary = text
            applyThinkingDuration(thinkingMs)
        case .approvalRequested, .suspended, .approvalResolved, .uiBlock, .uiBlockUpdate, .uiBlockResolve, .deviceCall, .sideChannel, .textPreview:
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

    /// Visual SPEC §7/§8: working rows shimmer; waiting / failed / stopped are static and bypass the dwell.
    enum Kind: Equatable, Sendable { case working, waiting, failed, stopped }
    var kind: Kind {
        switch self {
        case .awaitingUser: return .waiting
        case .failed: return .failed
        case .stopped: return .stopped
        default: return .working
        }
    }
    var title: String { title(en: false) }
    func title(en: Bool) -> String {
        func t(_ zh: String, _ e: String) -> String { en ? e : zh }
        switch self {
        case .sending: return t("正在发送", "Sending")
        case .busyRetry: return t("有点忙，稍后自动重试", "Busy — retrying shortly")
        case .accepted(let n): return n % 2 == 0 ? t("Catpaw 正在工作", "Catpaw is working") : t("正在琢磨", "Thinking it over")
        case .recallingMemory: return t("正在回想相关记忆", "Recalling what you've told me")
        case .switchingModel: return t("换个模型再试", "Trying another model")
        case .tool(let name, let n): return ToolStepCopy.title(name, occurrence: n, en: en)
        case .awaitingUser(let tool): return ToolStepCopy.confirmTitle(tool, en: en)
        case .composing: return t("正在整理回答", "Putting the answer together")
        case .failed(let reason):
            if reason == Self.timeoutReason { return t("等太久了，可以重试", "Took too long — try again") }
            return t("没完成：", "Didn't finish: ") + reason
        case .stopped: return t("已停止", "Stopped")
        }
    }
    /// VoiceOver label (SPEC §11): waiting points at the card below.
    func accessibilityTitle(en: Bool) -> String {
        if case .awaitingUser = self { return title(en: en) + (en ? ". Card below." : "，确认卡片在下方") }
        return title(en: en)
    }
    /// SPEC §2 icon table. The icon never shimmers.
    var symbol: String {
        switch self {
        case .tool(let name, _): return ToolStepCopy.symbol(name)
        case .awaitingUser: return "arrow.down"
        case .recallingMemory: return "brain"
        case .switchingModel: return "arrow.triangle.2.circlepath"
        case .busyRetry: return "hourglass"
        case .composing: return "pencil"
        case .failed: return "exclamationmark.circle"
        case .stopped: return "stop.circle"
        case .sending, .accepted: return "sparkle"
        }
    }
    /// Visual SPEC v2 §2.1: kitten pose per state (imagesets StatusKitten<Pose>).
    enum KittenPose: String, Equatable, Sendable {
        case thinking = "Thinking", tool = "Tool", writing = "Writing", waiting = "Waiting", done = "Done", failed = "Failed", stopped = "Stopped"
        var asset: String { "StatusKitten" + rawValue }
    }
    enum BadgeTone: Equatable, Sendable { case neutral, waiting, failed, stopped }
    var pose: KittenPose {
        switch self {
        case .sending, .busyRetry, .accepted, .recallingMemory, .switchingModel: return .thinking
        case .tool(let name, _): return ToolStepCopy.writingTools.contains(name) ? .writing : .tool
        case .composing: return .writing
        case .awaitingUser: return .waiting
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }
    /// Badge glyph (nil = no badge) and tone, SPEC v2 §2.2–§2.3.
    var badge: (symbol: String, tone: BadgeTone)? {
        switch self {
        case .sending, .accepted, .recallingMemory: return nil
        case .switchingModel: return ("arrow.triangle.2.circlepath", .neutral)
        case .busyRetry: return ("hourglass", .neutral)
        case .tool(let name, _): return (ToolStepCopy.badgeSymbol(name), .neutral)
        case .composing: return ("pencil", .neutral)
        case .awaitingUser: return ("arrow.down", .waiting)
        case .failed: return ("exclamationmark", .failed)
        case .stopped: return ("stop.fill", .stopped)
        }
    }
    /// Announcement category (SPEC §11): announce only when this changes — not on variant swaps inside a category.
    var category: String {
        switch self {
        case .tool(let name, _): return "tool:" + ToolStepCopy.symbol(name)
        case .awaitingUser: return "waiting"
        case .failed: return "failed"
        case .stopped: return "stopped"
        default: return "working:" + symbol
        }
    }
    /// Shimmer only while Catpaw is actually working; waiting on the user, failures and stops are static.
    var animated: Bool { kind == .working }
    static let timeoutReason = "timeout"
    /// Plain, generic failure reasons only — never server messages, arguments or reasoning.
    static func failureReason(_ code: String) -> String {
        switch code {
        case "rate_limited", "chat_runtime_busy", "model_daily_limit", "daily_limit", "quota_exceeded", "model_quota_exceeded", "model_history_conflict": return "模型繁忙"
        case "timeout", "pending_timeout", "provider_timeout": return timeoutReason
        default: return AnswerFailureCopy.friendly(code)
        }
    }
}

/// Min-dwell + under-1s gate. Pure value type, driven by an injected clock (unit-tested).
/// - Nothing is visible until the turn is `hideUnder` old: turns that finish faster show no row at all.
/// - A displayed state stays at least `minDwell` (measured from when it became visible); newer targets wait, latest wins.
struct StatusLineThrottle: Equatable {
    static let minDwell: TimeInterval = 0.6
    static let hideUnder: TimeInterval = 0.6   // visual SPEC §6 appear delay (brainstorm said 1s)
    let turnStart: Date
    private(set) var current: StatusLinePhase?
    private(set) var currentSince: Date?
    private(set) var pending: StatusLinePhase?
    init(turnStart: Date) { self.turnStart = turnStart }

    private var visibleFrom: Date { turnStart.addingTimeInterval(Self.hideUnder) }
    /// What the row shows at `now` (nil = nothing).
    /// P1-2: static states (waiting / failed / stopped) bypass the appear gate too.
    func displayed(at now: Date) -> StatusLinePhase? { (current?.animated == false || now >= visibleFrom) ? current : nil }
    /// Submit a new target. Returns the delay after which `tick` must be called again (nil = nothing scheduled).
    mutating func submit(_ phase: StatusLinePhase, at now: Date) -> TimeInterval? {
        if current == nil || current == phase { if current == nil { current = phase; currentSince = now }; pending = nil; return untilVisible(now) }
        // SPEC §6: waiting / failed / stopped bypass the dwell — if the user has to act, don't make them wait.
        if !phase.animated { current = phase; currentSince = now; pending = nil; return untilVisible(now) }
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
    /// P1-3: nil = announce now; otherwise retry after the returned delay (the caller replays the then-current state).
    /// Attention states (waiting / failed / stopped) always go out immediately and still reset the window.
    mutating func request(attention: Bool, at now: Date) -> TimeInterval? {
        if attention { last = now; return nil }
        if let last, now.timeIntervalSince(last) < Self.interval { return Self.interval - now.timeIntervalSince(last) }
        last = now; return nil
    }
}

/// Maps the real event stream to status targets (pure; the projection feeds it and owns the throttle).
struct StatusLineReducer {
    private(set) var target: StatusLinePhase? = nil
    private var toolCounts: [String: Int] = [:]
    private var acceptedCount = 0
    private var composingCount = 0
    private var running: [(call: String, tool: String)] = []   // insertion order (PREREVIEW P2-1: deterministic title)
    /// Calls that really need an answer (card device calls, approvals, decision ui blocks). B1: `.suspended` only waits on these.
    private var answerable: Set<String> = []
    private var lastTool: String?
    private var awaiting = false

    mutating func sending() { target = .sending }
    /// P1-1: rebuilt projection (cold start, session switch, row rebuild) — restore the waiting state from the snapshot.
    mutating func restoreAwaiting(tool: String?) { awaiting = true; answerable.insert("restored"); target = .awaitingUser(tool: tool) }
    mutating func restoreAccepted() { if target == nil { target = .accepted(occurrence: acceptedCount); acceptedCount += 1 } }
    static func autoRuns(_ call: ConversationDeviceCall) -> Bool {
        call.confirm == "none" || DeviceToolContract.autoRunReadOnlyTools.contains(call.tool)
    }
    mutating func busyRetry() { target = .busyRetry }
    mutating func apply(_ payload: ConversationTurnEvent.Payload) {
        switch payload {
        case .started: running = []; answerable = []; awaiting = false; target = .accepted(occurrence: acceptedCount); acceptedCount += 1
        case .reasoningSummary:
            guard running.isEmpty, !awaiting else { break }
            switch target { case .accepted?, .composing?, .recallingMemory?, .switchingModel?: break; default: target = .accepted(occurrence: acceptedCount); acceptedCount += 1 }
        case .sideChannel(let type, let data):
            if type == "memory_recalled" || type == "memory.used" { if running.isEmpty && !awaiting { target = .recallingMemory } }
            if type == "model_route", let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], o["failover"] as? Bool == true { target = .switchingModel }
        case .toolStarted(let call, let name, _):
            running.removeAll { $0.call == call }; running.append((call, name)); lastTool = name
            let n = toolCounts[name, default: 0]; toolCounts[name] = n + 1
            if !awaiting { target = .tool(name: name, occurrence: n) }
        case .deviceCall(let call):
            lastTool = call.tool
            if Self.autoRuns(call) {
                // B1: read-only device tools run without a card — show the tool's working copy, never 「等你确认」.
                if !awaiting { target = .tool(name: call.tool, occurrence: max(0, toolCounts[call.tool, default: 1] - 1)) }
                break
            }
            answerable.insert(call.callID); awaiting = true; target = .awaitingUser(tool: call.tool)
        case .approvalRequested(let request):
            answerable.insert(request.callID); lastTool = request.tool
            awaiting = true; target = .awaitingUser(tool: request.tool)
        case .suspended:
            // B1: the server suspends for every interrupt, including confirm:"none" device calls. Wait only when
            // something answerable is actually pending this turn.
            if !answerable.isEmpty { awaiting = true; if target?.kind != .waiting { target = .awaitingUser(tool: lastTool) } }
        case .uiBlock(let ui):
            if ui.waitsForDecision { answerable.insert("ui:" + ui.id); awaiting = true; target = .awaitingUser(tool: "render_ui") }
        case .approvalResolved, .uiBlockResolve:
            awaiting = false; answerable = []
            if let tool = running.last?.tool { target = .tool(name: tool, occurrence: max(0, toolCounts[tool, default: 1] - 1)) } else { target = .composing(occurrence: composingCount); composingCount += 1 }
        case .toolResult(let result):
            running.removeAll { $0.call == result.callID }
            if running.isEmpty && !awaiting { target = .composing(occurrence: composingCount); composingCount += 1 }
        case .textDelta, .textPreview: target = nil         // the answer itself is now the progress
        case .completed: target = nil
        case .failed(let message, _): target = message == "cancelled" ? .stopped : .failed(reason: StatusLinePhase.failureReason(message))
        default: break
        }
    }
}

/// Latest live `text_preview` per turn, shared by the projections of one turn (the pending row and the answer row that
/// replaces it at the first persisted batch) so the bubble never shrinks back to the persisted text. Memory only, bound to
/// the signed-in account: cleared on sign-out / account switch (AccountChangeObservers) and whenever the account epoch moves.
@MainActor enum LiveTextPreviewCache {
    private static var latest: [UUID: ConversationTextPreview] = [:]
    private static var order: [UUID] = []
    private static var epoch: UInt64?
    private static var observing = false
    /// Injectable for tests; production reads the shared account barrier.
    static var currentEpoch: () -> UInt64 = { AccountEpoch.shared.epoch }
    static var count: Int { latest.count }
    private static func checkEpoch() {
        let now = currentEpoch()
        if epoch != now { removeAll(); epoch = now }
    }
    static func preview(for operationID: UUID) -> ConversationTextPreview? { checkEpoch(); return latest[operationID] }
    static func store(_ preview: ConversationTextPreview, for operationID: UUID) {
        checkEpoch()
        if !observing { observing = true; AccountChangeObservers.register("liveTextPreview") { _, _ in LiveTextPreviewCache.removeAll() } }
        if latest.updateValue(preview, forKey: operationID) == nil {
            order.append(operationID)
            if order.count > 8 { latest.removeValue(forKey: order.removeFirst()) }
        }
    }
    static func drop(_ operationID: UUID) {
        guard latest.removeValue(forKey: operationID) != nil else { return }
        order.removeAll { $0 == operationID }
    }
    static func removeAll() { latest.removeAll(); order.removeAll() }
}
