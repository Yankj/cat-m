#if os(iOS)
import SwiftUI
import UIKit

/// A scoped recognizer, never a replacement for NavigationStack or a scroll delegate.
struct SidebarGestureBridge: UIViewRepresentable {
    var enabled: Bool
    var progress: CGFloat
    var allowsContentPan: Bool
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
        // Root/scope/modal invalidation cancels the recognizer as well as motion.
        context.coordinator.recognizer?.isEnabled = enabled
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
        weak var touchedTextView: UITextView?
        init(_ owner: SidebarGestureBridge) { self.owner = owner }
        func attach(_ view: AnchorView) {
            anchor = view
            guard target !== view.window else { return }
            detach()
            guard let parent = view.window else { return }
            target = parent
            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
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
            guard owner.enabled, let anchor, anchor.window != nil else { return false }
            // The window receives touches from both the host and presented system pickers.
            // Restrict to this live anchor and leave any UIKit modal to its own recognizers.
            if anchor.window?.rootViewController?.presentedViewController != nil { return false }
            let point = touch.location(in: anchor)
            guard anchor.bounds.contains(point), !owner.excludedAreas.contains(where: { $0.contains(point) }) else { return false }
            touchedTextView = nil
            var node = touch.view
            while let view = node {
                if view is UITextField || view is UISlider || view is UISwitch { return false }
                if let text = view as? UITextView {
                    if textOwnsTouch(text) { return false }
                    touchedTextView = text
                }
                if let scroll = view as? UIScrollView,
                   scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right > scroll.bounds.width + 1 { return false }
                node = view.superview
            }
            return owner.progress > 0 || SidebarGesturePolicy.mayOpen(isAtRoot: true, isPresented: false,
                startX: point.x, inHorizontalContent: false, inEditableControl: false, allowsContentPan: owner.allowsContentPan)
        }
        private func textOwnsTouch(_ text: UITextView) -> Bool {
            SidebarGesturePolicy.textViewOwnsTouch(isEditable: text.isEditable, hasMarkedText: text.markedTextRange != nil,
                selectionLength: text.selectedRange.length, selectionGestureActive: hasActiveSelectionGesture(text), isFirstResponder: text.isFirstResponder)
        }
        private func hasActiveSelectionGesture(_ view: UIView) -> Bool {
            if (view.gestureRecognizers ?? []).contains(where: { $0 is UILongPressGestureRecognizer && ($0.state == .began || $0.state == .changed) }) { return true }
            return view.subviews.contains(where: hasActiveSelectionGesture)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer, let text = touchedTextView, text.isSelectable,
                  otherGestureRecognizer is UILongPressGestureRecognizer, let view = otherGestureRecognizer.view else { return false }
            // A short horizontal move fails the text long press by movement;
            // a deliberate hold lets native selection win before root reveal.
            return view === text || view.isDescendant(of: text)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer, let scroll = otherGestureRecognizer.view as? UIScrollView,
                  otherGestureRecognizer === scroll.panGestureRecognizer, scroll.isScrollEnabled else { return false }
            // The root horizontal recognizer makes its axis decision first.
            // Vertical reading proceeds as soon as our direction check fails;
            // horizontal controls were excluded before either gesture begins.
            return scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right <= scroll.bounds.width + 1
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard owner.enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            if let text = touchedTextView, textOwnsTouch(text) { return false }
            let velocity = pan.velocity(in: anchor)
            return SidebarGesturePolicy.acceptsPan(progress: owner.progress, x: velocity.x, y: velocity.y)
        }
        @objc func drag(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                tracking = true; owner.onBegan()
                owner.onChanged(pan.translation(in: anchor).x)
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
