import Foundation

// Wave 2 · V3 device tools (plan §3.1): `device_call` → confirm card → execute on device → `device_result`.
// Execution belongs to the Mac worker's DeviceToolRouter (M1); reporting the result belongs to 三角's network layer
// (B3/B6, `POST /device-result`). Both sit behind protocols here with stubs so the card works in Previews and demo.

/// `{"type":"device_call","call_id":"…","tool":"calendar_create","args":{},"confirm":"card","ttl_sec":600}`
struct DeviceCall: Codable, Sendable, Equatable, Identifiable {
    enum Confirm: String, Codable, Sendable { case card, none }
    let call_id: String
    let tool: String
    var args: [String: DeviceCallValue]
    var confirm: Confirm?
    var ttl_sec: Int?
    /// catpaw.device.v1 (#49 / services/edge/docs/device-call-contract.md).
    var interrupt_id: String?
    var args_hash: String?
    /// ISO 8601; wins over `ttl_sec` when present.
    var expires_at: String?
    var id: String { call_id }
    /// Absolute deadline: `expires_at`, else `ttl_sec` counted from when the card was first seen.
    func deadline(firstSeen: Date) -> Date? {
        if let raw = expires_at, let date = DeviceCallDates.parse(raw) { return date }
        if let ttl = ttl_sec, ttl > 0 { return firstSeen.addingTimeInterval(TimeInterval(ttl)) }
        return nil
    }
}

/// JSON scalar subset the card can show and edit; arrays are shown joined (to[] for mail / sms).
indirect enum DeviceCallValue: Codable, Sendable, Equatable {
    /// `list` = all-string arrays (editable, e.g. to[]); `array` = any other array (e.g. calendar_create.alarms [-15, -60]).
    case string(String), number(Double), bool(Bool), list([String]), array([DeviceCallValue]), object([String: DeviceCallValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([String].self) { self = .list(a) }
        else if let a = try? c.decode([DeviceCallValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: DeviceCallValue].self) { self = .object(o) }
        else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .list(let a): try c.encode(a)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
    var text: String {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): b ? "✓" : "—"
        case .list(let a): a.joined(separator: "、")
        case .array(let a): a.map(\.text).joined(separator: "、")
        case .object(let o): o.keys.sorted().map { "\($0): \(o[$0]!.text)" }.joined(separator: "，")
        case .null: ""
        }
    }
}

enum DeviceCallStatus: String, Codable, Sendable, CaseIterable { case ok, cancelled, denied, error }

/// `{call_id, status, data}` for `POST /device-result`.
struct DeviceCallResult: Codable, Sendable, Equatable {
    let call_id: String
    let status: DeviceCallStatus
    var data: [String: DeviceCallValue]?
    /// Optional deep link for the receipt row's 打开 (e.g. `calshow:`), filled in by the executor. Local only: opened on the
    /// device, never sent to the server (excluded from `CodingKeys`).
    var openURL: String? = nil
    private enum CodingKeys: String, CodingKey { case call_id, status, data }
}

/// M1 (Mac worker): runs the tool with EventKit / MFMessage / MFMail / tel / MapKit / URL schemes, including the
/// system permission prompt and the system compose sheets (cancel there → `.cancelled`).
@MainActor protocol DeviceToolExecuting: AnyObject {
    func canExecute(_ tool: String) -> Bool
    func execute(_ call: DeviceCall) async -> DeviceCallResult
}

/// 三角 (B6 DeviceResultClient): delivers the result to the cloud agent for the same turn.
@MainActor protocol DeviceResultSubmitting {   // not class-bound: 三角's ConversationDeviceResultSubmitter is a struct
    func submit(_ result: DeviceCallResult) async throws
    /// Chat-UX #6: report a receipt undo to the turn.
    func reportUndo(callID: String, outcome: DeviceUndoOutcome) async throws
}
extension DeviceResultSubmitting { func reportUndo(callID: String, outcome: DeviceUndoOutcome) async throws {} }

@MainActor final class DeviceToolExecutorStub: DeviceToolExecuting {
    var outcome: DeviceCallStatus = .ok
    func canExecute(_ tool: String) -> Bool { true }
    func execute(_ call: DeviceCall) async -> DeviceCallResult {
        try? await Task.sleep(for: .milliseconds(400))
        return .init(call_id: call.call_id, status: outcome, data: nil, openURL: nil)
    }
}

