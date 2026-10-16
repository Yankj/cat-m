import XCTest
import EventKit
@testable import CatpawM

/// Real DeviceToolRouter + real DeviceCallStore on the BE5C simulator (EventKit granted via simctl privacy).
/// NoBug P1-5 dedupe, plus Codex p89b / p89c counter-examples on the REAL executor path (not FakeExecutor):
/// no tap → no credential → no write; forged / swapped / replayed credentials; local cancel; sign-out; URL handoff;
/// passive session invalidation; per-account ledger.
@MainActor final class DeviceToolRouterEventKitTests: XCTestCase {
    private let store = EKEventStore()

    private func need(_ type: EKEntityType) throws {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else {
            throw XCTSkip("EventKit \(type == .event ? "calendar" : "reminders") not granted; run `xcrun simctl privacy <udid> grant \(type == .event ? "calendar" : "reminders") <bundle>` first")
        }
    }

    // Isolated barrier: the test HOST app runs its own auth lifecycle on AccountEpoch.shared (passive invalidation signs
    // it out when the host has no session), which would race these tests. The gate/router/store all read DeviceCallGate.epoch.
    override func setUp() async throws { DeviceCallGate.epoch = AccountEpoch(account: "xctest-user"); DeviceCallGate.reset() }
    override func tearDown() async throws { DeviceCallGate.reset(); DeviceCallGate.epoch = .shared; DeviceCallHub.executor = DeviceToolExecutorStub(); DeviceCallHub.submitter = DeviceResultSubmitterStub() }

