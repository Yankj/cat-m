import SwiftUI

/// Keep the host NavigationStack mounted at its original width. The sidebar is
/// a fixed underlay; only this complete foreground moves during a reveal.
@MainActor public struct SidebarHost<Content: View>: View {
    @Binding private var isPresented: Bool
    private let isAtRoot: Bool
    private let snapshot: SidebarSnapshot
    private let theme: SidebarTheme
    private let localize: (String) -> String
    private let excludedGestureAreas: [CGRect]
    private let allowsContentPan: Bool
    private let onSelect: (SidebarDestination) -> Void
    private let onWillOpen: () -> Void
    private let onDismissed: () -> Void
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var query = ""
    @StateObject private var motion = SidebarMotionDriver()

    /// isAtRoot must be false while any modal owns interaction. Generic clients
    /// retain edge-only opening unless they explicitly opt into content panning.
    public init(isPresented: Binding<Bool>, isAtRoot: Bool, snapshot: SidebarSnapshot,
                theme: SidebarTheme = .cat, localize: @escaping (String) -> String = {$0}, excludedGestureAreas: [CGRect] = [],
                allowsContentPan: Bool = false,
                onWillOpen: @escaping () -> Void = {}, onDismissed: @escaping () -> Void = {},
                onSelect: @escaping (SidebarDestination) -> Void, @ViewBuilder content: () -> Content) {
        _isPresented = isPresented; self.isAtRoot = isAtRoot; self.snapshot = snapshot
        self.theme = theme; self.localize = localize; self.excludedGestureAreas = excludedGestureAreas
        self.allowsContentPan = allowsContentPan
        self.onWillOpen = onWillOpen; self.onDismissed = onDismissed
        self.onSelect = onSelect; self.content = content()
    }
    public var body: some View {
        // Sidebar 17:24 (B-b): the host is full-bleed (.ignoresSafeArea(.container) below, the letterbox fix), so the panel
        // slot no longer inherited the container insets — its account row ran under the status-bar clock and the settings /
        // search bar into the home indicator. Read the insets here, outside the full-bleed region, and hand them to the panel.
        GeometryReader { outer in
            host(insets: outer.safeAreaInsets)
        }
    }
    private func host(insets: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let width = SidebarGesturePolicy.drawerWidth(available: geometry.size.width)
            let active = isAtRoot && motion.isVisible
            let progress = isAtRoot ? motion.position : 0
            let translation = width * progress
            let visibleForegroundWidth = SidebarForegroundLayout.visibleWidth(viewportWidth: geometry.size.width, translation: translation)
            let radius = SidebarGesturePolicy.foregroundCornerRadius(progress: progress)
            let foregroundShape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius,
                                                         bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
            ZStack(alignment: .leading) {
                // Equatable slot: the panel body is not re-evaluated on each spring frame,
                // only the cheap parallax offset below changes per frame.
                SidebarPanelSlot(snapshot: snapshot, query: $query, theme: theme, localize: localize,
                                 isActive: isAtRoot && motion.isFullyOpen,
                                 onSelect: { destination in
                                     guard snapshot.permits(destination) else { return }
                                     close(); onSelect(destination)
                                 }, onClose: close).equatable()
                    // Exactly the container insets (never doubled): the panel background stays full-bleed, its content does not.
                    .safeAreaPadding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: 0))
                    .ignoresSafeArea([.container, .keyboard])
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: reduceMotion ? 0 : -width * 0.22 * (1 - min(1, progress)))
                    .allowsHitTesting(active && !motion.isDragging)
                    .accessibilityHidden(!isAtRoot || !motion.isFullyOpen)
                ZStack(alignment: .leading) {
                    // The blocked conversation and its dismiss action are siblings.
                    // An overlay on disabled/AX-hidden content inherits that state
                    // and would also hide or disable the only visible scrim.
                    content
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(!active).accessibilityHidden(active)
                    if active {
                        // AX and hit testing use the visible strip, not the
                        // full-width translated conversation behind it. Keep
                        // its leading edge local to the translated foreground.
                        Button(action: close) {
                            Color.black.opacity(0.22 * Double(min(1, progress)))
                                .frame(width: visibleForegroundWidth, height: geometry.size.height)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .frame(width: visibleForegroundWidth, height: geometry.size.height)
                            .accessibilityLabel(localize("关闭侧栏"))
                            .accessibilityIdentifier("sidebar.scrim")
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    // Zero radius is the ordinary full-width host. Only the
                    // exposed leading edge rounds; the system keyboard is in
                    // its own window and navigation keeps the same proposal.
                    .clipShape(foregroundShape)
                    .overlay {
                        foregroundShape.strokeBorder(theme.separator.opacity(Double(progress)), lineWidth: 1 / max(1, displayScale))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .offset(x: translation)
                    .animation(nil, value: progress)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .background(theme.panel).clipped()
                // The modal AX scope includes both navigation and its sibling
                // dismiss strip; neither is excluded by a nested modal panel.
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(active ? .isModal : [])
                #if os(iOS)
                .background(SidebarGestureBridge(enabled: isAtRoot, progress: progress,
                                                 allowsContentPan: allowsContentPan, excludedAreas: excludedGestureAreas,
                                                 onBegan: {
                                                     guard isAtRoot else { return }
                                                     if !motion.isVisible { onWillOpen() }
                                                     motion.beginDrag()
                                                 }, onChanged: { translation in
                                                     guard isAtRoot else { return }
                                                     motion.drag(translationX: translation, width: width)
                                                 }, onEnded: { velocity, cancelled in
                                                     guard isAtRoot, motion.isDragging else { return }
                                                     isPresented = motion.endDrag(velocityX: velocity, width: width, cancelled: cancelled, reduceMotion: reduceMotion)
                                                 }))
                #endif
        }
        // Full-bleed host: the GeometryReader used to take only the safe-area rect, and the clipShape/clipped above cut the
        // chat's edge-to-edge canvas to it — the status-bar and home-indicator strips showed the bare window (black in dark,
        // white in light): the "letterboxed" iPhone 13 report. Children still receive the container insets (the nav bar and
        // composer stay where they were); the keyboard region is still honoured.
        .ignoresSafeArea(.container)
        .onAppear {
            if isAtRoot {
                if isPresented { onWillOpen(); motion.move(to: true, reduceMotion: reduceMotion) }
            } else { reset() }
        }.onChange(of: isPresented) { _, shown in
            guard isAtRoot else { reset(); return }
            if shown && !motion.isVisible { onWillOpen() }
            motion.move(to: shown, reduceMotion: reduceMotion)
        }.onChange(of: motion.isVisible) { _, visible in
            if !visible { onDismissed() }
        }.onChange(of: isAtRoot) { _, atRoot in
            if !atRoot { reset() }
        }.onChange(of: snapshot.contextID) { _, _ in
            query = ""; reset()
        }.onChange(of: reduceMotion) { _, reduced in
            if reduced { motion.removeInertia() }
        }.onDisappear { motion.reset() }
    }
    private func close() { isPresented = false; motion.move(to: false, reduceMotion: reduceMotion) }
    private func reset() { isPresented = false; motion.reset() }
}

/// Closures are excluded from equality on purpose: they only capture the binding,
/// the motion driver and `snapshot`, which is compared.
private struct SidebarPanelSlot: View, Equatable {
    let snapshot: SidebarSnapshot
    @Binding var query: String
    let theme: SidebarTheme
    let localize: (String) -> String
    let isActive: Bool
    let onSelect: (SidebarDestination) -> Void
    let onClose: () -> Void
    static func == (a: Self, b: Self) -> Bool {
        a.snapshot == b.snapshot && a.query == b.query && a.isActive == b.isActive
    }
    var body: some View {
        SidebarPanel(snapshot: snapshot, query: $query, theme: theme, localize: localize,
                     isActive: isActive, isModal: false, onSelect: onSelect, onClose: onClose)
    }
}

/// The dismiss button has its own on-screen geometry. Clipping a wider Button
/// does not change its accessibility frame or its computed activation point.
struct SidebarForegroundLayout {
    static func visibleWidth(viewportWidth: CGFloat, translation: CGFloat) -> CGFloat {
        guard viewportWidth.isFinite, translation.isFinite else { return 0 }
        return max(0, viewportWidth - max(0, translation))
    }
}
