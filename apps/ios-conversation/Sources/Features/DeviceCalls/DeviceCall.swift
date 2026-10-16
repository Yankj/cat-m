import CryptoKit
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
        if let raw = expires_at { return DeviceCallDates.parse(raw) ?? .distantPast }   // unparsable → already expired (fail closed)
        if let ttl = ttl_sec, ttl > 0 { return firstSeen.addingTimeInterval(TimeInterval(ttl)) }
        return nil
    }
    /// Codex PR #89 P2: absolute deadline for a grant. Unparsable `expires_at` → nil (refused); when both are present the
    /// EARLIER of expires_at and receivedAt+ttl wins; neither → nil (refused).
    func strictDeadline(receivedAt: Date) -> Date? {
        let ttl = ttl_sec.flatMap { $0 > 0 ? receivedAt.addingTimeInterval(TimeInterval($0)) : nil }
        if let raw = expires_at {
            guard let abs = DeviceCallDates.parse(raw) else { return nil }
            return ttl.map { min($0, abs) } ?? abs
        }
        return ttl
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
    /// Restart recovery: find the original effect by call_id WITHOUT writing (nil = not found / unknown).
    func lookup(_ call: DeviceCall) async -> DeviceCallResult?
}
extension DeviceToolExecuting { func lookup(_ call: DeviceCall) async -> DeviceCallResult? { nil } }

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
    struct Record: Codable, Equatable {
        var phase: Phase; var call: DeviceCall?; var updatedAt: Date; var account: String? = nil
        init(phase: Phase, call: DeviceCall?, updatedAt: Date, account: String? = nil) { self.phase = phase; self.call = call; self.updatedAt = updatedAt; self.account = account }
    }
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
        records[id] = .init(phase: p, call: call ?? records[id]?.call, updatedAt: .now, account: records[id]?.account ?? DeviceCallGate.currentAccount())
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
    }

    /// Revoked by the service (cancelled / resolved elsewhere / turn ended): a still-confirming card becomes inert.
    func expireIfConfirming(_ id: String) { if phase(id) == .confirming { set(id, .expired) } }
    func run(_ call: DeviceCall, tap: DeviceCallGate.TapToken? = nil) async {
        guard phase(call.id) == .confirming else { return }
        var effective = call
        if let edits = edited[call.id] { effective.args.merge(edits) { _, new in new } }
        // Codex P0-1: refuse anything not registered by a typed event for this account and still valid. Not executed and
        // not reported (an unknown call_id has no turn to report into); the card shows it as not done.
        if let why = DeviceCallGate.check(call, finalArgs: effective.args, tap: tap) { set(call.id, .done(DeviceCallGate.rejected(call, why))); return }
        phases[call.id] = .running; persist(call.id, .running, call: effective)   // durable BEFORE any side effect
        await execute(effective)
    }
    /// Relaunch path for a call that was `.running` when the app died.
    func resumeInterrupted(_ id: String) async {
        // Codex PR #89: a restart never re-grants a write. Only the account that ran it may recover it, and recovery only
        // LOOKS UP the original effect (call_id marker); if it is not found the outcome is unknown — nothing is re-executed.
        guard let record = records[id], let call = record.call, record.account != nil, record.account == DeviceCallGate.currentAccount(),
              interrupted.remove(id) != nil else { return }
        let found = DeviceToolContract.idempotentTools.contains(call.tool) ? await DeviceCallHub.executor.lookup(call) : nil
        await finish(call, found ?? DeviceToolContract.interruptedUnknown(call))
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
        for id in pendingReportIDs where !retrying.contains(id) && (records[id]?.account == nil || records[id]?.account == DeviceCallGate.currentAccount()) {
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

/// Codex P0-1 (PR #89 re-review): the single execution authority for device calls.
/// - Grants come ONLY from `receive`, called by the app service at the authenticated SSE boundary
///   (`ConversationDeviceCall.lifecycle`), never from a view. A grant binds call_id + tool + args hash + interrupt +
///   conversation + turn + non-nil account + session generation + a strict, non-extendable deadline.
/// - Writes additionally consume a one-shot local tap token minted by the card button for the FINAL (edited) args.
/// - `commitCheck` is synchronous and is called by the executor immediately before each system side effect, so expiry,
///   sign-out (generation bump) or revocation during an await (permission prompt, lookup) still stops the write.
/// - Cancel / resolve / turn end revoke; repeated events never extend; a wall-clock rollback cannot extend
///   (an uptime budget is checked too); the boundary is fail-first (`now >= deadline` is expired).
@MainActor enum DeviceCallGate {
    struct Grant: Equatable {
        let callID: String, tool: String, argsHash: String, interruptID: String?, conversationID: String?, turnID: String?
        let account: String, generation: Int, deadline: Date, uptimeAtGrant: TimeInterval, budget: TimeInterval
        var revoked = false
    }
    struct TapToken: Equatable, Sendable { let callID: String; let finalArgsHash: String; let nonce: UUID }
    enum Rejection: String, Equatable {
        case unregistered = "unauthorized_call", accountMismatch = "account_mismatch", noAccount = "no_account", expired = "call_expired",
             invalidExpiry = "invalid_expiry", revoked = "call_revoked", mismatch = "call_mismatch", tapRequired = "tap_required", staleSession = "stale_session"
    }
    /// Signed-in user id (NativeAuthApplicationModel); nil when signed out → nothing may run.
    static var currentAccount: () -> String? = { nil }
    static var wallClock: () -> Date = { Date() }
    static var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private(set) static var generation = 0
    private static var grants: [String: Grant] = [:]
    private static var taps: [String: TapToken] = [:]

    static func argsHash(_ args: [String: DeviceCallValue]) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(args)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The only grant source. A second event for the same call_id never replaces or extends the first grant.
    static func receive(_ call: DeviceCall, conversationID: String? = nil, turnID: String? = nil) {
        guard grants[call.call_id] == nil, let account = currentAccount() else { return }
        let now = wallClock()
        let deadline = call.strictDeadline(receivedAt: now) ?? .distantPast   // missing / unparsable → fail closed
        grants[call.call_id] = .init(callID: call.call_id, tool: call.tool, argsHash: argsHash(call.args), interruptID: call.interrupt_id,
                                     conversationID: conversationID, turnID: turnID, account: account, generation: generation,
                                     deadline: deadline, uptimeAtGrant: uptime(), budget: max(0, deadline.timeIntervalSince(now)))
    }
    /// Cancelled / resolved elsewhere / turn finished: the grant dies and any confirming card shows as no longer valid.
    static func revoke(_ callIDs: [String]) {
        for id in callIDs { grants[id]?.revoked = true; taps[id] = nil; DeviceCallStore.shared.expireIfConfirming(id) }
    }
    static func isLive(_ callID: String) -> Bool { commitCheck(callID) == nil }

    /// Called only by the card's confirm button: binds the tap to the final args the user saw.
    static func confirmTap(_ call: DeviceCall, finalArgs: [String: DeviceCallValue]) -> TapToken? {
        guard validate(call) == nil else { return nil }
        let token = TapToken(callID: call.call_id, finalArgsHash: argsHash(finalArgs), nonce: UUID())
        taps[call.call_id] = token; return token
    }
    /// Run start: the call must match its grant exactly; a write must present (and consumes) the tap token for `finalArgs`.
    static func check(_ call: DeviceCall, finalArgs: [String: DeviceCallValue], tap: TapToken?) -> Rejection? {
        if let why = validate(call) { return why }
        if DeviceToolContract.runsWithoutTap(tool: call.tool, confirm: call.confirm), tap == nil { return nil }
        guard let tap, let issued = taps[call.call_id], issued == tap, tap.finalArgsHash == argsHash(finalArgs) else { return .tapRequired }
        taps[call.call_id] = nil   // one-shot
        return nil
    }
    /// Synchronous re-validation immediately before a system side effect.
    static func commitCheck(_ callID: String) -> Rejection? {
        guard let g = grants[callID] else { return .unregistered }
        if g.revoked { return .revoked }
        guard let account = currentAccount() else { return .noAccount }
        guard g.account == account else { return .accountMismatch }
        guard g.generation == generation else { return .staleSession }
        if g.deadline == .distantPast { return .invalidExpiry }
        if wallClock() >= g.deadline || uptime() - g.uptimeAtGrant >= g.budget { return .expired }
        return nil
    }
    private static func validate(_ call: DeviceCall) -> Rejection? {
        if let why = commitCheck(call.call_id) { return why }
        guard let g = grants[call.call_id], g.tool == call.tool, g.argsHash == argsHash(call.args), g.interruptID == call.interrupt_id else { return .mismatch }
        return nil
    }
    static func rejected(_ call: DeviceCall, _ why: Rejection) -> DeviceCallResult {
        .init(call_id: call.call_id, status: .error, data: ["reason": .string(why.rawValue), "retryable": .bool(false)])
    }
    /// Wires the session service's SSE boundary (received / resolved / cancelled / turn ended) to this gate.
    static func installLifecycle() {
        ConversationDeviceCall.lifecycle = { event in
            Task { @MainActor in
                switch event {
                case .received(let wire, let conversationID, let turnID):
                    if let call = DeviceCall(wire) { receive(call, conversationID: conversationID.uuidString, turnID: turnID.uuidString) }
                case .revoked(let ids): revoke(ids)
                }
            }
        }
    }
    /// Sign-out / account switch: every grant and tap dies, and in-flight executions fail their commit check.
    static func reset() { grants = [:]; taps = [:]; generation += 1 }
}

extension DeviceCall {
    /// Full catpaw.device.v1 fields (the session's `wireJSON` only carries call_id, tool, args, confirm, ttl_sec).
    init?(_ call: ConversationDeviceCall) {
        guard let args = try? JSONDecoder().decode([String: DeviceCallValue].self, from: call.args) else { return nil }
        self.init(call_id: call.callID, tool: call.tool, args: args, confirm: Confirm(rawValue: call.confirm) ?? .card,
                  ttl_sec: call.ttlSec, interrupt_id: call.interruptID, args_hash: call.argsHash, expires_at: call.expiresAt)
    }
}
