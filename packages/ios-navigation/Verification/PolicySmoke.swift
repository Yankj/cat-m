import Foundation

/// A Foundation-only executable for simctl spawn; no App, services, credentials, or installation.
@main struct PolicySmoke {
    static func main() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let state = SidebarSnapshot(contextID: "synthetic-only", conversations: [.init(id: id, title: "离线 Alpha")])
        let checks: [Bool] = [
            state.matching("alpha").map(\.id) == [id],
            state.permits(.conversation(id)),
            !state.permits(.tasks), !state.permits(.memory), !state.permits(.results),
            !SidebarGesturePolicy.mayOpen(isAtRoot: false, isPresented: false, startX: 0, inHorizontalContent: false, inEditableControl: false),
            !SidebarGesturePolicy.mayOpen(isAtRoot: true, isPresented: false, startX: 0, inHorizontalContent: true, inEditableControl: false),
            SidebarGesturePolicy.progress(direction: .opening, translationX: 1000, width: 320) == 1,
            !SidebarGesturePolicy.settlesOpen(direction: .opening, progress: 1, velocityX: 1000, cancelled: true),
            SidebarGesturePolicy.settlesOpen(direction: .closing, progress: 0, velocityX: -1000, cancelled: true)
        ]
        guard checks.allSatisfy({ $0 }) else { fatalError("FAIL synthetic sidebar policy smoke") }
        print("PASS \(checks.count) synthetic sidebar policy checks; no UI/VoiceOver/latency claim")
    }
}
