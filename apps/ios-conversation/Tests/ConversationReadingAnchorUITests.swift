import XCTest

/// Native geometry evidence from controlled transcript events, never real model acceptance.
final class ConversationReadingAnchorUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func until(_ condition:()->Bool,seconds:TimeInterval=8)->Bool {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {if condition(){return true};RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        return condition()
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {
        let value=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with:Data(value.utf8))) as? [String:Any] ?? [:]
    }
    private func capture(_ app:XCUIApplication,_ name:String) {
        let item=XCTAttachment(screenshot:app.screenshot());item.name=name;item.lifetime = .keepAlways;add(item)
    }
    func testResultAboveReadingPositionCompensatesAndBelowResultDoesNotMoveIt() {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-reading-growth"]
        app.launch()
        XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12))
        XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        let input=app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:5));input.tap();input.typeText("Synthetic reading geometry")
        app.buttons["chat.send"].tap()
        let reader=app.staticTexts["chat.assistantMessage"].firstMatch,transcript=app.scrollViews["chat.transcript"]
        XCTAssertTrue(reader.waitForExistence(timeout:5))
        XCTAssertTrue(until{reader.label.contains("Reading checkpoint 18.")})
        // Drag only inside the actually visible transcript, above the editor/keyboard.
        // UIScrollView AX bounds may extend behind both system navigation and keyboard.
        let frame=transcript.frame.intersection(app.frame)
        let top=max(frame.minY,app.navigationBars.firstMatch.frame.maxY)+8
        let bottom=min(frame.maxY,input.frame.minY)-8
        XCTAssertGreaterThan(bottom-top,100,"A real visible transcript strip must exist")
        // Correct from actual observed geometry, rather than assuming one fixed
        // drag reaches a reading position across keyboard/safe-area changes.
        let targetY=top-60
        for _ in 0..<12 {
            let current=reader.frame.minY
            if abs(current-targetY)<=25 {break}
            let visibleBottom=min(transcript.frame.maxY,input.frame.minY)-8
            let down=current<targetY
            let distance=min(visibleBottom-top-40,max(20,abs(current-targetY)))
            let startY=down ? top+20:visibleBottom-20
            let endY=startY+(down ? distance:-distance)
            let x=frame.minX+min(14,frame.width/10)
            app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:startY))
                .press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:endY)),withVelocity:.slow,thenHoldForDuration:0.2)
        }
        XCTAssertTrue(until{self.probe(app)["reading_following_latest"] as? Bool == false})
        var last=reader.frame.minY,stableSince=Date()
        XCTAssertTrue(until{let next=reader.frame.minY;if abs(next-last)>0.5 {last=next;stableSince=Date()};return Date().timeIntervalSince(stableSince)>0.3})
        let originalY=reader.frame.minY,originalText=reader.label
        XCTAssertLessThan(originalY,top,"Test must read within a block, not merely align its top")
        let geometry=XCTAttachment(string:"native_body_before_y=\(originalY);visible_top=\(top);text_length=\(originalText.count);fixture=controlled_native_events")
        geometry.name="Reading-original-native-body-geometry";geometry.lifetime = .keepAlways;add(geometry)
        XCTAssertGreaterThan(originalY,top-300,"Upper card must remain near enough to be materialized")
        capture(app,"Native-reading-before-upper-result")
        let next=app.buttons["qa.reading.grow"];XCTAssertTrue(next.isHittable);next.tap()
        XCTAssertTrue(app.staticTexts["Synthetic upper result"].waitForExistence(timeout:5),"The upper pending row must actually become a native result card")
        XCTAssertTrue(until{app.textFields["chat.genui.duration.field.0"].exists})
        XCTAssertEqual(reader.label,originalText,"The same text must survive the tool result")
        capture(app,"Native-reading-after-upper-result-before-assertion")
        let diagnostics=XCTAttachment(string:app.staticTexts["qa.p0Probe"].value as? String ?? "missing native probe")
        diagnostics.name="Actual-native-anchor-diagnostics-after-upper-result";diagnostics.lifetime = .keepAlways;add(diagnostics)
        XCTAssertEqual(reader.frame.minY,originalY,accuracy:3,"A real result above the viewport must preserve the current block and pixel offset")
        XCTAssertEqual(probe(app)["reading_following_latest"] as? Bool,false)
        capture(app,"Native-reading-after-upper-result")
        // Move to a new deliberate reading point near the lower pending card.
        // A distant lazy row that never renders cannot prove below-growth behavior.
        app.buttons["chat.jumpToLatest"].tap()
        XCTAssertTrue(until{self.probe(app)["reading_following_latest"] as? Bool == true && (self.probe(app)["reading_distance_from_bottom"] as? Int ?? 9999)<=80})
        let visibleBottom=min(transcript.frame.maxY,input.frame.minY)-8
        let startY=top+24,travel=min(120,(visibleBottom-top)*0.4),x=frame.minX+min(14,frame.width/10)
        app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:startY))
            .press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:startY+travel)),withVelocity:.slow,thenHoldForDuration:0.2)
        XCTAssertTrue(until{self.probe(app)["reading_following_latest"] as? Bool == false})
        var lowerLast=reader.frame.minY,lowerStableSince=Date()
        XCTAssertTrue(until{let y=reader.frame.minY;if abs(y-lowerLast)>0.5 {lowerLast=y;lowerStableSince=Date()};return Date().timeIntervalSince(lowerStableSince)>0.3})
        let lowerReadingY=reader.frame.minY
        capture(app,"Native-reading-near-lower-pending-result")
        next.tap()
        XCTAssertTrue(app.staticTexts["Synthetic lower result"].waitForExistence(timeout:5))
        XCTAssertTrue(until{self.probe(app)["turn_state"] as? String == "completed"})
        XCTAssertEqual(reader.frame.minY,lowerReadingY,accuracy:3,"Growth below the reading point must not be treated as an offset correction")
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        XCTAssertTrue(app.buttons["chat.jumpToLatest"].isHittable)
        capture(app,"Native-reading-after-lower-result-no-drift")
        app.buttons["chat.jumpToLatest"].tap()
        XCTAssertTrue(until{self.probe(app)["reading_following_latest"] as? Bool == true && (self.probe(app)["reading_distance_from_bottom"] as? Int ?? 9999)<=80})
        XCTAssertFalse(app.buttons["chat.jumpToLatest"].exists)
    }
}
