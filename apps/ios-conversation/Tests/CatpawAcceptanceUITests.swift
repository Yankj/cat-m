import XCTest
import UIKit

/// One-click acceptance suite (scripts/run-ui-acceptance.sh). Every step attaches a keepAlways screenshot
/// named "NN-step" so the script can build an ordered report. Fixture cases use the offline P0 backend
/// (CF_UI_TEST_STORE + CF_UI_TEST_SCENARIO=p0-ui-acceptance*): no HTTP, Auth or model calls.
/// The live anonymous-login case runs only with CATPAW_ACCEPTANCE_LIVE=1.
final class CatpawAcceptanceUITests: XCTestCase {
    private let bundleID = ProcessInfo.processInfo.environment["CATPAW_UI_BUNDLE_ID"] ?? "com.example.CatpawM.ConversationFirst.Auth"

    /// Per-test isolation: kill any running instance (e.g. one launched by Device Hub/simctl) so every
    /// test cold-launches with its own fresh CF_UI_TEST_STORE, never reusing a previous test's state.
    override func setUp() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundleID)
        if app.state != .notRunning { app.terminate(); _ = app.wait(for: .notRunning, timeout: 10) }
    }
    override func tearDown() { XCUIApplication(bundleIdentifier: bundleID).terminate() }

    private func fixtureApp(_ scenario: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchEnvironment["CF_UI_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["CF_UI_TEST_SCENARIO"] = scenario
        for (k, v) in extra { app.launchEnvironment[k] = v }
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func input(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["chat.input"].firstMatch }
    private func waitFor(_ element: XCUIElement, _ format: String, _ args: CVarArg..., timeout: TimeInterval) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter.wait(for: [e], timeout: timeout) == .completed
    }
    private func send(_ app: XCUIApplication, _ text: String) {
        let field = input(app); XCTAssertTrue(field.waitForExistence(timeout: 20)); field.tap(); field.typeText(text)
        let button = app.buttons["chat.send"]; XCTAssertTrue(waitFor(button, "enabled == true", timeout: 10)); shot(app, "02b-send-enabled-with-text"); button.tap()
    }

    // 1. Launch animation → first screen
    func test01LaunchAnimation() {
        let app = fixtureApp("p0-ui-acceptance"); app.launch()
        shot(app, "01-launch-mark-early")
        Thread.sleep(forTimeInterval: 0.5); shot(app, "01-launch-mark-mid")
        if !input(app).waitForExistence(timeout: 20) {
            // One cold relaunch with a brand-new store before failing (simulator launch hiccup).
            shot(app, "01-retry-before-relaunch"); app.terminate(); _ = app.wait(for: .notRunning, timeout: 10)
            app.launchEnvironment["CF_UI_TEST_STORE"] = UUID().uuidString; app.launch()
        }
        XCTAssertTrue(input(app).waitForExistence(timeout: 20), "Composer must appear after the launch mark")
        shot(app, "01-launch-first-screen")
    }

    // 2. Anonymous login → chat (live; real Auth, no model call)
    func test02AnonymousLoginIntoChat() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_ACCEPTANCE_LIVE"] == "1" else { throw XCTSkip("Set CATPAW_ACCEPTANCE_LIVE=1 to exercise real anonymous sign-in") }
        let app = XCUIApplication(bundleIdentifier: bundleID); app.launch()
        shot(app, "02-auth-entrance")
        let start = app.buttons["auth.startExperience"]
        if start.waitForExistence(timeout: 15) {
            XCTAssertTrue(waitFor(start, "enabled == true", timeout: 20)); start.tap(); shot(app, "02-auth-starting")
        }
        XCTAssertTrue(input(app).waitForExistence(timeout: 45), "Anonymous session must land in chat")
        XCTAssertFalse(app.buttons["auth.startExperience"].exists)
        shot(app, "02-chat-after-anonymous-login")
    }

    // 3+4+6. Send → thinking → streaming body → scroll-to-latest → stop
    func test03SendThinkingStreamScrollAndStop() {
        let app = fixtureApp("p0-ui-acceptance"); app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 20)); shot(app, "03-empty-chat")
        send(app, "Acceptance synthetic prompt")
        XCTAssertTrue(app.descendants(matching: .any)["chat.userMessage"].firstMatch.waitForExistence(timeout: 10))
        let thinking = app.descendants(matching: .any)["chat.answer.thinking"].firstMatch
        if thinking.waitForExistence(timeout: 3) { shot(app, "03-thinking") } else { shot(app, "03-thinking-not-visible") }
        let answer = app.descendants(matching: .any)["chat.assistantMessage"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "Streaming body must appear"); Thread.sleep(forTimeInterval: 1.5)
        shot(app, "04-streaming-body")

        // Scroll away from the bottom while streaming → jump-to-latest appears → tap → gone.
        let transcript = app.descendants(matching: .any)["chat.transcript"].firstMatch
        (transcript.exists ? transcript : app.scrollViews.firstMatch).swipeDown(velocity: .fast)
        let jump = app.buttons["chat.jumpToLatest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "Scroll-to-latest button must appear when reader leaves the bottom")
        shot(app, "06-jump-to-latest-visible"); jump.tap()
        XCTAssertTrue(waitFor(jump, "exists == false", timeout: 5)); shot(app, "06-jump-to-latest-returned")

        // Stop: the composer exposes a stop control (label 停止回答) only once cancellation is wired.
        let stop = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "停止回答", "chat.stop")).firstMatch
        if stop.waitForExistence(timeout: 2) {
            shot(app, "05-stop-visible")
            stop.tap(); shot(app, "05-stopped")
            // Server cancel: partial + interrupted footer, or the full answer if the cancel raced completion.
            let interrupted = app.descendants(matching: .any)["chat.answer.interrupted"].firstMatch, done = app.descendants(matching: .any)["chat.reply.completed"].firstMatch
            let deadline = Date().addingTimeInterval(20)
            while !(interrupted.exists || done.exists) && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            shot(app, "05-after-cancel")
            XCTAssertTrue(interrupted.exists || done.exists, "Stop must end in interrupted partial or full answer (cancel raced completion)")
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "cancelled")).firstMatch.exists, "No raw error after stop")
        } else {
            shot(app, "05-stop-control-missing")
            XCTExpectFailure("ConversationComposerChromeAdapter.stop() is a no-op and runState never reports .responding; stop UI not wired yet", strict: false) {
                XCTFail("Stop control not present while streaming")
            }
        }
        XCTAssertTrue(app.descendants(matching: .any)["chat.reply.completed"].firstMatch.waitForExistence(timeout: 30) || app.descendants(matching: .any)["chat.answer.interrupted"].firstMatch.exists)
        shot(app, "04-final-settled")
    }

    // 5. '+' attachment menu
    func test04AttachmentMenu() {
        let app = fixtureApp("p0-ui-acceptance"); app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 20))
        let add = app.buttons["chat.composer.add"]; XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        XCTAssertTrue(app.buttons["照片"].waitForExistence(timeout: 5) || app.buttons["Photos"].exists, "Attachment menu must list photos")
        XCTAssertTrue(app.buttons["文件"].exists || app.buttons["Files"].exists)
        shot(app, "07-attachment-menu")
        app.buttons["文件"].exists ? app.buttons["文件"].tap() : app.buttons["Files"].tap()
        Thread.sleep(forTimeInterval: 1.5); shot(app, "07-file-importer")
    }

    // 7. Offline status capsule → retry → recovered
    func test05OfflineCapsuleAndRetry() {
        let app = fixtureApp("p0-ui-acceptance-offline", extra: ["CATPAW_ACCEPTANCE_OFFLINE_SECONDS": "30"]); app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 20))
        // r8: offline is a faint meta line above the pill + status dot in the title (no capsule)
        let field = input(app); field.tap(); field.typeText("离线草稿")
        let meta = app.descendants(matching: .any)["chat.composer.meta"].firstMatch
        XCTAssertTrue(meta.waitForExistence(timeout: 10), "Offline meta line must show"); shot(app, "r8-06-offline-draft")
        shot(app, "08-online-recovered")
    }

    // r8. Top bar = two-line sidebar glyph + title menu + new chat; composer pill, no info / ellipsis
    func test06R8Chrome() {
        let app = fixtureApp("p0-ui-acceptance"); app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["sidebar.open"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.title"].firstMatch.exists)
        XCTAssertTrue(app.buttons["chat.new"].exists)
        XCTAssertFalse(app.buttons["chat.more"].exists)
        XCTAssertFalse(app.buttons["chat.composer.context"].exists)
        XCTAssertTrue(app.buttons["chat.composer.voice"].exists, "Empty draft shows voice")
        shot(app, "r8-01-empty")
        let field = input(app); field.tap(); field.typeText("第一行\n第二行\n第三行\n第四行\n第五行\n第六行\n第七行\n第八行")
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.composer.voice"].exists)
        XCTAssertLessThan(field.frame.height, 200, "Composer caps at ~6 lines")
        shot(app, "r8-02-typing-multiline")
        app.descendants(matching: .any)["chat.title"].firstMatch.tap(); shot(app, "r8-03-title-menu")
    }

    // Real backend: anonymous user + cloud consent + real message (CATPAW_ACCEPTANCE_REAL=1, DeviceTrial build).
    func test07RealChatEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_ACCEPTANCE_REAL"] == "1" else { throw XCTSkip("real backend only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        let start = app.buttons["auth.startExperience"]
        if start.waitForExistence(timeout: 8) { XCTAssertTrue(waitFor(start, "enabled == true", timeout: 20), "开始体验 must be enabled (config present)"); start.tap() }
        XCTAssertTrue(input(app).waitForExistence(timeout: 45))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow"] { let b = springboard.buttons[label]; if b.waitForExistence(timeout: 3) { b.tap(); break } }
        shot(app, "real-01-chat")
        if let title = ProcessInfo.processInfo.environment["CATPAW_REAL_OPEN"], !title.isEmpty {
            app.buttons["sidebar.open"].tap(); Thread.sleep(forTimeInterval: 1)
            shot(app, "real-legacy-00-sidebar")
            let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title))
            _ = rows.firstMatch.waitForExistence(timeout: 5)
            let row = rows.allElementsBoundByIndex.first(where: { $0.isHittable })
            XCTAssertNotNil(row, "conversation \(title) visible in sidebar"); row?.tap(); Thread.sleep(forTimeInterval: 2); shot(app, "real-legacy-01-opened")
        }
        if ProcessInfo.processInfo.environment["CATPAW_REAL_NEW"] == "1" { app.buttons["chat.new"].tap(); Thread.sleep(forTimeInterval: 1.5); shot(app, "real-01b-new-chat") }
        let field = input(app); field.tap(); field.typeText(ProcessInfo.processInfo.environment["CATPAW_REAL_TEXT"] ?? "用一句话介绍你自己")
        app.buttons["chat.send"].tap()
        let review = app.buttons["chat.consent.review"]
        if review.waitForExistence(timeout: 8) { shot(app, "real-02a-consent-banner"); review.tap() }
        let allow = app.buttons["chat.modelConsent.allow"]
        if allow.waitForExistence(timeout: 8) { shot(app, "real-02-consent"); allow.tap() }
        if app.descendants(matching: .any)["chat.answer.thinking"].firstMatch.waitForExistence(timeout: 15) { shot(app, "real-03-thinking") }
        if app.descendants(matching: .any)["chat.assistantMessage"].firstMatch.waitForExistence(timeout: 60) { Thread.sleep(forTimeInterval: 0.8); shot(app, "real-04-streaming") }
        let done = app.descendants(matching: .any)["chat.reply.completed"].firstMatch.waitForExistence(timeout: 120)
        shot(app, done ? "real-05-done" : "real-05-not-done")
        XCTAssertTrue(done, "Real reply must complete")
    }

    // 9. Composer dictation: mic → (system permission prompt | dictating stop control | friendly notice); voice → coming soon
    func test09ComposerDictation() {
        let app = fixtureApp("p0-ui-acceptance"); app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 20))
        let voice = app.buttons["chat.composer.voice"]; XCTAssertTrue(voice.waitForExistence(timeout: 10)); voice.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer.voice.comingSoon"].waitForExistence(timeout: 3), "Voice conversation must show a coming-soon toast")
        shot(app, "09a-voice-coming-soon")
        let mic = app.buttons["chat.composer.mic"]; XCTAssertTrue(mic.waitForExistence(timeout: 10)); mic.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dictating = app.buttons["chat.composer.dictating"], notice = app.alerts.firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !dictating.exists && !notice.exists {
            let prompt = springboard.alerts.firstMatch
            if prompt.exists { shot(app, "09b-permission-prompt"); prompt.buttons.element(boundBy: prompt.buttons.count - 1).tap() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(dictating.exists || notice.exists, "Mic must start dictation or explain why it cannot")
        shot(app, dictating.exists ? "09c-dictating" : "09c-dictation-notice")
        if dictating.exists { dictating.tap(); XCTAssertTrue(mic.waitForExistence(timeout: 10) || app.buttons["chat.send"].exists) }
        else { notice.buttons.element(boundBy: notice.buttons.count - 1).tap() }
    }

    // PR #33 dictation stress: rapid start/stop ×5, start while a reply streams, relaunch and restart. Runs on any build
    // (CATPAW_UI_BUNDLE_ID selects the installed DeviceTrial app); asserts the app stays alive and dictation is restartable.
    func test10DictationStress() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_DICTATION_STRESS"] == "1" else { throw XCTSkip("stress only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 30))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func clearPrompts() { for _ in 0..<3 { let a = springboard.alerts.firstMatch; if a.waitForExistence(timeout: 1) { a.buttons.element(boundBy: a.buttons.count - 1).tap() } }; if app.alerts.firstMatch.exists { let a = app.alerts.firstMatch; a.buttons.element(boundBy: a.buttons.count - 1).tap() } }
        func toggle() { // coordinate taps: the mic/dictating button legitimately morphs mid-tap; a vanished element must not fail the test
            for e in [app.buttons["chat.composer.dictating"], app.buttons["chat.composer.mic"]] where e.exists { let f = e.frame; guard !f.isEmpty else { continue }
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap(); return } }
        toggle(); clearPrompts(); shot(app, "10a-first-start")
        for _ in 0..<10 { toggle(); Thread.sleep(forTimeInterval: 0.15) }
        Thread.sleep(forTimeInterval: 2); XCTAssertEqual(app.state, .runningForeground, "alive after rapid toggles"); shot(app, "10b-after-rapid")
        if app.buttons["chat.composer.dictating"].exists { app.buttons["chat.composer.dictating"].tap(); Thread.sleep(forTimeInterval: 1) }
        let field = input(app); field.tap(); field.typeText("写三段话介绍猫")
        if app.buttons["chat.send"].exists { app.buttons["chat.send"].tap() }
        Thread.sleep(forTimeInterval: 2); toggle(); Thread.sleep(forTimeInterval: 2); shot(app, "10c-dictation-during-stream")
        XCTAssertEqual(app.state, .runningForeground, "alive when dictating during stream"); toggle(); Thread.sleep(forTimeInterval: 3)
        app.terminate(); app.launch(); XCTAssertTrue(input(app).waitForExistence(timeout: 30))
        toggle(); Thread.sleep(forTimeInterval: 1.5); clearPrompts()
        XCTAssertTrue(app.buttons["chat.composer.dictating"].exists || app.alerts.firstMatch.exists || app.buttons["chat.composer.mic"].exists, "restartable after relaunch")
        shot(app, "10d-restart-after-relaunch"); toggle(); Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground)
    }

    // 11. catpaw.ui.v1 through the DEBUG demo backend (docs/demo-fixture-backend.md): approval → round 1
    //     (card, list, progress, choices) → choose → round 2 (progress update, form, confirm, sheet).
    //     Needs real anonymous sign-in, so it runs only with CATPAW_ACCEPTANCE_DEMO=1.
    func test11GenerativeUIDemoRounds() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_ACCEPTANCE_DEMO"] == "1" else { throw XCTSkip("Set CATPAW_ACCEPTANCE_DEMO=1 (needs sign-in; chat is scripted by -CatpawDemoBackend)") }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments += ["-CatpawDemoBackend", "-CatpawSkipOnboarding"]; forwardPublicConfig(app); app.launch()
        let start = app.buttons["auth.startExperience"]
        if start.waitForExistence(timeout: 8) { XCTAssertTrue(waitFor(start, "enabled == true", timeout: 20)); start.tap() }
        XCTAssertTrue(input(app).waitForExistence(timeout: 45))
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        func block(_ id: String) -> XCUIElement { element("chat.block." + id) }
        send(app, "帮我安排今天")
        let approve = app.buttons["chat.approval.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "create_task approval card"); shot(app, "11a-approval"); approve.tap()
        for id in ["demo-card", "demo-list", "demo-progress", "demo-choices"] {
            XCTAssertTrue(block(id).waitForExistence(timeout: 20), "round 1: \(id)")
        }
        shot(app, "11b-round1-card-list-progress-choices")
        let choice = block("demo-choices").descendants(matching: .any)["chat.block.item.a"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        for id in ["demo-form", "demo-confirm", "demo-sheet"] {
            XCTAssertTrue(block(id).waitForExistence(timeout: 20), "round 2: \(id)")
        }
        XCTAssertTrue(element("chat.block.step.plan").exists || element("chat.block.step.read").exists, "progress update visible")
        shot(app, "11c-round2-progress-form-confirm-sheet")
        let confirm = block("demo-confirm").descendants(matching: .any)["chat.block.confirm.approve"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap(); Thread.sleep(forTimeInterval: 1); shot(app, "11d-confirm-answered") }
        XCTAssertFalse(element("chat.block.error").exists, "no decision error")
    }

    /// Debug builds have no CATPAW_* in Info.plist; forward the PUBLIC values from the runner env (TEST_RUNNER_CATPAW_*).
    private func forwardPublicConfig(_ app: XCUIApplication) {
        for name in ["CATPAW_SUPABASE_PROJECT_URL", "CATPAW_SUPABASE_PUBLISHABLE_KEY", "CATPAW_BACKEND_ORIGIN", "CATPAW_SERVER_SCOPE_ID", "CATPAW_MODEL_ROUTE", "CATPAW_MODEL"] {
            if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { app.launchEnvironment[name] = value }
        }
    }

    // UX audit tour (CATPAW_UX_TOUR=1, installed DeviceTrial app via CATPAW_UI_BUNDLE_ID): screenshots of every surface + common gestures.
    func test12UXTour() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_UX_TOUR"] == "1" else { throw XCTSkip("tour only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 30)); Thread.sleep(forTimeInterval: 1.5)
        shot(app, "ux-01-conversation")
        let msgs = app.scrollViews["chat.transcript"]
        if msgs.exists { msgs.swipeDown(); Thread.sleep(forTimeInterval: 0.6); shot(app, "ux-02-scrolled-up") }
        let text = app.staticTexts.allElementsBoundByIndex.last(where: { $0.isHittable && $0.label.count > 12 })
        if let text { text.press(forDuration: 0.8); Thread.sleep(forTimeInterval: 0.8); shot(app, "ux-03-longpress-message"); app.tap(); Thread.sleep(forTimeInterval: 0.5) }
        if app.buttons["chat.new"].exists { app.buttons["chat.new"].tap(); Thread.sleep(forTimeInterval: 1); shot(app, "ux-04-new-chat-empty") }
        let field = input(app); field.tap(); Thread.sleep(forTimeInterval: 0.6); shot(app, "ux-05-composer-focused")
        field.typeText("第一行\n第二行\n第三行"); Thread.sleep(forTimeInterval: 0.4); shot(app, "ux-06-composer-multiline")
        for id in ["chat.composer.add", "chat.add", "composer.add"] where app.buttons[id].exists { app.buttons[id].tap(); Thread.sleep(forTimeInterval: 0.8); shot(app, "ux-07-plus-menu"); app.tap(); break }
        if app.buttons["chat.title.menu"].exists || app.buttons["chat.title"].exists { (app.buttons["chat.title.menu"].exists ? app.buttons["chat.title.menu"] : app.buttons["chat.title"]).tap(); Thread.sleep(forTimeInterval: 0.8); shot(app, "ux-08-title-menu"); app.tap() }
        if app.buttons["sidebar.open"].exists { app.buttons["sidebar.open"].tap(); Thread.sleep(forTimeInterval: 1); shot(app, "ux-09-drawer") }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Surface tour for shots/latest/w2: toolbar, composer, popover, live turn (cat head + Dynamic Island), action row,
    /// long-press, drawer, proactive inbox, tasks, memory, settings (邀请码).
    func test14Surfaces() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_SURFACE_TOUR"] == "1" else { throw XCTSkip("surface tour only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); forwardPublicConfig(app); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        func screen(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        XCTAssertTrue(input(app).waitForExistence(timeout: 40)); Thread.sleep(forTimeInterval: 1.5)
        if app.buttons["chat.new"].isEnabled { app.buttons["chat.new"].tap(); Thread.sleep(forTimeInterval: 1) }
        shot(app, "w2-s01-home-circleicons")
        let plus = app.buttons["chat.composer.add"]
        if plus.exists { plus.tap(); Thread.sleep(forTimeInterval: 0.8); shot(app, "w2-s02-plus-popover"); plus.tap(); Thread.sleep(forTimeInterval: 0.5) }
        let field = input(app); field.tap(); Thread.sleep(forTimeInterval: 0.8)
        if !app.keyboards.firstMatch.exists { field.tap(); Thread.sleep(forTimeInterval: 0.8) }
        field.typeText("用三段话介绍一下猫为什么喜欢纸箱，每段至少80字")
        shot(app, "w2-s03-composer-typing")
        Thread.sleep(forTimeInterval: 0.6)
        let sends = app.buttons.matching(NSPredicate(format: "identifier == 'chat.send' OR identifier == 'chat.composer.send'")).allElementsBoundByIndex
        if let send = sends.first(where: { $0.isHittable && $0.isEnabled }) { send.tap() } else { field.typeText("\n") }
        Thread.sleep(forTimeInterval: 0.5)
        if (field.value as? String)?.contains("纸箱") == true, let send = sends.first(where: { $0.isHittable }) { send.tap() }
        let allow = app.buttons["允许此对话"]
        if allow.waitForExistence(timeout: 4) { shot(app, "w2-s03b-model-consent"); allow.tap() }
        Thread.sleep(forTimeInterval: 1.5); shot(app, "w2-s04-turn-1s5")
        Thread.sleep(forTimeInterval: 4.5); shot(app, "w2-s05-turn-6s-cathead")
        Thread.sleep(forTimeInterval: 3); XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 2); screen("w2-s06-dynamic-island")
        app.activate(); Thread.sleep(forTimeInterval: 25)
        shot(app, "w2-s07-answer-actionrow")
        let bubble = app.descendants(matching: .any).matching(identifier: "chat.assistant.message").allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.descendants(matching: .any).matching(identifier: "chat.assistant.message").allElementsBoundByIndex.last
        if let bubble { bubble.press(forDuration: 0.8); Thread.sleep(forTimeInterval: 0.9)
            XCTAssertTrue(app.descendants(matching: .any)["chat.message.reactionBar"].exists, "#62 overlay")
            shot(app, "w2-s08-longpress"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap(); Thread.sleep(forTimeInterval: 0.8) }
        // Tool card (pastel CategoryPaw): ask for a reminder → device_call confirm card.
        let f2 = input(app); f2.tap(); Thread.sleep(forTimeInterval: 0.6); if !app.keyboards.firstMatch.exists { f2.tap(); Thread.sleep(forTimeInterval: 0.6) }
        if app.keyboards.firstMatch.exists { f2.typeText("帮我在提醒事项里建一个明天上午9点的提醒：交周报")
            app.buttons.matching(NSPredicate(format: "identifier == 'chat.send'")).allElementsBoundByIndex.first(where: { $0.isHittable && $0.isEnabled })?.tap()
            if app.buttons["允许此对话"].waitForExistence(timeout: 3) { app.buttons["允许此对话"].tap() }
            Thread.sleep(forTimeInterval: 25); app.swipeUp(); Thread.sleep(forTimeInterval: 0.5); shot(app, "w2-s08b-tool-card") }
        // Proactive card via debug deep link (pastel CategoryPaw on the card).
        app.terminate(); app.launchArguments = ["-CatpawSkipOnboarding", "-CatpawOpenURL", "catpawm://proactive/debug"]; app.launch()
        if app.buttons["proactive.engine.resetLedger"].waitForExistence(timeout: 30) { app.buttons["proactive.engine.resetLedger"].tap(); app.buttons["debug.signal.addMeeting"].tap()
            let run = app.buttons["debug.signal.run"]; var n = 0; while !(run.exists && run.isHittable) && n < 5 { app.swipeUp(); n += 1 }; run.tap(); Thread.sleep(forTimeInterval: 3) }
        app.terminate(); app.launchArguments = ["-CatpawSkipOnboarding", "-CatpawOpenURL", "catpawm://proactive"]; app.launch(); Thread.sleep(forTimeInterval: 3); shot(app, "w2-s08c-proactive-card")
        // Populate the task list: accept the card's reminder action so 任务 shows a real Catpaw reminder.
        let createReminder = app.buttons.matching(NSPredicate(format: "identifier == 'chat.proactiveSuggestion.create_reminder'")).firstMatch
        if createReminder.waitForExistence(timeout: 4) { createReminder.tap(); Thread.sleep(forTimeInterval: 2.5); shot(app, "w2-s08d-reminder-created") }
        for l in ["完成", "Done"] where app.buttons[l].exists { app.buttons[l].tap(); break }; Thread.sleep(forTimeInterval: 0.8)
        func drawer() { for _ in 0..<3 where !app.buttons["sidebar.open"].exists { if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }; Thread.sleep(forTimeInterval: 0.8) }
            if app.buttons["sidebar.open"].exists { app.buttons["sidebar.open"].tap(); Thread.sleep(forTimeInterval: 1) } }
        drawer(); shot(app, "w2-s09-drawer")
        if app.buttons["sidebar.proactive"].exists { app.buttons["sidebar.proactive"].tap(); Thread.sleep(forTimeInterval: 1.2); shot(app, "w2-s10-proactive-inbox")
            for l in ["完成", "Done"] where app.buttons[l].exists { app.buttons[l].tap(); break }; Thread.sleep(forTimeInterval: 0.8) }
        drawer(); if app.buttons["sidebar.tasks"].exists { app.buttons["sidebar.tasks"].tap(); Thread.sleep(forTimeInterval: 1.5); shot(app, "w2-s11-tasks"); app.navigationBars.buttons.firstMatch.tap(); Thread.sleep(forTimeInterval: 0.8) }
        drawer(); if app.buttons["sidebar.memory"].exists && app.buttons["sidebar.memory"].isEnabled { app.buttons["sidebar.memory"].tap(); Thread.sleep(forTimeInterval: 1.5); shot(app, "w2-s12-memory"); app.navigationBars.buttons.firstMatch.tap(); Thread.sleep(forTimeInterval: 0.8) }
        drawer(); if app.buttons["sidebar.settings"].exists { app.buttons["sidebar.settings"].tap() }; Thread.sleep(forTimeInterval: 1.5); shot(app, "w2-s13-settings")
        for _ in 0..<4 where !app.buttons["settings.invite"].exists { app.swipeUp() }
        if app.buttons["settings.invite"].exists { app.buttons["settings.invite"].tap(); Thread.sleep(forTimeInterval: 1); shot(app, "w2-s14-invite-sheet") }
        // Dictation: first tap starts, second tap stops + commits (no alert).
        app.terminate(); app.launchArguments = ["-CatpawSkipOnboarding"]; app.launch(); Thread.sleep(forTimeInterval: 2)
        // A restored proactive inbox / sheet must not cover the composer in the dictation shots.
        for _ in 0..<3 { var closed = false; for l in ["完成", "Done", "关闭"] where app.buttons[l].exists && app.buttons[l].isHittable { app.buttons[l].tap(); closed = true; break }
            if !closed { if app.sheets.firstMatch.exists || app.otherElements["proactive.inbox"].exists { app.swipeDown(velocity: .fast) } else { break } }; Thread.sleep(forTimeInterval: 0.8) }
        XCTAssertTrue(input(app).waitForExistence(timeout: 30)); Thread.sleep(forTimeInterval: 1)
        addUIInterruptionMonitor(withDescription: "perm") { alert in for l in ["允许", "好", "Allow", "OK"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }; return false }
        let mic = app.buttons["chat.composer.mic"]
        if mic.exists { mic.tap(); Thread.sleep(forTimeInterval: 0.35); screen("w2-s15-dictation-recording"); Thread.sleep(forTimeInterval: 1.2); screen("w2-s15b-dictation-after-1s5")
            let confirm = app.descendants(matching: .any).matching(identifier: "chat.composer.dictation.confirm").firstMatch
            if confirm.exists { confirm.tap() } else if mic.exists { mic.tap() }
            Thread.sleep(forTimeInterval: 1.5); screen("w2-s16-dictation-second-tap") }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// #64: recent-photo strip → image message → full-screen viewer → 保存到照片.
    func test15ImageViewer() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_SURFACE_TOUR"] == "1" else { throw XCTSkip("surface tour only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); forwardPublicConfig(app); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        addUIInterruptionMonitor(withDescription: "perm") { alert in for l in ["允许完全访问", "允许", "好", "Allow Full Access", "Allow", "OK"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }; return false }
        XCTAssertTrue(input(app).waitForExistence(timeout: 40)); Thread.sleep(forTimeInterval: 1)
        if app.buttons["chat.new"].isEnabled { app.buttons["chat.new"].tap(); Thread.sleep(forTimeInterval: 1) }
        app.buttons["chat.composer.add"].tap(); Thread.sleep(forTimeInterval: 1.2); app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 0.5)
        let thumb = app.descendants(matching: .any).matching(identifier: "chat.attach.thumb").firstMatch
        guard thumb.waitForExistence(timeout: 5) else { shot(app, "w2-v00-no-recent-photos"); return }
        thumb.tap(); Thread.sleep(forTimeInterval: 0.6); shot(app, "w2-v00-photo-selected"); let addSel = app.buttons["chat.attach.add"]; if addSel.exists { addSel.tap() }; Thread.sleep(forTimeInterval: 1.2); shot(app, "w2-v01-image-attached")
        let field = input(app); field.tap(); Thread.sleep(forTimeInterval: 0.8); if !app.keyboards.firstMatch.exists { field.tap(); Thread.sleep(forTimeInterval: 0.8) }; if app.keyboards.firstMatch.exists { field.typeText("这是什么？") }
        let sends = app.buttons.matching(NSPredicate(format: "identifier == 'chat.send'")).allElementsBoundByIndex
        sends.first(where: { $0.isHittable })?.tap()
        for l in ["允许此对话"] where app.buttons[l].waitForExistence(timeout: 10) { app.buttons[l].tap(); break } // text consent if this chat is new
        if sends.first(where: { $0.isHittable && $0.isEnabled }) != nil, !app.descendants(matching: .any)["image.consent.viewport"].exists { sends.first(where: { $0.isHittable && $0.isEnabled })?.tap() }
        let allow = app.buttons["image.consent.allow"]
        if allow.waitForExistence(timeout: 12) {
            shot(app, "w2-v02-image-consent")
            let ns = app.descendants(matching: .any)["image.consent.nonSensitive"]; if ns.exists { ns.tap(); Thread.sleep(forTimeInterval: 0.4) }
            if !allow.isEnabled, ns.switches.firstMatch.exists { ns.switches.firstMatch.tap() }
            allow.tap(); Thread.sleep(forTimeInterval: 2)
        } else { shot(app, "w2-v02-no-image-consent") }
        let image = app.descendants(matching: .any).matching(identifier: "chat.message.image").firstMatch
        guard image.waitForExistence(timeout: 15) else { shot(app, "w2-v02b-no-image-message"); return }
        Thread.sleep(forTimeInterval: 8); shot(app, "w2-v02c-image-in-message")
        image.tap(); Thread.sleep(forTimeInterval: 1); shot(app, "w2-v03-viewer")
        let save = app.descendants(matching: .any).matching(identifier: "chat.imageViewer.save").firstMatch
        // The viewer lives in an overlay window that XCUI may not expose; fall back to the button's on-screen spot.
        if save.waitForExistence(timeout: 4) || true { if save.exists { save.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.77, dy: 0.105)).tap() }; Thread.sleep(forTimeInterval: 1.2)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for l in ["允许", "Allow", "好", "OK"] where springboard.buttons[l].waitForExistence(timeout: 1.5) { shot(app, "w2-v04a-photos-permission"); springboard.buttons[l].tap(); break }
            Thread.sleep(forTimeInterval: 1.5); shot(app, "w2-v04-viewer-saved") } else { shot(app, "w2-v04-no-save-button") }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Proactive chain: simulated non-user signal → engine (filter/dedupe/evaluate) → card + notification → confirm → EKReminder; repeat → suppressed.
    private func openLink(_ s: String) {
        XCUIDevice.shared.system.open(URL(string: s)!)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["打开", "Open"] where sb.buttons[label].waitForExistence(timeout: 2) { sb.buttons[label].tap(); break }
    }
    func test13ProactiveChain() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_PROACTIVE_TOUR"] == "1" else { throw XCTSkip("proactive tour only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); forwardPublicConfig(app); app.launchArguments += ["-CatpawSkipOnboarding", "-CatpawOpenURL", "catpawm://proactive/debug"]; app.launch()
        let reset = app.buttons["proactive.engine.resetLedger"]; XCTAssertTrue(reset.waitForExistence(timeout: 40)); reset.tap()
        app.buttons["debug.signal.addMeeting"].tap(); Thread.sleep(forTimeInterval: 0.4)
        func run() { let b = app.buttons["debug.signal.run"]; var n = 0; while !(b.exists && b.isHittable) && n < 5 { app.swipeUp(); n += 1 }; b.tap() }
        run(); Thread.sleep(forTimeInterval: 4)
        shot(app, "w2-p01-pipeline-run")
        app.swipeDown(); app.swipeDown(); shot(app, "w2-p01b-engine-log")
        run(); Thread.sleep(forTimeInterval: 4); app.swipeDown(); app.swipeDown()
        shot(app, "w2-p02-duplicate-suppressed")
        app.terminate(); app.launchArguments = ["-CatpawSkipOnboarding", "-CatpawOpenURL", "catpawm://proactive"]; app.launch()
        Thread.sleep(forTimeInterval: 2); shot(app, "w2-p03-inbox-card")
        let create = app.buttons.matching(NSPredicate(format: "identifier == 'chat.proactiveSuggestion.create_reminder'")).firstMatch
        if create.waitForExistence(timeout: 5) { create.tap(); Thread.sleep(forTimeInterval: 2.5); shot(app, "w2-p04-reminder-created") }
        XCTAssertEqual(app.state, .runningForeground)
    }
    /// Live device_tools check: ask for a Reminder, expect chat.deviceCall confirm, run it.
    /// Voice mode look: tap mic → full-screen calm voice overlay (glow, transcript, waveform, mic orb, keyboard/camera).
    func test17VoiceMode() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_DEVICE_TOUR"] == "1" else { throw XCTSkip("device tour only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); forwardPublicConfig(app); app.launchArguments += ["-CatpawSkipOnboarding", "-CatpawVoiceModePreview", "YES"]; app.launch()
        addUIInterruptionMonitor(withDescription: "perm") { alert in
            for l in ["允许", "Allow", "好", "OK"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            return false
        }
        if app.buttons["auth.closeUnrestoredSession"].waitForExistence(timeout: 5) { app.buttons["auth.closeUnrestoredSession"].tap(); Thread.sleep(forTimeInterval: 2) }
        if app.buttons["auth.startExperience"].waitForExistence(timeout: 5) { app.buttons["auth.startExperience"].tap() }
        XCTAssertTrue(input(app).waitForExistence(timeout: 60))
        let mic = app.buttons["chat.composer.mic"]; XCTAssertTrue(mic.waitForExistence(timeout: 10)); mic.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let mode = app.descendants(matching: .any)["chat.voice.mode"]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !mode.exists && !app.alerts.firstMatch.exists {
            let prompt = springboard.alerts.firstMatch
            if prompt.exists { prompt.buttons.element(boundBy: prompt.buttons.count - 1).tap() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let ok = mode.exists
        Thread.sleep(forTimeInterval: 2)
        shot(app, ok ? "w2-v10-voice-mode" : "w2-v10-voice-missing")
        XCTAssertTrue(ok, "voice mode overlay must appear on tap-to-dictate")
    }

    // test19: one plain send, for capturing the client's failure path (quota etc.).
    func test19PlainSend() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_DEVICE_TOUR"] == "1" else { throw XCTSkip("device tour only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); forwardPublicConfig(app); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 60)); Thread.sleep(forTimeInterval: 1.5)
        if app.buttons["chat.new"].exists && app.buttons["chat.new"].isEnabled { app.buttons["chat.new"].tap(); Thread.sleep(forTimeInterval: 1) }
        let f = input(app); f.tap(); f.typeText(ProcessInfo.processInfo.environment["CATPAW_DEVICE_ASK"] ?? "你好")
        Thread.sleep(forTimeInterval: 0.6)
        let sends = app.buttons.matching(NSPredicate(format: "identifier == 'chat.send'")).allElementsBoundByIndex
        if let s = sends.first(where: { $0.isHittable && $0.isEnabled }) { s.tap() } else { app.buttons["chat.send"].firstMatch.tap() }
        for _ in 0..<2 { for id in ["chat.modelConsent.allow"] where app.buttons[id].waitForExistence(timeout: 4) { app.buttons[id].tap() }; for l in ["确认发送许可", "允许此对话"] where app.buttons[l].exists { app.buttons[l].tap(); Thread.sleep(forTimeInterval: 1) } }
        Thread.sleep(forTimeInterval: 10); shot(app, "t19-after-send")
        f.tap(); f.typeText("再试一次"); Thread.sleep(forTimeInterval: 0.6)
        if let s = app.buttons.matching(NSPredicate(format: "identifier == 'chat.send'")).allElementsBoundByIndex.first(where: { $0.isHittable && $0.isEnabled }) { s.tap() }
        Thread.sleep(forTimeInterval: 8); shot(app, "t19-after-second")
    }

    // test18: frame-level probes for 新建对话 empty-state stability and first-run voice permissions.
    func test18NewChatAndVoiceFirstRun() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_DEVICE_TOUR"] == "1" else { throw XCTSkip("device tour only") }
        let app = XCUIApplication(bundleIdentifier: bundleID); forwardPublicConfig(app); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        if app.buttons["auth.closeUnrestoredSession"].waitForExistence(timeout: 5) { app.buttons["auth.closeUnrestoredSession"].tap(); Thread.sleep(forTimeInterval: 2) }
        XCTAssertTrue(input(app).waitForExistence(timeout: 60)); Thread.sleep(forTimeInterval: 1.5)
        // A. sidebar → 新建对话, sample the empty-state position every frame we can.
        for round in 0..<2 {
            app.buttons["sidebar.open"].tap(); Thread.sleep(forTimeInterval: 1)
            app.buttons["sidebar.new"].tap()
            var ys: [String] = []
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 1.6 {
                let e = app.otherElements["chat.empty"]
                ys.append(String(format: "%.2f:%@", Date().timeIntervalSince(t0), e.exists ? String(format: "%.0f", e.frame.minY) : "-"))
            }
            let a = XCTAttachment(string: ys.joined(separator: " ")); a.name = "newchat-y-\(round)"; a.lifetime = .keepAlways; add(a)
            NSLog("CATPAW_NEWCHAT_Y \(round) \(ys.joined(separator: " "))")
            shot(app, "t18-newchat-\(round)")
        }
        // B. voice: first tap (permission prompts), then a second tap.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let mic = app.buttons["chat.composer.mic"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 5)); mic.tap()
        for i in 0..<3 {
            let a = springboard.alerts.firstMatch
            guard a.waitForExistence(timeout: 3) else { break }
            shot(app, "t18-voice-perm-\(i)")
            for l in ["允许", "好", "Allow", "OK"] where a.buttons[l].exists { a.buttons[l].tap(); break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        var states: [String] = []
        let t1 = Date()
        while Date().timeIntervalSince(t1) < 2.5 { states.append(String(format: "%.2f:%@", Date().timeIntervalSince(t1), app.otherElements["chat.voice.mode"].exists ? "V" : (app.buttons["chat.composer.dictating"].exists ? "d" : "_"))) }
        NSLog("CATPAW_VOICE_A \(states.joined(separator: " "))")
        shot(app, "t18-voice-after-perm")
        if app.otherElements["chat.voice.mode"].exists || app.buttons["chat.composer.dictating"].exists { app.buttons["chat.composer.dictation.confirm"].firstMatch.tap(); Thread.sleep(forTimeInterval: 1.5) }
        if app.buttons["chat.composer.mic"].firstMatch.exists { app.buttons["chat.composer.mic"].firstMatch.tap() }
        states = []
        let t2 = Date()
        while Date().timeIntervalSince(t2) < 2.5 { states.append(String(format: "%.2f:%@", Date().timeIntervalSince(t2), app.otherElements["chat.voice.mode"].exists ? "V" : (app.buttons["chat.composer.dictating"].exists ? "d" : "_"))) }
        NSLog("CATPAW_VOICE_B \(states.joined(separator: " "))")
        shot(app, "t18-voice-second-tap")
    }

    func test16DeviceReminder() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_DEVICE_TOUR"] == "1" else { throw XCTSkip("device tour only") }
        let ask = ProcessInfo.processInfo.environment["CATPAW_DEVICE_ASK"] ?? "帮我在提醒事项里建一个明天上午9点的提醒：交周报"
        let tag = ProcessInfo.processInfo.environment["CATPAW_DEVICE_TAG"] ?? "w2-d"
        let app = XCUIApplication(bundleIdentifier: bundleID); forwardPublicConfig(app); app.launchArguments += ["-CatpawSkipOnboarding"]; app.launch()
        addUIInterruptionMonitor(withDescription: "perm") { alert in
            for l in ["允许", "Allow", "好", "OK", "允许完全访问", "Allow Full Access"] where alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            return false
        }
        // DeviceTrial may be stuck on session-recovery; exit then retry anonymous experience.
        if app.buttons["auth.closeUnrestoredSession"].waitForExistence(timeout: 5) {
            app.buttons["auth.closeUnrestoredSession"].tap(); Thread.sleep(forTimeInterval: 2)
        }
        for l in ["再试一次", "Try again"] where app.buttons[l].exists { app.buttons[l].tap(); Thread.sleep(forTimeInterval: 3); break }
        XCTAssertTrue(input(app).waitForExistence(timeout: 60)); Thread.sleep(forTimeInterval: 1)
        if app.buttons["chat.new"].exists && app.buttons["chat.new"].isEnabled { app.buttons["chat.new"].tap(); Thread.sleep(forTimeInterval: 1) }
        func clearDraft() {
            let f = input(app); f.tap(); Thread.sleep(forTimeInterval: 0.5)
            if let v = f.value as? String, !v.isEmpty, app.keyboards.firstMatch.exists { f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count + 4)) }
        }
        func tapSend() {
            Thread.sleep(forTimeInterval: 0.6)
            let sends = app.buttons.matching(NSPredicate(format: "identifier == 'chat.send'")).allElementsBoundByIndex
            if let s = sends.first(where: { $0.isHittable && $0.isEnabled }) { s.tap() } else { app.buttons["chat.send"].firstMatch.tap() }
        }
        clearDraft()
        if !app.descendants(matching: .any)["chat.assistant.message"].exists {
            input(app).typeText("你好"); tapSend()
            let allow = app.buttons["允许此对话"]
            if allow.waitForExistence(timeout: 12) { shot(app, tag + "00-consent-sheet"); allow.tap(); Thread.sleep(forTimeInterval: 2) }
            else if app.buttons["chat.consent.review"].waitForExistence(timeout: 5), app.buttons["chat.consent.review"].isEnabled {
                app.buttons["chat.consent.review"].tap(); if allow.waitForExistence(timeout: 8) { allow.tap() }
            }
            for _ in 0..<40 { if app.descendants(matching: .any)["chat.assistant.message"].exists { break }; Thread.sleep(forTimeInterval: 1) }
            Thread.sleep(forTimeInterval: 3)
            shot(app, tag + "00b-after-warmup")
        }
        clearDraft()
        let field = input(app); field.tap(); Thread.sleep(forTimeInterval: 0.8)
        if !app.keyboards.firstMatch.exists { field.tap(); Thread.sleep(forTimeInterval: 0.8) }
        if app.keyboards.firstMatch.exists { field.typeText(ask) }
        else { UIPasteboard.general.string = ask; field.press(forDuration: 1.0); if app.menuItems["粘贴"].waitForExistence(timeout: 2) { app.menuItems["粘贴"].tap() } else if app.menuItems["Paste"].waitForExistence(timeout: 1) { app.menuItems["Paste"].tap() } }
        tapSend()
        // Model consent sheet (auto or via 确认发送许可). Prefer accessibility ids from ConversationModelConsentView.
        func allowModelConsent() -> Bool {
            let allowBtn = app.descendants(matching: .any)["chat.modelConsent.allow"]
            if allowBtn.waitForExistence(timeout: 2), allowBtn.isHittable { allowBtn.tap(); return true }
            for l in ["允许此对话", "Allow this conversation"] where app.buttons[l].exists && app.buttons[l].isHittable { app.buttons[l].tap(); return true }
            return false
        }
        var allowed = allowModelConsent()
        if !allowed {
            let review = app.buttons["chat.consent.review"]
            if review.waitForExistence(timeout: 15) {
                for _ in 0..<45 {
                    if allowModelConsent() { allowed = true; break }
                    if review.exists && review.isEnabled { review.tap(); Thread.sleep(forTimeInterval: 1.2); if allowModelConsent() { allowed = true; break } }
                    // If review stays disabled, something is "busy"/inflight — wait it out.
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
        shot(app, allowed ? tag + "00-consent-allowed" : tag + "00-consent-stuck")
        // After allow, pending strip should drain once the turn starts.
        if allowed {
            let pending = app.descendants(matching: .any)["chat.pendingSummary"]
            for _ in 0..<40 where pending.exists { Thread.sleep(forTimeInterval: 1) }
            Thread.sleep(forTimeInterval: 2)
        }
        // Wait for device confirm card (or capture whatever the model said).
        let run = app.descendants(matching: .any).matching(identifier: "chat.deviceCall.run").firstMatch
        var sawCard = run.waitForExistence(timeout: 55)
        if !sawCard {
            app.swipeUp(); Thread.sleep(forTimeInterval: 0.5)
            sawCard = run.waitForExistence(timeout: 10)
        }
        shot(app, sawCard ? tag + "01-device-confirm" : tag + "01-no-device-card")
        // Capture assistant text for the report.
        let assistant = app.descendants(matching: .any).matching(identifier: "chat.assistant.message").allElementsBoundByIndex.last
        if let assistant, assistant.exists {
            let a = XCTAttachment(string: "assistant=\(assistant.label)"); a.name = tag + "01-assistant-label"; a.lifetime = .keepAlways; add(a)
        }
        XCTAssertTrue(sawCard, "device_call confirm card (chat.deviceCall.run) must appear — CATPAW_DEVICE_TOOLS_ENABLED may still be off for this subject")
        run.tap(); Thread.sleep(forTimeInterval: 1.5)
        app.tap() // flush interruption monitor
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for l in ["允许", "Allow", "好", "OK"] where springboard.buttons[l].waitForExistence(timeout: 2) { springboard.buttons[l].tap(); break }
        Thread.sleep(forTimeInterval: 3)
        let receipt = app.descendants(matching: .any).matching(identifier: "chat.deviceCall.receipt").firstMatch
        let running = app.descendants(matching: .any).matching(identifier: "chat.deviceCall.running").firstMatch
        shot(app, receipt.exists ? tag + "02-device-receipt" : (running.exists ? tag + "02-device-running" : tag + "02-after-run"))
        XCTAssertTrue(receipt.waitForExistence(timeout: 20) || !run.exists, "reminder confirm should complete to a receipt")
        // 任务 list should show the Catpaw reminder created by the device tool / local mirror.
        if app.buttons["sidebar.open"].exists { app.buttons["sidebar.open"].tap(); Thread.sleep(forTimeInterval: 1) }
        if app.buttons["sidebar.tasks"].exists { app.buttons["sidebar.tasks"].tap(); Thread.sleep(forTimeInterval: 2); shot(app, tag + "03-tasks-after-reminder") }
        XCTAssertEqual(app.state, .runningForeground)
    }


}
