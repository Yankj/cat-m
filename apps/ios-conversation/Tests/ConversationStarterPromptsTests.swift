import XCTest
import UIKit
import SwiftUI
@testable import cat

/// feat/chat-starter-prompts: catalog, time-of-day order and bilingual copy of the empty-conversation starters.
final class ConversationStarterPromptsTests: XCTestCase {
    func testCatalogIsSixUniqueCompletePrompts() {
        let all = ConversationStarterPrompts.all
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.prompt)).count, all.count)
        for p in all {
            XCTAssertFalse(p.symbol.isEmpty, p.id)
            // Placeholders must be filled in: a tap sends a sensible, complete request.
            for hole in ["xx", "XX", "…", "...", "{"] { XCTAssertFalse(p.prompt.contains(hole), "\(p.id) has placeholder \(hole)") }
            XCTAssertLessThanOrEqual(p.prompt.count, 24, "\(p.id) must fit two caption lines on iPhone 13")
        }
    }

    func testTimeOfDayOrderIsAPermutationWithTheRightLead() {
        let ids = Set(ConversationStarterPrompts.all.map(\.id))
        for hour in 0..<24 { XCTAssertEqual(Set(ConversationStarterPrompts.ordered(hour: hour).map(\.id)), ids, "hour \(hour)") }
        XCTAssertEqual(ConversationStarterPrompts.ordered(hour: 8).first?.id, "schedule")    // morning: today's schedule first
        XCTAssertEqual(ConversationStarterPrompts.ordered(hour: 14).first?.id, "meeting")    // afternoon: meeting / leave-time chain
        XCTAssertEqual(ConversationStarterPrompts.ordered(hour: 21).first?.id, "reminder")   // evening: tomorrow's reminder
        XCTAssertEqual(ConversationStarterPrompts.dayPart(hour: 4), .evening)
        XCTAssertEqual(ConversationStarterPrompts.dayPart(hour: 5), .morning)
        XCTAssertEqual(ConversationStarterPrompts.dayPart(hour: 11), .afternoon)
        XCTAssertEqual(ConversationStarterPrompts.dayPart(hour: 17), .evening)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9))!
        XCTAssertEqual(ConversationStarterPrompts.ordered(at: morning, calendar: calendar).first?.id, "schedule")
    }

    func testEveryStarterIsLocalizedInBothLanguages() {
        for p in ConversationStarterPrompts.all {
            for key in [p.title, p.prompt] {
                XCTAssertEqual(AppLanguage.chinese.ui(key), key)
                let en = AppLanguage.english.ui(key)
                XCTAssertNotEqual(en, key, "missing en for \(key)")
                XCTAssertNil(en.range(of: #"[\u3400-\u9fff]"#, options: .regularExpression), "en copy still Chinese: \(en)")
            }
        }
        for key in ["试试这些", "轻点立即发送"] { XCTAssertNotEqual(AppLanguage.english.ui(key), key) }
    }
}

/// fix/chat-acceptance-3 #3: every device tool the app advertises (X-cat-Device-Tools) must be accepted as a
/// `tool_call` name, otherwise ConversationSessionService.apply throws invalidEvent (「服务返回了不匹配的对话或工具结果」).
/// Prod turn 75aba37d (附近咖啡馆 starter → places_search) stalled at sequence 2 for exactly this reason.
final class DeviceToolNamesContractTests: XCTestCase {
    func testEveryAdvertisedDeviceToolIsAnAcceptedToolCallName() {
        for tool in DeviceToolContract.clientTools {
            XCTAssertTrue(NativeChatHTTPBackend.approvalToolNames.contains(tool), "\(tool) advertised but rejected as tool_call")
        }
        XCTAssertTrue(NativeChatHTTPBackend.approvalToolNames.contains("places_search"))
    }

    /// NoBug §4.6: every server-registered agent-memory tool (MEMORY_TOOLS) must be an accepted tool_call name, and the iOS
    /// approval classification must match the server's TOOL_APPROVAL declaration. Reads the server source in this checkout.
    @MainActor func testServerMemoryToolsAreAcceptedAndClassifiedLikeTheServer() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../services/edge/supabase/functions/_shared").standardizedFileURL
        let contract = try String(contentsOf: shared.appendingPathComponent("agent-memory/contract.mjs"), encoding: .utf8)
        let registry = try String(contentsOf: shared.appendingPathComponent("core/src/tools.mjs"), encoding: .utf8)
        func matches(_ pattern: String, _ text: String) -> [[String]] {
            let re = try! NSRegularExpression(pattern: pattern)
            return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
                (1..<m.numberOfRanges).map { String(text[Range(m.range(at: $0), in: text)!]) }
            }
        }
        let serverTools = Set(matches(#"fn\('(memory_[a-z_]+)'"#, contract).map { $0[0] })
        XCTAssertEqual(serverTools, ["memory_search", "memory_save", "memory_update", "memory_forget"], "MEMORY_TOOLS changed; update iOS")
        let declared = Dictionary(uniqueKeysWithValues: matches(#"(memory_[a-z_]+):\{approval:'([a-z_]+)'"#, registry).map { ($0[0], $0[1] != "never") })
        for tool in serverTools {
            XCTAssertTrue(NativeChatHTTPBackend.approvalToolNames.contains(tool), "\(tool) is offered by the server but rejected as tool_call")
            XCTAssertEqual(NativeChatHTTPBackend.memoryToolApproval[tool], declared[tool], "\(tool) approval classification differs from TOOL_APPROVAL")
        }
        XCTAssertEqual(ConversationApprovalCardView.toolTitle("memory_forget") { key, _ in key }, "忘记记忆")
    }
}

/// fix/chat-acceptance-3 #2: consent is asked once per account + route_hash, not once per conversation.
final class AccountModelConsentMemoryTests: XCTestCase {
    private func defaults() -> UserDefaults { let name = "consent-test-\(UUID())"; let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d }
    func testSameAccountSameRouteIsCarried() {
        let d = defaults(), subject = UUID(), scope = UUID()
        let memory = AccountModelConsentMemory(subjectID: subject, serverScopeID: scope, defaults: d)
        XCTAssertFalse(memory.allows("e0a91d27"))
        memory.remember("e0a91d27")
        XCTAssertTrue(AccountModelConsentMemory(subjectID: subject, serverScopeID: scope, defaults: d).allows("e0a91d27"))
    }
    func testChangedRouteHashAsksAgain() {
        let d = defaults(), memory = AccountModelConsentMemory(subjectID: UUID(), serverScopeID: UUID(), defaults: d)
        memory.remember("0065e54a"); XCTAssertFalse(memory.allows("e0a91d27"))
    }
    func testOtherAccountOrNoSubjectNeverInherits() {
        let d = defaults(), scope = UUID()
        AccountModelConsentMemory(subjectID: UUID(), serverScopeID: scope, defaults: d).remember("e0a91d27")
        XCTAssertFalse(AccountModelConsentMemory(subjectID: UUID(), serverScopeID: scope, defaults: d).allows("e0a91d27"))
        let anonymous = AccountModelConsentMemory(subjectID: nil, serverScopeID: scope, defaults: d)
        anonymous.remember("e0a91d27"); XCTAssertFalse(anonymous.allows("e0a91d27"))
    }
}

/// v1 letterbox blocker (2026-10-17): the BUILT app must carry a valid launch screen — the Info.plist key, a compiled
/// storyboardc that instantiates, and every asset it draws — or iOS can run it in compatibility mode / draw a blank
/// first frame. Hosted test: Bundle.main is the built cat.app.
final class LaunchScreenBundleTests: XCTestCase {
    func testBuiltAppDeclaresAndShipsItsLaunchScreen() throws {
        let name = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, "built Info.plist has no UILaunchStoryboardName")
        XCTAssertEqual(name, "LaunchScreen")
        let compiled = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "storyboardc"), "\(name).storyboardc missing from the built app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiled.appendingPathComponent("Info.plist").path))
        let root = try XCTUnwrap(UIStoryboard(name: name, bundle: .main).instantiateInitialViewController(), "launch storyboard has no initial view controller")
        root.loadViewIfNeeded()
        XCTAssertNotNil(root.view.backgroundColor, "launch screen background colour asset did not resolve")
        func images(_ v: UIView) -> [UIImageView] { ((v as? UIImageView).map { [$0] } ?? []) + v.subviews.flatMap(images) }
        for view in images(root.view) { XCTAssertNotNil(view.image, "launch screen image asset did not resolve") }
    }
}

/// User report 15:14 ("launch logo STRETCHED"): both launch stages must draw the tile square at 96 pt.
@MainActor final class LaunchLogoAspectTests: XCTestCase {
    func testSwiftUILaunchMarkTileIsSquare() throws {
        let renderer = ImageRenderer(content: catLaunchMark(isReady: false).frame(width: 390, height: 844).environment(\.colorScheme, .light))
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage)
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w { let i = (y * w + x) * 4
            if px[i] > 200, px[i+1] > 60, px[i+1] < 190, px[i+2] < 90 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } } }
        XCTAssertGreaterThan(maxX, minX, "no orange tile drawn")
        let tw = maxX - minX + 1, th = maxY - minY + 1
        XCTAssertLessThanOrEqual(abs(tw - th), 2, "launch tile is \(tw)×\(th) pt — stretched")
        XCTAssertEqual(Double(tw), Double(catLaunchMark.side), accuracy: 2)
        XCTAssertEqual(Double(minX + tw / 2), 195, accuracy: 1.5, "tile centred horizontally on the full screen")
        XCTAssertEqual(Double(minY + th / 2), 422, accuracy: 1.5, "tile centred vertically on the full screen")
    }
    /// launch-v2 (方块): 70×56 LaunchGlyph + slogan in a 100 pt group whose centre sits at 1.22 × the view's centre.
    func testStoryboardGlyphAndSloganLayoutOnIPhone13() throws {
        let vc = try XCTUnwrap(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); vc.view.layoutIfNeeded()
        func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
        let iv = try XCTUnwrap(all(vc.view).compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(iv.contentMode, .scaleAspectFit)
        let glyph = iv.convert(iv.bounds, to: vc.view)
        XCTAssertEqual(glyph.width, 70, accuracy: 0.01); XCTAssertEqual(glyph.height, 56, accuracy: 0.01)
        XCTAssertEqual(glyph.midX, 195, accuracy: 0.01, "horizontally centred")
        XCTAssertEqual(glyph.minY, 422 * 1.22 - 50, accuracy: 0.5, "group centreY = 1.22 × view centreY, glyph at group top")
        let image = try XCTUnwrap(iv.image)
        XCTAssertEqual(image.size.width / image.size.height, 70.0 / 56.0, accuracy: 0.01)
        let slogan = try XCTUnwrap(all(vc.view).compactMap { $0 as? UILabel }.first)
        let sf = slogan.convert(slogan.bounds, to: vc.view)
        XCTAssertEqual(sf.minY, glyph.maxY + 20, accuracy: 0.5); XCTAssertEqual(sf.midX, 195, accuracy: 0.5)
        XCTAssertFalse((slogan.text ?? "").isEmpty)
    }
}

