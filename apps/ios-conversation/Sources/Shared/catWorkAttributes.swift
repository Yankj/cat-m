import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the app target and the `catWidgets` extension.
/// `ContentState` is exactly the APNs `content-state` of docs/backend/proactive-tasks.md
/// (`{title, body, kind, taskID}`) so server `live_activity_update` pushes decode unchanged.
struct CatpawWorkAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var body: String
        /// Server event kind (`reminder_due|task_created|task_updated|agent_message`) or a client turn kind
        /// (`working|done|failed|needs_user`). Unknown kinds render as working.
        var kind: String
        var taskID: String
        /// ux-round-1505 (all optional → payloads from older builds / the proactive server still decode):
        var startedAt: Date? = nil   // turn start → Text(timerInterval:); nil hides the timer
        var endedAt: Date? = nil     // freezes elapsed on done / failed
        var step: Int? = nil         // 1-based count of tool steps started (honest dots, no fake total)
        var tool: String? = nil      // raw tool id; the widget maps it to a spoken verb, never shown
        var summary: String? = nil   // the task itself, e.g. 评审会加进日历

        /// Presentation-only mapping; not encoded.
        enum Status: Hashable { case working, needsUser, reminder, done, failed }
        var status: Status {
            switch kind {
            case Kind.done: return .done
            case Kind.failed: return .failed
            case Kind.needsUser: return .needsUser
            case "reminder_due": return .reminder
            default: return .working
            }
        }
        enum Kind {
            static let working = "working", done = "done", failed = "failed", needsUser = "needs_user"
            /// r11 client turn phases (status stays `.working`; they only change the cat head pose).
            static let thinking = "thinking", tool = "tool", writing = "writing"
        }
        /// Cat head pose for the Live Activity / Dynamic Island.
        enum Pose: Hashable { case thinking, tool, writing, waiting, done, failed }
        var pose: Pose {
            switch kind {
            case Kind.thinking, Kind.working: return .thinking
            case Kind.tool: return .tool
            case Kind.writing: return .writing
            case Kind.done: return .done
            case Kind.failed: return .failed
            default: return .waiting
            }
        }
    }
    var taskID: String
    var conversationID: String
    var title: String
}


/// Isolated from chat-turn Live Activities. Countdown to leave_at for proactive travel cards.
struct CatpawLeaveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        /// Absolute leave time (seconds since reference date) for TimeInterval-based UI.
        var leaveAt: Date
        var minutesLeft: Int
        var meetingTitle: String
    }
    var suggestionID: String
    var meetingTitle: String
}

#endif

/// status-line v1.0 (harness-brainstorm §4.5, visual SPEC §9): ONE copy table for every tool the app can see, shared by the
/// chat status row, the step list glyphs and the Live Activity / Dynamic Island (short form). Copy names only the tool type
/// and a generic object — never arguments or reasoning. Tool copy is literal; playful variants only for tool-less phases.
/// No 「…」, no 「！」, no 「马上」/「稍等哦」 (SPEC §9 copy rules).
struct ToolStepCopy: Equatable, Sendable {
    /// Running copy (zh / en); variants rotate only when the same tool is entered again (no fake carousel).
    let running: [String]
    let runningEN: [String]
    /// Live Activity / Dynamic Island form.
    let short: String
    let shortEN: String
    /// Copy while a confirmation card for this tool is pending; nil = this tool never shows a card.
    let confirm: String?
    let confirmEN: String?
    let symbol: String

