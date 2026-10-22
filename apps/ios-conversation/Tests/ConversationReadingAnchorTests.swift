import XCTest
import SwiftUI
import UIKit
@testable import cat

final class ConversationReadingAnchorTests:XCTestCase {
    private let a=UUID(),b=UUID(),c=UUID()
    private func row(_ id:UUID,_ y:Double,_ height:Double=400)->ConversationReadingAnchorRow {.init(id:id,minY:y,height:height)}
    private let viewport=ConversationReadingAnchorViewport(top:500,bottom:800)
    private func saved()->ConversationReadingAnchorSnapshot {
        ConversationReadingAnchorPolicy.capture(rows:[row(a,0),row(b,400),row(c,800)],viewport:viewport,orderedIDs:[a,b,c])!
    }
    func testUpperGrowthPreservesPointInsideStableBlock() {
        let old=saved();XCTAssertEqual(old.record.rowID,b);XCTAssertEqual(old.record.intraOffset,100)
        let value=ConversationReadingAnchorPolicy.correction(from:old,rows:[row(a,0,640),row(b,640),row(c,1040)],viewport:viewport,orderedIDs:[a,b,c])
        XCTAssertEqual(value?.delta,240);XCTAssertEqual(value?.usedFallback,false)
    }
    func testUpperShrinkCompensatesInOppositeDirection() {
        let value=ConversationReadingAnchorPolicy.correction(from:saved(),rows:[row(a,0,320),row(b,320),row(c,720)],viewport:viewport,orderedIDs:[a,b,c])
        XCTAssertEqual(value?.delta,-80)
    }
    func testLowerGrowthAndSameBlockTailGrowthDoNotMoveReadingPoint() {
        for rows in [[row(a,0),row(b,400),row(c,800,900)],[row(a,0),row(b,400,900),row(c,1300)]] {
            XCTAssertEqual(ConversationReadingAnchorPolicy.correction(from:saved(),rows:rows,viewport:viewport,orderedIDs:[a,b,c])?.delta,0)
        }
    }
    func testDeletedAndRecycledRowsUseMeasuredNeighbourWithoutTotalSizeGuessing() {
        for ids in [[a,b,c],[a,c]] {
            let value=ConversationReadingAnchorPolicy.correction(from:saved(),rows:[row(a,0),row(c,880)],viewport:viewport,orderedIDs:ids)
            XCTAssertEqual(value?.referenceRowID,c);XCTAssertEqual(value?.delta,80)
            XCTAssertEqual(value?.usedFallback,true);XCTAssertEqual(value?.savedRowWasRemoved,!ids.contains(b))
        }
    }
    func testNoCommonMeasuredRowCannotInventCorrection() {
        XCTAssertNil(ConversationReadingAnchorPolicy.correction(from:saved(),rows:[],viewport:viewport,orderedIDs:[a,b,c]))
    }
    func testDuplicateOrNonfiniteGeometryCannotBecomeAnAnchor() {
        XCTAssertNil(ConversationReadingAnchorPolicy.capture(rows:[row(a,400),row(a,410)],viewport:viewport,orderedIDs:[a]))
        XCTAssertNil(ConversationReadingAnchorPolicy.capture(rows:[row(a,.nan)],viewport:viewport,orderedIDs:[a]))
        XCTAssertNil(ConversationReadingAnchorPolicy.capture(rows:[row(a,0)],viewport:.init(top:.infinity,bottom:800),orderedIDs:[a]))
    }
    func testFollowLatestAndUserMotionTakePriorityOverCompensation() {
        XCTAssertFalse(ConversationReadingAnchorPolicy.shouldCompensate(followingLatest:true,isUserScrolling:false))
        XCTAssertFalse(ConversationReadingAnchorPolicy.shouldCompensate(followingLatest:false,isUserScrolling:true))
        XCTAssertTrue(ConversationReadingAnchorPolicy.shouldCompensate(followingLatest:false,isUserScrolling:false))
    }
    @MainActor func testNativeOffsetChangeBecomesNewAnchorInsteadOfBeingPulledBack() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let previous=scene.windows.first{$0.isKeyWindow},window=UIWindow(windowScene:scene)
        let coordinator=ConversationReadingAnchorCoordinator()
        let context=ConversationReadingAnchorContext(profileID:UUID(),scopeID:UUID(),conversationID:UUID())
        let ids=[a,b,c]
        let content=ScrollView {
            VStack(spacing:0) {
                ForEach(ids,id:\.self) { id in
                    Color.clear.frame(height:400).background(ConversationReadingAnchorMarker(id:id,context:context,coordinator:coordinator))
                }
            }.background(ConversationReadingAnchorTracker(context:context,followingLatest:false,orderedIDs:ids,coordinator:coordinator))
        }
        let host=UIHostingController(rootView:content)
        window.rootViewController=host;window.frame=CGRect(x:0,y:0,width:390,height:600);window.makeKeyAndVisible()
        defer {window.isHidden=true;window.rootViewController=nil;previous?.makeKey()}
        func descendants(_ view:UIView)->[UIView] {[view]+view.subviews.flatMap(descendants)}
        var scroll:UIScrollView?
        for _ in 0..<80 {
            host.view.layoutIfNeeded();scroll=descendants(host.view).compactMap{$0 as? UIScrollView}.first
            if let scroll,scroll.contentSize.height>1000,coordinator.snapshot != nil {break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        let native=try XCTUnwrap(scroll);XCTAssertGreaterThan(native.contentSize.height,1000)
        let originalDelegate=native.delegate
        native.setContentOffset(CGPoint(x:0,y:100),animated:false)
        for _ in 0..<40 {if coordinator.snapshot != nil {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNotNil(coordinator.snapshot)
        native.setContentOffset(CGPoint(x:0,y:105),animated:false)
        XCTAssertNil(coordinator.snapshot,"KVO must relinquish the old snapshot at the native offset event, before async layout")
        for _ in 0..<40 {if coordinator.snapshot != nil {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNotNil(coordinator.snapshot)
        let resting=coordinator.snapshot
        native.setContentOffset(CGPoint(x:0,y:105),animated:false)
        XCTAssertEqual(coordinator.snapshot,resting,"A same-value native notification is not user motion and must not discard the saved reading point")
        XCTAssertEqual(native.contentOffset.y,105,accuracy:0.1,"Programmatic/VO/last inertial offset must not be pulled back to100")
        XCTAssertTrue(native.delegate === originalDelegate);XCTAssertTrue(native.bounces)
    }
}
