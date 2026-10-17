import Foundation
import MapKit
import CoreLocation
import CryptoKit
import Observation
#if canImport(EventKit)
import EventKit
#endif
#if os(iOS)
import UIKit
import UserNotifications
import BackgroundTasks
import WidgetKit
#endif

// On-device ProactiveEngine (interview demo core).
// Non-user signal (EventKit next event / BGAppRefresh / simulated signal) → rule pre-filter → dedupe ledger
// (signal_hash) → evaluate (server /proactive/evaluate, local rules offline) → card + actionable local notification
// → user confirms → idempotent EventKit reminder write (operation_id in EKReminder url/notes).
// Memory: "提前 N 分钟" in the user's memories changes the reminder lead time and is cited in the card.

struct ProactiveLogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let at: Date
    let text: String
}

/// One candidate trigger, before dedupe.
struct ProactiveSignal: Equatable, Sendable {
    enum Source: String, Sendable { case eventKit = "calendar", simulated = "simulated", manual = "manual", background = "bg_refresh" }
    var source: Source
    var eventID: String
    var title: String
    var start: Date
    var place: String
    /// Debug 「模拟起点」— Why must say 「从模拟起点 X」; never silent.
    var simulatedOriginLabel: String? = nil
    var simulatedOriginLat: Double? = nil
    var simulatedOriginLon: Double? = nil
    /// EKEvent attendee names / phones for notify draft.
    var attendeeNames: [String] = []
    var attendeeRecipients: [String] = []
    /// Stable per (event, start): the same meeting never triggers twice.
    var signalHash: String {
        ProactiveRules.signalHash(eventID: eventID, start: start)
    }
}

/// p90i v7: #90's `AccountParkedItemSource` (#89). Only EventKit items are listed (the app's own data is parked and
/// restored automatically by `claimData`, no prompt).
@MainActor final class ProactiveParkedSource: AccountParkedItemSource {
    func parkedItems(account: String) -> [AccountParkedItem] { ProactiveEngine.shared.externalParkedItems(account: account) }
    func apply(_ decision: AccountParkedDecision, to item: AccountParkedItem, account: String) async -> String {
        await ProactiveEngine.shared.applyExternal(decision, item, account: account)
    }
}

@MainActor @Observable final class ProactiveEngine {
    static let shared = ProactiveEngine()

    private init() { Self.registerAccountObserver() }
    /// #89 AccountChangeObservers: sign-out / passive expiry / switch bump AccountEpoch synchronously, then await this
    /// cleanup. Idempotent (keyed). The closure resolves `.shared` only when it runs, so registering from `init`
    /// neither retains the instance nor re-enters the `shared` initializer. Also called at launch so a sign-out
    /// before the engine is first touched still wipes the persisted inbox/ledgers.
    static func registerAccountObserver() {
        #if os(iOS)
        AccountChangeObservers.register("proactive") { previous, current in await ProactiveEngine.shared.accountDidChange(previous: previous, current: current) }
        registerParkedSource()
        #endif
    }
    /// p90i v7: EventKit items Catpaw created go through #89's one keep/cancel decision (default keep). Also called from
    /// #89's `registerDeviceParkedSources` so a cold start followed by an immediate sign-out lists them.
    static func registerParkedSource() {
        if !AccountParkedItems.registeredKeys.contains(ProactiveParking.sourceKey) { AccountParkedItems.register(ProactiveParking.sourceKey, ProactiveParkedSource()) }
    }
    /// Card detail after the user chose to delete the reminder Catpaw created (UIStrings key; zh/en).
    static let reminderDeletedDetail = "提醒已删除"
    /// p90j: the reminder was already gone when the user chose to delete it.
    static let reminderGoneDetail = "提醒已不存在"
    static let notificationCategory = "CATPAW_PROACTIVE"
    static let createAction = "CATPAW_PROACTIVE_CREATE"
    static let laterAction = "CATPAW_PROACTIVE_LATER"
    static let notNowAction = "CATPAW_PROACTIVE_NOT_NOW"
    static let bgTaskID = "com.yankj.catpawm.proactive.refresh"

    private(set) var log: [ProactiveLogEntry] = []
    private(set) var calendarDenied = false
    private(set) var lastSuggestionID: String?
    var defaultLeadMinutes = 10
    private let defaults = UserDefaults.standard
    private let ledgerKey = "catpaw.proactive.ledger.v1", opsKey = "catpaw.proactive.ops.v1", suggestionsKey = "catpaw.proactive.suggestions.v1"
    #if canImport(EventKit)
    let store = EKEventStore()
    #endif

    // MARK: Log + ledger

    func note(_ text: String) {
        log.insert(.init(at: ProactiveClock.now(), text: text), at: 0)
        if log.count > 80 { log.removeLast(log.count - 80) }
        print("catpaw.proactive \(text)")
    }
    private var ledger: [String: Double] {
        get { defaults.dictionary(forKey: ledgerKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: ledgerKey) }
    }
    func resetLedger() { ledger = [:]; signalLedger = .init(); note("ledger cleared") }

    /// Codex PR90d #1 / PR90e #1 #2: owner-scoped data lifecycle (`ProactiveDataOwner.plan`). Synchronous (no await), at
    /// every write entry and account change: same owner → nothing; no owner recorded (first run after the upgrade) →
    /// the data is migrated to the signed-in account (only other accounts' queued write-backs go); otherwise the
    /// previous owner's data is wiped. Adopt and wipe both register the new owner, so it never stays "".
    func claimData(for account: String?, force: Bool = false) {
        let owner = defaults.object(forKey: ProactiveDataOwner.key) as? String
        let plan: ProactiveDataOwner.Plan = force ? .wipe : ProactiveDataOwner.plan(owner: owner, current: account)
        switch plan {
        case .keep: return
        case .adopt, .quarantine:   // PR90f #1: never claimed for whoever is signed in, never dropped
            quarantineUnownedData()
        case .wipe:
            // p90i P1-a: the old account's data is parked under it (never dropped, never executed under anyone else).
            if ProactiveParking.shouldPark(plan: plan, owner: owner, force: force), let owner { park(owner: owner) }
        }
        for id in Set(ProactiveSuggestionStore.shared.items.keys).union(ProactiveLocalBackend.load().keys) { CatpawLeaveActivity.stop(suggestionID: id) }
        quota = ProactiveQuotaLedger()
        syncQueue.purge(account: nil); localOnly = []; localFeedback = .init()
        if force { serverIDs = [:] }   // p90i S5: per-account map — another account's ids are simply not visible
        ProactiveLocalBackend.wipe(); ProactiveSuggestionStore.shared.resetForAccountChange()
        pendingReminders = [:]; pendingAttendees = [:]; generations = .init(); ledger = [:]; signalLedger = .init(); lastSuggestionID = nil
        defaults.set(account ?? "", forKey: ProactiveDataOwner.key)
        if let account, !force { unpark(account: account) }   // p90i: the owner signing in again gets its own data back
        if plan == .wipe { note("proactive data owner \(owner ?? "unknown") → \(account ?? "signed out"): previous owner's data \(force ? "reset" : "parked")") }
        else { note("proactive data without a recorded owner quarantined (not shown / sent / synced until proven; never deleted)"); Task { await reconcileQuarantine() } }
    }

    // MARK: Parking (p90i P1-a; interim until #89's generic decision API)

