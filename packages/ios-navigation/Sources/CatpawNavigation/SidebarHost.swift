import SwiftUI

/// Wrap the host's NavigationStack. The host remains the navigation/state owner.
public struct SidebarHost<Content: View>: View {
    @Binding private var isPresented: Bool
    private let isAtRoot: Bool
    private let snapshot: SidebarSnapshot
    private let theme: SidebarTheme
    private let excludedGestureAreas: [CGRect]
    private let onSelect: (SidebarDestination) -> Void
    private let onWillOpen: () -> Void
    private let onDismissed: () -> Void
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var dragProgress: CGFloat = 0
    @State private var isDragging = false

    /// isAtRoot must also be false while another modal owns interaction. Exclusion areas
    /// use host-local coordinates for custom code/content views that cannot be detected as UIScrollView.
    public init(isPresented: Binding<Bool>, isAtRoot: Bool, snapshot: SidebarSnapshot,
                theme: SidebarTheme = .catpaw, excludedGestureAreas: [CGRect] = [],
                onWillOpen: @escaping () -> Void = {}, onDismissed: @escaping () -> Void = {},
                onSelect: @escaping (SidebarDestination) -> Void, @ViewBuilder content: () -> Content) {
        _isPresented = isPresented; self.isAtRoot = isAtRoot; self.snapshot = snapshot
        self.theme = theme; self.excludedGestureAreas = excludedGestureAreas
        self.onWillOpen = onWillOpen; self.onDismissed = onDismissed
        self.onSelect = onSelect; self.content = content()
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = SidebarGesturePolicy.drawerWidth(available: geometry.size.width)
            let active = isAtRoot && (isPresented || isDragging)
            let progress = isDragging && !reduceMotion ? dragProgress : (isPresented ? CGFloat(1) : 0)
            ZStack(alignment: .leading) {
                content.allowsHitTesting(!active).accessibilityHidden(active)
                if active {
                    Button { close() } label: {
                        Color.black.opacity(0.22 * Double(progress)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("关闭侧栏")
                        .accessibilityIdentifier("sidebar.scrim")
                    SidebarPanel(snapshot: snapshot, query: $query, theme: theme,
                                 onSelect: { destination in
                                     guard snapshot.permits(destination) else { return }
                                     close(); onSelect(destination)
                                 }, onClose: close)
                        .frame(width: width).offset(x: -width * (1 - progress))
                        .accessibilityHidden(progress == 0)
                        #if os(iOS)
                        .background(SidebarGestureBridge(direction: .closing, enabled: isPresented,
                                                         excludedAreas: [], onBegan: { isDragging = true; dragProgress = 1 },
                                                         onChanged: { dragProgress = SidebarGesturePolicy.progress(direction: .closing, translationX: $0, width: width) },
                                                         onEnded: { velocity, cancelled in settle(.closing, velocity: velocity, cancelled: cancelled) }))
                        #endif
                }
            }.animation(reduceMotion || isDragging ? nil : .easeOut(duration: 0.22), value: progress)
                #if os(iOS)
                .background(SidebarGestureBridge(direction: .opening, enabled: isAtRoot && !active,
                                                 excludedAreas: excludedGestureAreas, onBegan: {
                                                     isDragging = true; dragProgress = 0
                                                 }, onChanged: {
                                                     dragProgress = SidebarGesturePolicy.progress(direction: .opening, translationX: $0, width: width)
                                                 }, onEnded: { velocity, cancelled in settle(.opening, velocity: velocity, cancelled: cancelled) }))
                #endif
        }.onAppear {
            if !isAtRoot { close() }
        }.onChange(of: isPresented) { _, shown in
            if shown {
                if isAtRoot { onWillOpen() } else { close() }
            } else { onDismissed() }
        }.onChange(of: isAtRoot) { _, atRoot in
            if !atRoot { close() }
        }.onChange(of: snapshot.contextID) { _, _ in
            query = ""; close()
        }
    }

    private func close() { isDragging = false; isPresented = false; dragProgress = 0 }
    private func settle(_ direction: SidebarDragDirection, velocity: CGFloat, cancelled: Bool) {
        let open = SidebarGesturePolicy.settlesOpen(direction: direction, progress: dragProgress,
                                                    velocityX: velocity, cancelled: cancelled) && isAtRoot
        isDragging = false; isPresented = open; dragProgress = open ? 1 : 0
    }
}
