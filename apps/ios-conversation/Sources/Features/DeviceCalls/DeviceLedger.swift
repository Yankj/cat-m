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
    /// p89h-2: identity read back from the object actually saved / matched (not the call args). nil → undo can't verify → unknown.
    var saved: DeviceSavedIdentity? = nil
}

/// Outcome of trying to remove a ledger item from the OS store (Codex p89d-5: "not found" is only claimed when the store
/// could actually be read; no permission / read failure is `.undetermined`, never "already gone").
enum DeviceLedgerRemoval: Equatable { case removed, notFound, removeFailed, permissionRevoked, undetermined }
/// p89i-3: undo is two-phase. `prepareRemoval` runs the (possibly slow, async) EventKit queries OUTSIDE the account lock and
/// off any synchronous wait; it returns either a decided outcome or a short synchronous `apply` that the ledger runs inside
/// `AccountEpoch.commit` (re-resolve by id + re-verify, then delete). Sign-out / switch during the query → commit refuses.
enum DeviceLedgerRemovalPlan { case decided(DeviceLedgerRemoval); case ready(@MainActor () -> DeviceLedgerRemoval) }
/// EventKit removal seam (tests inject a fake; the app uses EKEventStore).
@MainActor protocol DeviceLedgerItemStore: AnyObject {
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> DeviceLedgerRemoval
    /// p89e-3: the ledger calls this one (call id available for a marker lookup); default forwards to the id-only form.
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval
    /// p89g-3: marker lookup with the recorded identity (title / due) so a copy can never be taken for the original.
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, title: String, due: Date?) -> DeviceLedgerRemoval
    /// p89h-2: identity-verified removal; `identity` is the persisted saved-object identity (nil = unverifiable).
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) -> DeviceLedgerRemoval
    /// p89i-3: async query phase; default = the synchronous form applied inside the commit (fakes).
    func prepareRemoval(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) async -> DeviceLedgerRemovalPlan
    /// Product decision (p89i): when the original can't be proven, list every object carrying our marker so the USER picks.
    func candidates(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) async -> [DeviceUndoCandidate]
    /// Delete exactly the object the user chose (must still carry our marker). Synchronous; runs inside `epoch.commit`.
    func removeChosen(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval
}
extension DeviceLedgerItemStore {
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval { remove(kind: kind, itemID: itemID) }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, title: String, due: Date?) -> DeviceLedgerRemoval { remove(kind: kind, itemID: itemID, callID: callID) }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) -> DeviceLedgerRemoval { remove(kind: kind, itemID: itemID, callID: callID) }
    func prepareRemoval(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) async -> DeviceLedgerRemovalPlan {
        .ready { self.remove(kind: kind, itemID: itemID, callID: callID, identity: identity) }
    }
    func candidates(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) async -> [DeviceUndoCandidate] { [] }
    func removeChosen(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval { .undetermined }
}
/// One object carrying the call marker, shown to the user when Catpaw can't prove which one it created.
struct DeviceUndoCandidate: Equatable, Identifiable, Sendable {
    let id: String; let title: String; let start: Date?
    /// The ledger's recorded id (may still be the original even though its identity no longer matches, e.g. moved).
    let isRecorded: Bool
}
/// Result of an undo attempt as the UI needs it. `.needsChoice` / `.needsPermission` are user decisions — never a guess,
/// never a silent skip; the default (dismiss) keeps everything.
enum DeviceUndoAttempt: Equatable {
    case done(DeviceUndoOutcome)
    case needsPermission
    case needsChoice([DeviceUndoCandidate])
    var outcome: DeviceUndoOutcome { if case .done(let o) = self { return o }; return .unknown }
}

