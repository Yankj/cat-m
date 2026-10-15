import Foundation

public enum SidebarDestination: Equatable, Sendable {
    case newConversation, conversation(UUID), tasks, results, memory, settings
}

/// Supply only the current account/scope's records. This package does not fetch or persist them.
public struct SidebarConversation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var preview: String?
    public init(id: UUID, title: String, preview: String? = nil) {
        self.id = id; self.title = title; self.preview = preview
    }
}
public struct SidebarCapabilities: Equatable, Sendable {
    public var canCreateConversation: Bool
    public var canSelectConversation: Bool
    public var tasks: Bool
    public var results: Bool
    public var memory: Bool
    public var settings: Bool
    public init(canCreateConversation: Bool = true, canSelectConversation: Bool = true,
                tasks: Bool = false, results: Bool = false, memory: Bool = false, settings: Bool = true) {
        self.canCreateConversation = canCreateConversation; self.canSelectConversation = canSelectConversation
        self.tasks = tasks; self.results = results; self.memory = memory; self.settings = settings
    }
    public func allows(_ destination: SidebarDestination) -> Bool {
        switch destination {
        case .newConversation: canCreateConversation
        case .conversation: canSelectConversation
        case .tasks: tasks
        case .results: results
        case .memory: memory
        case .settings: settings
        }
    }
}
public struct SidebarSnapshot: Equatable, Sendable {
    /// A noncredential namespace used to reset transient search across account changes.
    public var contextID: String
    public var selectedConversationID: UUID?
    public var conversations: [SidebarConversation]
    public var capabilities: SidebarCapabilities
    public init(contextID: String, selectedConversationID: UUID? = nil,
                conversations: [SidebarConversation], capabilities: SidebarCapabilities = .init()) {
        self.contextID = contextID; self.selectedConversationID = selectedConversationID
        self.conversations = conversations; self.capabilities = capabilities
    }
    public func matching(_ query: String) -> [SidebarConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || ($0.preview?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }
    public func permits(_ destination: SidebarDestination) -> Bool {
        guard capabilities.allows(destination) else { return false }
        if case .conversation(let id) = destination { return conversations.contains { $0.id == id } }
        return true
    }
}

public enum SidebarDragDirection: Sendable { case opening, closing }
public enum SidebarGesturePolicy {
    /// Our interaction defaults, not measured latency or HIG-mandated values.
    public static let edgeWidth: CGFloat = 24
    public static func drawerWidth(available: CGFloat) -> CGFloat {
        max(0, min(320, available * 0.86, available - 44))
    }
    public static func mayOpen(isAtRoot: Bool, isPresented: Bool,
                               startX: CGFloat, inHorizontalContent: Bool, inEditableControl: Bool, allowsContentPan: Bool = false) -> Bool {
        isAtRoot && !isPresented && startX >= 0 && (allowsContentPan || startX <= edgeWidth) && !inHorizontalContent && !inEditableControl
    }
    /// A TextKit display surface is not an editor. Active text selection still
    /// owns its touch, including a long press that has not produced a range yet.
    static func textViewOwnsTouch(isEditable: Bool, hasMarkedText: Bool, selectionLength: Int, selectionGestureActive: Bool, isFirstResponder: Bool = true) -> Bool {
        // TextKit retains selectedRange after focus leaves. That historical range
        // must not permanently convert a read-only display into a gesture owner.
        isEditable || hasMarkedText || (isFirstResponder && selectionLength > 0) || selectionGestureActive
    }
    static func foregroundCornerRadius(progress: CGFloat) -> CGFloat {
        progress.isFinite ? 24 * min(1, max(0, progress)) : 0
    }
    static func acceptsPan(progress: CGFloat, x: CGFloat, y: CGFloat) -> Bool {
        guard x.isFinite, y.isFinite, progress.isFinite else { return false }
        if progress <= 0 { return acceptsDirection(.opening, x: x, y: y) }
        if progress >= 1 { return acceptsDirection(.closing, x: x, y: y) }
        return abs(x) > abs(y) * 1.2
    }
    public static func acceptsDirection(_ direction: SidebarDragDirection, x: CGFloat, y: CGFloat) -> Bool {
        abs(x) > abs(y) * 1.2 && (direction == .opening ? x > 0 : x < 0)
    }
    public static func progress(direction: SidebarDragDirection, translationX: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return direction == .opening ? 0 : 1 }
        let value = direction == .opening ? translationX / width : 1 + translationX / width
        return min(1, max(0, value))
    }
    public static func settlesOpen(direction: SidebarDragDirection, progress: CGFloat,
                                   velocityX: CGFloat, cancelled: Bool) -> Bool {
        if cancelled { return direction == .closing }
        if direction == .opening && velocityX > 400 { return true }
        if direction == .closing && velocityX < -400 { return false }
        return progress >= 0.5
    }
}