/// chat-ux-1505 #1: header picker offers only server-allowed models; offline routes disabled; checkmark logic.
final class ModelPickerOptionsTests: XCTestCase {
    private func route(_ id: String, _ models: [String], status: String = "online") throws -> ModelRouteInfo {
        let json = #"{"id":"\#(id)","display_name":"\#(id.uppercased())","status":"\#(status)","models":[\#(models.enumerated().map { #"{"id":"\#($1)","default":\#($0 == 0)}"# }.joined(separator: ","))]}"#
        return try JSONDecoder().decode(ModelRouteInfo.self, from: Data(json.utf8))
    }
    func testOptionsAreAutoPlusAllowListOnly() throws {
        let routes = [try route("gemini", ["google/gemini-3.5-flash-lite", "google/gemini-3.5-flash"]), try route("openrouter", ["x/free-a"], status: "offline")]
        let o = ModelPickerOptions.build(routes)
        XCTAssertEqual(o.map(\.id), ["auto|", "gemini|google/gemini-3.5-flash-lite", "gemini|google/gemini-3.5-flash", "openrouter|x/free-a"])
        XCTAssertEqual(o[1].label, "gemini-3.5-flash-lite")
        XCTAssertFalse(o[3].enabled)
    }
    func testSelectionAndHeaderLabel() throws {
        let routes = [try route("gemini", ["google/gemini-3.5-flash-lite", "google/gemini-3.5-flash"])]
        let o = ModelPickerOptions.build(routes)
        XCTAssertTrue(ModelPickerOptions.isSelected(o[1], route: "gemini", model: nil, routes: routes))   // route default
        XCTAssertTrue(ModelPickerOptions.isSelected(o[2], route: "gemini", model: "google/gemini-3.5-flash", routes: routes))
        XCTAssertFalse(ModelPickerOptions.isSelected(o[1], route: "gemini", model: "google/gemini-3.5-flash", routes: routes))
        XCTAssertNil(ModelPickerOptions.headerLabel(route: "auto", model: nil, routes: routes))
        XCTAssertEqual(ModelPickerOptions.headerLabel(route: "gemini", model: "google/gemini-3.5-flash", routes: routes), "gemini-3.5-flash")
    }
}