    /// Snapshot of `owner`'s local data (same blobs as the quarantine + its unsynced write-backs, live and dead), appended
    /// to `ProactiveParking.key` under that account. Nothing parked is shown, sent, synced or re-armed.
    private func park(owner: String) {
        var blobs: [String: Data] = [:]
        for k in quarantineBlobKeys { if let d = defaults.data(forKey: k) { blobs[k] = d } }
        let (items, dead) = syncQueue.extractSplit()   // p90i: dead letters parked apart, restored as dead letters
        let inbox = blobs[ProactiveLocalBackend.storageKey].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard !inbox.isEmpty || !items.isEmpty || !dead.isEmpty else { return }   // nothing of that account to keep
        // EventKit reminders the app created are outside the app: never deleted / edited here, listed for the user (#89).
        let ext = ProactiveParking.externalItems(inbox: inbox, reminderOps: pendingReminders.mapValues(\.operationID))
        if !ext.isEmpty {
            var all = externalStore, mine = all[owner.lowercased()] ?? []
            for e in ext where !mine.contains(where: { $0.suggestionID == e.suggestionID }) { mine.append(e) }
            all[owner.lowercased()] = mine; externalStore = all
        }
        var lot = ProactiveParking.Lot(defaults.dictionary(forKey: ProactiveParking.key))
        lot.park(account: owner, record: ["at": ProactiveClock.now().timeIntervalSince1970, "blobs": blobs, "localOnly": Array(localOnly),
                                          "queue": (try? JSONEncoder().encode(items)) ?? Data(),
                                          "dead": (try? JSONEncoder().encode(dead)) ?? Data(), "decision": "keep"])
        defaults.set(lot.raw, forKey: ProactiveParking.key)
        note("parked \(inbox.count) card(s) / \(items.count) unsynced op(s) of \(owner); restored when it signs in again")
    }
    /// The owner signed in again: its parked inbox, reminder / attendee contexts, generations and write-backs come back
    /// (the current, freshly wiped store wins on any clash) and its ops are synced under it. Synchronous.
    private func unpark(account: String) {
        var lot = ProactiveParking.Lot(defaults.dictionary(forKey: ProactiveParking.key))
        let recs = lot.take(account: account)
        guard !recs.isEmpty else { return }
        defaults.set(lot.raw, forKey: ProactiveParking.key)
        var ops = 0
        for r in recs {
            for (k, old) in r["blobs"] as? [String: Data] ?? [:] {
                if k == Self.generationsKey {
                    let o = (try? JSONDecoder().decode(ProactiveActionGenerations.self, from: old)) ?? .init()
                    var g = generations; for (id, v) in o.values where v > g[id] { g.values[id] = v }; generations = g; continue
                }
                let rel = (try? JSONSerialization.jsonObject(with: old) as? [String: Any]) ?? [:]
                var cur = defaults.data(forKey: k).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                for (id, v) in rel where cur[id] == nil { cur[id] = v }
                if let d = try? JSONSerialization.data(withJSONObject: cur) { defaults.set(d, forKey: k) }
            }
            localOnly = localOnly.union(r["localOnly"] as? [String] ?? [])
            let items = (r["queue"] as? Data).flatMap { try? JSONDecoder().decode([CatpawPersistentQueue<SyncOp>.Item].self, from: $0) } ?? []
            syncQueue.reinstate(items, account: account); ops += items.count   // only items stamped with this account (or unstamped)
            let dead = (r["dead"] as? Data).flatMap { try? JSONDecoder().decode([CatpawPersistentQueue<SyncOp>.Item].self, from: $0) } ?? []
            syncQueue.reinstateDead(dead, account: account)   // p90i 08:57: stay dead, flagged for the user, never retried
        }
        let all = ProactiveLocalBackend.load()
        for s in all.values { ProactiveSuggestionStore.shared.adopt(s) }
        CatpawWidgetSnapshotWriter.write(Array(all.values))
        note("restored \(recs.count) parked record(s) / \(ops) op(s) of \(account) → syncing under it")
        Task { await drainSync() }
    }
    private var externalStore: [String: [ProactiveParking.ExternalItem]] {
        get { defaults.data(forKey: ProactiveParking.externalKey).flatMap { try? JSONDecoder().decode([String: [ProactiveParking.ExternalItem]].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: ProactiveParking.externalKey) }
    }
    /// p90i: the signed-in account's restored dead letters awaiting the user's retry / discard (no UI yet).
    func syncNeedingConfirmation() -> [CatpawPersistentQueue<SyncOp>.Item] {
        guard let a = AccountEpoch.shared.currentAccount else { return [] }
        return syncQueue.needingConfirmation(account: a)
    }
    /// p90i v7 (#89 AccountParkedItems source). Collected right after the epoch bump, BEFORE the observers park the data,
    /// so the live owner's created reminders are listed too (plus the ones parked earlier). Titles are the user's own.
    func externalParkedItems(account: String) -> [AccountParkedItem] {
        var out = externalPendingDecision(for: account)
        if let o = dataOwner, o.caseInsensitiveCompare(account) == .orderedSame {
            let inbox = defaults.data(forKey: ProactiveLocalBackend.storageKey).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for e in ProactiveParking.externalItems(inbox: inbox, reminderOps: pendingReminders.mapValues(\.operationID)) where !out.contains(where: { $0.operationID == e.operationID }) { out.append(e) }
        }
        let reminders = pendingReminders
        return out.map { e in ProactiveParking.parkedItem(e, title: reminders[e.suggestionID].map { "准备：\($0.title)" } ?? "Catpaw 创建的提醒") }
    }
    /// Test seam for the EventKit delete (nil → the real store).
    var externalReminderRemover: ((String) async -> String)?
    /// Applies #89's decision. keep → left in Reminders and still listed for that account; cancel → the user chose to undo
    /// it: only the reminder this operation created is removed; on success it is no longer pending (nor re-recorded).
    func applyExternal(_ d: AccountParkedDecision, _ item: AccountParkedItem, account: String) async -> String {
        switch ProactiveParking.effect(d, item) {
        case .leave:
            var all = externalStore, mine = all[account.lowercased()] ?? []
            if !mine.contains(where: { $0.operationID == item.key }), let sid = pendingReminders.first(where: { $0.value.operationID == item.key })?.key {
                mine.append(.init(suggestionID: sid, operationID: item.key, kind: item.detail)); all[account.lowercased()] = mine; externalStore = all
            }
            return "kept: left in Reminders"
        case .remove(let op):
            let r = await (externalReminderRemover ?? Self.removeExternalReminder)(op)
            guard r == "deleted" || r == "already_gone" else { return "kept: \(r)" }
            let sids = Set((externalStore[account.lowercased()] ?? []).filter { $0.operationID == op }.map(\.suggestionID) + pendingReminders.filter { $0.value.operationID == op }.map(\.key))
            markReminderDeleted(sids, account: account, detail: r == "already_gone" ? Self.reminderGoneDetail : Self.reminderDeletedDetail)   // NoBug p90i (b) / p90j: 提醒已删除 or 提醒已不存在
            var all = externalStore; all[account.lowercased()]?.removeAll { $0.operationID == op }; externalStore = all
            var p = pendingReminders; for (k, v) in p where v.operationID == op { p[k] = nil }; pendingReminders = p   // not re-recorded by the park
            note("external reminder \(op) \(r) on the user's decision")
            return r
        }
    }
    /// Sets the card's create_reminder entry to `reminderDeletedDetail`, in the live inbox (still that account's) and in
    /// its parked records — the card then shows the reminder is gone instead of "created".
    private func markReminderDeleted(_ ids: Set<String>, account: String, detail: String) {
        guard !ids.isEmpty else { return }
        func edit(_ data: Data?) -> Data? {
            guard var inbox = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return nil }
            var changed = false
            for id in ids {
                guard var card = inbox[id] as? [String: Any], var taken = card["taken"] as? [[String: Any]] else { continue }
                for i in taken.indices where taken[i]["action"] as? String == "create_reminder" { taken[i]["detail"] = detail; changed = true }
                card["taken"] = taken; inbox[id] = card
            }
            return changed ? try? JSONSerialization.data(withJSONObject: inbox) : nil
        }
        if let o = dataOwner, o.caseInsensitiveCompare(account) == .orderedSame, let d = edit(defaults.data(forKey: ProactiveLocalBackend.storageKey)) {
            defaults.set(d, forKey: ProactiveLocalBackend.storageKey)
            for (id, s) in ProactiveLocalBackend.load() where ids.contains(id) { ProactiveSuggestionStore.shared.adopt(s) }
        }
        var lot = ProactiveParking.Lot(defaults.dictionary(forKey: ProactiveParking.key))
        if var recs = lot.slots[account.lowercased()] {
            for i in recs.indices { if var b = recs[i]["blobs"] as? [String: Data], let d = edit(b[ProactiveLocalBackend.storageKey]) { b[ProactiveLocalBackend.storageKey] = d; recs[i]["blobs"] = b } }
            lot.slots[account.lowercased()] = recs; defaults.set(lot.raw, forKey: ProactiveParking.key)
        }
    }
    /// The real delete, only on the user's explicit decision: by the marker of the operation that created it.
    static func removeExternalReminder(_ op: String) async -> String {
        #if canImport(EventKit)
        let es = ProactiveEngine.shared.store, auth = EKEventStore.authorizationStatus(for: .reminder)
        guard auth == .fullAccess || auth == .authorized else { return "not_authorized" }
        guard let id = await ProactiveEngine.shared.findReminder(marker: URL(string: "catpawm://op/\(op)")!),
              let item = es.calendarItem(withIdentifier: id) as? EKReminder else { return "already_gone" }
        do { try es.remove(item, commit: true); return "deleted" } catch { return "failed:\(error.localizedDescription)" }
        #else
        return "no_eventkit"
        #endif
    }
    /// EventKit items of `account` awaiting the user's decision (#89's list). #90 never removes entries itself.
    func externalPendingDecision(for account: String) -> [ProactiveParking.ExternalItem] { externalStore[account.lowercased()] ?? [] }
    /// Test seam: the reminder context `confirmReminder` would have stored for a created reminder.
    func recordPendingReminderForTest(_ id: String, operationID: String) {
        let now = ProactiveClock.now(); var p = pendingReminders
        p[id] = PendingReminder(title: "t", due: now, start: now, place: "", operationID: operationID); pendingReminders = p
    }
    private func appendParkedNotifications(owner: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        var lot = ProactiveParking.Lot(defaults.dictionary(forKey: ProactiveParking.key))
        guard var recs = lot.slots[owner.lowercased()], var last = recs.popLast() else { return }
        last["notifications"] = (last["notifications"] as? [String] ?? []) + ids; recs.append(last); lot.slots[owner.lowercased()] = recs
        defaults.set(lot.raw, forKey: ProactiveParking.key)
    }
    var parkedAccounts: [String] { ProactiveParking.Lot(defaults.dictionary(forKey: ProactiveParking.key)).accounts }
    /// Read-only views for #89's decision UI and tests.
    func parkedOps(for account: String) -> [SyncOp]? {
        guard let recs = ProactiveParking.Lot(defaults.dictionary(forKey: ProactiveParking.key)).slots[account.lowercased()] else { return nil }
        let dec = { (d: Any?) in (d as? Data).flatMap { try? JSONDecoder().decode([CatpawPersistentQueue<SyncOp>.Item].self, from: $0) }?.map(\.op) ?? [] }
        return recs.flatMap { dec($0["queue"]) + dec($0["dead"]) }
    }
    func parkedInbox(for account: String) -> [String: Any] {
        let recs = ProactiveParking.Lot(defaults.dictionary(forKey: ProactiveParking.key)).slots[account.lowercased()] ?? []
        return recs.reduce(into: [:]) { acc, r in
            let d = (r["blobs"] as? [String: Data])?[ProactiveLocalBackend.storageKey]
            for (k, v) in d.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] { acc[k] = v }
        }
    }

    // MARK: Quarantine (Codex PR90f #1)

    /// Raw persisted blobs moved into the quarantine (inbox, reminder + attendee contexts, undo generations).
    private var quarantineBlobKeys: [String] { [ProactiveLocalBackend.storageKey, suggestionsKey, Self.attendeesKey, Self.generationsKey] }
    /// The isolated store: a plist dictionary under `ProactiveQuarantine.key`. Only reconcile reads it.
    private func quarantineUnownedData() {
        // p90i: a later unowned set is parked under "(unknown)" rather than wiped.
        guard defaults.dictionary(forKey: ProactiveQuarantine.key) == nil else { park(owner: "(unknown)"); return }
        var blobs: [String: Data] = [:]
        for k in quarantineBlobKeys { if let d = defaults.data(forKey: k) { blobs[k] = d } }
        let (items, dead) = syncQueue.extractSplit()   // p90i 09:01: dead letters kept apart (released as dead letters)
        let record: [String: Any] = ["at": ProactiveClock.now().timeIntervalSince1970, "blobs": blobs, "serverIDs": takeLegacyServerIDs(), "localOnly": Array(localOnly),
                                     "queue": (try? JSONEncoder().encode(items)) ?? Data(), "dead": (try? JSONEncoder().encode(dead)) ?? Data(),
                                     "stamps": (items + dead).compactMap(\.account)]
        defaults.set(record, forKey: ProactiveQuarantine.key)
    }
    var hasQuarantine: Bool { defaults.dictionary(forKey: ProactiveQuarantine.key) != nil }
    /// Server evidence: the cloud returns this server id for the bearer of `token` (owner-scoped). Replaceable in tests.
    var serverProbe: (String, AccountToken) async -> Bool = { id, token in await ProactiveEngine.get("suggestions/\(id)", token: token) != nil }
    /// Codex PR90g #1: ownership is proven per record (`ProactiveQuarantine.releasable`): a record is released — with its
    /// own reminder / attendee context, server id, generation and write-backs — only on its own evidence (its queued
    /// write-backs all name this account, or the cloud returns its own server id for this account). Everything else
    /// stays quarantined; whatever is left after `ttl` expires.
    @discardableResult func reconcileQuarantine() async -> ProactiveQuarantine.Verdict? {
        guard var record = defaults.dictionary(forKey: ProactiveQuarantine.key) else { return nil }
        let at = Date(timeIntervalSince1970: record["at"] as? Double ?? 0), token = AccountEpoch.shared.capture()
        let (live, dead) = Self.quarantineQueues(record), items = live + dead   // evidence / ids from both
        let blobs = record["blobs"] as? [String: Data] ?? [:], sids = record["serverIDs"] as? [String: String] ?? [:]
        let inbox = blobs[ProactiveLocalBackend.storageKey].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let ids = Array(Set(inbox.keys).union(items.map(\.op.local)).union(sids.keys)).sorted()
        let stamps = Dictionary(grouping: items, by: \.op.local).mapValues { $0.map(\.account) }
        var confirmed = Set<String>()
        if let token {
            let unproven = ids.filter { !ProactiveQuarantine.releasable(ids: [$0], stamps: stamps, confirmed: [], current: token.account).contains($0) }
            for id in unproven.prefix(20) { if let sid = sids[id], await serverProbe(sid, token) { confirmed.insert(id) } }
        }
        let released = ProactiveQuarantine.releasable(ids: ids, stamps: stamps, confirmed: confirmed, current: token?.account)
        if let token, !released.isEmpty {
            guard AccountEpoch.shared.commit(token, { () -> Void in
                claimData(for: token.account)
                record = releaseQuarantine(record, ids: released, live: live, dead: dead, to: token.account)
            }) != nil else { return .hold }
            note("quarantine released \(released.count) of \(ids.count) record(s) to \(token.account) on their own evidence")
            Task { await drainSync() }
        }
        let left = ids.filter { !released.contains($0) }
        if left.isEmpty { defaults.removeObject(forKey: ProactiveQuarantine.key); return released.isEmpty ? nil : .release }
        // p90i P1-b: never deleted (by age or otherwise); kept, separated, until a record proves its own owner.
        if released.isEmpty { note("quarantine held: \(left.count) record(s) without evidence, \(Int(ProactiveClock.now().timeIntervalSince(at) / 86400)) day(s) old") }
        return released.isEmpty ? .hold : .release
    }
    /// Moves the released records (and only their own entries) into the active stores; returns the remaining record.
    /// Live and dead queued items of a quarantine record (records written before p90i keep everything under "queue").
    private static func quarantineQueues(_ record: [String: Any]) -> (live: [CatpawPersistentQueue<SyncOp>.Item], dead: [CatpawPersistentQueue<SyncOp>.Item]) {
        let dec = { (d: Any?) in (d as? Data).flatMap { try? JSONDecoder().decode([CatpawPersistentQueue<SyncOp>.Item].self, from: $0) } ?? [] }
        return (dec(record["queue"]), dec(record["dead"]))
    }
    private func releaseQuarantine(_ record: [String: Any], ids: Set<String>, live: [CatpawPersistentQueue<SyncOp>.Item], dead: [CatpawPersistentQueue<SyncOp>.Item], to account: String) -> [String: Any] {
        var record = record, blobs = record["blobs"] as? [String: Data] ?? [:]
        for (k, old) in blobs {
            if k == Self.generationsKey {
                var o = (try? JSONDecoder().decode(ProactiveActionGenerations.self, from: old)) ?? .init(), g = generations
                for id in ids { if let v = o.values[id], v > g[id] { g.values[id] = v }; o.values[id] = nil }
                generations = g; blobs[k] = try? JSONEncoder().encode(o); continue
            }
            var rel = (try? JSONSerialization.jsonObject(with: old) as? [String: Any]) ?? [:]
            var cur = defaults.data(forKey: k).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for id in ids { if let v = rel.removeValue(forKey: id), cur[id] == nil { cur[id] = v } }   // the current owner's entry wins
            if let d = try? JSONSerialization.data(withJSONObject: cur) { defaults.set(d, forKey: k) }
            blobs[k] = try? JSONSerialization.data(withJSONObject: rel)
        }
        record["blobs"] = blobs
        var sids = record["serverIDs"] as? [String: String] ?? [:], cur = serverIDs
        for id in ids { if let v = sids.removeValue(forKey: id), cur[id] == nil { cur[id] = v } }
        serverIDs = cur; record["serverIDs"] = sids
        var lo = Set(record["localOnly"] as? [String] ?? []); localOnly = localOnly.union(lo.intersection(ids)); lo.subtract(ids); record["localOnly"] = Array(lo)
        let p = ProactiveQuarantine.partition(live: live, dead: dead, released: ids) { $0.op.local }
        syncQueue.reinstate(p.live, account: account)       // only this record's, only unstamped / this account's
        syncQueue.reinstateDead(p.dead, account: account)   // p90i 09:01: stay dead, flagged, group blocked, never retried
        record["queue"] = (try? JSONEncoder().encode(p.restLive)) ?? Data(); record["dead"] = (try? JSONEncoder().encode(p.restDead)) ?? Data()
        record["stamps"] = (p.restLive + p.restDead).compactMap(\.account)
        defaults.set(record, forKey: ProactiveQuarantine.key)
        let all = ProactiveLocalBackend.load()
        for id in ids { if let s = all[id] { ProactiveSuggestionStore.shared.adopt(s) } }
        CatpawWidgetSnapshotWriter.write(Array(all.values))
        return record
    }
    /// Codex P0-5: evaluated vs delivered (v2). v1 entries migrate as delivered.
    private let signalLedgerKey = "catpaw.proactive.ledger.v2"
    private var signalLedger: ProactiveSignalLedger {
        get {
            if let d = defaults.data(forKey: signalLedgerKey), let l = try? JSONDecoder().decode(ProactiveSignalLedger.self, from: d) { return l }
            return ProactiveSignalLedger(legacy: ledger)
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: signalLedgerKey) }
    }

    // MARK: Memory → lead time

    /// Looks for "提前 N 分钟" / "N minutes early" in the live agent memory; falls back to `defaultLeadMinutes`.
    /// Settings/debug writes the same phrase via `setLeadMinutes` so evaluate has hard evidence.
    func leadTime() async -> (minutes: Int, memory: ProactiveSuggestion.MemoryRef?) {
        // Cloud backend first, then the persisted on-device library (NoBug P0-1: survives cold start).
        // Codex PR91 #3: fail closed — a load error or an unknown cloud switch (last known off) means no memory.
        let local: (any MemoryLibraryBackend)? = MemoryLibraryHub.backend === MemoryLibraryHub.local ? nil : MemoryLibraryHub.local
        let snaps = await MemoryRecallLoader.snapshots(cloud: MemoryLibraryHub.backend, local: local, owner: MemoryLibraryHub.local.owner)
        if let hit = ProactiveRules.lead(in: snaps) { return (hit.minutes, .init(id: hit.item.id, content: hit.item.content)) }
        return (defaultLeadMinutes, nil)
    }

    /// Settings / debug: writes a REAL memory item into the store Settings › 记忆 lists (MemoryLibraryHub.backend).
    /// Returns a user-facing outcome; no shadow store — if the library refuses, nothing is used.
    @discardableResult func setLeadMinutes(_ minutes: Int) async -> String {
        let n = min(180, max(1, minutes)), phrase = "开会提前 \(n) 分钟准备"
        guard let backend = MemoryLibraryHub.backend else { note("lead write failed: no memory library"); return "记忆库不可用，未写入" }
        do {
            let snap = try await backend.load()
            let old = snap.items.filter { $0.content.range(of: #"提前\s*\d{1,3}\s*分钟"#, options: .regularExpression) != nil }.map(\.id)
            if !old.isEmpty { try await backend.forget(ids: old) }
            let id = try await backend.create(kind: "preference", content: phrase)
            note("lead memory created id=\(id) “\(phrase)” in \(type(of: backend))")
            return "已写入记忆：\(phrase)"
        } catch MemoryLibraryError.notEnabled, MemoryLibraryError.unsupported {
            // Settings › 记忆 lists Hub.backend. If agent-memory is 未开通 / no create, install a local
            // stub as the same page backend so the row is visible+deletable (honest label, no UserDefaults).
            // Persisted on-device library (Application Support) — survives cold start; migrated when the gate opens.
            let stub = MemoryLibraryHub.local
            if MemoryLibraryHub.backend !== stub { MemoryLibraryHub.install(backend: stub) }
            do {
                let snap = try await stub.load()
                let old = snap.items.filter { $0.content.range(of: #"提前\s*\d{1,3}\s*分钟"#, options: .regularExpression) != nil }.map(\.id)
                if !old.isEmpty { try await stub.forget(ids: old) }
                let id = try await stub.create(kind: "preference", content: phrase)
                note("lead memory local-stub id=\(id) (agent-memory unavailable)")
                return "agent-memory 未开通 — 已写入本机记忆库（设置 › 记忆可见可删）：\(phrase)"
            } catch {
                note("lead local-stub failed: \(error)"); return "写入本机记忆库失败"
            }
        } catch { note("lead write failed: \(error)"); return "写入记忆失败" }
    }

    /// Delete lead preference + matching memory so evaluate falls back to default.
    func clearLeadMinutes() async {
        if let backend = MemoryLibraryHub.backend, let snap = try? await backend.load() {
            let ids = snap.items.filter { ($0.content.contains("提前") && $0.content.contains("分钟")) }.map(\.id)
            if !ids.isEmpty { try? await backend.forget(ids: ids) }
        }
        let localIDs = MemoryLibraryHub.local.items.filter { ProactiveRules.isLeadMemory($0.content) }.map(\.id)
        if !localIDs.isEmpty { try? await MemoryLibraryHub.local.forget(ids: localIDs) }
        note("lead_minutes cleared — evaluate uses default \(defaultLeadMinutes)")
    }

    /// Debug / Settings entry: prompt When-In-Use so travelETA can use a real fix (no silent CBD fallback).
    @discardableResult func requestLocationAccess() async -> String {
        #if canImport(CoreLocation) && os(iOS)
        let status = CLLocationManager.authorizationStatus()
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            if let c = await Self.requestCurrentCoordinate() {
                return String(format: "已授权 · 当前约 %.4f, %.4f", c.latitude, c.longitude)
            }
            return "已授权 · 暂无定位点（可在模拟器 Features › Location 设望京）"
        case .denied, .restricted:
            return "定位被拒绝 — 请到系统设置开启"
        case .notDetermined:
            let ok = await LocationOnceProbe().requestWhenInUse()
            return ok ? "已授权 When-In-Use" : "未授权"
        @unknown default:
            return "未知定位状态"
        }
        #else
        return "本平台无定位"
        #endif
    }



    // MARK: Signals

    /// Real non-user signal: the next calendar event in the coming 3 hours.
    /// `ask`: only explicit user actions (debug panel, permission card) may show the system prompt; background /
    /// foreground scans stay silent while the status is undetermined.
    func scanCalendar(source: ProactiveSignal.Source = .eventKit, ask: Bool = false) async {
        await drainSync()  // Codex PR90 #5: retry write-backs left over from a failure or a previous launch
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined && !ask { return }
        if status == .notDetermined {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if !granted { return calendarUnavailable() }
        } else if status != .fullAccess && status != .authorized { return calendarUnavailable() }
        calendarDenied = false
        let now = ProactiveClock.now()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(3 * 3600), calendars: nil)
        guard let event = store.events(matching: predicate).filter({ !$0.isAllDay && $0.startDate > now }).sorted(by: { $0.startDate < $1.startDate }).first else {
            note("collect source=\(source.rawValue) upcoming=0 → nothing to do"); return
        }
        let names = (event.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        let recipients = (event.attendees ?? []).compactMap { att -> String? in
            let url = att.url
            guard let scheme = url.scheme?.lowercased() else { return nil }
            if scheme == "tel" || scheme == "sms" {
                let prefix = scheme + ":"
                return url.absoluteString.replacingOccurrences(of: prefix, with: "")
            }
            return nil
        }
        await handle(.init(source: source, eventID: event.calendarItemIdentifier, title: event.title ?? "日程", start: event.startDate, place: event.location ?? "",
                           attendeeNames: names, attendeeRecipients: recipients))
        #endif
    }
    private func calendarUnavailable() {
        calendarDenied = true
        note("collect calendar=denied → degrade card (manual meeting input)")
        let degrade = ProactiveSuggestion(id: "permission-calendar", title: "日历权限未开启", reason: "开启日历后我能在会前主动提醒你；也可以手动告诉我下一场会。",
                                          actions: [.dismiss], signals: [.init(kind: "permission", text: "calendar=denied")], createdAt: ProactiveClock.now())
        ProactiveSuggestionStore.shared.adopt(degrade)
    }

    /// Pipeline core shared by EventKit, BGAppRefresh, the debug panel and the manual degrade input.
    @discardableResult func handle(_ signal: ProactiveSignal, now: Date = ProactiveClock.now()) async -> ProactiveSuggestion? {
        note("collect source=\(signal.source.rawValue) event=\(signal.title) start=\(signal.start.formatted(date: .omitted, time: .shortened))")
        // Rule pre-filter
        let minutes = signal.start.timeIntervalSince(now) / 60
        guard ProactiveRules.inWindow(start: signal.start, now: now) else { note("filter drop: starts in \(Int(minutes)) min (window 0–180)"); return nil }
        // AccountEpoch (b): bind this chain to the signed-in account before any await; every write below commits under it.
        guard let token = AccountEpoch.shared.capture() else { note("signed out → no proactive work"); return nil }
        claimData(for: token.account)
        let wallStart = ProactiveClock.now()
        // Dedupe ledger
        let hash = signal.signalHash
        // Codex P0-5: "evaluated" ≠ "delivered". Delivered → never again; evaluated-silent → re-evaluate later.
        var sl = signalLedger
        guard sl.shouldEvaluate(hash, now: now) else {
            note(sl.delivered[hash] != nil ? "dedupe SUPPRESSED delivered signal_hash=\(hash)" : "dedupe: evaluated recently, re-evaluate later signal_hash=\(hash)")
            return nil
        }
        sl.markEvaluated(hash, now: now); signalLedger = sl
        note("dedupe evaluate signal_hash=\(hash)")
        // Evaluate
        let lead = await leadTime()
        let simOrigin: CLLocationCoordinate2D? = {
            guard let la = signal.simulatedOriginLat, let lo = signal.simulatedOriginLon else { return nil }
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }()
        let travel = await Self.travelETA(to: signal.place, from: simOrigin, simulatedLabel: signal.simulatedOriginLabel)
        let travelMinutes = travel.minutes
        let usedETA = travel.usedETA
        let originNote = travel.originNote
        // leave_at = meeting_start - lead_minutes - travel_minutes (travel 0 only when ETA unused → lead only)
        let leaveAt = ProactiveRules.leaveAt(start: signal.start, leadMinutes: lead.minutes, travelMinutes: travelMinutes, usedETA: usedETA)
        let remindAt = leaveAt  // remind when user should leave
        var decision: Decision, fromServer = false
        if let remote = await evaluateRemote(signal, leadMinutes: lead.minutes, travelMinutes: usedETA ? travelMinutes : nil, token: token) { decision = remote; fromServer = true }
        else { decision = evaluateLocal(signal, leadMinutes: lead.minutes, travelMinutes: usedETA ? travelMinutes : nil, now: now) }
        do {
            // p90i (#91 S1): only locally produced decisions are gated; the cloud already applied the learned weights.
            let gated = ProactiveRules.gatedLevel(decision.level, fromServer: fromServer, confidence: ProactiveRules.localConfidence(ProactiveRules.localTrigger, Int(signal.start.timeIntervalSince(now) / 60), travelMinutes: usedETA ? travelMinutes : nil), gate: Self.effectiveFeedbackGate)
            if gated != decision.level { decision = .init(level: gated, why: decision.why + " · feedback gate → \(gated.name)", via: decision.via) }
        }
        guard decision.intervene else { note("decide silent: \(decision.why)"); return nil }
        note("decide intervene (\(decision.via)): \(decision.why); lead=\(lead.minutes) travel=\(usedETA ? String(travelMinutes ?? 0) : "unused") leaveAt=\(leaveAt.formatted(date: .omitted, time: .shortened))")
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        var memories: [ProactiveSuggestion.MemoryRef] = []
        if let m = lead.memory { memories.append(m) }
        var signals: [ProactiveSuggestion.Signal] = [
            .init(kind: signal.source == .eventKit || signal.source == .background ? "calendar" : signal.source.rawValue,
                  text: "\(signal.start.formatted(f)) \(signal.title)\(signal.place.isEmpty ? "" : " · " + signal.place)"),
            .init(kind: "time", text: "现在 \(now.formatted(f)) · 建议 \(leaveAt.formatted(f)) 出发"),
            .init(kind: "rule", text: lead.memory != nil
                  ? "提前 \(lead.minutes) 分钟（记忆） · signal_hash=\(hash)"
                  : "提前 \(lead.minutes) 分钟（默认） · signal_hash=\(hash)")
        ]
        if usedETA, let tm = travelMinutes, tm > 0 {
            let originBit = originNote.map { " · \($0)" } ?? ""
            signals.insert(.init(kind: "travel", text: "路途约 \(tm) 分钟（MapKit）\(originBit)"), at: 1)
        } else {
            signals.insert(.init(kind: "travel", text: "未用到 ETA"), at: 1)
        }
        let title: String
        let reason: String
        if usedETA, let tm = travelMinutes, tm > 0 {
            title = "\(leaveAt.formatted(f)) 该出发 · \(signal.title)"
            let originBit = originNote.map { "（\($0)）" } ?? ""
            reason = lead.memory != nil
                ? "记忆提前 \(lead.minutes) 分钟 + 路途 \(tm) 分钟\(originBit) → \(leaveAt.formatted(f)) 出发（会 \(signal.start.formatted(f)) 开始）"
                : "默认提前 \(lead.minutes) 分钟 + 路途 \(tm) 分钟\(originBit) → \(leaveAt.formatted(f)) 出发"
        } else {
            title = "\(signal.start.formatted(f)) \(signal.title) · 要我 \(leaveAt.formatted(f)) 提醒你吗？"
            reason = lead.memory != nil
                ? "你习惯提前 \(lead.minutes) 分钟准备（未用到 ETA），提醒定在 \(leaveAt.formatted(f))"
                : "会议 \(Int(minutes)) 分钟后开始，默认提前 \(lead.minutes) 分钟（未用到 ETA）"
        }
        let suggestion = ProactiveSuggestion(
            id: "evt-" + hash,
            title: title, reason: reason,
            memories: memories, actions: [.create_reminder, .notify_attendees, .snooze, .dismiss],
            signals: signals, status: .pending, createdAt: now, trigger: ProactiveRules.localTrigger)
        let committed: ProactiveSuggestion? = AccountEpoch.shared.commit(token) { () -> ProactiveSuggestion in
            // A notification may have recovered and acted on this same meeting while evaluation awaited
            // its response. Preserve that newer inbox state instead of replacing it with a pending card.
            if let existing = ProactiveSuggestionStore.shared.items[suggestion.id] { return existing }
            pendingReminders[suggestion.id] = .init(title: signal.title, due: remindAt, start: signal.start, place: signal.place,
                                                    operationID: "op-" + hash, leaveAt: leaveAt, leadMinutes: lead.minutes,
                                                    travelMinutes: usedETA ? travelMinutes : nil, usedETA: usedETA)
            if !signal.attendeeNames.isEmpty || !signal.attendeeRecipients.isEmpty {
                pendingAttendees[suggestion.id] = (signal.attendeeNames, signal.attendeeRecipients)
            }
            rememberServerID(local: suggestion.id)
            if serverIDs[suggestion.id] == nil { localOnly.insert(suggestion.id) }   // evaluated offline: no cloud record
            ProactiveLocalBackend.save(suggestion, token: token)
            ProactiveSuggestionStore.shared.adopt(suggestion)
            lastSuggestionID = suggestion.id
            // Codex PR90 P2: quiet hours / cap against the real delivery instant (evaluation may have taken a while).
            intervene(suggestion, level: decision.level, now: ProactiveRules.deliveryInstant(evaluatedAt: now, startedWall: wallStart, wall: ProactiveClock.now()), token: token, eventID: signal.eventID)
            var delivered = signalLedger; delivered.markDelivered(hash, level: decision.level, now: now); signalLedger = delivered
            // Exactly once: the pipeline posts in place of this meeting's unfired pre-scheduled notification (or, if that one
            // already fired, treats it as the delivery and only shows the card).
            return suggestion
        }
        guard let committed else { note("account changed during evaluation → dropped (no save / notification / widget)"); return nil }
        return committed
    }

    /// NoBug: set to `{ ProactiveFeedbackSync.shared.gate(decision: $0, confidence: $1, trigger: $2) }` once 三角's P0-4 lands.
    static var feedbackGate: ((String, Double, String) -> String)?
    /// Codex PR90d: the gate actually applied — 三角's learned one when installed, else the on-device default built from
    /// this user's own feedback (`ProactiveLocalFeedback`: can only lower a level; no feedback → unchanged).
    static var effectiveFeedbackGate: (String, Double, String) -> String {
        if let feedbackGate { return feedbackGate }
        let local = ProactiveEngine.shared.localFeedback   // value snapshot: the closure needs no actor hop
        return { decision, _, trigger in local.gate(decision, trigger: trigger) }
    }
    private static let localFeedbackKey = "catpaw.proactive.feedback.local.v1"
    var localFeedback: ProactiveLocalFeedback {
        get { defaults.data(forKey: Self.localFeedbackKey).flatMap { try? JSONDecoder().decode(ProactiveLocalFeedback.self, from: $0) } ?? .init() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.localFeedbackKey) }
    }
    /// Local-only suggestions (evaluated offline, never got a server id): their write-backs have no cloud record to
    /// update, so they are dropped with a note instead of retrying into the dead-letter list.
    private static let localOnlyKey = "catpaw.proactive.localOnly.v1"
    private(set) var localOnly: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.localOnlyKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.localOnlyKey) }
    }
    struct Decision {
        var level: ProactiveLevel; var why: String; var via: String
        var intervene: Bool { level != .silent }
        init(level: ProactiveLevel, why: String, via: String) { self.level = level; self.why = why; self.via = via }
        init(intervene: Bool, why: String, via: String) { self.init(level: intervene ? .notify : .silent, why: why, via: via) }
    }
    private func evaluateLocal(_ s: ProactiveSignal, leadMinutes: Int, travelMinutes: Int? = nil, now: Date) -> Decision {
        let minutes = Int(s.start.timeIntervalSince(now) / 60)
        if minutes < 3 { return .init(intervene: false, why: "too late to help (\(minutes) min)", via: "local") }
        // Codex P0-5: too early → silent for now; the ledger lets it be re-evaluated as the meeting nears.
        if ProactiveRules.localLevel(minutesUntil: minutes, leadMinutes: leadMinutes, travelMinutes: travelMinutes) == .silent {
            return .init(intervene: false, why: "too early (\(minutes) min) · re-evaluate later", via: "local")
        }
        return .init(intervene: true, why: "meeting in \(minutes) min, lead \(leadMinutes) min", via: "local rules")
    }
    /// 三角's `/catpaw/proactive/v1` base (edge fn catpaw-proactive); nil when not configured / signed out.
    static func apiBase() -> URL? {
        let info = Bundle.main.infoDictionary
        guard let raw = (info?["CatpawProactiveBaseURL"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? (info?["CatpawSupabaseProjectURL"] as? String).flatMap({ $0.isEmpty ? nil : $0 + "/functions/v1/catpaw-proactive" }) else { return nil }
        return URL(string: raw)?.appendingPathComponent("catpaw/proactive/v1")
    }
    /// `token`: the account this request is for. Checked before and after the bearer await (so the bearer is that
    /// account's), and the response is discarded if the account changed while it was in flight (Codex PR90d #2).
    /// p90i (三角 trial S3): the token is required; nil is rejected (`ProactivePostGate`), never "no account check".
    static func post(_ path: String, _ body: [String: Any], token: AccountToken?) async -> [String: Any]? {
        guard ProactivePostGate.admit(token, epoch: .shared) else { return nil }
        guard let base = apiBase(), let bearer = try? await CatpawPushTokenUploader.shared.bearer() else { return nil }
        guard ProactivePostGate.admit(token, epoch: .shared) else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 6)
        request.httpMethod = "POST"; request.setValue(bearer, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = encodeBody(body)
        request.httpBody = payload
        // #63 S1: stable per (route, body) so a retry after a dropped response replays instead of re-running.
        let key = (body["operation_id"] as? String).map { "op-\($0)-\(path.split(separator: "/").last ?? "")" }
            ?? "pr-" + SHA256.hash(data: Data(path.utf8) + (payload ?? Data())).prefix(16).map { String(format: "%02x", $0) }.joined()
        request.setValue(String(key.prefix(200)), forHTTPHeaderField: "Idempotency-Key")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard ProactivePostGate.admit(token, epoch: .shared) else { return nil }
        return decodeResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
    /// The exact request bytes `post` sends (p90i P3: the host replay matches these byte for byte).
    static func encodeBody(_ body: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
    /// How `post` reads a response (200 → JSON; 403 → feature disabled; anything else → nil = retry).
    static func decodeResponse(status: Int, data: Data) -> [String: Any]? {
        if status == 403 { FeatureEnrollment.shared.proactiveDisabled = true; shared.note("server proactive feature_disabled → local rules; enroll prompt shown in Settings") }
        guard status == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    /// Codex PR90f #1: read-only `GET` under the same token rules as `post` (quarantine evidence: the cloud owns that id
    /// for this account). Next to 三角's `post`; `post` itself is unchanged.
    static func get(_ path: String, token: AccountToken) async -> [String: Any]? {
        guard AccountEpoch.shared.isValid(token), let base = apiBase(), let bearer = try? await CatpawPushTokenUploader.shared.bearer() else { return nil }
        guard AccountEpoch.shared.isValid(token) else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 6)
        request.httpMethod = "GET"; request.setValue(bearer, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), AccountEpoch.shared.isValid(token),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    /// The write-back transport (`post`); replaceable in tests so the real drain can be driven offline → online.
    var transport: (String, [String: Any], AccountToken) async -> [String: Any]? = { path, body, token in await ProactiveEngine.post(path, body, token: token) }
    /// Server suggestion id per local suggestion, for action/undo/feedback write-back. Persisted (Codex PR90 #5).
    /// p90i (三角 trial S5): partitioned by the data owner (`ProactiveServerIDMap`). The pre-p90i global map migrates
    /// to the recorded owner; with no / a signed-out owner it stays for the quarantine (`takeLegacyServerIDs`).
    private var serverIDMap: ProactiveServerIDMap {
        get { UserDefaults.standard.data(forKey: ProactiveServerIDMap.key).flatMap { try? JSONDecoder().decode(ProactiveServerIDMap.self, from: $0) } ?? .init() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: ProactiveServerIDMap.key) }
    }
    private var dataOwner: String? { UserDefaults.standard.object(forKey: ProactiveDataOwner.key) as? String }
    private func migrateLegacyServerIDs() {
        guard let legacy = UserDefaults.standard.dictionary(forKey: ProactiveServerIDMap.legacyKey) as? [String: String] else { return }
        let (m, q) = ProactiveServerIDMap.migrate(legacy: legacy, owner: dataOwner)
        if dataOwner == "" {   // signed-out owner: never handed to the next sign-in — parked as unknown-owner ids
            var lot = ProactiveParking.Lot(UserDefaults.standard.dictionary(forKey: ProactiveParking.key))
            lot.park(account: "(unknown)", record: ["at": ProactiveClock.now().timeIntervalSince1970, "serverIDs": q, "decision": "keep"])
            UserDefaults.standard.set(lot.raw, forKey: ProactiveParking.key); UserDefaults.standard.removeObject(forKey: ProactiveServerIDMap.legacyKey); return
        }
        guard q.isEmpty, let o = dataOwner else { return }   // no owner recorded: left for the quarantine
        var cur = serverIDMap; for (k, v) in m.ids(for: o) where cur.ids(for: o)[k] == nil { cur.set(k, v, account: o) }
        serverIDMap = cur; UserDefaults.standard.removeObject(forKey: ProactiveServerIDMap.legacyKey)
    }
    /// The unowned legacy global map, moved out (into the quarantine record) — never handed to the signed-in account.
    private func takeLegacyServerIDs() -> [String: String] {
        let legacy = UserDefaults.standard.dictionary(forKey: ProactiveServerIDMap.legacyKey) as? [String: String] ?? [:]
        UserDefaults.standard.removeObject(forKey: ProactiveServerIDMap.legacyKey); return legacy
    }
    private(set) var serverIDs: [String: String] {
        get { migrateLegacyServerIDs(); return serverIDMap.ids(for: dataOwner ?? "") }
        set { migrateLegacyServerIDs(); guard let o = dataOwner, !o.isEmpty else { return }; var m = serverIDMap; m.replace(newValue, account: o); serverIDMap = m }
    }
    func serverIDs(for account: String) -> [String: String] { serverIDMap.ids(for: account) }
    /// Pending action/undo write-backs: persisted, retried with backoff, bound to the account (Codex PR90 #5).
    struct SyncOp: Codable, Sendable {
        var local: String; var action: String; var operationID: String
        /// Codex PR90e #5: a snooze's own until (ISO 8601), so the cloud records the device's instant, not its own.
        var until: String? = nil
    }
    let syncQueue = CatpawPersistentQueue<SyncOp>(name: "proactive.sync")
    /// Codex PR90 #6: undo generations → fresh idempotency identity for actions re-taken after undo.
    fileprivate static let generationsKey = "catpaw.proactive.generations.v1"
    private var generations: ProactiveActionGenerations {
        get { UserDefaults.standard.data(forKey: Self.generationsKey).flatMap { try? JSONDecoder().decode(ProactiveActionGenerations.self, from: $0) } ?? .init() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.generationsKey) }
    }
    func operationID(_ local: String, _ action: String, ordinal: Int = 1) -> String {
        ProactiveRules.operationID(suggestion: local, action: action, generation: generations[local], ordinal: ordinal)
    }
    /// Every snooze notification this card may have pending: one per snooze intent, plus the pre-PR90e legacy id.
    func snoozeBases(_ s: ProactiveSuggestion) -> [String] {
        [s.id + "-snooze"] + (s.taken ?? []).filter { $0.action == .snooze }
            .compactMap { ProactiveUndo.snoozeIntent(detail: $0.detail) }.map { ProactiveDeliveryPipeline.snoozeBase(s.id, intent: $0) }
    }
    /// Codex PR90c #5 / PR90d #4 — the complete undo (catpaw.proactive.undo.v1, same as the server); the real UI entry
    /// `ProactiveLocalBackend.undo` calls this. Token bound before any await; reverts the last reversible action's real
    /// effect (reminder delete errors propagate; snooze notification cancelled; a snooze that becomes current again is
    /// re-armed at its own until), clears the cloud success state of the undone action, then persists and queues the
    /// cloud undo (fresh generation) under that token only.
    private(set) var lastUndoRestore: (id: String, outcome: String)?
    func undoLast(_ id: String) async throws -> ProactiveSuggestion {
        guard let token = AccountEpoch.shared.capture() else { throw ProactiveEngineError.writeFailed }
        claimData(for: token.account)
        var s = ProactiveLocalBackend.load()[id] ?? ProactiveSuggestionStore.shared.items[id] ?? ProactiveSuggestion(id: id, title: "", reason: "")   // persisted first (Mac c8aee26)
        let taken = s.taken ?? []
        let plan = ProactiveUndo.plan(offered: s.effectiveActions.map(\.rawValue), taken: taken.map(\.action.rawValue), status: s.effectiveStatus.rawValue)
        guard let removed = plan.removed, let index = plan.removedIndex else { note("undo: nothing reversible id=\(id)"); return s }
        if removed == "create_reminder" {
            #if canImport(EventKit)
            try await removeReminderChecked(id, token: token)
            #endif
        }
        guard AccountEpoch.shared.isValid(token) else { throw ProactiveEngineError.writeFailed }   // switched meanwhile: nothing saved
        if removed == "snooze" {   // exactly the undone intent's notification (+ the legacy id)
            delivery.remove(bases: [id + "-snooze"] + (ProactiveUndo.snoozeIntent(detail: taken[index].detail).map { [ProactiveDeliveryPipeline.snoozeBase(id, intent: $0)] } ?? []), token: token)
        }
        CatpawLeaveActivity.stop(suggestionID: id)
        var kept = taken; kept.remove(at: index); s.taken = kept
        s.status = ProactiveSuggestion.Status(rawValue: plan.status) ?? .pending
        s.serverActionStates?[removed] = nil   // the cloud's success of the undone action must not beat the undo
        let restore = ProactiveUndo.restoredSnooze(taken: kept.map { ($0.action.rawValue, $0.at, $0.detail, $0.until) }, status: plan.status)
        // Codex PR90f #2: the re-arm is awaited and its outcome recorded on the kept snooze entry (and `lastUndoRestore`),
        // so "snoozed again" is verifiable: posted / cardOnly:<reason> / refused:<reason> / expired.
        if let restore, let k = kept.lastIndex(where: { $0.action == .snooze }) {
            let outcome: String
            if restore > ProactiveClock.now() {
                let intent = ProactiveUndo.snoozeIntent(detail: kept[k].detail) ?? "restored-\(Int(restore.timeIntervalSince1970))"
                switch await snooze(s, until: restore, intent: intent, token: token) {
                case .posted: outcome = "posted"
                case .cardOnly(let r): outcome = "cardOnly:" + r
                case .refused(let r): outcome = "refused:" + r
                }
            } else { outcome = "expired" }
            kept[k].detail = ProactiveUndo.withRestore(kept[k].detail, outcome); s.taken = kept
            lastUndoRestore = (id, outcome)
            // Codex PR90g #2: shown "snoozed" only when the restored reminder really is scheduled; else the card is
            // actionable again (pending) and says the reminder could not be restored.
            s.status = ProactiveSuggestion.Status(rawValue: ProactiveUndo.statusAfterRestore(plan.status, outcome: outcome)) ?? .pending
        }
        guard AccountEpoch.shared.commit(token, { () -> Void in ProactiveLocalBackend.save(s, token: token) }) != nil else { throw ProactiveEngineError.writeFailed }
        var g = generations; let op = g.undo(id); generations = g
        syncAction("undo", local: id, operationID: op, token: token)
        return s
    }
    private var lastRemote: [String: Any]?
    /// `POST /catpaw/proactive/v1/evaluate`; nil (offline / not deployed) → local rules.
    private func evaluateRemote(_ s: ProactiveSignal, leadMinutes: Int, travelMinutes: Int? = nil, minutesUntil: Int? = nil, evaluateAt: Date? = nil, token: AccountToken? = nil) async -> Decision? {
        // Codex PR90d #2: bound to the originating token for real — `post(token:)` re-checks it around the bearer await
        // and the response.
        if let token, !AccountEpoch.shared.isValid(token) { return nil }
        let minutes = minutesUntil ?? Int(s.start.timeIntervalSince(ProactiveClock.now()) / 60)
        var data: [String: Any] = ["title": s.title, "location": s.place, "minutes_until": minutes]
        // Never claim ETA when unused / zero — omit the key rather than send 0.
        if let travelMinutes, travelMinutes > 0 { data["travel_minutes"] = travelMinutes }
        var context: [String: Any] = ["time_zone": TimeZone.current.identifier, "lead_minutes": leadMinutes]
        if let evaluateAt { context["evaluate_at"] = ISO8601DateFormatter().string(from: evaluateAt) }   // PR90d P2: judged at the fire instant
        let body: [String: Any] = ["signals": [["type": "meeting_upcoming", "source": s.source.rawValue, "dedupe_key": s.signalHash, "data": data]],
                                   "context": context]
        guard let json = await Self.post("evaluate", body, token: token) else { note("evaluate server unavailable → local rules"); lastRemote = nil; return nil }
        if let token, !AccountEpoch.shared.isValid(token) { lastRemote = nil; return nil }  // response of a gone account
        lastRemote = json
        let decision = (json["decision"] as? String) ?? "card"
        return .init(level: ProactiveLevel(server: decision), why: "\(decision) · \((json["reason"] as? String) ?? "") conf=\((json["confidence"] as? Double).map { String(format: "%.2f", $0) } ?? "-") source=\((json["source"] as? String) ?? "?")", via: "server")
    }
    func rememberServerID(local: String) {
        if let sug = lastRemote?["suggestion"] as? [String: Any], let id = sug["id"] as? String { serverIDs[local] = id }
        else if let id = lastRemote?["event_id"] as? String { serverIDs[local] = id }
        if serverIDs[local] != nil, syncQueue.items.contains(where: { $0.op.local == local }) { Task { await drainSync() } }
    }
    /// Codex PR90d #2: queued under the account the action was taken for (`token`), never "whoever is signed in now";
    /// a stale token enqueues nothing. One FIFO group per suggestion and no superseding: the cloud history must match the
    /// device's exactly, or a later undo reverts different actions on each side.
    func syncAction(_ action: String, local: String, operationID: String, until: Date? = nil, token: AccountToken?) {
        guard let token, AccountEpoch.shared.isValid(token) else { note("sync \(action) dropped: account changed"); return }
        syncQueue.enqueue(SyncOp(local: local, action: action, operationID: operationID, until: until.map { ISO8601DateFormatter().string(from: $0) }),
                          key: operationID, account: token.account, group: local, now: ProactiveClock.now())
        Task { await drainSync() }
    }
    static func syncBody(_ op: SyncOp) -> [String: Any] { ProactiveSyncWire.body(action: op.action, operationID: op.operationID, until: op.until) }
    /// Sends due write-backs. A missing server id (evaluated offline) or a network failure → retry later; restart-safe.
    /// Codex PR90h #3: registers a cloud card's write-back identity for the current account (never overwrites one). The
    /// card itself is persisted by the first perform / undo (both read the store's copy when the inbox has none).
    func adoptCloudIdentity(local: String, server: String) {
        guard let token = AccountEpoch.shared.capture() else { return }
        AccountEpoch.shared.commit(token) { () -> Void in
            claimData(for: token.account)
            if serverIDs[local] == nil { serverIDs[local] = server }
            localOnly.remove(local)
        }
        note("cloud card \(local) writes back to \(server)")
    }
    func drainSync() async {
        guard let token = AccountEpoch.shared.capture() else { return }
        let r = await syncQueue.drain(now: ProactiveClock.now(), account: token.account) { op in
            guard AccountEpoch.shared.isValid(token) else { return .retry }
            var sid = self.serverIDs[op.local]
            if sid == nil, self.localOnly.contains(op.local) {
                // Codex PR90f #5: offline-evaluated → create its cloud record first (idempotent by client id), then this
                // op and the rest of its FIFO group replay in order. Never dropped; a failure retries the whole group.
                guard let s = ProactiveSuggestionStore.shared.items[op.local] ?? ProactiveLocalBackend.load()[op.local] else { return .retry }
                let created = await self.transport("suggestions", ProactiveSyncWire.createBody(clientID: s.id, title: s.title, reason: s.reason,
                                                   actions: s.effectiveActions.map(\.rawValue), createdAt: s.createdAt), token)
                guard AccountEpoch.shared.isValid(token), let id = (created?["suggestion"] as? [String: Any])?["id"] as? String ?? created?["event_id"] as? String else {
                    self.note("offline suggestion \(op.local): cloud create failed → retry"); return .retry
                }
                AccountEpoch.shared.commit(token) { () -> Void in self.serverIDs[op.local] = id; self.localOnly.remove(op.local) }
                self.note("offline suggestion \(op.local) created in the cloud as \(id)"); sid = id
            }
            guard let id = sid else { return .retry }
            let res = await self.transport("suggestions/\(id)/\(ProactiveSyncWire.route(action: op.action))", Self.syncBody(op), token)
            self.note("server \(op.action) id=\(id) \(res == nil ? "failed → queued for retry" : "recorded")")
            return res == nil ? .retry : .done
        }
        if r.sent + r.retried + r.dropped > 0 { note("sync queue sent=\(r.sent) retry=\(r.retried) dead=\(r.dropped) left=\(syncQueue.items.count)") }
    }

    // MARK: Intervene: card + banner + actionable notification

    /// Codex P0-3 / PR90 #3: one persisted quota for in-app and pre-scheduled notifications (reservations + deliveries by identity).
    private let quotaKey = "catpaw.proactive.quota.v2"
    var quota: ProactiveQuotaLedger {
        get { defaults.data(forKey: quotaKey).flatMap { try? JSONDecoder().decode(ProactiveQuotaLedger.self, from: $0) } ?? ProactiveQuotaLedger() }
        set { var q = newValue; q.prune(now: ProactiveClock.now()); defaults.set(try? JSONEncoder().encode(q), forKey: quotaKey) }
    }
    private func deliveredToday(_ now: Date) -> Int { quota.count(on: now) }

    /// Codex PR90c: every proactive system notification goes through one pipeline (account barrier after the
    /// authorization await, quiet hours at the real fire instant, shared quota, late-completion removal).
    @ObservationIgnored lazy var delivery = ProactiveDeliveryPipeline(epoch: .shared, poster: ProactiveSystemPoster(), loadQuota: { [unowned self] in self.quota }, saveQuota: { [unowned self] in self.quota = $0 })

    private func intervene(_ s: ProactiveSuggestion, level: ProactiveLevel, now: Date, token: AccountToken, eventID: String? = nil) {
        let plan = ProactiveRules.delivery(level: level, now: now, deliveredToday: 0)
        note("deliver requested=\(level.name) → in-app=\(plan.inAppCard)")
        guard plan.inAppCard else { return }
        #if os(iOS)
        CatpawInAppBannerCenter.shared.show(CatpawInAppBanner(title: s.title, body: s.reason, symbol: "calendar.badge.clock", deepLink: URL(string: "catpawm://proactive")))
        #endif
        let deliveryID = serverIDs[s.id] ?? s.id  // one delivery id shared with APNs (server event_id when known)
        var q = quota; q.alias(deliveryID, to: s.id); quota = q
        let leave = pendingReminders[s.id]?.leaveAt, meeting = pendingReminders[s.id]?.title ?? s.title
        Task { @MainActor in
            let out = await delivery.deliverNow(id: s.id, requestID: deliveryID, title: s.title, body: s.reason, category: Self.notificationCategory,
                                                info: ["catpaw_proactive_id": s.id], requested: level, token: token,
                                                supersedes: eventID.map { ["pre-" + $0] } ?? [])
            note("intervene \(level.name) id=\(s.id) → \(out)")
            guard case .posted = out, level == .interrupt, let leave else { return }
            AccountEpoch.shared.commit(token) { CatpawLeaveActivity.start(suggestionID: s.id, meetingTitle: meeting, leaveAt: leave) }
        }
    }

    // MARK: Confirmed write (idempotent)

    struct PendingReminder: Codable, Sendable {
        var title: String; var due: Date; var start: Date; var place: String; var operationID: String
        /// leave_at = start - lead_minutes - travel_minutes (nil travel → lead only).
        var leaveAt: Date? = nil
        var leadMinutes: Int = 10
        var travelMinutes: Int? = nil
        /// false when MapKit ETA failed / skipped — Why must say 「未用到 ETA」.
        var usedETA: Bool = false
    }
    fileprivate static let attendeesKey = "catpaw.proactive.attendees.v1"
    private var pendingAttendees: [String: (names: [String], recipients: [String])] {
        get {
            guard let data = defaults.data(forKey: Self.attendeesKey),
                  let raw = try? JSONDecoder().decode([String: AttendeesDTO].self, from: data) else { return [:] }
            return raw.mapValues { ($0.names, $0.recipients) }
        }
        set {
            let raw = newValue.mapValues { AttendeesDTO(names: $0.names, recipients: $0.recipients) }
            defaults.set(try? JSONEncoder().encode(raw), forKey: Self.attendeesKey)
        }
    }
    private struct AttendeesDTO: Codable { var names: [String]; var recipients: [String] }
    private var pendingReminders: [String: PendingReminder] {
        get { (defaults.data(forKey: suggestionsKey)).flatMap { try? JSONDecoder().decode([String: PendingReminder].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: suggestionsKey) }
    }

    func pendingReminder(for suggestionID: String) -> PendingReminder? {
        pendingReminders[suggestionID]
    }
    func attendees(for suggestionID: String) -> (names: [String], recipients: [String]) {
        pendingAttendees[suggestionID] ?? ([], [])
    }

    enum WriteOutcome: Equatable { case created(String), alreadyExists(String), denied, failed(String) }

    /// Creates the EKReminder once per operation_id; a second confirm finds the existing one.
    /// `token`: the account the user confirmed under (taken before any await); the EventKit write commits only for it.
    /// (Same contract as 三角's #91 p91b-2 confirmReminder fix.)
    func confirmReminder(_ suggestionID: String, token: AccountToken? = AccountEpoch.shared.capture()) async -> WriteOutcome {
        guard token != nil else { return .failed("signed_out") }
        guard AccountEpoch.shared.isValid(token) else { return .failed("stale_account") }
        guard let p = pendingReminders[suggestionID] else { note("confirm unknown suggestion \(suggestionID)"); return .failed("unknown") }
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        let now = EKEventStore.authorizationStatus(for: .reminder)
        guard now == .fullAccess || now == .authorized else { note("write reminders=denied → degrade"); return .denied }
        let marker = URL(string: "catpawm://op/\(p.operationID)")!
        if let existing = await findReminder(marker: marker) {
            note("write idempotent: operation_id=\(p.operationID) already exists → no duplicate")
            return .alreadyExists(existing)
        }
        let r = EKReminder(eventStore: store)
        r.title = "准备：\(p.title)"
        r.notes = "Catpaw 主动提醒 · operation_id=\(p.operationID)" + (p.place.isEmpty ? "" : "\n地点：\(p.place)")
        r.url = marker
        r.calendar = store.defaultCalendarForNewReminders()
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: p.due)
        r.addAlarm(EKAlarm(absoluteDate: p.due))
        do {
            guard try AccountEpoch.shared.commit(token, { () throws -> Void in try store.save(r, commit: true) }) != nil else { note("write dropped: account changed"); return .failed("stale_account") }
            note("write EKReminder created operation_id=\(p.operationID) due=\(p.due.formatted(date: .omitted, time: .shortened))")
            return .created(r.calendarItemIdentifier)
        } catch { note("write failed: \(error.localizedDescription)"); return .failed(error.localizedDescription) }
        #else
        return .failed("no EventKit")
        #endif
    }
    #if canImport(EventKit)
    private func findReminder(marker: URL) async -> String? {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [String] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { items in
                c.resume(returning: (items ?? []).filter { $0.url == marker || ($0.notes ?? "").contains(marker.lastPathComponent) }.map(\.calendarItemIdentifier))
            }
        }
        return found.first
    }
    func removeReminder(_ suggestionID: String) async {
        do { try await removeReminderChecked(suggestionID, token: AccountEpoch.shared.capture()) } catch { note("undo reminder delete FAILED: \(error.localizedDescription)") }
    }
    /// Codex PR90c #5: a failed delete is an error (undo must not report success). Not found → nothing to remove.
    /// PR90d #2: the delete commits only for `token` (the account the undo started under).
    func removeReminderChecked(_ suggestionID: String, token: AccountToken?) async throws {
        guard let token else { throw ProactiveEngineError.writeFailed }
        // p90i (三角 trial S2): no mapping / no permission → unknown (caller keeps the state); authorized + not found → gone.
        let p = pendingReminders[suggestionID], auth = EKEventStore.authorizationStatus(for: .reminder)
        let authorized = auth == .fullAccess || auth == .authorized
        let id = (p != nil && authorized) ? await findReminder(marker: URL(string: "catpawm://op/\(p!.operationID)")!) : nil
        let item = id.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
        switch ProactiveUndo.reminderUndoStep(hasMapping: p != nil, authorized: authorized, found: item != nil) {
        case .unknown(let why): note("undo reminder unknown (\(why)) id=\(suggestionID) → state kept"); throw ProactiveEngineError.undoUnknown
        case .alreadyGone: note("undo reminder already gone id=\(suggestionID)"); return
        case .delete: break
        }
        guard let p, let item else { throw ProactiveEngineError.undoUnknown }
        guard try AccountEpoch.shared.commit(token, { () throws -> Void in try store.remove(item, commit: true) }) != nil else { throw ProactiveEngineError.writeFailed }
        note("undo removed reminder operation_id=\(p.operationID)")
    }
    #endif

    /// Codex PR90d #3: through the delivery pipeline (account/epoch stamp, scoped id, quota + quiet hours at the fire
    /// instant, late-completion cleanup).
    /// Awaited by the real entry, so the card says "snoozed" only when the notification really got scheduled (Codex PR90e #4).
    func snooze(_ s: ProactiveSuggestion, until: Date, intent: String, token: AccountToken) async -> ProactiveDeliveryPipeline.Outcome {
        let out = await delivery.snooze(id: s.id, intent: intent, title: s.title, body: s.reason, category: Self.notificationCategory,
                                        info: ["catpaw_proactive_id": s.id], fire: until, token: token)
        note("snooze id=\(s.id) intent=\(intent) until=\(until) → \(out)")
        return out
    }

    // MARK: MapKit travel ETA (transit preferred)

    /// Geocode meeting place → MKDirections.
    /// Origin = real CLLocation When-In-Use, or explicit debug 模拟起点. No silent Shanghai/CBD fallback.
    /// travel > 180 min → invalid → usedETA=false. Why must never claim ETA when unused.
    static func travelETA(
        to place: String,
        from origin: CLLocationCoordinate2D? = nil,
        simulatedLabel: String? = nil
    ) async -> (minutes: Int?, usedETA: Bool, originNote: String?) {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, false, nil) }
        let src: CLLocationCoordinate2D
        let note: String?
        if let origin, let label = simulatedLabel, !label.isEmpty {
            src = origin
            note = "从模拟起点 \(label)"
        } else if let origin, simulatedLabel == nil {
            // Caller passed a real/resolved coordinate (e.g. pipeline location) without a sim label.
            src = origin
            note = nil
        } else if let real = await Self.requestCurrentCoordinate() {
            src = real
            note = nil
        } else {
            return (nil, false, nil)  // no auth / no fix → 未用到 ETA
        }
        do {
            let geocoder = CLGeocoder()
            let marks = try await geocoder.geocodeAddressString(trimmed)
            guard let dest = marks.first?.location?.coordinate else { return (nil, false, note) }
            for mode in [MKDirectionsTransportType.transit, .automobile, .walking] {
                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: src))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
                req.transportType = mode
                req.requestsAlternateRoutes = false
                let directions = MKDirections(request: req)
                guard let resp = try? await directions.calculate(), let route = resp.routes.first else { continue }
                let mins = max(1, Int(route.expectedTravelTime / 60))
                if ProactiveRules.validTravel(mins) == nil { return (nil, false, note) }  // cap: > 180 min → invalid
                return (mins, true, note)
            }
            return (nil, false, note)
        } catch {
            return (nil, false, note)
        }
    }

    /// One-shot When-In-Use location. Returns nil if denied / undetermined (no prompt from background) / timeout.
    static func requestCurrentCoordinate() async -> CLLocationCoordinate2D? {
        #if canImport(CoreLocation) && os(iOS)
        let status = CLLocationManager.authorizationStatus()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        let probe = await MainActor.run { LocationOnceProbe() }
        return await probe.coordinate(timeout: 4)
        #else
        return nil
        #endif
    }

    // MARK: Out-of-app: pre-scheduled notification + BGAppRefresh

    /// Pre-schedules a local notification for the next event (fires even if the app is killed).
    func prescheduleNextEvent() async {
        #if canImport(EventKit) && os(iOS)
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return }
        guard let token = AccountEpoch.shared.capture() else { return }   // before any await (Codex PR90c / PR91c #2)
        claimData(for: token.account)
        let now = ProactiveClock.now(), lead = await leadTime()
        guard AccountEpoch.shared.isValid(token) else { note("preschedule dropped: account changed during lead lookup"); return }
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        guard let e = store.events(matching: predicate).filter({ !$0.isAllDay && $0.startDate > now }).sorted(by: { $0.startDate < $1.startDate }).first else { return }
        let fire = ProactiveRules.prescheduleFire(start: e.startDate, leadMinutes: lead.minutes)
        guard fire > now.addingTimeInterval(60) else { return }
        let signal = ProactiveSignal(source: .background, eventID: e.calendarItemIdentifier, title: e.title ?? "日程", start: e.startDate, place: e.location ?? "")
        let hash = signal.signalHash, identity = "evt-" + hash
        guard signalLedger.delivered[hash] == nil else { return }  // already delivered in-app
        // Codex PR90c #4: the cloud decision for the fire instant (silent → nothing), else local rules; then the learned
        // feedback gate with the trigger's confidence; then the device gate at the fire instant inside the pipeline.
        let cloud = await evaluateRemote(signal, leadMinutes: lead.minutes, minutesUntil: lead.minutes, evaluateAt: fire, token: token)
        guard AccountEpoch.shared.isValid(token) else { note("preschedule dropped: account changed during evaluate"); return }
        guard let level = ProactiveRules.prescheduleDecision(cloud: cloud?.level, leadMinutes: lead.minutes, gate: Self.effectiveFeedbackGate) else {
            delivery.remove(bases: ["pre-" + e.calendarItemIdentifier], token: token)
            note("preschedule skipped: decision \(cloud?.level.name ?? "local") below notify"); return
        }
        if cloud != nil { rememberServerID(local: identity) }  // the cloud event_id becomes the shared delivery id
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        let out = await delivery.preschedule(
            identity: identity, requestID: "pre-" + e.calendarItemIdentifier,
            title: "\(e.startDate.formatted(f)) \(e.title ?? "日程")", body: "要我提前 \(lead.minutes) 分钟提醒你准备吗？", category: Self.notificationCategory,
            info: ["catpaw_proactive_id": identity, "catpaw_proactive_event": e.calendarItemIdentifier, "catpaw_proactive_title": signal.title,
                   "catpaw_proactive_start": String(e.startDate.timeIntervalSince1970),
                   "catpaw_proactive_due": String(fire.timeIntervalSince1970), "catpaw_proactive_place": signal.place],
            fire: fire, level: level, token: token)
        note("preschedule \(fire.formatted(f)) \(e.title ?? "") → \(out)")
        #endif
    }

    #if os(iOS)
    /// The system's pending / delivered notifications (UNUserNotificationCenter); replaceable so a host test can drive the
    /// real account-change entry with local and APNs payloads of several accounts (Codex PR90f #6).
    var inventory: ProactiveNotificationInventory = SystemNotificationInventory()
    /// AccountEpoch (b) / Codex PR90d #1: runs via AccountChangeObservers ("proactive") after the synchronous epoch bump.
    /// Data: `claimData` (synchronous, before any await; same-account restore keeps everything). Notifications: only those
    /// that are not the current account's — resolved exactly like the receive gate, local stamp or APNs `catpaw.account`.
    func accountDidChange(previous: String?, current: String?) async {
        claimData(for: AccountEpoch.shared.currentAccount)   // same account → keep; never-owned → migrate; else wipe
        let pending = await inventory.pending()
        let shown = await inventory.delivered()
        let live = AccountEpoch.shared.currentAccount
        let p = pending.filter { ProactiveDataOwner.removeOnChange($0.info, current: live) }.map(\.id)
        let d = shown.filter { ProactiveDataOwner.removeOnChange($0.info, current: live) }.map(\.id)
        inventory.remove(pending: p, delivered: d)
        if let previous, !p.isEmpty { appendParkedNotifications(owner: previous, ids: p) }   // p90i: re-armable from the parked card
        await reconcileQuarantine()
        note("account \(previous ?? "-") → \(current ?? "-"): removed \(p.count) pending / \(d.count) delivered notifications of other accounts")
    }
    static var categories: Set<UNNotificationCategory> {
        let isChinese = Locale.current.language.languageCode?.identifier == "zh"
        return [UNNotificationCategory(identifier: notificationCategory, actions: [
            UNNotificationAction(identifier: createAction, title: isChinese ? "创建提醒" : "Create reminder", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "checklist")),
            UNNotificationAction(identifier: laterAction, title: isChinese ? "稍后提醒" : "Snooze", options: [], icon: UNNotificationActionIcon(systemImageName: "clock")),
            UNNotificationAction(identifier: notNowAction, title: isChinese ? "暂不处理" : "Not now", options: [], icon: UNNotificationActionIcon(systemImageName: "xmark"))],
            intentIdentifiers: [], options: [.customDismissAction])]
    }
    /// Notification action → the existing proactive action client. Returns true for every proactive payload,
    /// including malformed/unknown actions, so it can never fall through to an unrelated push action path.
    func handleNotification(actionIdentifier: String, userInfo: [AnyHashable: Any]) async -> Bool {
        let isProactive = userInfo["catpaw_proactive_id"] is String || userInfo["catpaw_proactive_event"] is String
        guard isProactive else { return false }
        // Codex PR90c / PR91c #2: a tap or action resumes only for the account + sign-in that scheduled it.
        guard ProactiveAccountGate.belongsToCurrent(userInfo, epoch: .shared) else { note("notification of another account/epoch dropped"); return true }

        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            _ = resolveNotificationSuggestion(userInfo)
            CatpawRouteCenter.shared.pending = .proactive
            return true
        }

        let action: ProactiveSuggestion.Action
        switch actionIdentifier {
        case Self.createAction: action = .create_reminder
        case Self.laterAction: action = .snooze
        case Self.notNowAction: action = .dismiss
        default:
            note("notification ignored action=\(actionIdentifier)")
            return true
        }

        guard let suggestion = resolveNotificationSuggestion(userInfo) else {
            note("notification unresolved suggestion")
            return true
        }
        let suggestions = ProactiveSuggestionStore.shared
        guard !suggestions.busy.contains(suggestion.id),
              suggestion.effectiveStatus == .pending || suggestion.effectiveStatus == .snoozed,
              suggestion.effectiveActions.contains(action) else {
            note("notification ignored unavailable action id=\(suggestion.id)")
            return true
        }
        await ProactiveSuggestionStore.shared.perform(action, suggestion)
        return true
    }

    private func resolveNotificationSuggestion(_ userInfo: [AnyHashable: Any]) -> ProactiveSuggestion? {
        let id = userInfo["catpaw_proactive_id"] as? String
        let context = notificationContext(userInfo)
        let signal = context.map {
            ProactiveSignal(source: .background, eventID: $0.eventID, title: $0.title, start: $0.start, place: $0.place)
        }
        if userInfo["catpaw_proactive_event"] != nil && context == nil { return nil }
        if let id, let signal, id != "evt-" + signal.signalHash { return nil }
        if let id, let suggestion = ProactiveSuggestionStore.shared.items[id] {
            guard pendingReminder(for: id).map({ $0.start > ProactiveClock.now() }) ?? true else { return nil }
            return suggestion
        }

        guard let signal, let context else { return nil }
        let expectedID = "evt-" + signal.signalHash
        if let existing = ProactiveSuggestionStore.shared.items[expectedID] { return existing }

        // Recover the scheduled meeting without evaluating it or posting another notification. Mark
        // its existing signal as seen so a foreground scan cannot generate a second intervention.
        // Written only under the token it was scheduled with; an untagged (legacy) payload resumes nothing (Codex PR90d #3).
        guard let token = delivery.resumeToken(userInfo) else { return nil }
        return AccountEpoch.shared.commit(token) { () -> ProactiveSuggestion in
        claimData(for: token.account)
        var seen = ledger
        seen[signal.signalHash] = ProactiveClock.now().timeIntervalSince1970
        ledger = seen
        var reminders = pendingReminders
        let reminder = reminders[expectedID] ?? PendingReminder(
            title: signal.title, due: context.due, start: signal.start, place: signal.place,
            operationID: "op-" + signal.signalHash
        )
        reminders[expectedID] = reminder
        pendingReminders = reminders
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let suggestion = ProactiveSuggestion(
            id: expectedID,
            title: "\(signal.start.formatted(time)) \(signal.title)",
            reason: "会议即将开始，准备提醒定在 \(reminder.due.formatted(time))",
            actions: [.create_reminder, .snooze, .dismiss],
            signals: [.init(kind: "calendar", text: "\(signal.start.formatted(time)) \(signal.title)")],
            status: .pending, createdAt: ProactiveClock.now()
        )
        ProactiveLocalBackend.save(suggestion, token: token)
        ProactiveSuggestionStore.shared.adopt(suggestion)
        return suggestion
        }
    }

    private func notificationContext(_ userInfo: [AnyHashable: Any]) -> CatpawScheduledMeetingNotification? {
        let now = ProactiveClock.now()
        if let context = CatpawScheduledMeetingNotification(userInfo: userInfo, defaultLeadMinutes: defaultLeadMinutes, now: now) {
            return context
        }
        // Only the legacy event-ID-only format needs an EventKit lookup. Invalid new metadata fails closed.
        guard userInfo["catpaw_proactive_title"] == nil, userInfo["catpaw_proactive_start"] == nil else { return nil }
        guard let eventID = userInfo["catpaw_proactive_event"] as? String, !eventID.isEmpty else { return nil }
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        if (status == .fullAccess || status == .authorized),
           let event = store.calendarItem(withIdentifier: eventID) as? EKEvent {
            var recovered = userInfo
            recovered["catpaw_proactive_title"] = event.title ?? "日程"
            recovered["catpaw_proactive_start"] = event.startDate.timeIntervalSince1970
            recovered["catpaw_proactive_place"] = event.location ?? ""
            return CatpawScheduledMeetingNotification(userInfo: recovered, defaultLeadMinutes: defaultLeadMinutes, now: now)
        }
        #endif
        return nil
    }

    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            Task { @MainActor in
                ProactiveEngine.shared.note("BGAppRefresh fired")
                await ProactiveEngine.shared.scanCalendar(source: .background)
                await ProactiveEngine.shared.prescheduleNextEvent()
                scheduleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }
    static func scheduleBackgroundRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: bgTaskID)
        r.earliestBeginDate = ProactiveClock.now().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    #endif
}

