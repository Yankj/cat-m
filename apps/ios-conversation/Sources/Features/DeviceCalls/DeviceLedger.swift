import SwiftUI
import EventKit

/// Local ledger of things Catpaw created on this phone (EventKit reminders / calendar events), shown in 任务 next to
/// server tasks with a "本机" source tag and an undo. Stored in Application Support; never synced.
struct DeviceLedgerEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case reminder, event }
    let id: String          // call_id
    let kind: Kind
    let itemID: String      // EKReminder.calendarItemIdentifier / EKEvent.eventIdentifier
    let title: String
    let due: Date?
    let createdAt: Date
    var undone: Bool = false
}

@MainActor final class DeviceLedger: ObservableObject {
    static let shared = DeviceLedger()
    @Published private(set) var entries: [DeviceLedgerEntry] = []
    private let url: URL = {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("catpaw-device-ledger.json")
    }()
    private let store = EKEventStore()

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([DeviceLedgerEntry].self, from: data) { entries = saved }
    }
    var active: [DeviceLedgerEntry] { entries.filter { !$0.undone }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }

    /// Called after a successful device call; ignores tools that don't create a durable item.
    func record(call: DeviceCall, result: DeviceCallResult) {
        guard result.status == .ok, !entries.contains(where: { $0.id == call.call_id }) else { return }
        let kind: DeviceLedgerEntry.Kind, item: String, dueKey: String
        switch call.tool {
        case "reminder_create", "alarm_set": kind = .reminder; item = result.data?["reminder_id"]?.text ?? ""; dueKey = call.tool == "alarm_set" ? "time" : "due"
        case "calendar_create": kind = .event; item = result.data?["event_id"]?.text ?? ""; dueKey = "start"
        default: return
        }
        guard !item.isEmpty else { return }
        let args = call.args
        let title = args["title"]?.text ?? args["label"]?.text ?? ""
        entries.append(.init(id: call.call_id, kind: kind, itemID: item, title: title, due: Self.date(args[dueKey]?.text), createdAt: Date()))
        save()
    }

    /// Removes the EventKit item Catpaw created. Returns false if it could not be removed (already gone counts as success).
    @discardableResult func undo(_ entry: DeviceLedgerEntry) -> Bool {
        var ok = true
        switch entry.kind {
        case .reminder: if let r = store.calendarItem(withIdentifier: entry.itemID) as? EKReminder { do { try store.remove(r, commit: true) } catch { ok = false } }
        case .event: if let e = store.event(withIdentifier: entry.itemID) { do { try store.remove(e, span: .thisEvent, commit: true) } catch { ok = false } }
        }
        if ok, let i = entries.firstIndex(of: entry) { entries[i].undone = true; save() }
        return ok
    }

    func entry(callID: String) -> DeviceLedgerEntry? { entries.first { $0.id == callID } }
    func isUndone(callID: String) -> Bool { entry(callID: callID)?.undone == true }
    /// Chat-UX #6: delete what this call_id created. Same EventKit path as `undo(_:)`, with a precise outcome for the model.
    func undo(callID: String) -> DeviceUndoOutcome {
        guard let entry = entry(callID: callID) else { return .alreadyGone }
        if entry.undone { return .alreadyGone }
        let found: Bool
        switch entry.kind {
        case .reminder: found = store.calendarItem(withIdentifier: entry.itemID) is EKReminder
        case .event: found = store.event(withIdentifier: entry.itemID) != nil
        }
        let outcome = DeviceUndoRules.outcome(found: found, deleted: undo(entry))
        return outcome
    }

    private func save() { if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) } }
    nonisolated static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s)
    }
}

/// 任务 rows for the ledger: icon · title · due · "本机" tag · 撤销.
@MainActor struct DeviceLedgerSection: View {
    @ObservedObject private var ledger = DeviceLedger.shared
    @State private var failed: String?
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    var body: some View {
        if !ledger.active.isEmpty {
            Section {
                ForEach(ledger.active) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.kind == .reminder ? "checklist" : "calendar").foregroundStyle(CatpawColors.action).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(CatpawTypography.Role.body.font)
                            HStack(spacing: 6) {
                                Text(ui(entry.kind == .reminder ? "本机提醒" : "本机日程"))
                                    .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.actionText)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(CatpawColors.action.opacity(0.1), in: Capsule())
                                if let due = entry.due { Text(due.formatted(date: .abbreviated, time: .shortened)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
                            }
                        }
                        Spacer(minLength: 0)
                        Button(ui("撤销")) { if !ledger.undo(entry) { failed = entry.id } }
                            .font(CatpawTypography.Role.secondary.font).buttonStyle(.borderless)
                            .accessibilityIdentifier("tasks.device.undo." + entry.id)
                    }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("tasks.device." + entry.id)
                    if failed == entry.id { Text(ui("撤销未完成，请在系统 App 中删除。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention) }
                }
            } header: { Text(ui("Catpaw 在本机创建的")) }
        }
    }
}
