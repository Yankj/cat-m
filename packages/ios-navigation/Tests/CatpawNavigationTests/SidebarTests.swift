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
        XCTAssertEqual(SidebarGesturePolicy.drawerWidth(available: 390), 327.6, accuracy: 0.01)
        XCTAssertEqual(SidebarGesturePolicy.drawerWidth(available: 1024), 360)
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
    func testCancellationRestoresPriorPresentation() {
        XCTAssertFalse(SidebarGesturePolicy.settlesOpen(direction: .opening, progress: 0.9, velocityX: 1000, cancelled: true))
        XCTAssertTrue(SidebarGesturePolicy.settlesOpen(direction: .closing, progress: 0.1, velocityX: -1000, cancelled: true))
    }
}
