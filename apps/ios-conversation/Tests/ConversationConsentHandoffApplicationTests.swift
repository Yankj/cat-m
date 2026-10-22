import Combine
import Foundation
import UIKit
import XCTest
import catImageComposer
@testable import cat

/// Real model/service entry points with explicitly injected local consent replies.
/// No HTTP, Auth, model, photo-library, image understanding or UI acceptance.
@MainActor final class ConversationConsentHandoffApplicationTests:XCTestCase {
    private struct Fixture {
        let root:URL
        let model:ConversationFirstModel
        let backend:ConsentHandoffTestBackend
        let imageHash:String
    }
    private func fixture(textAllowed:Bool=false) async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("consent-handoff-"+UUID().uuidString)
        let repository=try Repository(persistence:FilePersistence(url:root.appendingPathComponent("store.json")))
        let backend=ConsentHandoffTestBackend(textAllowed:textAllowed)
        let model=ConversationFirstModel(repository:repository,service:ConversationSessionService(repository:repository,backend:backend))
        await model.start();await model.refreshConnection();model.editDraft("Synthetic image caption 🐾")
        let bytes=UIGraphicsImageRenderer(size:CGSize(width:16,height:16)).pngData {context in UIColor.blue.setFill();context.fill(CGRect(x:0,y:0,width:16,height:16))}
        let packet=try await SystemImageAttachmentEncoder().encode(bytes,id:UUID(),format:.png,limits:.init())
        model.imageDraft.restorePrepared(packet)
        return .init(root:root,model:model,backend:backend,imageHash:packet.sha256)
    }
    private func finish(_ f:Fixture) async {_=await f.model.deactivate();try? FileManager.default.removeItem(at:f.root)}
    private func next<Value>(_ publisher:Published<Value?>.Publisher,_ name:String) async throws -> Value {
        let event=expectation(description:name);var received:Value?
        let subscription=publisher.compactMap{$0}.prefix(1).sink{received=$0;event.fulfill()}
        await fulfillment(of:[event],timeout:3)
        withExtendedLifetime(subscription){}
        return try XCTUnwrap(received,name)
    }
    private func savedImageDecision(_ model:ConversationFirstModel) async {
        let event=expectation(description:"image decision finished")
        let subscription=model.$checkingImageConsent.filter{!$0}.prefix(1).sink{_ in event.fulfill()}
        await fulfillment(of:[event],timeout:3);withExtendedLifetime(subscription){}
    }
    private func imageReview(_ f:Fixture) async throws -> (ConversationImageConsent,UUID) {
        f.model.requestImageConsent()
        let consent=try await next(f.model.$pendingImageConsent,"image review")
        await savedImageDecision(f.model)
        return (consent,try XCTUnwrap(f.model.imageConsentReviewToken))
    }
    private func assertDraft(_ f:Fixture,_ text:String="Synthetic image caption 🐾") {
        XCTAssertEqual(f.model.draft,text);XCTAssertEqual(f.model.imageDraft.attachment?.sha256,f.imageHash)
        XCTAssertTrue(f.model.session?.turns.isEmpty == true,"Consent alone must not admit a turn")
    }
    func testTextAllowFastReturnQueuesExactImageReviewWithoutSending() async throws {
        let f=try await fixture();f.model.requestImageConsent()
        let text=try await next(f.model.$pendingModelConsent,"text review"),token=try XCTUnwrap(f.model.modelConsentReviewToken)
        let started=expectation(description:"text grant actually started")
        await f.backend.holdTextGrant{started.fulfill()}
        f.model.allowPendingModelConsent(text,reviewToken:token);f.model.allowPendingModelConsent(text,reviewToken:token)
        await fulfillment(of:[started],timeout:3)
        XCTAssertNil(f.model.pendingModelConsent);XCTAssertNil(f.model.modelConsentReviewToken);XCTAssertNil(f.model.pendingImageConsent)
        assertDraft(f);var counts=await f.backend.counts();XCTAssertEqual(counts,[1,0,0])
        await f.backend.releaseTextGrant()
        let image=try await next(f.model.$pendingImageConsent,"image review after text acknowledgement")
        await savedImageDecision(f.model)
        let imageToken=try XCTUnwrap(f.model.imageConsentReviewToken)
        XCTAssertTrue(f.model.matchesImageConsent(image,reviewToken:imageToken));XCTAssertEqual(image.previewHash,f.imageHash)
        f.model.allowPendingImageConsent(image,confirmed:false,reviewToken:imageToken)
        counts=await f.backend.counts();XCTAssertEqual(counts,[1,0,0]);assertDraft(f);await finish(f)
    }
    func testImageAllowConsumesOnceWhileHeldAndOldCancelCannotAbortSaving() async throws {
        let f=try await fixture(textAllowed:true),(image,token)=try await imageReview(f)
        let started=expectation(description:"image grant actually started");await f.backend.holdImageGrant{started.fulfill()}
        f.model.allowPendingImageConsent(image,confirmed:true,reviewToken:token)
        f.model.allowPendingImageConsent(image,confirmed:true,reviewToken:token)
        await fulfillment(of:[started],timeout:3)
        XCTAssertTrue(f.model.checkingImageConsent);XCTAssertEqual(f.model.imageConsentReviewToken,token)
        XCTAssertFalse(f.model.cancelImageConsent(matching:image,reviewToken:token))
        var counts=await f.backend.counts();XCTAssertEqual(counts,[0,1,0])
        await f.backend.releaseImageGrant();await savedImageDecision(f.model)
        XCTAssertTrue(f.model.imageGate.imageConsentMatchesCurrentRoute);XCTAssertNil(f.model.imageConsentReviewToken);XCTAssertNil(f.model.pendingImageConsent)
        f.model.allowPendingImageConsent(image,confirmed:true,reviewToken:token)
        counts=await f.backend.counts();XCTAssertEqual(counts,[0,1,0]);assertDraft(f);await finish(f)
    }
    func testTextPresentationClearRetainsOriginalReviewAuthority() async throws {
        let f=try await fixture();f.model.requestImageConsent()
        let consent=try await next(f.model.$pendingModelConsent,"text review"),token=try XCTUnwrap(f.model.modelConsentReviewToken)
        f.model.pendingModelConsent=nil
        XCTAssertTrue(f.model.matchesModelConsent(consent,reviewToken:token))
        f.model.allowPendingModelConsent(consent,reviewToken:token)
        _=try await next(f.model.$pendingImageConsent,"image review")
        let counts=await f.backend.counts();XCTAssertEqual(counts,[1,0,0]);assertDraft(f);await finish(f)
    }
    func testImagePresentationClearCannotBecomeImplicitDenialOrSend() async throws {
        let f=try await fixture(textAllowed:true),(consent,token)=try await imageReview(f)
        f.model.pendingImageConsent=nil
        XCTAssertTrue(f.model.matchesImageConsent(consent,reviewToken:token))
        f.model.allowPendingImageConsent(consent,confirmed:true,reviewToken:token);await savedImageDecision(f.model)
        XCTAssertTrue(f.model.imageGate.imageConsentMatchesCurrentRoute)
        let counts=await f.backend.counts();XCTAssertEqual(counts,[0,1,0]);assertDraft(f);await finish(f)
    }
    func testOldTextPresentationCannotDeferOrAllowNewIdenticalReview() async throws {
        let f=try await fixture();f.model.requestImageConsent()
        let old=try await next(f.model.$pendingModelConsent,"first text review"),oldToken=try XCTUnwrap(f.model.modelConsentReviewToken)
        XCTAssertTrue(f.model.deferModelConsent(old,reviewToken:oldToken));f.model.requestImageConsent()
        let current=try await next(f.model.$pendingModelConsent,"reopened text review"),currentToken=try XCTUnwrap(f.model.modelConsentReviewToken)
        XCTAssertNotEqual(currentToken,oldToken);XCTAssertEqual(old.routeHash,current.routeHash);XCTAssertEqual(old.expectedRevision,current.expectedRevision)
        XCTAssertFalse(f.model.deferModelConsent(old,reviewToken:oldToken));f.model.allowPendingModelConsent(old,reviewToken:oldToken)
        XCTAssertTrue(f.model.matchesModelConsent(current,reviewToken:currentToken));XCTAssertNotNil(f.model.pendingModelConsent)
        let counts=await f.backend.counts();XCTAssertEqual(counts,[0,0,0]);assertDraft(f);await finish(f)
    }
    func testOldImagePresentationCannotCancelOrAllowReopenedPreview() async throws {
        let f=try await fixture(textAllowed:true),(old,oldToken)=try await imageReview(f)
        XCTAssertTrue(f.model.cancelImageConsent(matching:old,reviewToken:oldToken))
        let (current,currentToken)=try await imageReview(f)
        XCTAssertNotEqual(oldToken,currentToken);XCTAssertEqual(old.previewHash,current.previewHash)
        XCTAssertFalse(f.model.cancelImageConsent(matching:old,reviewToken:oldToken));f.model.allowPendingImageConsent(old,confirmed:true,reviewToken:oldToken)
        XCTAssertTrue(f.model.matchesImageConsent(current,reviewToken:currentToken))
        let counts=await f.backend.counts();XCTAssertEqual(counts,[0,0,0]);assertDraft(f);await finish(f)
    }
    func testChangedModelNoticeOrRevisionCannotConsumeMatchingToken() async throws {
        let f=try await fixture();f.model.requestImageConsent()
        let c=try await next(f.model.$pendingModelConsent,"text review"),token=try XCTUnwrap(f.model.modelConsentReviewToken)
        let wrong=[ConversationModelConsent(conversationID:UUID(),title:c.title,body:c.body,routeHash:c.routeHash,expectedRevision:c.expectedRevision),
                   ConversationModelConsent(conversationID:c.conversationID,title:c.title,body:c.body,routeHash:textHash("wrong route"),expectedRevision:c.expectedRevision),
                   ConversationModelConsent(conversationID:c.conversationID,title:c.title,body:c.body,routeHash:c.routeHash,expectedRevision:c.expectedRevision+1),
                   ConversationModelConsent(conversationID:c.conversationID,title:c.title+" changed",body:c.body,routeHash:c.routeHash,expectedRevision:c.expectedRevision),
                   ConversationModelConsent(conversationID:c.conversationID,title:c.title,body:c.body+" changed",routeHash:c.routeHash,expectedRevision:c.expectedRevision)]
        for value in wrong {XCTAssertFalse(f.model.matchesModelConsent(value,reviewToken:token));XCTAssertFalse(f.model.deferModelConsent(value,reviewToken:token));f.model.allowPendingModelConsent(value,reviewToken:token)}
        XCTAssertTrue(f.model.matchesModelConsent(c,reviewToken:token));let counts=await f.backend.counts();XCTAssertEqual(counts,[0,0,0]);await finish(f)
    }
    func testCaptionChangeRetiresImageTokenWithoutLosingPreview() async throws {
        let f=try await fixture(textAllowed:true),(consent,token)=try await imageReview(f)
        f.model.editDraft("Changed caption 🐾")
        XCTAssertNil(f.model.imageConsentReviewToken);XCTAssertFalse(f.model.matchesImageConsent(consent,reviewToken:token))
        XCTAssertFalse(f.model.cancelImageConsent(matching:consent,reviewToken:token));f.model.allowPendingImageConsent(consent,confirmed:true,reviewToken:token)
        let counts=await f.backend.counts();XCTAssertEqual(counts,[0,0,0]);assertDraft(f,"Changed caption 🐾");await finish(f)
    }
    func testUnknownImageGrantOutcomeKeepsInputAndNeverAutomaticallyRetries() async throws {
        let f=try await fixture(textAllowed:true),(consent,token)=try await imageReview(f)
        let started=expectation(description:"uncertain image grant started");await f.backend.holdImageGrant{started.fulfill()}
        f.model.allowPendingImageConsent(consent,confirmed:true,reviewToken:token);await fulfillment(of:[started],timeout:3)
        await f.backend.releaseImageGrant(uncertain:true)
        _=try await next(f.model.$error,"uncertain grant reported")
        XCTAssertNil(f.model.imageConsentReviewToken);XCTAssertNil(f.model.pendingImageConsent);XCTAssertFalse(f.model.imageGate.imageConsentMatchesCurrentRoute)
        f.model.allowPendingImageConsent(consent,confirmed:true,reviewToken:token)
        let counts=await f.backend.counts();XCTAssertEqual(counts,[0,1,0]);assertDraft(f);await finish(f)
    }
    func testNetworkClosureRetiresBothReviewKindsAndRejectsOldCallbacks() async throws {
        for allowed in [false,true] {
            let f=try await fixture(textAllowed:allowed);f.model.requestImageConsent()
            if allowed {
                let c=try await next(f.model.$pendingImageConsent,"image review"),token=try XCTUnwrap(f.model.imageConsentReviewToken)
                f.model.setNetworkAdmissionAllowed(false)
                XCTAssertNil(f.model.imageConsentReviewToken);XCTAssertFalse(f.model.matchesImageConsent(c,reviewToken:token))
                f.model.allowPendingImageConsent(c,confirmed:true,reviewToken:token)
            } else {
                let c=try await next(f.model.$pendingModelConsent,"text review"),token=try XCTUnwrap(f.model.modelConsentReviewToken)
                f.model.setNetworkAdmissionAllowed(false)
                XCTAssertNil(f.model.modelConsentReviewToken);XCTAssertFalse(f.model.matchesModelConsent(c,reviewToken:token))
                f.model.allowPendingModelConsent(c,reviewToken:token)
            }
            XCTAssertNil(f.model.pendingImageConsent);XCTAssertNil(f.model.pendingModelConsent)
            let counts=await f.backend.counts();XCTAssertEqual(counts,[0,0,0]);assertDraft(f);await finish(f)
        }
    }
}

