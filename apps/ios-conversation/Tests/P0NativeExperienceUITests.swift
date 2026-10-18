import XCTest
import UIKit

final class P0NativeExperienceUITests:XCTestCase {
    func testR5ComposerReflowsWithoutLosingDraftOrSending() {
        let app=launch("p0-ui-lifecycle",visualReview:true),input=app.textViews["chat.input"]
        clear(input)
        let send=app.buttons["chat.send"]
        XCTAssertFalse(send.isEnabled,"An empty composer keeps a disabled send action")
        NativeUIGeometry.assertMinimumHeight(send.frame)
        XCTAssertLessThanOrEqual(abs(send.frame.midY-input.frame.midY),12,"Empty input is one compact row")
        let draft="R5 local draft\nSecond line keeps the original editor"
        input.typeText(draft)
        XCTAssertEqual(input.value as? String,draft)
        XCTAssertTrue(send.isEnabled && send.isHittable)
        XCTAssertGreaterThanOrEqual(send.frame.minY,input.frame.maxY-1,"Draft controls occupy their own row")
        XCTAssertTrue(input.isHittable)
        let more=app.buttons["chat.more"]
        XCTAssertTrue(more.isHittable);more.tap()
        app.catpawOpenSettings()
        XCTAssertTrue(app.descendants(matching:.any)["connection.state"].waitForExistence(timeout:4))
        XCTAssertTrue(app.descendants(matching:.any)["settings.appVersion"].exists)
        XCTAssertTrue(app.descendants(matching:.any)["settings.appBuild"].exists)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertEqual(input.value as? String,draft,"Opening conversation controls never submits or replaces the draft")
        XCTAssertFalse(app.staticTexts["chat.userMessage"].exists,"Menu navigation does not send the draft")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="R5-native-drafting-controls-and-preserved-local-draft";shot.lifetime = .keepAlways;add(shot)
    }

