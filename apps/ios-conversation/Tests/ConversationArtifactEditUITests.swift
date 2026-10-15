import XCTest
import CryptoKit

/// Root-host interaction with a durable, explicitly synthetic server. No external link is opened.
final class ConversationArtifactEditUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false}
    private func launch(_ scenario:String)->XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment=["CF_UI_TEST_STORE":UUID().uuidString,"CF_UI_TEST_SCENARIO":scenario,"P0_PERF_RECORDING":"1"]
        if scenario.hasPrefix("p0-ui-large") || scenario=="p0-ui-genui-large" {app.launchEnvironment["CATPAW_UI_TEST_TEXT_SIZE"]="accessibility5"}
        app.launch();assertReady(app);return app
    }
    private func assertReady(_ app:XCUIApplication) {
        XCTAssertTrue(app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:12),app.debugDescription)
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout:6),app.debugDescription)
        XCTAssertEqual(probe(app)["fixture_reality"] as? String,"injected_synthetic_offline")
        XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
    }
    private func probe(_ app:XCUIApplication)->[String:Any] {
        let raw=app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with:Data(raw.utf8))) as? [String:Any] ?? [:]
    }
    private func wait(_ predicate:()->Bool,seconds:TimeInterval=12,file:StaticString=#filePath,line:UInt=#line) {
        let deadline=Date().addingTimeInterval(seconds)
        while Date()<deadline {if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        XCTFail("Synthetic artifact edit condition timed out",file:file,line:line)
    }
    private func reveal(_ app:XCUIApplication,_ element:XCUIElement,conversation:Bool=false) {
        for _ in 0..<18 {
            let top=max(130,app.navigationBars.firstMatch.frame.maxY+12)
            var bottom=app.frame.height-36
            if app.keyboards.firstMatch.exists {bottom=min(bottom,app.keyboards.firstMatch.frame.minY-12)}
            if conversation,app.buttons["attachment.pick"].exists {bottom=min(bottom,app.buttons["attachment.pick"].frame.minY-12)}
            if conversation,app.buttons["chat.jumpToLatest"].exists {bottom=min(bottom,app.buttons["chat.jumpToLatest"].frame.minY-12)}
            if app.buttons["chat.artifact.edit.save"].exists {bottom=min(bottom,app.buttons["chat.artifact.edit.save"].frame.minY-12)}
            let visible=element.exists ? min(element.frame.maxY,bottom)-max(element.frame.minY,top) : 0
            if element.exists && element.isHittable && visible>=min(44,element.frame.height) {return}
            XCTAssertGreaterThan(bottom-top,45,app.debugDescription)
            let midpoint=(top+bottom)/2,down=element.exists ? element.frame.midY<midpoint : conversation
            let distance=min(bottom-top-20,max(44,element.exists ? abs(element.frame.midY-midpoint) : bottom-top-20))
            let start=down ? top+10 : bottom-10,end=start+(down ? distance : -distance)
            // Use the visible scroll gutter so a selectable paragraph or nested TextEditor
            // does not turn the vertical page gesture into caret/selection manipulation.
            app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:start/app.frame.height)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:end/app.frame.height)))
        }
        XCTAssertTrue(element.exists && element.isHittable,app.debugDescription)
    }
    private func back(_ app:XCUIApplication) {
        let button=app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(button.exists && button.isHittable,app.debugDescription);button.tap()
    }
    private func sendAndKeepChatDraft(_ app:XCUIApplication)->(String,String?) {
        let input=app.textViews["chat.input"];input.tap();input.typeText("Synthetic sourced result for manual editing")
        app.buttons["chat.send"].tap();wait({self.probe(app)["turn_state"] as? String == "completed"})
        input.tap();input.typeText("Keep this independent chat draft through artifact editing")
        let text=input.value as? String ?? "",hash=SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()
        XCTAssertFalse(text.isEmpty)
        wait({self.probe(app)["draft_hash"] as? String==hash})
        return (text,hash)
    }
    private func openArtifact(_ app:XCUIApplication,version:Int=2) {
        let open=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","chat.artifact.open.")).firstMatch
        if !open.exists {
            let card=app.buttons.matching(NSPredicate(format:"label CONTAINS %@","Synthetic sourced report")).firstMatch
            reveal(app,card,conversation:true);XCTAssertTrue(card.waitForExistence(timeout:6),app.debugDescription);card.tap()
        }
        XCTAssertTrue(open.waitForExistence(timeout:5),app.debugDescription);reveal(app,open,conversation:true);open.tap()
        wait({app.staticTexts["chat.artifact.reader.version"].label=="v\(version)"})
    }
    private func openEditor(_ app:XCUIApplication) {
        let edit=app.buttons["chat.artifact.reader.edit.toolbar"]
        XCTAssertTrue(edit.waitForExistence(timeout:5),app.debugDescription);XCTAssertTrue(edit.isHittable,app.debugDescription);edit.tap()
        XCTAssertTrue(app.staticTexts["chat.artifact.edit.baseVersion"].waitForExistence(timeout:6),app.debugDescription)
        wait({app.buttons["chat.artifact.edit.refresh"].isEnabled})
        XCTAssertTrue(app.staticTexts["chat.artifact.edit.baseVersion"].label.hasSuffix("v2"),app.debugDescription)
    }
    private func enterHumanDraft(_ app:XCUIApplication)->String {
        let field=app.textViews["chat.artifact.edit.contentField"]
        reveal(app,field);XCTAssertTrue(field.isHittable,app.debugDescription);field.tap()
        field.typeText("\nHuman-added synthetic text; original sources were not reread.\nEDIT-END")
        let value=field.value as? String ?? ""
        XCTAssertTrue(value.contains("Human-added synthetic text; original sources were not reread."))
        XCTAssertTrue(value.contains("EDIT-END"),"Synthetic last-input marker remains in the actual editor value")
        wait({app.buttons["chat.artifact.edit.close"].isEnabled && app.buttons["chat.artifact.edit.save"].isEnabled})
        assertActiveEditorReachable(app)
        return value
    }
    private func assertActiveEditorReachable(_ app:XCUIApplication,file:StaticString=#filePath,line:UInt=#line) {
        let field=app.textViews["chat.artifact.edit.contentField"],keyboard=app.keyboards.firstMatch
        let save=app.buttons["chat.artifact.edit.save"],close=app.buttons["chat.artifact.edit.close"]
        let bar=app.navigationBars.matching(NSPredicate(format:"identifier IN %@ OR label IN %@",["修改成果","Edit artifact"],["修改成果","Edit artifact"])).firstMatch
        let scroll=app.scrollViews["chat.artifact.edit.viewport"]
        let deadline=Date().addingTimeInterval(15)
        var previous:[CGRect]=[],frames:[CGRect]=[],previousCaret:[Double]=[],stable=0,visible:CGFloat=0,top:CGFloat=0,bottom:CGFloat=0
        var ready=false
        while Date()<deadline {
            let controlsExist=keyboard.exists && field.exists && save.exists && close.exists && scroll.exists
            if controlsExist {
                // Retain one whole sample. Never combine a pre-keyboard boundary
                // with later field/footer frames, or count clipped AX bounds.
                frames=[field.frame,keyboard.frame,save.frame,close.frame,scroll.frame,bar.exists ? bar.frame : .zero]
                top=max(frames[4].minY,frames[5].maxY+8)
                bottom=min(frames[4].maxY,frames[1].minY,frames[2].minY)-8
                visible=max(0,min(frames[0].maxY,bottom)-max(frames[0].minY,top))
                let valid=visible>=44 && frames[2].height>=44 && frames[3].height>=44 && frames[2].maxY<=frames[1].minY && field.isHittable && save.isHittable && close.isHittable
                let observed=probe(app)
                let caret=(observed["editor_caret_rect"] as? [Double]) ?? []
                let bounds=(observed["editor_visible_bounds"] as? [Double]) ?? []
                let selection=(observed["editor_selection_utf16"] as? [Int]) ?? []
                let marker=(field.value as? String ?? "") as NSString
                let end=marker.range(of:"EDIT-END",options:.backwards)
                let selectionMatches=selection.count==2 && end.location != NSNotFound && selection[0]==NSMaxRange(end) && selection[1]==0
                var actualCaretVisible=false
                if caret.count==4,bounds.count==4,bounds[2]>0,bounds[3]>0,(observed["editor_field_identifier"] as? String)=="chat.artifact.edit.contentField" {
                    actualCaretVisible=CGRect(x:bounds[0],y:bounds[1],width:bounds[2],height:bounds[3]).contains(CGRect(x:caret[0],y:caret[1],width:caret[2],height:caret[3]))
                }
                let caretSample=caret+bounds+selection.map(Double.init)
                stable=valid && actualCaretVisible && selectionMatches && frames==previous && caretSample==previousCaret ? stable+1:0
                previous=frames;previousCaret=caretSample
                if stable>=2 {ready=true;break}
            } else {stable=0;previous=[];previousCaret=[]}
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        }
        let geometry=XCTAttachment(string:"candidate=AF-UX-TYPOGRAPHY-20261014-23;version=0.3.0(23);reality=offline_synthetic_simulator\nwhole_sample_frames=\(frames)\nactual_UIKit_editor_observation=\(probe(app).filter{$0.key.hasPrefix("editor_")})\nvisible_field_height=\(visible)\nviewport=\(top)...\(bottom)\nconsecutive_stable_valid_samples=\(stable)")
        geometry.name="Build23-stable-active-editor-geometry";geometry.lifetime = .keepAlways;add(geometry)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Build23-stable-active-editor-keyboard";screenshot.lifetime = .keepAlways;add(screenshot)
        XCTAssertTrue(ready,"The focused editor must have >=44pt inside the stable actual scroll viewport above footer and keyboard; frames=\(frames), visible=\(visible), bounds=\(top)...\(bottom)",file:file,line:line)
    }
    private func assertDraftStatus(_ app:XCUIApplication,_ labels:[String]) {
        wait({labels.contains(app.staticTexts["chat.artifact.edit.draftStatus"].label)})
        XCTAssertFalse(app.staticTexts["chat.artifact.edit.draftStatus"].label.contains("尚未提交。"),"An unresolved original operation cannot be presented as never submitted")
    }
    private func closeEditor(_ app:XCUIApplication) {
        let close=app.buttons["chat.artifact.edit.close"]
        XCTAssertTrue(close.waitForExistence(timeout:5) && close.isEnabled && close.isHittable,app.debugDescription);close.tap()
        wait({!close.exists && app.staticTexts["chat.artifact.reader.version"].exists})
    }
    private func hashInReader(_ app:XCUIApplication)->String {
        let hash=app.staticTexts["chat.artifact.reader.hash"]
        if !hash.exists {let history=app.descendants(matching:.any).matching(identifier:"chat.artifact.reader.history").firstMatch;reveal(app,history);history.tap()}
        XCTAssertTrue(hash.waitForExistence(timeout:3),app.debugDescription)
        XCTAssertNotNil(hash.label.range(of:"^SHA-256 [a-f0-9]{64}$",options:.regularExpression));return hash.label
    }
    private func capture(_ app:XCUIApplication,_ name:String) {
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="Simulator-synthetic-AF-W31-REVIEW-20261014-04-v20-"+name;attachment.lifetime = .keepAlways;add(attachment)
    }
    private func verifyAppliedAndOldReader(_ app:XCUIApplication,raw:String,chatDraft:(String,String?),expectedReplyCalls:Int=1) {
        let applied=app.staticTexts["chat.artifact.edit.applied"]
        XCTAssertTrue(applied.waitForExistence(timeout:12),app.debugDescription);XCTAssertTrue(applied.label.hasSuffix("v3"))
        reveal(app,applied);XCTAssertTrue(applied.isHittable,app.debugDescription)
        XCTAssertFalse(app.buttons["chat.artifact.edit.save"].isEnabled)
        XCTAssertFalse(app.staticTexts["chat.artifact.edit.deliveryIssue"].exists,app.debugDescription)
        wait({self.probe(app)["artifact_committed_revisions"] as? Int==1 && self.probe(app)["artifact_posts"] as? Int==1})
        capture(app,"receipt-applied-v3")
        closeEditor(app)
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v2","Selected immutable reader does not jump to the new head")
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.content"].label.contains("Synthetic immutable report version 2."))
        XCTAssertFalse(app.staticTexts["chat.artifact.reader.content"].label.contains("Human-added synthetic text"))
        let oldHash=hashInReader(app)
        let newer=app.descendants(matching:.any).matching(identifier:"chat.artifact.reader.history.v3").firstMatch
        XCTAssertTrue(newer.waitForExistence(timeout:6),app.debugDescription);reveal(app,newer);newer.tap()
        wait({app.staticTexts["chat.artifact.reader.version"].label=="v3"})
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.content"].label,raw)
        XCTAssertTrue(app.staticTexts["chat.artifact.reader.userRevision"].exists,"Manual revision declares the source snapshot boundary")
        let newHash=hashInReader(app);XCTAssertNotEqual(oldHash,newHash)
        capture(app,"same-artifact-new-version-unrechecked")
        let sources=app.buttons["chat.artifact.reader.sources"];XCTAssertTrue(sources.exists,app.debugDescription);reveal(app,sources);sources.tap()
        let row=app.descendants(matching:.any).matching(identifier:"chat.artifact.source.source-1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:5),app.debugDescription);XCTAssertLessThanOrEqual(app.sheets.count,1)
        let sheetCount=app.sheets.count;row.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label IN %@",["对应成果版本 · v3","Result version · v3"])).firstMatch.waitForExistence(timeout:5),app.debugDescription)
        let sourceLink=app.descendants(matching:.any).matching(identifier:"chat.artifact.source.open").firstMatch
        XCTAssertTrue(sourceLink.waitForExistence(timeout:4),app.debugDescription);reveal(app,sourceLink);XCTAssertTrue(sourceLink.isHittable,app.debugDescription)
        XCTAssertEqual(app.sheets.count,sheetCount,"Source detail pushes within the existing source sheet")
        capture(app,"v3-keeps-original-source-snapshot-single-sheet")
        // Receipt-backed external links are visible; synthetic tests never open the network.
        let detailBar=app.navigationBars.matching(NSPredicate(format:"identifier IN %@ OR label IN %@",["来源详情","Source details"],["来源详情","Source details"])).firstMatch
        XCTAssertTrue(detailBar.exists && detailBar.buttons.firstMatch.isHittable,app.debugDescription);detailBar.buttons.firstMatch.tap()
        app.buttons["chat.artifact.sources.close"].tap();wait({app.staticTexts["chat.artifact.reader.version"].label=="v3"})
        back(app);wait({app.staticTexts["chat.artifact.reader.version"].label=="v2"});XCTAssertEqual(app.staticTexts["chat.artifact.reader.hash"].label,oldHash)
        back(app);let input=app.textViews["chat.input"];XCTAssertTrue(input.waitForExistence(timeout:5));XCTAssertEqual(input.value as? String,chatDraft.0)
        wait({self.probe(app)["draft_hash"] as? String==chatDraft.1})
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,expectedReplyCalls);XCTAssertEqual(probe(app)["artifact_posts"] as? Int,1);XCTAssertEqual(probe(app)["external_network_enabled"] as? Bool,false)
        capture(app,"return-keeps-independent-chat-draft")
    }
    private func runManualRevision(_ scenario:String) {
        let app=launch(scenario),draft=sendAndKeepChatDraft(app)
        if scenario=="p0-ui-large-artifact-edit" {
            app.buttons["sidebar.open"].tap();let close=app.buttons["sidebar.close"];XCTAssertTrue(close.waitForExistence(timeout:5));close.tap()
            wait({!app.keyboards.firstMatch.exists});XCTAssertEqual(app.textViews["chat.input"].value as? String,draft.0)
        }
        openArtifact(app);openEditor(app);let raw=enterHumanDraft(app)
        if scenario=="p0-ui-large-artifact-edit" {
            assertActiveEditorReachable(app)
            let status=app.staticTexts["chat.artifact.edit.draftStatus"]
            XCTAssertTrue(status.exists && status.isHittable,app.debugDescription)
            XCTAssertLessThanOrEqual(status.frame.height,app.buttons["chat.artifact.edit.save"].frame.height,"The short maximum-size status fits within a single-line action height; screenshot verifies the visible line while VoiceOver retains the full label")
            XCTAssertTrue(["修改草稿已保存在本机，尚未提交。","Your edit draft is saved locally and has not been submitted."].contains(status.label),status.label)
            XCTAssertTrue(["保存为成果新版本","Save a new artifact version"].contains(app.buttons["chat.artifact.edit.save"].label),"Short visible title retains the complete VoiceOver label")
            capture(app,"maximum-text-editor-keyboard-save-close-reachable")
        }
        capture(app,"local-draft-before-submit");closeEditor(app)
        XCTAssertEqual(app.staticTexts["chat.artifact.reader.version"].label,"v2");XCTAssertEqual(probe(app)["artifact_posts"] as? Int,0)
        openEditor(app);let field=app.textViews["chat.artifact.edit.contentField"];XCTAssertEqual(field.value as? String,raw)
        XCTAssertTrue(app.buttons["chat.artifact.edit.save"].isEnabled,app.debugDescription)
        app.buttons["chat.artifact.edit.save"].tap();verifyAppliedAndOldReader(app,raw:raw,chatDraft:draft)
    }
    func testRootManualRevisionDraftReopenAndExactVersionHistoryKeepChatDraft() {runManualRevision("p0-ui-artifact-edit")}
    func testMaximumTextManualEditorKeyboardSaveCloseAndHistoryRemainReachable() {runManualRevision("p0-ui-large-artifact-edit")}
    func testRootUnknownColdRestartOnlyReadsOriginalModificationAndKeepsVersions() {
        let app=launch("p0-ui-artifact-edit-unknown"),draft=sendAndKeepChatDraft(app)
        openArtifact(app);openEditor(app);let raw=enterHumanDraft(app);app.buttons["chat.artifact.edit.save"].tap()
        let unknown=app.staticTexts["chat.artifact.edit.unknown"]
        XCTAssertTrue(unknown.waitForExistence(timeout:10),app.debugDescription);XCTAssertFalse(app.buttons["chat.artifact.edit.save"].isEnabled)
        XCTAssertEqual(app.textViews["chat.artifact.edit.contentField"].value as? String,raw)
        assertDraftStatus(app,["原修改待核对，草稿已保存在本机。","The original revision awaits verification. Your draft is saved on this device."])
        wait({self.probe(app)["artifact_posts"] as? Int==1 && self.probe(app)["artifact_committed_revisions"] as? Int==1})
        XCTAssertEqual(probe(app)["synthetic_reply_calls"] as? Int,1)
        let reads=probe(app)["artifact_reads"] as? Int ?? -1;capture(app,"unknown-original-operation-kept")
        let field=app.textViews["chat.artifact.edit.contentField"]
        reveal(app,field);field.tap();field.typeText("\nUnsubmitted follow-up draft while the original revision awaits verification.")
        let newerRaw=field.value as? String ?? ""
        XCTAssertNotEqual(newerRaw,raw)
        assertDraftStatus(app,["新稿尚未提交；原修改待核对，草稿已保存在本机。","The new draft has not been submitted. The original revision awaits verification; your draft is saved on this device."])
        XCTAssertFalse(app.buttons["chat.artifact.edit.save"].isEnabled);assertActiveEditorReachable(app)
        XCTAssertEqual(probe(app)["artifact_posts"] as? Int,1)
        capture(app,"unknown-with-new-unsubmitted-local-draft")
        closeEditor(app);app.terminate();app.launch();assertReady(app)
        XCTAssertEqual(app.textViews["chat.input"].value as? String,draft.0)
        openArtifact(app);openEditor(app)
        wait({(self.probe(app)["artifact_reads"] as? Int ?? -1)>reads})
        XCTAssertEqual(app.textViews["chat.artifact.edit.contentField"].value as? String,newerRaw,"Cold recovery preserves newer raw while reading only the original operation")
        verifyAppliedAndOldReader(app,raw:raw,chatDraft:draft,expectedReplyCalls:0)
    }
}
