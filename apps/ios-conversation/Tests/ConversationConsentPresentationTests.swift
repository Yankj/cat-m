import XCTest
@testable import cat

final class ConversationConsentPresentationTests:XCTestCase {
    private final class Owner {}
    private let owner=Owner()
    private func request(_ token:UUID=UUID(),conversation:UUID=UUID(),revision:Int=0)->ConversationConsentPresentation {
        .init(id:token,modelIdentity:ObjectIdentifier(owner),scope:Profiles.user,
              content:.model(.init(conversationID:conversation,title:"Original permission",body:"Original notice",routeHash:textHash("route"),expectedRevision:revision)))
    }
    func testFastNextReviewWaitsForActualDismissalAndLateNilCannotCancelIt() {
        let a=request(),b=request();var state=ConversationConsentPresentationCoordinator()
        state.reconcile(a);state.didAppear(a.id);XCTAssertEqual(state.active,a)
        state.reconcile(nil);XCTAssertNil(state.active);XCTAssertEqual(state.closing,a.id)
        state.reconcile(b);XCTAssertNil(state.active);XCTAssertEqual(state.desired,b)
        XCTAssertNil(state.userDismiss(a.id))
        state.didDismiss(a.id);XCTAssertEqual(state.active,b)
        XCTAssertNil(state.userDismiss(a.id));state.didDismiss(a.id);XCTAssertEqual(state.active,b)
    }
    func testUnshownReviewCanBeCancelledOrReplacedWithoutWaitingForImpossibleDismissal() {
        let a=request(),b=request();var state=ConversationConsentPresentationCoordinator()
        state.reconcile(a);state.reconcile(nil);XCTAssertNil(state.active);XCTAssertNil(state.closing)
        state.reconcile(b);XCTAssertEqual(state.active,b)
        state.didAppear(a.id);state.didDismiss(a.id);XCTAssertEqual(state.active,b);XCTAssertNil(state.appeared)
        state.didAppear(b.id);XCTAssertEqual(state.appeared,b.id)
    }
    func testSlowNextReviewArrivesAfterDismissalWithSameBehavior() {
        let a=request(),b=request();var state=ConversationConsentPresentationCoordinator()
        state.reconcile(a);state.didAppear(a.id);state.reconcile(nil);state.didDismiss(a.id)
        XCTAssertNil(state.active);XCTAssertNil(state.closing)
        state.reconcile(b);XCTAssertEqual(state.active,b)
    }
    func testBackgroundOrAccountChangeBeforeDismissalCannotPromoteCachedReview() {
        let a=request(),b=request();var state=ConversationConsentPresentationCoordinator()
        state.reconcile(a);state.didAppear(a.id);state.reconcile(b);XCTAssertNil(state.active)
        state.reconcile(nil);state.didDismiss(a.id)
        XCTAssertNil(state.active);XCTAssertNil(state.desired)
    }
    func testUserDismissReturnsOnlyExactRenderedSnapshotOnce() {
        let a=request(),b=request();var state=ConversationConsentPresentationCoordinator()
        state.reconcile(a);state.didAppear(a.id);XCTAssertNil(state.userDismiss(b.id));XCTAssertEqual(state.active,a)
        XCTAssertEqual(state.userDismiss(a.id),a);XCTAssertNil(state.userDismiss(a.id))
        state.reconcile(b);XCTAssertNil(state.active);state.didDismiss(a.id);XCTAssertEqual(state.active,b)
    }
    func testReopeningSameConsentRequiresNewOwnerAndUnchangedReviewDoesNotClose() {
        let conversation=UUID(),a=request(conversation:conversation),b=request(conversation:conversation)
        var state=ConversationConsentPresentationCoordinator();state.reconcile(a);state.didAppear(a.id);state.reconcile(a)
        XCTAssertEqual(state.active,a);XCTAssertNil(state.closing)
        state.reconcile(b);XCTAssertNil(state.active);XCTAssertEqual(state.closing,a.id)
        state.didDismiss(b.id);XCTAssertNil(state.active)
        state.didDismiss(a.id);XCTAssertEqual(state.active,b);XCTAssertNil(state.userDismiss(a.id))
    }
    func testImageSnapshotPreservesOriginalPreviewCaptionAndRoute() {
        let c=ConversationImageConsent(conversationID:UUID(),previewID:UUID(),previewHash:textHash("image"),routeHash:textHash("image-route"),expectedRevision:4,title:"Image",body:"Original image notice",confirmation:"Review",allowLabel:"Allow",denyLabel:"Later")
        let raw="Line one\n\n  exact caption  ",bytes=Data([1,2,3])
        let a=ConversationConsentPresentation(id:UUID(),modelIdentity:ObjectIdentifier(owner),scope:Profiles.user,content:.image(c,preview:bytes,caption:raw))
        var state=ConversationConsentPresentationCoordinator();state.reconcile(a)
        XCTAssertEqual(state.active,a)
        guard let content=state.active?.content,case .image(let consent,let preview,let caption)=content else {return XCTFail("Original typed image review required")}
        XCTAssertEqual(consent,c);XCTAssertEqual(preview,bytes);XCTAssertTrue(caption.utf8.elementsEqual(raw.utf8))
    }

    /// W1: the consent sheet shows the Gemini free-tier disclosure (may train / human review) when the route carries it.
    func testConsentBodyShowsGeminiAndOpenCodeDisclosuresWithPolicyLinks() {
        let gemini="If the Google Gemini route is used, Google may use it for training. See https://ai.google.dev/gemini-api/terms."
        let route:[String:Any]=["gemini_disclosure":gemini,"opencode_disclosure":"OpenCode Zen notice","policy_urls":["https://ai.google.dev/gemini-api/terms","https://opencode.ai/legal/privacy-policy"]]
        let body=NativeChatHTTPBackend.consentBody("Base notice",metadata:["route":route],ui:[:])
        XCTAssertTrue(body.hasPrefix("Base notice"))
        XCTAssertTrue(body.contains(gemini))
        XCTAssertTrue(body.contains("OpenCode Zen notice"))
        let g=body.range(of:gemini),o=body.range(of:"OpenCode Zen notice")
        XCTAssertNotNil(g);XCTAssertNotNil(o)
        if let g,let o { XCTAssertLessThan(g.lowerBound,o.lowerBound) }
        XCTAssertTrue(body.contains("https://opencode.ai/legal/privacy-policy"))
        let without=NativeChatHTTPBackend.consentBody("Base notice",metadata:["route":["policy_url":"https://openrouter.ai/privacy"]],ui:[:])
        XCTAssertFalse(without.contains("Gemini"))
        XCTAssertEqual(NativeChatHTTPBackend.consentBody("Already: \(gemini)",metadata:["route":["gemini_disclosure":gemini]],ui:[:]),"Already: \(gemini)")
    }
}
