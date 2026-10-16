import XCTest
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
        await ProactiveEngine.shared.accountDidChange()   // clean inbox/ledgers for this account
        ProactiveEngine.shared.resetLedger()
    }
    override func tearDown() async throws {
        if let saved { ProactiveEngine.shared.delivery.poster = saved }
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
}