    static let generic = ToolStepCopy(running: ["正在处理"], runningEN: ["Working on it"], short: "正在处理", shortEN: "Working on it",
                                      confirm: "等你确认", confirmEN: "Waiting for you", symbol: "sparkle")
    static let table: [String: ToolStepCopy] = {
        var t: [String: ToolStepCopy] = [:]
        func add(_ names: [String], _ symbol: String, _ running: [String], _ runningEN: [String], _ short: String, _ shortEN: String,
                 _ confirm: String? = nil, _ confirmEN: String? = nil) {
            for n in names { t[n] = ToolStepCopy(running: running, runningEN: runningEN, short: short, shortEN: shortEN, confirm: confirm, confirmEN: confirmEN, symbol: symbol) }
        }
        add(["calendar_list"], "calendar", ["正在查看你的日程", "正在翻日历"], ["Checking your schedule", "Looking through your calendar"], "查看日历", "Checking calendar")
        add(["calendar_create", "create_calendar_event"], "calendar.badge.plus", ["正在准备日程"], ["Preparing the event"], "添加日程", "Adding event", "等你确认日程", "Waiting for you to confirm the event")
        add(["update_calendar_event"], "calendar.badge.clock", ["正在调整日程"], ["Updating the event"], "调整日程", "Updating event", "等你确认修改", "Waiting for you to confirm the change")
        add(["reminder_create", "create_reminder"], "bell", ["正在准备提醒"], ["Preparing a reminder"], "设置提醒", "Setting reminder", "等你确认提醒", "Waiting for you to confirm the reminder")
        add(["update_reminder"], "bell", ["正在调整提醒"], ["Updating the reminder"], "调整提醒", "Updating reminder", "等你确认修改", "Waiting for you to confirm the change")
        add(["alarm_set"], "alarm", ["正在定闹钟"], ["Setting an alarm"], "设置闹钟", "Setting alarm", "等你确认闹钟", "Waiting for you to confirm the alarm")
        add(["places_search"], "mappin.and.ellipse", ["正在找附近的地方"], ["Finding places nearby"], "搜索附近", "Searching nearby")
        add(["maps_open"], "map", ["正在规划路线"], ["Planning the route"], "打开地图", "Opening Maps", "等你确认打开地图", "Waiting for you to open Maps")
        add(["web_search"], "magnifyingglass", ["正在搜索网页"], ["Searching the web"], "搜索网页", "Searching web")
        add(["delegate_sources_v1"], "doc.text.magnifyingglass", ["正在阅读你给的链接"], ["Reading your link"], "阅读链接", "Reading link")
        add(["contacts_search"], "person.crop.circle", ["正在找联系人"], ["Looking up contacts"], "查找联系人", "Finding contact", "等你允许查找", "Waiting for your permission")
        add(["mail_compose"], "envelope", ["正在起草邮件"], ["Drafting the email"], "起草邮件", "Drafting email", "等你确认草稿", "Waiting for you to review the draft")
        add(["sms_compose"], "message", ["正在起草短信"], ["Drafting the message"], "起草短信", "Drafting message", "等你确认草稿", "Waiting for you to review the draft")
        add(["phone_call"], "phone", ["正在准备拨号"], ["Preparing the call"], "准备拨号", "Preparing call", "等你确认拨打", "Waiting for you to confirm the call")
        add(["shop_open"], "bag", ["正在准备购物搜索"], ["Preparing a shopping search"], "打开购物", "Opening shop", "等你确认打开", "Waiting for you to confirm")
        add(["shortcut_run"], "square.stack.3d.up", ["正在准备快捷指令"], ["Preparing the shortcut"], "运行快捷指令", "Running shortcut", "等你确认运行", "Waiting for you to confirm")
        add(["list_tasks"], "checklist", ["正在看你的待办"], ["Checking your to-dos"], "查看待办", "Checking to-dos")
        add(["create_task", "update_task"], "checklist", ["正在整理待办"], ["Updating your to-dos"], "整理待办", "Updating to-dos", "等你确认", "Waiting for you")
        add(["memory_search"], "brain", ["正在回想你说过的事"], ["Recalling what you said"], "回想记忆", "Recalling")
        add(["memory_save", "memory_update"], "brain.head.profile", ["正在记下来"], ["Saving this to memory"], "记下来", "Saving")
        add(["memory_forget"], "trash", ["正在找要忘记的记忆"], ["Finding the memory to forget"], "删除记忆", "Forgetting", "等你确认删除", "Waiting for you to confirm deletion")
        add(["propose_memory_v1"], "brain", ["正在整理可记住的内容"], ["Noting what to remember"], "回想记忆", "Recalling")
        add(["render_ui", "present_cgui_v1"], "rectangle.on.rectangle", ["正在准备卡片"], ["Preparing a card"], "准备卡片", "Preparing card", "请在卡片上选择", "Choose on the card")
        add(["delegate_task", "delegate_plan_v1"], "list.bullet.rectangle", ["正在拆解任务"], ["Breaking the task down"], "拆解任务", "Planning")
        add(["agent_status"], "list.bullet.rectangle", ["正在查任务进展"], ["Checking task progress"], "查看进展", "Checking progress")
        add(["revise_current_report_v1", "revise_current_work_v1"], "pencil", ["正在修改报告"], ["Revising the report"], "修改报告", "Revising")
        add(["external_write"], "arrow.up.forward.app", ["正在准备外部操作"], ["Preparing an external action"], "外部操作", "External action", "等你确认", "Waiting for you")
        return t
    }()
    /// Memory tools are copy-covered even before the Mac integration adds them to the allowlist.
    static let memoryTools = ["memory_search", "memory_save", "memory_update", "memory_forget"]
    /// Unknown ids: name-pattern fallback for the symbol only (SPEC §2: *search* / *fetch* / *browse*); copy stays generic.
    static func entry(_ tool: String) -> ToolStepCopy { table[tool] ?? generic }
    static func title(_ tool: String, en: Bool = false) -> String { title(tool, occurrence: 0, en: en) }
    static func title(_ tool: String, occurrence: Int, en: Bool = false) -> String {
        let e = entry(tool), r = en ? e.runningEN : e.running
        return r[max(0, occurrence) % r.count]
    }
    static func short(_ tool: String, en: Bool = false) -> String { let e = entry(tool); return en ? e.shortEN : e.short }
    static func symbol(_ tool: String) -> String {
        if let e = table[tool] { return e.symbol }
        let k = tool.lowercased()
        if k.contains("fetch") || k.contains("browse") { return "doc.text.magnifyingglass" }
        if k.contains("search") { return "magnifyingglass" }
        return generic.symbol
    }
    static func confirmTitle(_ tool: String?, en: Bool = false) -> String {
        let e = tool.flatMap { table[$0] }
        return (en ? e?.confirmEN : e?.confirm) ?? (en ? generic.confirmEN! : generic.confirm!)
    }
}

