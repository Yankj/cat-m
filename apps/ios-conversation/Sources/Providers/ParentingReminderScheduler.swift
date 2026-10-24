import Foundation

public enum ParentingNotificationAuthorization: Equatable, Sendable { case notDetermined, denied, authorized }

public struct ParentingPendingNotification: Equatable, Sendable {
    public let id: String
    public let signature: String?
    public let fireAt: Date?
    public init(id: String, signature: String?, fireAt: Date?) { self.id = id; self.signature = signature; self.fireAt = fireAt }
}

public struct ParentingNotificationRequest: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let fireAt: Date
    public let userInfo: [String: String]
    public init(id: String, title: String, body: String, fireAt: Date, userInfo: [String: String]) {
        self.id = id; self.title = title; self.body = body; self.fireAt = fireAt; self.userInfo = userInfo
    }
}

/// The only surface of the system notification centre the scheduler needs. Tests use a fake;
/// production uses `ParentingSystemNotificationCenter`.
public protocol ParentingNotificationCenter: Sendable {
    func authorization() async -> ParentingNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    /// Only requests created by this feature (identifier prefix `ParentingReminderPayload.identifierPrefix`).
    func pending() async -> [ParentingPendingNotification]
    func add(_ request: ParentingNotificationRequest) async throws
    func remove(ids: [String]) async
}

public struct ParentingReminderCopy: Sendable {
    public let ui: @Sendable (_ key: String, _ arguments: [String]) -> String
    public init(ui: @escaping @Sendable (String, [String]) -> String) { self.ui = ui }
    public static let system = ParentingReminderCopy { key, arguments in AppLanguage(locale: .current).ui(key, arguments: arguments) }
}

/// Remembers, per arrangement, the fire time this device last scheduled, so that a reminder which has since
/// gone off is not later reported as missed. Not part of the encrypted ledger.
public protocol ParentingReminderMemory: Sendable {
    func load() -> [UUID: Date]
    func save(_ value: [UUID: Date])
}

/// What the Today screen may claim. `scheduled` only for requests read back from the system.
public struct ParentingReminderStatus: Equatable, Sendable {
    public var settings: ParentingReminderSettings
    public var authorization: ParentingNotificationAuthorization
    public var outcomes: [UUID: ParentingReminderOutcome]
    /// A system call failed during the last sync; nothing is claimed for items without read-back.
    public var systemRefused: Bool
    public var checkedAt: Date
    public var scheduledCount: Int {
        outcomes.values.reduce(0) { if case .scheduled = $1 { return $0 + 1 } else { return $0 } }
    }
}

