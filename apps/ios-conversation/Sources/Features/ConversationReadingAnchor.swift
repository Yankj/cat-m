import Foundation

/// Presentation identity only. No account, request or execution authority lives here.
struct ConversationReadingAnchorContext: Equatable, Hashable, Sendable {
    let profileID: UUID
    let scopeID: UUID
    let conversationID: UUID
}

/// Geometry is in the owning scroll view's content coordinate system.
struct ConversationReadingAnchorRow: Equatable, Sendable {
    let id: UUID
    let minY: Double
    let height: Double
    var maxY: Double { minY + height }
}
struct ConversationReadingAnchorViewport: Equatable, Sendable {
    let top: Double
    let bottom: Double
}
struct ConversationReadingAnchorRecord: Equatable, Sendable {
    let rowID: UUID
    let intraOffset: Double
    let viewportY: Double
}
struct ConversationReadingAnchorSnapshot: Equatable, Sendable {
    let record: ConversationReadingAnchorRecord
    let rows: [ConversationReadingAnchorRow]
    let viewport: ConversationReadingAnchorViewport
    let orderedIDs: [UUID]
}
struct ConversationReadingAnchorCorrection: Equatable, Sendable {
    let referenceRowID: UUID
    let delta: Double
    let usedFallback: Bool
    let savedRowWasRemoved: Bool
}

/// A content-size delta is not a reading delta: growth below a reader must not
/// move them. Compare the same row's content point against its old viewport point.
enum ConversationReadingAnchorPolicy {
    static func shouldCompensate(followingLatest: Bool, isUserScrolling: Bool) -> Bool {
        !followingLatest && !isUserScrolling
    }
    static func capture(rows: [ConversationReadingAnchorRow], viewport: ConversationReadingAnchorViewport,
                        orderedIDs: [UUID]) -> ConversationReadingAnchorSnapshot? {
        guard viewport.top.isFinite, viewport.bottom.isFinite, viewport.bottom > viewport.top else { return nil }
        let rows = validRows(rows, orderedIDs: orderedIDs)
        guard let first = rows.first(where: { $0.maxY > viewport.top && $0.minY < viewport.bottom }) else { return nil }
        return .init(record: record(for: first, viewport: viewport), rows: rows, viewport: viewport, orderedIDs: orderedIDs)
    }
    static func correction(from previous: ConversationReadingAnchorSnapshot,
                           rows: [ConversationReadingAnchorRow], viewport: ConversationReadingAnchorViewport,
                           orderedIDs: [UUID]) -> ConversationReadingAnchorCorrection? {
        guard viewport.top.isFinite, viewport.bottom.isFinite, viewport.bottom > viewport.top else { return nil }
        let current = Dictionary(uniqueKeysWithValues: validRows(rows, orderedIDs: orderedIDs).map { ($0.id, $0) })
        let saved = previous.record
        if let row = current[saved.rowID] {
            return correction(record: saved, row: row, viewport: viewport, fallback: false, removed: false)
        }
        // A recycled LazyVStack marker is not a deleted message. Prefer the
        // nearest surviving successor, then predecessor from the previous order,
        // preserving that row's own old pixel position. With no common measured
        // row, capture afresh rather than guessing from total content growth.
        guard let index = previous.orderedIDs.firstIndex(of: saved.rowID) else { return nil }
        let successors = previous.orderedIDs.dropFirst(index + 1)
        let predecessors = previous.orderedIDs.prefix(index).reversed()
        let oldRows = Dictionary(uniqueKeysWithValues: previous.rows.map { ($0.id, $0) })
        for id in Array(successors) + Array(predecessors) {
            guard let old = oldRows[id], let row = current[id] else { continue }
            return correction(record: record(for: old, viewport: previous.viewport), row: row, viewport: viewport,
                              fallback: true, removed: !orderedIDs.contains(saved.rowID))
        }
        return nil
    }
    private static func correction(record: ConversationReadingAnchorRecord, row: ConversationReadingAnchorRow,
                                   viewport: ConversationReadingAnchorViewport, fallback: Bool, removed: Bool) -> ConversationReadingAnchorCorrection? {
        let point = row.minY + min(max(0, record.intraOffset), row.height)
        let delta = point - viewport.top - record.viewportY
        guard delta.isFinite else { return nil }
        return .init(referenceRowID: row.id, delta: delta, usedFallback: fallback, savedRowWasRemoved: removed)
    }
    private static func record(for row: ConversationReadingAnchorRow, viewport: ConversationReadingAnchorViewport) -> ConversationReadingAnchorRecord {
        let inside = min(max(0, viewport.top - row.minY), row.height)
        return .init(rowID: row.id, intraOffset: inside, viewportY: row.minY + inside - viewport.top)
    }
    private static func validRows(_ rows: [ConversationReadingAnchorRow], orderedIDs: [UUID]) -> [ConversationReadingAnchorRow] {
        let order = Dictionary(orderedIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let grouped = Dictionary(grouping: rows, by: \.id)
        return grouped.values.compactMap { group in
            guard group.count == 1, let row = group.first, order[row.id] != nil,
                  row.minY.isFinite, row.height.isFinite, row.height > 0, row.maxY.isFinite else { return nil }
            return row
        }.sorted { a, b in a.minY == b.minY ? order[a.id, default: 0] < order[b.id, default: 0] : a.minY < b.minY }
    }
}

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// One coordinator per transcript. It observes the existing UIScrollView and
/// never replaces its delegate, pan recognizer, deceleration or bounce physics.
@MainActor final class ConversationReadingAnchorCoordinator: ObservableObject {
    private(set) var snapshot: ConversationReadingAnchorSnapshot?
    private(set) var lastCorrection: Double = 0
    private var context: ConversationReadingAnchorContext?
    private var followingLatest = true
    private var orderedIDs: [UUID] = []
    private var generation: UInt64 = 0
    private var scheduled: DispatchWorkItem?
    private var measuring = false
    private var contentSizeChanged = false
    private weak var tracker: ConversationReadingAnchorTrackingView?
    private weak var scroll: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var markers: [ObjectIdentifier: WeakReadingMarker] = [:]
    private var onContentSizeChange: () -> Void = {}