@MainActor final class DeviceResultSubmitterStub: DeviceResultSubmitting {
    private(set) var sent: [DeviceCallResult] = []
    func submit(_ result: DeviceCallResult) async throws { sent.append(result) }
    private(set) var undos: [(String, DeviceUndoOutcome)] = []
    func reportUndo(callID: String, outcome: DeviceUndoOutcome) async throws { undos.append((callID, outcome)) }
}

/// Injection points: M1 sets `executor`, 三角's installer sets `submitter` (and clears both at sign-out).
@MainActor enum DeviceCallHub {
    static var executor: any DeviceToolExecuting = DeviceToolExecutorStub()
    static var submitter: (any DeviceResultSubmitting)? = DeviceResultSubmitterStub()
    /// Local ledger hook (DeviceLedger.shared.record in the app; nil in tests).
    static var recorder: ((DeviceCall, DeviceCallResult) -> Void)?
}

/// Card state per call_id, kept across transcript re-renders AND app kills (NoBug P0-3).
/// Order in `run`: persist `.running` + the effective call → execute → persist the result as `.reportFailed` (executed,
/// not yet acknowledged) → report → persist `.done`. On relaunch a call still `.running` is "interrupted":
/// idempotent tools (executor dedupes by call_id marker) are re-run, others report `interrupted_outcome_unknown`.
/// A call stuck in `.reportFailed` re-reports the saved result (the server is idempotent per operation_id).
@MainActor final class DeviceCallStore: ObservableObject {
    static let shared = DeviceCallStore()
    enum Phase: Equatable, Codable { case confirming, running, done(DeviceCallResult), reportFailed(DeviceCallResult), expired }
    struct Record: Codable, Equatable { var phase: Phase; var call: DeviceCall?; var updatedAt: Date }
    @Published private(set) var phases: [String: Phase] = [:]
    @Published var edited: [String: [String: DeviceCallValue]] = [:]
    private var seen: [String: Date] = [:]
    private var records: [String: Record] = [:]
    private var interrupted: Set<String> = []
    private let defaults: UserDefaults
    static let storageKey = "catpaw.devicecall.records.v1"
    static let retention: TimeInterval = 7 * 24 * 3600

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved.filter { now.timeIntervalSince($0.value.updatedAt) < Self.retention }
        }
        for (id, r) in records {
            phases[id] = r.phase
            if r.phase == .running { interrupted.insert(id) }
        }
    }

    func phase(_ id: String) -> Phase { phases[id] ?? .confirming }
    func firstSeen(_ id: String) -> Date { if let d = seen[id] { return d }; let now = Date(); seen[id] = now; return now }
    func set(_ id: String, _ p: Phase) { phases[id] = p; persist(id, p, call: nil) }
    func isInterrupted(_ id: String) -> Bool { interrupted.contains(id) }
    func record(_ id: String) -> Record? { records[id] }
    func reset() { phases = [:]; edited = [:]; seen = [:]; records = [:]; interrupted = []; defaults.removeObject(forKey: Self.storageKey); undoQueue = .init(); defaults.removeObject(forKey: Self.undoKey) }

    private func persist(_ id: String, _ p: Phase, call: DeviceCall?) {
        records[id] = .init(phase: p, call: call ?? records[id]?.call, updatedAt: .now)
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
    }

    func run(_ call: DeviceCall) async {
        guard phase(call.id) == .confirming else { return }
        // Codex P0-1: refuse anything not registered by a typed event for this account and still valid. Not executed and
        // not reported (an unknown call_id has no turn to report into); the card shows it as not done.
        if let why = DeviceCallGate.check(call) { set(call.id, .done(DeviceCallGate.rejected(call, why))); return }
        var effective = call
        if let edits = edited[call.id] { effective.args.merge(edits) { _, new in new } }
        phases[call.id] = .running; persist(call.id, .running, call: effective)   // durable BEFORE any side effect
        await execute(effective)
    }
    /// Relaunch path for a call that was `.running` when the app died.
    func resumeInterrupted(_ id: String) async {
        guard interrupted.remove(id) != nil, let call = records[id]?.call else { return }
        if DeviceToolContract.idempotentTools.contains(call.tool) { await execute(call) }
        else { await finish(call, DeviceToolContract.interruptedUnknown(call)) }
    }
    private func execute(_ call: DeviceCall) async {
        let executor = DeviceCallHub.executor
        let result = executor.canExecute(call.tool) ? await executor.execute(call) : DeviceToolContract.unsupported(call)
        await finish(call, result)
    }
    private func finish(_ call: DeviceCall, _ result: DeviceCallResult) async {
        set(call.id, .reportFailed(result))   // executed, not yet acknowledged — survives a kill before report
        DeviceCallHub.recorder?(call, result)
        await report(result, submitter: DeviceCallHub.submitter)
    }
    func cancel(_ call: DeviceCall) async {
        let submitter = DeviceCallHub.submitter
        guard phase(call.id) == .confirming else { return }
        await report(.init(call_id: call.call_id, status: .cancelled), submitter: submitter)
    }
    /// Calls whose result was executed but never acknowledged (persisted `.reportFailed`).
    var pendingReportIDs: [String] { phases.compactMap { if case .reportFailed = $0.value { $0.key } else { nil } }.sorted() }
    private var retrying: Set<String> = []
    /// NoBug P1-4: re-send every unacknowledged result (on relaunch once the submitter is installed, and on foreground).
    /// Never re-executes; the server is idempotent per operation_id. Returns how many were acknowledged.
    @discardableResult func retryPendingReports() async -> Int {
        guard DeviceCallHub.submitter != nil else { return 0 }
        await retryUndoReports()
        var ok = 0
        for id in pendingReportIDs where !retrying.contains(id) {
            retrying.insert(id); await retryReport(id); retrying.remove(id)
            if case .done = phase(id) { ok += 1 }
        }
        return ok
    }
    // Chat-UX #6: undo reports are queued durably first, so a failure (offline, app restart, unknown turn) retries later.
    static let undoKey = "catpaw.devicecall.undos.v1"
    private(set) lazy var undoQueue: DeviceUndoQueue = defaults.data(forKey: Self.undoKey).flatMap { try? JSONDecoder().decode(DeviceUndoQueue.self, from: $0) } ?? .init()
    private func saveUndoQueue() { if let data = try? JSONEncoder().encode(undoQueue) { defaults.set(data, forKey: Self.undoKey) } }
    func reportUndo(callID: String, outcome: DeviceUndoOutcome) async {
        undoQueue.enqueue(callID, outcome); saveUndoQueue()
        await retryUndoReports()
    }
    private var drainingUndos = false
    func retryUndoReports() async {
        guard !drainingUndos, !undoQueue.isEmpty, let submitter = DeviceCallHub.submitter else { return }
        drainingUndos = true; defer { drainingUndos = false }
        for (id, outcome) in undoQueue.pending.sorted(by: { $0.key < $1.key }) {
            do { try await submitter.reportUndo(callID: id, outcome: outcome); if undoQueue.pending[id] == outcome { undoQueue.acknowledge(id) } } catch {}
        }
        saveUndoQueue()
    }
    func retryReport(_ id: String) async {
        let submitter = DeviceCallHub.submitter
        guard case .reportFailed(let result) = phase(id) else { return }
        await report(result, submitter: submitter)
    }
    private func report(_ result: DeviceCallResult, submitter: (any DeviceResultSubmitting)?) async {
        do { try await submitter?.submit(result); set(result.call_id, submitter == nil ? .reportFailed(result) : .done(result)) }
        catch { set(result.call_id, .reportFailed(result)) }
    }
}

