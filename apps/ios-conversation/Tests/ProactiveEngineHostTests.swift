import XCTest
import UserNotifications
@testable import CatpawM

/// Codex PR90c: regressions on the real host call chain (ProactiveEngine / ProactiveLocalBackend / ProactiveSuggestionStore /
/// the real `ProactiveSuggestion` decoder). Only UNUserNotificationCenter is replaced (by `delivery.poster`), so every
/// add/remove counted here is a call the shipping code would make. Run on a simulator (any, not BE5C):
///   xcodebuild test -scheme CatpawM -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CatpawMTests/ProactiveEngineHostTests
@MainActor final class ProactiveEngineHostTests: XCTestCase {
    final class Poster: ProactiveNotificationPoster {
        var adds: [ProactiveNotificationRequest] = [], removed: [String] = []
        var duringAuthorization: (() -> Void)?
        /// What the system answers to an add (PR90f: the snooze paths await it).
        var addResult = true
        func requestAuthorization() async -> Bool { duringAuthorization?(); return true }
        func add(_ r: ProactiveNotificationRequest, completion: @escaping @MainActor (Bool) -> Void) { adds.append(r); completion(addResult) }
        func remove(ids: [String]) { removed += ids }
    }
    /// Fake pending / delivered system notifications for the real account-change entry (PR90f #6).
    final class Inventory: ProactiveNotificationInventory {
        var pendingItems: [ProactiveInventoryItem] = [], deliveredItems: [ProactiveInventoryItem] = []
        var removedPending: [String] = [], removedDelivered: [String] = []
        func pending() async -> [ProactiveInventoryItem] { pendingItems }
        func delivered() async -> [ProactiveInventoryItem] { deliveredItems }
        func remove(pending: [String], delivered: [String]) { removedPending += pending; removedDelivered += delivered }
    }
    private var poster = Poster(), inventory = Inventory()
    private var saved: ProactiveNotificationPoster?
    /// PR90f (Mac run): no test reads the wall clock. Daytime and night instants in the machine's own calendar.
    static func local(_ h: Int, _ m: Int = 0, day: Int = 15) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
    static let day = local(10), night = local(23, 30)
    private var calls: [String] = []
    private var savedBackend: (any ProactiveSuggestionBackend)?