    func testNormalReviewLaunchHasNoFixtureOrCloudAdmission() {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=[:];app.launch()
        let start=app.buttons["auth.startExperience"]
        XCTAssertTrue(start.waitForExistence(timeout:12),app.debugDescription)
        XCTAssertFalse(start.isEnabled,"Offline review package cannot admit Auth or model requests")
        XCTAssertTrue(app.staticTexts["auth.error"].exists)
        XCTAssertFalse(app.staticTexts["qa.p0Fixture"].exists)
        XCTAssertFalse(app.staticTexts["auth.fixture"].exists)
        XCTAssertFalse(app.textViews["chat.input"].exists)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Build23-normal-launch-no-fixture-no-cloud-config";screenshot.lifetime = .keepAlways;add(screenshot)
    }
    func testSystemTextCategoryIsRespectedWithoutScenarioSizeOverride() {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-large"]
        app.launch();XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12))
        let input=app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:6))
        let limit=Date().addingTimeInterval(6)
        var measured:[String:Any]=[:]
        while Date()<limit {
            let raw=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
            measured=(try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [String:Any] ?? [:]
            if measured["input_font_point_size"] as? Double != nil {break}
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        }
        guard let rawCategory=measured["input_system_category"] as? String,let actual=measured["input_font_point_size"] as? Double else {XCTFail("Actual UIKit typography observation missing");return}
        let category=UIContentSizeCategory(rawValue:rawCategory)
        let expected=UIFont.preferredFont(forTextStyle:.body,compatibleWith:UITraitCollection(preferredContentSizeCategory:category))
        XCTAssertEqual(actual,Double(expected.pointSize),accuracy:0.01,"Scenario identity cannot force a font different from the actual system category")
        XCTAssertGreaterThanOrEqual(input.frame.height,expected.lineHeight+16-1)
        let raw="中文草稿 English remains local";replaceAll(app,input,with:raw)
        XCTAssertEqual(input.value as? String,raw)
        NativeUIGeometry.assertMinimumHeight(app.buttons["chat.send"].frame)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Simulator-system-text-category-"+rawCategory+"-no-scenario-clamp";screenshot.lifetime = .keepAlways;add(screenshot)
        let evidence=XCTAttachment(string:"actual_system_category="+rawCategory+";input_point_size="+String(actual)+";QA_size_override=absent;fixture=explicit_offline;model_requests=0");evidence.name="Actual-UIKit-system-category-witness";evidence.lifetime = .keepAlways;add(evidence)
    }
    override func setUp(){continueAfterFailure=false}
    private func launch(_ scenario:String,visualReview:Bool=false)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario,"P0_PERF_RECORDING":"1"]
        if scenario.hasPrefix("p0-ui-large") || scenario=="p0-ui-genui-large" {app.launchEnvironment["CATPAW_UI_TEST_TEXT_SIZE"]="accessibility5"}
        if visualReview {app.launchEnvironment["CATPAW_QA_VISUAL_REVIEW"]="1"}
        app.launch();if !visualReview {XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12))}
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:5))
        if !visualReview {
            XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline")
            XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        }
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
    private func clear(_ input:XCUIElement){
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        replaceAll(app,input,with:"")
    }
    private func revealEarlier(_ app:XCUIApplication,_ element:XCUIElement) {
        NativeUIScrollReveal.reveal(app,element)
    }
    private func replaceAll(_ app:XCUIApplication,_ input:XCUIElement,with text:String) {
        input.tap()
        if !(input.value as? String ?? "").isEmpty {
            input.press(forDuration:1.1)
            let selectAll=app.menuItems.matching(NSPredicate(format:"label IN %@",["全选","Select All"])).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout:3),app.debugDescription)
            selectAll.tap()
            input.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue:text)
        } else if !text.isEmpty {input.typeText(text)}
        XCTAssertEqual(input.value as? String,text,"Replace the selected text, regardless of the prior caret position")
    }
    private func verifyPickerEntry(_ app:XCUIApplication) {
        let input=app.textViews["chat.input"],raw=input.value as? String ?? ""
        let inline=app.buttons["attachment.pick"],context=app.scrollViews["chat.input.context.viewport"]
        let inlineVisible=inline.exists && context.exists ? inline.frame.intersection(context.frame).height:0
        let usesDetails = !inline.exists || !inline.isHittable || inlineVisible<44
        if usesDetails {
            let details=app.buttons["chat.input.context.open"]
            XCTAssertTrue(details.exists && details.isHittable,"Adaptive context must keep a real image-picker route")
            NativeUIGeometry.assertMinimumHeight(details.frame);details.tap()
            XCTAssertTrue(app.buttons["chat.input.context.close"].waitForExistence(timeout:5))
        }
        let picker=usesDetails ? app.scrollViews["chat.input.context.scroll"].buttons["attachment.pick"]:inline
        XCTAssertTrue(picker.waitForExistence(timeout:5),app.debugDescription)
        if usesDetails {NativeUIScrollReveal.reveal(app,picker)}
        XCTAssertTrue(picker.isHittable);NativeUIGeometry.assertMinimumHeight(picker.frame)
        picker.tap()
        let cancel=app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout:5),"The details action opens the actual system PhotosPicker")
        XCTAssertTrue(cancel.isHittable);cancel.tap()
        wait({!cancel.exists})
        if usesDetails {
            let close=app.buttons["chat.input.context.close"]
            wait({close.exists && close.isHittable && !cancel.exists})
            close.tap();wait({!close.exists && !app.scrollViews["chat.input.context.scroll"].exists})
        }
        wait({input.exists && input.isHittable && !cancel.exists})
        XCTAssertEqual(input.value as? String,raw,"Cancelling image selection leaves the exact conversation draft intact")
        XCTAssertFalse(app.images["attachment.preview"].exists)
    }
    private func attach(_ app:XCUIApplication,name:String){
        if app.buttons["qa.p0Export"].exists {app.buttons["qa.p0Export"].tap()}
        let data=(try? JSONSerialization.data(withJSONObject:probe(app),options:[.sortedKeys,.prettyPrinted])) ?? Data()
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testActualConsentAlertConfirmationDispatchesOriginalMessageOnce() {
        let app=launch("p0-ui-consent"),input=app.textViews["chat.input"]
        XCTAssertEqual(probe(app)["synthetic_consent_calls"] as? Int,0)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        clear(input);input.typeText("Synthetic explicit permission question");app.buttons["chat.send"].tap()
        let allow=app.buttons["chat.modelConsent.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertTrue(allow.isEnabled && allow.isHittable);NativeUIGeometry.assertMinimumHeight(allow.frame);allow.tap()
        wait({self.probe(app)["synthetic_consent_calls"] as? Int == 1 && self.probe(app)["turn_state"] as? String == "running"},seconds:8)
        let reader=app.descendants(matching:.any)["chat.assistantMessage"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout:2))
        let partial=reader.label;XCTAssertTrue(partial.hasPrefix("Synthetic streamed segment."))
        XCTAssertLessThan(partial.count,String(repeating:"Synthetic streamed segment. ",count:64).count)
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:12)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        attach(app,name:"Actual-alert-button-consent-before-original-dispatch-no-real-model")
    }
    func testReplyActionsQuotePreservesDraftWithoutDispatch() {
        let app=launch("p0-ui-echo"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic message action check");app.buttons["chat.send"].tap()
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:10)
        input.tap();input.typeText("Preserve my unfinished draft")
        let more=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.answer.more.")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout:3));more.tap()
        let quote=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.answer.quote.")).firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout:3));quote.tap()
        let draft=input.value as? String ?? ""
        XCTAssertTrue(draft.hasPrefix("Preserve my unfinished draft"))
        XCTAssertTrue(draft.contains("> Synthetic offline reply; no model call."))
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.answer.copy.")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.answer.share.")).firstMatch.exists)
        attach(app,name:"Reply-quote-keeps-draft-no-additional-dispatch")
    }
    private func openPlan(_ app:XCUIApplication) {
        XCTAssertFalse(app.buttons["Cancel"].exists,"A system PhotosPicker cannot still own interaction when opening a task plan")
        XCTAssertFalse(app.buttons["chat.input.context.close"].exists,"Close the input details before opening another sheet")
        let action=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.goal.plan.")).firstMatch
        if !action.exists {
            let card=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Synthetic local report")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout:6),app.debugDescription);revealEarlier(app,card);card.tap()
        }
        XCTAssertTrue(action.waitForExistence(timeout:5),app.debugDescription);revealEarlier(app,action);action.tap()
        XCTAssertTrue(app.staticTexts["chat.plan.revision"].waitForExistence(timeout:5),app.debugDescription)
    }
    func testTaskPlanDraftSurvivesSheetCloseAndEditsOriginalTask() {
        let app=launch("p0-ui-plan"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic local report plan");app.buttons["chat.send"].tap()
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:10)
        input.tap();input.typeText("Keep the chat draft")
        verifyPickerEntry(app)
        openPlan(app);app.buttons["chat.plan.edit"].tap()
        let requirements=app.textViews["chat.plan.requirementsField"]
        XCTAssertTrue(requirements.waitForExistence(timeout:3));requirements.tap()
        requirements.typeText(" Add a risks section from supplied fictional data.")
        let exact=requirements.value as? String ?? ""
        app.buttons["chat.plan.keepDraft"].tap();app.buttons["chat.plan.close"].tap()
        wait({!app.staticTexts["chat.plan.revision"].exists && !app.buttons["chat.plan.close"].exists && input.isHittable})
        XCTAssertEqual(input.value as? String,"Keep the chat draft")
        openPlan(app);XCTAssertTrue(app.staticTexts["chat.plan.savedDraft"].exists)
        app.buttons["chat.plan.edit"].tap()
        XCTAssertEqual(requirements.value as? String,exact)
        app.buttons["chat.plan.save"].tap()
        XCTAssertTrue(app.staticTexts["chat.plan.applied"].waitForExistence(timeout:5),app.debugDescription)
        XCTAssertTrue(app.staticTexts["chat.plan.revision"].label.contains("v2"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Native-plan-same-task-applied-v2-offline";shot.lifetime = .keepAlways;add(shot)
        app.buttons["chat.plan.close"].tap()
        XCTAssertEqual(input.value as? String,"Keep the chat draft")
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        attach(app,name:"Plan amendment draft preserved on reopen with original work and no conversation dispatch")
    }
    func testTaskPlanUnknownKeepsOriginalAmendmentAndBlocksResubmit() {
        let app=launch("p0-ui-plan-unknown"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic unknown plan amendment");app.buttons["chat.send"].tap()
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:10)
        verifyPickerEntry(app)
        openPlan(app);app.buttons["chat.plan.edit"].tap()
        let requirements=app.textViews["chat.plan.requirementsField"];requirements.tap();requirements.typeText(" Add risks.")
        app.buttons["chat.plan.save"].tap()
        XCTAssertTrue(app.staticTexts["chat.plan.unknown"].waitForExistence(timeout:5),app.debugDescription)
        XCTAssertFalse(app.buttons["chat.plan.save"].isEnabled)
        app.buttons["chat.plan.keepDraft"].tap()
        let refresh=app.buttons["chat.plan.refresh"]
        if !refresh.isHittable {app.swipeUp()}
        refresh.tap()
        XCTAssertTrue(app.staticTexts["chat.plan.revision"].label.contains("v2"))
        XCTAssertFalse(app.buttons["chat.plan.edit"].exists)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        attach(app,name:"Plan-unknown-read-original-no-resubmit")
    }
    func testGenerativeInvalidRawInputSurvivesNativeColdRelaunch() {
        let app=launch("p0-ui-genui"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic persisted local input");app.buttons["chat.send"].tap()
        let total=app.textFields["chat.genui.duration.field.0"]
        revealEarlier(app,total);total.tap()
        total.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:8)+"-")
        XCTAssertEqual(total.value as? String,"-")
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:16)
        XCUIDevice.shared.press(.home);app.terminate();app.launch()
        XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12))
        revealEarlier(app,total)
        XCTAssertEqual(total.value as? String,"-","Cold reopen must retain the incomplete raw input")
        XCTAssertTrue(app.staticTexts["chat.genui.duration.error"].exists)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0,"Reopening local state must not generate another reply")
        attach(app,name:"Native-SwiftData-cold-reopen-keeps-invalid-local-input")
    }
    func testGenerativeDurationLocalEditSurvivesStreamingWithoutDispatch() {
        let app=launch("p0-ui-genui"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic local time budget");app.buttons["chat.send"].tap()
        let total=app.textFields["chat.genui.duration.field.0"]
        wait({self.probe(app)["synthetic_reply_calls"] as? Int == 1},seconds:8)
        revealEarlier(app,total);total.tap()
        total.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:8)+"61")
        XCTAssertEqual(total.value as? String,"61")
        XCTAssertEqual(probe(app)["reading_following_latest"] as? Bool,false)
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:16)
        XCTAssertEqual(total.value as? String,"61","Streaming text must not recreate local inputs")
        XCTAssertTrue(app.staticTexts["chat.genui.duration.result"].label.contains("19.00"))
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Native-local-duration-stable-during-synthetic-stream";shot.lifetime = .keepAlways;add(shot)
        total.tap();total.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:8)+"0")
        XCTAssertTrue(app.staticTexts["chat.genui.duration.result"].label.contains("-42.00"),"Over-budget stays negative")
        total.tap();total.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:8))
        XCTAssertTrue(app.staticTexts["chat.genui.duration.error"].exists)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        for (index,value) in [(0,"0"),(1,"0.004"),(2,"0")] {
            let field=app.textFields["chat.genui.duration.field."+String(index)]
            revealEarlier(app,field);field.tap();field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:8)+value)
        }
        XCTAssertTrue(app.staticTexts["chat.genui.duration.result"].label.contains("0.00"))
        XCTAssertTrue(app.staticTexts["chat.genui.duration.overBudget"].exists,"A negative exact remainder must stay over budget after display rounding")
        XCTAssertTrue(app.staticTexts["-0.004 分钟"].exists || app.staticTexts["-0.004 minutes"].exists)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        attach(app,name:"Native-local-duration-invalid-negative-no-dispatch")
    }
    func testGenerativeTableFiltersCompleteDatasetLocally() {
        let app=launch("p0-ui-genui-table"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic local table");app.buttons["chat.send"].tap()
        let filter=app.textFields["chat.genui.filter"]
        wait({self.probe(app)["synthetic_reply_calls"] as? Int == 1},seconds:8)
        revealEarlier(app,filter);filter.tap();filter.typeText("Option 6")
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:16)
        XCTAssertEqual(filter.value as? String,"Option 6")
        XCTAssertTrue(app.staticTexts["Option 6"].exists,"Filtering must include rows outside the five-row preview")
        XCTAssertFalse(app.staticTexts["Option 1"].exists)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Native-filter-all-six-synthetic-rows";shot.lifetime = .keepAlways;add(shot)
        let full=app.buttons["chat.genui.fullTable"];revealEarlier(app,full);full.tap()
        let expandedFilter=app.textFields["chat.genui.fullFilter"]
        XCTAssertEqual(expandedFilter.value as? String,"Option 6")
        expandedFilter.tap();expandedFilter.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:8)+"Option 5")
        XCTAssertTrue(app.staticTexts["Option 5"].exists);XCTAssertFalse(app.staticTexts["Option 6"].exists)
        let done=app.navigationBars.buttons.matching(NSPredicate(format:"label IN %@",["完成","Done"])).firstMatch
        XCTAssertTrue(done.exists);done.tap()
        XCTAssertEqual(filter.value as? String,"Option 5","Full sheet and preview must share local state")
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        attach(app,name:"Native-table-filter-no-model-or-domain-dispatch")
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
    func testReadingAboveBottomSurvivesStreamAndJumpResumesFollowing() {
        let app=launch("p0-ui-reading"),input=app.textViews["chat.input"]
        clear(input);input.typeText("Synthetic long reading");app.buttons["chat.send"].tap()
        let reader=app.descendants(matching:.any)["chat.assistantMessage"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout:5))
        wait({reader.label.count >= 3000},seconds:8)
        app.scrollViews["chat.transcript"].swipeDown()
        let jump=app.buttons["chat.jumpToLatest"]
        XCTAssertTrue(jump.waitForExistence(timeout:3))
        XCTAssertEqual(probe(app)["reading_following_latest"] as? Bool,false)
        let originalY=reader.frame.minY,originalCount=reader.label.count
        wait({reader.label.count >= originalCount+1000},seconds:4)
        XCTAssertEqual(reader.frame.minY,originalY,accuracy:12,"New deltas must not move the reading anchor")
        XCTAssertTrue(jump.exists);XCTAssertEqual(probe(app)["reading_following_latest"] as? Bool,false)
        jump.tap()
        wait({self.probe(app)["reading_following_latest"] as? Bool == true && (self.probe(app)["reading_distance_from_bottom"] as? Int ?? 9999) <= 80},seconds:3)
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:18)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        XCTAssertFalse(jump.exists)
        attach(app,name:"Reading-anchor-real-scroll-Simulator-synthetic-stream")
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
    func testQueueSheetEditsPausedIntentAndResumesOnlyExplicitly() {
        let app=launch("p0-ui-queue"),input=app.textViews["chat.input"]
        replaceAll(app,input,with:"Synthetic first running request");app.buttons["chat.send"].tap()
        wait({self.probe(app)["synthetic_reply_calls"] as? Int == 1 && self.probe(app)["turn_state"] as? String == "running"})
        input.tap();input.typeText("Synthetic original queued message");app.buttons["chat.send"].tap()
        let summary=app.buttons["chat.pendingSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout:5))
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"chat.userMessage").count,1,"Queued follow-ups must not duplicate formal transcript messages")
        let compact=XCTAttachment(screenshot:app.screenshot());compact.name="Native-one-row-queue-summary-synthetic";compact.lifetime = .keepAlways;add(compact)
        summary.tap()
        let edit=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.followup.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout:5));edit.tap()
        let editor=app.textViews["chat.followup.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout:5));replaceAll(app,editor,with:"Synthetic edited queued message")
        app.buttons["chat.followup.save"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic edited queued message"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["Synthetic original queued message"].exists)
        XCTAssertTrue(app.buttons["chat.followup.resume"].exists)
        let paused=XCTAttachment(screenshot:app.screenshot());paused.name="Native-edited-queue-stays-paused-synthetic";paused.lifetime = .keepAlways;add(paused)
        app.buttons["chat.followup.close"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout:5))
        wait({self.probe(app)["turn_state"] as? String == "completed"},seconds:45)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1,"Closing and saving must not send the edited follow-up")
        summary.tap();let resume=app.buttons["chat.followup.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout:3));XCTAssertTrue(resume.isEnabled);resume.tap()
        app.buttons["chat.followup.close"].tap()
        wait({self.probe(app)["synthetic_reply_calls"] as? Int == 2 && self.probe(app)["turn_state"] as? String == "completed"},seconds:10)
        XCTAssertFalse(summary.exists)
        XCTAssertTrue(app.staticTexts["Synthetic edited queued message"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic original queued message"].exists)
        attach(app,name:"Actual-native-queue-edit-explicit-resume-no-real-model")
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

    private func waitForClosedSidebarRoot(_ app:XCUIApplication) {
        // Value restoration precedes the physical settling endpoint. Wait for
        // actual gesture ownership, not an old input's cached AX value.
        wait({!app.buttons["sidebar.close"].exists && !app.buttons["sidebar.scrim"].exists && app.buttons["sidebar.open"].exists && app.buttons["sidebar.open"].isEnabled && app.buttons["sidebar.open"].isHittable && app.textViews["chat.input"].isHittable},seconds:5)
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
        XCTAssertEqual(input.value as? String,original);waitForClosedSidebarRoot(app)
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
    func testSidebarSearchClearAndTwoUnsentDraftsRemainInTheirConversations(){
        let app=launch("p0-ui-lifecycle"),input=app.textViews["chat.input"]
        let firstText="First unsent sidebar draft",secondText="Second independent sidebar draft"
        replaceAll(app,input,with:firstText)
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.new"].tap()
        wait({(input.value as? String) != firstText},seconds:5);waitForClosedSidebarRoot(app)
        input.tap();input.typeText(secondText)
        app.buttons["sidebar.open"].tap()
        let firstRow=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","sidebar.conversation.",firstText)).firstMatch
        let secondRow=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","sidebar.conversation.",secondText)).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout:5));XCTAssertTrue(secondRow.waitForExistence(timeout:5))
        let firstID=firstRow.identifier,secondID=secondRow.identifier
        let drafts=XCTAttachment(screenshot:app.screenshot());drafts.name="Native-sidebar-two-scoped-unsent-drafts";drafts.lifetime = .keepAlways;add(drafts)
        let search=app.textFields["sidebar.search"];search.tap();search.typeText("No matching conversation")
        XCTAssertTrue(app.staticTexts["sidebar.empty"].waitForExistence(timeout:3))
        app.buttons["sidebar.search.clear"].tap()
        XCTAssertFalse(app.staticTexts["sidebar.empty"].exists);XCTAssertEqual(search.value as? String,search.placeholderValue)
        search.tap();search.typeText(firstText)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","sidebar.conversation.")).count,1)
        app.buttons[firstID].tap();waitForClosedSidebarRoot(app);XCTAssertEqual(input.value as? String,firstText)
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.search.clear"].tap();app.buttons[secondID].tap()
        waitForClosedSidebarRoot(app);XCTAssertEqual(input.value as? String,secondText)
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        let restored=XCTAttachment(screenshot:app.screenshot());restored.name="Native-sidebar-returned-to-second-exact-draft";restored.lifetime = .keepAlways;add(restored)
        attach(app,name:"Native-sidebar-clear-search-scope-isolation-no-send")
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
        let cancel=app.buttons.matching(NSPredicate(format:"label IN %@",["Cancel","取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout:5));cancel.tap()
        XCTAssertEqual(input.value as? String,original);XCTAssertFalse(app.images["attachment.preview"].exists)
        app.buttons["attachment.pick"].tap();XCTAssertTrue(cancel.waitForExistence(timeout:5))
        let pickerShot=XCTAttachment(screenshot:app.screenshot());pickerShot.name="Actual-PhotosPicker-owned-synthetic-media";pickerShot.lifetime = .keepAlways;add(pickerShot)
        print("OWNED_SYNTHETIC_PHOTOS_PICKER_TREE " + app.debugDescription)
        let photos=app.images.matching(identifier:"PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout:15),app.debugDescription)
        XCTAssertTrue(photos.firstMatch.label.contains("10月12日"),"Only the new seeded synthetic media may be selected; stop for any other first image")
        photos.firstMatch.tap()
        XCTAssertTrue(app.images["attachment.preview"].waitForExistence(timeout:8))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled);XCTAssertTrue(app.staticTexts["attachment.localOnly"].exists)
        XCTAssertEqual(input.value as? String,original);XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,0)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Local-preview-server-vision-disabled-no-fallback";shot.lifetime = .keepAlways;add(shot)
        app.buttons["sidebar.open"].tap();app.buttons["sidebar.new"].tap()
        wait({(input.value as? String) != original},seconds:5);XCTAssertFalse(app.images["attachment.preview"].exists)
        input.tap();input.typeText("Second conversation keeps its own text")
        app.buttons["sidebar.open"].tap()
        let first=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","sidebar.conversation.",original ?? "Saved local draft")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout:5));first.tap()
        XCTAssertEqual(input.value as? String,original);XCTAssertTrue(app.images["attachment.preview"].waitForExistence(timeout:3))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        let retained=XCTAttachment(screenshot:app.screenshot());retained.name="Native-PhotosPicker-draft-restored-to-original-conversation";retained.lifetime = .keepAlways;add(retained)
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
