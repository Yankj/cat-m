import Foundation

// NoBug P0 portable tests (macOS swiftc, no simulator): memory persistence/migration, empty default, device-call
// durability + dedupe on relaunch, unsupported-tool reason, meituan URL, ProactiveRules (window, dedupe, leave_at, lead).
@MainActor final class FakeExecutor: DeviceToolExecuting {
    var supported: Set<String>; var executed: [String] = []; var writes: [String: String] = [:]   // call_id → item id (dedupe)
    init(_ s: Set<String>) { supported = s }
    func canExecute(_ tool: String) -> Bool { supported.contains(tool) }
    func execute(_ call: DeviceCall) async -> DeviceCallResult {
        executed.append(call.call_id)
        if let id = writes[call.call_id] { return .init(call_id: call.call_id, status: .ok, data: ["event_id": .string(id), "deduped": .bool(true)]) }
        let id = "evt-\(writes.count + 1)"; writes[call.call_id] = id
        return .init(call_id: call.call_id, status: .ok, data: ["event_id": .string(id)])
    }
}
@MainActor final class FakeSubmitter: DeviceResultSubmitting {
    var sent: [DeviceCallResult] = []; var fail = false
    func submit(_ result: DeviceCallResult) async throws { if fail { throw URLError(.notConnectedToInternet) }; sent.append(result) }
}
@MainActor final class RefusingBackend: MemoryLibraryBackend {
    var capabilities: MemoryLibraryCapabilities { [] }; var created: [String] = []; var refuse: MemoryLibraryError? = nil
    var useMemory = true; var emptyID = false; var failAfter: Int? = nil
    func load() async throws -> MemoryLibrarySnapshot { if refuse == .notEnabled { throw MemoryLibraryError.notEnabled }; return .init(items: created.enumerated().map { .init(id: "cloud-\($0.offset)", group: .preference, content: $0.element) }, useMemory: useMemory, autoSave: nil) }
    func update(id: String, content: String) async throws {}
    func forget(ids: [String]) async throws {}
    func setUseMemory(_ on: Bool) async throws { useMemory = on }
    func setAutoSave(_ on: Bool) async throws {}
    func clearAll() async throws {}
    func undoSave(memoryID: String, undoToken: String?) async throws {}
    func create(kind: String, content: String) async throws -> String {
        if let refuse { throw refuse }
        if !useMemory { throw MemoryLibraryError.failed("409 memory_consent_required") }   // server requireActive
        if let n = failAfter, created.count >= n { throw MemoryLibraryError.unavailable }
        created.append(content); return emptyID ? "" : "cloud-\(created.count)" }
}