    override func setUp() async throws {
        ProactiveClock.now = { Self.day }
        saved = ProactiveEngine.shared.delivery.poster
        poster = Poster(); ProactiveEngine.shared.delivery.poster = poster
        ProactiveEngine.shared.delivery.clock = { ProactiveClock.now() }
        inventory = Inventory(); ProactiveEngine.shared.inventory = inventory
        calls = []; ProactiveEngine.shared.transport = { [weak self] path, _, _ in self?.calls.append(path); return nil }   // offline unless a test says so
        ProactiveEngine.shared.serverProbe = { _, _ in false }
        UserDefaults.standard.removeObject(forKey: ProactiveQuarantine.key)
        UserDefaults.standard.removeObject(forKey: ProactiveParking.key); UserDefaults.standard.removeObject(forKey: ProactiveServerIDMap.key)
        AccountEpoch.shared.activate(account: "XCTEST-A")
        ProactiveEngine.shared.claimData(for: "XCTEST-A", force: true)   // clean inbox/ledgers, owned by this account
        ProactiveEngine.shared.resetLedger()
        savedBackend = ProactiveSuggestionHub.backend; ProactiveSuggestionHub.backend = ProactiveLocalBackend()   // PR90g: the real UI path
        ProactiveSuggestionStore.shared.resetForAccountChange()
    }
    override func tearDown() async throws {
        if let saved { ProactiveEngine.shared.delivery.poster = saved }
        ProactiveEngine.shared.delivery.clock = { ProactiveClock.now() }
        ProactiveEngine.shared.inventory = SystemNotificationInventory()
        ProactiveEngine.shared.transport = { path, body, token in await ProactiveEngine.post(path, body, token: token) }
        ProactiveEngine.shared.serverProbe = { id, token in await ProactiveEngine.get("suggestions/\(id)", token: token) != nil }
        UserDefaults.standard.removeObject(forKey: ProactiveQuarantine.key)
        AccountEpoch.shared.signOut()
        ProactiveClock.now = { Date() }
        if let savedBackend { ProactiveSuggestionHub.backend = savedBackend }
    }
    private func signal(_ id: String, inMinutes m: Double = 8) -> ProactiveSignal {
        ProactiveSignal(source: .simulated, eventID: id + UUID().uuidString, title: "XCTest 会议", start: ProactiveClock.now().addingTimeInterval(m * 60), place: "")
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(400)) }

    func testSignedOutHandleDoesNothing() async {
        AccountEpoch.shared.signOut()
        let s = await ProactiveEngine.shared.handle(signal("signed-out"))
        await settle()
        XCTAssertNil(s); XCTAssertTrue(poster.adds.isEmpty)
    }

    func testSignOutDuringNotificationAuthorizationPostsNothing() async {
        poster.duringAuthorization = { AccountEpoch.shared.signOut() }
        _ = await ProactiveEngine.shared.handle(signal("auth-race"))
        await settle()
        XCTAssertTrue(poster.adds.isEmpty, "token re-validated after the authorization await")
    }

    func testDeliveredNotificationCarriesAccountAndEpoch() async throws {
        _ = await ProactiveEngine.shared.handle(signal("stamp"))
        await settle()
        let add = try XCTUnwrap(poster.adds.first)
        XCTAssertEqual(add.info[ProactiveAccountGate.accountKey], "XCTEST-A")
        XCTAssertEqual(add.info[ProactiveAccountGate.epochKey], String(AccountEpoch.shared.epoch))
        // Tap after an account switch: dropped, nothing written into the new account's inbox.
        AccountEpoch.shared.activate(account: "XCTEST-B")
        let before = ProactiveLocalBackend.load().count
        let info = add.info.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value }
        _ = await ProactiveEngine.shared.handleNotification(actionIdentifier: ProactiveEngine.notNowAction, userInfo: info)
        XCTAssertEqual(ProactiveLocalBackend.load().count, before)
    }

    func testRealDecoderAndExistingCardMergeCloudSuccess() throws {
        let id = "xctest-merge-" + UUID().uuidString
        let pending = try XCTUnwrap(ProactiveSuggestionAdapter.decode(Data(#"{"id":"\#(id)","title":"t","reason":"r","actions":["create_reminder","notify_attendees","dismiss"],"status":"pending"}"#.utf8)))
        ProactiveSuggestionStore.shared.adopt(pending)
        XCTAssertTrue(ProactiveSuggestionStore.shared.current(pending).remainingActions.contains(.notify_attendees))
        let update = try XCTUnwrap(ProactiveSuggestionAdapter.decode(Data(#"{"id":"\#(id)","title":"t","reason":"r","actions":["create_reminder","notify_attendees","dismiss"],"status":"pending","action_states":{"notify_attendees":"done"}}"#.utf8)))
        XCTAssertEqual(update.serverActionStates?["notify_attendees"], "done", "real ProactiveSuggestion decodes action_states")
        ProactiveSuggestionStore.shared.adopt(update)
        XCTAssertFalse(ProactiveSuggestionStore.shared.current(pending).remainingActions.contains(.notify_attendees), "existing card merged the cloud success")
    }

    func testDismissCancelsSnoozeNotification() async throws {
        let id = "xctest-dismiss-" + UUID().uuidString
        ProactiveSuggestionStore.shared.adopt(ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.snooze, .dismiss], status: .snoozed, createdAt: ProactiveClock.now()))
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: id)
        XCTAssertTrue(poster.removed.contains(id + "-snooze"))
    }

    func testUndoLastKeepsSentSMSAndQueuesCloudUndo() async throws {
        let id = "xctest-undo-" + UUID().uuidString
        let s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .notify_attendees, .dismiss], status: .dismissed, createdAt: ProactiveClock.now(),
                                    taken: [.init(action: .notify_attendees, at: ProactiveClock.now(), detail: "已发送短信", outcome: .succeeded), .init(action: .dismiss, at: ProactiveClock.now())])
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        let after = try await ProactiveEngine.shared.undoLast(id)
        XCTAssertEqual(after.taken?.map(\.action), [.notify_attendees]); XCTAssertEqual(after.effectiveStatus, .pending)
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == id && $0.op.action == "undo" })
        XCTAssertNotEqual(ProactiveEngine.shared.operationID(id, "dismiss"), "op-\(id)-dismiss", "fresh identity after undo")
    }

    func testAccountChangeObserverRegisteredAndWipesOnSignOutNotify() async {
        ProactiveEngine.registerAccountObserver()          // launch path (idempotent; init registers too)
        _ = ProactiveEngine.shared
        XCTAssertTrue(AccountChangeObservers.registeredKeys.contains("proactive"))
        let id = "xctest-observer-" + UUID().uuidString
        ProactiveLocalBackend.save(ProactiveSuggestion(id: id, title: "t", reason: "r", status: .pending, createdAt: ProactiveClock.now()))
        AccountEpoch.shared.signOut()                       // sync bump first (NativeAuthApplicationModel order)
        await AccountChangeObservers.notify(previous: "XCTEST-A", current: nil)
        XCTAssertNil(ProactiveLocalBackend.load()[id], "previous account's inbox wiped by the registered observer")
    }

    // MARK: Codex PR90d
    func testBackendUndoEntryUsesUndoLast() async throws {
        let id = "xctest-bundo-" + UUID().uuidString
        let s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .snooze, .dismiss], status: .dismissed, createdAt: ProactiveClock.now(),
                                    taken: [.init(action: .snooze, at: ProactiveClock.now(), detail: ProactiveUndo.snoozeDetail(until: ProactiveClock.now().addingTimeInterval(600))), .init(action: .dismiss, at: ProactiveClock.now())])
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        let after = try await ProactiveLocalBackend().undo(id)   // the real UI entry
        await settle()
        XCTAssertEqual(after.taken?.map(\.action), [.snooze], "undo.v1: only the last action reverted")
        XCTAssertEqual(after.effectiveStatus, .snoozed)
        XCTAssertTrue(poster.adds.contains { $0.id.hasPrefix(id + "-snooze") }, "undoing the dismiss restores the snooze notification")
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == id && $0.op.action == "undo" && $0.account == "XCTEST-A" })
        XCTAssertEqual(ProactiveUndo.restoreOutcome(detail: after.taken?.last?.detail), "posted", "PR90f #2: the re-arm result is recorded on the kept snooze")
        XCTAssertEqual(ProactiveEngine.shared.lastUndoRestore?.outcome, "posted")
        XCTAssertEqual(ProactiveUndo.restoreOutcome(detail: ProactiveLocalBackend.load()[id]?.taken?.last?.detail), "posted", "and persisted")
    }
    func testUndoClearsServerSuccessOfTheUndoneAction() async throws {
        let id = "xctest-sas-" + UUID().uuidString
        var s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .dismiss], status: .done, createdAt: ProactiveClock.now(),
                                    taken: [.init(action: .dismiss, at: ProactiveClock.now())])
        s.serverActionStates = ["dismiss": "done"]
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        let after = try await ProactiveLocalBackend().undo(id)
        XCTAssertNil(after.serverActionStates?["dismiss"], "cloud state of the undone action does not beat the undo")
    }
    func testSameAccountColdRestoreKeepsData() async {
        let id = "xctest-keep-" + UUID().uuidString
        ProactiveLocalBackend.save(ProactiveSuggestion(id: id, title: "t", reason: "r", status: .pending, createdAt: ProactiveClock.now()))
        await AccountChangeObservers.notify(previous: nil, current: "XCTEST-A")   // epoch nil → same account restored
        XCTAssertNotNil(ProactiveLocalBackend.load()[id], "same-account restore never wipes")
    }
    func testSwitchCleansOnlyThePreviousOwner() async {
        let a = "xctest-a-" + UUID().uuidString, b = "xctest-b-" + UUID().uuidString
        ProactiveLocalBackend.save(ProactiveSuggestion(id: a, title: "t", reason: "r", status: .pending, createdAt: ProactiveClock.now()))
        AccountEpoch.shared.activate(account: "XCTEST-B")
        ProactiveLocalBackend.save(ProactiveSuggestion(id: b, title: "t", reason: "r", status: .pending, createdAt: ProactiveClock.now()))   // B's data before the observer ran
        await AccountChangeObservers.notify(previous: "XCTEST-A", current: "XCTEST-B")
        let inbox = ProactiveLocalBackend.load()
        XCTAssertNil(inbox[a], "A's card is not in B's inbox"); XCTAssertNotNil(inbox[b], "B's new data survives the late cleanup")
        XCTAssertTrue(ProactiveEngine.shared.parkedAccounts.contains("xctest-a"), "p90i P1-a: A's data parked under A, not wiped")
    }
    func testStaleTokenWritesNothing() async {
        let tokA = AccountEpoch.shared.capture()
        AccountEpoch.shared.activate(account: "XCTEST-B")
        let r = await ProactiveEngine.shared.confirmReminder("xctest-nope", token: tokA)
        XCTAssertEqual(r, .failed("stale_account"))
        let before = ProactiveEngine.shared.syncQueue.items.count
        ProactiveEngine.shared.syncAction("dismiss", local: "xctest-x", operationID: "op-xctest-x", token: tokA)
        XCTAssertEqual(ProactiveEngine.shared.syncQueue.items.count, before, "A's action never enqueued under B")
    }
    func testLegacyUntaggedTapWritesNothing() async {
        let before = ProactiveLocalBackend.load().count
        let info: [AnyHashable: Any] = ["catpaw_proactive_id": "evt-legacy", "catpaw_proactive_event": "E", "catpaw_proactive_title": "t",
                                        "catpaw_proactive_start": ProactiveClock.now().addingTimeInterval(3600).timeIntervalSince1970]
        _ = await ProactiveEngine.shared.handleNotification(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info)
        XCTAssertEqual(ProactiveLocalBackend.load().count, before)
    }
    func testAdoptMergePersists() throws {
        let id = "xctest-persist-" + UUID().uuidString
        let base = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .notify_attendees, .dismiss], status: .pending, createdAt: ProactiveClock.now())
        ProactiveSuggestionStore.shared.adopt(base); ProactiveLocalBackend.save(base)
        var upd = base; upd.serverActionStates = ["notify_attendees": "done"]
        ProactiveSuggestionStore.shared.adopt(upd)
        XCTAssertEqual(ProactiveLocalBackend.load()[id]?.serverActionStates?["notify_attendees"], "done", "merged state reaches disk (a reload cannot resurrect the action)")
    }
    // MARK: Codex PR90e — real entries: NativeAuthApplicationModel.applyAccountBarrier (the auth model's own barrier +
    // AccountChangeObservers hook), ProactiveLocalBackend.perform / undo / list.
    private func login(_ id: UUID) async {
        NativeAuthApplicationModel.applyAccountBarrier(NativeAuthSnapshot(phase: .authenticated, user: NativeAuthUser(id: id), generation: 1, message: nil), fresh: true, epoch: .shared)
        await settle()
    }
    private func logout() async {
        NativeAuthApplicationModel.applyAccountBarrier(NativeAuthSnapshot(phase: .loginRequired, user: nil, generation: 2, message: nil), fresh: false, epoch: .shared)
        await settle()
    }
    private func card(_ prefix: String, actions: [ProactiveSuggestion.Action] = [.create_reminder, .snooze, .dismiss]) -> ProactiveSuggestion {
        ProactiveSuggestion(id: prefix + UUID().uuidString, title: "t", reason: "r", actions: actions, status: .pending, createdAt: ProactiveClock.now())
    }
    private var owner: String? { UserDefaults.standard.object(forKey: ProactiveDataOwner.key) as? String }

    /// P1-1: A logs out (owner ""), B logs in and writes, B logs out, C logs in → none of B's data is visible or kept.
    func testLogoutAndReloginViaRealEntry() async throws {
        ProactiveEngine.registerAccountObserver()
        let a = UUID(), b = UUID(), c = UUID()
        await login(a)
        let ca = card("xctest-la-"); ProactiveSuggestionStore.shared.adopt(ca)
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: ca.id)
        await logout()
        XCTAssertEqual(owner, ""); XCTAssertTrue(ProactiveLocalBackend.load().isEmpty)
        await login(b)
        let cb = card("xctest-lb-"); ProactiveSuggestionStore.shared.adopt(cb)
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: cb.id)
        XCTAssertEqual(owner?.lowercased(), b.uuidString.lowercased(), "B registered as owner after A's logout (never stuck at \"\")")
        XCTAssertNotNil(ProactiveLocalBackend.load()[cb.id])
        await logout(); await login(c)
        let listed = try await ProactiveLocalBackend().list()
        XCTAssertFalse(listed.contains { $0.id == cb.id }, "C never sees B's card"); XCTAssertNil(ProactiveLocalBackend.load()[cb.id])
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == cb.id }, "B's write-backs gone")
        // Same account again after a logout: starts clean and owns its new data.
        await logout(); await login(c)
        let cc = card("xctest-lc-"); ProactiveSuggestionStore.shared.adopt(cc)
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: cc.id)
        XCTAssertNotNil(ProactiveLocalBackend.load()[cc.id])
    }

    // MARK: Codex PR90f #1 — unknown owner → quarantine; released only on evidence, else expired.
    private func legacyDevice(stamps: [String], serverID: String? = nil) -> ProactiveSuggestion {
        let legacy = card("xctest-up-"); ProactiveLocalBackend.save(legacy)
        for (i, a) in stamps.enumerated() {
            ProactiveEngine.shared.syncQueue.enqueue(.init(local: legacy.id, action: "dismiss", operationID: "op-up-\(i)"), key: "op-up-\(i)", account: a, group: legacy.id)
        }
        if let serverID { UserDefaults.standard.set([legacy.id: serverID], forKey: "catpaw.proactive.serverIDs.v1") }
        UserDefaults.standard.removeObject(forKey: ProactiveDataOwner.key)        // what the previous build left behind
        return legacy
    }
    private func assertQuarantined(_ legacy: ProactiveSuggestion, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(ProactiveEngine.shared.hasQuarantine, file: file, line: line)
        XCTAssertNil(ProactiveLocalBackend.load()[legacy.id], "not in the active inbox", file: file, line: line)
        let shown = try await ProactiveLocalBackend().list()
        XCTAssertFalse(shown.contains { $0.id == legacy.id }, "not shown", file: file, line: line)
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.isEmpty, "nothing sendable", file: file, line: line)
        await ProactiveEngine.shared.drainSync()
        XCTAssertTrue(calls.isEmpty, "nothing synced", file: file, line: line)
        XCTAssertEqual(owner, "XCTEST-A", "the active (empty) store is the current account's", file: file, line: line)
    }
    func testUnknownOwnerQuarantinedThenReleasedByStamp() async throws {
        let legacy = legacyDevice(stamps: ["XCTEST-A", "xctest-a"])
        let early = try await ProactiveLocalBackend().list()
        XCTAssertFalse(early.contains { $0.id == legacy.id }, "unknown owner never shown, even before a write")
        ProactiveEngine.shared.claimData(for: "XCTEST-A")                        // what every write entry / account change does
        try await assertQuarantined(legacy)
        _ = await ProactiveEngine.shared.reconcileQuarantine(); await settle()
        XCTAssertFalse(ProactiveEngine.shared.hasQuarantine, "released")
        XCTAssertNotNil(ProactiveLocalBackend.load()[legacy.id], "released into the proven owner's inbox")
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.allSatisfy { $0.account == "XCTEST-A" })
    }
    func testUnknownOwnerHeldThenReleasedByServerEvidence() async throws {
        let legacy = legacyDevice(stamps: ["XCTEST-A", "XCTEST-OTHER"], serverID: "srv-up-1")
        ProactiveEngine.shared.claimData(for: "XCTEST-A")
        try await assertQuarantined(legacy)
        let held = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertEqual(held, .hold, "mixed stamps and no cloud confirmation → still held")
        var probed: [String] = []
        ProactiveEngine.shared.serverProbe = { id, token in probed.append(id + "@" + token.account); return true }
        let released = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertEqual(released, .release); XCTAssertEqual(probed, ["srv-up-1@XCTEST-A"], "checked by server id under this account")
        XCTAssertNotNil(ProactiveLocalBackend.load()[legacy.id])
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.contains(key: "op-up-0"), "this account's write-back released")
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.contains(key: "op-up-1"), "another account's write-back never re-bound")
        XCTAssertEqual(ProactiveEngine.shared.serverIDs[legacy.id], "srv-up-1")
    }
    func testUnknownOwnerExpiresWithoutEvidence() async throws {
        let legacy = legacyDevice(stamps: [], serverID: "srv-up-2")
        ProactiveEngine.shared.claimData(for: "XCTEST-A")
        try await assertQuarantined(legacy)
        let held = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertEqual(held, .hold)
        // p90i P1-b: past the old TTL it is still kept (never auto-deleted) and still not handed to this account.
        ProactiveClock.now = { Self.day.addingTimeInterval(ProactiveQuarantine.ttl + 3600) }
        let later = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertEqual(later, .hold)
        XCTAssertTrue(ProactiveEngine.shared.hasQuarantine, "kept past the old TTL"); XCTAssertNil(ProactiveLocalBackend.load()[legacy.id], "never handed to this account")
        // Still kept after a sign-out / another account (never deleted; released only on its own proof).
        AccountEpoch.shared.activate(account: "XCTEST-B"); ProactiveEngine.shared.claimData(for: "XCTEST-B")
        _ = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertTrue(ProactiveEngine.shared.hasQuarantine, "kept across accounts"); XCTAssertNil(ProactiveLocalBackend.load()[legacy.id])
    }

    // MARK: p90i P1-a (user standard 08:50) — app-managed data is bound to its account and managed automatically: on a
    // switch the old account's unsynced ops / inbox / context / generations are parked under it; when THAT account signs
    // in again they are restored and synced under it. Another account never sees or sends them. Nothing is dropped.
    func testSwitchParksAndOwnerReloginRestoresAndSyncsViaRealSignIn() async throws {
        ProactiveEngine.registerAccountObserver()
        let a = UUID(), b = UUID()
        await login(a)
        let ca = card("xctest-pa-"); ProactiveSuggestionStore.shared.adopt(ca)
        ProactiveEngine.shared.adoptCloudIdentity(local: ca.id, server: "srv-pa")
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: ca.id)        // offline (setUp transport → nil): queued, unsynced
        let cs = card("xctest-ps-"); ProactiveSuggestionStore.shared.adopt(cs)
        ProactiveEngine.shared.adoptCloudIdentity(local: cs.id, server: "srv-ps")
        _ = try await ProactiveLocalBackend().perform(.snooze, on: cs.id)
        let genA = ProactiveEngine.shared.operationID(ca.id, "dismiss")
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == ca.id })
        // B signs in: nothing of A is visible or sendable; A's data is parked under A, not dropped.
        await login(b)
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == ca.id || $0.op.local == cs.id }, "nothing of A is sendable under B")
        XCTAssertNil(ProactiveLocalBackend.load()[ca.id]); XCTAssertNil(ProactiveLocalBackend.load()[cs.id])
        let listedB = try await ProactiveLocalBackend().list()
        XCTAssertFalse(listedB.contains { $0.id == ca.id || $0.id == cs.id }, "B never sees A's cards")
        XCTAssertNil(ProactiveEngine.shared.serverIDs[ca.id], "B does not resolve A's server ids")
        var sent: [(String, String)] = []
        ProactiveEngine.shared.transport = { path, _, token in sent.append((path, token.account)); return ["ok": true] }
        ProactiveClock.now = { Self.day.addingTimeInterval(3600) }                     // past any retry backoff
        await ProactiveEngine.shared.drainSync(); await settle()
        XCTAssertTrue(sent.isEmpty, "A's ops never sent under B (\(sent))")
        XCTAssertNotNil(ProactiveEngine.shared.parkedOps(for: a.uuidString), "parked under A")
        // A signs in again: its inbox, context, generations and ops come back and are synced under A.
        await login(a)
        XCTAssertNotNil(ProactiveLocalBackend.load()[ca.id], "A's inbox restored"); XCTAssertNotNil(ProactiveLocalBackend.load()[cs.id])
        XCTAssertEqual(ProactiveEngine.shared.operationID(ca.id, "dismiss"), genA, "A's generations restored")
        await ProactiveEngine.shared.drainSync(); await settle()
        let paths = sent.map(\.0)
        XCTAssertTrue(paths.contains("suggestions/srv-pa/action") && paths.contains("suggestions/srv-ps/action"), "A's parked ops synced (\(paths))")
        XCTAssertTrue(sent.allSatisfy { $0.1.caseInsensitiveCompare(a.uuidString) == .orderedSame }, "only under A")
        XCTAssertNil(ProactiveEngine.shared.parkedOps(for: a.uuidString), "nothing left parked for A")
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == ca.id || $0.op.local == cs.id }, "nothing stuck")
    }
    /// p90i: EventKit items the app created are outside the app — a switch never deletes or edits them; they are recorded
    /// as pending a user decision (#89's list) under the old account.
    func testSwitchLeavesEventKitRemindersAndRecordsThemForDecision() async throws {
        let c = card("xctest-ek-")
        var done = c; done.status = .done; done.taken = [.init(action: .create_reminder, at: ProactiveClock.now(), outcome: .succeeded)]
        ProactiveSuggestionStore.shared.adopt(done); ProactiveLocalBackend.save(done)
        ProactiveEngine.shared.recordPendingReminderForTest(c.id, operationID: "op-\(c.id)-create_reminder")
        AccountEpoch.shared.activate(account: "XCTEST-B"); ProactiveEngine.shared.claimData(for: "XCTEST-B")
        let pending = ProactiveEngine.shared.externalPendingDecision(for: "XCTEST-A")
        XCTAssertEqual(pending.map(\.suggestionID), [c.id]); XCTAssertEqual(pending.first?.operationID, "op-\(c.id)-create_reminder")
        XCTAssertEqual(pending.first?.kind, "eventkit_reminder")
        XCTAssertTrue(ProactiveEngine.shared.externalPendingDecision(for: "XCTEST-B").isEmpty)
    }
    /// p90i (三角 trial S5): server ids are partitioned per account; B never resolves A's mapping.
    func testServerIDsPartitionedByAccount() async throws {
        let c = card("xctest-sid-"); ProactiveSuggestionStore.shared.adopt(c)
        ProactiveEngine.shared.adoptCloudIdentity(local: c.id, server: "srv-sid-a")
        XCTAssertEqual(ProactiveEngine.shared.serverIDs[c.id], "srv-sid-a")
        XCTAssertNil(UserDefaults.standard.object(forKey: ProactiveServerIDMap.legacyKey), "nothing in the global map")
        AccountEpoch.shared.activate(account: "XCTEST-B"); ProactiveEngine.shared.claimData(for: "XCTEST-B")
        XCTAssertNil(ProactiveEngine.shared.serverIDs[c.id], "B does not see A's mapping")
        XCTAssertEqual(ProactiveEngine.shared.serverIDs(for: "XCTEST-A")[c.id], "srv-sid-a", "A's mapping kept under A")
    }
    func testLegacyGlobalServerIDsMigrateToRecordedOwner() async throws {
        UserDefaults.standard.set(["legacy-l": "legacy-s"], forKey: ProactiveServerIDMap.legacyKey)
        XCTAssertEqual(ProactiveEngine.shared.serverIDs["legacy-l"], "legacy-s", "owner XCTEST-A recorded → migrated to A")
        XCTAssertNil(UserDefaults.standard.object(forKey: ProactiveServerIDMap.legacyKey))
    }
    /// p90i (三角 trial S2): undo of a created reminder with no local mapping is unknown — state kept, not a silent success.
    func testUndoReminderWithoutMappingIsUnknownAndKeepsState() async throws {
        let id = "xctest-urm-" + UUID().uuidString
        let s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .dismiss], status: .done, createdAt: ProactiveClock.now(),
                                    taken: [.init(action: .create_reminder, at: ProactiveClock.now(), outcome: .succeeded)])
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        do { _ = try await ProactiveEngine.shared.undoLast(id); XCTFail("must not report an undo it could not verify") }
        catch let e as ProactiveEngineError { XCTAssertEqual(e, .undoUnknown) }
        XCTAssertEqual(ProactiveLocalBackend.load()[id]?.taken?.map(\.action), [.create_reminder], "state kept")
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == id && $0.op.action == "undo" }, "no cloud undo queued")
    }

    /// P1-4 / P1-5: snooze → it rang → snooze again schedules again; each intent its own operation id and until.
    func testRepeatedSnoozeViaBackend() async throws {
        let c = card("xctest-rs-"); ProactiveSuggestionStore.shared.adopt(c)
        let first = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        XCTAssertEqual(first.effectiveStatus, .snoozed); XCTAssertEqual(poster.adds.count, 1)
        ProactiveClock.now = { Self.day.addingTimeInterval(660) }   // the first snooze has rung
        let second = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        XCTAssertEqual(second.effectiveStatus, .snoozed)
        XCTAssertEqual(poster.adds.count, 2, "second snooze really scheduled"); XCTAssertNotEqual(poster.adds[0].id, poster.adds[1].id)
        let ops = ProactiveEngine.shared.syncQueue.items.filter { $0.op.local == c.id }.map(\.op)
        XCTAssertEqual(ops.map(\.action), ["snooze", "snooze"]); XCTAssertEqual(Set(ops.map(\.operationID)).count, 2, "new intent → new operation id")
        XCTAssertEqual(ops.map(\.until), (second.taken ?? []).map { Optional(ISO8601DateFormatter().string(from: ProactiveUndo.snoozeUntil(detail: $0.detail, at: $0.at))) }, "device until synced with each intent")
    }

    /// P1-5: device → cloud undo after two snoozes: the queued ops are exactly the ones the server contract test replays
    /// (op-<id>-snooze, op-<id>-snooze-n2, undo-<id>-g0); the device keeps the first snooze, like the server.
    func testDeviceToCloudUndoAfterTwoSnoozes() async throws {
        let c = card("xctest-du-"); ProactiveSuggestionStore.shared.adopt(c)
        _ = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        _ = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        let after = try await ProactiveLocalBackend().undo(c.id)
        XCTAssertEqual(after.effectiveStatus, .snoozed); XCTAssertEqual(after.taken?.count, 1)
        let ids = ProactiveEngine.shared.syncQueue.items.filter { $0.op.local == c.id }.map(\.op.operationID)
        XCTAssertEqual(ids, ["op-\(c.id)-snooze", "op-\(c.id)-snooze-n2", "undo-\(c.id)-g0"])
        XCTAssertTrue(poster.removed.contains { $0.hasPrefix(ProactiveDeliveryPipeline.snoozeBase(c.id, intent: "op-\(c.id)-snooze-n2")) }, "the undone snooze's own notification removed")
    }

    // MARK: Codex PR90f #2 — snooze keeps the original on failure; quiet hours pinned to a fixed night instant.
    func testFailedResnoozeKeepsOriginalReminderAndState() async throws {
        let c = card("xctest-keep-"); ProactiveSuggestionStore.shared.adopt(c)
        let first = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        let firstBase = ProactiveDeliveryPipeline.snoozeBase(c.id, intent: "op-\(c.id)-snooze")
        poster.addResult = false; poster.removed = []
        do { _ = try await ProactiveLocalBackend().perform(.snooze, on: c.id); XCTFail("must throw") } catch {}
        // Exact ids: the failed one's own id ("…-snooze-op-…-snooze-n2~…") starts with firstBase, and removing that
        // rejected request is correct; the original's scoped and legacy ids must never be touched.
        let tok = try XCTUnwrap(AccountEpoch.shared.capture())
        let original = [ProactiveDeliveryPipeline.scoped(firstBase, tok), firstBase]
        XCTAssertFalse(poster.removed.contains { original.contains($0) }, "the original snooze notification is kept (removed: \(poster.removed))")
        XCTAssertFalse(poster.removed.isEmpty, "the rejected new request itself is cleaned up")
        XCTAssertTrue(poster.removed.allSatisfy { $0.contains("-snooze-n2") }, "only the rejected new request is cleaned up")
        let stored = try XCTUnwrap(ProactiveLocalBackend.load()[c.id])
        XCTAssertEqual(stored.taken, first.taken, "history unchanged"); XCTAssertEqual(stored.effectiveStatus, .snoozed)
        XCTAssertEqual(ProactiveEngine.shared.syncQueue.items.filter { $0.op.local == c.id }.map(\.op.operationID), ["op-\(c.id)-snooze"], "nothing synced for the failed one")
        XCTAssertEqual(ProactiveEngine.shared.delivery.quota().entries[firstBase]?.state, .reserved, "the original keeps its slot")
    }
    // MARK: Codex PR90g #2 — a failed re-arm is visible: through the store (UI path) the card is actionable again,
    // the outcome is recorded and persisted, and the store shows an error. Three failure kinds.
    private func undoAfterDismissedSnooze(until: Date) async throws -> ProactiveSuggestion {
        let id = "xctest-undofail-" + UUID().uuidString
        let s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.snooze, .dismiss], status: .dismissed, createdAt: Self.day,
                                    taken: [.init(action: .snooze, at: Self.day, detail: ProactiveUndo.snoozeDetail(until: until, intent: "op-\(id)-snooze")), .init(action: .dismiss, at: Self.day)])
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        await ProactiveSuggestionStore.shared.undo(s)                       // what the card's undo button calls
        return try XCTUnwrap(ProactiveSuggestionStore.shared.items[id])
    }
    private func assertVisibleFailure(_ after: ProactiveSuggestion, _ prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ProactiveUndo.restoreOutcome(detail: after.taken?.last?.detail)?.hasPrefix(prefix) == true, "outcome recorded: \(String(describing: after.taken?.last?.detail))", file: file, line: line)
        XCTAssertEqual(after.effectiveStatus, .pending, "not silently shown as snoozed", file: file, line: line)
        XCTAssertTrue(after.snoozeRestoreFailed, file: file, line: line)
        XCTAssertEqual(ProactiveLocalBackend.load()[after.id]?.effectiveStatus, .pending, "persisted", file: file, line: line)
        XCTAssertNotNil(ProactiveSuggestionStore.shared.errorKey, "the user is told", file: file, line: line)
    }
    func testUndoRestoreRefusedIsVisible() async throws {
        poster.addResult = false
        assertVisibleFailure(try await undoAfterDismissedSnooze(until: Self.day.addingTimeInterval(600)), "refused")
    }
    func testUndoRestoreCardOnlyIsVisible() async throws {
        ProactiveClock.now = { Self.night }
        assertVisibleFailure(try await undoAfterDismissedSnooze(until: Self.night.addingTimeInterval(600)), "cardOnly")
    }
    func testUndoRestoreExpiredIsVisible() async throws {
        assertVisibleFailure(try await undoAfterDismissedSnooze(until: Self.day.addingTimeInterval(-60)), "expired")
    }
    func testUndoRestorePostedStaysSnoozedWithoutError() async throws {
        let after = try await undoAfterDismissedSnooze(until: Self.day.addingTimeInterval(600))
        XCTAssertEqual(after.effectiveStatus, .snoozed); XCTAssertFalse(after.snoozeRestoreFailed); XCTAssertNil(ProactiveSuggestionStore.shared.errorKey)
    }
    /// PR90g #3: a cloud snooze without a device detail re-arms at the cloud's own until, not "at + 10 min".
    func testUndoUsesTheCloudUntil() async throws {
        let id = "xctest-cu-" + UUID().uuidString, until = Self.day.addingTimeInterval(3 * 3600)
        let s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.snooze, .dismiss], status: .dismissed, createdAt: Self.day,
                                    taken: [.init(action: .snooze, at: Self.day, until: until), .init(action: .dismiss, at: Self.day)])
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        await ProactiveSuggestionStore.shared.undo(s)
        let add = try XCTUnwrap(poster.adds.last)
        XCTAssertEqual(add.fireAt?.timeIntervalSince1970 ?? 0, until.timeIntervalSince1970, accuracy: 1)
    }
    func testQuietHoursAtFixedNightInstant() async throws {
        ProactiveClock.now = { Self.night }
        _ = await ProactiveEngine.shared.handle(signal("night"))
        await settle()
        XCTAssertTrue(poster.adds.isEmpty, "no system notification in quiet hours")
        let c = card("xctest-night-"); ProactiveSuggestionStore.shared.adopt(c)
        do { _ = try await ProactiveLocalBackend().perform(.snooze, on: c.id); XCTFail("snooze into quiet hours must not claim success") }
        catch { XCTAssertEqual(error as? ProactiveEngineError, .snoozeNotScheduled) }
        XCTAssertNil(ProactiveLocalBackend.load()[c.id]?.taken, "card unchanged")
    }

    // MARK: Codex PR90f #5 — offline suggestion: created in the cloud first, then its ops in order.
    func testOfflineSuggestionCreatedThenOpsReplayed() async throws {
        let c = card("xctest-off-"); ProactiveSuggestionStore.shared.adopt(c); ProactiveLocalBackend.save(c)
        UserDefaults.standard.set([c.id], forKey: "catpaw.proactive.localOnly.v1")
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: c.id); await settle()
        XCTAssertEqual(calls, ["suggestions"], "offline: create attempted, op not sent ahead of it")
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == c.id }, "kept for retry (never dropped)")
        var bodies: [(String, [String: Any])] = []
        ProactiveEngine.shared.transport = { path, body, _ in bodies.append((path, body)); return path == "suggestions" ? ["suggestion": ["id": "srv-off-1"], "event_id": "srv-off-1"] : ["ok": true] }
        ProactiveClock.now = { Self.day.addingTimeInterval(7200) }   // past the retry backoff
        await ProactiveEngine.shared.drainSync()
        XCTAssertEqual(bodies.map(\.0), ["suggestions", "suggestions/srv-off-1/action"], "create, then the queued op")
        XCTAssertEqual(bodies.first?.1["client_id"] as? String, c.id)
        XCTAssertEqual(ProactiveEngine.shared.serverIDs[c.id], "srv-off-1"); XCTAssertFalse(ProactiveEngine.shared.localOnly.contains(c.id))
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == c.id })
    }

    // MARK: Codex PR90f #6 — APNs / local owner cleanup through the real sign-in entry; APNs tap of another account.
    func testAccountChangeRemovesOtherAccountsNotificationsViaRealSignIn() async throws {
        ProactiveEngine.registerAccountObserver()
        let b = UUID(), bID = b.uuidString
        inventory.pendingItems = [
            .init(id: "a-local", info: ["catpaw_proactive_id": "x", ProactiveAccountGate.accountKey: "XCTEST-A", ProactiveAccountGate.epochKey: "1"]),
            .init(id: "b-local", info: ["catpaw_proactive_id": "y", ProactiveAccountGate.accountKey: bID, ProactiveAccountGate.epochKey: "1"]),
            .init(id: "untagged", info: ["catpaw_proactive_id": "z"]),
            .init(id: "chat", info: ["aps": ["alert": "hi"]])]
        inventory.deliveredItems = [
            .init(id: "a-apns", info: ["catpaw": ["kind": "proactive_decision", "account": "xctest-a", "event_id": "E1"]]),
            .init(id: "b-apns", info: ["catpaw": ["kind": "proactive_decision", "account": bID.lowercased(), "event_id": "E2"]])]
        await login(b)
        XCTAssertEqual(Set(inventory.removedPending), ["a-local", "untagged"], "other account + untagged pending removed; B's and non-proactive kept")
        XCTAssertEqual(inventory.removedDelivered, ["a-apns"], "A's delivered APNs removed, B's (server lower-case uuid) kept")
        // A's APNs tapped after the switch: handled as proactive, writes nothing into B's inbox.
        let before = ProactiveLocalBackend.load().count
        let handled = await ProactiveEngine.shared.handleNotification(actionIdentifier: ProactiveEngine.notNowAction,
                                                                      userInfo: ["catpaw_proactive_id": "evt-a", "catpaw": ["kind": "proactive_decision", "account": "XCTEST-A", "event_id": "E1"]])
        XCTAssertTrue(handled); XCTAssertEqual(ProactiveLocalBackend.load().count, before)
    }

    // MARK: Codex PR90g #1 — per-record evidence: one proven record never releases another.
    func testQuarantineReleasesOnlyTheProvenRecord() async throws {
        let mine = card("xctest-qa-"), other = card("xctest-qb-")
        ProactiveLocalBackend.save(mine); ProactiveLocalBackend.save(other)
        ProactiveEngine.shared.syncQueue.enqueue(.init(local: mine.id, action: "dismiss", operationID: "op-qa"), key: "op-qa", account: "XCTEST-A", group: mine.id)
        ProactiveEngine.shared.syncQueue.enqueue(.init(local: other.id, action: "dismiss", operationID: "op-qb"), key: "op-qb", account: "XCTEST-OTHER", group: other.id)
        UserDefaults.standard.set([mine.id: "srv-qa", other.id: "srv-qb"], forKey: "catpaw.proactive.serverIDs.v1")
        UserDefaults.standard.removeObject(forKey: ProactiveDataOwner.key)
        ProactiveEngine.shared.claimData(for: "XCTEST-A")
        XCTAssertTrue(ProactiveEngine.shared.hasQuarantine)
        var probed: [String] = []
        ProactiveEngine.shared.serverProbe = { id, _ in probed.append(id); return false }
        let v = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertEqual(v, .release)
        XCTAssertEqual(probed, ["srv-qb"], "only the unproven record is probed, by its own server id")
        let inbox = ProactiveLocalBackend.load()
        XCTAssertNotNil(inbox[mine.id], "A's own record released"); XCTAssertNil(inbox[other.id], "the other record stays quarantined")
        XCTAssertEqual(ProactiveEngine.shared.serverIDs[mine.id], "srv-qa"); XCTAssertNil(ProactiveEngine.shared.serverIDs[other.id])
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.contains(key: "op-qa")); XCTAssertFalse(ProactiveEngine.shared.syncQueue.contains(key: "op-qb"))
        XCTAssertTrue(ProactiveEngine.shared.hasQuarantine, "remainder kept")
        // Later the cloud confirms the other one under this account → released on its own evidence.
        ProactiveEngine.shared.serverProbe = { id, _ in id == "srv-qb" }
        _ = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertNotNil(ProactiveLocalBackend.load()[other.id]); XCTAssertFalse(ProactiveEngine.shared.hasQuarantine)
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.contains(key: "op-qb"), "another account's write-back never re-bound")
    }

    // MARK: Codex PR90g #5 — the real UNUserNotificationCenter: owner cleanup through the real sign-in entry (no fake inventory).
    func testRealNotificationCenterOwnerCleanup() async throws {
        ProactiveEngine.registerAccountObserver()
        ProactiveEngine.shared.inventory = SystemNotificationInventory()
        let center = UNUserNotificationCenter.current(), b = UUID(), tag = UUID().uuidString
        // Precondition, not a skip: simctl cannot pre-grant notifications, so the UI test grants it once on this install.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            XCTFail("Notifications not authorized on this simulator (status \(status.rawValue): \(status == .denied ? "denied" : status == .notDetermined ? "notDetermined" : "other")). Run CatpawMUITests/ProactiveNotificationAuthUITests/testGrantNotificationAuthorizationForHostTests first (same simulator, do not uninstall), then this test.")
            return
        }
        func request(_ id: String, _ account: String) -> UNNotificationRequest {
            let c = UNMutableNotificationContent(); c.title = "xctest"
            c.userInfo = ["catpaw_proactive_id": id, ProactiveAccountGate.accountKey: account, ProactiveAccountGate.epochKey: "1"]
            return UNNotificationRequest(identifier: id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
        }
        let aID = "xctest-real-a-" + tag, bID = "xctest-real-b-" + tag
        try await center.add(request(aID, "XCTEST-A")); try await center.add(request(bID, b.uuidString))
        let before = await center.pendingNotificationRequests().map(\.identifier)
        XCTAssertTrue(before.contains(aID) && before.contains(bID), "both really pending in the system center: \(before)")
        await login(b)
        let after = await center.pendingNotificationRequests().map(\.identifier)
        XCTAssertFalse(after.contains(aID), "A's pending request removed from the real center")
        XCTAssertTrue(after.contains(bID), "B's kept")
        center.removePendingNotificationRequests(withIdentifiers: [bID])
    }

    // MARK: Codex PR90h #4 — delivered notifications in the REAL center, in the real order: delivered while A is current
    // (A's local stamp and A's APNs-shaped `catpaw` payload with a `decision` that warrants a system notification), then
    // the switch to B removes both; a chat notification stays. An APNs-shaped payload for another account arriving
    // while A is current is suppressed by willPresent (other_account) and never shows up as delivered.
    // Root cause of the 9d49d25 failure: the APNs-shaped payload had no `decision`, so the gate read it as a card-level
    // decision (inbox only) and willPresent returned [] — correctly not presented, so never "delivered".
    // Real APNs transport is not exercised (a simulator cannot receive one from a test); the payload is the server's.
    func testRealNotificationCenterDeliveredAndAPNsCleanup() async throws {
        ProactiveEngine.registerAccountObserver()
        ProactiveEngine.shared.inventory = SystemNotificationInventory()
        let center = UNUserNotificationCenter.current(), b = UUID(), tag = UUID().uuidString
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            XCTFail("Notifications not authorized on this simulator (status \(status.rawValue)). Run CatpawMUITests/ProactiveNotificationAuthUITests/testGrantNotificationAuthorizationForHostTests first (same simulator, do not uninstall), then this test.")
            return
        }
        func soon(_ id: String, _ info: [String: Any]) -> UNNotificationRequest {
            let c = UNMutableNotificationContent(); c.title = "xctest delivered"; c.userInfo = info
            return UNNotificationRequest(identifier: id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        }
        ProactiveEngine.shared.quota = ProactiveQuotaLedger()   // today's cap starts empty (gate runs on ProactiveClock = 10:00, not quiet hours)
        let aLocal = "xctest-dl-a-" + tag, aAPNs = "xctest-dl-apns-a-" + tag, bAPNs = "xctest-dl-apns-b-" + tag, chat = "xctest-dl-chat-" + tag
        XCTAssertEqual(AccountEpoch.shared.currentAccount, "XCTEST-A", "delivered while A is current")
        try await center.add(soon(aLocal, ["catpaw_proactive_id": aLocal, ProactiveAccountGate.accountKey: "XCTEST-A", ProactiveAccountGate.epochKey: String(AccountEpoch.shared.epoch)]))
        try await center.add(soon(aAPNs, ["catpaw": ["kind": "proactive_decision", "decision": "notify", "account": "xctest-a", "event_id": "E-a-" + tag]]))
        try await center.add(soon(bAPNs, ["catpaw": ["kind": "proactive_decision", "decision": "notify", "account": b.uuidString.lowercased(), "event_id": "E-b-" + tag]]))
        try await center.add(soon(chat, ["aps": ["alert": "hi"]]))
        var delivered: [String] = []
        for _ in 0..<30 {
            delivered = await center.deliveredNotifications().map(\.request.identifier)
            if [aLocal, aAPNs, chat].allSatisfy(delivered.contains) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue([aLocal, aAPNs, chat].allSatisfy(delivered.contains), "A's local, A's APNs-shaped and the chat notification delivered within 15 s: \(delivered)")
        try await Task.sleep(for: .seconds(1))
        delivered = await center.deliveredNotifications().map(\.request.identifier)
        XCTAssertFalse(delivered.contains(bAPNs), "another account's APNs-shaped notification is suppressed while A is current (willPresent other_account)")
        let stillPending = await center.pendingNotificationRequests().contains { $0.identifier == bAPNs }
        XCTAssertFalse(stillPending, "and it is not still pending (it fired)")
        await login(b)
        let after = await center.deliveredNotifications().map(\.request.identifier)
        XCTAssertFalse(after.contains(aLocal), "A's delivered local notification removed on the switch to B")
        XCTAssertFalse(after.contains(aAPNs), "A's delivered APNs-shaped notification removed on the switch to B")
        XCTAssertTrue(after.contains(chat), "a non-proactive notification is never touched")
        center.removeDeliveredNotifications(withIdentifiers: [chat, bAPNs])
    }

    // MARK: Codex PR90h #3 — a cloud card, end to end through the real client entries: the chat adapter decodes the
    // server's response (fixture written by the Edge suite), the store's perform / undo run the real backend + queue, and
    // the queue writes back to the cloud record. The Edge suite replays exactly these requests on the real service.
    private static let edgeFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../services/edge/test/fixtures")
    /// p90i P3: one continuous round trip against a recording of the REAL Edge handler (no stitched halves): client
    /// decode of the cloud card → each user action → the real queue drain encodes the request (byte-compared with the
    /// recording) → the client's own response decode (`decodeResponse`, incl. the recorded 403) → decode of the card the
    /// server returns → restore → undo again. Fixture: services/edge/test/fixtures/proactive-cloud-card-replay.json
    /// (generated and checked by services/edge/test/proactive-codex-pr90i-replay.test.mjs).
    func testCloudCardContinuousReplay() async throws {
        let iso = ISO8601DateFormatter(), t0 = try XCTUnwrap(iso.date(from: "2026-10-15T02:00:00Z")); var now = t0
        ProactiveClock.now = { now }
        let fx = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.edgeFixtures.appendingPathComponent("proactive-cloud-card-replay.json"))) as? [String: Any])
        let ex = try XCTUnwrap(fx["exchanges"] as? [[String: Any]]), until = iso.string(from: t0.addingTimeInterval(600))
        func bytes(_ o: Any?) -> Data { (o.flatMap { try? JSONSerialization.data(withJSONObject: $0) }) ?? Data() }
        var cursor = 0, mismatches: [String] = [], statuses: [Int] = []
        ProactiveEngine.shared.transport = { path, body, _ in
            guard cursor < ex.count, ex[cursor]["method"] as? String == "POST" else { mismatches.append("unexpected POST \(path) at \(cursor)"); return nil }
            let e = ex[cursor]; cursor += 1
            let want = (e["request"] as? String ?? "").replacingOccurrences(of: "__UNTIL__", with: until)
            let got = ProactiveEngine.encodeBody(body).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if e["path"] as? String != path || got != want { mismatches.append("\(path) \(got) ≠ \(e["path"] ?? "") \(want)") }
            let status = e["status"] as? Int ?? 0; statuses.append(status)
            return ProactiveEngine.decodeResponse(status: status, data: bytes(e["response"]))
        }
        func serverCard() throws -> ProactiveSuggestion {   // the GET the app makes after a write, decoded by the real adapter
            let e = try XCTUnwrap(cursor < ex.count ? ex[cursor] : nil, "recording exhausted"); cursor += 1
            XCTAssertEqual(e["method"] as? String, "GET", "the recording expects a POST here (\(cursor - 1))")
            let s = try XCTUnwrap(ProactiveSuggestionAdapter.decode(bytes((e["response"] as? [String: Any])?["suggestion"])))
            ProactiveSuggestionStore.shared.adopt(s); return s
        }
        func drain() async { await ProactiveEngine.shared.drainSync(); await settle() }
        let card = try serverCard()
        XCTAssertEqual(ProactiveEngine.shared.serverIDs[card.id], "SERVER-ID")
        await ProactiveSuggestionStore.shared.perform(.snooze, card); await drain()
        XCTAssertEqual(statuses, [200]); XCTAssertEqual(try serverCard().effectiveStatus, .snoozed)
        XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .snoozed)
        await ProactiveSuggestionStore.shared.perform(.dismiss, card); await drain()
        // The recorded refusal: the client decodes 403 as "not recorded" → kept queued, feature-disabled flagged, state kept.
        XCTAssertEqual(statuses, [200, 403])
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == card.id && $0.op.action == "dismiss" }, "refused write-back stays queued")
        XCTAssertTrue(FeatureEnrollment.shared.proactiveDisabled, "403 feature_disabled surfaced"); FeatureEnrollment.shared.proactiveDisabled = false
        XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .dismissed)
        now = t0.addingTimeInterval(120); await drain()                                 // retried after the backoff
        XCTAssertEqual(statuses, [200, 403, 200]); XCTAssertEqual(try serverCard().effectiveStatus, .dismissed)
        let addsBefore = poster.adds.count
        await ProactiveSuggestionStore.shared.undo(card); await drain()                 // restores the snooze
        XCTAssertGreaterThan(poster.adds.count, addsBefore, "restored snooze re-armed"); XCTAssertNil(ProactiveSuggestionStore.shared.errorKey)
        let restored = try serverCard()
        XCTAssertEqual(restored.effectiveStatus, .snoozed); XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .snoozed)
        XCTAssertEqual(restored.taken?.last?.until?.timeIntervalSince1970 ?? 0, t0.addingTimeInterval(600).timeIntervalSince1970, accuracy: 1, "the server kept the device until")
        await ProactiveSuggestionStore.shared.undo(card); await drain()                 // undo again
        XCTAssertEqual(try serverCard().effectiveStatus, .pending); XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .pending)
        XCTAssertEqual(statuses, [200, 403, 200, 200, 200]); XCTAssertEqual(cursor, ex.count, "the whole recording replayed, in order")
        XCTAssertEqual(mismatches, [], "every request byte-identical to the recording")
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == card.id })
    }
    func testCloudCardFullRoundTrip() async throws {
        let card = try XCTUnwrap(ProactiveSuggestionAdapter.decode(try Data(contentsOf: Self.edgeFixtures.appendingPathComponent("proactive-cloud-card.json"))), "real adapter decodes the server response")
        let expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.edgeFixtures.appendingPathComponent("proactive-cloud-card-requests.json"))) as? [String: Any])
        let want = (expected["requests"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "") + " " + (($0["body"] as? [String: Any])?["operation_id"] as? String ?? "") }
        var sent: [String] = [], untils: [String?] = []
        ProactiveEngine.shared.transport = { path, body, _ in
            if path.hasPrefix("suggestions/") { sent.append(path + " " + (body["operation_id"] as? String ?? "")); if body["action"] as? String == "snooze" { untils.append(body["until"] as? String) } }
            return ["ok": true]
        }
        ProactiveSuggestionStore.shared.adopt(card)                                      // what the chat card does on render
        XCTAssertEqual(ProactiveEngine.shared.serverIDs[card.id], "SERVER-ID", "the cloud card's write-back identity is registered")
        await ProactiveSuggestionStore.shared.perform(.snooze, card)
        XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .snoozed)
        await ProactiveSuggestionStore.shared.perform(.dismiss, card)
        XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .dismissed)
        let addsBefore = poster.adds.count
        await ProactiveSuggestionStore.shared.undo(card)                                 // restores the snooze
        XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .snoozed)
        XCTAssertGreaterThan(poster.adds.count, addsBefore, "the restored snooze is re-armed"); XCTAssertNil(ProactiveSuggestionStore.shared.errorKey)
        await ProactiveSuggestionStore.shared.undo(card)                                 // undo again
        XCTAssertEqual(ProactiveSuggestionStore.shared.items[card.id]?.effectiveStatus, .pending)
        ProactiveClock.now = { Self.day.addingTimeInterval(7200) }
        await ProactiveEngine.shared.drainSync(); await settle()
        XCTAssertEqual(sent, want, "the queue writes back to the cloud record, in order, with the operation ids the server replays")
        XCTAssertEqual(untils.count, 1); XCTAssertNotNil(untils.first ?? nil, "the snooze carries the device until")
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == card.id }, "nothing left stuck in .retry")
    }
}
