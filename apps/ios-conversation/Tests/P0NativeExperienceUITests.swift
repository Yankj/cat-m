import XCTest

final class P0NativeExperienceUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func launch(_ scenario:String)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario,"P0_PERF_RECORDING":"1"]
        app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12))
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:5))
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline")
        XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        return app
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {
        let text=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any] ?? [:]
    }
    private func wait(_ predicate:()->Bool,seconds:TimeInterval=15){
        let deadline=Date().addingTimeInterval(seconds)
        while Date()<deadline { if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTFail("P0 explicit offline fixture condition timed out")
    }
    private func clear(_ input:XCUIElement){input.tap();let value=input.value as? String ?? "";if !value.isEmpty { input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:value.utf16.count)) }}
    private func attach(_ app:XCUIApplication,name:String){
        if app.buttons["qa.p0Export"].exists {app.buttons["qa.p0Export"].tap()}
        let data=(try? JSONSerialization.data(withJSONObject:probe(app),options:[.sortedKeys,.prettyPrinted])) ?? Data()
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testActualConsentAlertConfirmationDispatchesOriginalMessageOnce() {
        let app=launch("p0-ui-consent"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic explicit permission question");app.buttons["chat.send"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:5))
        XCTAssertEqual(probe(app)["synthetic_consent_calls"] as? Int,0)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        let allow=app.alerts.firstMatch.buttons.matching(NSPredicate(format:"label IN %@",["允许此对话","Allow this conversation"])).firstMatch
        XCTAssertTrue(allow.exists);allow.tap()
        wait({self.probe(app)["synthetic_consent_calls"] as? Int == 1 && self.probe(app)["turn_state"] as? String == "running"},seconds:8)
        let reader=app.descendants(matching:.any)["chat.assistantMessage"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout:2))
        let partial=reader.label;XCTAssertTrue(partial.hasPrefix("Synthetic streamed segment."))
        XCTAssertLessThan(partial.count,String(repeating:"Synthetic streamed segment. ",count:64).count)
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:12)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        attach(app,name:"Actual-alert-button-consent-before-original-dispatch-no-real-model")
    }
    func testStableLocalEchoDuringPermissionAndTwentyCallbackSamples() {
        let app=launch("p0-ui-echo"),input=app.textViews["chat.input"]
        XCTAssertEqual(input.value as? String,"Saved local draft");clear(input)
        for index in 0..<20 {
            input.tap();input.typeText("Synthetic echo \(index)");app.buttons["chat.send"].tap()
            XCTAssertTrue(app.staticTexts["chat.pendingAdmission"].firstMatch.waitForExistence(timeout:1))
            wait({((self.probe(app)["echo_samples"] as? [[String:Any]])?.count ?? 0) >= index+1})
            let operation=(probe(app)["echo_samples"] as? [[String:Any]])?.last?["operation_id"] as? String
            wait({self.probe(app)["turn_state"] as? String == "completed" && self.probe(app)["turn_id"] as? String == operation})
        }
        wait({((self.probe(app)["frame_intervals_ms"] as? [Double])?.count ?? 0) >= 300})
        let data=probe(app),samples=data["echo_samples"] as? [[String:Any]] ?? []
        XCTAssertEqual(samples.count,20);XCTAssertEqual(data["is_presented_frame_proof"] as? Bool,false)
        XCTAssertEqual(data["synthetic_reply_calls"] as? Int,20)
        // Record the actual values. No GPU/physical first-frame or performance PASS is inferred here.
        attach(app,name:"P0-Simulator-action-geometry-callback-20-samples")
    }
    func testNativeMarkedTextPreventsSendAndCommandReturn(){
        let app=launch("p0-ui-ime"),input=app.textViews["chat.input"];clear(input)
        app.buttons["qa.p0IME.mark"].tap();wait({self.probe(app)["composition_active"] as? Bool == true})
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        let before=input.value as? String;app.buttons["qa.p0IME.command"].tap()
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0);XCTAssertEqual(input.value as? String,before)
        app.buttons["qa.p0IME.commit"].tap();wait({self.probe(app)["composition_active"] as? Bool == false})
        XCTAssertTrue(app.buttons["chat.send"].isEnabled);attach(app,name:"P0-actual-UITextInput-marked-text-injection")
    }
    func testSimulatorHomeFiveSecondsRecoversSameSyntheticTurn(){
        let app=launch("p0-ui-lifecycle"),input=app.textViews["chat.input"];clear(input);input.typeText("Synthetic scene recovery");app.buttons["chat.send"].tap()
        wait({self.probe(app)["synthetic_reply_calls"] as? Int == 1})
        let initial=probe(app),id=initial["turn_id"] as? String,conversation=initial["conversation_id"] as? String
        XCUIDevice.shared.press(.home);RunLoop.current.run(until:Date().addingTimeInterval(5));app.activate()
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:20)
        let final=probe(app);XCTAssertEqual(final["turn_id"] as? String,id);XCTAssertEqual(final["conversation_id"] as? String,conversation)
        XCTAssertEqual(final["synthetic_reply_calls"] as? Int,1);XCTAssertGreaterThanOrEqual(final["synthetic_observe_calls"] as? Int ?? 0,1)
        attach(app,name:"P0-Simulator-home5s-in-process-backend-not-cloud-continuation")
    }
    func testLargestDynamicTypeComposerAndStreamRemainAccessible(){
        let app=launch("p0-ui-large"),input=app.textViews["chat.input"];XCTAssertTrue(input.isHittable);clear(input);input.typeText("Synthetic large type")
        XCTAssertTrue(app.buttons["chat.send"].isHittable);app.buttons["chat.send"].tap()
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:20)
        let reader=app.descendants(matching:.any)["chat.assistantMessage"].firstMatch;XCTAssertTrue(reader.exists)
        let expected=String(repeating:"\u{5408}\u{6210}\u{6D41}\u{5F0F}\u{6B63}\u{6587}\u{1F43E}\n",count:512)
        XCTAssertEqual(reader.label,expected)
        XCTAssertTrue(input.isHittable);XCTAssertTrue(app.buttons["chat.send"].exists);attach(app,name:"P0-Simulator-accessibility5-composer-stream")
    }

    func testIntegratedSidebarRoutesSearchAndNativeBackPreserveSavedDraft(){
        let app=launch("p0-ui-lifecycle"),input=app.textViews["chat.input"]
        let original=input.value as? String
        app.buttons["sidebar.open"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForExistence(timeout:3))
        XCTAssertFalse(app.buttons["sidebar.memory"].isEnabled)
        let search=app.textFields["sidebar.search"];search.tap();search.typeText("no synthetic match")
        XCTAssertTrue(app.staticTexts["sidebar.empty"].waitForExistence(timeout:3))
        search.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:18));search.typeText("Saved local draft")
        let records=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","sidebar.conversation."))
        XCTAssertEqual(records.count,1);records.firstMatch.tap()
        XCTAssertEqual(input.value as? String,original)
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.tasks"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["navigation.tasks"].waitForExistence(timeout:3))
        XCTAssertFalse(app.buttons["sidebar.open"].exists)
        let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.01,dy:0.45))
        start.press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.45)))
        XCTAssertTrue(app.buttons["sidebar.open"].waitForExistence(timeout:3));XCTAssertFalse(app.buttons["sidebar.close"].exists)
        XCTAssertEqual(input.value as? String,original)
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.results"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["navigation.results"].waitForExistence(timeout:3))
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.staticTexts["connection.state"].waitForExistence(timeout:3) || app.descendants(matching:.any)["connection.state"].exists)
        XCTAssertFalse(app.buttons["sidebar.open"].exists);app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertEqual(input.value as? String,original);XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        attach(app,name:"Integrated-sidebar-real-root-routes-native-back")
    }
    func testIntegratedRootEdgeAndPanelClosingGestures(){
        let app=launch("p0-ui-lifecycle"),input=app.textViews["chat.input"],original=input.value as? String
        let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.01,dy:0.40))
        start.press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.40)))
        XCTAssertTrue(app.buttons["sidebar.close"].waitForExistence(timeout:3))
        app.coordinate(withNormalizedOffset:CGVector(dx:0.70,dy:0.40)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.05,dy:0.40)))
        XCTAssertTrue(input.waitForExistence(timeout:3));XCTAssertFalse(app.buttons["sidebar.close"].exists)
        app.buttons["sidebar.open"].tap();app.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.40)).tap()
        XCTAssertTrue(input.waitForExistence(timeout:3));XCTAssertFalse(app.buttons["sidebar.close"].exists)
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.close"].tap()
        XCTAssertTrue(input.waitForExistence(timeout:3));XCTAssertFalse(app.buttons["sidebar.close"].exists)
        XCTAssertEqual(input.value as? String,original);attach(app,name:"Integrated-root-edge-panel-swipe-and-scrim")
    }
    func testIntegratedActualPhotosPickerCancelPreviewAndClosedGate(){
        let app=launch("p0-ui-lifecycle"),input=app.textViews["chat.input"],original=input.value as? String
        app.buttons["attachment.pick"].tap()
        let cancel=app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout:5));cancel.tap()
        XCTAssertEqual(input.value as? String,original);XCTAssertFalse(app.images["attachment.preview"].exists)
        app.buttons["attachment.pick"].tap();XCTAssertTrue(cancel.waitForExistence(timeout:5))
        let pickerShot=XCTAttachment(screenshot:app.screenshot());pickerShot.name="Actual-PhotosPicker-owned-synthetic-media";pickerShot.lifetime = .keepAlways;add(pickerShot)
        print("OWNED_SYNTHETIC_PHOTOS_PICKER_TREE " + app.debugDescription)
        let photos=app.images.matching(identifier:"PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout:5))
        XCTAssertTrue(photos.firstMatch.label.contains("10月12日"),"Only the new seeded synthetic media may be selected; stop for any other first image")
        photos.firstMatch.tap()
        XCTAssertTrue(app.images["attachment.preview"].waitForExistence(timeout:8))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled);XCTAssertTrue(app.staticTexts["attachment.localOnly"].exists)
        XCTAssertEqual(input.value as? String,original);XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Local-preview-server-vision-disabled-no-fallback";shot.lifetime = .keepAlways;add(shot)
        app.buttons["attachment.remove"].tap();XCTAssertFalse(app.images["attachment.preview"].exists)
        XCTAssertEqual(input.value as? String,original);XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0);attach(app,name:"Actual-PhotosPicker-local-only-cancel-preview-remove")
    }
    func testIntegratedLargestTypeSidebarFooterIsReachable(){
        let app=launch("p0-ui-large");app.buttons["sidebar.open"].tap()
        print("LARGE_SIDEBAR_TREE " + app.debugDescription)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Largest-type-sidebar-open";shot.lifetime = .keepAlways;add(shot)
        XCTAssertTrue(app.buttons["sidebar.close"].waitForExistence(timeout:3))
        let panel=app.scrollViews.containing(.button,identifier:"sidebar.settings").firstMatch
        panel.swipeUp();panel.swipeUp()
        XCTAssertTrue(app.buttons["sidebar.settings"].isHittable);app.buttons["sidebar.settings"].tap()
        let connection=app.descendants(matching:.any)["connection.state"]
        let opened=connection.waitForExistence(timeout:5)
        if !opened { print("LARGE_AFTER_SETTINGS_TREE " + app.debugDescription) }
        XCTAssertTrue(opened);XCTAssertFalse(app.buttons["sidebar.close"].exists)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.textViews["chat.input"].isHittable);attach(app,name:"Integrated-sidebar-accessibility5-footer")
    }
}
