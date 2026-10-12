import Foundation
public enum DeepLinkResolver {
    public static func resolve(_ url: URL, snapshot: StoreSnapshot, scope: DataScope) throws -> Route {
        guard url.scheme == "catpawm", url.user == nil, url.password == nil, let host = url.host,
              let id = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let record = snapshot.records[id], record.header.scope == scope, record.header.deletedAt == nil else { throw CatpawError.missing }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard (components?.queryItems ?? []).allSatisfy({ $0.name == "version" }) else { throw CatpawError.invalid("链接参数无效。") }
        switch host {
        case "conversation": guard record.conversation != nil else { throw CatpawError.missing }; return .conversation(id)
        case "task": guard record.task != nil else { throw CatpawError.missing }; return .task(id)
        case "document":
            guard let doc = record.document else { throw CatpawError.missing }
            let version = Int(components?.queryItems?.first(where: { $0.name == "version" })?.value ?? "") ?? doc.currentVersion
            guard version > 0, let v = snapshot.records[stableID("\(id)-v\(version)")], v.header.scope == scope, v.header.deletedAt == nil else { throw CatpawError.missing }
            return .document(id, version: version)
        default: throw CatpawError.invalid("不支持的链接页面。")
        }
    }
}