/// Real backend for the suggestion card/inbox: confirm writes the EKReminder.
@MainActor final class ProactiveLocalBackend: ProactiveSuggestionBackend {
    private static let key = "catpaw.proactive.inbox.v1"
    static var storageKey: String { key }
    /// Persisted inbox so cards survive relaunch / notification cold start.
    /// Codex PR90d #2: written only while `token` (the account the action started under) is current, owned by it.
    static func save(_ s: ProactiveSuggestion, token: AccountToken? = AccountEpoch.shared.capture()) {
        guard let token else { return }
        AccountEpoch.shared.commit(token) { () -> Void in
            ProactiveEngine.shared.claimData(for: token.account)
            var all = load(); all[s.id] = s
            UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
            CatpawWidgetSnapshotWriter.write(Array(all.values))
        }
    }
    static func wipe() { UserDefaults.standard.removeObject(forKey: key); CatpawWidgetSnapshotWriter.write([]) }
    static func load() -> [String: ProactiveSuggestion] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: ProactiveSuggestion].self, from: $0) } ?? [:]
    }
    private let mock = ProactiveSuggestionMock([])
    /// Codex PR90e #1: the inbox is shown only to its owner (or, before the upgrade migration ran, to the signed-in account).
    static var readable: Bool {
        ProactiveDataOwner.plan(owner: UserDefaults.standard.object(forKey: ProactiveDataOwner.key) as? String, current: AccountEpoch.shared.currentAccount) == .keep   // PR90f: unknown owner → not shown
    }
    init() {
        if Self.readable { for s in Self.load().values { mock.upsert(s); ProactiveSuggestionStore.shared.adopt(s) } }
        // Codex PR90d: a cloud state merged into an existing card is persisted, so a reload cannot resurrect the action.
        ProactiveSuggestionStore.shared.onMerged = { Self.save($0) }
        // Codex PR90h #3: a card that arrived from the cloud writes back to its own cloud record (and is kept locally, so
        // perform / undo / relaunch find it).
        ProactiveSuggestionStore.shared.onCloudIdentity = { local, server in ProactiveEngine.shared.adoptCloudIdentity(local: local, server: server) }
    }
    /// Codex P0-5: refresh reads the persisted inbox (the source every write path saves to), not an insert-only cache.
    func list() async throws -> [ProactiveSuggestion] {
        guard Self.readable else { return [] }
        return Self.load().values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
    func perform(_ action: ProactiveSuggestion.Action, on id: String) async throws -> ProactiveSuggestion {
        // Codex PR90d #2: bound before any await; every effect, save and enqueue below commits for this account only.
        guard let token = AccountEpoch.shared.capture() else { throw ProactiveEngineError.writeFailed }
        ProactiveEngine.shared.claimData(for: token.account)
        // Mac c8aee26: read the persisted inbox first — the source every write saves to. The card store's copy is not
        // updated by this entry, so a stale copy reused the first snooze's intent (same id → already_delivered / the
        // failed re-snooze tearing down the original).
        var s = ProactiveLocalBackend.load()[id] ?? ProactiveSuggestionStore.shared.items[id] ?? ProactiveSuggestion(id: id, title: "", reason: "")
        // Codex PR90 #4: check the persisted success (local + cloud action_states) before running an effect again.
        guard ProactiveActionStates.shouldExecute(action.rawValue, s.actionStates) else {
            ProactiveEngine.shared.note("\(action.rawValue) already succeeded for \(id) → not run again"); return s
        }
        switch action {
        case .create_reminder:
            switch await ProactiveEngine.shared.confirmReminder(id, token: token) {
            case .created: s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now(), detail: "已写入提醒事项", outcome: .succeeded)]
            case .alreadyExists: s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now(), detail: "提醒已存在，未重复创建", outcome: .succeeded)]
            case .denied: throw ProactiveEngineError.remindersDenied
            case .failed: throw ProactiveEngineError.writeFailed
            }
        case .snooze:
            // Codex PR90e #4 #5: one intent = one operation id = one notification; shown snoozed only if it was scheduled.
            let intent = ProactiveEngine.shared.operationID(id, action.rawValue, ordinal: (s.taken ?? []).filter { $0.action == .snooze }.count + 1)
            let until = ProactiveClock.now().addingTimeInterval(600)
            // Codex PR90f #2: the new snooze is scheduled (and confirmed by the system) first; only then is the previous one
            // removed. Any failure throws with the original reminder, status and history untouched.
            let previous = ProactiveEngine.shared.snoozeBases(s)
            switch await ProactiveEngine.shared.snooze(s, until: until, intent: intent, token: token) {
            case .posted: break
            case .cardOnly: throw ProactiveEngineError.snoozeNotScheduled
            case .refused: throw ProactiveEngineError.writeFailed
            }
            let fresh = ProactiveDeliveryPipeline.snoozeBase(id, intent: intent)
            ProactiveEngine.shared.delivery.remove(bases: previous.filter { $0 != fresh }, token: token)
            s.status = .snoozed; s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now(), detail: ProactiveUndo.snoozeDetail(until: until, intent: intent))]
        case .dismiss:
            CatpawLeaveActivity.stop(suggestionID: id)
            ProactiveEngine.shared.delivery.remove(bases: ProactiveEngine.shared.snoozeBases(s), token: token)  // dismiss cancels every pending snooze
            s.status = .dismissed; s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now())]
        case .notify_attendees:
            // P0-4: MessageUI via DeviceToolRouter — never mark done unless compose was presented and user sent.
            let outcome = await Self.notifyAttendees(for: id)
            guard AccountEpoch.shared.isValid(token) else { throw ProactiveEngineError.writeFailed }   // switched while the sheet was up
            switch outcome {
            case .sent:
                s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now(), detail: "已发送短信", outcome: .succeeded)]
            case .cancelled:
                // Sheet opened then cancelled — stay pending; record evidence without done (and never sync it).
                s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now(), detail: "已打开短信 · 已取消", outcome: .cancelled)]
            case .unavailable:
                s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now(), detail: "本机无法发短信（模拟器常见）", outcome: .unavailable)]
                mock.upsert(s); Self.save(s, token: token)  // persist evidence; stay pending
                throw ProactiveEngineError.smsUnavailable
            case .error:
                s.taken = (s.taken ?? []) + [.init(action: action, at: ProactiveClock.now(), detail: "短信打开失败", outcome: .failed)]
                mock.upsert(s); Self.save(s, token: token)
                throw ProactiveEngineError.writeFailed
            }
        }
        // Codex P0-5: an effect is done for the card only when every offered effect succeeded.
        if action == .create_reminder || action == .notify_attendees { s.status = s.allEffectsDone ? .done : .pending }
        // Only a real success is synced; a cancelled / unavailable SMS never reaches the cloud as notify_attendees.
        let state = s.actionStates[action.rawValue]
        if !ProactiveActionStates.effects.contains(action.rawValue) || state.map(ProactiveActionStates.shouldSync) == true {
            // Codex PR90e #5: a new intent of a repeatable action (snooze, dismiss) gets a new id; a queued retry keeps its own.
            let ordinal = ProactiveActionStates.effects.contains(action.rawValue) ? 1 : (s.taken ?? []).filter { $0.action == action }.count
            let until = action == .snooze ? s.taken?.last.map { ProactiveUndo.snoozeUntil(detail: $0.detail, at: $0.at, until: $0.until) } : nil
            ProactiveEngine.shared.syncAction(action.rawValue, local: id, operationID: ProactiveEngine.shared.operationID(id, action.rawValue, ordinal: ordinal), until: until, token: token)
        }
        guard AccountEpoch.shared.isValid(token) else { throw ProactiveEngineError.writeFailed }
        mock.upsert(s); Self.save(s, token: token); return s
    }
    /// Codex PR90d #4: the real entry delegates to the engine's complete undo (catpaw.proactive.undo.v1).
    func undo(_ id: String) async throws -> ProactiveSuggestion {
        let s = try await ProactiveEngine.shared.undoLast(id)
        mock.upsert(s); return s
    }
    func feedback(_ value: ProactiveFeedback, on id: String) async throws {
        // Codex PR90d: feeds the on-device default gate (used until 三角's learned gate is installed).
        let trigger = ProactiveSuggestionStore.shared.items[id]?.trigger ?? ProactiveRules.localTrigger
        var f = ProactiveEngine.shared.localFeedback; f.record(value, trigger: trigger); ProactiveEngine.shared.localFeedback = f
        ProactiveEngine.shared.note("feedback \(value.rawValue) id=\(id) trigger=\(trigger)")
        // PR91 P0-4 (trial merge): also persisted per account and posted to the server; throws when only queued (待同步).
        try await ProactiveFeedbackSync.shared.submit(value, suggestionID: id, trigger: trigger, serverID: ProactiveEngine.shared.serverIDs[id])
    }
}

