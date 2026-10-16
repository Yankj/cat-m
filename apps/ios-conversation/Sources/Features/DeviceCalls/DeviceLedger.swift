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

/// Outcome of trying to remove a ledger item from the OS store (Codex p89d-5: "not found" is only claimed when the store
/// could actually be read; no permission / read failure is `.undetermined`, never "already gone").
enum DeviceLedgerRemoval: Equatable { case removed, notFound, removeFailed, permissionRevoked, undetermined }
/// EventKit removal seam (tests inject a fake; the app uses EKEventStore).
@MainActor protocol DeviceLedgerItemStore: AnyObject {
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> DeviceLedgerRemoval
    /// p89e-3: the ledger calls this one (call id available for a marker lookup); default forwards to the id-only form.
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval
    /// p89g-3: marker lookup with the recorded identity (title / due) so a copy can never be taken for the original.
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, title: String, due: Date?) -> DeviceLedgerRemoval
}
extension DeviceLedgerItemStore {
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval { remove(kind: kind, itemID: itemID) }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, title: String, due: Date?) -> DeviceLedgerRemoval { remove(kind: kind, itemID: itemID, callID: callID) }
}
/// p89e-3: an identifier that no longer resolves does NOT prove the item is gone (EventKit ids change when an item moves
/// calendar / re-syncs — EKEvent.h). The real adapter therefore never reports `.notFound`:
/// - id resolves → remove it;
/// - events: id misses → search the call marker (our notes) in a ±400-day window; remove only when EXACTLY ONE event carries
///   the marker AND it matches the recorded identity (title, start == due). A user copy keeps our notes, so several matches
///   (or an identity mismatch) are ambiguous → `.undetermined` (p89g-3: never delete a guess, never mark undone);
/// - anything else (reminder id miss, marker not found, no permission, no readable calendars) → `.undetermined` / `.permissionRevoked`
///   → the ledger keeps `.unknown` (never "already gone", never marked undone).
@MainActor final class EventKitLedgerItemStore: DeviceLedgerItemStore {
    private let store: EKEventStore
    init(store: EKEventStore = EKEventStore()) { self.store = store }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> DeviceLedgerRemoval { remove(kind: kind, itemID: itemID, callID: nil) }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval { remove(kind: kind, itemID: itemID, callID: Optional(callID)) }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, title: String, due: Date?) -> DeviceLedgerRemoval {
        remove(kind: kind, itemID: itemID, callID: Optional(callID), identity: (title, due))
    }
    private func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String?, identity: (title: String, due: Date?)? = nil) -> DeviceLedgerRemoval {
        let type: EKEntityType = kind == .reminder ? .reminder : .event
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return .permissionRevoked }
        guard !store.calendars(for: type).isEmpty else { return .undetermined }
        switch kind {
        case .reminder:
            guard let r = store.calendarItem(withIdentifier: itemID) as? EKReminder else { return .undetermined }
            do { try store.remove(r, commit: true); return .removed } catch { return .removeFailed }
        case .event:
            var target = store.event(withIdentifier: itemID)
            if target == nil, let callID {
                let marker = DeviceToolContract.callMarker(callID), now = Date()
                let window = store.predicateForEvents(withStart: now.addingTimeInterval(-400 * 86400), end: now.addingTimeInterval(400 * 86400), calendars: nil)
                let matches = store.events(matching: window).filter { $0.notes?.contains(marker) == true }
                // p89g-3: unique AND identity-verified, else ambiguous. Without a recorded identity there is no proof.
                guard matches.count == 1, let only = matches.first, let identity else { return .undetermined }
                guard identity.title.isEmpty || only.title == identity.title else { return .undetermined }
                if let due = identity.due { guard let start = only.startDate, abs(start.timeIntervalSince(due)) < 1 else { return .undetermined } }
                target = only
            }
            guard let e = target else { return .undetermined }
            do { try store.remove(e, span: .thisEvent, commit: true); return .removed } catch { return .removeFailed }
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
            let o: DeviceUndoOutcome
            switch items.remove(kind: entry.kind, itemID: entry.itemID, callID: entry.id, title: entry.title, due: entry.due) {
            case .removed: o = .undone
            case .notFound: o = .alreadyGone
            case .removeFailed: o = .failed
            case .permissionRevoked, .undetermined: o = .unknown   // can't tell → never marked undone, never reported
            }
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
