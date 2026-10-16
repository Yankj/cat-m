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
    /// Codex p89c: owning account (AccountEpoch account id). Legacy entries without one are never shown or undone.
    var account: String? = nil
}

/// EventKit removal seam (tests inject a fake; the app uses EKEventStore).
@MainActor protocol DeviceLedgerItemStore: AnyObject {
    /// nil = item not found; true = removed; false = removal failed.
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> Bool?
}
@MainActor final class EventKitLedgerItemStore: DeviceLedgerItemStore {
    private let store = EKEventStore()
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> Bool? {
        switch kind {
        case .reminder:
            guard let r = store.calendarItem(withIdentifier: itemID) as? EKReminder else { return nil }
            do { try store.remove(r, commit: true); return true } catch { return false }
        case .event:
            guard let e = store.event(withIdentifier: itemID) else { return nil }
            do { try store.remove(e, span: .thisEvent, commit: true); return true } catch { return false }
        }
    }
}

/// Codex p89c (shared with #91): per-account local ledger.
/// - Every entry carries its account; `active` / `entry(callID:)` only ever expose the signed-in account's entries.
/// - `record` takes the AccountToken captured BEFORE the device call and writes through `AccountEpoch.commit`, so a result
///   that returns after sign-out / switch is dropped.
/// - `undo` deletes only for the signed-in account, inside `commit`; anything uncertain returns `.unknown`.
/// - `signOut(account:)` purges that account's entries from memory and disk.
@MainActor final class DeviceLedger: ObservableObject {
    static let shared = DeviceLedger()
    @Published private(set) var entries: [DeviceLedgerEntry] = []
    private let url: URL
    private let epoch: AccountEpoch
    private let items: DeviceLedgerItemStore

    init(url: URL? = nil, epoch: AccountEpoch = .shared, items: DeviceLedgerItemStore? = nil) {
        self.url = url ?? {
            let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
            return dir.appendingPathComponent("catpaw-device-ledger.json")
        }()
        self.epoch = epoch; self.items = items ?? EventKitLedgerItemStore()
        if let data = try? Data(contentsOf: self.url), let saved = try? JSONDecoder().decode([DeviceLedgerEntry].self, from: data) { entries = saved.filter { $0.account != nil } }
    }
    private func mine(_ e: DeviceLedgerEntry) -> Bool { e.account != nil && e.account == epoch.currentAccount }
    var active: [DeviceLedgerEntry] { entries.filter { mine($0) && !$0.undone }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }

    /// Called after a successful device call; ignores tools that don't create a durable item.
    /// `token`: captured before the call ran; nil or stale → nothing is recorded.
    func record(call: DeviceCall, result: DeviceCallResult, token: AccountToken?) {
        guard result.status == .ok, let token else { return }
        let kind: DeviceLedgerEntry.Kind, item: String, dueKey: String
        switch call.tool {
        case "reminder_create", "alarm_set": kind = .reminder; item = result.data?["reminder_id"]?.text ?? ""; dueKey = call.tool == "alarm_set" ? "time" : "due"
        case "calendar_create": kind = .event; item = result.data?["event_id"]?.text ?? ""; dueKey = "start"
        default: return
        }
        guard !item.isEmpty else { return }
        let args = call.args
        let title = args["title"]?.text ?? args["label"]?.text ?? ""
        epoch.commit(token) {
            guard !entries.contains(where: { $0.id == call.call_id && $0.account == token.account }) else { return }
            entries.append(.init(id: call.call_id, kind: kind, itemID: item, title: title, due: Self.date(args[dueKey]?.text), createdAt: Date(), account: token.account))
            save()
        }
    }

    /// 任务 row 撤销. Returns true only when the item is known to be gone.
    @discardableResult func undo(_ entry: DeviceLedgerEntry) -> Bool { undo(callID: entry.id).removed }

    func entry(callID: String) -> DeviceLedgerEntry? { entries.first { $0.id == callID && mine($0) } }
    func isUndone(callID: String) -> Bool { entry(callID: callID)?.undone == true }
    /// Chat-UX #6: delete what this call_id created, for the signed-in account only.
    func undo(callID: String) -> DeviceUndoOutcome {
        guard let token = epoch.capture(), let entry = entry(callID: callID) else { return .unknown }   // other account / signed out / never recorded
        if entry.undone { return .alreadyGone }
        let outcome: DeviceUndoOutcome? = epoch.commit(token) {
            let removed = items.remove(kind: entry.kind, itemID: entry.itemID)
            let o: DeviceUndoOutcome = removed == nil ? .alreadyGone : removed == true ? .undone : .failed
            if o.removed, let i = entries.firstIndex(where: { $0.id == entry.id && $0.account == token.account }) { entries[i].undone = true; save() }
            return o
        }
        return outcome ?? .unknown
    }
    /// Sign-out: the account's local ledger is cleared (memory + disk).
    func signOut(account: String?) {
        guard let account else { return }
        entries.removeAll { $0.account == account }; save()
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
