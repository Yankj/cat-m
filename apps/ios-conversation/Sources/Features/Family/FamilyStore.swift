import Foundation
import SwiftUI

/// One view model for 今天 / 确认卡 / 我们家: every screen renders the same server projection.
/// Local state never promotes an item to "已安排"; only a refreshed projection does (api-v1 §9).
@MainActor
public final class FamilyStore: ObservableObject {
    public enum Phase: Equatable { case idle, loading, ready, unavailable, failed(String) }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var projection: FamilyProjection?
    @Published public private(set) var lastCards: [FamilyCaptureCard] = []
    @Published public private(set) var busyItem: UUID?
    @Published public var notice: String?
    private let backend: any FamilyBackend
    private var household: UUID?
    public init(backend: any FamilyBackend) { self.backend = backend }

    public static func today(_ tz: String = "Asia/Shanghai") -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    public func load(date: String? = nil) async {
        phase = projection == nil ? .loading : phase
        do {
            if household == nil {
                let ids = try await backend.bootstrap()
                household = ids.first
                if household == nil { household = try await backend.ensureHousehold(name: "我们家") }
            }
            guard let hh = household else { phase = .unavailable; return }
            let next = try await backend.projection(hh, localDate: date ?? Self.today(projection?.timezone ?? "Asia/Shanghai"))
            // never let an older response overwrite a newer one
            if let cur = projection, cur.local_date == next.local_date, cur.projection_revision > next.projection_revision { return }
            projection = next; phase = .ready
        } catch FamilyError.notFound { phase = .unavailable } catch FamilyError.unavailable { phase = .unavailable } catch { phase = .failed("暂时连不上，稍后再试") }
    }

    public func capture(text: String) async {
        guard let hh = household, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { lastCards = try await backend.captureText(hh, captureID: UUID(), text: text).cards; await load(date: projection?.local_date) }
        catch { notice = "没能整理这段话，原文还在，可以再试一次" }
    }
    public func capture(photoJPEG: Data) async {
        guard let hh = household else { return }
        do { lastCards = try await backend.capturePhoto(hh, captureID: UUID(), jpeg: photoJPEG).cards; await load(date: projection?.local_date) }
        catch FamilyError.rejected(let code) where code == "capability_unavailable" { notice = "识别通知图片暂未开放" }
        catch { notice = "这张图片没能读出来" }
    }

    public func confirm(_ p: FamilyPendingConfirmation) async {
        await run(p.item_id, FamilyCommand(type: "item.confirm", household: projection!.household_id, target: p.item_id, expectedRevision: p.revision, proposal: p.proposal_id))
    }
    public func dismiss(_ p: FamilyPendingConfirmation) async {
        await run(p.item_id, FamilyCommand(type: "item.cancel", household: projection!.household_id, target: p.item_id, expectedRevision: p.revision))
    }
    public func correct(_ p: FamilyPendingConfirmation, title: String, bring: [String]) async {
        await run(p.item_id, FamilyCommand(type: "item.correct", household: projection!.household_id, target: p.item_id, expectedRevision: p.revision,
                                           payload: ["title": .string(title), "bring": .array(bring.map { .string($0) })]))
    }
    public func correctMemory(_ m: FamilyMemory, text: String) async {
        await run(m.memory_id, FamilyCommand(type: "memory.correct", household: projection!.household_id, target: m.memory_id, expectedRevision: m.revision, payload: ["text": .string(text)]))
    }
    public func deleteMemory(_ m: FamilyMemory) async {
        await run(m.memory_id, FamilyCommand(type: "memory.delete", household: projection!.household_id, target: m.memory_id, expectedRevision: m.revision))
    }
    public func setPaused(memory: Bool? = nil, reminders: Bool? = nil) async {
        guard let p = projection, let s = p.home.settings else { return }
        if let v = memory { await run(p.household_id, FamilyCommand(type: "memory.pause", household: p.household_id, expectedRevision: s.revision, payload: ["paused": .bool(v)])) }
        if let v = reminders { await run(p.household_id, FamilyCommand(type: "reminder.pause", household: p.household_id, expectedRevision: s.revision, payload: ["paused": .bool(v)])) }
    }
    public func saveChild(_ c: FamilyChild?, name: String, school: String?, klass: String?, teacher: String?) async {
        guard let p = projection else { return }
        var payload: [String: FamilyJSON] = ["display_name": .string(name)]
        payload["school_label"] = school.map { .string($0) } ?? .null
        payload["class_label"] = klass.map { .string($0) } ?? .null
        payload["teacher_label"] = teacher.map { .string($0) } ?? .null
        await run(c?.member_id ?? p.household_id, FamilyCommand(type: "child.upsert", household: p.household_id, target: c?.member_id, expectedRevision: c?.revision, payload: payload))
    }
    public func deleteChild(_ c: FamilyChild) async {
        await run(c.member_id, FamilyCommand(type: "child.delete", household: projection!.household_id, target: c.member_id, expectedRevision: c.revision))
    }

    private func run(_ busy: UUID, _ cmd: FamilyCommand) async {
        busyItem = busy; defer { busyItem = nil }
        do {
            let r = try await backend.command(cmd)
            if !r.applied { notice = Self.message(r.error?.code) }
        } catch FamilyError.outcomeUnknown { notice = "网络断了，结果还不确定，正在核对" }
        catch FamilyError.conflict(let c) { notice = Self.message(c) }
        catch { notice = "暂时没保存，稍后再试" }
        await load(date: projection?.local_date)   // the projection, not the tap, decides what is shown
    }
    static func message(_ code: String?) -> String {
        switch code {
        case "revision_conflict", "proposal_closed": return "内容刚被更新过，已刷新，请再看一眼"
        case "confirmation_required": return "需要你先确认这件事"
        case "quiet_hours": return "21:00–08:00 不打扰，换个时间吧"
        case "daily_limit": return "今天的提醒已经够多了"
        case "memory_paused": return "记忆已暂停"
        default: return "这一步没有完成"
        }
    }
}