    private func calCall(_ id: String, _ start: Date, title: String = "PR89 gate") -> DeviceCall {
        DeviceCall(call_id: id, tool: "calendar_create", args: ["title": .string(title), "start": .string(DeviceCallDates.format(start)), "end": .string(DeviceCallDates.format(start.addingTimeInterval(1800)))], confirm: .card, ttl_sec: 600)
    }
    /// Credential the way the card does it: tap token for the final args, then authorize.
    private func credential(_ call: DeviceCall) -> DeviceCallGate.Credential? {
        if case .success(let c) = DeviceCallGate.authorize(call, finalArgs: call.args, tap: DeviceCallGate.confirmTap(call, finalArgs: call.args)) { return c }
        return nil
    }
    private func forged(_ call: DeviceCall) -> DeviceCallGate.Credential {
        .init(callID: call.call_id, tool: call.tool, finalArgsHash: DeviceCallGate.argsHash(call.args), token: AccountToken(account: "xctest-user", epoch: DeviceCallGate.epoch.epoch), generation: UUID(), nonce: UUID())
    }
    private func events(with ids: [String], around start: Date) -> Int {
        store.reset()
        let all = store.events(matching: store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(86400), calendars: nil))
        return all.filter { e in ids.contains { e.notes?.contains(DeviceToolContract.callMarker($0)) == true } }.count
    }
    private func cleanup(_ ids: [String], around start: Date) {
        store.reset()
        for e in store.events(matching: store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(86400), calendars: nil))
            where ids.contains(where: { e.notes?.contains(DeviceToolContract.callMarker($0)) == true }) { try? store.remove(e, span: .thisEvent, commit: true) }
    }

    /// Codex p89b-1: the real router refuses without a credential minted for THIS grant (never registered / revoked /
    /// signed out / forged), before touching EventKit.
    func testRouterRefusesWithoutLiveGrant() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(4 * 86400)
        let router = DeviceToolRouter()
        let unreg = calCall("xctest-forged-" + UUID().uuidString, start)
        let r1 = await router.execute(unreg, credential: forged(unreg))
        XCTAssertEqual(r1.status, .error); XCTAssertEqual(r1.data?["reason"], .string("unauthorized_call"))
        let revoked = calCall("xctest-revoked-" + UUID().uuidString, start); DeviceCallGate.receive(revoked)
        let rc = try XCTUnwrap(credential(revoked)); DeviceCallGate.revoke([revoked.call_id])
        let r2 = await router.execute(revoked, credential: rc)
        XCTAssertEqual(r2.data?["reason"], .string("call_revoked"))
        let out = calCall("xctest-signedout-" + UUID().uuidString, start); DeviceCallGate.receive(out)
        let oc = try XCTUnwrap(credential(out)); DeviceCallGate.epoch.signOut()
        let r3 = await router.execute(out, credential: oc)
        XCTAssertEqual(r3.status, .error)
        XCTAssertEqual(events(with: [unreg.call_id, revoked.call_id, out.call_id], around: start), 0)
    }

    /// Codex p89b-1 (the old line 47 test inverted): receive → router WITHOUT the tap must NOT write.
    func testWriteWithoutTapIsRefusedByRealRouter() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(5 * 86400)
        let call = calCall("xctest-notap-" + UUID().uuidString, start); DeviceCallGate.receive(call)
        guard case .failure(let e) = DeviceCallGate.authorize(call, finalArgs: call.args, tap: nil) else { return XCTFail("a write without a tap must not mint a credential") }
        XCTAssertEqual(e.why, .tapRequired)
        let router = DeviceToolRouter()
        let r = await router.execute(call, credential: forged(call))   // only way to reach the router without a tap
        XCTAssertEqual(r.status, .error); XCTAssertEqual(r.data?["reason"], .string("stale_session"))
        // Counter-test: same id, with the real tap → written exactly once.
        let ok = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        XCTAssertEqual(ok.status, .ok)
        XCTAssertEqual(events(with: [call.call_id], around: start), 1)
        cleanup([call.call_id], around: start)
    }

    /// Codex p89b-1: a read-only grant's credential cannot drive a write tool; a credential is bound to the final args.
    func testCredentialBoundToToolAndFinalArgs() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(6 * 86400)
        let id = "xctest-swap-" + UUID().uuidString
        let list = DeviceCall(call_id: id, tool: "calendar_list", args: [:], confirm: DeviceCall.Confirm.none, ttl_sec: 600)
        DeviceCallGate.receive(list)
        guard case .success(let roCred) = DeviceCallGate.authorize(list, finalArgs: list.args, tap: nil) else { return XCTFail("read-only auto-run credential") }
        let router = DeviceToolRouter()
        let write = calCall(id, start)
        let r1 = await router.execute(write, credential: roCred)
        XCTAssertEqual(r1.status, .error)
        let w2 = calCall("xctest-args-" + UUID().uuidString, start); DeviceCallGate.receive(w2)
        let c2 = try XCTUnwrap(credential(w2))
        var edited = w2; edited.args["title"] = .string("swapped after tap")
        let r2 = await router.execute(edited, credential: c2)
        XCTAssertEqual(r2.data?["reason"], .string("call_mismatch"))
        XCTAssertEqual(events(with: [id, w2.call_id], around: start), 0)
    }

    /// Codex p89b-3 (real Store + real Router): local cancel revokes before the report await; the old tap cannot run.
    func testLocalCancelRevokesOnRealStore() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(7 * 86400)
        let suite = "xctest.cancel." + UUID().uuidString
        let st = DeviceCallStore(defaults: UserDefaults(suiteName: suite)!)
        DeviceCallHub.executor = DeviceToolRouter(); DeviceCallHub.submitter = DeviceResultSubmitterStub()
        let call = calCall("xctest-cancel-" + UUID().uuidString, start); DeviceCallGate.receive(call)
        let tap = DeviceCallGate.confirmTap(call, finalArgs: call.args)
        await st.cancel(call)
        XCTAssertFalse(DeviceCallGate.isLive(call.call_id))
        await st.run(call, tap: tap)
        XCTAssertEqual(events(with: [call.call_id], around: start), 0)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Codex p89b-4 / p89c-a (real Store + real Router): sign-out after the tap — nothing written, nothing reported.
    func testSignOutAfterTapOnRealStore() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(8 * 86400)
        let suite = "xctest.signout." + UUID().uuidString
        let st = DeviceCallStore(defaults: UserDefaults(suiteName: suite)!)
        let sub = DeviceResultSubmitterStub()
        DeviceCallHub.executor = DeviceToolRouter(); DeviceCallHub.submitter = sub
        let call = calCall("xctest-so-" + UUID().uuidString, start); DeviceCallGate.receive(call)
        let tap = DeviceCallGate.confirmTap(call, finalArgs: call.args)
        DeviceCallGate.epoch.signOut()
        await st.run(call, tap: tap)
        XCTAssertEqual(events(with: [call.call_id], around: start), 0)
        XCTAssertTrue(sub.sent.isEmpty)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Codex p89b-2: URL handoff tools fail closed on a revoked / signed-out credential (incl. the shop web fallback).
    func testURLToolsFailClosed() async throws {
        let router = DeviceToolRouter()
        for (tool, args) in [("shop_open", ["platform": DeviceCallValue.string("nonexistent-platform"), "query": .string("猫粮")]),
                             ("maps_open", ["query": .string("望京")]), ("phone_call", ["number": .string("10086")])] {
            let call = DeviceCall(call_id: "xctest-url-\(tool)-" + UUID().uuidString, tool: tool, args: args, confirm: .card, ttl_sec: 600)
            DeviceCallGate.receive(call)
            let c = try XCTUnwrap(credential(call))
            DeviceCallGate.revoke([call.call_id])
            let r = await router.execute(call, credential: c)
            XCTAssertEqual(r.data?["reason"], .string("call_revoked"), tool)
        }
        let call = DeviceCall(call_id: "xctest-url-so-" + UUID().uuidString, tool: "shop_open", args: ["platform": .string("taobao"), "query": .string("x")], confirm: .card, ttl_sec: 600)
        DeviceCallGate.receive(call); let c = try XCTUnwrap(credential(call))
        DeviceCallGate.epoch.signOut()
        let r = await router.execute(call, credential: c)
        XCTAssertEqual(r.status, .error)
    }

    /// Codex p89c-c: passive invalidation (loginRequired) closes the barrier synchronously and runs the account hooks.
    func testPassiveInvalidationIsSynchronous() async throws {
        let call = calCall("xctest-passive-" + UUID().uuidString, Date().addingTimeInterval(86400)); DeviceCallGate.receive(call)
        XCTAssertTrue(DeviceCallGate.isLive(call.call_id))
        var seen: [String?] = []
        AccountChangeObservers.register("xctest") { previous, _ in seen.append(previous) }
        defer { AccountChangeObservers.unregister("xctest") }
        let snap = NativeAuthSnapshot(phase: .loginRequired, user: nil, generation: 9, message: nil)
        NativeAuthApplicationModel.applyAccountBarrier(snap, fresh: false, epoch: DeviceCallGate.epoch)
        XCTAssertNil(DeviceCallGate.epoch.currentAccount)
        XCTAssertFalse(DeviceCallGate.isLive(call.call_id), "grant dies synchronously, no SwiftUI .task involved")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(seen, ["xctest-user"])
    }

    /// Codex p89c-b: the ledger is per account; another account can't see or undo; sign-out clears; uncertain → unknown.
    func testLedgerIsPerAccount() throws {
        final class FakeItems: DeviceLedgerItemStore { var removed: [String] = []; func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> Bool? { removed.append(itemID); return true } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let epoch = AccountEpoch(account: "A"), items = FakeItems()
        let ledger = DeviceLedger(url: url, epoch: epoch, items: items)
        let call = DeviceCall(call_id: "led-1", tool: "calendar_create", args: ["title": .string("A 的日程")], confirm: .card, ttl_sec: 600)
        let tokA = try XCTUnwrap(epoch.capture())
        ledger.record(call: call, result: .init(call_id: "led-1", status: .ok, data: ["event_id": .string("evt-A")]), token: tokA)
        XCTAssertEqual(ledger.active.map(\.id), ["led-1"])
        epoch.activate(account: "B")
        XCTAssertTrue(ledger.active.isEmpty, "B cannot see A's entries")
        XCTAssertEqual(ledger.undo(callID: "led-1"), .unknown, "B cannot undo A's item")
        XCTAssertTrue(items.removed.isEmpty)
        ledger.record(call: DeviceCall(call_id: "led-late", tool: "calendar_create", args: [:], confirm: .card, ttl_sec: 600),
                      result: .init(call_id: "led-late", status: .ok, data: ["event_id": .string("evt-late")]), token: tokA)
        epoch.activate(account: "A")
        XCTAssertEqual(ledger.active.map(\.id), ["led-1"], "a late result with A's old token is not recorded")
        XCTAssertEqual(ledger.undo(callID: "led-1"), .undone); XCTAssertEqual(items.removed, ["evt-A"])
        ledger.signOut(account: "A")
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertTrue(DeviceLedger(url: url, epoch: epoch, items: items).entries.isEmpty, "cleared on disk too")
    }

    func testCalendarCreateDedupesByCallID() async throws {
        try need(.event)
        let id = "xctest-cal-" + UUID().uuidString, start = Date().addingTimeInterval(3 * 86400)
        let call = calCall(id, start, title: "NoBug dedupe")
        DeviceCallGate.receive(call)
        let router = DeviceToolRouter(), c = try XCTUnwrap(credential(call))
        let first = await router.execute(call, credential: c), second = await router.execute(call, credential: c)
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(first.data?["event_id"], second.data?["event_id"])
        XCTAssertEqual(second.data?["deduped"], .bool(true))
        let n = events(with: [id], around: start)
        print("nobug.eventkit calendar call_id=\(id) events_with_marker=\(n) event_id=\(first.data?["event_id"]?.text ?? "")")
        XCTAssertEqual(n, 1)
        cleanup([id], around: start)
    }

    func testReminderCreateDedupesByCallID() async throws {
        try need(.reminder)
        let id = "xctest-rem-" + UUID().uuidString
        let call = DeviceCall(call_id: id, tool: "reminder_create", args: ["title": .string("NoBug dedupe reminder")], confirm: .card, ttl_sec: 600)
        DeviceCallGate.receive(call)
        let router = DeviceToolRouter(), c = try XCTUnwrap(credential(call))
        let first = await router.execute(call, credential: c), second = await router.execute(call, credential: c)
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(second.data?["deduped"], .bool(true))
        XCTAssertEqual(first.data?["reminder_id"], second.data?["reminder_id"])
        let marker = DeviceToolContract.callMarker(id)
        store.reset()
        let all: [EKReminder] = await withCheckedContinuation { c in store.fetchReminders(matching: store.predicateForReminders(in: nil)) { c.resume(returning: $0 ?? []) } }
        let matches = all.filter { $0.notes?.contains(marker) == true }
        print("nobug.eventkit reminder call_id=\(id) reminders_with_marker=\(matches.count)")
        XCTAssertEqual(matches.count, 1)
        for r in matches { try? store.remove(r, commit: true) }
    }
}
