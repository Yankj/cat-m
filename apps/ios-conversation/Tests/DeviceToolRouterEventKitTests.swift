import XCTest
import EventKit
@testable import CatpawM

/// Real DeviceToolRouter + real DeviceCallStore on the BE5C simulator (EventKit granted via simctl privacy).
/// NoBug P1-5 dedupe, plus Codex p89b / p89c counter-examples on the REAL executor path (not FakeExecutor):
/// no tap → no credential → no write; forged / swapped / replayed credentials; local cancel; sign-out; URL handoff;
/// passive session invalidation; per-account ledger.
@MainActor final class DeviceToolRouterEventKitTests: XCTestCase {
    /// One EKEventStore for the whole class (many instances → EventKit error 1021 → spurious 'not granted').
    static let sharedStore = EKEventStore()
    private var store: EKEventStore { Self.sharedStore }

    private func need(_ type: EKEntityType) throws {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else {
            XCTFail("skip is a failure"); throw CatpawError.unavailable("EventKit \(type == .event ? "calendar" : "reminders") not granted; run `xcrun simctl privacy <udid> grant \(type == .event ? "calendar" : "reminders") <bundle>` first")
        }
    }

    // Isolated barrier: the test HOST app runs its own auth lifecycle on AccountEpoch.shared (passive invalidation signs
    // it out when the host has no session), which would race these tests. The gate/router/store all read DeviceCallGate.epoch.
    override func setUp() async throws { DeviceCallGate.epoch = AccountEpoch(account: "xctest-user"); DeviceCallGate.reset() }
    override func tearDown() async throws { DeviceCallGate.reset(); DeviceCallGate.epoch = .shared; DeviceCallHub.executor = DeviceToolExecutorStub(); DeviceCallHub.submitter = DeviceResultSubmitterStub(); DeviceToolRouter.trace = nil; DeviceCallGate.beforeCommitHook = nil }

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
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore)
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
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore)
        let r = await router.execute(call, credential: forged(call))   // only way to reach the router without a tap
        XCTAssertEqual(r.status, .error); XCTAssertEqual(r.data?["reason"], .string("credential_required"))
        // Counter-test: same id, with the real tap → written exactly once.
        let ok = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        XCTAssertEqual(ok.status, .ok, "\(String(describing: ok.data))")
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
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore)
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
        DeviceCallHub.executor = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore); DeviceCallHub.submitter = DeviceResultSubmitterStub()
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
        DeviceCallHub.executor = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore); DeviceCallHub.submitter = sub
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
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore)
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

    /// Codex p89d-2/6: revoke AFTER every earlier check (right before the handoff) — the URL is not opened.
    func testURLRevokeAfterCheckIsRefusedAtCommit() async throws {
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore)
        for (tool, args) in [("shop_open", ["platform": DeviceCallValue.string("nonexistent-platform"), "query": .string("猫粮")]), ("maps_open", ["query": .string("望京")])] {
            let call = DeviceCall(call_id: "xctest-late-\(tool)-" + UUID().uuidString, tool: tool, args: args, confirm: .card, ttl_sec: 600)
            DeviceCallGate.receive(call)
            let c = try XCTUnwrap(credential(call))
            var hookRan = false
            DeviceCallGate.beforeCommitHook = { hookRan = true; DeviceCallGate.revokedIDs.insert([call.call_id]) }   // service-thread style revoke
            let r = await router.execute(call, credential: c)
            DeviceCallGate.beforeCommitHook = nil
            XCTAssertTrue(hookRan, "\(tool): the router reached the final commit")
            XCTAssertEqual(r.data?["reason"], .string("call_revoked"), tool)
        }
    }

    /// Codex p89e-2: revoked while the reminder dedupe fetch was suspended → the dedupe hit is refused at the commit gate.
    func testReminderDedupeHitRechecksRevoke() async throws {
        try need(.reminder)
        let id = "xctest-rem-revoke-" + UUID().uuidString
        let call = DeviceCall(call_id: id, tool: "reminder_create", args: ["title": .string("p89e dedupe revoke")], confirm: .card, ttl_sec: 600)
        DeviceCallGate.receive(call)
        let router = DeviceToolRouter(store: Self.sharedStore)
        let first = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        XCTAssertEqual(first.status, .ok)
        let c2 = try XCTUnwrap(credential(call))
        var trace: [String] = []; DeviceToolRouter.trace = { trace.append($0) }
        var hookRan = false
        DeviceCallGate.beforeCommitHook = { hookRan = true; DeviceCallGate.revokedIDs.insert([id]) }   // lands after the awaited fetch, before success
        let second = await router.execute(call, credential: c2)
        DeviceCallGate.beforeCommitHook = nil; DeviceToolRouter.trace = nil
        XCTAssertEqual(trace, ["dedupe-hit:reminder"], "p89g-4: the second execute really took the dedupe-hit branch")
        XCTAssertTrue(hookRan, "p89g-4: and reached the commit gate")
        XCTAssertEqual(second.data?["reason"], .string("call_revoked"), "\(String(describing: second.data))")
        XCTAssertNil(second.data?["deduped"])
        Self.sharedStore.reset()
        let all: [EKReminder] = await withCheckedContinuation { c in Self.sharedStore.fetchReminders(matching: Self.sharedStore.predicateForReminders(in: nil)) { c.resume(returning: $0 ?? []) } }
        for r in all where r.notes?.contains(DeviceToolContract.callMarker(id)) == true { try? Self.sharedStore.remove(r, commit: true) }
    }

    /// Codex p89g-4: calendar dedupe hit (after a real first write) re-checks revoke at the commit gate; trace proves the branch.
    func testCalendarDedupeHitRechecksRevoke() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(13 * 86400)
        let call = calCall("xctest-cal-revoke-" + UUID().uuidString, start)
        defer { cleanup([call.call_id], around: start) }
        DeviceCallGate.receive(call)
        let router = DeviceToolRouter(store: Self.sharedStore)
        let first = await router.execute(call, credential: try XCTUnwrap(credential(call))); XCTAssertEqual(first.status, .ok)
        let c2 = try XCTUnwrap(credential(call))
        var trace: [String] = []; DeviceToolRouter.trace = { trace.append($0) }
        var hookRan = false
        DeviceCallGate.beforeCommitHook = { hookRan = true; DeviceCallGate.revokedIDs.insert([call.call_id]) }
        let second = await router.execute(call, credential: c2)
        XCTAssertEqual(trace, ["dedupe-hit:calendar"]); XCTAssertTrue(hookRan)
        XCTAssertEqual(second.data?["reason"], .string("call_revoked"), "\(String(describing: second.data))")
        XCTAssertNil(second.data?["deduped"])
        XCTAssertEqual(events(with: [call.call_id], around: start), 1, "no second write")
    }

    /// Codex p89g-4: sms_compose / mail_compose present ONLY inside the commit gate (real Router, real credential, real
    /// `present`; MessageUI replaced by seams because the simulator has none). Positive run proves the sheet path executes;
    /// revoke-after-check and sign-out-after-check prove the gate refuses with nothing shown.
    func testComposeSheetsPresentOnlyThroughCommitGate() async throws {
        for tool in ["sms_compose", "mail_compose"] {
            for scenario in ["ok", "revoked", "signedOut"] {
                DeviceCallGate.reset(); DeviceCallGate.epoch = AccountEpoch(account: "xctest-user")
                let call = DeviceCall(call_id: "xctest-\(tool)-\(scenario)-" + UUID().uuidString, tool: tool, args: ["to": .string("10086"), "body": .string("p89g"), "subject": .string("s")], confirm: .card, ttl_sec: 600)
                DeviceCallGate.receive(call)
                let router = DeviceToolRouter(store: Self.sharedStore)
                var presented: [UIViewController] = []
                router.canCompose = { _ in true }
                router.makeComposer = { _ in UIViewController() }
                router.presentOverride = { vc in presented.append(vc); router.completeCompose(vc, .ok) }
                var trace: [String] = []; DeviceToolRouter.trace = { trace.append($0) }
                var hookRan = false
                DeviceCallGate.beforeCommitHook = {
                    hookRan = true
                    if scenario == "revoked" { DeviceCallGate.revokedIDs.insert([call.call_id]) }
                    if scenario == "signedOut" { DeviceCallGate.epoch.signOut() }
                }
                let result = await router.execute(call, credential: try XCTUnwrap(credential(call), "\(tool) \(scenario)"))
                DeviceCallGate.beforeCommitHook = nil; DeviceToolRouter.trace = nil
                XCTAssertTrue(hookRan, "\(tool) \(scenario): reached the commit gate")
                switch scenario {
                case "ok":
                    XCTAssertEqual(result.status, .ok, "\(tool)"); XCTAssertEqual(presented.count, 1, "\(tool): the sheet path really ran")
                    XCTAssertEqual(trace, ["present:\(tool)"])
                case "revoked":
                    XCTAssertEqual(result.data?["reason"], .string("call_revoked"), "\(tool) \(String(describing: result.data))")
                    XCTAssertTrue(presented.isEmpty, "\(tool): nothing shown after revoke"); XCTAssertTrue(trace.isEmpty)
                default:
                    XCTAssertNotEqual(result.status, .ok, "\(tool) signed out")
                    XCTAssertTrue(presented.isEmpty, "\(tool): nothing shown after sign-out"); XCTAssertTrue(trace.isEmpty)
                }
            }
        }
    }

    /// Codex p89g-3: REAL EventKit adapter, stale ledger id. A user COPY keeps our notes, so the marker matches twice →
    /// ambiguous → nothing deleted, `.unknown`, not undone. A single marker match whose identity (title/start) differs is
    /// also not proof. Counter-case (unique + identity match) is case 1 of the test below.
    func testRealEventKitLedgerAdapterRefusesAmbiguousOrMismatchedMarker() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(12 * 86400)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-amb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DeviceLedger(url: url, epoch: DeviceCallGate.epoch, items: EventKitLedgerItemStore(store: Self.sharedStore))
        let token = try XCTUnwrap(DeviceCallGate.epoch.capture())
        func add(_ id: String, title: String, at date: Date) throws {
            let e = EKEvent(eventStore: store); e.title = title; e.startDate = date; e.endDate = date.addingTimeInterval(1800)
            e.notes = DeviceToolContract.callMarker(id); e.calendar = store.defaultCalendarForNewEvents
            try store.save(e, span: .thisEvent, commit: true)
        }
        // 1) original + user copy (same notes) → two matches.
        let dup = calCall("xctest-ledger-dup-" + UUID().uuidString, start)
        defer { cleanup([dup.call_id], around: start) }
        try add(dup.call_id, title: "PR89 gate", at: start); try add(dup.call_id, title: "PR89 gate", at: start.addingTimeInterval(3600))
        func result(_ c: DeviceCall, title: String, at date: Date?) -> DeviceCallResult {
            var r = DeviceCallResult(call_id: c.call_id, status: .ok, data: ["event_id": .string("stale-" + UUID().uuidString)]); r.savedIdentity = .init(title: title, start: date); return r
        }
        ledger.record(call: dup, result: result(dup, title: "PR89 gate", at: start), token: token)
        do { let u = await ledger.undo(callID: dup.call_id); XCTAssertEqual(u, .unknown) }
        XCTAssertFalse(ledger.isUndone(callID: dup.call_id))
        XCTAssertEqual(events(with: [dup.call_id], around: start), 2, "neither the original nor the copy was deleted")
        // 2) single marker match, identity differs (title) → unknown, kept.
        let other = calCall("xctest-ledger-mismatch-" + UUID().uuidString, start)
        defer { cleanup([other.call_id], around: start) }
        try add(other.call_id, title: "someone else's copy", at: start)
        ledger.record(call: other, result: result(other, title: "PR89 gate", at: start), token: token)
        do { let u = await ledger.undo(callID: other.call_id); XCTAssertEqual(u, .unknown) }
        XCTAssertFalse(ledger.isUndone(callID: other.call_id))
        XCTAssertEqual(events(with: [other.call_id], around: start), 1)
        // 3) single marker match, start moved → unknown, kept.
        let moved = calCall("xctest-ledger-start-" + UUID().uuidString, start)
        defer { cleanup([moved.call_id], around: start) }
        try add(moved.call_id, title: "PR89 gate", at: start.addingTimeInterval(7200))
        ledger.record(call: moved, result: result(moved, title: "PR89 gate", at: start), token: token)
        do { let u = await ledger.undo(callID: moved.call_id); XCTAssertEqual(u, .unknown) }
        XCTAssertEqual(events(with: [moved.call_id], around: start), 1)
        // 4) p89h-2: missing identity is never a wildcard — single marker match, no saved identity → unknown, kept.
        let legacy = calCall("xctest-ledger-noid-" + UUID().uuidString, start)
        defer { cleanup([legacy.call_id], around: start) }
        try add(legacy.call_id, title: "PR89 gate", at: start)
        ledger.record(call: legacy, result: .init(call_id: legacy.call_id, status: .ok, data: ["event_id": .string("stale-" + UUID().uuidString)]), token: token)
        do { let u = await ledger.undo(callID: legacy.call_id); XCTAssertEqual(u, .unknown) }
        XCTAssertEqual(events(with: [legacy.call_id], around: start), 1)
        // 5) p89h-2: empty saved title must equal the object's title (no "empty = any"); saved start nil vs object start → unknown.
        let blank = calCall("xctest-ledger-blank-" + UUID().uuidString, start)
        defer { cleanup([blank.call_id], around: start) }
        try add(blank.call_id, title: "someone's copy", at: start)
        ledger.record(call: blank, result: result(blank, title: "", at: start), token: token)
        do { let u = await ledger.undo(callID: blank.call_id); XCTAssertEqual(u, .unknown) }
        let nostart = calCall("xctest-ledger-nostart-" + UUID().uuidString, start)
        defer { cleanup([nostart.call_id], around: start) }
        try add(nostart.call_id, title: "PR89 gate", at: start)
        ledger.record(call: nostart, result: result(nostart, title: "PR89 gate", at: nil), token: token)
        do { let u = await ledger.undo(callID: nostart.call_id); XCTAssertEqual(u, .unknown) }
        XCTAssertEqual(events(with: [blank.call_id, nostart.call_id], around: start), 2)
    }

    /// Codex p89h-3: REAL Router → restore lookup → dedupe → Ledger → REAL Adapter with a user COPY (same marker notes).
    /// Every stage refuses to pick: restore → nil (unknown), dedupe → duplicate_marker_ambiguous (no new write), undo →
    /// unknown even though the recorded id still resolves. Counter-case: copy removed → undo really deletes (undone).
    func testRouterRestoreDedupeLedgerRefuseMultiMatchCalendar() async throws {
        try need(.event)
        let start = Date().addingTimeInterval(14 * 86400)
        let call = calCall("xctest-multi-cal-" + UUID().uuidString, start, title: "p89h multi")
        defer { cleanup([call.call_id], around: start) }
        DeviceCallGate.receive(call)
        let router = DeviceToolRouter(store: Self.sharedStore)
        let first = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(first.savedIdentity?.title, "p89h multi"); XCTAssertNotNil(first.savedIdentity?.start)
        let restoredBefore = await router.lookup(call)
        XCTAssertNotNil(restoredBefore, "control: a single original is restorable")
        XCTAssertEqual(restoredBefore?.savedIdentity, first.savedIdentity)
        // user duplicates the event (EventKit copy keeps notes)
        let copy = EKEvent(eventStore: store); copy.title = "p89h multi"; copy.startDate = start.addingTimeInterval(3600); copy.endDate = start.addingTimeInterval(5400)
        copy.notes = DeviceToolContract.callMarker(call.call_id); copy.calendar = store.defaultCalendarForNewEvents
        try store.save(copy, span: .thisEvent, commit: true)
        let copyID = try XCTUnwrap(copy.eventIdentifier)
        let restored = await router.lookup(call)
        XCTAssertNil(restored, "restore never picks one of several")
        var trace: [String] = []; DeviceToolRouter.trace = { trace.append($0) }
        let again = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        DeviceToolRouter.trace = nil
        XCTAssertEqual(trace, ["dedupe-ambiguous:calendar"]); XCTAssertEqual(again.data?["reason"], .string("duplicate_marker_ambiguous"))
        XCTAssertEqual(events(with: [call.call_id], around: start), 2, "no third event")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-multi-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DeviceLedger(url: url, epoch: DeviceCallGate.epoch, items: EventKitLedgerItemStore(store: Self.sharedStore))
        ledger.record(call: call, result: first, token: try XCTUnwrap(DeviceCallGate.epoch.capture()))
        do { let u = await ledger.undo(callID: call.call_id); XCTAssertEqual(u, .unknown, "id resolves but the marker is not unique → unknown") }
        XCTAssertFalse(ledger.isUndone(callID: call.call_id))
        XCTAssertEqual(events(with: [call.call_id], around: start), 2, "nothing deleted")
        store.reset(); if let c = store.event(withIdentifier: copyID) { try store.remove(c, span: .thisEvent, commit: true) }
        do { let u = await ledger.undo(callID: call.call_id); XCTAssertEqual(u, .undone, "counter-case: unique + identity match → really deleted") }
        XCTAssertEqual(events(with: [call.call_id], around: start), 0)
    }

    func testRouterRestoreDedupeLedgerRefuseMultiMatchReminder() async throws {
        try need(.reminder)
        let id = "xctest-multi-rem-" + UUID().uuidString
        let call = DeviceCall(call_id: id, tool: "reminder_create", args: ["title": .string("p89h rem")], confirm: .card, ttl_sec: 600)
        func marked() async -> [EKReminder] {
            Self.sharedStore.reset()
            let all: [EKReminder] = await withCheckedContinuation { c in Self.sharedStore.fetchReminders(matching: Self.sharedStore.predicateForReminders(in: nil)) { c.resume(returning: $0 ?? []) } }
            return all.filter { $0.notes?.contains(DeviceToolContract.callMarker(id)) == true }
        }
        defer { Task { @MainActor in for r in await marked() { try? Self.sharedStore.remove(r, commit: true) } } }
        DeviceCallGate.receive(call)
        let router = DeviceToolRouter(store: Self.sharedStore)
        let first = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(first.savedIdentity?.title, "p89h rem")
        let control = await router.lookup(call); XCTAssertNotNil(control, "control: single original is restorable")
        let copy = EKReminder(eventStore: store); copy.title = "p89h rem"; copy.notes = "Catpaw · " + DeviceToolContract.callMarker(id)
        copy.calendar = store.defaultCalendarForNewReminders(); try store.save(copy, commit: true)
        let restored = await router.lookup(call); XCTAssertNil(restored, "restore never picks one of several")
        var trace: [String] = []; DeviceToolRouter.trace = { trace.append($0) }
        let again = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        DeviceToolRouter.trace = nil
        XCTAssertEqual(trace, ["dedupe-ambiguous:reminder"]); XCTAssertEqual(again.data?["reason"], .string("duplicate_marker_ambiguous"))
        let count2 = await marked().count; XCTAssertEqual(count2, 2, "no third reminder")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-multi-rem-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DeviceLedger(url: url, epoch: DeviceCallGate.epoch, items: EventKitLedgerItemStore(store: Self.sharedStore))
        ledger.record(call: call, result: first, token: try XCTUnwrap(DeviceCallGate.epoch.capture()))
        do { let u = await ledger.undo(callID: id); XCTAssertEqual(u, .unknown, "id resolves but marker not unique → unknown") }
        let count3 = await marked().count; XCTAssertEqual(count3, 2)
        try store.remove(copy, commit: true)
        do { let u = await ledger.undo(callID: id); XCTAssertEqual(u, .undone, "counter-case: unique + identity → deleted") }
        let count4 = await marked().count; XCTAssertEqual(count4, 0)
    }

    /// Codex p89e-3 / p89i-2: REAL EventKit adapter. A stale id is NOT resolved by marker (unknown, kept);
    /// an id that can't be resolved and has no marker stays `.unknown` (never "already gone", never marked undone).
    func testRealEventKitLedgerAdapterKeepsUnknownWhenAbsenceUnproven() async throws {
        try need(.event); try need(.reminder)
        let start = Date().addingTimeInterval(11 * 86400)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-real-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DeviceLedger(url: url, epoch: DeviceCallGate.epoch, items: EventKitLedgerItemStore(store: Self.sharedStore))
        let token = try XCTUnwrap(DeviceCallGate.epoch.capture())
        // 1) event exists, ledger id is stale → found by marker → removed.
        let moved = calCall("xctest-ledger-moved-" + UUID().uuidString, start)
        let e = EKEvent(eventStore: store); e.title = "PR89 gate"; e.startDate = start; e.endDate = start.addingTimeInterval(1800)
        e.notes = DeviceToolContract.callMarker(moved.call_id); e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
        var movedResult = DeviceCallResult(call_id: moved.call_id, status: .ok, data: ["event_id": .string("stale-" + UUID().uuidString)])
        movedResult.savedIdentity = .init(title: "PR89 gate", start: e.startDate)   // p89h-2: identity of the object actually saved
        ledger.record(call: moved, result: movedResult, token: token)
        // p89i-2: no marker fallback any more — an object found only by marker is exactly what a user copy looks like.
        do { let u = await ledger.undo(callID: moved.call_id); XCTAssertEqual(u, .unknown, "stale id → unknown, never a marker stand-in") }
        XCTAssertFalse(ledger.isUndone(callID: moved.call_id))
        XCTAssertEqual(events(with: [moved.call_id], around: start), 1, "the marker-matched object was NOT removed")
        cleanup([moved.call_id], around: start)
        // 2) unresolvable id, no marker anywhere → unknown, not undone.
        let ghost = calCall("xctest-ledger-ghost-" + UUID().uuidString, start)
        ledger.record(call: ghost, result: .init(call_id: ghost.call_id, status: .ok, data: ["event_id": .string("gone-" + UUID().uuidString)]), token: token)
        do { let u = await ledger.undo(callID: ghost.call_id); XCTAssertEqual(u, .unknown) }
        XCTAssertFalse(ledger.isUndone(callID: ghost.call_id))
        // 3) reminder id that doesn't resolve → unknown.
        let rem = DeviceCall(call_id: "xctest-ledger-rem-" + UUID().uuidString, tool: "reminder_create", args: ["title": .string("x")], confirm: .card, ttl_sec: 600)
        ledger.record(call: rem, result: .init(call_id: rem.call_id, status: .ok, data: ["reminder_id": .string("gone-" + UUID().uuidString)]), token: token)
        do { let u = await ledger.undo(callID: rem.call_id); XCTAssertEqual(u, .unknown) }
        XCTAssertFalse(ledger.isUndone(callID: rem.call_id))
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
    func testLedgerIsPerAccount() async throws {
        final class FakeItems: DeviceLedgerItemStore {
            var removed: [String] = []; var next: DeviceLedgerRemoval = .removed
            func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> DeviceLedgerRemoval { removed.append(itemID); return next }
        }
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
        do { let u = await ledger.undo(callID: "led-1"); XCTAssertEqual(u, .unknown, "B cannot undo A's item") }
        XCTAssertTrue(items.removed.isEmpty)
        ledger.record(call: DeviceCall(call_id: "led-late", tool: "calendar_create", args: [:], confirm: .card, ttl_sec: 600),
                      result: .init(call_id: "led-late", status: .ok, data: ["event_id": .string("evt-late")]), token: tokA)
        epoch.activate(account: "A")
        XCTAssertEqual(ledger.active.map(\.id), ["led-1"], "a late result with A's old token is not recorded")
        items.next = .permissionRevoked
        do { let u = await ledger.undo(callID: "led-1"); XCTAssertEqual(u, .unknown, "p89d-5 no permission → unknown, not alreadyGone") }
        items.next = .undetermined
        do { let u = await ledger.undo(callID: "led-1"); XCTAssertEqual(u, .unknown, "p89d-5 unreadable store → unknown") }
        XCTAssertFalse(ledger.isUndone(callID: "led-1"), "an unknown outcome never marks the entry undone")
        items.next = .removed
        do { let u = await ledger.undo(callID: "led-1"); XCTAssertEqual(u, .undone); XCTAssertEqual(items.removed, ["evt-A", "evt-A", "evt-A"]) }
        ledger.signOut(account: "A")
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertTrue(DeviceLedger(url: url, epoch: epoch, items: items).entries.isEmpty, "cleared on disk too")
    }

    // MARK: p89i — receipts are the only trust source; unprovable → user decision; async undo outside the lock.

    private func tempLedger(_ items: DeviceLedgerItemStore? = nil) -> (DeviceLedger, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-p89i-\(UUID().uuidString).json")
        return (DeviceLedger(url: url, epoch: DeviceCallGate.epoch, items: items ?? EventKitLedgerItemStore(store: Self.sharedStore)), url)
    }
    private func tempReceipts() -> DeviceCreationReceipts { DeviceCreationReceipts(url: FileManager.default.temporaryDirectory.appendingPathComponent("receipts-\(UUID().uuidString).json")) }
    private func markedEvent(_ id: String, title: String, at date: Date) throws -> String {
        let e = EKEvent(eventStore: store); e.title = title; e.startDate = date; e.endDate = date.addingTimeInterval(1800)
        e.notes = DeviceToolContract.callMarker(id); e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true); return try XCTUnwrap(e.eventIdentifier)
    }
    private func exists(_ eventID: String) -> Bool { store.reset(); return store.event(withIdentifier: eventID) != nil }
    /// A DeviceCallStore as it is found after a kill: the call persisted `.running` for this account, nothing else.
    private func coldStore(with call: DeviceCall) throws -> DeviceCallStore {
        let suite = "xctest.cold." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let rec = [call.call_id: DeviceCallStore.Record(phase: .running, call: call, updatedAt: .now, account: "xctest-user")]
        defaults.set(try JSONEncoder().encode(rec), forKey: DeviceCallStore.storageKey)
        return DeviceCallStore(defaults: defaults)
    }

    /// Codex p89i-1 counter-example on the REAL cold-restore chain: persisted `.running` → new Store → resumeInterrupted →
    /// Router.lookup → finish/recorder → Ledger → undo. A marker match is never trusted on its own.
    func testColdRestoreNeverTrustsAMarkerMatchAlone() async throws {
        try need(.event)
        let receipts = tempReceipts(), router = DeviceToolRouter(store: Self.sharedStore, receipts: receipts)
        let (ledger, url) = tempLedger(); defer { try? FileManager.default.removeItem(at: url) }
        DeviceCallHub.executor = router; DeviceCallHub.submitter = DeviceResultSubmitterStub()
        DeviceCallHub.recorder = { c, r, t in ledger.record(call: c, result: r, token: t) }
        defer { DeviceCallHub.recorder = nil }
        // A) original created (receipt written), ledger never written (kill); user copies + edits the copy, deletes the original.
        let startA = Date().addingTimeInterval(21 * 86400)
        let a = calCall("xctest-cold-copy-" + UUID().uuidString, startA, title: "p89i cold")
        DeviceCallGate.receive(a)
        let created = await router.execute(a, credential: try XCTUnwrap(credential(a))); XCTAssertEqual(created.status, .ok)
        let originalID = try XCTUnwrap(created.data?["event_id"]?.text)
        let copyID = try markedEvent(a.call_id, title: "p89i cold (copy, edited)", at: startA.addingTimeInterval(3600))
        store.reset(); try store.remove(try XCTUnwrap(store.event(withIdentifier: originalID)), span: .thisEvent, commit: true)
        let stA = try coldStore(with: a); XCTAssertTrue(stA.isInterrupted(a.call_id))
        await stA.resumeInterrupted(a.call_id)
        XCTAssertNil(ledger.entry(callID: a.call_id), "the copy found by marker is not recorded as Catpaw's item")
        switch stA.phase(a.call_id) {
        case .reportFailed(let r), .done(let r): XCTAssertNotEqual(r.status, .ok, "restore reported unknown, not success")
        default: XCTFail("restore did not finish")
        }
        let attemptA = await ledger.undoAttempt(callID: a.call_id); XCTAssertEqual(attemptA, .done(.unknown))
        XCTAssertTrue(exists(copyID), "the copy was never deleted")
        store.reset(); if let c = store.event(withIdentifier: copyID) { try store.remove(c, span: .thisEvent, commit: true) }
        // B) crash between save and receipt: a marked event, no receipt → unknown, untouched.
        let startB = Date().addingTimeInterval(22 * 86400)
        let b = calCall("xctest-cold-noreceipt-" + UUID().uuidString, startB, title: "p89i noreceipt")
        let bID = try markedEvent(b.call_id, title: "p89i noreceipt", at: startB)
        let stB = try coldStore(with: b); await stB.resumeInterrupted(b.call_id)
        XCTAssertNil(ledger.entry(callID: b.call_id)); XCTAssertTrue(exists(bID))
        store.reset(); if let e = store.event(withIdentifier: bID) { try store.remove(e, span: .thisEvent, commit: true) }
        // C) counter-case: receipt + intact original → recovered with the RECEIPT identity → undo really deletes it.
        let startC = Date().addingTimeInterval(23 * 86400)
        let c = calCall("xctest-cold-ok-" + UUID().uuidString, startC, title: "p89i ok")
        DeviceCallGate.receive(c)
        let made = await router.execute(c, credential: try XCTUnwrap(credential(c))); let cID = try XCTUnwrap(made.data?["event_id"]?.text)
        let stC = try coldStore(with: c); await stC.resumeInterrupted(c.call_id)
        let entry = try XCTUnwrap(ledger.entry(callID: c.call_id), "recovered from the receipt")
        XCTAssertEqual(entry.saved, receipts.receipt(c.call_id, account: "xctest-user")?.identity)
        let attemptC = await ledger.undoAttempt(callID: c.call_id); XCTAssertEqual(attemptC, .done(.undone))
        XCTAssertFalse(exists(cID))
    }

    /// Codex p89i-2: explicit query rule — far-future events, copies outside the window, moved objects, copies inside.
    /// Unprovable cases become a USER decision (candidates; default keep), each choice's effect asserted.
    func testQueryRuleAndUserDecisionForUnprovableUndo() async throws {
        try need(.event)
        let receipts = tempReceipts(), router = DeviceToolRouter(store: Self.sharedStore, receipts: receipts)
        let (ledger, url) = tempLedger(); defer { try? FileManager.default.removeItem(at: url) }
        let token = try XCTUnwrap(DeviceCallGate.epoch.capture())
        func make(_ prefix: String, _ start: Date) async throws -> (DeviceCall, String) {
            let call = calCall(prefix + UUID().uuidString, start, title: "p89i rule"); DeviceCallGate.receive(call)
            let r = await router.execute(call, credential: try XCTUnwrap(credential(call))); XCTAssertEqual(r.status, .ok)
            ledger.record(call: call, result: r, token: token); return (call, try XCTUnwrap(r.data?["event_id"]?.text))
        }
        // 1) far future (500 days): window is around the SAVED start → proven → deleted.
        let (far, farID) = try await make("xctest-far-", Date().addingTimeInterval(500 * 86400))
        let farAttempt = await ledger.undoAttempt(callID: far.call_id); XCTAssertEqual(farAttempt, .done(.undone)); XCTAssertFalse(exists(farID))
        // 2) copy OUTSIDE the window (+400 d): not counted; the original is proven by id + identity → deleted; copy untouched.
        let s2 = Date().addingTimeInterval(24 * 86400)
        let (out, outID) = try await make("xctest-outwin-", s2)
        let farCopy = try markedEvent(out.call_id, title: "p89i rule", at: s2.addingTimeInterval(400 * 86400))
        let outAttempt = await ledger.undoAttempt(callID: out.call_id); XCTAssertEqual(outAttempt, .done(.undone))
        XCTAssertFalse(exists(outID)); XCTAssertTrue(exists(farCopy), "a copy outside the window can never pass the id check")
        store.reset(); if let e = store.event(withIdentifier: farCopy) { try store.remove(e, span: .thisEvent, commit: true) }
        // 3) moved by the user (+1 day): identity differs → user decision, nothing deleted until the choice.
        let s3 = Date().addingTimeInterval(25 * 86400)
        let (moved, movedID) = try await make("xctest-moved-", s3)
        store.reset(); let ev = try XCTUnwrap(store.event(withIdentifier: movedID)); ev.startDate = s3.addingTimeInterval(86400); ev.endDate = s3.addingTimeInterval(88200)
        try store.save(ev, span: .thisEvent, commit: true)
        guard case .needsChoice(let c3) = await ledger.undoAttempt(callID: moved.call_id) else { return XCTFail("moved → the user decides") }
        XCTAssertEqual(c3.map(\.id), [movedID]); XCTAssertTrue(c3[0].isRecorded); XCTAssertTrue(exists(movedID), "prompt only, nothing deleted")
        ledger.keepAll(callID: moved.call_id); XCTAssertTrue(exists(movedID), "都保留 → kept"); XCTAssertFalse(ledger.isUndone(callID: moved.call_id))
        XCTAssertEqual(ledger.undoChosen(callID: moved.call_id, itemID: movedID), .undone); XCTAssertFalse(exists(movedID))
        XCTAssertTrue(ledger.isUndone(callID: moved.call_id), "the recorded object was chosen → undone")
        // 4) copy INSIDE the window: two candidates; choosing the copy deletes only the copy and does not mark undone.
        let s4 = Date().addingTimeInterval(26 * 86400)
        let (dup, dupID) = try await make("xctest-dupchoice-", s4)
        let copyID = try markedEvent(dup.call_id, title: "p89i rule", at: s4.addingTimeInterval(3600))
        guard case .needsChoice(let c4) = await ledger.undoAttempt(callID: dup.call_id) else { return XCTFail("copy → the user decides") }
        XCTAssertEqual(Set(c4.map(\.id)), [dupID, copyID]); XCTAssertEqual(c4.first { $0.isRecorded }?.id, dupID)
        XCTAssertTrue(exists(dupID) && exists(copyID), "prompt only")
        XCTAssertEqual(ledger.undoChosen(callID: dup.call_id, itemID: copyID), .undone)
        XCTAssertFalse(exists(copyID)); XCTAssertTrue(exists(dupID)); XCTAssertFalse(ledger.isUndone(callID: dup.call_id))
        let after = await ledger.undoAttempt(callID: dup.call_id); XCTAssertEqual(after, .done(.undone), "unique again → proven"); XCTAssertFalse(exists(dupID))
        XCTAssertTrue(DeviceLedger.decisions.contains { $0.contains("\(moved.call_id): user kept all") })
        XCTAssertTrue(DeviceLedger.decisions.contains { $0.contains("\(dup.call_id): user chose \(copyID)") })
    }

    /// Codex p89i-3: the reminder query is async (no semaphore) and runs OUTSIDE the account lock; sign-out / switch /
    /// edit during the query → the final commit refuses, nothing deleted. Permission gone → the user is asked.
    func testReminderUndoQueryOutsideLockAndLogoutDuringQuery() async throws {
        try need(.reminder)
        let receipts = tempReceipts(), router = DeviceToolRouter(store: Self.sharedStore, receipts: receipts)
        func make(_ title: String) async throws -> (DeviceCall, String) {
            let call = DeviceCall(call_id: "xctest-remq-" + UUID().uuidString, tool: "reminder_create", args: ["title": .string(title)], confirm: .card, ttl_sec: 600)
            DeviceCallGate.receive(call); let r = await router.execute(call, credential: try XCTUnwrap(credential(call))); XCTAssertEqual(r.status, .ok)
            return (call, try XCTUnwrap(r.data?["reminder_id"]?.text))
        }
        func alive(_ id: String) -> Bool { store.reset(); return store.calendarItem(withIdentifier: id) != nil }
        for scenario in ["signOut", "switch", "edited"] {
            DeviceCallGate.epoch = AccountEpoch(account: "xctest-user")
            let (call, rid) = try await make("p89i rem " + scenario)
            let adapter = EventKitLedgerItemStore(store: Self.sharedStore)
            let (ledger, url) = tempLedger(adapter); defer { try? FileManager.default.removeItem(at: url) }
            let token = try XCTUnwrap(DeviceCallGate.epoch.capture())
            ledger.record(call: call, result: { var r = DeviceCallResult(call_id: call.call_id, status: .ok, data: ["reminder_id": .string(rid)]); r.savedIdentity = receipts.receipt(call.call_id, account: "xctest-user")?.identity; return r }(), token: token)
            var ran = false
            adapter.afterQuery = {
                ran = true
                XCTAssertTrue(DeviceCallGate.epoch.isValid(token), "the account lock is free during the query (isValid takes it)")
                switch scenario {
                case "signOut": DeviceCallGate.epoch.signOut()
                case "switch": DeviceCallGate.epoch.activate(account: "someone-else")
                default: if let r = self.store.calendarItem(withIdentifier: rid) as? EKReminder { r.title = "edited by user"; try? self.store.save(r, commit: true) }
                }
            }
            let o = await ledger.undo(callID: call.call_id)
            XCTAssertTrue(ran, scenario); XCTAssertEqual(o, .unknown, scenario); XCTAssertTrue(alive(rid), "\(scenario): nothing deleted")
            if let r = store.calendarItem(withIdentifier: rid) as? EKReminder { try? store.remove(r, commit: true) }
        }
        // Permission revoked → the user is asked (fake store: the simulator can't revoke in-process); nothing removed.
        final class NoPermission: DeviceLedgerItemStore {
            var removed = 0
            func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> DeviceLedgerRemoval { removed += 1; return .removed }
            func prepareRemoval(kind: DeviceLedgerEntry.Kind, itemID: String, callID: String, identity: DeviceSavedIdentity?) async -> DeviceLedgerRemovalPlan { .decided(.permissionRevoked) }
        }
        DeviceCallGate.epoch = AccountEpoch(account: "xctest-user")
        let np = NoPermission(); let (ledger, url) = tempLedger(np); defer { try? FileManager.default.removeItem(at: url) }
        let call = DeviceCall(call_id: "xctest-noperm-" + UUID().uuidString, tool: "reminder_create", args: ["title": .string("x")], confirm: .card, ttl_sec: 600)
        ledger.record(call: call, result: .init(call_id: call.call_id, status: .ok, data: ["reminder_id": .string("r1")]), token: try XCTUnwrap(DeviceCallGate.epoch.capture()))
        let attempt = await ledger.undoAttempt(callID: call.call_id)
        XCTAssertEqual(attempt, .needsPermission); XCTAssertEqual(np.removed, 0); XCTAssertFalse(ledger.isUndone(callID: call.call_id))
    }

    /// p89i generic park + per-item decision (AccountParkedItems) with the device-call source: only the leaving account's
    /// items are collected; per item keep / cancel applied deterministically; unanswered = keep; every line logged.
    func testParkedDeviceCallsPerItemDecision() async throws {
        let keepCall = calCall("xctest-park-keep-" + UUID().uuidString, Date().addingTimeInterval(86400))
        let cancelCall = calCall("xctest-park-cancel-" + UUID().uuidString, Date().addingTimeInterval(86400))
        let silent = calCall("xctest-park-silent-" + UUID().uuidString, Date().addingTimeInterval(86400))
        for c in [keepCall, cancelCall, silent] { DeviceCallGate.receive(c) }
        let suite = "xctest.park." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var recs: [String: DeviceCallStore.Record] = [:]
        for c in [keepCall, cancelCall, silent] { recs[c.call_id] = .init(phase: .running, call: c, updatedAt: .now, account: "xctest-user") }
        let other = calCall("xctest-park-other-" + UUID().uuidString, Date()); recs[other.call_id] = .init(phase: .running, call: other, updatedAt: .now, account: "someone-else")
        defaults.set(try JSONEncoder().encode(recs), forKey: DeviceCallStore.storageKey)
        let st = DeviceCallStore(defaults: defaults)
        AccountParkedItems.register(DeviceCallParkedSource.key, DeviceCallParkedSource(store: st)); defer { AccountParkedItems.unregister(DeviceCallParkedSource.key) }
        DeviceCallGate.epoch.signOut()   // order step 1 happens before collect
        let items = AccountParkedItems.collect(account: "xctest-user")
        XCTAssertEqual(Set(items.map(\.key)), Set([keepCall, cancelCall, silent].map { "running:" + $0.call_id }), "only the leaving account's items")
        XCTAssertTrue(items.allSatisfy { $0.title.hasPrefix("进行中：添加日程") })
        let lines = await AccountParkedItems.resolve(account: "xctest-user") { _ in
            ["\(DeviceCallParkedSource.key)/running:\(keepCall.call_id)": .keep, "\(DeviceCallParkedSource.key)/running:\(cancelCall.call_id)": .cancel]
        }
        XCTAssertEqual(st.phase(cancelCall.call_id), .expired); XCTAssertFalse(DeviceCallGate.isLive(cancelCall.call_id))
        XCTAssertEqual(st.phase(keepCall.call_id), .running, "keep → parked for that account"); XCTAssertEqual(st.phase(silent.call_id), .running, "no answer → keep")
        XCTAssertEqual(st.phase(other.call_id), .running, "another account's item untouched")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.contains("\(DeviceCallParkedSource.key)/running:\(cancelCall.call_id) cancel: revoked + card expired"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("\(DeviceCallParkedSource.key)/running:\(silent.call_id) keep:") })
        let reopened = DeviceCallStore(defaults: defaults)
        XCTAssertFalse(reopened.isInterrupted(cancelCall.call_id), "a cancelled item is never restored"); XCTAssertTrue(reopened.isInterrupted(keepCall.call_id), "a kept item is offered again (lookup-only restore)")
    }

    func testCalendarCreateDedupesByCallID() async throws {
        try need(.event)
        let id = "xctest-cal-" + UUID().uuidString, start = Date().addingTimeInterval(3 * 86400)
        let call = calCall(id, start, title: "NoBug dedupe")
        DeviceCallGate.receive(call)
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore), c = try XCTUnwrap(credential(call))
        let first = await router.execute(call, credential: c)
        let replay = await router.execute(call, credential: c)   // p89d-1: consumed at the execution boundary
        XCTAssertEqual(replay.data?["reason"], .string("credential_required"))
        let second = await router.execute(call, credential: try XCTUnwrap(credential(call)))   // a fresh tap (e.g. relaunch re-run)
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
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore), c = try XCTUnwrap(credential(call))
        let first = await router.execute(call, credential: c)
        let second = await router.execute(call, credential: try XCTUnwrap(credential(call)))
        XCTAssertEqual(first.status, .ok); XCTAssertEqual(second.data?["deduped"], .bool(true), "\(String(describing: second.data))")
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

