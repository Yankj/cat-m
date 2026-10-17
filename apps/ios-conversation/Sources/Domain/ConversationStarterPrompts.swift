import Foundation

/// Empty-conversation starter prompts (feat/chat-starter-prompts). Each one maps to a capability the app runs end to end
/// from a single chat message (device.v1 tools / task tools / plain chat). `title` and `prompt` are UIStrings.json keys
/// (zh-Hans source text); the view localizes them. Foundation-only so ordering is unit-testable.
struct ConversationStarterPrompt: Identifiable, Equatable, Sendable {
    enum Capability: String, Sendable {
        case calendarRead     // calendar_list — read-only, auto-runs after calendar permission
        case reminderCreate   // reminder_create (confirm card) / create_task
        case calendarCreate   // calendar_create (confirm card); a located meeting ≤3h away feeds the leave-time suggestion
        case nearbyPlaces     // places_search — MapKit ETA list, auto-runs after location permission
        case taskBreakdown    // plain chat / task plan
        case writing          // plain chat drafting
    }
    let id: String
    let title: String
    let prompt: String
    let symbol: String
    let capability: Capability
}

enum ConversationStarterPrompts {
    static let schedule = ConversationStarterPrompt(id: "schedule", title: "今天的日程", prompt: "帮我看看今天的日程，有什么要提前准备？", symbol: "calendar", capability: .calendarRead)
    static let reminder = ConversationStarterPrompt(id: "reminder", title: "设个提醒", prompt: "明天上午 10 点提醒我给客户回电话", symbol: "bell", capability: .reminderCreate)
    static let meeting = ConversationStarterPrompt(id: "meeting", title: "加个会议", prompt: "1 小时后在望京 SOHO 开评审会，加进日历", symbol: "calendar.badge.plus", capability: .calendarCreate)
    static let nearby = ConversationStarterPrompt(id: "nearby", title: "附近咖啡馆", prompt: "附近有哪些适合办公的咖啡馆？", symbol: "cup.and.saucer", capability: .nearbyPlaces)
    static let breakdown = ConversationStarterPrompt(id: "breakdown", title: "拆解任务", prompt: "把「下周上线新版本」拆成待办清单", symbol: "checklist", capability: .taskBreakdown)
    static let writing = ConversationStarterPrompt(id: "writing", title: "起草周报", prompt: "帮我起草周报：本周进展、风险、下周计划", symbol: "doc.text", capability: .writing)
    static let all: [ConversationStarterPrompt] = [schedule, reminder, meeting, nearby, breakdown, writing]

    enum DayPart: Equatable, Sendable { case morning, afternoon, evening }
    static func dayPart(hour: Int) -> DayPart {
        switch hour {
        case 5..<11: .morning
        case 11..<17: .afternoon
        default: .evening
        }
    }
    /// Time-of-day order (first row = most useful now): morning leads with today's schedule, afternoon with the
    /// meeting / leave-time chain, evening with tomorrow's reminder. Always the same six prompts.
    static func ordered(hour: Int) -> [ConversationStarterPrompt] {
        switch dayPart(hour: hour) {
        case .morning: [schedule, reminder, meeting, nearby, breakdown, writing]
        case .afternoon: [meeting, schedule, nearby, reminder, breakdown, writing]
        case .evening: [reminder, schedule, breakdown, meeting, writing, nearby]
        }
    }
    static func ordered(at date: Date = Date(), calendar: Calendar = .current) -> [ConversationStarterPrompt] {
        ordered(hour: calendar.component(.hour, from: date))
    }
}