extension ProactiveLocalBackend {
    /// Builds a short 「告诉参会人」 draft from the pending meeting and presents MessageUI.
    fileprivate static func notifyAttendees(for suggestionID: String) async -> DeviceToolRouter.NotifyComposeOutcome {
        let pending = ProactiveEngine.shared.pendingReminder(for: suggestionID)
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        let title = pending?.title ?? "会议"
        let start = pending.map { $0.start.formatted(f) } ?? ""
        let place = pending?.place ?? ""
        var lines = ["我可能稍晚到一下（Catpaw 提醒）。", "会议：\(title)" + (start.isEmpty ? "" : " · \(start)")]
        if !place.isEmpty { lines.append("地点：\(place)") }
        if let leaveAt = pending?.leaveAt {
            lines.append("我计划 \(leaveAt.formatted(f)) 出发")
        }
        let attendees = ProactiveEngine.shared.attendees(for: suggestionID)
        if !attendees.names.isEmpty { lines.append("参会人：" + attendees.names.joined(separator: "、")) }
        let body = lines.joined(separator: "\n")
        let recipients = attendees.recipients
        let router = (DeviceCallHub.executor as? DeviceToolRouter) ?? DeviceToolRouter()
        ProactiveEngine.shared.note("notify_attendees present MessageUI suggestion=\(suggestionID) recipients=\(recipients.count)")
        return await router.notifyAttendeesCompose(body: body, recipients: recipients)
    }
}


