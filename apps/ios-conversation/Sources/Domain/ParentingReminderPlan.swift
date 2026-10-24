import Foundation

/// How long before a confirmed arrangement the parent wants to be reminded.
public enum ParentingReminderLead: String, Codable, CaseIterable, Sendable, Identifiable {
    case minutes15, minutes30, hour1, eveningBefore
    public var id: String { rawValue }
    /// Resource key shown to the parent.
    public var title: String {
        switch self {
        case .minutes15: return "提前 15 分钟"
        case .minutes30: return "提前 30 分钟"
        case .hour1: return "提前 1 小时"
        case .eveningBefore: return "前一天晚上 8 点"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .minutes15: return 15 * 60
        case .minutes30: return 30 * 60
        case .hour1: return 60 * 60
        case .eveningBefore: return nil
        }
    }
}

/// Parent-controlled reminder preferences. Stored per account; never part of the encrypted ledger,
/// so older ledgers decode unchanged. Reminders are off until the parent turns them on.
public struct ParentingReminderSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var lead: ParentingReminderLead
    /// Lock-screen text omits the child's name and the arrangement title.
    public var hideContent: Bool
    public init(enabled: Bool = false, lead: ParentingReminderLead = .hour1, hideContent: Bool = false) {
        self.enabled = enabled; self.lead = lead; self.hideContent = hideContent
    }
    public static let `default` = ParentingReminderSettings()
}

public enum ParentingReminderSkipReason: String, Codable, Sendable, Equatable {
    /// The reminder time (after moving out of quiet hours) is already in the past.
    case pastReminderTime
    /// The household's local day already has the maximum number of reminders.
    case dailyLimit
}

public enum ParentingReminderOutcome: Equatable, Sendable {
    /// Confirmed by reading the pending request back from the system, not merely requested.
    case scheduled(Date)
    /// This device scheduled it earlier and its time has passed, so the system has delivered it (or the parent dismissed it).
    case reminded(Date)
    case skipped(ParentingReminderSkipReason)
    /// More than the system allows is pending; this one is scheduled the next time the app opens.
    case deferred
}

public struct ParentingPlannedReminder: Equatable, Sendable {
    public let arrangementID: UUID
    public let childName: String
    public let title: String
    public let dueAt: Date
    public let fireAt: Date
    /// True when the reminder was moved earlier to stay out of quiet hours.
    public let movedForQuietHours: Bool
}

public struct ParentingReminderPlan: Equatable, Sendable {
    public var reminders: [ParentingPlannedReminder]
    public var skipped: [UUID: ParentingReminderSkipReason]
    public var deferred: Set<UUID>
    /// Reminders this device scheduled earlier (as remembered) whose time has now passed.
    public var reminded: [UUID: Date] = [:]
}

/// Pure planning. Only confirmed (`planned`) arrangements in the future get a reminder; drafts, cancelled
/// and completed ones never do. Quiet hours 21:00-08:00 and at most `maxPerDay` reminders per local day.
public enum ParentingReminderPlanner {
    public static let quietStartHour = 21
    public static let quietEndHour = 8
    public static let eveningHour = 20
    public static let maxPerDay = 2
    /// iOS keeps at most 64 pending local notifications per app.
    public static let maxPending = 48

    public static func isQuiet(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= quietStartHour || hour < quietEndHour
    }

