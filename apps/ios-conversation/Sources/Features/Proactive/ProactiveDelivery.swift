import Foundation

/// P0-3: the four proactive levels survive end-to-end on the client (Codex review 3fc2faf).
/// silent → nothing; card → in-app only; notify → normal notification; interrupt → time-sensitive + Live Activity.
/// The on-device policy (confidence floor, quiet hours, daily cap) is the final gate and applies whether the level
/// came from the server or from local rules after the remote call failed. It can only lower a level, never raise it.
enum ProactiveLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case silent, card, notify, interrupt
    /// Unknown server strings degrade to `card` (visible, never louder).
    init(server: String?) { self = server.flatMap(ProactiveLevel.init(rawValue:)) ?? .card }
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

struct ProactiveDeliveryPolicy: Sendable {
    var dailyCap = 5
    var quietStartHour = 22
    var quietEndHour = 8
    /// Below this the assistant stays silent (matches edge `silentBelow`).
    var silentBelow = 0.3
    /// An interrupt may break quiet hours only with server confidence at least this high.
    var quietInterruptConfidence = 0.9
    static let standard = ProactiveDeliveryPolicy()
}

struct ProactiveChannels: Equatable, Sendable {
    var inApp: Bool, notification: Bool, timeSensitive: Bool, liveActivity: Bool
}

enum ProactiveDelivery {
    static func channels(_ level: ProactiveLevel) -> ProactiveChannels {
        switch level {
        case .silent: .init(inApp: false, notification: false, timeSensitive: false, liveActivity: false)
        case .card: .init(inApp: true, notification: false, timeSensitive: false, liveActivity: false)
        case .notify: .init(inApp: true, notification: true, timeSensitive: false, liveActivity: false)
        case .interrupt: .init(inApp: true, notification: true, timeSensitive: true, liveActivity: true)
        }
    }

    static func isQuiet(_ now: Date, calendar: Calendar, policy: ProactiveDeliveryPolicy = .standard) -> Bool {
        let h = calendar.component(.hour, from: now)
        return policy.quietStartHour > policy.quietEndHour
            ? (h >= policy.quietStartHour || h < policy.quietEndHour)
            : (h >= policy.quietStartHour && h < policy.quietEndHour)
    }

    /// Final on-device gate. `confidence == nil` means the remote decision was unavailable (local rules).
    static func finalLevel(proposed: ProactiveLevel, confidence: Double?, now: Date, calendar: Calendar,
                           deliveredToday: Int, policy: ProactiveDeliveryPolicy = .standard) -> ProactiveLevel {
        var level = proposed
        if let confidence, confidence < policy.silentBelow { return .silent }
        if level >= .notify, isQuiet(now, calendar: calendar, policy: policy),
           !(level == .interrupt && (confidence ?? 0) >= policy.quietInterruptConfidence) { level = .card }
        if level >= .notify, deliveredToday >= policy.dailyCap { level = .card }
        return level
    }

    /// Offline rules (remote unavailable): too late → silent; otherwise a normal notification.
    static func localLevel(minutesUntil: Int) -> ProactiveLevel { minutesUntil < 3 ? .silent : .notify }
}

/// On-device record of system notifications actually delivered (notify/interrupt), for the daily cap.
struct ProactiveDeliveryLog: Codable, Sendable, Equatable {
    var notified: [Double] = []
    mutating func record(_ level: ProactiveLevel, at now: Date) {
        guard ProactiveDelivery.channels(level).notification else { return }
        notified.append(now.timeIntervalSince1970)
        notified = notified.filter { now.timeIntervalSince1970 - $0 < 3 * 86400 }
    }
    func deliveredToday(now: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: now).timeIntervalSince1970, end = start + 86400
        return notified.filter { $0 >= start && $0 < end }.count
    }
}
