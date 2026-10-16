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
}

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
    func reset() { phases = [:]; edited = [:]; seen = [:]; records = [:]; interrupted = []; defaults.removeObject(forKey: Self.storageKey) }

    private func persist(_ id: String, _ p: Phase, call: DeviceCall?) {
        records[id] = .init(phase: p, call: call ?? records[id]?.call, updatedAt: .now)
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
    }

    func run(_ call: DeviceCall) async {
        guard phase(call.id) == .confirming else { return }
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