private actor ConsentHandoffTestBackend:ConversationBackend {
    private let textRoute=textHash("named offline consent text route"),imageRoute=textHash("named offline consent image route")
    private var textAllowed:Bool
    private var imageRevision=0,textGrants=0,imageGrants=0,replies=0
    private var textStarted:(@Sendable()->Void)?,imageStarted:(@Sendable()->Void)?
    private var holdText=false,holdImage=false,uncertainImage=false
    private var heldText:CheckedContinuation<Void,Never>?,heldImage:CheckedContinuation<Void,Never>?
    init(textAllowed:Bool){self.textAllowed=textAllowed}
    func counts()->[Int]{[textGrants,imageGrants,replies]}
    func holdTextGrant(_ started:@escaping @Sendable()->Void){holdText=true;textStarted=started}
    func holdImageGrant(_ started:@escaping @Sendable()->Void){holdImage=true;imageStarted=started}
    func releaseTextGrant(){holdText=false;heldText?.resume();heldText=nil}
    func releaseImageGrant(uncertain:Bool=false){uncertainImage=uncertain;holdImage=false;heldImage?.resume();heldImage=nil}
    func connection(scope:DataScope) async ->ConversationConnection {.init(state:.providerUnverified,provider:"Named offline consent fixture",detail:"No HTTP/Auth/model")}
    func modelConsent(scope:DataScope,conversationID:UUID) async throws ->ConversationModelConsent? {
        textAllowed ? nil:.init(conversationID:conversationID,title:"Synthetic text consent",body:"Injected local response only; no network, model or actual image understanding.",routeHash:textRoute,expectedRevision:0)
    }
    func allowModelConsent(scope:DataScope,consent:ConversationModelConsent) async throws {
        guard !textAllowed,consent.routeHash==textRoute,consent.expectedRevision==0 else {throw ConversationSessionError.invalidEvent}
        textGrants+=1;textStarted?();if holdText {await withCheckedContinuation{heldText=$0}};textAllowed=true
    }
    func imageCapabilities(scope:DataScope,conversationID:UUID) async throws ->ConversationImageCapability {.init(available:true,liveTransmissionAvailable:true,routeHash:imageRoute,state:"named_offline_fixture",detail:"No actual image request")}
    func imageConsent(scope:DataScope,conversationID:UUID,previewID:UUID,previewHash:String) async throws ->ConversationImageConsent {
        .init(conversationID:conversationID,previewID:previewID,previewHash:previewHash,routeHash:imageRoute,expectedRevision:imageRevision,title:"Synthetic image consent",body:"Local fixture only",confirmation:"Confirm synthetic nonsensitive image",allowLabel:"Allow fixture",denyLabel:"Cancel")
    }
    func allowImageConsent(scope:DataScope,consent:ConversationImageConsent,nonSensitiveConfirmed:Bool) async throws ->Int {
        guard textAllowed,nonSensitiveConfirmed,consent.routeHash==imageRoute,consent.expectedRevision==imageRevision else {throw ConversationSessionError.invalidEvent}
        imageGrants+=1;imageStarted?();if holdImage {await withCheckedContinuation{heldImage=$0}};imageRevision+=1
        if uncertainImage {throw URLError(.networkConnectionLost)};return imageRevision
    }
    func observe(_ request:ConversationTurnRequest) async throws ->ConversationObservation {throw ConversationSessionError.notConfigured}
    func reply(_ request:ConversationTurnRequest) async throws ->AsyncThrowingStream<ConversationTurnEvent,Error> {
        replies+=1;throw ConversationDispatchFailure.notSent(reason:"This consent-only fixture must not send a turn")
    }
}
