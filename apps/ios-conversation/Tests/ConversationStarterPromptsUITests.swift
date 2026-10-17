import XCTest

/// feat/chat-starter-prompts: on the offline echo fixture, tapping a starter card on the empty conversation sends its
/// full prompt at once (user bubble appears, starters and empty state go away) and the turn completes normally.
final class ConversationStarterPromptsUITests: XCTestCase {
    private let bundleID = "com.example.CatpawM.ConversationFirst.Auth"
    private let reminderPrompt = "明天上午 10 点提醒我给客户回电话"
    override func setUp() { continueAfterFailure = false }

    private func launchEmpty() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchEnvironment = ["CF_UI_TEST_STORE": UUID().uuidString, "CF_UI_TEST_SCENARIO": "p0-ui-echo", "CATPAW_QA_VISUAL_REVIEW": "1"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 15), app.debugDescription)
        let new = app.buttons["chat.new"]
        if new.waitForExistence(timeout: 5), new.isEnabled { new.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["chat.empty"].waitForExistence(timeout: 10))
        return app
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testTappingStarterSendsFullPromptImmediately() {
        let app = launchEmpty()
        let card = app.buttons["chat.starter.reminder"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        for id in ["schedule", "reminder", "meeting", "nearby", "breakdown", "writing"] {
            XCTAssertTrue(app.buttons["chat.starter." + id].exists, id)
            XCTAssertTrue(app.buttons["chat.starter." + id].isHittable, "\(id) must be visible without scrolling")
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        attach(app, "starter-empty-state")
        card.tap()
        // Instant send: the user bubble appears and the empty state (with its starters) is gone, before any reply.
        XCTAssertTrue(app.descendants(matching: .any)["chat.userMessage"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["chat.starter.reminder"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.empty"].exists)
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", reminderPrompt)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 2), "The bubble must carry the full starter prompt")
        XCTAssertEqual((app.textViews["chat.input"].value as? String)?.contains(reminderPrompt), false, "The prompt is sent, not left in the composer")
        XCTAssertTrue(app.staticTexts["chat.reply.completed"].waitForExistence(timeout: 15))
        attach(app, "starter-sent-and-completed")
    }

    func testTypingOwnDraftHidesStarters() {
        let app = launchEmpty()
        let card = app.buttons["chat.starter.schedule"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let input = app.textViews["chat.input"]; input.tap(); input.typeText("自己写")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["chat.userMessage"].exists, "Typing never sends a starter")
    }
}
