import XCTest

/// Actual host and native HTTP adapter; explicitly synthetic loopback Auth/model/rows.
final class ConversationInboxUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private let port=8784
    private func wait(_ test:()->Bool,seconds:TimeInterval=25){let until=Date().addingTimeInterval(seconds);while Date()<until {if test(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))};XCTFail("Named cross-conversation native condition timed out")}
    private func probe(_ app:XCUIApplication)->[String:Any] {let raw=app.staticTexts["qa.p0Probe"].value as? String ?? "{}";return (try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [String:Any] ?? [:]}
    private func stats()->[String:Any] {
        let done=expectation(description:"Read local synthetic server counters");var result:[String:Any]=[:]
        URLSession.shared.dataTask(with:URL(string:"http://127.0.0.1:\(port)/testing/v1/stats")!){data,_,_ in if let data,let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{result=value["counters"] as? [String:Any] ?? [:]};done.fulfill()}.resume()
        wait(for:[done],timeout:6);return result
    }
    private func capture(_ app:XCUIApplication,_ name:String){let value=XCTAttachment(screenshot:app.screenshot());value.name="Synthetic-inbox37-"+name;value.lifetime = .keepAlways;add(value)}
    private func first(_ app:XCUIApplication,_ prefix:String)->XCUIElement {app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@",prefix)).firstMatch}
    private func back(_ app:XCUIApplication){let button=app.navigationBars.buttons.element(boundBy:0);XCTAssertTrue(button.waitForExistence(timeout:4));button.tap()}
    func testBInspectsAExactResultAndColdRestoresDraftWithoutNewDispatch() {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-accepted-work","CATPAW_ACCEPTED_WORK_PORT":String(port),"P0_PERF_RECORDING":"1"]
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US"]
        app.launch();let input=app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:15))
        input.tap();input.typeText("Organize these fictional notes as a local report for an offline inbox check.")
        app.buttons["chat.input.context.open"].tap();let review=app.buttons["chat.input.context.acceptedWork"];XCTAssertTrue(review.waitForExistence(timeout:5));review.tap()
        let confirm=app.buttons["chat.acceptedWork.confirm"];XCTAssertTrue(confirm.waitForExistence(timeout:6));wait({confirm.isEnabled});confirm.tap()
        let allow=app.buttons["chat.modelConsent.allow"];XCTAssertTrue(allow.waitForExistence(timeout:8));XCTAssertTrue(allow.isHittable);allow.tap()
        wait({self.probe(app)["turn_state"] as? String=="completed"})
        let originalConversation=probe(app)["conversation_id"] as? String,originalTurn=probe(app)["turn_id"] as? String
        let disclosure=first(app,"chat.goal.");XCTAssertTrue(disclosure.waitForExistence(timeout:10));disclosure.tap()
        let open=first(app,"chat.artifact.open.");XCTAssertTrue(open.waitForExistence(timeout:10));open.tap()
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.version"].waitForExistence(timeout:6));let originalVersion=app.staticTexts["chat.artifact.reader.version"].label
        app.staticTexts["chat.artifact.reader.history"].tap();let hash=app.staticTexts["chat.artifact.reader.hash"].label;XCTAssertTrue(hash.hasPrefix("SHA-256 "));capture(app,"original-A-exact-result")
        // The explicit DEBUG metrics HUD occupies the upper-right toolbar area.
        // Use the actual sidebar new-conversation route, outside that QA overlay.
        back(app);app.buttons["sidebar.open"].tap();let fresh=app.buttons["sidebar.new"];XCTAssertTrue(fresh.waitForExistence(timeout:5));fresh.tap()
        XCTAssertTrue(app.staticTexts["chat.empty"].waitForExistence(timeout:10),app.debugDescription)
        let raw="B unsent draft: keep punctuation, spaces and line breaks.\nStill unsent."
        input.tap();input.typeText(raw)
        wait({self.probe(app)["conversation_id"] as? String != originalConversation})
        let b=probe(app)["conversation_id"] as? String
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.results"].tap()
        let result=first(app,"inbox.artifact.");XCTAssertTrue(result.waitForExistence(timeout:10));let exactID=result.identifier
        let before=stats();result.tap()
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.version"].waitForExistence(timeout:10));XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,originalVersion)
        app.staticTexts["chat.artifact.reader.history"].tap();XCTAssertEqual(app.staticTexts["chat.artifact.reader.hash"].label,hash)
        XCTAssertEqual(probe(app)["conversation_id"] as? String,b);capture(app,"B-reading-A-same-version-hash")
        back(app);back(app);XCTAssertEqual(input.value as? String,raw)
        app.terminate();app.launch();XCTAssertTrue(input.waitForExistence(timeout:15));XCTAssertEqual(input.value as? String,raw)
        XCTAssertEqual(probe(app)["conversation_id"] as? String,b)
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.results"].tap();let same=app.descendants(matching:.any).matching(NSPredicate(format:"identifier == %@",exactID)).firstMatch;XCTAssertTrue(same.waitForExistence(timeout:10));same.tap()
        let original=app.buttons["inbox.return"];XCTAssertTrue(original.waitForExistence(timeout:8));XCTAssertGreaterThanOrEqual(original.frame.height,44);original.tap()
        wait({self.probe(app)["conversation_id"] as? String==originalConversation});XCTAssertEqual(probe(app)["turn_id"] as? String,originalTurn)
        let after=stats();for key in ["accepted_posts","memory_posts","provider_calls","turns"]{XCTAssertEqual(before[key] as? Int,after[key] as? Int,"Read/navigation must not increment "+key)}
        app.buttons["sidebar.open"].tap();let oldB=app.buttons["sidebar.conversation."+(b ?? "")];XCTAssertTrue(oldB.waitForExistence(timeout:6));oldB.tap();XCTAssertEqual(input.value as? String,raw);capture(app,"B-draft-returned-after-A-management")
    }
    func testLargestSystemTextReadsServerResultWithoutLocalAAndExplainsReturnLimit() {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-accepted-work","CATPAW_ACCEPTED_WORK_PORT":String(port),"P0_PERF_RECORDING":"1"]
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US"]
        app.launch();let input=app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:15))
        wait({self.probe(app)["input_system_category"] as? String != nil})
        XCTAssertEqual(probe(app)["input_system_category"] as? String,"UICTContentSizeCategoryAccessibilityXXXL","Requires the actual maximum system category without a fixture override")
        input.tap();input.typeText("B unsent draft")
        let before=stats()
        app.buttons["sidebar.open"].tap();let results=app.buttons["sidebar.results"];XCTAssertTrue(results.waitForExistence(timeout:6));results.tap()
        let result=first(app,"inbox.artifact.");XCTAssertTrue(result.waitForExistence(timeout:10));capture(app,"actual-maximum-result-list");result.tap()
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.version"].waitForExistence(timeout:10))
        let original=app.buttons["inbox.return"];XCTAssertTrue(original.waitForExistence(timeout:5));XCTAssertTrue(original.isHittable);XCTAssertGreaterThanOrEqual(original.frame.height,44);capture(app,"actual-maximum-result-fixed-return")
        original.tap();let message=app.staticTexts["The original conversation is not saved on this device. You can still read this result."]
        XCTAssertTrue(message.waitForExistence(timeout:10),app.debugDescription);capture(app,"actual-maximum-missing-local-history-limit")
        let after=stats();for key in ["accepted_posts","memory_posts","provider_calls","turns"]{XCTAssertEqual(before[key] as? Int,after[key] as? Int)}
        back(app);back(app);XCTAssertEqual(input.value as? String,"B unsent draft")
    }

}