/// Codex p89d-6: end-to-end wiring on the REAL AccountEpoch.shared (no injected epoch):
/// Auth (NativeAuthSessionManager with accountBarrier .shared + the app's barrier) → ConversationSessionService (typed SSE
/// device_call, principal-bound source token) → DeviceCallGate lifecycle → DeviceToolRouter (EventKit) / DeviceLedger.
/// Passive invalidation happens at the manager (refresh fails) — no app model, no SwiftUI task.
actor WiringDeviceCallBackend: ConversationBackend {
    let calls: [ConversationDeviceCall]
    private var live: AsyncThrowingStream<ConversationTurnEvent, Error>.Continuation?
    init(calls: [ConversationDeviceCall]) { self.calls = calls }
    func connection(scope: DataScope) async -> ConversationConnection { ConversationConnection(state: .connected, provider: "Wiring test backend", detail: "Test only") }
    func reply(_ r: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let (stream, c) = AsyncThrowingStream.makeStream(of: ConversationTurnEvent.self)
        for (i, call) in calls.enumerated() { c.yield(ConversationTurnEvent(operationID: r.operationID, epoch: r.epoch, sequence: i + 1, payload: .deviceCall(call))) }
        live = c
        return stream
    }
    func cancelTurn(_ r: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt { .init(turnID: r.operationID, state: "failed", cancelled: true, alreadyTerminal: false) }
    func observe(_ r: ConversationTurnRequest) async throws -> ConversationObservation { throw CatpawError.unavailable("wiring test") }
}

final class LifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var tokens: [String: AccountToken?] = [:]
    func add(_ id: String, _ token: AccountToken?) { lock.lock(); tokens[id] = .some(token); lock.unlock() }
    func seen(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return tokens[id] != nil }
    func token(_ id: String) -> AccountToken? { lock.lock(); defer { lock.unlock() }; return tokens[id] ?? nil }
}