/// Codex review P0-1: only calls that arrived as an authenticated, typed `device_call` SSE event (registered here by
/// `ConversationApprovalHost`) may execute, for the account that received them and before they expire. Display content
/// (Markdown fences, quoted / historical replies) can never register a call, so it has zero side effects.
@MainActor enum DeviceCallGate {
    struct Grant: Equatable { let account: String?; let deadline: Date? }
    enum Rejection: String, Equatable { case unregistered = "unauthorized_call", accountMismatch = "account_mismatch", expired = "call_expired" }
    /// Signed-in user id (set by NativeAuthApplicationModel); nil when signed out / guest.
    static var currentAccount: () -> String? = { nil }
    private static var grants: [String: Grant] = [:]
    static func register(_ call: DeviceCall, now: Date = .now) {
        grants[call.call_id] = .init(account: currentAccount(), deadline: call.deadline(firstSeen: now))
    }
    static func check(_ call: DeviceCall, now: Date = .now) -> Rejection? {
        guard let grant = grants[call.call_id] else { return .unregistered }
        guard grant.account == currentAccount() else { return .accountMismatch }
        if let deadline = grant.deadline, now > deadline { return .expired }
        return nil
    }
    static func rejected(_ call: DeviceCall, _ why: Rejection) -> DeviceCallResult {
        .init(call_id: call.call_id, status: .error, data: ["reason": .string(why.rawValue), "retryable": .bool(false)])
    }
    static func reset() { grants = [:] }
}
