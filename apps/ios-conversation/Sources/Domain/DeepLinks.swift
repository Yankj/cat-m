import Foundation
public enum DeepLinkResolver {
    public static func resolve(_ url: URL, snapshot: StoreSnapshot, scope: DataScope) throws -> Route {
        guard url.scheme == "catpawm", url.user == nil, url.password == nil, let host = url.host,
              let id = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let record = snapshot.records[id], record.header.scope == scope, record.header.deletedAt == nil else { throw catError.missing }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard (components?.queryItems ?? []).allSatisfy({ $0.name == "version" }) else { throw catError.invalid("链接参数无效。") }
        switch host {
        case "conversation": guard record.conversation != nil else { throw catError.missing }; return .conversation(id)
        case "task": guard record.task != nil else { throw catError.missing }; return .task(id)
        case "document":
            guard let doc = record.document else { throw catError.missing }
            let version = Int(components?.queryItems?.first(where: { $0.name == "version" })?.value ?? "") ?? doc.currentVersion
            guard version > 0, let v = snapshot.records[stableID("\(id)-v\(version)")], v.header.scope == scope, v.header.deletedAt == nil else { throw catError.missing }
            return .document(id, version: version)
        default: throw catError.invalid("不支持的链接页面。")
        }
    }
}

/// App-level routes for out-of-app entry points (widgets, Control Center, notifications, Live Activity).
/// `catpawm://conversation/<uuid>` · `catpawm://new` · `catpawm://tasks` · `catpawm://memory` · `catpawm://proactive`
/// · `catpawm://results` · `catpawm://settings` (v1.2: also the in-chat capability buttons)
public enum catAppRoute: Equatable, Sendable {
    case conversation(UUID), newConversation, tasks, memory, proactive, proactiveDebug, results, settings
    public init?(url: URL) {
        guard url.scheme == "catpawm", url.user == nil, url.password == nil, let host = url.host else { return nil }
        let tail = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "conversation": guard let id = UUID(uuidString: tail) else { return nil }; self = .conversation(id)
        case "new": self = .newConversation
        case "tasks": self = .tasks
        case "memory": self = .memory
        case "proactive": self = tail == "debug" ? .proactiveDebug : .proactive
        case "results": self = .results
        case "settings": self = .settings
        default: return nil
        }
    }
}

/// v1.2 capability buttons: the assistant may end a reply with Markdown links such as `[打开记忆](catpawm://memory)`
/// (docs/product/capabilities/catpaw-capabilities.json). Only these bare hosts are accepted — no path, query or
/// credentials — so a reply can never reach debug pages or a specific conversation. Without the backend identity
/// block the model simply emits no links and no buttons appear.
public struct catCapabilityLink: Equatable, Sendable, Identifiable {
    public let label: String
    public let route: catAppRoute
    public let url: URL
    public var id: String { url.absoluteString }
}
public enum catCapabilityLinks {
    public static let allowedHosts: Set<String> = ["memory", "tasks", "proactive", "results", "settings"]
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "catpawm", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host, allowedHosts.contains(host), url.path.isEmpty || url.path == "/" else { return false }
        return true
    }
    /// Allowed links in order of appearance, de-duplicated by target, at most `limit`.
    public static func extract(from markdown: String, limit: Int = 2) -> [catCapabilityLink] {
        guard markdown.contains("catpawm://"), let re = try? NSRegularExpression(pattern: #"\[([^\]\n]{1,40})\]\((catpawm://[^)\s]{1,40})\)"#) else { return [] }
        let ns = markdown as NSString
        var out: [catCapabilityLink] = []
        for m in re.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, let url = URL(string: ns.substring(with: m.range(at: 2))), isAllowed(url),
                  let route = catAppRoute(url: url), !out.contains(where: { $0.route == route }) else { continue }
            out.append(.init(label: label, route: route, url: url))
            if out.count == limit { break }
        }
        return out
    }
}