actor CountingDemoBackend: ConversationBackend {
    let inner = CatpawDemoConversationBackend()
    private(set) var uiSubmits = 0
    func connection(scope: DataScope) async -> ConversationConnection { await inner.connection(scope: scope) }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> { try await inner.reply(request) }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation { try await inner.observe(request) }
    func submitApproval(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationApprovalDecision, argsHash: String, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        try await inner.submitApproval(request, interruptID: interruptID, decision: decision, argsHash: argsHash, operationID: operationID, afterSequence: afterSequence)
    }
    func submitUIDecision(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        uiSubmits += 1
        return try await inner.submitUIDecision(request, interruptID: interruptID, decision: decision, argsHash: argsHash, response: response, operationID: operationID, afterSequence: afterSequence)
    }
}

actor HeldStreamUIBackend: ConversationBackend {
    private var live: AsyncThrowingStream<ConversationTurnEvent, Error>.Continuation?
    private(set) var uiSubmits = 0
    var streaming: Bool { live != nil }
    func connection(scope: DataScope) async -> ConversationConnection { ConversationConnection(state: .connected, provider: "Held test backend", detail: "Test only") }
    func reply(_ r: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        let (stream, c) = AsyncThrowingStream.makeStream(of: ConversationTurnEvent.self); live = c; return stream
    }
    func finishStream() { live?.finish(); live = nil }
    func submitUIDecision(_ request: ConversationTurnRequest, interruptID: String, decision: ConversationUIDecision, argsHash: String, response: Data?, operationID: UUID, afterSequence: Int) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        uiSubmits += 1; throw ConversationApprovalFailure.notFound
    }
    func cancelTurn(_ r: ConversationTurnRequest) async throws -> ConversationTurnCancelReceipt { .init(turnID: r.operationID, state: "failed", cancelled: true, alreadyTerminal: false) }
    func observe(_ r: ConversationTurnRequest) async throws -> ConversationObservation { throw CatpawError.unavailable("held test") }
}

