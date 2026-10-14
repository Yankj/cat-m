import XCTest

final class ConversationArtifactReaderUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func launch(_ scenario:String)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario,"P0_PERF_RECORDING":"1"]
        if scenario.hasPrefix("p0-ui-large") || scenario=="p0-ui-genui-large" {app.launchEnvironment["CATPAW_UI_TEST_TEXT_SIZE"]="accessibility5"}
        app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12));XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:6))
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline");XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        return app
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {
        let value=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with:Data(value.utf8))) as? [String:Any] ?? [:]
    }
    private func wait(_ predicate:()->Bool,seconds:TimeInterval=12) {
        let until=Date().addingTimeInterval(seconds)
        while Date()<until {if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        XCTFail("Explicit synthetic reader condition timed out")
    }
    private func reveal(_ app:XCUIApplication,_ element:XCUIElement,conversation:Bool=false) {
        for _ in 0..<18 {
            let top=max(130,app.navigationBars.firstMatch.frame.maxY+12)
            var bottom=app.frame.height-36
            if app.keyboards.firstMatch.exists {bottom=min(bottom,app.keyboards.firstMatch.frame.minY-12)}
            if conversation,app.buttons["attachment.pick"].exists {bottom=min(bottom,app.buttons["attachment.pick"].frame.minY-12)}
            if conversation,app.buttons["chat.jumpToLatest"].exists {bottom=min(bottom,app.buttons["chat.jumpToLatest"].frame.minY-12)}
            let visible=element.exists ? min(element.frame.maxY,bottom)-max(element.frame.minY,top) : 0
            if element.exists && element.isHittable && visible>=min(44,element.frame.height) {return}
            XCTAssertGreaterThan(bottom-top,45,app.debugDescription)
            let middle=(top+bottom)/2
            let down=element.exists ? element.frame.midY<middle : conversation
            let distance=min(bottom-top-20,max(44,element.exists ? abs(element.frame.midY-middle) : bottom-top-20))
            let start=down ? top+10 : bottom-10,end=start+(down ? distance : -distance)
            let a=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:start/app.frame.height)),b=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:end/app.frame.height))
            a.press(forDuration:0.05,thenDragTo:b)
        }
        XCTAssertTrue(element.exists && element.isHittable,app.debugDescription)
    }
    private func openArtifact(_ app:XCUIApplication) {
        let open=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.artifact.open.")).firstMatch
        if !open.exists {
            let card=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Synthetic sourced report")).firstMatch
            reveal(app,card,conversation:true);XCTAssertTrue(card.waitForExistence(timeout:6),app.debugDescription);card.tap()
        }
        XCTAssertTrue(open.waitForExistence(timeout:5),app.debugDescription);reveal(app,open,conversation:true);open.tap()
        wait({app.staticTexts["chat.artifact.reader.version"].label=="v2"})
    }
    private func hashInReader(_ app:XCUIApplication)->String {
        let hash=app.staticTexts["chat.artifact.reader.hash"]
        if !hash.exists {
            let history=app.descendants(matching:.any).matching(identifier:"chat.artifact.reader.history").firstMatch
            XCTAssertTrue(history.waitForExistence(timeout:3),app.debugDescription);reveal(app,history);history.tap()
        }
        XCTAssertTrue(hash.waitForExistence(timeout:3),app.debugDescription)
        XCTAssertNotNil(hash.label.range(of:"^SHA-256 [a-f0-9]{64}$",options:.regularExpression))
        return hash.label
    }
    private func back(_ app:XCUIApplication) {
        let button=app.navigationBars.firstMatch.buttons.firstMatch;XCTAssertTrue(button.exists && button.isHittable,app.debugDescription);button.tap()
    }
    private func capture(_ app:XCUIApplication,_ name:String) {
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="Synthetic-source-reader-v19-"+name;attachment.lifetime = .keepAlways;add(attachment)
    }
    private func runReaderPath(_ scenario:String) {
        let app=launch(scenario),input=app.textViews["chat.input"]
        input.tap();let previous=input.value as? String ?? "";if !previous.isEmpty {input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:previous.utf16.count))}
        input.typeText("Synthetic immutable sourced report");app.buttons["chat.send"].tap()
        wait({self.probe(app)["turn_state"] as? String == "completed"})
        input.tap();input.typeText("Keep this unrelated chat draft")
        let draft=input.value as? String ?? "",draftHash=probe(app)["draft_hash"] as? String
        if scenario=="p0-ui-large-sourced-artifact" {
            // The existing sidebar action dismisses the keyboard without replacing the chat draft.
            app.buttons["sidebar.open"].tap()
            let close=app.buttons["sidebar.close"];XCTAssertTrue(close.waitForExistence(timeout:5));close.tap()
            wait({!app.keyboards.firstMatch.exists})
            XCTAssertEqual(input.value as? String,draft);XCTAssertEqual(probe(app)["draft_hash"] as? String,draftHash)
        }
        openArtifact(app)
        capture(app,"current-v2")
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.content"].label.contains("Synthetic immutable report version 2."))
        let sources=app.buttons["chat.artifact.reader.sources"];XCTAssertTrue(sources.waitForExistence(timeout:3));reveal(app,sources);sources.tap()
        let row=app.descendants(matching:.any).matching(identifier:"chat.artifact.source.source-1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:5),app.debugDescription)
        if scenario=="p0-ui-large-sourced-artifact" {
            let sourceBar=app.navigationBars.matching(NSPredicate(format:"identifier IN %@ OR label IN %@",["已读来源","Read sources"],["已读来源","Read sources"])).firstMatch
            XCTAssertTrue(sourceBar.waitForExistence(timeout:3),app.debugDescription)
            XCTAssertLessThan(sourceBar.frame.minY,app.frame.height*0.2,"Accessibility source navigation uses the large sheet")
            XCTAssertGreaterThan(row.frame.height,240,"Source rows inherit the reader's accessibility text size")
        }
        let sourceSheetCount=app.sheets.count;XCTAssertLessThanOrEqual(sourceSheetCount,1)
        row.tap()
        let readLink=app.links["chat.artifact.source.open"].exists ? app.links["chat.artifact.source.open"] : app.descendants(matching:.any).matching(identifier:"chat.artifact.source.open").firstMatch
        XCTAssertTrue(readLink.waitForExistence(timeout:5),app.debugDescription)
        if scenario=="p0-ui-large-sourced-artifact" {reveal(app,readLink);XCTAssertTrue(readLink.isHittable,app.debugDescription)}
        XCTAssertEqual(app.sheets.count,sourceSheetCount,"Source details push inside the same sheet")
        capture(app,"source-detail-single-sheet")
        // Opening an external URL is deliberately not part of the synthetic UI test.
        let detailBar=app.navigationBars.matching(NSPredicate(format:"identifier IN %@ OR label IN %@",["来源详情","Source details"],["来源详情","Source details"])).firstMatch
        XCTAssertTrue(detailBar.waitForExistence(timeout:3),app.debugDescription);detailBar.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout:3));app.buttons["chat.artifact.sources.close"].tap()
        wait({app.staticTexts["chat.artifact.reader.version"].label=="v2"})
        let currentHash=hashInReader(app)
        let old=app.descendants(matching:.any).matching(identifier:"chat.artifact.reader.history.v1").firstMatch
        XCTAssertTrue(old.waitForExistence(timeout:3));reveal(app,old);old.tap()
        wait({app.staticTexts["chat.artifact.reader.version"].label=="v1"})
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.content"].label.contains("Synthetic immutable report version 1."))
        let oldHash=hashInReader(app);XCTAssertNotEqual(oldHash,currentHash)
        capture(app,"immutable-history-v1")
        back(app);wait({app.staticTexts["chat.artifact.reader.version"].label=="v2"});XCTAssertEqual(app.staticTexts["chat.artifact.reader.hash"].label,currentHash)
        back(app);XCTAssertTrue(input.waitForExistence(timeout:5));XCTAssertEqual(input.value as? String,draft)
        wait({self.probe(app)["draft_hash"] as? String==draftHash})
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1);XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        capture(app,"return-preserves-draft-no-external-link")
    }
    func testRootReaderSourceSheetAndExactHistoryKeepDraft(){runReaderPath("p0-ui-sourced-artifact")}
    func testLargeTextReaderSourceNavigationAndHistoryKeepDraft(){runReaderPath("p0-ui-large-sourced-artifact")}
}
