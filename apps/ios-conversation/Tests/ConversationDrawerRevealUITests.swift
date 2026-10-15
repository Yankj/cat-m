import Foundation
import UIKit
import XCTest

/// Explicit in-process P0 fixture. Screenshots prove endpoint composition only;
/// Root's recording must separately assess tracking, interruption and re-grab.
final class ConversationDrawerRevealUITests:XCTestCase {
    private let bundleID="com.example.CatpawM.ConversationFirst.Auth"
    private let question="Synthetic drawer reading check"
    private let reply="Synthetic offline reply; no model call."
    override func setUp(){continueAfterFailure=false}

    private func until(_ condition:()->Bool,seconds:TimeInterval=8)->Bool {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {
            if condition(){return true}
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        }
        return condition()
    }
    private func launchAndReply()->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:bundleID)
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":"p0-ui-echo","CATPAW_QA_VISUAL_REVIEW":"1"]
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        let input=app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout:12),app.debugDescription)
        XCTAssertFalse(app.staticTexts["qa.p0Fixture"].exists,"The visual fixture flag removes the toolbar-obscuring overlay")
        // A new local conversation avoids replacing any seeded fixture draft.
        let new=app.buttons["chat.new"]
        XCTAssertTrue(new.waitForExistence(timeout:5));XCTAssertTrue(new.isEnabled && new.isHittable);new.tap()
        XCTAssertTrue(until{input.exists && (input.value as? String)==""},app.debugDescription)
        input.tap();input.typeText(question)
        let send=app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled && send.isHittable);send.tap() // the sole Send press in this test
        XCTAssertTrue(app.staticTexts["chat.reply.completed"].waitForExistence(timeout:12),app.debugDescription)
        XCTAssertTrue(until{self.reader(app).exists && self.reader(app).label==self.reply},app.debugDescription)
        return app
    }
    private func reader(_ app:XCUIApplication)->XCUIElement {
        app.descendants(matching:.any).matching(identifier:"chat.assistantMessage").firstMatch
    }
    private func userEchoCount(_ app:XCUIApplication)->Int {
        app.descendants(matching:.any).matching(identifier:"chat.userMessage").count
    }
    private func capture(_ app:XCUIApplication,_ phase:String) {
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Drawer-native-"+phase;image.lifetime = .keepAlways;add(image)
        let scrim=app.buttons["sidebar.scrim"],close=app.buttons["sidebar.close"],input=app.textViews["chat.input"]
        let facts="reality=explicit_in_process_synthetic;scenario=p0-ui-echo;visual_overlay=hidden;phase=\(phase)\napp=\(app.frame)\nreader=\(reader(app).exists ? reader(app).frame:.zero)\ninput=\(input.exists ? input.frame:.zero)\nclose_exists=\(close.exists)\nscrim=\(scrim.exists ? scrim.frame:.zero)\nuser_echo_count=\(userEchoCount(app))\nlimit=endpoint screenshot and visible transcript checks; no continuous-motion or real-model acceptance"
        let text=XCTAttachment(string:facts);text.name="Drawer-native-geometry-"+phase;text.lifetime = .keepAlways;add(text)
    }
    private func drag(_ app:XCUIApplication,from start:CGPoint,to end:CGPoint) {
        let origin=app.coordinate(withNormalizedOffset:.zero)
        origin.withOffset(CGVector(dx:start.x-app.frame.minX,dy:start.y-app.frame.minY))
            .press(forDuration:0.05,thenDragTo:origin.withOffset(CGVector(dx:end.x-app.frame.minX,dy:end.y-app.frame.minY)),withVelocity:.slow,thenHoldForDuration:0.2)
    }
    private func assertNoAdditionalReply(_ app:XCUIApplication,draft:String,echoes:Int) {
        XCTAssertEqual(app.textViews["chat.input"].value as? String,draft,"Presentation gestures preserve the exact local draft")
        XCTAssertEqual(userEchoCount(app),echoes,"No extra user turn appears without a Send press")
        XCTAssertEqual(reader(app).label,reply)
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"chat.assistantMessage").count,1)
        XCTAssertTrue(app.staticTexts["chat.reply.completed"].exists)
    }
    func testReadOnlyReplyPanRevealsForegroundStripAndClosesKeepingChineseDraft() {
        let app=launchAndReply(),input=app.textViews["chat.input"],draft="尚未发送的中文草稿"
        input.tap();input.typeText(draft);XCTAssertEqual(input.value as? String,draft)
        let echoes=userEchoCount(app);XCTAssertGreaterThan(echoes,0)
        let body=reader(app),transcript=app.scrollViews["chat.transcript"]
        XCTAssertTrue(body.exists && body.isHittable);XCTAssertTrue(transcript.exists)
        let visible=body.frame.intersection(transcript.frame).intersection(app.frame)
        XCTAssertGreaterThan(visible.width,100);XCTAssertGreaterThan(visible.height,12)
        let start=CGPoint(x:visible.minX+visible.width*0.40,y:visible.midY)
        XCTAssertGreaterThan(start.x,app.frame.minX+44,"Opening must start in the read-only TextKit body, beyond the edge gesture zone")
        capture(app,"before-body-pan")
        drag(app,from:start,to:CGPoint(x:app.frame.maxX-12,y:start.y))
        let close=app.buttons["sidebar.close"],scrim=app.buttons["sidebar.scrim"]
        XCTAssertTrue(until{close.exists && close.isHittable},app.debugDescription)
        XCTAssertTrue(scrim.exists && scrim.isHittable,app.debugDescription)
        let retained=scrim.frame.intersection(app.frame)
        XCTAssertGreaterThanOrEqual(retained.width,44,"The translated original foreground remains visible at the right")
        XCTAssertGreaterThan(retained.minX,app.frame.midX)
        XCTAssertLessThanOrEqual(abs(retained.maxX-app.frame.maxX),1)
        capture(app,"open-right-foreground-retained")
        // Close from the retained foreground itself, not by tapping the close icon.
        let y=app.frame.minY+app.frame.height*0.5
        drag(app,from:CGPoint(x:app.frame.maxX-10,y:y),to:CGPoint(x:app.frame.minX+32,y:y))
        XCTAssertTrue(until{!close.exists && input.exists && input.isHittable},app.debugDescription)
        assertNoAdditionalReply(app,draft:draft,echoes:echoes)
        capture(app,"closed-same-local-draft")
    }
    func testReadOnlyLongPressOwnsSystemCopyMenuThenBodyPanResumesWithoutSending() {
        let app=launchAndReply(),input=app.textViews["chat.input"],draft="系统文字菜单关闭后保留中文草稿"
        input.tap();input.typeText(draft);XCTAssertEqual(input.value as? String,draft)
        let echoes=userEchoCount(app),body=reader(app),transcript=app.scrollViews["chat.transcript"]
        XCTAssertTrue(body.exists && body.isHittable)
        let visible=body.frame.intersection(transcript.frame).intersection(app.frame)
        XCTAssertGreaterThan(visible.width,100);XCTAssertGreaterThan(visible.height,12)
        let origin=app.coordinate(withNormalizedOffset:.zero)
        let word=CGPoint(x:visible.minX+min(30,visible.width*0.12),y:visible.minY+min(12,visible.height*0.35))
        origin.withOffset(CGVector(dx:word.x-app.frame.minX,dy:word.y-app.frame.minY)).press(forDuration:1.2)
        // Exact system action labels only: never accept our separate "复制回复"
        // button as proof that UIKit selected actual text. Do not invoke Copy.
        let predicate=NSPredicate(format:"label IN %@",["复制","拷贝","Copy"])
        let copyItem=app.menuItems.matching(predicate).firstMatch,copyButton=app.buttons.matching(predicate).firstMatch
        func copyMenuVisible()->Bool {
            (copyItem.exists && copyItem.isHittable) || (copyButton.exists && copyButton.isHittable)
        }
        XCTAssertTrue(until{copyMenuVisible()},"A real UIKit Copy menu must appear after long-pressing the read-only text. "+app.debugDescription)
        XCTAssertFalse(app.buttons["sidebar.close"].exists,"A text-selection long press must never become a drawer gesture")
        capture(app,"system-text-selection-copy-menu-no-drawer")
        let leading=body.descendants(matching:.any).matching(identifier:"com.apple.text.grabber.leading")
        let trailing=body.descendants(matching:.any).matching(identifier:"com.apple.text.grabber.trailing")
        XCTAssertGreaterThan(leading.count,0,"Observe the actual leading selection handle before ending text selection")
        XCTAssertGreaterThan(trailing.count,0,"Observe the actual trailing selection handle before ending text selection")
        // Prove that editing focus transferred to the original draft by inserting
        // and deleting a real character. Never mutate UIKit's selectedRange.
        input.tap();input.typeText("x"+XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(input.value as? String,draft,"The focus proof restores the exact original draft")
        XCTAssertTrue(until{!copyMenuVisible()},"The actual system editing menu must close. "+app.debugDescription)
        func noHittableBodySelectionHandles()->Bool {
            let handles=leading.allElementsBoundByIndex+trailing.allElementsBoundByIndex
            return handles.allSatisfy{!$0.isHittable}
        }
        XCTAssertTrue(until{noHittableBodySelectionHandles()},"The old reply must have no actionable selection handles before a reading pan. "+app.debugDescription)
        for handle in leading.allElementsBoundByIndex+trailing.allElementsBoundByIndex {
            XCTAssertFalse(handle.isHittable,"Check actual handle hit testing, not only menu/exists state")
        }
        let selectionEvidence=XCTAttachment(string:"focus_proof=typed_x_then_deleted;draft_exact=\((input.value as? String)==draft);leading_AX_count=\(leading.count);trailing_AX_count=\(trailing.count);remaining_handles_hittable=\(!noHittableBodySelectionHandles());copy_menu_visible=\(copyMenuVisible())\nlimit=AX absence does not prove an empty UIKit selectedRange; the following actual body pan must succeed")
        selectionEvidence.name="Drawer-native-system-selection-focus-transfer";selectionEvidence.lifetime = .keepAlways;add(selectionEvidence)
        // Do not tap the reply again: that can reactivate its previous selection.
        let current=body.frame.intersection(transcript.frame).intersection(app.frame)
        XCTAssertGreaterThan(current.width,100);XCTAssertGreaterThan(current.height,12)
        let start=CGPoint(x:current.minX+current.width*0.4,y:current.midY)
        XCTAssertGreaterThan(start.x,app.frame.minX+44)
        drag(app,from:start,to:CGPoint(x:app.frame.maxX-12,y:start.y))
        let close=app.buttons["sidebar.close"]
        XCTAssertTrue(until{close.exists && close.isHittable},"Reading pan must work again after leaving text selection. "+app.debugDescription)
        capture(app,"after-system-menu-body-pan-open")
        let y=app.frame.minY+app.frame.height*0.5
        drag(app,from:CGPoint(x:app.frame.maxX-10,y:y),to:CGPoint(x:app.frame.minX+32,y:y))
        XCTAssertTrue(until{!close.exists && input.exists && input.isHittable},app.debugDescription)
        assertNoAdditionalReply(app,draft:draft,echoes:echoes)
        capture(app,"system-menu-closed-reading-pan-restored-same-draft")
    }
    func testChineseEditorAndModalDetailsKeepHorizontalGestureOwnership() {
        let app=launchAndReply(),input=app.textViews["chat.input"],draft="中文输入区保留这份未发送草稿"
        input.tap();input.typeText(draft);XCTAssertEqual(input.value as? String,draft)
        let echoes=userEchoCount(app),field=input.frame.intersection(app.frame)
        XCTAssertTrue(input.isHittable);XCTAssertGreaterThan(field.width,100)
        drag(app,from:CGPoint(x:field.minX+field.width*0.20,y:field.midY),to:CGPoint(x:field.minX+field.width*0.85,y:field.midY))
        XCTAssertFalse(app.buttons["sidebar.close"].exists,"Editable Chinese input retains its own cursor/selection gesture")
        XCTAssertEqual(input.value as? String,draft)
        let details=app.buttons["chat.input.context.open"]
        XCTAssertTrue(details.exists && details.isEnabled && details.isHittable);details.tap()
        let modalClose=app.buttons["chat.input.context.close"],scroll=app.scrollViews["chat.input.context.scroll"]
        XCTAssertTrue(modalClose.waitForExistence(timeout:5));XCTAssertTrue(scroll.exists)
        let modal=scroll.frame.intersection(app.frame),y=modal.minY+modal.height*0.4
        drag(app,from:CGPoint(x:modal.minX+modal.width*0.3,y:y),to:CGPoint(x:app.frame.maxX-12,y:y))
        XCTAssertTrue(modalClose.exists && modalClose.isHittable)
        XCTAssertFalse(app.buttons["sidebar.close"].exists,"The foreground details sheet owns interaction; the root drawer cannot open behind it")
        capture(app,"modal-owns-horizontal-gesture")
        modalClose.tap();XCTAssertTrue(until{!modalClose.exists && input.exists && input.isHittable},app.debugDescription)
        assertNoAdditionalReply(app,draft:draft,echoes:echoes)
        capture(app,"editor-and-modal-preserve-draft")
    }
}