@main @MainActor enum NoBugP0Runner {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ m: String) { if ok { passed += 1; print("PASS \(m)") } else { failed += 1; print("FAIL \(m)") } }

    static func main() async {
        await memory(); await deviceCalls(); proactive(); nearby(); groundedFixtures(); contactsPrivacy(); replyVariants(); followUps(); await deviceUndo(); dictation(); codexP0_3()
        print("nobug-p0 portable: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func memory() async {
        // P0-2: default init carries no sample data.
        expect(MemoryLibraryStub().items.isEmpty, "P0-2 MemoryLibraryStub() default is empty (no 望京/燕麦拿铁)")
        let none = MemoryLibraryNotEnabled()
        do { _ = try await none.load(); expect(false, "P0-2 not-enabled backend throws") } catch { expect((error as? MemoryLibraryError) == .notEnabled, "P0-2 未开通 backend throws .notEnabled") }
        // P0-1: persistence across a simulated cold start.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nobug-mem-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = MemoryLibraryStub(fileURL: url)
        let id = try! await a.create(kind: "preference", content: "开会提前 25 分钟准备")
        _ = try! await a.create(kind: "profile", content: "住在杭州")
        try! await a.setUseMemory(true)
        let b = MemoryLibraryStub(fileURL: url)   // "relaunch"
        expect(b.items.count == 2 && b.items.contains { $0.id == id }, "P0-1 local memory survives cold start (file reload)")
        let snap = try! await b.load()
        expect(ProactiveRules.lead(in: [snap])?.minutes == 25, "P0-1 lead memory effective after cold start")
        try! await b.setUseMemory(false)
        expect(ProactiveRules.lead(in: [try! await MemoryLibraryStub(fileURL: url).load()]) == nil, "使用记忆 off persists and disables lead")
        try! await b.setUseMemory(true)
        try! await b.forget(ids: [id])
        expect(MemoryLibraryStub(fileURL: url).items.count == 1, "forget persists")
        // Gate opens: migrate local → cloud, then local empty.
        let cloud = RefusingBackend()
        let r1 = await MemoryLibraryLocal.migrate(MemoryLibraryStub(fileURL: url), to: cloud)
        expect(r1.migrated == 1 && r1.kept == 0 && cloud.created == ["住在杭州"], "P0-1 gate open → local items migrated to backend")
        expect(MemoryLibraryStub(fileURL: url).items.isEmpty, "P0-1 migrated items removed locally (no double)")
        // Gate still off: refuse → kept.
        let c = MemoryLibraryStub(fileURL: url); _ = try! await c.create(kind: "preference", content: "提前 5 分钟")
        let off = RefusingBackend(); off.refuse = .notEnabled
        let r2 = await MemoryLibraryLocal.migrate(c, to: off)
        expect(r2.migrated == 0 && r2.kept == 1 && r2.stoppedBy == .notEnabled, "P0-1 gate off → items kept locally")
        expect(MemoryLibraryLocal.shouldSurfaceLocal(r2), "gate off → local library surfaced in 设置›记忆")
        // Idempotency: crash after cloud create but before local forget → rerun must not duplicate.
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("nobug-mem2-\(UUID().uuidString).json"); defer { try? FileManager.default.removeItem(at: url2) }
        let d = MemoryLibraryStub(fileURL: url2); _ = try! await d.create(kind: "preference", content: "开会提前 20 分钟准备")
        let cloud2 = RefusingBackend(); cloud2.created = ["开会提前 20 分钟准备"]   // already created before the "crash"
        let r3 = await MemoryLibraryLocal.migrate(d, to: cloud2)
        expect(cloud2.created.count == 1 && r3.deduped == 1 && r3.kept == 0, "P1-3 migration idempotent: content dedupe, no duplicate after crash")
        // Empty id = failure, local kept.
        let e = MemoryLibraryStub(fileURL: url2); _ = try! await e.create(kind: "preference", content: "喜欢靠窗")
        let cloud3 = RefusingBackend(); cloud3.emptyID = true
        let r4 = await MemoryLibraryLocal.migrate(e, to: cloud3)
        expect(r4.migrated == 0 && r4.kept == 1, "P1-3 empty id from create is an error (local kept)")
        // useMemory=false carried over.
        try! await e.setUseMemory(false)
        let cloud4 = RefusingBackend(); _ = await MemoryLibraryLocal.migrate(e, to: cloud4)
        expect(cloud4.useMemory == false, "P1-3 local 使用记忆=off carried to cloud")
        // Order: creates must happen while use_memory is on, setUseMemory(false) last (old order → 409, nothing migrated).
        let g = MemoryLibraryStub(fileURL: url2); try! await g.clearAll(); try! await g.setUseMemory(false)
        _ = try! await g.create(kind: "preference", content: "开会提前 12 分钟准备"); _ = try! await g.create(kind: "profile", content: "住在苏州")
        let cloud6 = RefusingBackend()
        let r6 = await MemoryLibraryLocal.migrate(g, to: cloud6)
        expect(r6.migrated == 2 && r6.kept == 0 && cloud6.created.count == 2 && cloud6.useMemory == false && r6.stoppedBy == nil,
               "P1-3 use_memory off: all items created first, then setUseMemory(false) (no 409)")
        // Partial failure keeps cloud library (no local overwrite).
        let f = MemoryLibraryStub(fileURL: url2); try! await f.clearAll(); _ = try! await f.create(kind: "preference", content: "A"); _ = try! await f.create(kind: "preference", content: "B")
        let cloud5 = RefusingBackend(); cloud5.failAfter = 1
        let r5 = await MemoryLibraryLocal.migrate(f, to: cloud5)
        expect(r5.migrated == 1 && r5.kept == 1 && !MemoryLibraryLocal.shouldSurfaceLocal(r5), "P1-3 partial failure keeps cloud as page backend")
    }

    static func call(_ id: String, _ tool: String = "calendar_create") -> DeviceCall {
        .init(call_id: id, tool: tool, args: ["title": .string("评审会"), "start": .string("2026-10-20T10:00:00+08:00")], confirm: .card, ttl_sec: 600)
    }

    static func deviceCalls() async {
        let suite = "nobug.devicecall." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let exec = FakeExecutor(["calendar_create", "sms_compose"]), sub = FakeSubmitter()
        DeviceCallHub.executor = exec; DeviceCallHub.submitter = sub; DeviceCallHub.recorder = nil

        // Round trip.
        let s1 = DeviceCallStore(defaults: defaults)
        await s1.run(call("c1"))
        expect(sub.sent.map(\.call_id) == ["c1"] && sub.sent[0].status == .ok, "P0-5 device_call round trip: execute → report ok")
        if case .done = s1.phase("c1") { expect(true, "phase done after report") } else { expect(false, "phase done after report") }
        expect(DeviceCallStore(defaults: defaults).phase("c1") != .confirming, "P0-3 done phase persists (card never re-asks after relaunch)")
        await DeviceCallStore(defaults: defaults).run(call("c1"))
        expect(exec.executed == ["c1"], "P0-3 relaunched store does not re-execute a finished call")

        // Kill between execute and report: persisted as reportFailed(result) → re-report, no re-execute.
        sub.fail = true
        await s1.run(call("c2"))
        let s2 = DeviceCallStore(defaults: defaults)
        if case .reportFailed(let r) = s2.phase("c2") { expect(r.status == .ok, "P0-3 executed-but-unreported result persisted") } else { expect(false, "P0-3 executed-but-unreported result persisted") }
        sub.fail = false
        await s2.retryReport("c2")
        expect(sub.sent.last?.call_id == "c2" && exec.executed.filter { $0 == "c2" }.count == 1, "P0-3 report resumes after relaunch without re-execute")

        // P1-4 auto retry of every pending report after relaunch; offline → stays pending, never re-executes.
        sub.fail = true; await s1.run(call("c2b")); await s1.run(call("c2c"))
        let s2b = DeviceCallStore(defaults: defaults)
        expect(Set(s2b.pendingReportIDs).isSuperset(of: ["c2b", "c2c"]), "P1-4 pending reports survive relaunch")
        expect(await s2b.retryPendingReports() == 0 && s2b.pendingReportIDs.contains("c2b"), "P1-4 offline retry keeps them pending")
        sub.fail = false
        let acked = await s2b.retryPendingReports()
        expect(acked >= 2 && s2b.pendingReportIDs.isEmpty && exec.executed.filter { ["c2b", "c2c"].contains($0) }.count == 2, "P1-4 foreground/relaunch retry acknowledges all, no re-execute")
        DeviceCallHub.submitter = nil
        expect(await DeviceCallStore(defaults: defaults).retryPendingReports() == 0, "P1-4 no submitter → no-op")
        DeviceCallHub.submitter = sub

        // Kill during execute (phase .running persisted) → idempotent tool re-run, executor dedupes by call_id.
        exec.writes["c3"] = "evt-already"   // event was written before the kill
        let running = try! JSONEncoder().encode(["c3": DeviceCallStore.Record(phase: .running, call: call("c3"), updatedAt: .now)])
        defaults.set(running, forKey: DeviceCallStore.storageKey)
        let s3 = DeviceCallStore(defaults: defaults)
        expect(s3.isInterrupted("c3") && s3.phase("c3") == .running, "P0-3 interrupted call detected on relaunch (no confirm card)")
        await s3.run(call("c3"))
        expect(exec.executed.filter { $0 == "c3" }.isEmpty, "P0-3 tapping again cannot start a second write")
        await s3.resumeInterrupted("c3")
        expect(sub.sent.last?.data?["event_id"] == .string("evt-already") && exec.writes["c3"] == "evt-already", "P0-3 resume dedupes calendar_create by call_id")

        // Non-idempotent interrupted → outcome unknown, not re-run.
        defaults.set(try! JSONEncoder().encode(["c4": DeviceCallStore.Record(phase: .running, call: call("c4", "sms_compose"), updatedAt: .now)]), forKey: DeviceCallStore.storageKey)
        let s4 = DeviceCallStore(defaults: defaults); await s4.resumeInterrupted("c4")
        expect(sub.sent.last?.data?["reason"] == .string("interrupted_outcome_unknown") && !exec.executed.contains("c4"), "P0-3 interrupted compose → outcome_unknown, never re-sent")

        // P0-4 unsupported tool → error with non-retryable reason.
        await s4.run(call("c5", "pay_apple"))
        let last = sub.sent.last
        expect(last?.status == .error && last?.data?["reason"] == .string("unsupported_tool") && last?.data?["retryable"] == .bool(false), "P0-4 canExecute=false → .error reason unsupported_tool retryable=false")
        // P0-4 meituan.
        let m = DeviceToolContract.shopURLs(platform: "meituan", query: "咖啡")
        expect(m.app?.scheme == "imeituan" && m.web?.host == "i.meituan.com", "P0-4 shop_open meituan → imeituan:// + i.meituan.com fallback")
        expect(DeviceToolContract.shopURLs(platform: "taobao", query: "x").app?.scheme == "taobao", "shop_open taobao unchanged")
        expect(Set(DeviceToolContract.clientTools).count == 12 && DeviceToolContract.clientTools.contains("places_search") && DeviceToolContract.clientTools.contains("calendar_list") && DeviceToolContract.clientTools.contains("contacts_search"), "P0-4 client advertises 12 tools incl. calendar_list/contacts_search/places_search")
    }

    static func proactive() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        expect(ProactiveRules.inWindow(start: now.addingTimeInterval(60 * 60), now: now), "window: 60 min ahead admitted")
        expect(!ProactiveRules.inWindow(start: now.addingTimeInterval(181 * 60), now: now), "window: 181 min ahead dropped")
        expect(!ProactiveRules.inWindow(start: now.addingTimeInterval(-60), now: now), "window: past meeting dropped")
        let start = now.addingTimeInterval(120 * 60)
        expect(ProactiveRules.leaveAt(start: start, leadMinutes: 10, travelMinutes: 35, usedETA: true) == start.addingTimeInterval(-45 * 60), "leave_at = start − lead − travel")
        expect(ProactiveRules.leaveAt(start: start, leadMinutes: 10, travelMinutes: 35, usedETA: false) == start.addingTimeInterval(-10 * 60), "leave_at ignores travel when ETA unused")
        expect(ProactiveRules.validTravel(181) == nil && ProactiveRules.validTravel(40) == 40, "ETA > 180 min invalid")
        let h1 = ProactiveRules.signalHash(eventID: "E1", start: start), h2 = ProactiveRules.signalHash(eventID: "E1", start: start.addingTimeInterval(1800))
        expect(h1 != h2 && h1 == ProactiveRules.signalHash(eventID: "E1", start: start), "signal_hash stable per (event,start); reschedule = new hash")
        var ledger: [String: Double] = [:]
        expect(ProactiveRules.admit(h1, ledger: &ledger, now: now) && !ProactiveRules.admit(h1, ledger: &ledger, now: now), "dedupe: same signal admitted once")
        expect(ProactiveRules.leadMinutes(in: "开会提前 15 分钟准备") == 15 && ProactiveRules.leadMinutes(in: "20 minutes early") == 20, "lead memory parse zh/en")
        expect(ProactiveRules.leadMinutes(in: "提前 500 分钟") == nil && ProactiveRules.leadMinutes(in: "喜欢靠窗") == nil, "lead memory bounds")
        let on = MemoryLibrarySnapshot(items: [.init(id: "a", group: .preference, content: "提前 7 分钟")], useMemory: true, autoSave: nil)
        var off = on; off.useMemory = false
        expect(ProactiveRules.lead(in: [off, on])?.minutes == 7 && ProactiveRules.lead(in: [off]) == nil, "lead honours 使用记忆 per library")
    }

    static func nearby() {
        let items: [MemoryLibraryItem] = [.init(id: "t1", group: .preference, content: "喜欢吃辣，不吃香菜"), .init(id: "m1", group: .preference, content: "出门一般坐地铁"),
                                          .init(id: "x", group: .profile, content: "住在杭州")]
        let p = NearbyRules.preferences(in: [.init(items: items, useMemory: true, autoSave: nil)])
        expect(p.tastes.map(\.id) == ["t1"] && p.mode == .transit && p.modeItem?.id == "m1", "nearby: taste + travel-mode memories picked")
        expect(NearbyRules.preferences(in: [.init(items: items, useMemory: false, autoSave: nil)]) == .init(), "nearby: 使用记忆 off → no memories used")
        expect(NearbyRules.effectiveMode(arg: "driving", prefs: p) == .driving && NearbyRules.effectiveMode(arg: "", prefs: p) == .transit && NearbyRules.effectiveMode(arg: "", prefs: .init()) == .walking, "nearby: mode arg > memory > walking")
        let why = NearbyRules.why(prefs: p, mode: .transit, modeFromArg: false, originNote: "起点是你当前的真实位置")
        let cands: [NearbyRules.Candidate] = [.init(name: "香菜面馆", category: "Restaurant", distance: 100), .init(name: "粤式茶餐厅", category: "Restaurant", distance: 200), .init(name: "重庆麻辣烫", category: "Restaurant", distance: 600)]
        let kw = NearbyRules.tasteKeywords(p)
        expect(kw.likes == ["辣"] && kw.dislikes == ["香菜"], "nearby: taste keywords like 辣 / dislike 香菜")
        let withTaste = NearbyRules.rank(cands, prefs: p), without = NearbyRules.rank(cands, prefs: .init())
        expect(without == [0, 1, 2] && withTaste == [2, 1, 0] && withTaste != without, "nearby: taste memory changes ranking (with ≠ without)")
        expect(NearbyRules.needsWiderSearch(2) && !NearbyRules.needsWiderSearch(NearbyRules.minResults), "nearby: < minResults widens radius")
        let wide = NearbyRules.why(prefs: .init(), mode: .walking, modeFromArg: false, originNote: "o", radius: 8000)
        expect(wide.contains("3 公里内不足 3 家，已扩到 8 公里"), "nearby: widened search stated in Why")
        expect(!NearbyRules.why(prefs: .init(), mode: .walking, modeFromArg: false, originNote: "o", radius: 3000).contains("已扩到"), "nearby: no widen note at 3 km")
        expect(why.contains("调整了排序") && NearbyRules.why(prefs: .init(), mode: .walking, modeFromArg: false, originNote: "o").contains("口味") == false, "nearby: Why mentions taste only when it changed ranking")
        expect(why.contains("喜欢吃辣") && why.contains("出门一般坐地铁") && why.contains("真实位置"), "nearby: Why cites memories + origin")
        expect(NearbyRules.telURL("021-6123 4567") == "tel:02161234567" && NearbyRules.telURL(nil) == nil, "nearby: tel url")
        expect(NearbyRules.mapsURL(lat: 31.2, lng: 121.4, name: "店", mode: .walking).hasSuffix("dirflg=w"), "nearby: maps url mode")
    }

    /// Mirror of services/edge/test/ui-grounded.test.mjs: every server-grounded block in the shared fixture decodes
    /// into GenerativeBlock as `.ready` with the same rows; errors/passthrough cases stay out of the client.
    static func groundedFixtures() {
        let url = URL(fileURLWithPath: "../../services/edge/docs/fixtures/catpaw-ui-grounded.json")
        guard let data = try? Data(contentsOf: url), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cases = root["cases"] as? [[String: Any]], let auto = root["auto"] as? [[String: Any]] else { expect(false, "grounded: fixture readable"); return }
        var decoded = 0
        for c in cases + auto {
            let name = c["name"] as? String ?? "?"
            guard let exp = c["expect"] as? [String: Any], let raw = exp["block"] as? [String: Any] else { continue }
            let bytes = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
            guard case .ready(let b) = GenerativeBlockCodec.decode(bytes) else { expect(false, "grounded: \(name) decodes .ready"); continue }
            let rows = (raw["places"] as? [[String: Any]]) ?? (raw["events"] as? [[String: Any]]) ?? []
            let ids = b.kind == .place ? (b.places ?? []).map(\.id) : (b.events ?? []).map(\.id)
            let names = b.kind == .place ? (b.places ?? []).map(\.name) : (b.events ?? []).map(\.title)
            expect(b.kind.isGrounded && !b.needsAnswer && ids == rows.compactMap { $0["id"] as? String }
                   && names == rows.compactMap { ($0["name"] ?? $0["title"]) as? String } && b.source?.callId == (raw["source"] as? [String: Any])?["callId"] as? String,
                   "grounded: \(name) mirrors server rows")
            decoded += 1
        }
        expect(decoded == 6, "grounded: 6 server blocks decoded (5 render_ui + 1 auto), got \(decoded)")
        let fake = #"{"id":"x","kind":"place","source":{"callId":"c"},"places":[{"id":"p1","name":"n","actions":[{"id":"go","label":"去","url":"javascript:alert(1)"}]}]}"#
        if case .fallback(let card, let err) = GenerativeBlockCodec.decode(Data(fake.utf8)) { expect(card.kind == .card && err.code == "schema_invalid", "grounded: unsafe deep link degrades to card") } else { expect(false, "grounded: unsafe deep link degrades to card") }
        if case .fallback = GenerativeBlockCodec.decode(Data(#"{"id":"x","kind":"place"}"#.utf8)) { expect(true, "grounded: place without server rows is not rendered") } else { expect(false, "grounded: place without server rows is not rendered") }
        expect(NearbyRules.placeBlockID(callID: "call-ab:12") == "places-call-ab12", "grounded: auto place block id mirrors server")
        expect(ConversationUIEvent.kinds.contains("place") && ConversationUIEvent.kindsHeaderValue.contains("event"), "grounded: client advertises place/event")
    }

    /// chat-ux #7: contacts never leave the phone without a tap; result is minimal.
    static func contactsPrivacy() {
        expect(!DeviceToolContract.runsWithoutTap(tool: "contacts_search", confirm: DeviceCall.Confirm.none), "contacts: no auto-run even if an old server sends confirm:none")
        expect(!DeviceToolContract.runsWithoutTap(tool: "contacts_search", confirm: DeviceCall.Confirm.card), "contacts: card → waits for tap")
        expect(DeviceToolContract.runsWithoutTap(tool: "calendar_list", confirm: DeviceCall.Confirm.none) && DeviceToolContract.runsWithoutTap(tool: "places_search", confirm: DeviceCall.Confirm.none), "contacts: other read-only tools still auto-run")
        let row = DeviceToolContract.minimalContact(name: "张三", phones: ["1", "2", "3", "4"], emails: ["a@x.cn"], includeEmail: false)
        expect(row["emails"] == nil && row["phones"] == .list(["1", "2", "3"]) && Set(row.keys) == ["name", "phones"], "contacts: minimal fields (name + ≤3 phones, no email by default)")
        expect(DeviceToolContract.minimalContact(name: "张三", phones: [], emails: ["a", "b", "c"], includeEmail: true)["emails"] == .list(["a", "b"]), "contacts: emails only when asked, ≤2")
    }

    /// chat-ux #1: edit & resend keeps the old answer as a switchable version (ReplyVariantGroup behind ReplyVariantStore).
    static func replyVariants() {
        let root = UUID(), regen = UUID(), edited = UUID(), regenEdited = UUID()
        var g = ReplyVariantGroup(root: root)
        g.addRegenerate(regen)
        expect(g.selectedTurn == regen && g.visiblePromptTurn == root && g.isVisible(turn: root, isUserPrompt: true) && !g.isVisible(turn: regen, isUserPrompt: true), "variants: regenerate keeps the original prompt row")
        g.addEdit(edited)
        expect(g.turns.count == 3 && g.selected == 2 && g.visiblePromptTurn == edited, "variants: edit → new answer selected, edited prompt shown")
        expect(g.isVisible(turn: edited, isUserPrompt: true) && !g.isVisible(turn: root, isUserPrompt: true) && g.isVisible(turn: edited, isUserPrompt: false) && !g.isVisible(turn: regen, isUserPrompt: false), "variants: old prompt + old answers hidden while on the edit")
        g.step(-2)
        expect(g.selectedTurn == root && g.visiblePromptTurn == root && g.isVisible(turn: root, isUserPrompt: false) && !g.isVisible(turn: edited, isUserPrompt: true), "variants: switch back → original prompt + original answer")
        g.step(2); g.addRegenerate(regenEdited)
        expect(g.promptTurn(of: regenEdited) == edited && g.visiblePromptTurn == edited && g.promptTurns == [root, edited], "variants: regenerate on an edited version re-answers the edited prompt")
        g.addEdit(edited); expect(g.turns.count == 4, "variants: duplicate add ignored")
        let legacy = Data(#"{"turns":["\#(root.uuidString)"],"selected":0}"#.utf8)
        expect((try? JSONDecoder().decode(ReplyVariantGroup.self, from: legacy))?.visiblePromptTurn == root, "variants: v1 persisted groups still decode")
        let round = try? JSONDecoder().decode(ReplyVariantGroup.self, from: (try? JSONEncoder().encode(g)) ?? Data())
        expect(round == g, "variants: edited groups persist")
        expect(!MessageEditRules.canSend("  猫吃什么 ", original: "猫吃什么") && !MessageEditRules.canSend("   ", original: "x") && MessageEditRules.canSend("狗吃什么", original: "猫吃什么"), "edit: unchanged / empty edits cannot be sent")
    }

    /// chat-ux #4: follow-up fence parsing.
    @MainActor final class FlakyUndoSubmitter: DeviceResultSubmitting {
        var online = false; var sent: [String] = []
        func submit(_ result: DeviceCallResult) async throws {}
        func reportUndo(callID: String, outcome: DeviceUndoOutcome) async throws { guard online else { throw URLError(.notConnectedToInternet) }; sent.append(callID + ":" + outcome.rawValue) }
    }
    @MainActor static func deviceUndoQueue() async {
        let defaults = UserDefaults(suiteName: "nobug-undo-\(UUID())")!
        let saved = DeviceCallHub.submitter; defer { DeviceCallHub.submitter = saved }
        let flaky = FlakyUndoSubmitter(); DeviceCallHub.submitter = flaky
        await DeviceCallStore(defaults: defaults).reportUndo(callID: "u1", outcome: .undone)
        expect(flaky.sent.isEmpty, "#6 offline undo report not sent yet")
        let relaunched = DeviceCallStore(defaults: defaults)            // app restart: queue comes back from disk
        expect(relaunched.undoQueue.pending == ["u1": .undone], "#6 pending undo survives an app restart")
        flaky.online = true
        _ = await relaunched.retryPendingReports()
        expect(flaky.sent == ["u1:undone"] && relaunched.undoQueue.isEmpty, "#6 retryPendingReports delivers the queued undo to the model")
        expect(DeviceCallStore(defaults: defaults).undoQueue.isEmpty, "#6 acknowledged undo is not re-sent after another restart")
        var q = DeviceUndoQueue(); q.enqueue("a", .failed); q.enqueue("b", .undone)
        let left = await q.drained { id, _ in if id == "a" { throw URLError(.timedOut) } }
        expect(left.pending == ["a": .failed], "#6 drain keeps only failed reports")
        var idx = DeviceCallTurnIndex(); let c = UUID(), t = UUID(); idx.set("k", conversationID: c, turnID: t)
        idx.save(defaults); expect(DeviceCallTurnIndex.load(defaults).turn(for: "k").map { $0 == (c, t) } == true, "#6 call→turn index persists for post-restart undo")
        for i in 0..<(DeviceCallTurnIndex.capacity + 5) { idx.set("x\(i)", conversationID: c, turnID: t, at: Date(timeIntervalSince1970: Double(i))) }
        expect(idx.entries.count == DeviceCallTurnIndex.capacity, "#6 index is capped")
    }
    static func deviceUndo() async {
        await deviceUndoQueue()
        expect(DeviceUndoRules.canUndo(tool: "calendar_create", status: "ok", alreadyUndone: false), "#6 ok calendar_create can be undone")
        expect(DeviceUndoRules.canUndo(tool: "alarm_set", status: "ok", alreadyUndone: false) && DeviceUndoRules.canUndo(tool: "reminder_create", status: "ok", alreadyUndone: false), "#6 reminder/alarm undoable")
        expect(!DeviceUndoRules.canUndo(tool: "calendar_create", status: "denied", alreadyUndone: false), "#6 failed write has nothing to undo")
        expect(!DeviceUndoRules.canUndo(tool: "calendar_create", status: "ok", alreadyUndone: true), "#6 undo only once")
        expect(!DeviceUndoRules.canUndo(tool: "contacts_search", status: "ok", alreadyUndone: false), "#6 reads are not undoable")
        expect(DeviceUndoRules.outcome(found: true, deleted: true) == .undone && DeviceUndoRules.outcome(found: false, deleted: true) == .alreadyGone && DeviceUndoRules.outcome(found: true, deleted: false) == .failed, "#6 outcome mapping")
        expect(DeviceUndoOutcome.alreadyGone.removed && !DeviceUndoOutcome.failed.removed, "#6 already gone counts as removed (same as proactive undo)")
        let op = UUID()
        expect(DeviceUndoRules.body(callID: "c1", outcome: .alreadyGone, operationID: op) == ["call_id": "c1", "operation_id": op.uuidString.lowercased(), "status": "already_gone"], "#6 wire body matches server statuses")
        expect(Set(DeviceUndoOutcome.allCases.map(\.rawValue)) == ["undone", "already_gone", "failed"], "#6 statuses mirror DEVICE_UNDO_STATUSES")
    }
    static func dictation() {
        expect(DictationPolicy.join("帮我订", "明天的会议室") == "帮我订明天的会议室", "dictation: no space joining Chinese")
        expect(DictationPolicy.join("好的。", "明天见") == "好的。明天见", "dictation: no space after CJK punctuation")
        expect(DictationPolicy.join("Book", "a room") == "Book a room", "dictation: Latin words get one space")
        expect(DictationPolicy.join("call", "，谢谢") == "call，谢谢" && DictationPolicy.join("hi\n", "there") == "hi\nthere" && DictationPolicy.join("", "你好") == "你好", "dictation: punctuation/newline/empty joins")
        expect(DictationPolicy.join("用 Swift", "写") == "用 Swift写", "dictation: Latin then CJK has no inserted space")
        var t = DictationTranscript(); t.update("明天上午"); t.commit(); t.update("九点开会")
        expect(t.text == "明天上午九点开会", "dictation: text from a finished segment is kept when the next one starts")
        t.commit(); t.update(""); expect(t.text == "明天上午九点开会", "dictation: empty new segment keeps the text so far")
        expect(DictationRestart.decide(failed: false, segmentHadText: true, emptyFailures: 0, sessionHasText: true) == .restart, "dictation: pause (final) restarts a segment")
        expect(DictationRestart.decide(failed: true, segmentHadText: false, emptyFailures: 0, sessionHasText: false) == .restart, "dictation: one error restarts")
        expect(DictationRestart.decide(failed: true, segmentHadText: false, emptyFailures: 2, sessionHasText: true) == .finish, "dictation: repeated empty errors finish with the text so far")
        expect(DictationRestart.decide(failed: true, segmentHadText: false, emptyFailures: 2, sessionHasText: false) == .fail, "dictation: repeated empty errors with nothing said fail")
        expect(DictationRestart.decide(failed: true, segmentHadText: true, emptyFailures: 2, sessionHasText: true) == .restart, "dictation: an error after text restarts")
        expect(DictationEngineTier.choose(analyzerOS: true, speechTranscriberReady: true, dictationTranscriberReady: true, recognizerAvailable: true, recognizerOnDevice: true) == .speechTranscriber, "dictation: iOS 26 prefers SpeechTranscriber")
        expect(DictationEngineTier.choose(analyzerOS: true, speechTranscriberReady: false, dictationTranscriberReady: true, recognizerAvailable: true, recognizerOnDevice: false) == .dictationTranscriber, "dictation: then DictationTranscriber")
        expect(DictationEngineTier.choose(analyzerOS: false, speechTranscriberReady: false, dictationTranscriberReady: false, recognizerAvailable: true, recognizerOnDevice: false) == .serverRecognizer, "dictation: no on-device support uses server recognition instead of refusing")
        expect(DictationEngineTier.choose(analyzerOS: false, speechTranscriberReady: false, dictationTranscriberReady: false, recognizerAvailable: true, recognizerOnDevice: true) == .onDeviceRecognizer, "dictation: on-device recognizer when supported")
        expect(DictationEngineTier.choose(analyzerOS: false, speechTranscriberReady: false, dictationTranscriberReady: false, recognizerAvailable: false, recognizerOnDevice: false) == .unavailable, "dictation: unavailable only when no recognizer")
        expect(DictationEngineTier.serverRecognizer.segmentLimit == 55 && DictationEngineTier.speechTranscriber.segmentLimit == nil, "dictation: auto-continue before the ~1 min request limit; analyzer has none")
        expect(DictationPolicy.localeIdentifier(for: .english) == "en-US" && DictationPolicy.localeIdentifier(for: .chinese) == "zh-CN", "dictation: locale follows app language")
    }
    static func followUps() {
        let d = { (t: String) in Data(t.utf8) }
        expect(FollowUpSuggestions.parse(d("猫能吃鱼吗？\n- 猫一天吃几顿\n2. 猫粮怎么选\n第四个"), closed: true) == ["猫能吃鱼吗？", "猫一天吃几顿", "猫粮怎么选"], "followups: ≤3, bullets/numbers stripped")
        expect(FollowUpSuggestions.parse(d("a\nb"), closed: false).isEmpty, "followups: unclosed fence renders nothing while streaming")
        expect(FollowUpSuggestions.parse(d("只有一个"), closed: true).isEmpty && FollowUpSuggestions.parse(d("x\nx"), closed: true).isEmpty, "followups: fewer than 2 distinct → nothing")
        expect(FollowUpSuggestions.parse(d(String(repeating: "长", count: 31) + "\n短一\n短二"), closed: true) == ["短一", "短二"], "followups: over-long lines dropped")
        expect(ConversationUIEvent.kindsHeaderValue.hasSuffix(",followups") && !ConversationUIEvent.kinds.contains("followups"), "followups: advertised as capability, not a ui.block kind")
    }
    /// Codex review P0-3: the client keeps all four levels and applies its own quiet hours + daily cap.
    static func codexP0_3() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        let night = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23, minute: 30))!
        let p = { (l: ProactiveLevel, at: Date, n: Int) in ProactiveRules.delivery(level: l, now: at, deliveredToday: n, calendar: cal) }
        expect(p(.silent, noon, 0) == .init(level: .silent, inAppCard: false, systemNotification: false, sound: false, timeSensitive: false, liveActivity: false), "codex P0-3 silent → nothing")
        let card = p(.card, noon, 0)
        expect(card.inAppCard && !card.systemNotification && !card.sound && !card.liveActivity, "codex P0-3 card → in-app card only, no sound notification")
        let notify = p(.notify, noon, 0)
        expect(notify.systemNotification && notify.sound && !notify.timeSensitive, "codex P0-3 notify → notification with sound")
        let interrupt = p(.interrupt, noon, 0)
        expect(interrupt.systemNotification && interrupt.timeSensitive && interrupt.liveActivity, "codex P0-3 interrupt → time-sensitive + Live Activity")
        expect(p(.notify, night, 0).level == .card && !p(.interrupt, night, 0).sound, "codex P0-3 on-device quiet hours (22–8) → card, no sound")
        expect(p(.notify, noon, ProactiveRules.dailyNotifyCap).level == .card, "codex P0-3 on-device daily cap → card")
        expect(ProactiveLevel(server: "notify") == .notify && ProactiveLevel(server: "bogus") == .card && ProactiveLevel(server: "silent") == .silent, "codex P0-3 server level parsed, unknown → card (never louder)")
    }

}