/// p89i-1: creation receipt — written in the SAME commit-gated closure as the EventKit save, from the object just saved.
/// It is the ONLY source of a trusted identity for restore / dedupe: a marker match without a receipt, or whose id /
/// identity differ from the receipt, is never trusted (restore → unknown; dedupe → no undo identity / not written again).
struct DeviceCreationReceipt: Codable, Equatable {
    let callID: String; let kind: DeviceLedgerEntry.Kind; let itemID: String; let identity: DeviceSavedIdentity
    let account: String; let createdAt: Date
}
@MainActor final class DeviceCreationReceipts {
    static let shared = DeviceCreationReceipts()
    static let retention: TimeInterval = 30 * 24 * 3600
    private let url: URL
    private(set) var all: [String: DeviceCreationReceipt] = [:]
    init(url: URL? = nil, now: Date = .now) {
        self.url = url ?? {
            let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
            return dir.appendingPathComponent("catpaw-device-receipts.json")
        }()
        if let data = try? Data(contentsOf: self.url), let saved = try? JSONDecoder().decode([String: DeviceCreationReceipt].self, from: data) {
            all = saved.filter { now.timeIntervalSince($0.value.createdAt) < Self.retention }
        }
    }
    func put(_ r: DeviceCreationReceipt) { all[r.callID] = r; save() }
    /// Only the account that created it may use a receipt.
    func receipt(_ callID: String, account: String?) -> DeviceCreationReceipt? {
        guard let r = all[callID], let account, r.account == account else { return nil }
        return r
    }
    func signOut(account: String?) { guard let account else { return }; all = all.filter { $0.value.account != account }; save() }
    private func save() { if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) } }
}

/// p89i-2: explicit EventKit query / uniqueness rule (shared by Router dedupe, restore and ledger undo).
/// - TRUST never comes from a query: only an object whose identifier equals the creation receipt / ledger id AND that
///   carries our call marker AND whose title + start/due equal the identity read back at creation is the original.
///   A copy gets a new identifier, so a copy anywhere (inside or outside any window) can never be deleted or trusted.
/// - Moved object (start / due / title changed by the user) → identity differs → unknown, never deleted.
/// - Uniqueness is an additional refusal, not a source of trust: events are counted in a window of ±`eventWindow` around
///   the SAVED start (not around "now", so far-future events work); reminders are counted over ALL reminders (no window).
///   More than one marked object in that range → ambiguous → unknown. Copies outside the window are not counted, which is
///   safe because they can never pass the identifier check.
enum DeviceEventKitRule {
    static let eventWindow: TimeInterval = 365 * 86400
    static func eventRange(around start: Date) -> (Date, Date) { (start.addingTimeInterval(-eventWindow), start.addingTimeInterval(eventWindow)) }
    static func matches(_ identity: DeviceSavedIdentity, title: String?, start: Date?) -> Bool {
        guard (title ?? "") == identity.title else { return false }
        switch (identity.start, start) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 1
        default: return false
        }
    }
    @MainActor static func markedEvents(_ store: EKEventStore, marker: String, around start: Date) -> [EKEvent] {
        let (a, b) = eventRange(around: start)
        return store.events(matching: store.predicateForEvents(withStart: a, end: b, calendars: nil)).filter { $0.notes?.contains(marker) == true }
    }
    /// All reminders carrying the marker; async callback, never a semaphore wait.
    @MainActor static func markedReminders(_ store: EKEventStore, marker: String) async -> [(id: String, identity: DeviceSavedIdentity)] {
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { rs in
                c.resume(returning: (rs ?? []).filter { $0.notes?.contains(marker) == true }.map { ($0.calendarItemIdentifier, DeviceSavedIdentity(title: $0.title ?? "", start: DeviceSavedIdentity.due($0.dueDateComponents))) })
            }
        }
    }
}

