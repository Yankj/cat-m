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

/// chat-context-1522 #1/#3 + status-line on BE5C, offline (`p0-ui-device-calendar`: synthetic create_calendar_event approval card,
/// decision through submitApproval, followups fence on every answer). No network, model or EventKit.
final class ChatContextDeviceCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(_ store: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment = ["CF_UI_TEST_STORE": store, "CF_UI_TEST_SCENARIO": "p0-ui-device-calendar"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); return app
    }
    private func shot(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.textViews["chat.input"]; XCTAssertTrue(field.waitForExistence(timeout: 15)); field.tap(); field.typeText(text)
        app.buttons["chat.send"].firstMatch.tap()
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: id) }
    private func label(_ app: XCUIApplication, _ text: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch }
    func testCancelledCalendarCardPersistsAndChipsOnlyUnderLatestAnswer() throws {
        let store = UUID().uuidString
        var app = launch(store)
        send(app, "帮我加个明天下午3点的评审会日程")
        let cancel = app.buttons["chat.approval.deny"].firstMatch
        let found = cancel.waitForExistence(timeout: 20); shot("cal-00-after-send")
        XCTAssertTrue(found, "calendar card\n" + app.debugDescription)
        let waiting = label(app, "等你确认日程")
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "status row: static 等你确认日程 while the card is pending")
        shot("cal-01-waiting"); Thread.sleep(forTimeInterval: 1.0); shot("cal-02-waiting-1s-later")
        XCTAssertTrue(waiting.exists, "waiting row stays while pending")
        cancel.tap()
        XCTAssertTrue(label(app, "已拒绝").waitForExistence(timeout: 10), "card shows its final state (已拒绝) after the decision")
        XCTAssertTrue(label(app, "没有添加这个日程").waitForExistence(timeout: 10), "turn finished after the device result")
        let chips = any(app, "chat.followups").firstMatch.waitForExistence(timeout: 5); shot("cal-03-cancelled")
        XCTAssertTrue(chips, "chips under the answer\n" + app.debugDescription)
        XCTAssertEqual(any(app, "chat.followups").count, 1)
        send(app, "好的，再说一句")
        XCTAssertTrue(label(app, "这是一条测试回答").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.0); shot("cal-04-second-answer")
        XCTAssertEqual(any(app, "chat.followups").count, 1, "chips only under the latest answer")
        XCTAssertTrue(label(app, "已拒绝").exists, "earlier card keeps its final state after a turn change")
        app.terminate()
        app = launch(store)
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 20))
        XCTAssertTrue(label(app, "已拒绝").waitForExistence(timeout: 10), "final state survives a cold relaunch"); shot("cal-05-relaunched")
        XCTAssertLessThanOrEqual(any(app, "chat.followups").count, 1)
    }
    /// status-line: a reply that finishes under the 0.6 s appear delay never shows a row; a tool phase shows the table copy.
    func testFastReplyShowsNoRowAndToolPhaseShowsCopy() throws {
        let app = launch(UUID().uuidString)
        send(app, "快速回一句")
        var seen: [String] = []
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            for id in ["chat.answer.working", "chat.answer.awaitingUser"] where app.descendants(matching: .any)[id].exists { seen.append(id) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(label(app, "收到。").waitForExistence(timeout: 5))
        XCTAssertTrue(seen.isEmpty, "no status row for a <1 s reply, saw \(seen)"); shot("sl-01-fast-reply")
        send(app, "看看我的待办")
        XCTAssertTrue(label(app, "正在看你的待办").waitForExistence(timeout: 5), "tool phase uses ToolStepCopy"); shot("sl-02-tool-phase")
        XCTAssertTrue(label(app, "你现在没有待办").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(app.descendants(matching: .any)["chat.answer.working"].exists, "row hides once text arrives"); shot("sl-03-answered")
    }
}

/// Sidebar 17:24 (B-b): with the full-bleed host, the open sidebar must still keep its account row below the status bar
/// and its settings / search bar above the home indicator.
final class SidebarSafeAreaUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testOpenSidebarRespectsTopAndBottomSafeArea() throws {
        let app = XCUIApplication(bundleIdentifier: "com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment = ["CF_UI_TEST_STORE": UUID().uuidString, "CF_UI_TEST_SCENARIO": "p0-ui-device-calendar"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let open = app.buttons["sidebar.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        let settings = app.descendants(matching: .any)["sidebar.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); Thread.sleep(forTimeInterval: 1.0)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "sidebar-open"; shot.lifetime = .keepAlways; add(shot)
        let window = app.windows.firstMatch.frame
        // Every current iPhone has a ≥ 20 pt status bar and, on Face ID models, a 34 pt home-indicator strip.
        let account = app.descendants(matching: .any)["sidebar.account"].firstMatch
        XCTAssertTrue(account.exists)
        let top = account.frame.minY
        XCTAssertGreaterThanOrEqual(top, 44, "top-most sidebar item sits below the status bar")
        XCTAssertLessThanOrEqual(settings.frame.maxY, window.maxY - 20, "settings / search bar above the home indicator")
        let search = app.descendants(matching: .any)["sidebar.search"].firstMatch
        if search.exists { XCTAssertLessThanOrEqual(search.frame.maxY, window.maxY - 20) }
        // Keyboard: the search bar rides just above it (one inset, not none and not doubled).
        search.tap()
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 0.8)
            let kb = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); kb.name = "sidebar-search-keyboard"; kb.lifetime = .keepAlways; add(kb)
            XCTAssertLessThanOrEqual(search.frame.maxY, keyboard.frame.minY, "search bar above the keyboard")
            XCTAssertGreaterThan(search.frame.minY, keyboard.frame.minY - 260, "search bar not lifted by a doubled keyboard inset (≈ keyboard height)")
        }
    }
}

