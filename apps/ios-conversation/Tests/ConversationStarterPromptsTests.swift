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
