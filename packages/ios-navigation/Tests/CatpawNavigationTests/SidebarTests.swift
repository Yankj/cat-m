import XCTest
@testable import CatpawNavigation

final class SidebarTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private var snapshot: SidebarSnapshot {
        .init(contextID: "synthetic-scope-a", selectedConversationID: first, conversations: [
            .init(id: first, title: "离线示例 Alpha", preview: "查阅书单"),
            .init(id: second, title: "周末计划", preview: "整理 ALPHA 草稿")
        ])
    }
    func testBlankSearchPreservesHistoryOrder() {
        XCTAssertEqual(snapshot.matching(" \n ").map(\.id), [first, second])
    }
    func testSearchMatchesTitleAndPreviewCaseInsensitively() {
        XCTAssertEqual(snapshot.matching(" alpha ").map(\.id), [first, second])
        XCTAssertEqual(snapshot.matching("书单").map(\.id), [first])
        XCTAssertTrue(snapshot.matching("不存在的记录").isEmpty)
    }
    func testConversationRoutingRequiresCurrentScopedRecord() {
        XCTAssertTrue(snapshot.permits(.conversation(first)))
        var changed = snapshot
        changed.contextID = "synthetic-scope-b"
        changed.conversations = [.init(id: second, title: "另一个范围")]
        XCTAssertFalse(changed.permits(.conversation(first)))
        XCTAssertTrue(changed.permits(.conversation(second)))
    }
    func testDefaultUnavailableRoutesCannotBeSelected() {
        XCTAssertTrue(snapshot.permits(.newConversation))
        XCTAssertTrue(snapshot.permits(.settings))
        for destination in [SidebarDestination.tasks, .results, .memory] {
            XCTAssertFalse(snapshot.permits(destination))
        }
    }
    func testCapabilitiesGateAllRouteTypes() {
        var changed = snapshot
        changed.capabilities = .init(canCreateConversation: false, canSelectConversation: false,
                                     tasks: true, results: true, memory: true, settings: false)
        XCTAssertFalse(changed.permits(.newConversation))
        XCTAssertFalse(changed.permits(.conversation(first)))
        XCTAssertFalse(changed.permits(.settings))
        for destination in [SidebarDestination.tasks, .results, .memory] { XCTAssertTrue(changed.permits(destination)) }
    }
    func testDrawerWidthLeavesDismissTargetAndCapsReadableWidth() {
        for width: CGFloat in [375, 390, 430, 1024] {
            XCTAssertEqual(SidebarGesturePolicy.drawerWidth(available: width), 320)
        }
        XCTAssertEqual(SidebarGesturePolicy.drawerWidth(available: 320), 275.2, accuracy: 0.01)
        XCTAssertEqual(SidebarGesturePolicy.drawerWidth(available: 100), 56)
        XCTAssertEqual(SidebarGesturePolicy.drawerWidth(available: 0), 0)
    }
    func testOnlyRootLeftEdgeCanOpen() {
        func allowed(root: Bool = true, shown: Bool = false, x: CGFloat = 0,
                     horizontal: Bool = false, editing: Bool = false) -> Bool {
            SidebarGesturePolicy.mayOpen(isAtRoot: root, isPresented: shown, startX: x,
                                        inHorizontalContent: horizontal, inEditableControl: editing)
        }
        XCTAssertTrue(allowed(x: 24))
        XCTAssertFalse(allowed(root: false))
        XCTAssertFalse(allowed(shown: true))
        XCTAssertFalse(allowed(x: 25))
        XCTAssertFalse(allowed(x: -1))
        XCTAssertFalse(allowed(horizontal: true))
        XCTAssertFalse(allowed(editing: true))
    }
    func testHorizontalIntentPreservesVerticalScrolling() {
        XCTAssertTrue(SidebarGesturePolicy.acceptsDirection(.opening, x: 100, y: 10))
        XCTAssertTrue(SidebarGesturePolicy.acceptsDirection(.closing, x: -100, y: 10))
        XCTAssertFalse(SidebarGesturePolicy.acceptsDirection(.opening, x: -100, y: 0))
        XCTAssertFalse(SidebarGesturePolicy.acceptsDirection(.closing, x: 100, y: 0))
        XCTAssertFalse(SidebarGesturePolicy.acceptsDirection(.opening, x: 10, y: 100))
        XCTAssertFalse(SidebarGesturePolicy.acceptsDirection(.closing, x: -10, y: 100))
        XCTAssertFalse(SidebarGesturePolicy.acceptsDirection(.opening, x: 0, y: 0))
    }
    func testInteractiveProgressClampsAndHandlesZeroWidth() {
        XCTAssertEqual(SidebarGesturePolicy.progress(direction: .opening, translationX: 160, width: 320), 0.5)
        XCTAssertEqual(SidebarGesturePolicy.progress(direction: .opening, translationX: -10, width: 320), 0)
        XCTAssertEqual(SidebarGesturePolicy.progress(direction: .opening, translationX: 1000, width: 320), 1)
        XCTAssertEqual(SidebarGesturePolicy.progress(direction: .closing, translationX: -160, width: 320), 0.5)
        XCTAssertEqual(SidebarGesturePolicy.progress(direction: .closing, translationX: -1000, width: 320), 0)
        XCTAssertEqual(SidebarGesturePolicy.progress(direction: .opening, translationX: 100, width: 0), 0)
        XCTAssertEqual(SidebarGesturePolicy.progress(direction: .closing, translationX: -100, width: 0), 1)
    }
    func testSlowDragSettlesAtHalfWidth() {
        for direction in [SidebarDragDirection.opening, .closing] {
            XCTAssertFalse(SidebarGesturePolicy.settlesOpen(direction: direction, progress: 0.49, velocityX: 0, cancelled: false))
            XCTAssertTrue(SidebarGesturePolicy.settlesOpen(direction: direction, progress: 0.5, velocityX: 0, cancelled: false))
        }
    }
    func testDirectionalFlickOverridesDistance() {
        XCTAssertTrue(SidebarGesturePolicy.settlesOpen(direction: .opening, progress: 0.1, velocityX: 401, cancelled: false))
        XCTAssertFalse(SidebarGesturePolicy.settlesOpen(direction: .closing, progress: 0.9, velocityX: -401, cancelled: false))
    }
    func testContentOpeningIsExplicitAndPreservesAllExclusions() {
        XCTAssertFalse(SidebarGesturePolicy.mayOpen(isAtRoot: true, isPresented: false, startX: 180, inHorizontalContent: false, inEditableControl: false))
        XCTAssertTrue(SidebarGesturePolicy.mayOpen(isAtRoot: true, isPresented: false, startX: 180, inHorizontalContent: false, inEditableControl: false, allowsContentPan: true))
        for (root, shown, horizontal, editing, x) in [(false, false, false, false, CGFloat(180)), (true, true, false, false, 180), (true, false, true, false, 180), (true, false, false, true, 180), (true, false, false, false, -1)] {
            XCTAssertFalse(SidebarGesturePolicy.mayOpen(isAtRoot: root, isPresented: shown, startX: x, inHorizontalContent: horizontal, inEditableControl: editing, allowsContentPan: true))
        }
    }
    func testMidSettlePanCanAcquireEitherDirectionButNotVerticalReading() {
        XCTAssertTrue(SidebarGesturePolicy.acceptsPan(progress: 0.4, x: 100, y: 10))
        XCTAssertTrue(SidebarGesturePolicy.acceptsPan(progress: 0.4, x: -100, y: 10))
        XCTAssertFalse(SidebarGesturePolicy.acceptsPan(progress: 0.4, x: 10, y: 100))
        XCTAssertFalse(SidebarGesturePolicy.acceptsPan(progress: 0, x: -100, y: 0))
        XCTAssertFalse(SidebarGesturePolicy.acceptsPan(progress: 1, x: 100, y: 0))
    }
    func testRegrabUsesVisiblePositionRatherThanOpenTarget() {
        var state = SidebarMotionState()
        state.move(to: true, reduceMotion: false); state.advance(seconds: 0.05)
        let visible = state.position
        XCTAssertGreaterThan(visible, 0); XCTAssertLessThan(visible, 1)
        state.beginDrag(); state.drag(translationX: 0, width: 320)
        XCTAssertEqual(state.position, visible, accuracy: 0.000001)
        state.drag(translationX: -32, width: 320)
        XCTAssertEqual(state.position, max(0, visible - 0.1), accuracy: 0.000001)
        XCTAssertTrue(state.isDragging); XCTAssertFalse(state.isSettling)
    }
    func testDragCancellationRestoresEndpointSelectedBeforeGrab() {
        var state = SidebarMotionState()
        state.move(to: true, reduceMotion: false); state.advance(seconds: 0.05)
        state.beginDrag(); state.drag(translationX: -300, width: 320)
        XCTAssertTrue(state.endDrag(velocityX: -2_000, width: 320, cancelled: true, reduceMotion: false))
        state.advance(seconds: 2)
        XCTAssertEqual(state.position, 1); XCTAssertTrue(state.isFullyOpen)
        state.move(to: false, reduceMotion: false); state.advance(seconds: 0.05)
        state.beginDrag(); state.drag(translationX: 300, width: 320)
        XCTAssertFalse(state.endDrag(velocityX: 2_000, width: 320, cancelled: true, reduceMotion: false))
        state.advance(seconds: 2)
        XCTAssertEqual(state.position, 0); XCTAssertFalse(state.isVisible)
    }
    func testReducedMotionStillTracksFingerAndOnlyRemovesSettleInertia() {
        var state = SidebarMotionState()
        state.beginDrag(); state.drag(translationX: 96, width: 320)
        state.removeInertia()
        XCTAssertEqual(state.position, 0.3, accuracy: 0.000001)
        XCTAssertTrue(state.isDragging)
        XCTAssertTrue(state.endDrag(velocityX: 600, width: 320, cancelled: false, reduceMotion: true))
        XCTAssertEqual(state.position, 1); XCTAssertTrue(state.isFullyOpen); XCTAssertFalse(state.isSettling)
    }
    func testSpringPartitionAndRapidRetargetPreserveContinuousPosition() {
        var whole = SidebarMotionState(), split = SidebarMotionState()
        whole.move(to: true, reduceMotion: false); split.move(to: true, reduceMotion: false)
        whole.advance(seconds: 0.1); split.advance(seconds: 0.04); split.advance(seconds: 0.06)
        XCTAssertEqual(whole.position, split.position, accuracy: 0.000001)
        XCTAssertEqual(whole.velocity, split.velocity, accuracy: 0.000001)
        let position = split.position, velocity = split.velocity
        split.move(to: false, reduceMotion: false)
        XCTAssertEqual(split.position, position); XCTAssertEqual(split.velocity, velocity)
        split.advance(seconds: 2)
        XCTAssertEqual(split.position, 0); XCTAssertFalse(split.isVisible)
    }
    func testResetRejectsLateTickAndLateDragEnd() {
        var state = SidebarMotionState()
        state.move(to: true, reduceMotion: false); state.advance(seconds: 0.1)
        state.beginDrag(); state.reset()
        state.drag(translationX: 300, width: 320); state.advance(seconds: 2)
        XCTAssertFalse(state.endDrag(velocityX: 1_000, width: 320, cancelled: true, reduceMotion: false))
        XCTAssertEqual(state.position, 0); XCTAssertFalse(state.isVisible)
    }
    func testReadonlyTextCanRevealWhileEditingMarkedAndSelectionRetainTouch() {
        XCTAssertFalse(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: false, selectionLength: 0, selectionGestureActive: false))
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: true, hasMarkedText: false, selectionLength: 0, selectionGestureActive: false))
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: true, selectionLength: 0, selectionGestureActive: false))
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: false, selectionLength: 2, selectionGestureActive: false))
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: false, selectionLength: 0, selectionGestureActive: true))
    }
    func testForegroundRoundingOnlyGrowsWithVisibleRevealAndClamps() {
        XCTAssertEqual(SidebarGesturePolicy.foregroundCornerRadius(progress: 0), 0)
        XCTAssertEqual(SidebarGesturePolicy.foregroundCornerRadius(progress: 0.5), 12)
        XCTAssertEqual(SidebarGesturePolicy.foregroundCornerRadius(progress: 1), 24)
        XCTAssertEqual(SidebarGesturePolicy.foregroundCornerRadius(progress: -1), 0)
        XCTAssertEqual(SidebarGesturePolicy.foregroundCornerRadius(progress: 2), 24)
        XCTAssertEqual(SidebarGesturePolicy.foregroundCornerRadius(progress: .nan), 0)
    }
    func testHistoricalReadonlySelectionDoesNotPermanentlyOwnTouch() {
        XCTAssertFalse(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: false, selectionLength: 8, selectionGestureActive: false, isFirstResponder: false), "An unfocused TextKit display may retain a historical selectedRange")
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: false, selectionLength: 8, selectionGestureActive: false, isFirstResponder: true), "The same range with actual selection ownership still takes priority")
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: false, selectionLength: 0, selectionGestureActive: true, isFirstResponder: false), "Native long-press selection wins even before first responder is acquired")
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: true, hasMarkedText: false, selectionLength: 0, selectionGestureActive: false, isFirstResponder: false))
        XCTAssertTrue(SidebarGesturePolicy.textViewOwnsTouch(isEditable: false, hasMarkedText: true, selectionLength: 0, selectionGestureActive: false, isFirstResponder: false))
    }
    func testClosingRetainsModalOwnershipUntilPhysicalEndpointAndCanBeReopened() {
        var state = SidebarMotionState()
        state.move(to: true, reduceMotion: true)
        state.move(to: false, reduceMotion: false)
        XCTAssertFalse(state.targetOpen); XCTAssertTrue(state.isVisible)
        state.advance(seconds: 0.1)
        XCTAssertGreaterThan(state.position, 0); XCTAssertTrue(state.isVisible, "A close intent is not permission to interact with the moving conversation")
        let visible = state.position
        state.move(to: true, reduceMotion: false)
        XCTAssertEqual(state.position, visible, "A new open intent reverses from the physical position")
        state.advance(seconds: 2); XCTAssertTrue(state.isFullyOpen)
        state.move(to: false, reduceMotion: false); state.advance(seconds: 2)
        XCTAssertEqual(state.position, 0); XCTAssertFalse(state.isVisible, "Only the physical closed endpoint returns foreground interaction")
    }
    func testVisibleScrimBoundsEndAtScreenEdgeForEveryRevealFraction() {
        for viewport: CGFloat in [320, 375, 402, 430, 1024] {
            let drawer = SidebarGesturePolicy.drawerWidth(available: viewport)
            for progress: CGFloat in [0, 0.1, 0.5, 1] {
                let translation = drawer * progress
                let width = SidebarForegroundLayout.visibleWidth(viewportWidth: viewport, translation: translation)
                let frame = CGRect(x: translation, y: 62, width: width, height: 778)
                XCTAssertEqual(frame.maxX, viewport, accuracy: 0.000001)
                XCTAssertGreaterThanOrEqual(width, 44)
                XCTAssertLessThan(frame.midX, viewport, "The computed activation point must remain on-screen")
            }
        }
    }
    func testMeasuredBuild32ScrimCounterexampleHasOnscreenReplacement() {
        let failed = CGRect(x: 320, y: 62, width: 402, height: 778)
        XCTAssertGreaterThan(failed.midX, 402, "Recorded native AX frame activated beyond the screen")
        let replacement = CGRect(x: 320, y: 62, width: SidebarForegroundLayout.visibleWidth(viewportWidth: 402, translation: 320), height: 778)
        XCTAssertEqual(replacement.width, 82)
        XCTAssertEqual(replacement.maxX, 402)
        XCTAssertEqual(replacement.midX, 361)
        XCTAssertEqual(SidebarForegroundLayout.visibleWidth(viewportWidth: 0, translation: 0), 0)
        XCTAssertEqual(SidebarForegroundLayout.visibleWidth(viewportWidth: 402, translation: 500), 0)
    }
    func testCancellationRestoresPriorPresentation() {
        XCTAssertFalse(SidebarGesturePolicy.settlesOpen(direction: .opening, progress: 0.9, velocityX: 1000, cancelled: true))
        XCTAssertTrue(SidebarGesturePolicy.settlesOpen(direction: .closing, progress: 0.1, velocityX: -1000, cancelled: true))
    }
}
