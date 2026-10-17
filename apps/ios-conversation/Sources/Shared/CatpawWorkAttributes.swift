import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the app target and the `CatpawWidgets` extension.
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

/// status-line v1.0 (harness-brainstorm §4.5): ONE copy table for every tool the app can see, shared by the chat status
/// row (ThinkingHeader), the step list glyphs and the Live Activity. Copy names only the tool type and a generic object —
/// never arguments or reasoning. Tool copy is literal; playful variants exist only for tool-less phases (StatusLineCopy).
struct ToolStepCopy: Equatable, Sendable {
    /// Running copy; variants rotate only when the same tool is entered again (no fake carousel).
    let running: [String]
    let symbol: String
    /// Copy while a confirmation card for this tool is pending; nil = this tool never shows a card.
    let confirm: String?

    static let generic = ToolStepCopy(running: ["正在处理"], symbol: "sparkle", confirm: "等你确认")
    static let table: [String: ToolStepCopy] = {
        var t: [String: ToolStepCopy] = [:]
        func add(_ names: [String], _ running: [String], _ symbol: String, _ confirm: String?) { for n in names { t[n] = ToolStepCopy(running: running, symbol: symbol, confirm: confirm) } }
        add(["calendar_list"], ["正在查看你的日程", "正在翻日历"], "calendar", nil)
        add(["calendar_create", "create_calendar_event"], ["正在准备日程", "正在排进日历"], "calendar.badge.plus", "等你确认日程")
        add(["update_calendar_event"], ["正在调整日程"], "calendar.badge.clock", "等你确认修改")
        add(["reminder_create", "create_reminder"], ["正在准备提醒"], "bell.badge", "等你确认提醒")
        add(["update_reminder"], ["正在调整提醒"], "bell", "等你确认修改")
        add(["alarm_set"], ["正在定闹钟"], "alarm", "等你确认闹钟")
        add(["places_search"], ["正在找附近的地方", "正在看看周边"], "mappin.and.ellipse", nil)
        add(["maps_open"], ["正在规划路线"], "map", "等你确认打开地图")
        add(["contacts_search"], ["正在找联系人"], "person.crop.circle", "等你允许查找")
        add(["mail_compose"], ["正在起草邮件"], "envelope", "等你确认草稿")
        add(["sms_compose"], ["正在起草短信"], "message", "等你确认草稿")
        add(["phone_call"], ["正在准备拨号"], "phone", "等你确认拨打")
        add(["shop_open"], ["正在准备购物搜索"], "bag", "等你确认打开")
        add(["shortcut_run"], ["正在准备快捷指令"], "square.stack.3d.up", "等你确认运行")
        add(["list_tasks"], ["正在看你的待办"], "checklist", nil)
        add(["create_task", "update_task"], ["正在整理待办"], "checklist", "等你确认待办")
        add(["memory_search"], ["正在回想你说过的事"], "brain", nil)
        add(["memory_save", "memory_update"], ["正在记下来"], "brain.head.profile", nil)
        add(["memory_forget"], ["正在找要忘记的记忆"], "trash", "等你确认删除")
        add(["propose_memory_v1"], ["正在整理可记住的内容"], "brain", nil)
        add(["render_ui", "present_cgui_v1"], ["正在准备卡片"], "rectangle.on.rectangle", "请在卡片上选择")
        add(["delegate_task", "delegate_plan_v1"], ["正在拆解任务", "正在一点点推进"], "list.bullet.rectangle", nil)
        add(["delegate_sources_v1"], ["正在阅读你给的链接"], "doc.text.magnifyingglass", nil)
        add(["agent_status"], ["正在查任务进展"], "clock.arrow.circlepath", nil)
        add(["revise_current_report_v1", "revise_current_work_v1"], ["正在修改报告"], "pencil", nil)
        add(["external_write"], ["正在准备外部操作"], "arrow.up.forward.app", "等你确认")
        add(["web_search"], ["正在搜索网页"], "magnifyingglass", nil)
        return t
    }()
    /// Memory tools are copy-covered even before the Mac integration adds them to the allowlist.
    static let memoryTools = ["memory_search", "memory_save", "memory_update", "memory_forget"]
    static func entry(_ tool: String) -> ToolStepCopy { table[tool] ?? generic }
    static func title(_ tool: String) -> String { entry(tool).running[0] }
    static func title(_ tool: String, occurrence: Int) -> String { let r = entry(tool).running; return r[max(0, occurrence) % r.count] }
    static func symbol(_ tool: String) -> String { entry(tool).symbol }
    static func confirmTitle(_ tool: String?) -> String { tool.flatMap { table[$0]?.confirm } ?? "等你确认" }
}
