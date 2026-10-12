import XCTest
import CryptoKit

/// Exercises visible native controls against the real local store, without injecting fixture data.
/// Generated names are test-only local content. No permissions or external actions are requested.
final class NativeUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.example.CatpawM")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    func testNativeMainChainAndRestart() throws {
        home()
        capture("02-home-native")
        app.buttons["root.newConversation"].tap()
        let input = app.textFields["conversation.input"]
        let multiline = app.textViews["conversation.input"]
        let composer = input.waitForExistence(timeout: 10) ? input : multiline
        XCTAssertTrue(composer.waitForExistence(timeout: 10), app.debugDescription)
        let token = String(UUID().uuidString.prefix(8))
        let prompt = "Native smoke \(token)"
        composer.tap(); composer.typeText(prompt)
        app.buttons["conversation.send"].tap()
        let result = app.buttons["conversation.document"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        capture("03-conversation-fixture-completed")
        visible(result); result.tap()
        let version = app.descendants(matching: .any)["document.version"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(version.label.contains("v1"), version.label)
        capture("04-reader-v1")
        let edit = app.buttons["document.edit"]
        visible(edit); edit.tap()
        let editor = app.textViews["document.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.press(forDuration: 1.2)
        let selectAll = app.buttons["全选"].exists ? app.buttons["全选"] : app.menuItems["全选"].exists ? app.menuItems["全选"] : app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "A real Select All action is required for whole-document replacement")
        selectAll.tap()
        let revision = "# Native revision \(token)\nv2 persisted locally."
        editor.typeText(revision)
        XCTAssertEqual(editor.value as? String, revision, "The editor must contain only the replacement text")
        visible(edit); edit.tap()
        XCTAssertTrue(app.staticTexts["Native revision \(token)"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["document.version"].firstMatch.label.contains("v2"))
        let digest = SHA256.hash(data: Data(revision.utf8)).map { String(format: "%02x", $0) }.joined()
        assertReaderHash(digest)
        capture("05-reader-v2")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Native revision \(token)"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["document.version"].firstMatch.label.contains("v2"))
        assertReaderHash(digest)
        capture("06-restart-v2-preserved")

        home(); openSidebar("sidebar.folder")
        visible(app.buttons["projects.create"]); app.buttons["projects.create"].tap()
        let project = "Native project \(token)"
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 5))
        app.alerts.textFields.firstMatch.typeText(project)
        app.alerts.buttons["创建"].tap()
        let projectLink = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", project)).firstMatch
        XCTAssertTrue(projectLink.waitForExistence(timeout: 10), app.debugDescription)
        capture("07-project-created")

        home(); visible(app.buttons["assistant.createDelegation"]); app.buttons["assistant.createDelegation"].tap()
        let goal = app.textViews["delegation.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        goal.tap(); goal.typeText("Native delegation \(token)")
        app.buttons["保存约定"].tap()
        let run = app.buttons["delegation.runFixture"]
        XCTAssertTrue(run.waitForExistence(timeout: 10), app.debugDescription)
        visible(run); run.tap()
        let read = app.buttons["阅读与修改"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        capture("08-delegation-artifact")
        visible(app.buttons["暂停"]); app.buttons["暂停"].tap()
        XCTAssertTrue(app.buttons["恢复"].waitForExistence(timeout: 10))
        XCTAssertFalse(run.exists)
        app.buttons["恢复"].tap()
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        visible(read); read.tap()
        XCTAssertTrue(app.descendants(matching: .any)["document.version"].firstMatch.waitForExistence(timeout: 10))
        capture("09-delegation-reader")
    }

    func testProfileSwitchReaderAtCurrentDynamicType() throws {
        executionTimeAllowance = 120
        home(); app.buttons["root.sidebar"].tap()
        app.segmentedControls.buttons["本机"].tap()
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8))
        openSidebar("sidebar.gearshape")
        let demo = app.switches["演示数据分区"]
        visible(demo); XCTAssertEqual(demo.value as? String, "0")
        demo.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8))
        openSidebar("sidebar.folder")
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "默认项目 · 本机")).firstMatch
        visible(project); project.tap()
        let csv = app.buttons["虚构工作量.csv"]
        visible(csv); csv.tap()
        let table = app.scrollViews["表格，可左右滚动查看所有列"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 6))
        capture("dynamic-csv-initial")
        table.swipeLeft(); table.swipeLeft(); capture("dynamic-csv-last-columns")
        XCTAssertTrue(app.staticTexts["Difference"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let markdown = app.buttons["阅读器示例.md"]
        visible(markdown); markdown.tap()
        XCTAssertTrue(app.staticTexts["本地阅读器示例"].waitForExistence(timeout: 6))
        visible(app.buttons["document.edit"]); capture("dynamic-reader-actions")
        home(); openSidebar("sidebar.gearshape")
        visible(demo); XCTAssertEqual(demo.value as? String, "1")
        demo.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        let restored = app.buttons["root.sidebar"].waitForExistence(timeout: 8)
        capture("dynamic-user-profile-after-toggle")
        XCTAssertTrue(restored, "Profile switch must expose a usable home immediately")
        app.buttons["root.sidebar"].tap(); app.segmentedControls.buttons["云端"].tap()
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8))
    }

    @MainActor func testLocalGatewayChatAndReadonlyArtifactSync() async throws {
        do {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8787/v1/capabilities")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw XCTSkip("Run the explicit synthetic native-ui-server harness first") }
        } catch { throw XCTSkip("Local synthetic UI server is unavailable: \(error.localizedDescription)") }
        home(); app.buttons["root.sidebar"].tap(); app.segmentedControls.buttons["本机"].tap()
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8))
        openSidebar("sidebar.gearshape")
        let demo = app.switches["演示数据分区"]
        visible(demo); XCTAssertEqual(demo.value as? String, "0")
        demo.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8))
        openSidebar("sidebar.gearshape")
        let gateway = app.buttons["settings.localGateway"]
        visible(gateway); gateway.tap()
        app.buttons["gateway.probe"].tap()
        XCTAssertTrue(app.staticTexts["合成 Gateway 已连接 · 真实调用关闭"].waitForExistence(timeout: 10))
        app.buttons["gateway.sync"].tap()
        XCTAssertTrue(app.staticTexts["合成成果已保存到演示分区"].waitForExistence(timeout: 10))
        capture("gateway-native-sync")
        app.buttons["gateway.newConversation"].tap()
        let input = app.textFields["conversation.input"].waitForExistence(timeout: 5) ? app.textFields["conversation.input"] : app.textViews["conversation.input"]
        input.tap(); input.typeText("Gateway UI synthetic \(UUID().uuidString.prefix(8))")
        app.buttons["conversation.send"].tap()
        let result = app.buttons["conversation.document"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        capture("gateway-native-chat-completed")
        visible(result); result.tap()
        XCTAssertTrue(app.descendants(matching: .any)["document.version"].firstMatch.waitForExistence(timeout: 8))
        capture("gateway-native-chat-reader")
        home()
        let delegation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant.delegation.", "Gateway UI 合成约定")).firstMatch
        visible(delegation); delegation.tap()
        let artifact = app.buttons["gateway.artifact"].firstMatch
        visible(artifact); artifact.tap()
        XCTAssertTrue(app.descendants(matching: .any)["document.version"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["document.edit"].exists, "Service-owned artifact is read-only")
        capture("gateway-native-service-artifact")
        let savedVersion = app.descendants(matching: .any)["document.version"].firstMatch.label
        app.terminate(); app.launch()
        // Demo mode is opt-in on each launch; re-enter visibly without resetting its store.
        home(); openSidebar("sidebar.gearshape"); visible(demo)
        XCTAssertEqual(demo.value as? String, "0")
        demo.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8))
        visible(delegation); delegation.tap(); visible(artifact); artifact.tap()
        XCTAssertTrue(app.descendants(matching: .any)["document.version"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(app.descendants(matching: .any)["document.version"].firstMatch.label, savedVersion)
        XCTAssertFalse(app.buttons["document.edit"].exists)
        home(); openSidebar("sidebar.gearshape"); visible(demo)
        demo.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8))
    }

    func testContrastKeyboardAndApprovalAtCurrentDynamicType() throws {
        executionTimeAllowance = 360
        for (theme, choice) in [("light", "浅色 · 本地补充"), ("dark", "深色")] {
            home(); openSidebar("sidebar.gearshape")
            let picker = app.buttons["settings.theme"]
            visible(picker); picker.tap()
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons[choice].tap(); home()
            app.buttons["root.newConversation"].tap()
            let input = app.textFields["conversation.input"].waitForExistence(timeout: 5) ? app.textFields["conversation.input"] : app.textViews["conversation.input"]
            captureRegions("contrast-\(theme)-placeholder", [("placeholder", input)])
            input.tap(); input.typeText("Contrast \(UUID().uuidString.prefix(8))")
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            let send = app.buttons["conversation.send"]
            XCTAssertTrue(input.isHittable && send.isHittable, app.debugDescription)
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1, "Send must remain above the keyboard")
            XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY + 1, "Draft must remain above the keyboard")
            captureRegions("contrast-\(theme)-keyboard", [("input", input), ("send", send), ("keyboard", keyboard)])
            send.tap()
            XCTAssertTrue(app.buttons["conversation.document"].firstMatch.waitForExistence(timeout: 15))

            home(); visible(app.buttons["assistant.createDelegation"]); app.buttons["assistant.createDelegation"].tap()
            let goal = app.textViews["delegation.goal"]
            XCTAssertTrue(goal.waitForExistence(timeout: 5)); goal.tap(); goal.typeText("Contrast approval \(UUID().uuidString.prefix(8))")
            app.buttons["保存约定"].tap()
            let run = app.buttons["delegation.runFixture"]
            visible(run); run.tap()
            XCTAssertTrue(app.buttons["阅读与修改"].firstMatch.waitForExistence(timeout: 10))
            let end = app.buttons["结束委托"]
            for _ in 0..<8 { if end.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(end.isEnabled && end.isHittable)
            captureRegions("contrast-\(theme)-delegation-controls", [("end", end)])
            let operation = app.buttons["单次模拟操作"].firstMatch
            visible(operation); operation.tap()
            let preview = app.buttons["预览单次模拟外发"]
            visible(preview); preview.tap()
            let version = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "版本 v")).firstMatch
            XCTAssertTrue(version.waitForExistence(timeout: 10))
            visible(version); captureRegions("contrast-\(theme)-approval-version", [("version", version)])
            let warning = app.staticTexts["不会向外部应用发送内容。"]
            visible(warning); captureRegions("contrast-\(theme)-approval-warning", [("warning", warning)])
            let confirm = app.buttons["确认模拟受理"]
            visible(confirm); XCTAssertTrue(confirm.isEnabled)
            captureRegions("contrast-\(theme)-approval-confirm", [("confirm", confirm)])
            app.buttons["取消"].tap(); home()
            let needed = app.staticTexts["需要你确认"]
            for _ in 0..<8 { if needed.exists && needed.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(needed.isHittable)
            XCTAssertLessThan(needed.frame.minY, app.frame.height / 2)
            captureRegions("contrast-\(theme)-home-confirmation-first", [("confirmation", needed)])
        }
    }

    private func captureRegions(_ name: String, _ regions: [(String, XCUIElement)]) {
        let values: [[String: Any]] = regions.map { key, element in
            let frame = element.frame
            return ["name": key, "label": element.label, "rect_points": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]]
        }
        let payload: [String: Any] = ["screen_points": [Double(app.frame.width), Double(app.frame.height)], "regions": values]
        let bytes = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let attachment = XCTAttachment(string: String(decoding: bytes, as: UTF8.self))
        attachment.name = name + "-regions"; attachment.lifetime = .keepAlways; add(attachment)
        capture(name)
    }

    private func home(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if app.buttons["root.sidebar"].exists { return }
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
            back.tap()
        }
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
    }

    private func openSidebar(_ identifier: String) {
        app.buttons["root.sidebar"].tap()
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        visible(item); item.tap()
    }

    private func visible(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<8 { if element.exists && element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription, file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func assertReaderHash(_ digest: String) {
        let hash = app.staticTexts["SHA-256 \(digest)"]
        if !hash.exists {
            let details = app.buttons["文件校验信息"]
            visible(details); details.tap()
        }
        XCTAssertTrue(hash.waitForExistence(timeout: 5), "Reader hash must match the exact replacement bytes")
    }
}

// Integrate into the existing CatpawMUITests iOS UI Testing Bundle. No app source changes required.
// All cases require explicit Simulator handoff and scoped QA data writes authorization.
import XCTest

final class CatpawAcceptanceUITests: XCTestCase {
    @MainActor private func start() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        // Running this UI suite is a deliberate local test action; retain existing App data.
        let app = XCUIApplication(bundleIdentifier: env["CATPAW_UI_BUNDLE_ID"] ?? "com.example.CatpawM")
        app.launch()
        continueAfterFailure = false
        // Native route restoration is preserved. Navigate back visibly; never wipe UserDefaults.
        for _ in 0..<8 {
            if app.buttons["root.sidebar"].exists { break }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: 2) else { break }
            back.tap()
        }
        XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 8), "Expected Chinese home. Select Chinese manually first if a previous test changed language.")
        evidence(app, "launch")
        return app
    }

    @MainActor private func evidence(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-screen"; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
    }
    @MainActor private func composer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["conversation.input"]
        if field.exists { return field }
        return app.textViews["conversation.input"]
    }
    @MainActor private func reach(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<7 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Element not reachable: \(element)", file: file, line: line)
    }
    @MainActor private func newConversation(_ app: XCUIApplication) {
        app.buttons["root.newConversation"].tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
    }
    @MainActor private func openScenario(_ scenario: String, in app: XCUIApplication) {
        app.buttons["conversation.more"].tap()
        let chooser = app.buttons["conversation.scenarios"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 3)); chooser.tap()
        let titles = ["failure": "明确失败", "unexpectedEOF": "缺少完成事件", "cancelled": "已取消", "unknown": "结果未知", "success": "成功完成"]
        let named = app.buttons[titles[scenario] ?? scenario]
        let identified = app.buttons["conversation.scenario.\(scenario)"]
        // UIKit-backed nested menus expose visible titles on this runtime.
        let item = identified.exists ? identified : named
        XCTAssertTrue(item.waitForExistence(timeout: 3), app.debugDescription); item.tap()
    }
    @MainActor private func taskLink(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "进度 · ")).firstMatch
    }
    @MainActor private func assertOneSubmission(_ app: XCUIApplication, name: String) {
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "你: ")).count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "助理 · 模拟回复")).count, 1)
        reach(taskLink(app), in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "进度 · ")).count, 1)
        evidence(app, name)
    }

    // U01 / F01: real route entries and back, no bottom navigation.
    @MainActor func testSidebarRoutesAndCloseWithoutBottomTabBar() throws {
        let app = try start()
        XCTAssertEqual(app.tabBars.count, 0)
        app.buttons["root.sidebar"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 3))
        evidence(app, "U01-sidebar")
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["root.sidebar"].isHittable)
        for (entry, title) in [("sidebar.clock", "定时任务"), ("sidebar.brain.head.profile", "专家"), ("sidebar.books.vertical", "技能"), ("sidebar.checklist", "任务"), ("sidebar.folder", "项目"), ("sidebar.gearshape", "设置")] {
            app.buttons["root.sidebar"].tap()
            reach(app.buttons[entry], in: app); app.buttons[entry].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 4))
            XCTAssertEqual(app.tabBars.count, 0); evidence(app, "U01-\(entry)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 3))
        }
    }

    // U02 / F03,F06: a real double tap while keyboard is visible.
    @MainActor func testEmptySendAndRapidDoubleTapCreateOneSubmission() throws {
        let app = try start(); newConversation(app)
        let send = app.buttons["conversation.send"]
        XCTAssertFalse(send.isEnabled)
        let field = composer(app); field.tap(); field.typeText("U02 中文重复点击 \(UUID().uuidString.prefix(8))")
        XCTAssertTrue(send.isHittable, "Keyboard must not cover send")
        send.doubleTap()
        XCTAssertTrue(app.buttons["conversation.document"].firstMatch.waitForExistence(timeout: 10))
        assertOneSubmission(app, name: "U02-double-send")
    }

    // U03/U04/U05 / F06: each negative provider scenario must be visible and recoverable.
    @MainActor private func failThenRetry(_ scenario: String, name: String) throws {
        let app = try start(); newConversation(app); openScenario(scenario, in: app)
        composer(app).tap(); composer(app).typeText("\(name) 中文原请求 \(UUID().uuidString.prefix(8))")
        app.buttons["conversation.send"].tap()
        let state = scenario == "cancelled" ? "已取消" : "回复未完成"
        XCTAssertTrue(app.staticTexts[state].waitForExistence(timeout: 10))
        assertOneSubmission(app, name: "\(name)-terminal")
        let link = taskLink(app); reach(link, in: app); link.tap()
        let retry = app.buttons["按原请求快照重试模拟运行"]
        XCTAssertTrue(retry.waitForExistence(timeout: 4)); reach(retry, in: app)
        evidence(app, "\(name)-before-retry"); retry.tap()
        XCTAssertTrue(app.staticTexts["本轮已完成 · 模拟"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["打开成果 v1"].exists)
        evidence(app, "\(name)-after-retry")
        reach(app.buttons["回到会话"], in: app); app.buttons["回到会话"].tap()
        assertOneSubmission(app, name: "\(name)-same-conversation")
    }
    @MainActor func testFailureShowsPartialReplyAndRetry() throws { try failThenRetry("failure", name: "U03") }
    @MainActor func testUnexpectedEOFIsNotCompletionAndRetryWorks() throws { try failThenRetry("unexpectedEOF", name: "U04") }
    @MainActor func testProviderCancelledThenRetryWorks() throws { try failThenRetry("cancelled", name: "U05") }

    // U06: outcomeUnknown is not success and offers no blind retry. It is not a remote receipt.
    @MainActor func testUnknownShowsNoRetryAndNoSuccessResult() throws {
        let app = try start(); newConversation(app); openScenario("unknown", in: app)
        composer(app).tap(); composer(app).typeText("U06 结果未知 \(UUID().uuidString.prefix(8))")
        app.buttons["conversation.send"].tap()
        XCTAssertTrue(app.staticTexts["回复未完成"].waitForExistence(timeout: 10))
        let link = taskLink(app); reach(link, in: app); link.tap()
        XCTAssertTrue(app.staticTexts["结果未知，先核验 · 模拟"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["按原请求快照重试模拟运行"].exists)
        XCTAssertFalse(app.buttons["打开成果 v1"].exists)
        evidence(app, "U06-unknown")
    }

    // U07 / F03,F07: sheet close and relaunch restore the unsubmitted Chinese draft.
    @MainActor func testConfigurationCloseAndRelaunchKeepChineseDraft() throws {
        let app = try start(); newConversation(app)
        let draft = "U07 未发送中文草稿\n项目切换前保留 🐈 \(UUID().uuidString.prefix(8))"
        composer(app).tap(); composer(app).typeText(draft)
        app.buttons["配置"].tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 3))
        app.buttons["完成"].tap()
        XCTAssertEqual(composer(app).value as? String, draft)
        evidence(app, "U07-after-sheet-close")
        XCUIDevice.shared.press(.home) // exercise the scene suspend path before process termination
        app.terminate(); app.launch()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertEqual(composer(app).value as? String, draft)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "你: ")).count, 0)
        evidence(app, "U07-after-relaunch")
    }

    // U08: repeated close/cancel must not silently create a persisted delegation.
    @MainActor func testDelegationFormCancelTwiceCreatesNothing() throws {
        let app = try start()
        let baseline = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "项")).allElementsBoundByIndex.map(\.label)
        for i in 1...2 {
            reach(app.buttons["assistant.createDelegation"], in: app); app.buttons["assistant.createDelegation"].tap()
            XCTAssertTrue(app.textViews["delegation.goal"].waitForExistence(timeout: 3))
            app.textViews["delegation.goal"].tap(); app.textViews["delegation.goal"].typeText("U08 应取消的约定 \(i)")
            evidence(app, "U08-before-cancel-\(i)")
            app.buttons["取消"].tap()
            XCTAssertTrue(app.buttons["root.sidebar"].waitForExistence(timeout: 3))
        }
        let after = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "项")).allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(after, baseline)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "U08 应取消的约定")).firstMatch.exists)
        evidence(app, "U08-cancelled-no-delegation")
    }

    // U09: open/close voice UI without authorizing anything; never dismiss OS alerts automatically.
    @MainActor func testOpeningVoiceSheetDoesNotRequestSystemPermission() throws {
        let app = try start(); newConversation(app)
        app.buttons["口述输入"].tap()
        XCTAssertTrue(app.staticTexts["说给助理听"].waitForExistence(timeout: 4))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertEqual(springboard.alerts.count, 0, "Opening a sheet must not request OS permissions")
        evidence(app, "U09-voice-open-no-grant")
        app.buttons["改用文字"].tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 3))
    }

    // U10: use long fixture input so the actual cancel control has a deterministic click window.
    @MainActor func testActualCancelButtonThenRetryKeepsOneSubmission() throws {
        let app = try start(); newConversation(app)
        let text = (0..<30).map { "U10 cancel-window line \($0)" }.joined(separator: "\n")
        composer(app).tap(); composer(app).typeText(text)
        app.buttons["conversation.send"].tap()
        let link = taskLink(app); XCTAssertTrue(link.waitForExistence(timeout: 5)); reach(link, in: app); link.tap()
        let cancel = app.buttons["取消模拟运行"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "A completed fixture is not a cancel-operation pass")
        reach(cancel, in: app); evidence(app, "U10-before-real-cancel"); cancel.tap()
        XCTAssertTrue(app.staticTexts["已取消 · 模拟"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["打开成果 v1"].exists)
        evidence(app, "U10-real-cancelled")
        let retry = app.buttons["按原请求快照重试模拟运行"]
        reach(retry, in: app); retry.tap()
        XCTAssertTrue(app.staticTexts["本轮已完成 · 模拟"].waitForExistence(timeout: 15))
        reach(app.buttons["回到会话"], in: app); app.buttons["回到会话"].tap()
        assertOneSubmission(app, name: "U10-cancel-retry-one-submission")
    }

    // U11: one rapid double tap is one UI intent, not two requested preparations.
    @MainActor func testDelegationRapidDoubleTapDoesNotCreateTwoArtifacts() throws {
        let app = try start(); let token = String(UUID().uuidString.prefix(8))
        reach(app.buttons["assistant.createDelegation"], in: app); app.buttons["assistant.createDelegation"].tap()
        let goal = app.textViews["delegation.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 4)); goal.tap(); goal.typeText("QA U11 repeat \(token)")
        app.buttons["保存约定"].tap()
        let run = app.buttons["delegation.runFixture"]
        XCTAssertTrue(run.waitForExistence(timeout: 5)); reach(run, in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == %@", "阅读与修改")).count, 0)
        run.doubleTap()
        XCTAssertTrue(app.buttons["阅读与修改"].firstMatch.waitForExistence(timeout: 5))
        let settled = expectation(description: "double tap admission/render window settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        evidence(app, "U11-after-double-prepare")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == %@", "阅读与修改")).count, 1, "Rapid double tap unexpectedly admitted two local preparations")
    }

    // U12: visible revocation and pause survive app restart; resumed output excludes that source.
    @MainActor func testSourceRevocationAndPausedDelegationSurviveRelaunch() throws {
        let app = try start(); let token = String(UUID().uuidString.prefix(8))
        reach(app.buttons["assistant.createDelegation"], in: app); app.buttons["assistant.createDelegation"].tap()
        let goal = app.textViews["delegation.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 4)); goal.tap(); goal.typeText("QA U12 revoke \(token)")
        app.buttons["保存约定"].tap()
        XCTAssertTrue(app.buttons["delegation.runFixture"].waitForExistence(timeout: 5))
        let sources = app.buttons["来源与分项权限"]
        reach(sources, in: app); sources.tap()
        let url = "https://example.invalid/U12-\(token)"
        let field = app.textFields["http(s) 来源"]
        reach(field, in: app); field.tap(); field.typeText(url)
        let addSource = app.buttons["添加来源配置"]
        reach(addSource, in: app); addSource.tap()
        let permission = app.switches["允许用于后续模拟准备"].firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 5)); reach(permission, in: app); permission.tap()
        XCTAssertEqual(permission.value as? String, "0")
        evidence(app, "U12-source-revoked")
        app.terminate(); app.launch() // new view instance, no lingering URL-field keyboard focus
        XCTAssertTrue(app.buttons["delegation.runFixture"].waitForExistence(timeout: 8))
        for _ in 0..<6 { if app.buttons["暂停"].isHittable { break }; app.swipeDown() }
        app.buttons["暂停"].tap()
        XCTAssertTrue(app.buttons["恢复"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["delegation.runFixture"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["恢复"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["delegation.runFixture"].exists)
        evidence(app, "U12-paused-after-relaunch")
        app.buttons["恢复"].tap(); let run = app.buttons["delegation.runFixture"]
        XCTAssertTrue(run.waitForExistence(timeout: 5)); reach(run, in: app); run.tap()
        let read = app.buttons["阅读与修改"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 5)); reach(read, in: app); read.tap()
        XCTAssertTrue(app.descendants(matching: .any)["document.version"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", url)).firstMatch.exists)
        evidence(app, "U12-resumed-reader-excludes-source")
    }


}
