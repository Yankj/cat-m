import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The rendered position is the state, not an implicit animation's target.
/// Normalized coordinates preserve the same reveal fraction after a width change.
struct SidebarMotionState {
    private(set) var position: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    private(set) var targetOpen = false
    private(set) var isDragging = false
    private(set) var isSettling = false
    private var dragStart: CGFloat = 0
    private var dragReturnOpen = false
    var isVisible: Bool { position > 0 || targetOpen || isDragging || isSettling }
    var isFullyOpen: Bool { targetOpen && position == 1 && !isDragging && !isSettling }

    mutating func move(to open: Bool, reduceMotion: Bool) {
        targetOpen = open; isDragging = false
        if reduceMotion { finish() }
        else { isSettling = position != endpoint || velocity != 0 }
    }
    mutating func beginDrag() {
        dragStart = position; dragReturnOpen = targetOpen
        isDragging = true; isSettling = false; velocity = 0
    }
    /// Past fully open the finger keeps a rubber-band hold (no dead stop at the edge).
    static let overshootLimit: CGFloat = 0.04
    mutating func drag(translationX: CGFloat, width: CGFloat) {
        guard isDragging, width > 0, width.isFinite, translationX.isFinite else { return }
        let raw = dragStart + translationX / width
        position = raw > 1 ? 1 + Self.overshootLimit * (1 - 1 / (1 + (raw - 1) * 3)) : max(0, raw)
    }
    /// UIScrollView-style projection: where the release would coast to. A slow drag past
    /// half opens; a short flick in either direction wins even from near the edge.
    static func projectedOpen(position: CGFloat, velocity: CGFloat) -> Bool {
        if abs(velocity) > 2.4 { return velocity > 0 }   // ≈ 750 pt/s on a 310 pt drawer
        return position + velocity * 0.2 >= 0.5
    }
    @discardableResult mutating func endDrag(velocityX: CGFloat, width: CGFloat, cancelled: Bool, reduceMotion: Bool) -> Bool {
        guard isDragging else { return targetOpen }
        let speed = velocityX.isFinite ? velocityX : 0
        velocity = !cancelled && width > 0 && width.isFinite ? speed / width : 0
        let open = cancelled ? dragReturnOpen : Self.projectedOpen(position: position, velocity: velocity)
        move(to: open, reduceMotion: reduceMotion)
        return open
    }
    /// Exact critically damped spring. No Euler step or hidden presentation layer
    /// can jump ahead of the position a subsequent finger gesture will acquire.
    mutating func advance(seconds: TimeInterval) {
        guard isSettling, !isDragging, seconds > 0, seconds.isFinite else { return }
        // ω 20 critically damped: ~0.3 s settle, carries the finger's release velocity.
        let t = CGFloat(seconds), omega: CGFloat = 20
        let displacement = position - endpoint
        let c = velocity + omega * displacement
        let decay = exp(-omega * t)
        let next = endpoint + (displacement + c * t) * decay
        velocity = (velocity - omega * c * t) * decay
        // A fast open may coast a few points past the edge and settle back instead of
        // hitting a wall; closing still clamps at 0 (nothing to reveal off-screen).
        position = min(1 + Self.overshootLimit, max(0, next))
        if next != position { velocity = 0 }
        if abs(position - endpoint) < 0.0001 && abs(velocity) < 0.005 { finish() }
    }
    mutating func removeInertia() { if !isDragging { finish() } }
    mutating func reset() { self = SidebarMotionState() }
    private var endpoint: CGFloat { targetOpen ? 1 : 0 }
    private mutating func finish() { position = endpoint; velocity = 0; isSettling = false }
}

@MainActor final class SidebarMotionDriver: ObservableObject {
    @Published private(set) var state = SidebarMotionState()
    private var previousTime: TimeInterval?
    #if os(iOS)
    private var displayLink: CADisplayLink?
    private var displayTarget: SidebarDisplayTarget?
    #else
    private var timer: Timer?
    private var generation = 0
    #endif
    var position: CGFloat { state.position }
    var isVisible: Bool { state.isVisible }
    var isDragging: Bool { state.isDragging }
    var isFullyOpen: Bool { state.isFullyOpen }

    func move(to open: Bool, reduceMotion: Bool) { state.move(to: open, reduceMotion: reduceMotion); schedule() }
    func beginDrag() { stopFrames(); state.beginDrag() }
    func drag(translationX: CGFloat, width: CGFloat) { state.drag(translationX: translationX, width: width) }
    @discardableResult func endDrag(velocityX: CGFloat, width: CGFloat, cancelled: Bool, reduceMotion: Bool) -> Bool {
        let open = state.endDrag(velocityX: velocityX, width: width, cancelled: cancelled, reduceMotion: reduceMotion)
        schedule(); return open
    }
    func removeInertia() { state.removeInertia(); schedule() }
    func reset() { stopFrames(); state.reset() }
    private func schedule() {
        guard state.isSettling else { stopFrames(); return }
        #if os(iOS)
        guard displayLink == nil else { return }
        let target = SidebarDisplayTarget(); target.owner = self; displayTarget = target
        let link = CADisplayLink(target: target, selector: #selector(SidebarDisplayTarget.frame(_:)))
        displayLink = link; link.add(to: .main, forMode: .common)
        #else
        guard timer == nil else { return }
        generation += 1; let token = generation
        let clock = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.advance(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        timer = clock; RunLoop.main.add(clock, forMode: .common)
        #endif
    }
    #if os(iOS)
    fileprivate func frame(_ link: CADisplayLink) {
        guard link === displayLink else { return }
        advance(at: link.timestamp)
    }
    #endif
    private func advance(at time: TimeInterval) {
        defer { if state.isSettling { previousTime = time } }
        guard let previousTime else { self.previousTime = time; return }
        state.advance(seconds: time - previousTime)
        if !state.isSettling { stopFrames() }
    }
    private func stopFrames() {
        #if os(iOS)
        displayLink?.invalidate(); displayLink = nil; displayTarget = nil
        #else
        generation += 1; timer?.invalidate(); timer = nil
        #endif
        previousTime = nil
    }
    deinit {
        #if os(iOS)
        displayLink?.invalidate()
        #else
        timer?.invalidate()
        #endif
    }
}
#if os(iOS)
@MainActor private final class SidebarDisplayTarget: NSObject {
    weak var owner: SidebarMotionDriver?
    @objc func frame(_ link: CADisplayLink) { owner?.frame(link) }
}
#endif
