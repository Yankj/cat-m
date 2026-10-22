import Foundation

// The iOS views use LA's bilingual helper. This portable runner exercises only the actual snapshot
// decoder and scheduled-notification parser, without launching the app or requesting any permission.
enum LA {
    static func s(_ zh: String, _ en: String) -> String { en }
}

@main struct WidgetNotificationSurfaceRunner {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
        checks += 1
    }

    struct Failure: Error { let message: String }

    static func snapshot(_ changes: [String: Any] = [:]) throws -> catWidgetEntry {
        var object: [String: Any] = [
            "version": 2, "updated_at": now.timeIntervalSince1970,
            "suggestion": ["id": "s1", "title": " Prepare notes ", "why": " Review starts soon "],
            "meeting": ["id": "s1", "title": "Review", "why": "Next calendar signal", "starts_at": now.addingTimeInterval(3600).timeIntervalSince1970],
        ]
        object.merge(changes) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: object)
        return AppGroupcatWidgetDataSource.decode(data, now: now)
    }

    static func main() throws {
        let populated = try snapshot()
        try check(populated.suggestion?.title == "Prepare notes" && populated.suggestion?.why == "Review starts soon", "title and why survive decoding")
        try check(populated.meeting?.startsAt == now.addingTimeInterval(3600), "meeting preserves its start")
        try check(!populated.isPlaceholder, "real snapshot is never a gallery placeholder")
        try check(populated.expirations == [now.addingTimeInterval(3600), now.addingTimeInterval(24 * 3600)], "timeline includes start and freshness expiry in order")

        for data in [Data(), Data("{".utf8), Data("[]".utf8), Data(repeating: 32, count: 65_537)] {
            let entry = AppGroupcatWidgetDataSource.decode(data, now: now)
            try check(entry.suggestion == nil && entry.meeting == nil && !entry.isPlaceholder, "missing/corrupt data stays empty")
        }
        for changes: [String: Any] in [
            ["version": 1, "tasks": [["status": "done"]]], ["version": 3],
            ["updated_at": NSNull()], ["updated_at": now.addingTimeInterval(-24 * 3600).timeIntervalSince1970],
            ["updated_at": now.addingTimeInterval(301).timeIntervalSince1970],
        ] {
            let entry = try snapshot(changes)
            try check(entry.suggestion == nil && entry.meeting == nil, "unsupported or stale snapshots never display content")
        }

        let badSuggestion = try snapshot(["suggestion": ["id": "bad", "title": " ", "why": "reason"]])
        try check(badSuggestion.suggestion == nil && badSuggestion.meeting != nil, "one malformed item does not discard the other")
        let badMeeting = try snapshot(["meeting": ["id": "bad", "title": "Review", "why": "reason", "starts_at": "tomorrow"]])
        try check(badMeeting.meeting == nil && badMeeting.suggestion != nil, "invalid date does not become an undated meeting")
        let unrepresentableMeeting = try snapshot(["meeting": ["id": "bad", "title": "Review", "why": "reason", "starts_at": 1e100]])
        try check(unrepresentableMeeting.meeting == nil, "extreme finite dates cannot reach widget date formatting")
        let pastMeeting = try snapshot(["meeting": ["id": "s1", "title": "Review", "why": "reason", "starts_at": now.timeIntervalSince1970]])
        try check(pastMeeting.meeting == nil && pastMeeting.suggestion == nil, "older v2 meeting and matching suggestion expire at start")
        let expiredSuggestion = try snapshot(["suggestion": ["id": "s2", "title": "Prepare", "why": "reason", "expires_at": now.timeIntervalSince1970]])
        try check(expiredSuggestion.suggestion == nil && expiredSuggestion.meeting != nil, "independent suggestion expiry preserves a future meeting")
        let badExpiry = try snapshot(["suggestion": ["id": "s2", "title": "Prepare", "why": "reason", "expires_at": "bad"]])
        try check(badExpiry.suggestion == nil, "invalid expiry is not silently ignored")

        var info: [AnyHashable: Any] = [
            "catpaw_proactive_event": "event-1", "catpaw_proactive_title": "Review",
            "catpaw_proactive_start": now.addingTimeInterval(3600).timeIntervalSince1970,
            "catpaw_proactive_due": now.addingTimeInterval(2700).timeIntervalSince1970,
            "catpaw_proactive_place": "Room 1",
        ]
        let context = catScheduledMeetingNotification(userInfo: info, defaultLeadMinutes: 10, now: now)
        try check(context?.due == now.addingTimeInterval(2700) && context?.place == "Room 1", "cold-start action retains the scheduled lead, even when the default changed")
        info.removeValue(forKey: "catpaw_proactive_due")
        let legacy = catScheduledMeetingNotification(userInfo: info, defaultLeadMinutes: 10, now: now)
        try check(legacy?.due == now.addingTimeInterval(3000), "legacy context uses bounded default lead")

        for (key, value): (String, Any) in [
            ("catpaw_proactive_event", " "), ("catpaw_proactive_title", ""),
            ("catpaw_proactive_start", now.timeIntervalSince1970),
            ("catpaw_proactive_start", now.addingTimeInterval(24 * 3600 + 1).timeIntervalSince1970),
            ("catpaw_proactive_start", Double.infinity), ("catpaw_proactive_start", Double.nan),
            ("catpaw_proactive_start", 1e100), ("catpaw_proactive_start", "tomorrow"),
            ("catpaw_proactive_due", Double.nan), ("catpaw_proactive_due", NSNull()),
            ("catpaw_proactive_due", now.addingTimeInterval(3601).timeIntervalSince1970),
            ("catpaw_proactive_due", now.addingTimeInterval(-7201).timeIntervalSince1970),
        ] {
            var invalid = info
            invalid[key] = value
            try check(catScheduledMeetingNotification(userInfo: invalid, defaultLeadMinutes: 10, now: now) == nil, "malformed/expired notification context fails closed: \(key)")
        }
        try check(catScheduledMeetingNotification(userInfo: info, defaultLeadMinutes: 181, now: now) == nil, "invalid fallback lead is rejected")
        print("PASS widget snapshot decoding, expiry timelines, and scheduled-notification recovery metadata (\(checks) checks)")
    }
}