extension ToolStepCopy {
    /// status-line visual SPEC v2 §2.3: 7.5pt badge glyphs. Base / .fill symbols only (.badge.plus variants turn to mush).
    static func badgeSymbol(_ tool: String) -> String {
        switch tool {
        case "calendar_list", "calendar_create", "create_calendar_event", "update_calendar_event": return "calendar"
        case "reminder_create", "create_reminder", "update_reminder": return "bell.fill"
        case "alarm_set": return "alarm.fill"
        case "places_search": return "mappin"
        case "maps_open": return "map.fill"
        case "web_search": return "magnifyingglass"
        case "delegate_sources_v1": return "link"
        case "contacts_search": return "person.fill"
        case "mail_compose": return "envelope.fill"
        case "sms_compose": return "message.fill"
        case "revise_current_report_v1", "revise_current_work_v1": return "pencil"
        case "list_tasks", "create_task", "update_task": return "checklist"
        case "memory_search", "memory_save", "memory_update", "propose_memory_v1": return "brain"
        case "memory_forget": return "trash.fill"
        case "delegate_task", "delegate_plan_v1", "agent_status": return "list.bullet"
        case "render_ui", "present_cgui_v1": return "square.grid.2x2.fill"
        case "phone_call": return "phone.fill"
        case "shop_open": return "bag.fill"
        case "shortcut_run": return "square.stack.3d.up.fill"
        case "external_write": return "arrow.up.forward"
        default:
            let k = tool.lowercased()
            if k.contains("fetch") || k.contains("browse") { return "link" }
            if k.contains("search") { return "magnifyingglass" }
            return "ellipsis"
        }
    }
    /// Writing-pose tools (SPEC v2 §2.1: compose tools and report revise use the Writing kitten).
    static let writingTools: Set<String> = ["mail_compose", "sms_compose", "revise_current_report_v1", "revise_current_work_v1"]
}
