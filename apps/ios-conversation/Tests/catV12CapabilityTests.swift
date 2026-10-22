import XCTest
@testable import cat

/// v1.2: capability deep links (catpawm://…), header identity, 主动 suppression copy and 记忆 last-used store.
final class catV12CapabilityTests: XCTestCase {
    func testAppRouteParsesNewHosts() {
        XCTAssertEqual(catAppRoute(url: URL(string: "catpawm://results")!), .results)
        XCTAssertEqual(catAppRoute(url: URL(string: "catpawm://settings")!), .settings)
        XCTAssertEqual(catAppRoute(url: URL(string: "catpawm://memory")!), .memory)
        XCTAssertNil(catAppRoute(url: URL(string: "catpawm://debugger")!))
    }
    func testAllowlistRejectsPathsQueriesAndOtherSchemes() {
        for ok in ["catpawm://memory", "catpawm://tasks", "catpawm://proactive", "catpawm://results", "catpawm://settings"] {
            XCTAssertTrue(catCapabilityLinks.isAllowed(URL(string: ok)!), ok)
        }
        for bad in ["catpawm://proactive/debug", "catpawm://conversation/7C1F0B0E-1111-4C3B-9A51-1F5E4D2C3B4A", "catpawm://new",
                    "catpawm://memory?x=1", "catpawm://u:p@memory", "https://memory", "catpawm://memory#a"] {
            XCTAssertFalse(catCapabilityLinks.isAllowed(URL(string: bad)!), bad)
        }
    }
    func testExtractKeepsOrderDedupesAndCaps() {
        let text = "记忆在这里：[打开记忆](catpawm://memory)，再看 [调试](catpawm://proactive/debug) 和 [查看成果](catpawm://results)、[又一个记忆](catpawm://memory)、[打开设置](catpawm://settings) [网页](https://x.example)"
        let links = catCapabilityLinks.extract(from: text)
        XCTAssertEqual(links.map(\.label), ["打开记忆", "查看成果"])
        XCTAssertEqual(links.map(\.route), [.memory, .results])
        XCTAssertEqual(catCapabilityLinks.extract(from: text, limit: 5).map(\.route), [.memory, .results, .settings])
        XCTAssertTrue(catCapabilityLinks.extract(from: "没有链接的普通回答").isEmpty)
        XCTAssertTrue(catCapabilityLinks.extract(from: "[](catpawm://memory)").isEmpty)
    }
    func testManifestLinksAreAllAllowed() throws {
        // The bundled-in-repo manifest is the server's source too; every link it offers must route in the app.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../docs/product/capabilities/catpaw-capabilities.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("manifest not reachable from the test host") }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let caps = try XCTUnwrap(root["capabilities"] as? [[String: Any]])
        let links = caps.compactMap { ($0["ui_entry"] as? [String: Any])?["link"] as? String }
        XCTAssertEqual(links.count, 5)
        for l in links { XCTAssertTrue(catCapabilityLinks.isAllowed(URL(string: l)!), l); XCTAssertNotNil(catAppRoute(url: URL(string: l)!), l) }
    }
    @MainActor func testHeaderShowsAssistantNameWithinV111Cap() {
        XCTAssertEqual(ConversationFirstView.headerTitle, "cat")
        let font = UIFont.systemFont(ofSize: 17)
        let width = ConversationFirstView.titleTextWidth(ConversationFirstView.headerTitle, barWidth: 393, font: font)
        let cap = ConversationFirstView.principalTitleMaxWidth(barWidth: 393)!
        XCTAssertNotNil(width); XCTAssertLessThanOrEqual(width!, cap - 120)
        XCTAssertEqual(ConversationFirstView.idleStatus(online: true, offlineLabel: "离线", ui: { $0 }), "在线 · 随时帮你")
        XCTAssertEqual(ConversationFirstView.idleStatus(online: false, offlineLabel: "离线", ui: { $0 }), "离线")
        XCTAssertEqual(ConversationFirstView.idleStatus(online: false, offlineLabel: nil, ui: { $0 }), "未连接")
    }
    func testProactiveSuppressionNotice() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let at = { (h: Int) in cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: h))! }
        XCTAssertNotNil(ProactiveRules.suppressionNotice(now: at(23), deliveredToday: 0, calendar: cal)?.range(of: "免打扰"))
        XCTAssertNotNil(ProactiveRules.suppressionNotice(now: at(12), deliveredToday: ProactiveRules.dailyNotifyCap, calendar: cal)?.range(of: "上限"))
        XCTAssertNil(ProactiveRules.suppressionNotice(now: at(12), deliveredToday: 1, calendar: cal))
        XCTAssertNotEqual(ProactiveRules.emptyHint("pending"), ProactiveRules.emptyHint("done"))
    }
    func testMemoryLastUsedRecordsAndBounds() {
        let d = UserDefaults(suiteName: "v12.lastUsed.\(UUID().uuidString)")!
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        MemoryLastUsed.record(ids: ["a", "b"], at: t, d)
        XCTAssertEqual(MemoryLastUsed.date("a", d), t)
        XCTAssertNil(MemoryLastUsed.date("zz", d))
        MemoryLastUsed.record(ids: (0..<(MemoryLastUsed.limit + 10)).map { "m\($0)" }, at: t.addingTimeInterval(60), d)
        XCTAssertLessThanOrEqual(MemoryLastUsed.all(d).count, MemoryLastUsed.limit)
        XCTAssertNil(MemoryLastUsed.date("a", d), "oldest entries are evicted first")
    }
}