@MainActor final class DeviceCallSharedEpochWiringTests: XCTestCase {
    private var ek: EKEventStore { DeviceToolRouterEventKitTests.sharedStore }
    override func tearDown() async throws { DeviceCallGate.reset(); AccountEpoch.shared.activate(account: nil); DeviceCallGate.epoch = .shared; ConversationDeviceCall.lifecycle = nil }

    /// Codex p89e-1: the operation's source = account AND login generation, pinned before its first await. The same account
    /// signing out and back in while the operation is suspended must NOT let the old operation's device_call be granted.
    func testSameAccountReloginDuringFirstAwaitRefusesOldOperation() async throws {
        let account = UUID().uuidString
        AccountEpoch.shared.activate(account: account)
        let oldLogin = try XCTUnwrap(AccountEpoch.shared.capture())
        DeviceCallGate.installLifecycle()
        let id = "relogin-" + UUID().uuidString
        let args: [String: DeviceCallValue] = ["title": .string("relogin")]
        let wire = ConversationDeviceCall(interruptID: UUID().uuidString.lowercased(), callID: id, tool: "reminder_create", args: try JSONEncoder().encode(args), confirm: "card", ttlSec: 600,
                                          argsHash: String(repeating: "a", count: 64), expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)))
        let repo = try Repository(persistence: FilePersistence(url: FileManager.default.temporaryDirectory.appendingPathComponent("relogin-\(UUID().uuidString).json")))
        let service = ConversationSessionService(repository: repo, backend: WiringDeviceCallBackend(calls: [wire]), principalAccount: account)
        let conversation = try await service.create(scope: Profiles.user)
        var relogged: AccountToken?
        ConversationSessionService.beforeClaimHook = {   // inside the operation, after its source was pinned
            AccountEpoch.shared.signOut(); AccountEpoch.shared.activate(account: account); relogged = AccountEpoch.shared.capture()
            ConversationSessionService.beforeClaimHook = nil
        }
        defer { ConversationSessionService.beforeClaimHook = nil }
        // p89g-4: record what reaches the service→gate lifecycle entry (call id → source token carried), then forward.
        let recorder = LifecycleRecorder()
        let installed = ConversationDeviceCall.lifecycle
        ConversationDeviceCall.lifecycle = { event in
            if case .received(let wire, _, _, let token) = event { recorder.add(wire.callID, token) }
            installed?(event)
        }
        let sending = Task { _ = try? await service.send(scope: Profiles.user, conversationID: conversation, text: "提醒我", operationID: UUID()) }
        defer { sending.cancel() }
        // p89g-4: wait until the old operation's device_call actually REACHED the gate (no fixed sleep, no vacuous pass).
        for _ in 0..<500 where !recorder.seen(id) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(recorder.seen(id), "the old operation's device_call really reached the lifecycle entry")
        XCTAssertFalse(AccountEpoch.shared.isValid(recorder.token(id)), "…carrying no valid source for the new login")
        let newLogin = try XCTUnwrap(relogged)
        XCTAssertEqual(newLogin.account, oldLogin.account); XCTAssertNotEqual(newLogin, oldLogin, "same account, new login generation")
        XCTAssertFalse(DeviceCallGate.isLive(id), "the old operation's device_call is never granted under the new login")
        // Counter-test: an operation that starts under the new login IS granted.
        let id2 = "relogin-new-" + UUID().uuidString
        let wire2 = ConversationDeviceCall(interruptID: UUID().uuidString.lowercased(), callID: id2, tool: "reminder_create", args: try JSONEncoder().encode(args), confirm: "card", ttlSec: 600,
                                           argsHash: String(repeating: "a", count: 64), expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)))
        let service2 = ConversationSessionService(repository: repo, backend: WiringDeviceCallBackend(calls: [wire2]), principalAccount: account)
        let c2 = try await service2.create(scope: Profiles.user)
        let sending2 = Task { _ = try? await service2.send(scope: Profiles.user, conversationID: c2, text: "提醒我", operationID: UUID()) }
        defer { sending2.cancel() }
        for _ in 0..<300 where !DeviceCallGate.isLive(id2) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(DeviceCallGate.isLive(id2))
        XCTAssertTrue(AccountEpoch.shared.isValid(recorder.token(id2)), "counter-run carries the new login's source")
    }

    /// Codex p89h-1: production (account-bound) service with a REAL pending ui block (DEBUG demo backend):
    /// nil source (signed out) → refused before the backend; same login → submitted exactly once and succeeds.
    func testUIDecisionProductionSourceRules() async throws {
        let account = UUID().uuidString
        AccountEpoch.shared.activate(account: nil); AccountEpoch.shared.activate(account: account)
        defer { AccountEpoch.shared.activate(account: nil) }
        let repo = try Repository(persistence: FilePersistence(url: FileManager.default.temporaryDirectory.appendingPathComponent("uiprod-\(UUID().uuidString).json")))
        let backend = CountingDemoBackend()
        let service = ConversationSessionService(repository: repo, backend: backend, principalAccount: account)
        await service.setUIClock { Date(timeIntervalSince1970: 1_700_000_000) }   // demo blocks carry fixed 2026 deadlines
        let conversation = try await service.create(scope: Profiles.user)
        let operation = UUID()
        _ = try await service.send(scope: Profiles.user, conversationID: conversation, text: "帮我建个跑步任务，再弹个窗", operationID: operation)
        let approvals = try await service.pendingApprovals(scope: Profiles.user, conversationID: conversation)
        try await service.submitApproval(scope: Profiles.user, conversationID: conversation, interruptID: try XCTUnwrap(approvals.first).interruptID, decision: .approve)
        let pending = try await service.pendingUIBlocks(scope: Profiles.user, conversationID: conversation)
        let block = try XCTUnwrap(pending.first { $0.id == "demo-choices" })
        let choices = Data(#"{"type":"ui.response","blockId":"demo-choices","actionId":null,"values":{},"selected":["a"],"respondedAt":"2026-10-16T00:10:00Z"}"#.utf8)
        // nil source: signed out (passive invalidation) → refused, backend never called.
        AccountEpoch.shared.signOut()
        do { try await service.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: operation, interruptID: block.interruptID!, decision: .submit, argsHash: block.argsHash!, response: choices); XCTFail("nil source must be refused") }
        catch { XCTAssertEqual(error as? ConversationApprovalFailure, ConversationSessionService.missingSource) }
        var submits = await backend.uiSubmits; XCTAssertEqual(submits, 0)
        // valid login (same account re-signed in, new generation; the decision is submitted fresh under it) → exactly one submit.
        AccountEpoch.shared.activate(account: account)
        try await service.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: operation, interruptID: block.interruptID!, decision: .submit, argsHash: block.argsHash!, response: choices)
        submits = await backend.uiSubmits; XCTAssertEqual(submits, 1, "normal submit reaches the backend exactly once")
        let after = try await service.pendingUIBlocks(scope: Profiles.user, conversationID: conversation)
        XCTAssertFalse(after.contains { $0.id == "demo-choices" }, "the block was really answered")
    }

    /// Codex p89g-1: a UI decision QUEUED behind a running stream carries the login pinned at the public submit. Same
    /// account signs out and back in while it waits → at dequeue it dies (CancellationError) and never reaches the backend.
    /// Counter-run: queued under the same login → dequeued and really executed (the backend submit is called).
    func testQueuedUIDecisionSameAccountReloginNeverReachesBackend() async throws {
        for relogin in [true, false] {
            let account = UUID().uuidString
            AccountEpoch.shared.activate(account: nil); AccountEpoch.shared.activate(account: account)
            let repo = try Repository(persistence: FilePersistence(url: FileManager.default.temporaryDirectory.appendingPathComponent("uiq-\(UUID().uuidString).json")))
            let backend = HeldStreamUIBackend()
            let service = ConversationSessionService(repository: repo, backend: backend, principalAccount: account)
            let conversation = try await service.create(scope: Profiles.user)
            let sending = Task { _ = try? await service.send(scope: Profiles.user, conversationID: conversation, text: "hi", operationID: UUID()) }
            for _ in 0..<500 where !(await backend.streaming) { try await Task.sleep(nanoseconds: 10_000_000) }
            let isStreaming = await backend.streaming; XCTAssertTrue(isStreaming, "a stream is running → the decision is queued")
            let turnID = UUID()
            let submit = Task { try await service.submitUIDecision(scope: Profiles.user, conversationID: conversation, turnID: turnID, interruptID: "ui-1", decision: .dismiss, argsHash: String(repeating: "a", count: 64), response: nil) }
            for _ in 0..<500 where (await service.queuedUIDecisions(conversationID: conversation)).isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            let queued = await service.queuedUIDecisions(conversationID: conversation); XCTAssertEqual(queued, ["ui-1"])
            if relogin { AccountEpoch.shared.signOut(); AccountEpoch.shared.activate(account: account) }
            await backend.finishStream()
            let outcome = await submit.result
            _ = await sending.result
            let submits = await backend.uiSubmits
            if relogin {
                guard case .failure(let error) = outcome, error is CancellationError else { return XCTFail("queued decision from the old login must die at dequeue, got \(outcome)") }
                XCTAssertEqual(submits, 0, "never reached the backend under the new login")
            } else {
                // The fixture turn has no pending ui block: the dequeued decision reaches performUIDecision's read + check and
                // is refused with exactly noPendingApproval (backend not called). Backend execution is proven in
                // testUIDecisionProductionSourceRules with a real pending block.
                guard case .failure(let error) = outcome, (error as? ConversationApprovalFailure) == .noPendingApproval else { return XCTFail("expected noPendingApproval, got \(outcome)") }
                XCTAssertEqual(submits, 0)
            }
        }
        AccountEpoch.shared.activate(account: nil)
    }

    func testAuthServiceGateRouterLedgerOnSharedEpoch() async throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return XCTFail("calendar access must be granted (simctl privacy) — a skip is a failure") }
        XCTAssertTrue(DeviceCallGate.epoch === AccountEpoch.shared)
        // Auth: real manager, shared barrier.
        let config = try NativeAuthConfiguration(projectURL: URL(string: "https://abcdefghijklmnopqrst.supabase.co")!, publishableKey: "sb_publishable_test_public_value",
                                                 backendOrigin: URL(string: "https://backend.example.invalid")!, serverScopeID: UUID())
        let clock = AuthTestClock(), storage = AuthTestStorage(), uid = UUID()
        let remote = AuthTestRemote(issuer: config.issuer, id: uid, clock: clock)
        let manager = NativeAuthSessionManager(configuration: config, remote: remote, vault: storage, barrier: storage, now: { clock.now() }, accountBarrier: .shared)
        try await manager.signIn(email: "wiring@example.invalid", password: "fixture-only")
        NativeAuthApplicationModel.applyAccountBarrier(await manager.snapshot(), fresh: true)
        XCTAssertEqual(AccountEpoch.shared.currentAccount, uid.uuidString)
        // Service → Gate: typed SSE device_call events, principal-bound.
        DeviceCallGate.installLifecycle()
        let start = Date().addingTimeInterval(9 * 86400)
        func wire(_ id: String) -> ConversationDeviceCall {
            let args: [String: DeviceCallValue] = ["title": .string("wiring"), "start": .string(DeviceCallDates.format(start)), "end": .string(DeviceCallDates.format(start.addingTimeInterval(1800)))]
            return ConversationDeviceCall(interruptID: UUID().uuidString.lowercased(), callID: id, tool: "calendar_create", args: try! JSONEncoder().encode(args), confirm: "card", ttlSec: 600,
                                          argsHash: String(repeating: "a", count: 64), expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)))
        }
        let id1 = "wire-1-" + UUID().uuidString, id2 = "wire-2-" + UUID().uuidString
        let wire1 = wire(id1), wire2 = wire(id2)   // one wire object per call (interrupt id is part of the grant)
        let repo = try Repository(persistence: FilePersistence(url: FileManager.default.temporaryDirectory.appendingPathComponent("wiring-\(UUID().uuidString).json")))
        let service = ConversationSessionService(repository: repo, backend: WiringDeviceCallBackend(calls: [wire1, wire2]), principalAccount: uid.uuidString)
        let conversation = try await service.create(scope: Profiles.user)
        let sending = Task { _ = try? await service.send(scope: Profiles.user, conversationID: conversation, text: "建两个日程", operationID: UUID()) }
        defer { sending.cancel() }
        for _ in 0..<300 where !(DeviceCallGate.isLive(id1) && DeviceCallGate.isLive(id2)) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(DeviceCallGate.isLive(id1) && DeviceCallGate.isLive(id2), "grants come from the real service's SSE boundary on the shared epoch")
        guard let w1 = DeviceCall(wire1), let w2 = DeviceCall(wire2) else { return XCTFail("decode") }
        func cred(_ c: DeviceCall) -> DeviceCallGate.Credential? {
            if case .success(let x) = DeviceCallGate.authorize(c, finalArgs: c.args, tap: DeviceCallGate.confirmTap(c, finalArgs: c.args)) { return x }; return nil
        }
        // Router + Ledger while signed in.
        final class NoItems: DeviceLedgerItemStore { func remove(kind: DeviceLedgerEntry.Kind, itemID: String) -> DeviceLedgerRemoval { .removed } }
        let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("wiring-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        let ledger = DeviceLedger(url: ledgerURL, epoch: .shared, items: NoItems())
        let router = DeviceToolRouter(store: DeviceToolRouterEventKitTests.sharedStore)
        let c1 = try XCTUnwrap(cred(w1)), r1 = await router.execute(w1, credential: c1)
        XCTAssertEqual(r1.status, .ok)
        ledger.record(call: w1, result: r1, token: c1.token)
        XCTAssertEqual(ledger.active.map(\.id), [id1])
        // Passive invalidation AT THE SOURCE: the refresh fails inside the manager → shared barrier closes synchronously.
        let c2 = try XCTUnwrap(cred(w2))
        await remote.behavior(failRefresh: true); clock.advance(4000)
        _ = try? await manager.authorization(subject: uid)
        XCTAssertNil(AccountEpoch.shared.currentAccount, "manager closed AccountEpoch.shared itself (no app model / SwiftUI task)")
        let r2 = await router.execute(w2, credential: c2)
        XCTAssertEqual(r2.status, .error)
        ledger.record(call: w2, result: .init(call_id: id2, status: .ok, data: ["event_id": .string("late")]), token: c2.token)
        XCTAssertTrue(ledger.active.isEmpty); do { let u = await ledger.undo(callID: id1); XCTAssertEqual(u, .unknown) }
        // EventKit: exactly the signed-in write landed.
        ek.reset()
        let all = ek.events(matching: ek.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(86400), calendars: nil))
        XCTAssertEqual(all.filter { $0.notes?.contains(DeviceToolContract.callMarker(id1)) == true }.count, 1)
        XCTAssertEqual(all.filter { $0.notes?.contains(DeviceToolContract.callMarker(id2)) == true }.count, 0)
        for e in all where e.notes?.contains(DeviceToolContract.callMarker(id1)) == true { try? ek.remove(e, span: .thisEvent, commit: true) }
    }
}
