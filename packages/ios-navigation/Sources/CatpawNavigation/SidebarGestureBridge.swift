#if os(iOS)
import SwiftUI
import UIKit

/// A scoped recognizer, never a replacement for NavigationStack or a scroll delegate.
struct SidebarGestureBridge: UIViewRepresentable {
    var direction: SidebarDragDirection
    var enabled: Bool
    var excludedAreas: [CGRect]
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isAccessibilityElement = false
        view.onAttachment = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.attach(view)
        }
        context.coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.owner = self
        // Keep an in-flight recognizer alive while SwiftUI updates the drawer.
        context.coordinator.recognizer?.isEnabled = enabled || context.coordinator.tracking
        context.coordinator.attach(view)
    }
    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        view.onAttachment = nil; coordinator.detach()
    }
    final class AnchorView: UIView {
        var onAttachment: (() -> Void)?
        override func didMoveToSuperview() { super.didMoveToSuperview(); onAttachment?() }
        override func didMoveToWindow() { super.didMoveToWindow(); onAttachment?() }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: SidebarGestureBridge
        weak var anchor: AnchorView?
        weak var target: UIView?
        var recognizer: UIPanGestureRecognizer?
        var tracking = false
        init(_ owner: SidebarGestureBridge) { self.owner = owner }
        func attach(_ view: AnchorView) {
            anchor = view
            guard target !== view.superview else { return }
            detach()
            guard let parent = view.superview else { return }
            target = parent
            let pan: UIPanGestureRecognizer
            if owner.direction == .opening {
                let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(drag(_:)))
                edge.edges = .left; pan = edge
            } else { pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:))) }
            pan.maximumNumberOfTouches = 1; pan.delegate = self
            pan.delaysTouchesBegan = false; pan.isEnabled = owner.enabled
            parent.addGestureRecognizer(pan); recognizer = pan
        }
        func detach() {
            if let recognizer { target?.removeGestureRecognizer(recognizer) }
            recognizer = nil; target = nil
            if tracking { tracking = false; owner.onEnded(0, true) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard owner.enabled, let anchor else { return false }
            let point = touch.location(in: anchor)
            guard anchor.bounds.contains(point), !owner.excludedAreas.contains(where: { $0.contains(point) }) else { return false }
            var node = touch.view
            while let view = node {
                if view is UITextField || view is UITextView { return false }
                if let scroll = view as? UIScrollView,
                   scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right > scroll.bounds.width + 1 { return false }
                node = view.superview
            }
            return owner.direction == .closing || SidebarGesturePolicy.mayOpen(isAtRoot: true, isPresented: false,
                startX: point.x, inHorizontalContent: false, inEditableControl: false)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard owner.enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: anchor)
            return SidebarGesturePolicy.acceptsDirection(owner.direction, x: velocity.x, y: velocity.y)
        }
        @objc func drag(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began: tracking = true; owner.onBegan()
            case .changed: owner.onChanged(pan.translation(in: anchor).x)
            case .ended, .cancelled, .failed:
                guard tracking else { return }
                tracking = false
                owner.onChanged(pan.translation(in: anchor).x)
                owner.onEnded(pan.velocity(in: anchor).x, pan.state != .ended)
                pan.isEnabled = owner.enabled
            default: break
            }
        }
    }
}
#endif
