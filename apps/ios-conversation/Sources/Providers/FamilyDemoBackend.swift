#if DEBUG
import Foundation

/// DEBUG-only in-memory family backend. The catpaw.family.v1 API is not deployed yet, so the
/// family entry renders sample data (labelled 「示例数据」) instead of calling missing prod endpoints.
public actor FamilyDemoBackend: FamilyBackend {
    private let hh = UUID()
    private let kid = UUID()
    private var rev = 1
    private var schedule: [FamilyScheduleEntry] = []
    private var pending: [FamilyPendingConfirmation] = []
    private var children: [FamilyChild] = []
    private var memories: [FamilyMemory] = []
    private var observations: [FamilyObservation] = []
    private var settings = FamilySettings(memory_paused: false, reminders_paused: false, revision: 1)
    private var reminders: [FamilyReminder] = []

    public init() {
        let today = Self.date(0), tomorrow = Self.date(1)
        children = [FamilyChild(member_id: kid, display_name: "朵朵", birth_year: 2019, school_label: "示例小学", class_label: "一年级(2)班", teacher_label: "王老师", place_label: nil, notes: nil, revision: 1)]
        let s1 = UUID()
        schedule = [FamilyScheduleEntry(item_id: s1, revision: 1, title: "游泳课（示例数据）", status: "scheduled", member_id: kid, child_display_name: "朵朵", local_date: today, local_time: "16:30", timezone: "Asia/Shanghai", place: "社区游泳馆", bring: ["泳镜", "毛巾"])]
        pending = [FamilyPendingConfirmation(item_id: UUID(), revision: 1, proposal_id: UUID(), title: "春游（示例数据）", member_id: kid, child_display_name: "朵朵", local_date: tomorrow, local_time: "08:00", place: "植物园", bring: ["水壶", "帽子"], source_kind: "text")]
        reminders = [FamilyReminder(reminder_id: UUID(), item_id: s1, kind: "bring", why_now: "出门前记得带泳镜", fire_at: today + "T15:30:00+08:00", revision: 1)]
        memories = [FamilyMemory(memory_id: UUID(), member_id: kid, text: "朵朵对芒果过敏（示例数据）", source: FamilySource(source_kind: "text", source_ref: "demo", captured_at: nil), revision: 1)]
        observations = [FamilyObservation(observation_id: UUID(), member_id: kid, text: "最近很喜欢画画（示例数据）", observed_on: today, revision: 1)]
    }
    static func date(_ offset: Int) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(Double(offset) * 86_400))
    }
    public func bootstrap() async throws -> [UUID] { [hh] }
    public func ensureHousehold(name: String) async throws -> UUID { hh }
    public func projection(_ household: UUID, localDate: String?) async throws -> FamilyProjection {
        FamilyProjection(protocol_: FamilyProtocol.name, household_id: hh, projection_revision: rev, local_date: localDate ?? Self.date(0), timezone: "Asia/Shanghai",
                         today: .init(schedule: schedule, pending_confirmations: pending, reminders: reminders),
                         home: .init(household: FamilyHousehold(household_id: hh, name: "我们家（示例数据）", timezone: "Asia/Shanghai", revision: 1),
                                     children: children, memories: memories, observations: observations, settings: settings))
    }
    private func ok(_ c: FamilyCommand, _ type: String, _ id: UUID) -> FamilyReceipt {
        rev += 1; return FamilyReceipt(command_id: c.command_id, status: "applied", objects: [.init(type: type, id: id, revision: rev)], error: nil)
    }
    public func command(_ c: FamilyCommand) async throws -> FamilyReceipt {
        let t = c.target_id ?? hh
        switch c.type {
        case "item.confirm":
            if let i = pending.firstIndex(where: { $0.item_id == t }) {
                let p = pending.remove(at: i)
                schedule.append(FamilyScheduleEntry(item_id: p.item_id, revision: p.revision + 1, title: p.title, status: "scheduled", member_id: p.member_id, child_display_name: p.child_display_name, local_date: p.local_date, local_time: p.local_time, timezone: "Asia/Shanghai", place: p.place, bring: p.bring))
            }
        case "item.cancel": pending.removeAll { $0.item_id == t }
        case "memory.delete": memories.removeAll { $0.memory_id == t }
        case "memory.pause": if case .bool(let v)? = c.payload?["paused"] { settings = FamilySettings(memory_paused: v, reminders_paused: settings.reminders_paused, revision: settings.revision + 1) }
        case "reminder.pause": if case .bool(let v)? = c.payload?["paused"] { settings = FamilySettings(memory_paused: settings.memory_paused, reminders_paused: v, revision: settings.revision + 1) }
        default: break
        }
        return ok(c, c.type.components(separatedBy: ".").first ?? "item", t)
    }
    public func captureText(_ household: UUID, captureID: UUID, text: String) async throws -> FamilyCaptureResponse {
        let item = UUID(), proposal = UUID(), title = String(text.prefix(20))
        pending.append(FamilyPendingConfirmation(item_id: item, revision: 1, proposal_id: proposal, title: title, member_id: kid, child_display_name: "朵朵", local_date: Self.date(1), local_time: nil, place: nil, bring: [], source_kind: "text"))
        rev += 1
        let r = FamilyReceipt(command_id: captureID, status: "applied", objects: [.init(type: "item", id: item, revision: 1)], error: nil)
        return FamilyCaptureResponse(capture_id: captureID, cards: [FamilyCaptureCard(receipt: r, item_id: item, proposal_id: proposal, candidate: .init(title: title, local_date: Self.date(1), local_time: nil, member_id: kid, place: nil, bring: [], missing: ["local_time"]))])
    }
    public func capturePhoto(_ household: UUID, captureID: UUID, jpeg: Data) async throws -> FamilyCaptureResponse {
        try await captureText(household, captureID: captureID, text: "图片里的通知（示例数据）")
    }
}
#endif
