import XCTest
import CryptoKit

/// Requires owner integration of the documented read-only P0 probe and deterministic harness.
/// Missing probe is a failure, never a fabricated timing pass. Run only after device/Simulator handoff.
final class P0ConversationUITests:XCTestCase {
 private func app(_ scenario:String) throws ->XCUIApplication{
  guard ProcessInfo.processInfo.environment["P0_APPROVED_UI_HANDOFF"]=="1" else{throw XCTSkip("Requires explicit device/Simulator control handoff")}
  continueAfterFailure=false;let app=XCUIApplication(bundleIdentifier:"com.example.CatpawM.ConversationFirst.Auth")
  app.launchEnvironment["CF_UI_TEST_STORE"]=UUID().uuidString
  app.launchEnvironment["CF_UI_TEST_SCENARIO"]=scenario;app.launchEnvironment["P0_MEASURE_PRESENTATION"]="1"
  app.launch();XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout:15))
  guard app.staticTexts["qa.p0Fixture"].waitForExistence(timeout:3) else{XCTFail("Isolated offline P0 fixture missing; stop before typing or sending");throw NSError(domain:"P0FixtureMissing",code:1)}
  let initial=try probe(app);guard initial["fixture_reality"] as? String=="injected_synthetic_offline",initial["external_network_enabled"] as? Bool==false else{XCTFail("Offline fixture proof missing; no Send action permitted");throw NSError(domain:"P0FixtureMissing",code:2)}
  return app
 }
 private func probe(_ app:XCUIApplication) throws ->[String:Any]{
  let element=app.descendants(matching:.any)["qa.p0Probe"]
  guard element.waitForExistence(timeout:3),let raw=element.value as? String,let value=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any] else{
   XCTFail("Required device/protocol probe absent; no P0 metric has been measured");throw NSError(domain:"P0MissingMeasurement",code:1)
  };return value
 }
 private func attach(_ app:XCUIApplication,_ name:String){let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)}
 func testSlowConsentPressHasActualPresentedFeedbackWithin100ms() throws{
  for sample in 0..<20 {
  let app=try app("p0-consent-held-2s"),input=app.textFields["chat.input"];input.tap();input.typeText("Synthetic pending feedback check \(sample)")
  app.buttons["chat.send"].tap();let p=try probe(app)
  let a=try XCTUnwrap(p["press_event_ns"] as? UInt64),b=try XCTUnwrap(p["first_visible_frame_ns"] as? UInt64)
  XCTAssertGreaterThanOrEqual(b,a);XCTAssertLessThanOrEqual(Double(b-a)/1e6,100)
  XCTAssertEqual(p["clock"] as? String,"device_uptime_ns");XCTAssertEqual(p["measurement_source"] as? String,"ios_device_presentation_probe")
  XCTAssertEqual(p["visible_state"] as? String,"consent_checking");XCTAssertEqual(p["client_turn_posts"] as? Int,0)
  XCTAssertTrue(app.descendants(matching:.any)["chat.pendingAdmission"].isHittable);attach(app,"p0-consent-presentation-\(sample)");app.terminate()
  }
 }
 func testLongStreamKeyboardScrollAndExactTerminalBody() throws{
  let app=try app("p0-stream-16384"),input=app.textFields["chat.input"];input.tap();input.typeText("Synthetic long response")
  app.buttons["chat.send"].tap();let answer=app.staticTexts["chat.assistantMessage"].firstMatch
  XCTAssertTrue(answer.waitForExistence(timeout:10));app.scrollViews.firstMatch.swipeDown()
  input.tap();input.typeText("draft while streaming");XCTAssertTrue(input.isHittable);XCTAssertTrue(app.buttons["chat.send"].isHittable)
  let before=try probe(app),anchor=try XCTUnwrap(before["visible_anchor_id"] as? String),y=try XCTUnwrap(before["visible_anchor_y"] as? Double)
  let done=app.descendants(matching:.any)["qa.p0Terminal"]
  XCTAssertTrue(done.waitForExistence(timeout:40));let after=try probe(app)
  XCTAssertEqual(after["visible_anchor_id"] as? String,anchor);XCTAssertLessThanOrEqual(abs(try XCTUnwrap(after["visible_anchor_y"] as? Double)-y),20)
  let body=answer.label,digest=SHA256.hash(data:Data(body.utf8)).map{String(format:"%02x",$0)}.joined()
  XCTAssertEqual(digest,after["expected_body_sha256"] as? String);XCTAssertEqual(body.count,16384)
  XCTAssertEqual(after["turn_state"] as? String,"completed");XCTAssertEqual(after["client_turn_posts"] as? Int,1);XCTAssertEqual(after["assistant_message_count"] as? Int,1)
  XCTAssertFalse(app.staticTexts["chat.unresolved"].exists);attach(app,"p0-long-stream-keyboard-anchor")
 }
 func testBackground5And30SecondsReattachesOriginalTurnWithoutPostingAgain() async throws{
  for seconds in [5,30]{
   let app=try app("p0-background-remote-completes"),input=app.textFields["chat.input"];input.tap();input.typeText("Synthetic background recovery")
   app.buttons["chat.send"].tap();XCTAssertTrue(app.staticTexts["chat.assistantMessage"].firstMatch.waitForExistence(timeout:10));let before=try probe(app)
   XCUIDevice.shared.press(.home);try await Task.sleep(nanoseconds:UInt64(seconds)*1_000_000_000);app.activate()
   XCTAssertTrue(app.descendants(matching:.any)["qa.p0Terminal"].waitForExistence(timeout:3));let after=try probe(app)
   XCTAssertEqual(after["conversation_id"] as? String,before["conversation_id"] as? String);XCTAssertEqual(after["turn_id"] as? String,before["turn_id"] as? String)
   XCTAssertEqual(after["client_turn_posts"] as? Int,1);XCTAssertEqual(after["chat_model_requests"] as? Int,before["chat_model_requests"] as? Int)
   XCTAssertEqual(after["rendered_body_sha256"] as? String,after["expected_body_sha256"] as? String);XCTAssertEqual(after["turn_state"] as? String,"completed")
   XCTAssertFalse(app.staticTexts["chat.unresolved"].exists);attach(app,"p0-scene-\(seconds)s-original-turn")
  }
 }
 func testImageSelectionCancelPreviewAndMultimodalFailureKeepsExactAsset() throws{
  let app=try app("p0-image-scripted-upload-failure"),input=app.textFields["chat.input"];input.tap();input.typeText("Synthetic image draft")
  let add=app.buttons["chat.attachImage"];XCTAssertTrue(add.waitForExistence(timeout:3));add.tap()
  let picker=app.descendants(matching:.any)["qa.syntheticImagePicker"];XCTAssertTrue(picker.waitForExistence(timeout:3));picker.buttons["取消"].tap()
  XCTAssertEqual(input.value as? String,"Synthetic image draft");XCTAssertEqual((try probe(app))["upload_count"] as? Int,0)
  add.tap();picker.buttons["qa.syntheticImage.redTriangle"].tap();XCTAssertTrue(app.images["chat.imagePreview"].waitForExistence(timeout:3))
  let selected=try probe(app),sha=try XCTUnwrap(selected["selected_image_sha256"] as? String)
  app.buttons["chat.send"].tap();XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout:10));let failed=try probe(app)
  XCTAssertEqual(failed["preview_image_sha256"] as? String,sha);XCTAssertEqual(failed["uploaded_image_sha256"] as? String,sha);XCTAssertEqual(failed["upload_count"] as? Int,1)
  XCTAssertEqual(failed["text_only_fallback_count"] as? Int,0);XCTAssertTrue(app.images["chat.imagePreview"].isHittable)
  app.buttons["chat.removeImage"].tap();XCTAssertFalse(app.images["chat.imagePreview"].exists);attach(app,"p0-image-error-retains-preview")
 }
}
