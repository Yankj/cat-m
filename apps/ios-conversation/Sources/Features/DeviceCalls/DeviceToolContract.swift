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
    static let tapRequiredTools: Set<String> = ["contacts_search"]
    /// True when the card may run the call on appear (no user tap).
    static func runsWithoutTap(tool: String, confirm: DeviceCall.Confirm?) -> Bool { confirm == DeviceCall.Confirm.none && !tapRequiredTools.contains(tool) }
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

/// Trust: what kind of effect a device tool has, shown on the confirm card so the user knows what they approve.
enum DeviceRiskTier: String, Sendable, Equatable {
    /// Reads phone data; nothing changes.
    case read
    /// Writes to the phone and can be undone from the receipt (calendar, reminder, alarm).
    case undoable
    /// Hands off to another app; the user finishes there (Maps, shopping, Shortcuts).
    case handoff
    /// Reaches other people; the system sheet / dialer asks again before anything is sent.
    case outbound
}

extension DeviceToolContract {
    static func riskTier(_ tool: String) -> DeviceRiskTier {
        switch tool {
        case "calendar_list", "contacts_search", "places_search": .read
        case "calendar_create", "reminder_create", "alarm_set": .undoable
        case "sms_compose", "mail_compose", "phone_call": .outbound
        default: .handoff
        }
    }
    /// One line under the card fields.
    static func riskNoteKey(_ tool: String) -> String {
        switch riskTier(tool) {
        case .read: "只读取，不会改动手机上的内容"
        case .undoable: "会写入手机，完成后可以撤销"
        case .handoff: "会打开其他 App，后续由你在那里完成"
        case .outbound: "会联系他人；系统界面会再让你确认一次"
        }
    }
    /// The model's one-line reason (`why` arg), trimmed for the card; nil when absent/blank.
    static func whyText(_ args: [String: DeviceCallValue]) -> String? {
        guard case .string(let raw)? = args["why"] else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(80))
    }
    /// maps_open: coordinates win over the text query (server allows either); mode → Apple Maps dirflg.
    static func mapsURL(query: String, lat: Double?, lng: Double?, mode: String) -> URL? {
        let flag = ["walk": "w", "walking": "w", "transit": "r", "drive": "d", "driving": "d"][mode] ?? "d"
                var items: [URLQueryItem] = []
        if let lat, let lng, lat.isFinite, lng.isFinite, abs(lat) <= 90, abs(lng) <= 180 {
            items.append(.init(name: "daddr", value: "\(lat),\(lng)"))
            if !query.isEmpty { items.append(.init(name: "q", value: query)) }
        } else {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            items.append(.init(name: "daddr", value: query))
        }
        items.append(.init(name: "dirflg", value: flag))
        var c = URLComponents(); c.queryItems = items
        return URL(string: "maps://?" + (c.percentEncodedQuery ?? ""))
    }
    /// shortcut_run → shortcuts://run-shortcut?name=…[&input=text&text=…]
    static func shortcutURL(name: String, input: String) -> URL? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var c = URLComponents(string: "shortcuts://run-shortcut")!
        c.queryItems = [.init(name: "name", value: name)] + (input.isEmpty ? [] : [.init(name: "input", value: "text"), .init(name: "text", value: input)])
        return c.url
    }
    /// shop_open `url`: only an https link is opened directly (no custom schemes from the model).
    static func shopDirectURL(_ raw: String) -> URL? {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespaces)), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return nil }
        return u
    }
}
