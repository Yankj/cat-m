import Foundation

/// catpaw.device.v1 client-side contract (NoBug P0-3/P0-4). Foundation-only so it is unit-testable and parsed by the
/// server contract test (services/edge/test/device-tool-client-contract.test.mjs reads `clientTools` from this file).
enum DeviceToolContract {
    /// Tools this app actually executes. Sent as `X-Catpaw-Device-Tools` so the server offers only these.
    static let clientTools: [String] = ["calendar_list", "calendar_create", "reminder_create", "mail_compose", "sms_compose", "phone_call", "contacts_search", "maps_open", "shop_open", "alarm_set", "shortcut_run", "places_search"]
    static let toolsHeader = "X-Catpaw-Device-Tools"
    static var toolsHeaderValue: String { clientTools.joined(separator: ",") }
    /// Tools whose executor de-duplicates by call_id (marker in EKEvent/EKReminder notes), so re-running after a kill
    /// cannot create a second item. Compose / open-URL tools are never re-run automatically.
    static let idempotentTools: Set<String> = ["calendar_create", "reminder_create", "alarm_set", "calendar_list", "contacts_search", "places_search"]

    /// chat-ux #7: tools that read private data and must never run without a tap, even if an older server says `confirm:none`.
    /// Codex P0-1: Markdown (model text, quotes, history) only renders; a `catpaw-card:device_call` fence is inert.
    static let markdownMayCreateDeviceCalls = false
    /// Explicit tradeoff (Codex PR #89): these two are read-only but NOT privacy-free — calendar_list returns titles, times
    /// and locations; places_search uses the current location and preference memory. They auto-run (still gated by a live,
    /// account-bound grant) because the result goes only to the same turn that asked; writes never auto-run.
    /// Codex P0-1: local risk table. Only these read-only tools may run on appear when the server says
    /// `confirm:none`; every write / compose / open / private-read tool (and any unknown tool) always waits for a tap.
    static let autoRunReadOnlyTools: Set<String> = ["calendar_list", "places_search"]
    static func runsWithoutTap(tool: String, confirm: DeviceCall.Confirm?) -> Bool { confirm == DeviceCall.Confirm.none && autoRunReadOnlyTools.contains(tool) }
    /// contacts_search result: name + up to 3 phones; emails only when the model asked (`include_email`). Pure, unit-tested.
    static func minimalContact(name: String, phones: [String], emails: [String], includeEmail: Bool) -> [String: DeviceCallValue] {
        var row: [String: DeviceCallValue] = ["name": .string(name), "phones": .list(Array(phones.prefix(3)))]
        if includeEmail { row["emails"] = .list(Array(emails.prefix(2))) }
        return row
    }

    /// Embedded in notes of anything we write; looked up before writing again.
    static func callMarker(_ callID: String) -> String { "catpaw call_id=\(callID)" }

    /// Non-retryable error for a tool this build cannot run (model must not retry it).
    static func unsupported(_ call: DeviceCall) -> DeviceCallResult {
        .init(call_id: call.call_id, status: .error, data: ["reason": .string("unsupported_tool"), "tool": .string(call.tool), "retryable": .bool(false),
                                                         "message": .string("This phone build cannot run \(call.tool). Do not retry; tell the user.")])
    }
    /// The app was killed while this call ran; for non-idempotent tools we cannot know whether the user sent/opened it.
    static func interruptedUnknown(_ call: DeviceCall) -> DeviceCallResult {
        .init(call_id: call.call_id, status: .error, data: ["reason": .string("interrupted_outcome_unknown"), "retryable": .bool(false),
                                                         "message": .string("The app restarted during this action; it may or may not have happened. Ask the user to check before retrying.")])
    }

    /// Codex P0-4: an external-URL handoff only *requests* the other app; a timeout is unknown, never success.
    static func handoffResult(_ outcome: DeviceHandoffOutcome, callID: String, extra: [String: DeviceCallValue] = [:], refusedReason: String? = nil) -> DeviceCallResult {
        switch outcome {
        case .opened:
            return .init(call_id: callID, status: .ok, data: extra.merging(["handoff": .string("requested")]) { a, _ in a })
        case .timedOut:
            return .init(call_id: callID, status: .error, data: extra.merging(["reason": .string("handoff_unknown"), "retryable": .bool(false),
                "message": .string("The open request was sent but iOS did not confirm it. Ask the user whether it opened before retrying.")]) { _, b in b })
        case .refused:
            var d = extra; d["reason"] = .string(refusedReason ?? "handoff_refused")
            return .init(call_id: callID, status: .error, data: d)
        }
    }
    /// Receipt wording for handoff results (nil → the card's normal wording).
    static func receiptKey(confirmKey: String, status: DeviceCallStatus, data: [String: DeviceCallValue]?) -> String? {
        if status == .ok, data?["handoff"] == .string("requested") { return "已请求打开" }
        if status != .ok, data?["reason"] == .string("handoff_unknown") { return "已请求打开，结果未知" }
        return nil
    }

    /// shop_open: app scheme + https fallback per platform. meituan → imeituan:// (NoBug P0-4), unknown → taobao.
    static func shopURLs(platform raw: String, query: String) -> (app: URL?, web: URL?) {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch raw.lowercased() {
        case "jd", "京东":
            return (URL(string: "openapp.jdmobile://virtual?params=%7B%22des%22:%22search%22,%22keyWord%22:%22\(q)%22%7D"), URL(string: "https://search.jd.com/Search?keyword=\(q)"))
        case "pdd", "拼多多":
            return (URL(string: "pinduoduo://com.xunmeng.pinduoduo/search_result.html?search_key=\(q)"), URL(string: "https://mobile.yangkeduo.com/search_result.html?search_key=\(q)"))
        case "meituan", "美团":
            return (URL(string: "imeituan://www.meituan.com/search?q=\(q)"), URL(string: "https://i.meituan.com/s/\(q)"))
        case "taobao", "淘宝":
            return (URL(string: "taobao://s.taobao.com/search?q=\(q)"), URL(string: "https://s.taobao.com/search?q=\(q)"))
        default:   // unknown platform: 淘宝 search, never a silent no-op
            return (URL(string: "taobao://s.taobao.com/search?q=\(q)"), URL(string: "https://s.taobao.com/search?q=\(q)"))
        }
    }
}

enum DeviceCallDates {
    static func parse(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw)
    }
    static func format(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

/// Result of handing a URL to iOS.
enum DeviceHandoffOutcome: Sendable, Equatable { case opened, timedOut, refused }
