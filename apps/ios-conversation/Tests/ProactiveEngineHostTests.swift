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
        func requestAuthorization() async -> Bool { duringAuthorization?(); return true }
        func add(_ r: ProactiveNotificationRequest, completion: @escaping @MainActor (Bool) -> Void) { adds.append(r); completion(true) }
        func remove(ids: [String]) { removed += ids }
    }
    private var poster = Poster()
    private var saved: ProactiveNotificationPoster?

    override func setUp() async throws {
        saved = ProactiveEngine.shared.delivery.poster
        poster = Poster(); ProactiveEngine.shared.delivery.poster = poster
        AccountEpoch.shared.activate(account: "XCTEST-A")
        ProactiveEngine.shared.claimData(for: "XCTEST-A", force: true)   // clean inbox/ledgers, owned by this account
        ProactiveEngine.shared.resetLedger()
    }
    override func tearDown() async throws {
        if let saved { ProactiveEngine.shared.delivery.poster = saved }
        ProactiveEngine.shared.delivery.clock = { .now }
        AccountEpoch.shared.signOut()
    }
    private func signal(_ id: String, inMinutes m: Double = 8) -> ProactiveSignal {
        ProactiveSignal(source: .simulated, eventID: id + UUID().uuidString, title: "XCTest 会议", start: .now.addingTimeInterval(m * 60), place: "")
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
        let now = Date.now
        guard !ProactiveRules.isQuiet(now.addingTimeInterval(5)) else { throw XCTSkip("quiet hours on this machine's clock") }
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
        ProactiveSuggestionStore.shared.adopt(ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.snooze, .dismiss], status: .snoozed, createdAt: .now))
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: id)
        XCTAssertTrue(poster.removed.contains(id + "-snooze"))
    }

    func testUndoLastKeepsSentSMSAndQueuesCloudUndo() async throws {
        let id = "xctest-undo-" + UUID().uuidString
        let s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .notify_attendees, .dismiss], status: .dismissed, createdAt: .now,
                                    taken: [.init(action: .notify_attendees, at: .now, detail: "已发送短信", outcome: .succeeded), .init(action: .dismiss, at: .now)])
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
        ProactiveLocalBackend.save(ProactiveSuggestion(id: id, title: "t", reason: "r", status: .pending, createdAt: .now))
        AccountEpoch.shared.signOut()                       // sync bump first (NativeAuthApplicationModel order)
        await AccountChangeObservers.notify(previous: "XCTEST-A", current: nil)
        XCTAssertNil(ProactiveLocalBackend.load()[id], "previous account's inbox wiped by the registered observer")
    }

    // MARK: Codex PR90d
    func testBackendUndoEntryUsesUndoLast() async throws {
        let id = "xctest-bundo-" + UUID().uuidString
        let s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .snooze, .dismiss], status: .dismissed, createdAt: .now,
                                    taken: [.init(action: .snooze, at: .now, detail: ProactiveUndo.snoozeDetail(until: .now.addingTimeInterval(600))), .init(action: .dismiss, at: .now)])
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        guard !ProactiveRules.isQuiet(.now.addingTimeInterval(600)) else { throw XCTSkip("quiet hours at the restored snooze time") }
        let after = try await ProactiveLocalBackend().undo(id)   // the real UI entry
        await settle()
        XCTAssertEqual(after.taken?.map(\.action), [.snooze], "undo.v1: only the last action reverted")
        XCTAssertEqual(after.effectiveStatus, .snoozed)
        XCTAssertTrue(poster.adds.contains { $0.id.hasPrefix(id + "-snooze") }, "undoing the dismiss restores the snooze notification")
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.items.contains { $0.op.local == id && $0.op.action == "undo" && $0.account == "XCTEST-A" })
    }
    func testUndoClearsServerSuccessOfTheUndoneAction() async throws {
        let id = "xctest-sas-" + UUID().uuidString
        var s = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .dismiss], status: .done, createdAt: .now,
                                    taken: [.init(action: .dismiss, at: .now)])
        s.serverActionStates = ["dismiss": "done"]
        ProactiveSuggestionStore.shared.adopt(s); ProactiveLocalBackend.save(s)
        let after = try await ProactiveLocalBackend().undo(id)
        XCTAssertNil(after.serverActionStates?["dismiss"], "cloud state of the undone action does not beat the undo")
    }
    func testSameAccountColdRestoreKeepsData() async {
        let id = "xctest-keep-" + UUID().uuidString
        ProactiveLocalBackend.save(ProactiveSuggestion(id: id, title: "t", reason: "r", status: .pending, createdAt: .now))
        await AccountChangeObservers.notify(previous: nil, current: "XCTEST-A")   // epoch nil → same account restored
        XCTAssertNotNil(ProactiveLocalBackend.load()[id], "same-account restore never wipes")
    }
    func testSwitchCleansOnlyThePreviousOwner() async {
        let a = "xctest-a-" + UUID().uuidString, b = "xctest-b-" + UUID().uuidString
        ProactiveLocalBackend.save(ProactiveSuggestion(id: a, title: "t", reason: "r", status: .pending, createdAt: .now))
        AccountEpoch.shared.activate(account: "XCTEST-B")
        ProactiveLocalBackend.save(ProactiveSuggestion(id: b, title: "t", reason: "r", status: .pending, createdAt: .now))   // B's data before the observer ran
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
                                        "catpaw_proactive_start": Date.now.addingTimeInterval(3600).timeIntervalSince1970]
        _ = await ProactiveEngine.shared.handleNotification(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info)
        XCTAssertEqual(ProactiveLocalBackend.load().count, before)
    }
    func testAdoptMergePersists() throws {
        let id = "xctest-persist-" + UUID().uuidString
        let base = ProactiveSuggestion(id: id, title: "t", reason: "r", actions: [.create_reminder, .notify_attendees, .dismiss], status: .pending, createdAt: .now)
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
        ProactiveSuggestion(id: prefix + UUID().uuidString, title: "t", reason: "r", actions: actions, status: .pending, createdAt: .now)
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

    /// P1-2: first run after the upgrade (no owner recorded): the signed-in account keeps its inbox and outbox.
    func testFirstUpgradeKeepsData() async throws {
        let legacy = card("xctest-up-"); ProactiveLocalBackend.save(legacy)
        ProactiveEngine.shared.syncQueue.enqueue(.init(local: legacy.id, action: "dismiss", operationID: "op-up-a"), key: "op-up-a", account: "XCTEST-A", group: legacy.id)
        ProactiveEngine.shared.syncQueue.enqueue(.init(local: legacy.id, action: "dismiss", operationID: "op-up-x"), key: "op-up-x", account: "XCTEST-OTHER", group: legacy.id)
        UserDefaults.standard.removeObject(forKey: ProactiveDataOwner.key)        // what the previous build left behind
        let listed = try await ProactiveLocalBackend().list()
        XCTAssertTrue(listed.contains { $0.id == legacy.id }, "visible before any write")
        ProactiveSuggestionStore.shared.adopt(legacy)
        _ = try await ProactiveLocalBackend().perform(.dismiss, on: legacy.id)    // first write → migration
        XCTAssertEqual(owner, "XCTEST-A", "migrated to the current account")
        XCTAssertNotNil(ProactiveLocalBackend.load()[legacy.id], "upgrade kept the inbox")
        XCTAssertTrue(ProactiveEngine.shared.syncQueue.contains(key: "op-up-a"), "this account's queued write-back kept")
        XCTAssertFalse(ProactiveEngine.shared.syncQueue.contains(key: "op-up-x"), "another account's queued write-back removed")
    }

    /// P1-4 / P1-5: snooze → it rang → snooze again schedules again; each intent its own operation id and until.
    func testRepeatedSnoozeViaBackend() async throws {
        guard !ProactiveRules.isQuiet(.now.addingTimeInterval(600)), !ProactiveRules.isQuiet(.now.addingTimeInterval(1300)) else { throw XCTSkip("quiet hours") }
        let c = card("xctest-rs-"); ProactiveSuggestionStore.shared.adopt(c)
        let first = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        XCTAssertEqual(first.effectiveStatus, .snoozed); XCTAssertEqual(poster.adds.count, 1)
        ProactiveEngine.shared.delivery.clock = { .now.addingTimeInterval(660) }   // the first snooze has rung
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
        guard !ProactiveRules.isQuiet(.now.addingTimeInterval(600)) else { throw XCTSkip("quiet hours") }
        let c = card("xctest-du-"); ProactiveSuggestionStore.shared.adopt(c)
        _ = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        _ = try await ProactiveLocalBackend().perform(.snooze, on: c.id)
        let after = try await ProactiveLocalBackend().undo(c.id)
        XCTAssertEqual(after.effectiveStatus, .snoozed); XCTAssertEqual(after.taken?.count, 1)
        let ids = ProactiveEngine.shared.syncQueue.items.filter { $0.op.local == c.id }.map(\.op.operationID)
        XCTAssertEqual(ids, ["op-\(c.id)-snooze", "op-\(c.id)-snooze-n2", "undo-\(c.id)-g0"])
        XCTAssertTrue(poster.removed.contains { $0.hasPrefix(ProactiveDeliveryPipeline.snoozeBase(c.id, intent: "op-\(c.id)-snooze-n2")) }, "the undone snooze's own notification removed")
    }
}
