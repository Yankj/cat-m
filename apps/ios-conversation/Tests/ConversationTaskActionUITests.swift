import XCTest

final class ConversationTaskActionUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func launch(_ scenario:String)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario,"P0_PERF_RECORDING":"1"]
        if scenario.hasPrefix("p0-ui-large") || scenario=="p0-ui-genui-large" {app.launchEnvironment["CATPAW_UI_TEST_TEXT_SIZE"]="accessibility5"}
        app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12));XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:6))
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline");XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        return app
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {let text=app.staticTexts["qa.p0Probe"].value as? String ?? "{}";return (try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any] ?? [:]}
    private func wait(_ predicate:()->Bool,seconds:TimeInterval=15){let until=Date().addingTimeInterval(seconds);while Date()<until {if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))};XCTFail("Explicit offline action fixture condition timed out")}
    private func element(_ app:XCUIApplication,_ prefix:String)->XCUIElement {app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@",prefix)).firstMatch}
    private func reveal(_ app:XCUIApplication,_ value:XCUIElement,conversation:Bool=false) {
        for _ in 0..<20 {
            let top=max(130,app.navigationBars.firstMatch.frame.maxY+12);var bottom=app.frame.height-36
            if app.keyboards.firstMatch.exists {bottom=min(bottom,app.keyboards.firstMatch.frame.minY-12)}
            if conversation,app.buttons["attachment.pick"].exists {bottom=min(bottom,app.buttons["attachment.pick"].frame.minY-12)}
            if conversation,app.buttons["chat.jumpToLatest"].exists {bottom=min(bottom,app.buttons["chat.jumpToLatest"].frame.minY-12)}
            let visible=value.exists ? min(value.frame.maxY,bottom)-max(value.frame.minY,top):0
            if value.exists && value.isHittable && visible>=min(value.frame.height,44) {return}
            XCTAssertGreaterThan(bottom-top,45,app.debugDescription)
            let middle=(top+bottom)/2,down=value.exists ? value.frame.midY<middle:conversation
            let distance=min(bottom-top-20,max(44,value.exists ? abs(value.frame.midY-middle):bottom-top-20)),start=down ? top+10:bottom-10,end=start+(down ? distance:-distance)
            // Keep vertical drags in the scroll margin, outside selectable prose and nested text views.
            app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:start/app.frame.height)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:end/app.frame.height)))
        };XCTFail("The target did not become visible within the observed content viewport: "+app.debugDescription)
    }
    private func send(_ app:XCUIApplication) {
        let input=app.textViews["chat.input"];input.tap();let old=input.value as? String ?? "";if !old.isEmpty {input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:old.utf16.count))};input.typeText("Synthetic precise calendar review");app.buttons["chat.send"].tap();wait({self.probe(app)["turn_state"] as? String=="completed"})
    }
    private func open(_ app:XCUIApplication) {
        if app.keyboards.firstMatch.exists {
            // Use existing native navigation to dismiss the keyboard without replacing the chat draft.
            app.buttons["sidebar.open"].tap();let close=app.buttons["sidebar.close"];XCTAssertTrue(close.waitForExistence(timeout:5),app.debugDescription);close.tap();wait({!app.keyboards.firstMatch.exists})
        }
        let entry=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.goal.actions.")).firstMatch
        if !entry.exists {let card=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Synthetic sourced report")).firstMatch;reveal(app,card,conversation:true);XCTAssertTrue(card.waitForExistence(timeout:6),app.debugDescription);card.tap()}
        XCTAssertTrue(entry.waitForExistence(timeout:6),app.debugDescription);reveal(app,entry,conversation:true);entry.tap();XCTAssertTrue(element(app,"chat.action.status.").waitForExistence(timeout:6),app.debugDescription)
    }
    private func identity(_ app:XCUIApplication)->(String,String) {
        let metadata=element(app,"chat.action.metadata.");XCTAssertTrue(metadata.waitForExistence(timeout:4),app.debugDescription);if !element(app,"chat.action.digest.").exists {reveal(app,metadata);metadata.tap()}
        let identifier=element(app,"chat.action.id."),digest=element(app,"chat.action.digest.");XCTAssertTrue(digest.waitForExistence(timeout:4),app.debugDescription)
        XCTAssertNotNil(digest.label.range(of:"^SHA-256 [a-f0-9]{64}$",options:.regularExpression));return (identifier.identifier,digest.label)
    }
    private func capture(_ app:XCUIApplication,_ name:String) {let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Synthetic-native-exact-action-"+name;shot.lifetime = .keepAlways;add(shot)}
    private func approved(_ app:XCUIApplication)->Bool {let label=element(app,"chat.action.status.").label;return label.contains("已批准") || label.lowercased().contains("approved")}
    private func assertApprovedWaiting(_ app:XCUIApplication) {let label=element(app,"chat.action.status.").label,english=label.lowercased();XCTAssertTrue(approved(app),label);XCTAssertTrue(label.contains("等待设备") || (english.contains("waiting") && english.contains("device")),label);XCTAssertTrue(label.contains("尚未执行") || (english.contains("not") && english.contains("executed")),label);XCTAssertFalse(element(app,"chat.action.approve.").exists);XCTAssertEqual(probe(app)["turn_state"] as? String,"completed")}
    func testCloseReopenExactReviewAndApproveOnlyWaitingDevice() {
        let app=launch("p0-ui-task-action");send(app)
        let input=app.textViews["chat.input"];input.tap();input.typeText("Unrelated unfinished chat draft")
        open(app);let original=identity(app);wait({self.probe(app)["action_posts"] as? Int==0});app.buttons["chat.actions.close"].tap();XCTAssertEqual(input.value as? String,"Unrelated unfinished chat draft")
        open(app);let reopened=identity(app);XCTAssertEqual(reopened.0,original.0);XCTAssertEqual(reopened.1,original.1);XCTAssertEqual(probe(app)["action_posts"] as? Int,0)
        let approve=element(app,"chat.action.approve.");reveal(app,approve);wait({approve.isEnabled});approve.tap();wait({self.approved(app)});assertApprovedWaiting(app);wait({self.probe(app)["action_posts"] as? Int==1});XCTAssertEqual(probe(app)["action_committed_decisions"] as? Int,1);capture(app,"approved-waiting-device")
        app.buttons["chat.actions.close"].tap();open(app);assertApprovedWaiting(app);XCTAssertEqual(probe(app)["action_posts"] as? Int,1);XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
    }
    func testUnknownColdRelaunchReadsOriginalDecisionAndNeverPostsAgain() {
        let app=launch("p0-ui-task-action-unknown");send(app);open(app);let original=identity(app)
        let approve=element(app,"chat.action.approve.");reveal(app,approve);wait({approve.isEnabled});approve.tap();XCTAssertTrue(element(app,"chat.action.unknown.").waitForExistence(timeout:6),app.debugDescription);XCTAssertFalse(approve.isEnabled);wait({self.probe(app)["action_posts"] as? Int==1});_ = identity(app);let originalOperation=element(app,"chat.action.localOperation.").label;XCTAssertNotNil(originalOperation.range(of:"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression));capture(app,"unknown-original-operation")
        // Close and terminate without refreshing: the local journal and separate fake server receipt must both survive.
        app.buttons["chat.actions.close"].tap();XCUIDevice.shared.press(.home);app.terminate();app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12));open(app);wait({self.approved(app)});let recovered=identity(app)
        XCTAssertEqual(recovered.0,original.0);XCTAssertEqual(recovered.1,original.1);XCTAssertEqual(element(app,"chat.action.localOperation.").label,originalOperation);assertApprovedWaiting(app);wait({self.probe(app)["action_reads"] as? Int==1});XCTAssertEqual(probe(app)["action_posts"] as? Int,1);XCTAssertEqual(probe(app)["action_committed_decisions"] as? Int,1);capture(app,"cold-original-get-recovery")
    }
    func testUnavailableVerifierRetainsReadableReviewWithoutAvailableDecision() {
        let app=launch("p0-ui-task-action-unavailable");send(app);open(app);XCTAssertTrue(app.staticTexts["chat.actions.unavailable"].waitForExistence(timeout:6),app.debugDescription)
        let approve=element(app,"chat.action.approve."),deny=element(app,"chat.action.deny.");reveal(app,approve);XCTAssertFalse(approve.isEnabled);XCTAssertFalse(deny.isEnabled);_ = identity(app);XCTAssertEqual(probe(app)["action_posts"] as? Int,0);capture(app,"unavailable-verifier-readable")
    }
    func testAccessibilityExactCalendarReviewRemainsReadableAndDenialHasNoEffect() {
        let app=launch("p0-ui-large-task-action");send(app);open(app)
        let title=element(app,"chat.action.title.");XCTAssertTrue(title.label.contains("Synthetic exact calendar review"));XCTAssertTrue(app.staticTexts["Synthetic local calendar"].exists);XCTAssertTrue(app.staticTexts["Asia/Shanghai"].exists)
        let readableStart=element(app,"chat.action.start.").label,reminder=element(app,"chat.action.reminder.").label
        XCTAssertTrue(reminder.contains("10") && !reminder.contains("-600"),"Use a human reminder, preserving exact seconds in metadata")
        _ = identity(app);let raw=element(app,"chat.action.exactStart.").label
        guard let range=raw.range(of:"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z",options:.regularExpression) else {XCTFail("Exact original UTC must remain inspectable");return}
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];guard let date=formatter.date(from:String(raw[range])) else {XCTFail("Invalid precise UTC");return}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Shanghai")!;let parts=calendar.dateComponents([.hour,.minute,.second],from:date),hour=parts.hour!,suffix=String(format:":%02d:%02d",parts.minute!,parts.second!)
        let hours=[hour,hour%12==0 ? 12:hour%12];XCTAssertTrue(hours.contains{readableStart.range(of:"(^|[^0-9])0?"+String($0)+suffix,options:.regularExpression) != nil},"Visible date/time uses the intent time zone, independently of the device zone: "+readableStart)
        let deny=element(app,"chat.action.deny.");reveal(app,deny);XCTAssertGreaterThanOrEqual(deny.frame.height,44);XCTAssertTrue(deny.isEnabled);capture(app,"large-exact-target-before-denial");deny.tap()
        wait({let label=self.element(app,"chat.action.status.").label;return label.contains("已拒绝") || label.contains("Denied")});XCTAssertFalse(element(app,"chat.action.approve.").exists);wait({self.probe(app)["action_posts"] as? Int==1});XCTAssertEqual(probe(app)["action_committed_decisions"] as? Int,1);capture(app,"large-denied-no-effect")
    }
}
