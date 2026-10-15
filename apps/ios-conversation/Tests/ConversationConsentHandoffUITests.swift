import XCTest
import Foundation

/// Actual native text-to-image presentation handoff. The composition is an
/// explicit in-process fixture: no Auth/HTTP/provider or photo library is used.
/// Run the same method with the actual default and maximum system text category.
final class ConversationConsentHandoffUITests: XCTestCase {
    private let caption = "请描述这张本地合成色块图片。\n这段说明仍未发送。"
    override func setUp() { continueAfterFailure = false }
    private func until(_ condition: () -> Bool, seconds: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), "Expected actual native state did not become ready", file: file, line: line)
    }
    private func probe(_ app: XCUIApplication) -> [String: Any] {
        let raw = app.staticTexts["qa.p0Probe"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }
    private func assertButton(_ app: XCUIApplication, _ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.exists && button.isEnabled && button.isHittable, app.debugDescription, file: file, line: line)
        NativeUIGeometry.assertMinimumHeight(button.frame, file: file, line: line)
        XCTAssertTrue(app.frame.contains(button.frame), "The actual decision must lie inside the visible viewport", file: file, line: line)
    }
    private func openImageReview(_ app: XCUIApplication) {
        let inline = app.buttons["image.consent.review"]
        if inline.exists && inline.isHittable { assertButton(app, inline); inline.tap(); return }
        let open = app.buttons["chat.input.context.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); assertButton(app, open); open.tap()
        let review = app.buttons["chat.input.context.imageConsent"]
        XCTAssertTrue(review.waitForExistence(timeout: 5)); NativeUIScrollReveal.reveal(app, review)
        assertButton(app, review); review.tap()
    }
    private func imageConfirmation(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["image.consent.nonSensitive"]
    }
    private func revealImageConfirmation(_ app:XCUIApplication) {
        NativeUIScrollReveal.reveal(app,imageConfirmation(app))
    }
    private func assertUnsent(_ app: XCUIApplication, textAllows: Int, imageReads: Int, imageAllows: Int) {
        until({
            let value = self.probe(app)
            return value["handoff_text_allows"] as? Int == textAllows && value["handoff_image_reads"] as? Int == imageReads && value["handoff_image_allows"] as? Int == imageAllows
        })
        let value = probe(app)
        XCTAssertEqual(value["fixture_reality"] as? String, "injected_synthetic_offline")
        XCTAssertEqual(value["external_network_enabled"] as? Bool, false)
        XCTAssertEqual(value["handoff_reply_attempts"] as? Int, 0)
        XCTAssertEqual(value["handoff_preview_mismatches"] as? Int, 0)
        XCTAssertEqual(value["synthetic_reply_calls"] as? Int, 0)
        XCTAssertEqual(value["outgoing_count"] as? Int, 0)
        XCTAssertEqual(value["turn_id"] as? String, "")
        XCTAssertEqual(app.staticTexts.matching(identifier: "chat.userMessage").count, 0)
        XCTAssertEqual(app.textViews["chat.input"].value as? String, caption)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Synthetic-native-consent-handoff-" + name; shot.lifetime = .keepAlways; add(shot)
        let ids = ["chat.modelConsent.allow", "chat.modelConsent.defer", "image.consent.allow", "image.consent.cancel", "image.consent.nonSensitive"]
        let geometry = ids.map { id -> String in
            let view = app.descendants(matching: .any).matching(identifier: id).firstMatch
            return "\(id);exists=\(view.exists);hittable=\(view.exists && view.isHittable);frame=\(view.exists ? view.frame : .zero)"
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: "reality=explicit_inprocess_synthetic;HTTP_adapter=absent;no_real_model;no_Send_pressed\n" + geometry)
        attachment.name = "Synthetic-consent-handoff-geometry-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testTextConsentHandsOffToImageAndCancelReopenAllowKeepsUnsentDraft() {
        let app = XCUIApplication(bundleIdentifier: "com.example.CatpawM.ConversationFirst.Auth")
        app.launchEnvironment = ["CF_UI_TEST_STORE": UUID().uuidString, "CF_UI_TEST_SCENARIO": "p0-ui-consent-handoff"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), app.debugDescription)
        until({ input.value as? String == self.caption && self.probe(app)["handoff_image_reads"] as? Int == 0 })
        assertUnsent(app, textAllows: 0, imageReads: 0, imageAllows: 0)
        XCTAssertTrue(app.images["attachment.preview"].exists, "A real locally encoded synthetic image was restored before UI review")
        let category = probe(app)["input_system_category"] as? String ?? "unobserved"
        let size = XCTAttachment(string: "system_category=\(category);CATPAW_UI_TEST_TEXT_SIZE=absent;actual_platform_layout=true;synthetic_image=32x24_color_blocks")
        size.name = "Consent-handoff-actual-system-text-category"; size.lifetime = .keepAlways; add(size)
        openImageReview(app)
        let textAllow = app.buttons["chat.modelConsent.allow"], textDefer = app.buttons["chat.modelConsent.defer"]
        XCTAssertTrue(textAllow.waitForExistence(timeout: 8), app.debugDescription)
        until({ textAllow.isEnabled && textAllow.isHittable && textDefer.exists && textDefer.isHittable })
        assertButton(app, textAllow); assertButton(app, textDefer); capture(app, "text-notice-before-allow")
        textAllow.tap() // This must hand off through the actual single presenter.
        let imageAllow = app.buttons["image.consent.allow"], imageCancel = app.buttons["image.consent.cancel"]
        XCTAssertTrue(imageCancel.waitForExistence(timeout: 8), "Image review must follow text approval without a second manual invocation. " + app.debugDescription)
        until({ imageCancel.isEnabled && imageCancel.isHittable })
        XCTAssertFalse(app.buttons["chat.modelConsent.allow"].exists, "Only the current image decision owns presentation")
        XCTAssertTrue(app.images["image.consent.preview"].exists)
        XCTAssertFalse(imageAllow.isEnabled, "The image grant requires a separate explicit nonsensitive confirmation")
        NativeUIGeometry.assertMinimumHeight(imageAllow.frame); assertButton(app, imageCancel)
        capture(app, "image-notice-before-cancel")
        imageCancel.tap()
        until({ !imageCancel.exists && input.exists && input.isHittable })
        assertUnsent(app, textAllows: 1, imageReads: 1, imageAllows: 0)
        XCTAssertTrue(app.images["attachment.preview"].exists)
        openImageReview(app)
        XCTAssertTrue(imageCancel.waitForExistence(timeout: 8)); until({ imageCancel.isHittable })
        XCTAssertFalse(textAllow.exists, "Reopening image consent must not ask for already granted text consent")
        XCTAssertFalse(imageAllow.isEnabled)
        // Consent selection belongs to the fixed decision area. Scroll only
        // the readonly notice, excluding navigation and every decision control.
        let notice=app.scrollViews["image.consent.viewport"],confirmation=imageConfirmation(app)
        let navigationBottom=app.navigationBars.allElementsBoundByIndex.filter{$0.isHittable}.map{$0.frame.maxY}.max() ?? notice.frame.minY
        let readingTop=max(notice.frame.minY,navigationBottom)+8,readingBottom=min(notice.frame.maxY,confirmation.frame.minY-8)
        XCTAssertGreaterThan(readingBottom-readingTop,44)
        let origin=app.coordinate(withNormalizedOffset:.zero),x=notice.frame.midX
        origin.withOffset(CGVector(dx:x,dy:readingTop+(readingBottom-readingTop)*0.75))
            .press(forDuration:0.1,thenDragTo:origin.withOffset(CGVector(dx:x,dy:readingTop+(readingBottom-readingTop)*0.25)),withVelocity:.slow,thenHoldForDuration:0.2)
        revealImageConfirmation(app)
        XCTAssertTrue(confirmation.isEnabled && confirmation.isHittable); NativeUIGeometry.assertMinimumHeight(confirmation.frame)
        XCTAssertFalse(imageAllow.isEnabled,"Scrolling must not confirm sensitive-content handling")
        XCTAssertEqual(confirmation.value as? String,"未选中")
        capture(app,"image-confirmation-visible-before-tap")
        confirmation.tap()
        XCTAssertEqual(confirmation.value as? String,"已选中")
        until({ imageAllow.isEnabled && imageAllow.isHittable })
        assertButton(app, imageAllow); assertButton(app, imageCancel); capture(app, "image-confirmed-before-allow")
        imageAllow.tap()
        until({ !imageCancel.exists && input.exists && input.isHittable })
        assertUnsent(app, textAllows: 1, imageReads: 2, imageAllows: 1)
        let value = probe(app)
        XCTAssertEqual(value["handoff_text_allow_attempts"] as? Int, 1)
        XCTAssertEqual(value["handoff_image_allow_attempts"] as? Int, 1)
        XCTAssertTrue(app.images["attachment.preview"].exists)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled, "Consent makes an explicit Send available; it never presses Send")
        capture(app, "returned-to-same-caption-image-with-zero-dispatch")
    }
}