/// Debug panel / degrade card adapter: simulated meetings go through the same real pipeline.
struct ProactiveEngineSignalAdapter: ProactiveSignalEngine {
    func run(_ input: ProactiveSignalInput, update: @escaping @Sendable (ProactiveStageResult) async -> Void) async -> ProactivePipelineSuggestion? {
        await update(.init(stage: .collect, status: .passed, details: ["meetings=\(input.meetings.count)", "calendar=\(input.calendarAuthorized ? "authorized" : "manual")"]))
        guard let m = input.meetings.filter({ $0.start > input.now }).sorted(by: { $0.start < $1.start }).first else {
            for s in [ProactivePipelineStage.filter, .merge, .decide, .intervene] { await update(.init(stage: s, status: .skipped, details: ["no candidate"])) }
            return nil
        }
        let signal = ProactiveSignal(source: input.calendarAuthorized ? .simulated : .manual, eventID: m.id.uuidString, title: m.title, start: m.start, place: m.place)
        await update(.init(stage: .filter, status: .passed, details: ["next=\(m.title)", "signal_hash=\(signal.signalHash)"]))
        let result = await ProactiveEngine.shared.handle(signal, now: input.now)
        let last = await MainActor.run { ProactiveEngine.shared.log.first?.text ?? "" }
        await update(.init(stage: .merge, status: result == nil ? .skipped : .passed, details: [last]))
        await update(.init(stage: .decide, status: result == nil ? .skipped : .passed, details: result.map { [$0.reason] } ?? ["suppressed / silent"]))
        await update(.init(stage: .intervene, status: result == nil ? .skipped : .passed, details: result == nil ? [] : ["card + banner + notification"]))
        return result.map { ProactivePipelineSuggestion(id: $0.id, kind: "meeting_prep", title: $0.title, body: $0.reason, channel: .push, meetingTitle: m.title, meetingStart: m.start, place: m.place, leaveAt: nil) }
    }
}