    init() {}

    func bind(context next: ConversationReadingAnchorContext?, followingLatest: Bool, orderedIDs: [UUID]) {
        if context != next {
            generation &+= 1; scheduled?.cancel(); scheduled = nil
            detachScroll(); snapshot = nil; lastCorrection = 0
            context = next
        }
        if self.followingLatest != followingLatest { snapshot = nil }
        self.followingLatest = followingLatest
        self.orderedIDs = orderedIDs
        invalidate()
    }

    fileprivate func attach(_ view: ConversationReadingAnchorTrackingView, onContentSizeChange: @escaping () -> Void) {
        // An old representable may leave its window after a new conversation
        // has bound this coordinator. It must never detach the new scroll view.
        guard view.owner === self, view.context == context, context != nil else { return }
        guard view.window != nil else {
            if tracker === view {
                generation &+= 1; scheduled?.cancel(); scheduled = nil
                detachScroll(); tracker = nil; snapshot = nil
            }
            return
        }
        tracker = view
        var ancestor = view.superview
        while let candidate = ancestor {
            if let candidate = candidate as? UIScrollView {
                if scroll !== candidate {
                    generation &+= 1; scheduled?.cancel(); scheduled = nil
                    detachScroll(); scroll = candidate; snapshot = nil
                    observations = [
                        candidate.observe(\.contentOffset, options: [.old, .new]) { [weak self, weak candidate] _, change in
                            MainActor.assumeIsolated {
                                guard let self, let candidate, self.scroll === candidate,
                                      change.oldValue != change.newValue else { return }
                                // Native offset changes own the new reading point, including
                                // the final inertial frame, VoiceOver and selection scrolling.
                                // Only our measuring transaction may adjust an old snapshot.
                                if !self.measuring { self.snapshot = nil }
                                self.invalidate()
                            }
                        },
                        candidate.observe(\.contentSize, options: [.new, .old]) { [weak self, weak candidate] _, change in
                            MainActor.assumeIsolated {
                                guard let self, let candidate, self.scroll === candidate else { return }
                                if change.oldValue != change.newValue { self.contentSizeChanged = true }
                                self.invalidate()
                            }
                        },
                        candidate.observe(\.bounds, options: [.new]) { [weak self, weak candidate] _, _ in
                            MainActor.assumeIsolated {
                                guard let self, let candidate, self.scroll === candidate else { return }
                                self.invalidate()
                            }
                        }
                    ]
                    candidate.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
                }
                self.onContentSizeChange = onContentSizeChange
                invalidate(); return
            }
            ancestor = candidate.superview
        }
        detachScroll()
    }

