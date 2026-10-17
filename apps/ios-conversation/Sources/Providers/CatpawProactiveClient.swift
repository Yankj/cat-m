import Foundation

/// `proactive.events` row as returned by `GET /events` (docs/backend/proactive-tasks.md).
public struct CatpawProactiveEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let task_id: String?
    public let conversation_id: String?
    public let kind: String               // reminder_due | task_created | task_updated | agent_message
    public let title: String
    public let body: String
    public let created_at: String
    public let read_at: String?
    public let payload: Payload?
    public struct Payload: Codable, Sendable, Equatable {
        public let actions: [String]?
        public let due_at: String?
        public let task: CatpawProactiveTask?
    }
    public var createdAt: Date { CatpawProactiveClient.date(created_at) ?? .distantPast }
    public var conversationID: UUID? { conversation_id.flatMap(UUID.init(uuidString:)) }
    public var offersTaskActions: Bool { task_id != nil && (kind == "reminder_due" || (payload?.actions?.isEmpty == false)) }
}

public struct CatpawProactiveTask: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let revision: Int
    public let due_at: String?
}

public enum CatpawProactiveError: Error, Equatable { case notConfigured, unauthorized, conflict, notFound, http(Int) }

/// Minimal client for Edge function `catpaw-proactive`. Auth comes from `CatpawPushTokenUploader.shared.bearer()`.
public actor CatpawProactiveClient {
    public static let shared = CatpawProactiveClient()
    private let session: URLSession
    private let base: URL?

    public init(session: URLSession = .shared, info: [String: Any]? = Bundle.main.infoDictionary) {
        self.session = session
        func url(_ key: String) -> URL? { (info?[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil } }
        base = url("CatpawProactiveBaseURL") ?? url("CatpawSupabaseProjectURL")?.appendingPathComponent("functions/v1/catpaw-proactive")
    }

    /// `GET /events?after=&conversation_id=`. The server currently ignores `conversation_id`; callers filter.
    public func events(after: String?, conversationID: UUID? = nil, limit: Int = 100) async throws -> [CatpawProactiveEvent] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let after { query.append(.init(name: "after", value: after)) }
        if let conversationID { query.append(.init(name: "conversation_id", value: conversationID.uuidString.lowercased())) }
        struct R: Decodable { let events: [CatpawProactiveEvent] }
        return try await send("GET", "events", query: query, as: R.self).events
    }
    public func task(_ id: String) async throws -> CatpawProactiveTask {
        struct R: Decodable { let task: CatpawProactiveTask }
        return try await send("GET", "tasks/" + id, as: R.self).task
    }
    /// `PATCH /tasks/:id` with `expected_revision`. On 409 refetches once and retries with the fresh revision.
    public func update(taskID: String, fields: [String: String]) async throws -> CatpawProactiveTask {
        struct R: Decodable { let task: CatpawProactiveTask }
        var current = try await task(taskID)
        for attempt in 0..<2 {
            var body: [String: Any] = fields; body["expected_revision"] = current.revision
            do { return try await send("PATCH", "tasks/" + taskID, body: body, as: R.self).task }
            catch CatpawProactiveError.conflict where attempt == 0 { current = try await task(taskID) }
        }
        throw CatpawProactiveError.conflict
    }
    public func markRead(eventID: String) async {
        struct R: Decodable {}
        _ = try? await send("POST", "events/" + eventID + "/read", body: [:], as: R.self)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil, as: T.Type) async throws -> T {
        guard let base else { throw CatpawProactiveError.notConfigured }
        let bearer: String
        do { bearer = try await CatpawPushTokenUploader.shared.bearer() } catch { throw CatpawProactiveError.unauthorized }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CatpawProactiveError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(bearer, forHTTPHeaderField: "Authorization")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        case 401, 403: throw CatpawProactiveError.unauthorized
        case 404: throw CatpawProactiveError.notFound
        case 409: throw CatpawProactiveError.conflict
        default: throw CatpawProactiveError.http(status)
        }
    }

    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: text)
    }
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
}