/// device-0728 P0 (NoBug): the sidebar's bottom-left gear must open 设置 — after the drawer settles and on a quick tap
/// while it is still opening. `tap()` lands on the element's centre, i.e. the empty middle of the gear glyph inside the
/// glass circle: on iOS 26 that point only fires the Button when the label declares a full-circle hit shape.
/// Run on an iOS 26.x simulator to reproduce the device bug (iOS 27 hit-tests interactive glass itself).
final class SidebarSettingsRouteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() { XCUIDevice.shared.appearance = .light; super.tearDown() }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment = ["CF_UI_TEST_STORE": UUID().uuidString, "CF_UI_TEST_SCENARIO": "p0-ui-device-calendar"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); return app
    }
    private func shot(_ name: String) { let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s) }
    private func openDrawer(_ app: XCUIApplication) -> XCUIElement {
        let open = app.buttons["sidebar.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        let gear = app.descendants(matching: .any)["sidebar.settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        return gear
    }
    func testGearOpensSettingsAfterDrawerSettles() {
        let app = launch()
        let gear = openDrawer(app); Thread.sleep(forTimeInterval: 1.0)
        shot("gear-before-tap"); gear.tap()
        let opened = app.descendants(matching: .any)["settings.appVersion"].waitForExistence(timeout: 5)
        shot("gear-after-tap")
        XCTAssertTrue(opened, "设置 did not open from the sidebar gear")
        XCTAssertFalse(app.buttons["sidebar.close"].exists, "drawer must be closed once 设置 is pushed")
    }
    func testGearOpensSettingsOnQuickTap() {
        let app = launch()
        openDrawer(app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.appVersion"].waitForExistence(timeout: 5), "设置 did not open on a quick gear tap")
    }
    func testComposerVoiceButtonIsABlackCircleInDarkMode() {
        XCUIDevice.shared.appearance = .dark
        let app = launch()
        let voice = app.buttons["chat.composer.voice"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 20))
        XCTAssertTrue(voice.isEnabled, "the voice button is enabled once the conversation is loaded")
        Thread.sleep(forTimeInterval: 0.8); shot("composer-voice-dark")   // review: black circle, white waveform
    }
}
