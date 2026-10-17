import XCTest
@testable import CatpawM

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

/// fix/chat-acceptance-3 #3: every device tool the app advertises (X-Catpaw-Device-Tools) must be accepted as a
/// `tool_call` name, otherwise ConversationSessionService.apply throws invalidEvent (「服务返回了不匹配的对话或工具结果」).
/// Prod turn 75aba37d (附近咖啡馆 starter → places_search) stalled at sequence 2 for exactly this reason.
final class DeviceToolNamesContractTests: XCTestCase {
    func testEveryAdvertisedDeviceToolIsAnAcceptedToolCallName() {
        for tool in DeviceToolContract.clientTools {
            XCTAssertTrue(NativeChatHTTPBackend.approvalToolNames.contains(tool), "\(tool) advertised but rejected as tool_call")
        }
        XCTAssertTrue(NativeChatHTTPBackend.approvalToolNames.contains("places_search"))
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