/// Sidebar 17:24 (B-a): the first-run flying cat is drawn only during the handoff, so a hand-off that fires after the host's
/// settle (phase already .done) can never leave it stranded at the root, outside the sliding chat page.
@MainActor final class FirstRunTransitionFlightTests: XCTestCase {
    func testFlightIsDrawnOnlyWhileLeaving() {
        let t = FirstRunTransition()
        XCTAssertFalse(t.drawsFlight, "idle")
        t.begin(reduceMotion: false); XCTAssertTrue(t.drawsFlight, "leaving")
        t.finish(); XCTAssertFalse(t.drawsFlight, "done: nothing may stay drawn, even if handOff(.headerAvatar) never ran")
        t.handOff(.headerAvatar); XCTAssertFalse(t.drawsFlight, "a late hand-off after finish() changes nothing")
        t.begin(reduceMotion: false); t.cancel(); XCTAssertFalse(t.drawsFlight, "cancelled")
    }
}

/// v1 17:55: a turn the server parks as `outcome_unknown` must not keep the conversation unresolved (busy) forever.
actor OutcomeUnknownBackend: ConversationBackend {
    private(set) var posts = 0, reads = 0
    private let message = UUID()
    func connection(scope: DataScope) async -> ConversationConnection { .init(state: .connected, provider: "outcome_unknown fixture", detail: "No network/model") }
    func reply(_ request: ConversationTurnRequest) async throws -> AsyncThrowingStream<ConversationTurnEvent, Error> {
        posts += 1
        let first = posts == 1, message = UUID()
        return AsyncThrowingStream { c in
            c.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 1, payload: .textDelta(messageID: message, text: "partial")))
            if !first { c.yield(.init(operationID: request.operationID, epoch: request.epoch, sequence: 2, payload: .completed(messageID: message, finalTextHash: textHash("partial")))) }
            c.finish()   // first turn: stream ends with no terminal event → local `.unknown`
        }
    }
    func observe(_ request: ConversationTurnRequest) async throws -> ConversationObservation {
        reads += 1
        return ConversationObservation(request: request, events: [], serverState: "outcome_unknown")
    }
}
final class OutcomeUnknownSettleTests: XCTestCase {
    func testOutcomeUnknownSettlesAfterThreeSnapshotsAndFreesTheConversation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OutcomeUnknown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try Repository(persistence: FilePersistence(url: folder.appendingPathComponent("store.json")))
        let backend = OutcomeUnknownBackend(), service = ConversationSessionService(repository: repo, backend: backend)
        let id = try await service.create(scope: Profiles.user)
        do { _ = try await service.send(scope: Profiles.user, conversationID: id, text: "请记住：我最喜欢喝燕麦拿铁", operationID: UUID()) } catch ConversationSessionError.unresolvedOperation { }
        var saved = try await service.read(scope: Profiles.user, conversationID: id)
        XCTAssertNotNil(saved.unresolved, "precondition: interrupted turn is unresolved")
        for n in 1...2 {
            try await service.observe(scope: Profiles.user, conversationID: id)
            saved = try await service.read(scope: Profiles.user, conversationID: id)
            XCTAssertNotNil(saved.unresolved, "still waiting after \(n) outcome_unknown snapshot(s)")
        }
        try await service.observe(scope: Profiles.user, conversationID: id)
        saved = try await service.read(scope: Profiles.user, conversationID: id)
        XCTAssertNil(saved.unresolved, "settled after 3 snapshots: the conversation is no longer busy")
        XCTAssertEqual(saved.turns.last?.state, .failed)
        XCTAssertEqual(saved.turns.last?.error, ConversationSessionService.outcomeUnverified, "rendered as 结果待核对, not 未发送")
        let posts = await backend.posts
        XCTAssertEqual(posts, 1, "never auto-resent: the step may have run")
        // A new message goes out normally afterwards.
        _ = try await service.send(scope: Profiles.user, conversationID: id, text: "我最喜欢喝什么？", operationID: UUID())
        saved = try await service.read(scope: Profiles.user, conversationID: id)
        XCTAssertEqual(saved.turns.last?.state, .completed)
        let after = await backend.posts
        XCTAssertEqual(after, 2)
    }
    func testBoundsAreThreeSnapshotsOrThirtySeconds() async throws {
        XCTAssertEqual(ConversationSessionService.outcomeUnknownMaxObservations, 3)
        XCTAssertEqual(ConversationSessionService.outcomeUnknownGiveUpSeconds, 30)
    }
}