    /// The moment to notify for `due`, or nil if it cannot be computed.
    public static func fireDate(due: Date, lead: ParentingReminderLead, calendar: Calendar) -> (date: Date, moved: Bool)? {
        let raw: Date
        if let interval = lead.interval {
            raw = due.addingTimeInterval(-interval)
        } else {
            let startOfDue = calendar.startOfDay(for: due)
            guard let previous = calendar.date(byAdding: .day, value: -1, to: startOfDue),
                  let evening = calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: previous) else { return nil }
            raw = evening
        }
        guard isQuiet(raw, calendar: calendar) else { return (raw, false) }
        // Move to 20:30 of the evening before the quiet window that contains `raw`.
        let day = calendar.component(.hour, from: raw) >= quietStartHour
            ? calendar.startOfDay(for: raw)
            : (calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: raw)) ?? calendar.startOfDay(for: raw))
        guard let moved = calendar.date(bySettingHour: eveningHour, minute: 30, second: 0, of: day) else { return nil }
        return (moved, true)
    }

    /// `remembered` maps an arrangement to the fire time this device last scheduled for it. It lets a reminder
    /// that has already gone off be reported as such, and count toward that day's limit, instead of "missed".
    public static func plan(workspace: ParentingWorkspace, settings: ParentingReminderSettings, now: Date,
                            calendar: Calendar = .autoupdatingCurrent, remembered: [UUID: Date] = [:]) -> ParentingReminderPlan {
        guard settings.enabled else { return .init(reminders: [], skipped: [:], deferred: [], reminded: [:]) }
        let names = Dictionary(uniqueKeysWithValues: workspace.children.map { ($0.id, $0.name) })
        var candidates: [ParentingPlannedReminder] = []
        var elapsed: [ParentingPlannedReminder] = []
        var skipped: [UUID: ParentingReminderSkipReason] = [:]
        for item in workspace.arrangements.sorted(by: { ($0.dueAt, $0.id.uuidString) < ($1.dueAt, $1.id.uuidString) })
        where item.state == .planned && item.dueAt > now {
            guard let name = names[item.childID], let fire = fireDate(due: item.dueAt, lead: settings.lead, calendar: calendar) else {
                skipped[item.id] = .pastReminderTime
                continue
            }
            let planned = ParentingPlannedReminder(arrangementID: item.id, childName: name, title: item.title, dueAt: item.dueAt,
                                                   fireAt: fire.date, movedForQuietHours: fire.moved)
            if fire.date <= now.addingTimeInterval(5) {
                if let earlier = remembered[item.id], abs(earlier.timeIntervalSince(fire.date)) < 1 { elapsed.append(planned) }
                else { skipped[item.id] = .pastReminderTime }
                continue
            }
            candidates.append(planned)
        }
        candidates.sort { ($0.fireAt, $0.arrangementID.uuidString) < ($1.fireAt, $1.arrangementID.uuidString) }
        var perDay: [Date: Int] = [:]
        // Reminders that already went off use up their day's allowance first.
        for done in elapsed { perDay[calendar.startOfDay(for: done.fireAt), default: 0] += 1 }
        var kept: [ParentingPlannedReminder] = []
        for candidate in candidates {
            let day = calendar.startOfDay(for: candidate.fireAt)
            if perDay[day, default: 0] >= maxPerDay { skipped[candidate.arrangementID] = .dailyLimit; continue }
            perDay[day, default: 0] += 1
            kept.append(candidate)
        }
        let deferred = Set(kept.dropFirst(maxPending).map(\.arrangementID))
        return .init(reminders: Array(kept.prefix(maxPending)), skipped: skipped, deferred: deferred,
                     reminded: Dictionary(elapsed.map { ($0.arrangementID, $0.fireAt) }, uniquingKeysWith: { first, _ in first }))
    }
}

/// Routing for a tapped or foreground reminder. A reminder belongs to the account that scheduled it.
public enum ParentingReminderPayload {
    public static let marker = "mimi_parenting_reminder"
    public static let subjectKey = "mimi_parenting_subject"
    public static let arrangementKey = "mimi_parenting_arrangement"
    public static let signatureKey = "mimi_parenting_signature"
    public static let identifierPrefix = "mimi.parenting.v1."

    public static func isParenting(_ info: [AnyHashable: Any]) -> Bool { (info[marker] as? String) == "1" }
    /// Present or open only while the same account that scheduled it is signed in.
    public static func belongsToCurrent(_ info: [AnyHashable: Any], currentAccount: String?) -> Bool {
        guard isParenting(info), let subject = info[subjectKey] as? String, let currentAccount else { return false }
        return subject.caseInsensitiveCompare(currentAccount) == .orderedSame
    }
    public static func identifier(subject: UUID, arrangement: UUID) -> String {
        identifierPrefix + subject.uuidString.lowercased() + "." + arrangement.uuidString.lowercased()
    }
    public static func subjectPrefix(_ subject: UUID) -> String { identifierPrefix + subject.uuidString.lowercased() + "." }
}
