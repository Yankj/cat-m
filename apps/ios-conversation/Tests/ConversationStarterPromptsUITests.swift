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

/// v1 letterbox blocker (2026-10-17): the chat canvas must be full-bleed. SidebarHost used to lay out and clip to the
/// safe-area rect, so the status-bar and home-indicator strips showed the bare window (black in dark mode, white in light)
/// and the app looked letterboxed. The pixels at the very top and very bottom must be the same canvas as mid-screen.
final class ChatFullBleedUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testChatCanvasCoversStatusBarAndHomeIndicatorStrips() throws {
        let app = XCUIApplication(bundleIdentifier: "com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment = ["CF_UI_TEST_STORE": UUID().uuidString, "CF_UI_TEST_SCENARIO": "p0-ui-echo", "CATPAW_QA_VISUAL_REVIEW": "1"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5) // launch hand-off finished
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = "chat-full-bleed"; a.lifetime = .keepAlways; add(a)
        let cg = try XCTUnwrap(shot.image.cgImage)
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func rgb(_ x: Int, _ yFromTop: Int) -> [Int] { let i = (yFromTop * w + x) * 4; return [Int(px[i]), Int(px[i+1]), Int(px[i+2])] }
        let canvas = rgb(6, h / 2)
        for (label, y) in [("status-bar strip", 4), ("home-indicator strip", h - 4)] {
            let p = rgb(6, y)
            XCTAssertTrue(zip(p, canvas).allSatisfy { abs($0 - $1) <= 8 }, "\(label) is \(p), canvas is \(canvas): the chat is not full-bleed (letterbox)")
        }
    }
}