/// #48: App Group snapshot for the Home/Lock widgets. The widget reads the same JSON (`catpaw.widget.snapshot.v1.json`);
/// without the App Group entitlement (`group.com.yankj.catpawm`, needs portal registration) the container is nil,
/// nothing is written and the widget shows its truthful empty state.
@MainActor enum CatpawWidgetSnapshotWriter {
    static let group = "group.com.yankj.catpawm"
    static let file = "catpaw.widget.snapshot.v1.json"
    static func write(_ suggestions: [ProactiveSuggestion]) {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let now = ProactiveClock.now()
        let pending = suggestions
            .filter {
                $0.effectiveStatus == .pending &&
                (ProactiveEngine.shared.pendingReminder(for: $0.id).map { $0.start > now } ?? true)
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                return $0.id < $1.id
            }

        var body: [String: Any] = [
            "version": 2,
            "updated_at": now.timeIntervalSince1970,
        ]
        if let suggestion = pending.first {
            var value: [String: Any] = [
                "id": suggestion.id,
                "title": suggestion.title,
                "why": suggestion.reason,
            ]
            if let reminder = ProactiveEngine.shared.pendingReminder(for: suggestion.id) {
                value["expires_at"] = reminder.start.timeIntervalSince1970
            }
            body["suggestion"] = value
        }

        let meetings: [(suggestion: ProactiveSuggestion, signal: ProactiveSuggestion.Signal, reminder: ProactiveEngine.PendingReminder?)] = pending.compactMap { suggestion in
            guard let signal = suggestion.signals?.first(where: { $0.kind == "calendar" }) else { return nil }
            return (suggestion, signal, ProactiveEngine.shared.pendingReminder(for: suggestion.id))
        }
        let meeting = meetings.min { lhs, rhs in
            if let left = lhs.reminder?.start, let right = rhs.reminder?.start { return left < right }
            if lhs.reminder != nil { return true }
            if rhs.reminder != nil { return false }
            return (lhs.suggestion.createdAt ?? .distantFuture) < (rhs.suggestion.createdAt ?? .distantFuture)
        }
        if let meeting {
            var value: [String: Any] = [
                "id": meeting.suggestion.id,
                "title": meeting.reminder?.title ?? meeting.signal.text,
                "why": meeting.suggestion.reason,
            ]
            if let reminder = meeting.reminder {
                value["starts_at"] = reminder.start.timeIntervalSince1970
                if !reminder.place.isEmpty { value["place"] = reminder.place }
            }
            body["meeting"] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
}


#if canImport(CoreLocation) && os(iOS)
/// Single-fix CLLocationManager wrapper for travelETA origin.
@MainActor private final class LocationOnceProbe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var authCont: CheckedContinuation<Bool, Never>?
    func requestWhenInUse() async -> Bool {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { cont in
            self.authCont = cont
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }
    func coordinate(timeout: TimeInterval) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            self.cont = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish(nil)
            }
        }
    }
    private func finish(_ c: CLLocationCoordinate2D?) {
        guard let cont else { return }
        self.cont = nil
        cont.resume(returning: c)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined, let authCont else { return }
        self.authCont = nil
        authCont.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
    }
}
#endif