/// p89e-3 / p89h / p89i: real adapter. Never reports `.notFound` (an id that no longer resolves does not prove absence).
/// Deletes only the object resolved by the RECORDED id that carries the marker and matches the persisted identity, and only
/// when the marker is unique under `DeviceEventKitRule`. An id that no longer resolves → `.undetermined` (no marker
/// fallback: a stand-in found by marker is exactly what a user copy looks like).
@MainActor final class EventKitLedgerItemStore: DeviceLedgerItemStore {
    private let store: EKEventStore
    /// p89i-3 test seam: runs after the async query phase, before the plan is returned (tests sign out / edit here).
    var afterQuery: (@MainActor () async -> Void)?
    init(store: EKEventStore = EKEventStore()) { self.store = store }
    // Synchronous forms are never used for real deletion (they would need a blocking reminder query) → undetermined.
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> DeviceLedgerRemoval { .undetermined }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval { .undetermined }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, title: String, due: Date?) -> DeviceLedgerRemoval { .undetermined }
    func remove(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) -> DeviceLedgerRemoval { .undetermined }

    private func access(_ kind: DeviceLedgerEntry.Kind) -> DeviceLedgerRemoval? {
        let type: EKEntityType = kind == .reminder ? .reminder : .event
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return .permissionRevoked }
        guard !store.calendars(for: type).isEmpty else { return .undetermined }
        return nil
    }
    func prepareRemoval(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) async -> DeviceLedgerRemovalPlan {
        if let no = access(kind) { return .decided(no) }
        guard let identity, !itemID.isEmpty else { return .decided(.undetermined) }   // missing identity is never a wildcard
        let marker = DeviceToolContract.callMarker(callID)
        let count: Int
        switch kind {
        case .reminder: count = await DeviceEventKitRule.markedReminders(store, marker: marker).count
        case .event:
            guard let start = identity.start else { return .decided(.undetermined) }
            count = DeviceEventKitRule.markedEvents(store, marker: marker, around: start).count
        }
        if let afterQuery { await afterQuery() }
        guard count == 1 else { return .decided(.undetermined) }   // none in range (moved far / gone) or several (copy)
        return .ready { [self] in self.finalRemove(kind: kind, itemID: itemID, marker: marker, identity: identity) }
    }
    func candidates(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) async -> [DeviceUndoCandidate] {
        guard access(kind) == nil else { return [] }
        let marker = DeviceToolContract.callMarker(callID)
        switch kind {
        case .reminder:
            return await DeviceEventKitRule.markedReminders(store, marker: marker).map { .init(id: $0.id, title: $0.identity.title, start: $0.identity.start, isRecorded: $0.id == itemID) }
        case .event:
            // Recorded object first (wherever it moved), then every marked event around the saved start (or now).
            var out: [DeviceUndoCandidate] = []
            if let e = store.event(withIdentifier: itemID), e.notes?.contains(marker) == true { out.append(.init(id: itemID, title: e.title ?? "", start: e.startDate, isRecorded: true)) }
            for e in DeviceEventKitRule.markedEvents(store, marker: marker, around: identity?.start ?? Date()) where !out.contains(where: { $0.id == e.eventIdentifier }) {
                out.append(.init(id: e.eventIdentifier ?? "", title: e.title ?? "", start: e.startDate, isRecorded: e.eventIdentifier == itemID))
            }
            return out.filter { !$0.id.isEmpty }
        }
    }
    func removeChosen(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String) -> DeviceLedgerRemoval {
        if let no = access(kind) { return no }
        let marker = DeviceToolContract.callMarker(callID)
        switch kind {
        case .reminder:
            guard let r = store.calendarItem(withIdentifier: itemID) as? EKReminder, r.notes?.contains(marker) == true else { return .undetermined }
            do { try store.remove(r, commit: true); return .removed } catch { return .removeFailed }
        case .event:
            guard let e = store.event(withIdentifier: itemID), e.notes?.contains(marker) == true else { return .undetermined }
            do { try store.remove(e, span: .thisEvent, commit: true); return .removed } catch { return .removeFailed }
        }
    }
    /// Runs inside `AccountEpoch.commit`: synchronous, no queries that wait — re-resolve by id and re-verify, then delete.
    private func finalRemove(kind: DeviceLedgerEntry.Kind, itemID: String, marker: String, identity: DeviceSavedIdentity) -> DeviceLedgerRemoval {
        if let no = access(kind) { return no }
        switch kind {
        case .reminder:
            guard let r = store.calendarItem(withIdentifier: itemID) as? EKReminder, r.notes?.contains(marker) == true,
                  DeviceEventKitRule.matches(identity, title: r.title, start: DeviceSavedIdentity.due(r.dueDateComponents)) else { return .undetermined }
            do { try store.remove(r, commit: true); return .removed } catch { return .removeFailed }
        case .event:
            guard let e = store.event(withIdentifier: itemID), e.notes?.contains(marker) == true,
                  DeviceEventKitRule.matches(identity, title: e.title, start: e.startDate) else { return .undetermined }
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
            entries.append(.init(id: call.call_id, kind: kind, itemID: item, title: title, due: Self.date(args[dueKey]?.text), createdAt: Date(), account: token.account, saved: result.savedIdentity))
            save()
        }
    }

    /// 任务 row 撤销. Returns true only when the item is known to be gone.
    @discardableResult func undo(_ entry: DeviceLedgerEntry) async -> Bool { await undo(callID: entry.id).removed }

    func entry(callID: String) -> DeviceLedgerEntry? { entries.first { $0.id == callID && mine($0) } }
    func isUndone(callID: String) -> Bool { entry(callID: callID)?.undone == true }
    /// Chat-UX #6: delete what this call_id created, for the signed-in account only.
    /// p89i-3: the EventKit query runs before (outside) the account lock; the final re-verify + delete runs inside
    /// `epoch.commit(token)`, so a sign-out / switch during the query refuses the delete (→ unknown, nothing removed).
    func undo(callID: String) async -> DeviceUndoOutcome {
        guard let token = epoch.capture(), let entry = entry(callID: callID) else { return .unknown }   // other account / signed out / never recorded
        if entry.undone { return .alreadyGone }
        let plan = await items.prepareRemoval(kind: entry.kind, itemID: entry.itemID, callID: entry.id, identity: entry.saved)
        return apply(plan, entry: entry, token: token)
    }
    private func apply(_ plan: DeviceLedgerRemovalPlan, entry: DeviceLedgerEntry, token: AccountToken) -> DeviceUndoOutcome {
        let outcome: DeviceUndoOutcome? = epoch.commit(token) {
            let removal: DeviceLedgerRemoval
            switch plan { case .decided(let r): removal = r; case .ready(let apply): removal = apply() }
            let o: DeviceUndoOutcome
            switch removal {
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
    /// p89i product decision: what the UI calls. Proven → deleted (`.done`). Permission gone → `.needsPermission` (user
    /// opens Settings or leaves it). Unprovable (copy / moved / outside the query range / no identity) → `.needsChoice`
    /// with the marked candidates; nothing is deleted until the user picks one (`undoChosen`). Default = keep.
    func undoAttempt(callID: String) async -> DeviceUndoAttempt {
        guard let token = epoch.capture(), let entry = entry(callID: callID) else { return .done(.unknown) }
        if entry.undone { return .done(.alreadyGone) }
        let plan = await items.prepareRemoval(kind: entry.kind, itemID: entry.itemID, callID: entry.id, identity: entry.saved)
        if case .decided(.permissionRevoked) = plan { Self.log("undo \(callID): permission revoked → ask user"); return .needsPermission }
        var outcome: DeviceUndoOutcome = .unknown
        if case .ready = plan { outcome = apply(plan, entry: entry, token: token) }   // proven → deleted under the barrier
        guard outcome == .unknown, epoch.isValid(token) else { return .done(outcome) }
        // Not provable (copy / moved / out of range / no identity / changed during the query) → the user decides.
        let c = await items.candidates(kind: entry.kind, itemID: entry.itemID, callID: entry.id, identity: entry.saved)
        guard epoch.isValid(token) else { return .done(.unknown) }
        Self.log("undo \(callID): unprovable → user choice among \(c.count)")
        return c.isEmpty ? .done(.unknown) : .needsChoice(c)
    }
    /// The user picked `itemID` from `.needsChoice`. Deletes exactly that object (if it still carries our marker) under the
    /// same account barrier; the entry is marked undone only when the chosen object is the recorded one.
    func undoChosen(callID: String, itemID: String) -> DeviceUndoOutcome {
        guard let token = epoch.capture(), let entry = entry(callID: callID) else { return .unknown }
        let outcome: DeviceUndoOutcome? = epoch.commit(token) {
            let o: DeviceUndoOutcome
            switch items.removeChosen(kind: entry.kind, itemID: itemID, callID: entry.id) {
            case .removed: o = .undone
            case .removeFailed: o = .failed
            default: o = .unknown
            }
            if o.removed, itemID == entry.itemID, let i = entries.firstIndex(where: { $0.id == entry.id && $0.account == token.account }) { entries[i].undone = true; save() }
            return o
        }
        Self.log("undo \(callID): user chose \(itemID) → \(String(describing: outcome ?? .unknown))")
        return outcome ?? .unknown
    }
    /// User chose 都保留: logged, nothing deleted.
    func keepAll(callID: String) { Self.log("undo \(callID): user kept all") }
    private(set) static var decisions: [String] = []
    static func log(_ s: String) { decisions.append(s); DeviceDecisionLog.write(s) }

    /// Sign-out: the account's local ledger is cleared (memory + disk).
    func signOut(account: String?) {
        guard let account else { return }
        entries.removeAll { $0.account == account }; save()
        DeviceCreationReceipts.shared.signOut(account: account)   // p89i-1: that account's creation receipts go too
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
    @State private var choosing: String = ""
    @State private var candidates: [DeviceUndoCandidate] = []
    @State private var needsPermission = false
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
                        Button(ui("撤销")) { Task {
                            choosing = entry.id
                            switch await ledger.undoAttempt(callID: entry.id) {
                            case .done(let o): if !o.removed { failed = entry.id }
                            case .needsChoice(let c): candidates = c
                            case .needsPermission: needsPermission = true
                            }
                        } }
                            .font(CatpawTypography.Role.secondary.font).buttonStyle(.borderless)
                            .accessibilityIdentifier("tasks.device.undo." + entry.id)
                    }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("tasks.device." + entry.id)
                    if failed == entry.id { Text(ui("撤销未完成，请在系统 App 中删除。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention) }
                }
            } header: { Text(ui("Catpaw 在本机创建的")) }
            .modifier(DeviceUndoDecision(candidates: $candidates, needsPermission: $needsPermission, callID: choosing, ledger: ledger) { o in if !o.removed { failed = choosing } })
        }
    }
}

/// p89i product decision UI (system dialog style, Chinese copy, no accent text): unprovable undo → the user picks which
/// marked object to delete, default 都保留; permission gone → 去设置 or 先不处理. Shared by the receipt card and 任务.
@MainActor struct DeviceUndoDecision: ViewModifier {
    @Binding var candidates: [DeviceUndoCandidate]
    @Binding var needsPermission: Bool
    let callID: String
    let ledger: DeviceLedger
    var done: (DeviceUndoOutcome) -> Void
    @Environment(\.locale) private var locale
    private func ui(_ k: String) -> String { AppLanguage(locale: locale).ui(k) }
    private func label(_ c: DeviceUndoCandidate) -> String {
        let when = c.start.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ui("无时间")
        return ui("删除") + "「\(c.title)」\(when)" + (c.isRecorded ? ui("（Catpaw 记录的那一个）") : "")
    }
    func body(content: Content) -> some View {
        content
            .confirmationDialog(ui("无法确认哪一个是 Catpaw 创建的"), isPresented: Binding(get: { !candidates.isEmpty }, set: { if !$0 && !candidates.isEmpty { ledger.keepAll(callID: callID); candidates = [] } }), titleVisibility: .visible) {
                ForEach(candidates) { c in
                    Button(label(c), role: .destructive) { candidates = []; done(ledger.undoChosen(callID: callID, itemID: c.id)) }
                }
                Button(ui("都保留"), role: .cancel) { ledger.keepAll(callID: callID); candidates = [] }
            } message: { Text(ui("它可能被复制、移动过。请选择要删除的一项，或全部保留。")) }
            .alert(ui("没有日历或提醒事项权限"), isPresented: $needsPermission) {
                Button(ui("去设置")) { DeviceLedger.log("undo \(callID): user → settings"); if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                Button(ui("先不处理"), role: .cancel) { DeviceLedger.log("undo \(callID): user left it") }
            } message: { Text(ui("权限已关闭，Catpaw 不会删除任何内容。开启后可再次撤销。")) }
    }
}
