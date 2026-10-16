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
        XCTAssertNil(inbox[a], "A's data gone"); XCTAssertNotNil(inbox[b], "B's new data survives the late cleanup")
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
        ProactiveClock.now = { Self.day.addingTimeInterval(ProactiveQuarantine.ttl + 3600) }
        let expired = await ProactiveEngine.shared.reconcileQuarantine()
        XCTAssertEqual(expired, .expire)
        XCTAssertFalse(ProactiveEngine.shared.hasQuarantine); XCTAssertNil(ProactiveLocalBackend.load()[legacy.id], "never handed to this account")
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
}