#if canImport(ActivityKit) && os(iOS)
import ActivityKit


@MainActor enum CatpawLeaveActivity {
    static func start(suggestionID: String, meetingTitle: String, leaveAt: Date) {
        CatpawLiveActivityCoordinator.shared.startLeaveCountdown(suggestionID: suggestionID, meetingTitle: meetingTitle, leaveAt: leaveAt)
    }
    static func stop(suggestionID: String) {
        CatpawLiveActivityCoordinator.shared.stopLeaveCountdown(suggestionID: suggestionID)
    }
    /// Sign-out: end every Live Activity of every type — departure countdowns (also from before a relaunch) and the
    /// work activity, whose pending start timer is cancelled (Codex PR91 p91b-3).
    /// Test seam (PR91 XCTest): observes stopAll() for sign-out ordering.
    nonisolated(unsafe) static var stopAllObserver: (() -> Void)?
    static func stopAll() {
        stopAllObserver?()
        let ids = Set(Activity<CatpawLeaveAttributes>.activities.map { $0.attributes.suggestionID })
        for id in ids { stop(suggestionID: id) }
        CatpawLiveActivityCoordinator.shared.resetForSignOut()
    }
}
#else
@MainActor enum CatpawLeaveActivity {
    static func start(suggestionID: String, meetingTitle: String, leaveAt: Date) {}
    static func stop(suggestionID: String) {}
    nonisolated(unsafe) static var stopAllObserver: (() -> Void)?
    static func stopAll() { stopAllObserver?() }
}
#endif