/// Keeps the system's pending local notifications equal to the plan derived from the confirmed ledger.
/// Reminders are local only: no server, no APNs, no calendar write. Re-run after every ledger change,
/// on foreground, and when settings change.
public actor ParentingReminderScheduler {
    private let center: any ParentingNotificationCenter
    private let subjectID: UUID
    private let calendar: Calendar
    private let copy: ParentingReminderCopy
    private let isCurrentAccount: @Sendable () -> Bool
    private let memory: (any ParentingReminderMemory)?
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(center: any ParentingNotificationCenter, subjectID: UUID, calendar: Calendar = .autoupdatingCurrent,
                copy: ParentingReminderCopy = .system, memory: (any ParentingReminderMemory)? = nil,
                isCurrentAccount: @escaping @Sendable () -> Bool) {
        self.center = center; self.subjectID = subjectID; self.calendar = calendar; self.copy = copy
        self.memory = memory; self.isCurrentAccount = isCurrentAccount
    }

    public func authorization() async -> ParentingNotificationAuthorization { await center.authorization() }

    /// Asks the system for permission. Only call from an explicit parent action.
    public func requestAuthorization() async -> ParentingNotificationAuthorization {
        guard isCurrentAccount() else { return await center.authorization() }
        _ = try? await center.requestAuthorization()
        return await center.authorization()
    }

    /// Removes every reminder this feature scheduled for this account.
    public func clear() async {
        await acquire(); defer { release() }
        let own = await center.pending().map(\.id).filter { $0.hasPrefix(ParentingReminderPayload.subjectPrefix(subjectID)) }
        if !own.isEmpty { await center.remove(ids: own) }
    }

    public func reconcile(workspace: ParentingWorkspace, settings: ParentingReminderSettings,
                          now: Date = Date()) async -> ParentingReminderStatus {
        await acquire(); defer { release() }
        let prefix = ParentingReminderPayload.subjectPrefix(subjectID)
        var authorization = await center.authorization()
        var status = ParentingReminderStatus(settings: settings, authorization: authorization, outcomes: [:],
                                             systemRefused: false, checkedAt: now)
        let pending = await center.pending().filter { $0.id.hasPrefix(prefix) }
        guard isCurrentAccount() else { return status }
        guard settings.enabled, authorization == .authorized else {
            // Off or not allowed: nothing may remain scheduled, and nothing is claimed.
            if !pending.isEmpty { await center.remove(ids: pending.map(\.id)) }
            return status
        }
        let remembered = memory?.load() ?? [:]
        let plan = ParentingReminderPlanner.plan(workspace: workspace, settings: settings, now: now, calendar: calendar, remembered: remembered)
        var desired: [String: (ParentingNotificationRequest, ParentingPlannedReminder)] = [:]
        for reminder in plan.reminders {
            let request = makeRequest(reminder, settings: settings)
            desired[request.id] = (request, reminder)
        }
        let stale = pending.filter { desired[$0.id] == nil }.map(\.id)
        if !stale.isEmpty { await center.remove(ids: stale) }
        let known = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [String] = []
        for (id, entry) in desired.sorted(by: { $0.value.0.fireAt < $1.value.0.fireAt }) {
            if known[id]?.signature == entry.0.userInfo[ParentingReminderPayload.signatureKey] { continue }
            // Refuse any write once the account that owns this ledger is gone.
            guard isCurrentAccount() else { break }
            do { try await center.add(entry.0); added.append(id) } catch { status.systemRefused = true }
        }
        if !isCurrentAccount() {
            let own = await center.pending().map(\.id).filter { $0.hasPrefix(prefix) }
            if !own.isEmpty { await center.remove(ids: own) }
            return status
        }
        authorization = await center.authorization()
        status.authorization = authorization
        let readBack = Dictionary(await center.pending().filter { $0.id.hasPrefix(prefix) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in desired {
            if let fireAt = readBack[id]?.fireAt, readBack[id]?.signature == entry.0.userInfo[ParentingReminderPayload.signatureKey] {
                status.outcomes[entry.1.arrangementID] = .scheduled(fireAt)
            } else {
                status.systemRefused = true
            }
        }
        for (id, fireAt) in plan.reminded { status.outcomes[id] = .reminded(fireAt) }
        for (id, reason) in plan.skipped { status.outcomes[id] = .skipped(reason) }
        for id in plan.deferred { status.outcomes[id] = .deferred }
        // Remember what is confirmed scheduled (and what already went off); forget everything else.
        var next = plan.reminded
        for reminder in plan.reminders { if case .scheduled = status.outcomes[reminder.arrangementID] { next[reminder.arrangementID] = reminder.fireAt } }
        if next != remembered { memory?.save(next) }
        return status
    }

    func makeRequest(_ reminder: ParentingPlannedReminder, settings: ParentingReminderSettings) -> ParentingNotificationRequest {
        let title = copy.ui("小咪提醒", [])
        let body: String
        if settings.hideContent {
            body = copy.ui("有一件孩子的安排即将开始，打开小咪查看。", [])
        } else {
            let time = reminder.dueAt.formatted(date: .abbreviated, time: .shortened)
            let why = reminder.movedForQuietHours
                ? copy.ui("为避开夜间安静时段，已提前到前一晚提醒", [])
                : copy.ui("按你的设置，{0}提醒", [copy.ui(settings.lead.title, [])])
            body = copy.ui("{0}：{1}", [reminder.childName, reminder.title]) + "\n" + copy.ui("{0} 开始 · {1}", [time, why])
        }
        let signature = bytesHash(Data("\(reminder.fireAt.timeIntervalSince1970)|\(reminder.dueAt.timeIntervalSince1970)|\(title)|\(body)".utf8))
        return ParentingNotificationRequest(
            id: ParentingReminderPayload.identifier(subject: subjectID, arrangement: reminder.arrangementID),
            title: title, body: body, fireAt: reminder.fireAt,
            userInfo: [ParentingReminderPayload.marker: "1",
                       ParentingReminderPayload.subjectKey: subjectID.uuidString.lowercased(),
                       ParentingReminderPayload.arrangementKey: reminder.arrangementID.uuidString.lowercased(),
                       ParentingReminderPayload.signatureKey: signature])
    }

    private func acquire() async {
        if !running { running = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
    }
}

/// Settings and reminder memory live beside, not inside, the encrypted ledger.
public struct ParentingReminderSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, subjectID: UUID) {
        self.defaults = defaults
        key = "mimi.parenting.reminders.v1." + subjectID.uuidString.lowercased()
    }
    public func load() -> ParentingReminderSettings {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(ParentingReminderSettings.self, from: data) else { return .default }
        return value
    }
    public func save(_ settings: ParentingReminderSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
    public func erase() { defaults.removeObject(forKey: key) }
}

public struct ParentingReminderMemoryStore: ParentingReminderMemory, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, subjectID: UUID) {
        self.defaults = defaults
        key = "mimi.parenting.reminders.memory.v1." + subjectID.uuidString.lowercased()
    }
    public func load() -> [UUID: Date] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: Double] else { return [:] }
        return Dictionary(raw.compactMap { pair in UUID(uuidString: pair.key).map { ($0, Date(timeIntervalSince1970: pair.value)) } },
                          uniquingKeysWith: { first, _ in first })
    }
    public func save(_ value: [UUID: Date]) {
        defaults.set(Dictionary(uniqueKeysWithValues: value.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }), forKey: key)
    }
}