    fileprivate func detach(_ view: ConversationReadingAnchorTrackingView) {
        guard tracker === view else { return }
        generation &+= 1; scheduled?.cancel(); scheduled = nil
        detachScroll(); tracker = nil; snapshot = nil; lastCorrection = 0
    }
    fileprivate func register(_ view: ConversationReadingAnchorMarkerView) {
        markers[ObjectIdentifier(view)] = WeakReadingMarker(view)
        if view.context == context { invalidate() }
    }
    fileprivate func unregister(_ view: ConversationReadingAnchorMarkerView) {
        markers.removeValue(forKey: ObjectIdentifier(view))
        if view.context == context { invalidate() }
    }
    fileprivate func invalidate() {
        guard !measuring, context != nil, scroll != nil, scheduled == nil else { return }
        let epoch = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.scheduled = nil; self.commitLayout(epoch: epoch)
        }
        scheduled = work; DispatchQueue.main.async(execute: work)
    }
    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        guard scroll?.panGestureRecognizer === recognizer else { return }
        // Once the user owns scrolling, the old resting anchor cannot pull
        // against their finger or inertial motion on the next layout commit.
        snapshot = nil; invalidate()
    }
    private func detachScroll() {
        observations.forEach { $0.invalidate() }; observations.removeAll()
        scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
        scroll = nil; contentSizeChanged = false; onContentSizeChange = {}
    }
    private func commitLayout(epoch: UInt64) {
        guard generation == epoch, let context, let tracker, tracker.context == context,
              let scroll, let window = scroll.window, tracker.window === window else { return }
        measuring = true
        defer { measuring = false }
        scroll.layoutIfNeeded()
        guard generation == epoch, self.scroll === scroll else { return }
        let notifySize = contentSizeChanged; contentSizeChanged = false
        var rows = measuredRows(in: scroll, context: context)
        var viewport = measuredViewport(in: scroll)
        let userScrolling = scroll.isDragging || scroll.isDecelerating ||
            scroll.panGestureRecognizer.state == .began || scroll.panGestureRecognizer.state == .changed
        lastCorrection = 0
        if ConversationReadingAnchorPolicy.shouldCompensate(followingLatest: followingLatest, isUserScrolling: userScrolling),
           let snapshot, let correction = ConversationReadingAnchorPolicy.correction(from: snapshot, rows: rows, viewport: viewport, orderedIDs: orderedIDs) {
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            let target = min(maximum, max(minimum, scroll.contentOffset.y + CGFloat(correction.delta)))
            let actualDelta = target - scroll.contentOffset.y
            if actualDelta.isFinite, abs(actualDelta) > 0.5 / max(1, window.screen.scale) {
                UIView.performWithoutAnimation {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
                }
                lastCorrection = Double(actualDelta)
                rows = measuredRows(in: scroll, context: context); viewport = measuredViewport(in: scroll)
            }
        }
        snapshot = ConversationReadingAnchorPolicy.capture(rows: rows, viewport: viewport, orderedIDs: orderedIDs)
        if notifySize && followingLatest { onContentSizeChange() }
    }
    private func measuredRows(in scroll: UIScrollView, context: ConversationReadingAnchorContext) -> [ConversationReadingAnchorRow] {
        markers = markers.filter { $0.value.view != nil }
        return markers.values.compactMap { marker in
            guard let view = marker.view, view.context == context, let id = view.rowID,
                  view.window === scroll.window, view.isDescendant(of: scroll) else { return nil }
            let frame = view.convert(view.bounds, to: scroll)
            return .init(id: id, minY: Double(frame.minY), height: Double(frame.height))
        }
    }
    private func measuredViewport(in scroll: UIScrollView) -> ConversationReadingAnchorViewport {
        .init(top: Double(scroll.contentOffset.y + scroll.adjustedContentInset.top),
              bottom: Double(scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom))
    }
}

