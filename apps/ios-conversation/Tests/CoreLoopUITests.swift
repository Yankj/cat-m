import XCTest

/// Integrate into the owner's UI test target only after explicit Simulator handoff.
/// Production case is read-only. Fixture cases never select a real provider or create a live identity.
final class CoreLoopUITests: XCTestCase {
    private let bundle = "com.example.CatpawM.OpenMuseDemo"
    private let fixtureBundle = "com.example.CatpawM.ConversationFirst.Auth"
    private func attach(_ app: XCUIApplication,_ name:String) {
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    private func value(_ element:XCUIElement,_ expected:String,timeout:TimeInterval=12) {
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@",expected),object:element)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:timeout),.completed)
    }
    func testExistingAnonymousTurnTerminalAndColdRestoreWithoutSending() throws {
        guard ProcessInfo.processInfo.environment["CATPAW_QA_READONLY_UI"] == "1" else { throw XCTSkip("Owner must hand off Simulator and explicitly select existing synthetic-only conversation") }
        continueAfterFailure=false
        let expected=ProcessInfo.processInfo.environment["CATPAW_QA_EXPECTED_FINAL"] ?? "CATPAW ANONYMOUS LIVE OK"
        let historyText=ProcessInfo.processInfo.environment["CATPAW_QA_EXISTING_TITLE"] ?? "Isolated synthetic integration check"
        let app=XCUIApplication(bundleIdentifier:bundle);app.launch()
        let input=app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:40))
        XCTAssertFalse(app.buttons["auth.startExperience"].exists);XCTAssertFalse(app.staticTexts["fixture.identity"].exists)
        // Select the already completed synthetic conversation; a newer task may be last selected.
        app.buttons["chat.history"].tap()
        let selected=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","chat.history.row.",historyText)).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout:10))
        let selectable=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:selected)
        XCTAssertEqual(XCTWaiter.wait(for:[selectable],timeout:20),.completed);selected.tap()
        let observe=app.buttons["chat.observe"]
        if observe.exists {
            let enabled=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:observe)
            XCTAssertEqual(XCTWaiter.wait(for:[enabled],timeout:20),.completed);observe.tap()
        }
        let answer=app.staticTexts.matching(identifier:"chat.assistantMessage").matching(NSPredicate(format:"label CONTAINS %@",expected)).firstMatch
        let terminal=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == true"),object:answer)
        let result=XCTWaiter.wait(for:[terminal],timeout:45);attach(app,"qa-existing-original-terminal")
        XCTAssertEqual(result,XCTWaiter.Result.completed,"A visible prefix is not the expected complete reply")
        XCTAssertEqual(answer.label.trimmingCharacters(in:.whitespacesAndNewlines),expected)
        let resolved=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.staticTexts["chat.unresolved"])
        XCTAssertEqual(XCTWaiter.wait(for:[resolved],timeout:15),.completed)
        app.buttons["chat.history"].tap()
        let row=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","chat.history.row.",historyText)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10));let originalRow=row.identifier;row.tap()
        XCTAssertTrue(app.staticTexts["chat.reply.completed"].exists)
        app.buttons["chat.history"].tap()
        let unknown=app.buttons["chat.history.row.ED2F017D-8078-4AB9-857E-8072215F1009"]
        XCTAssertTrue(unknown.waitForExistence(timeout:10));unknown.tap()
        XCTAssertTrue(app.staticTexts["chat.unresolved"].waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["chat.reply.completed"].exists,"An unknown original must never show the completed badge")
        attach(app,"qa-original-unknown-never-completed")
        app.buttons["chat.history"].tap();app.buttons[originalRow].tap()
        XCTAssertTrue(answer.waitForExistence(timeout:10))
        app.terminate();app.launch();XCTAssertTrue(input.waitForExistence(timeout:40))
        XCTAssertFalse(app.buttons["auth.startExperience"].exists);XCTAssertTrue(answer.waitForExistence(timeout:15));XCTAssertFalse(app.staticTexts["chat.unresolved"].exists)
        XCTAssertTrue(app.staticTexts["chat.reply.completed"].exists)
        app.buttons["chat.history"].tap();XCTAssertTrue(app.buttons[originalRow].waitForExistence(timeout:10));attach(app,"qa-existing-cold-restored-history")
        let proof:[String:Any]=["bundle":bundle,"same_history_row":originalRow,"complete_reply_visible":true,"unresolved_visible":false,"send_taps":0,"start_experience_taps":0,"credential_access":false,"identity_backend_verification":"owner must attach sanitized subject/scope equality; UI alone does not prove subject ID"]
        let evidence=XCTAttachment(data:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),uniformTypeIdentifier:"public.json");evidence.name="qa-readonly-cold-restore-proof";evidence.lifetime = .keepAlways;add(evidence)
    }
    private func fixture() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["CATPAW_QA_FIXTURE_UI"] == "1" else { throw XCTSkip("Requires isolated local synthetic auth fixture; not the production account") }
        let app=XCUIApplication(bundleIdentifier:fixtureBundle)
        app.launchEnvironment["R7_AUTH_TEST_STORE"]=UUID().uuidString
        app.launchEnvironment["R7_AUTH_TEST_SCENARIO"]="account-isolation"
        app.launch();let email=app.textFields["auth.email"]
        XCTAssertTrue(email.waitForExistence(timeout:15),"Fixture entry is required; stop if real production UI appears")
        email.tap();email.typeText("a.test@example.invalid");let password=app.secureTextFields["auth.password"];password.tap();password.typeText("fixture-only")
        app.buttons["auth.signIn"].tap();XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:15));return app
    }
    func testFixtureChineseDraftSwitchAndSheetDismissPreserveOriginalIDs() throws {
        continueAfterFailure=false;let app=try fixture(),input=app.textViews["chat.input"]
        let a="甲项目草稿：中文长句与ABC123，保留输入。",b="乙项目草稿：第二份输入。"
        input.tap();input.typeText(a);app.buttons["chat.new"].tap()
        let empty=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '' OR value == %@ OR value == nil","说说你想做的事…"),object:input)
        XCTAssertEqual(XCTWaiter.wait(for:[empty],timeout:12),.completed);input.tap();input.typeText(b)
        app.catpawOpenSettings();XCTAssertTrue(app.descendants(matching:.any)["connection.state"].waitForExistence(timeout:10));app.buttons["完成"].tap();value(input,b)
        app.buttons["chat.history"].tap()
        let aRow=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","chat.history.row.",a)).firstMatch
        let bRow=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","chat.history.row.",b)).firstMatch
        XCTAssertTrue(aRow.waitForExistence(timeout:10));XCTAssertTrue(bRow.exists);let aID=aRow.identifier,bID=bRow.identifier
        XCTAssertNotEqual(aID,bID);aRow.tap();value(input,a)
        app.buttons["chat.history"].tap();app.buttons["完成"].tap();value(input,a)
        app.buttons["chat.history"].tap();app.buttons[bID].tap();value(input,b);attach(app,"qa-fixture-two-drafts-return")
        app.terminate();app.launchEnvironment["R7_AUTH_TEST_SCENARIO"]="cold-valid";app.launch();XCTAssertTrue(input.waitForExistence(timeout:20));value(input,b)
        app.buttons["chat.history"].tap();XCTAssertTrue(app.buttons[aID].waitForExistence(timeout:10));XCTAssertTrue(app.buttons[bID].exists);attach(app,"qa-fixture-cold-two-original-drafts")
        XCTAssertEqual(app.tabBars.count,0)
    }
    func testFixtureRepeatedSendOnUnconfiguredProviderRetainsDraftAndCreatesNoReply() throws {
        continueAfterFailure=false;let app=try fixture(),input=app.textViews["chat.input"],text="帮我完成一个独立合成测试的小报告，不连接模型。"
        input.tap();input.typeText(text)
        XCTAssertEqual(input.value as? String,text,"Natural task wording enters through the native conversation input")
        let send=app.buttons["chat.send"];XCTAssertTrue(send.isEnabled);send.tap();if send.isEnabled { send.tap() }
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout:10));value(input,text)
        XCTAssertEqual(app.staticTexts.matching(identifier:"chat.userMessage").count,0);XCTAssertEqual(app.staticTexts.matching(identifier:"chat.assistantMessage").count,0)
        app.buttons["chat.history"].tap();XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label CONTAINS %@",text)).firstMatch.waitForExistence(timeout:10));attach(app,"qa-fixture-double-send-preflight-retained")
    }
}