/// UNUserNotificationCenter behind `ProactiveNotificationPoster` (Codex PR90c). The add is enqueued, never awaited
/// inside the account barrier; its completion feeds the pipeline's late-completion cleanup.
@MainActor final class ProactiveSystemPoster: ProactiveNotificationPoster {
    /// Keys CatpawScheduledMeetingNotification reads as TimeInterval.
    static let numericKeys: Set<String> = ["catpaw_proactive_start", "catpaw_proactive_due"]
    func requestAuthorization() async -> Bool {
        #if os(iOS)
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        #else
        return false
        #endif
    }
    func add(_ r: ProactiveNotificationRequest, completion: @escaping @MainActor (Bool) -> Void) {
        #if os(iOS)
        let content = UNMutableNotificationContent()
        content.title = r.title; content.body = r.body; content.categoryIdentifier = r.category
        content.sound = r.level >= .notify ? .default : nil
        content.interruptionLevel = r.level == .interrupt ? .timeSensitive : .active
        content.userInfo = r.info.reduce(into: [AnyHashable: Any]()) { out, kv in
            out[kv.key] = Self.numericKeys.contains(kv.key) ? (Double(kv.value) as Any? ?? kv.value) : kv.value
        }
        let trigger: UNNotificationTrigger
        if let fireAt = r.fireAt {
            trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt), repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: ProactiveDeliveryPipeline.postDelay, repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger)) { error in
            let ok = error == nil
            Task { @MainActor in completion(ok) }
        }
        #else
        completion(false)
        #endif
    }
    func remove(ids: [String]) {
        #if os(iOS)
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ids); c.removeDeliveredNotifications(withIdentifiers: ids)
        #endif
    }
}

/// Codex PR90f #6: pending / delivered notifications, narrowed (UNUserNotificationCenter in the app, a fake in host tests).
struct ProactiveInventoryItem: @unchecked Sendable { var id: String; var info: [AnyHashable: Any] }
@MainActor protocol ProactiveNotificationInventory {
    func pending() async -> [ProactiveInventoryItem]
    func delivered() async -> [ProactiveInventoryItem]
    func remove(pending: [String], delivered: [String])
}
#if os(iOS)
@MainActor struct SystemNotificationInventory: ProactiveNotificationInventory {
    func pending() async -> [ProactiveInventoryItem] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map { .init(id: $0.identifier, info: $0.content.userInfo) }
    }
    func delivered() async -> [ProactiveInventoryItem] {
        await UNUserNotificationCenter.current().deliveredNotifications().map { .init(id: $0.request.identifier, info: $0.request.content.userInfo) }
    }
    func remove(pending: [String], delivered: [String]) {
        let c = UNUserNotificationCenter.current(); c.removePendingNotificationRequests(withIdentifiers: pending); c.removeDeliveredNotifications(withIdentifiers: delivered)
    }
}
#endif
