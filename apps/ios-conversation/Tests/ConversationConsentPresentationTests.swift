import XCTest
@testable import CatpawM

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
}

final class AppModelConsentGrantTests: XCTestCase {
    override func setUp() { AppModelConsentGrant.defaults = UserDefaults(suiteName: "AppModelConsentGrantTests")!; AppModelConsentGrant.defaults.removePersistentDomain(forName: "AppModelConsentGrantTests") }
    override func tearDown() { AppModelConsentGrant.defaults = .standard }
    func testAskOnceThenReuseByRouteHash() {
        XCTAssertNil(AppModelConsentGrant.current); XCTAssertTrue(AppModelConsentGrant.serverAllowHonored)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        AppModelConsentGrant.record(routeHash: "h1", at: t)
        XCTAssertEqual(AppModelConsentGrant.current, .init(routeHash: "h1", grantedAt: t))
        XCTAssertTrue(AppModelConsentGrant.matches("h1"))
        XCTAssertFalse(AppModelConsentGrant.matches("h2"), "a material disclosure change must re-ask")
    }
    func testRevocationStopsServerAllowUntilReGranted() {
        AppModelConsentGrant.record(routeHash: "h1"); AppModelConsentGrant.revoke()
        XCTAssertNil(AppModelConsentGrant.current); XCTAssertFalse(AppModelConsentGrant.matches("h1"))
        XCTAssertFalse(AppModelConsentGrant.serverAllowHonored)
        AppModelConsentGrant.record(routeHash: "h1")
        XCTAssertTrue(AppModelConsentGrant.serverAllowHonored); XCTAssertNil(AppModelConsentGrant.revokedAt)
    }
}