@MainActor private final class WeakReadingMarker {
    weak var view: ConversationReadingAnchorMarkerView?
    init(_ view: ConversationReadingAnchorMarkerView) { self.view = view }
}

/// Put in each stable timeline row's background, using the row's full proposal.
/// This native marker never participates in hit testing, AX, focus or state.
@MainActor struct ConversationReadingAnchorMarker: UIViewRepresentable {
    let id: UUID
    let context: ConversationReadingAnchorContext?
    let coordinator: ConversationReadingAnchorCoordinator
    func makeUIView(context: Context) -> ConversationReadingAnchorMarkerView {
        let view = ConversationReadingAnchorMarkerView(); configure(view); return view
    }
    func updateUIView(_ view: ConversationReadingAnchorMarkerView, context: Context) { configure(view) }
    static func dismantleUIView(_ view: ConversationReadingAnchorMarkerView, coordinator: ()) {
        view.owner?.unregister(view); view.owner = nil
    }
    private func configure(_ view: ConversationReadingAnchorMarkerView) {
        if view.owner !== coordinator { view.owner?.unregister(view) }
        view.owner = coordinator; view.rowID = id; view.context = context; coordinator.register(view)
    }
}
@MainActor final class ConversationReadingAnchorMarkerView: UIView {
    fileprivate weak var owner: ConversationReadingAnchorCoordinator?
    fileprivate var rowID: UUID?
    fileprivate var context: ConversationReadingAnchorContext?
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layoutSubviews() { super.layoutSubviews(); owner?.register(self) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { owner?.unregister(self) } else { owner?.register(self) }
    }
}

/// A background of the same LazyVStack as the rows. Layout and native KVO are
/// coalesced onto a main-queue commit; no permanent display-link or polling loop.
@MainActor struct ConversationReadingAnchorTracker: UIViewRepresentable {
    let context: ConversationReadingAnchorContext?
    let followingLatest: Bool
    let orderedIDs: [UUID]
    let coordinator: ConversationReadingAnchorCoordinator
    var onContentSizeChange: () -> Void = {}
    func makeUIView(context: Context) -> ConversationReadingAnchorTrackingView {
        let view = ConversationReadingAnchorTrackingView(); configure(view); return view
    }
    func updateUIView(_ view: ConversationReadingAnchorTrackingView, context: Context) { configure(view) }
    static func dismantleUIView(_ view: ConversationReadingAnchorTrackingView, coordinator: ()) {
        view.owner?.detach(view); view.owner = nil
    }
    private func configure(_ view: ConversationReadingAnchorTrackingView) {
        if view.owner !== coordinator { view.owner?.detach(view) }
        view.owner = coordinator; view.context = context; view.onContentSizeChange = onContentSizeChange
        coordinator.bind(context: context, followingLatest: followingLatest, orderedIDs: orderedIDs)
        coordinator.attach(view, onContentSizeChange: onContentSizeChange)
    }
}
@MainActor final class ConversationReadingAnchorTrackingView: UIView {
    fileprivate weak var owner: ConversationReadingAnchorCoordinator?
    fileprivate var context: ConversationReadingAnchorContext?
    fileprivate var onContentSizeChange: () -> Void = {}
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layoutSubviews() { super.layoutSubviews(); owner?.invalidate() }
    override func didMoveToWindow() {
        super.didMoveToWindow(); owner?.attach(self, onContentSizeChange: onContentSizeChange)
    }
    override func didMoveToSuperview() {
        super.didMoveToSuperview(); owner?.attach(self, onContentSizeChange: onContentSizeChange)
    }
}
#endif
