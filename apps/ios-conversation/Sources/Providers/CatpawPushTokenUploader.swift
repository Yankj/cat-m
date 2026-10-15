import Foundation

/// One row of Supabase table `public.device_push_tokens` (schema assumption, see PR description):
/// unique(token); RLS `user_id = auth.uid()`; upsert via PostgREST `on_conflict=token`.
public struct CatpawPushTokenRecord: Codable, Sendable, Equatable {
    public var user_id: UUID?
    public var token: String
    public var kind: String            // "live_activity" | "apns" (future: remote notifications / push-to-start)
    public var platform: String
    public var apns_environment: String // "sandbox" | "production"
    public var bundle_id: String
    public var activity_id: String?
    public var task_id: String?
    public var conversation_id: String?
    public var active: Bool
    public var updated_at: Date

    public static func liveActivity(token: String, activityID: String, taskID: String, conversationID: String) -> Self {
        .init(user_id: nil, token: token, kind: "live_activity", platform: "ios", apns_environment: apnsEnvironment, bundle_id: Bundle.main.bundleIdentifier ?? "",
              activity_id: activityID, task_id: taskID, conversation_id: conversationID, active: true, updated_at: Date())
    }
    public static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

/// Queues push tokens and upserts them once an authorization provider is registered.
/// Wiring (owner of NativeAuthApplicationModel): after building `AuthenticatedNativeChatCredentials` call
/// `await CatpawPushTokenUploader.shared.setAuthorization(subjectID: user.id) { try await credentials.authorization(scope: partition.scope) }`
/// and `clearAuthorization()` on sign-out. Until then tokens stay queued in memory (never written to disk).
public actor CatpawPushTokenUploader {
    public static let shared = CatpawPushTokenUploader()
    public typealias Authorization = @Sendable () async throws -> String

    private var authorization: Authorization?
    private var subjectID: UUID?
    private var pending: [String: CatpawPushTokenRecord] = [:]
    private var activityTokens: [String: String] = [:]
    private let session: URLSession
    private let projectURL: URL?
    private let publishableKey: String?

    public init(session: URLSession = .shared, info: [String: Any]? = Bundle.main.infoDictionary) {
        self.session = session
        let url = (info?["CatpawSupabaseProjectURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        projectURL = url?.scheme == "https" ? url : nil
        publishableKey = (info?["CatpawSupabasePublishableKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func setAuthorization(subjectID: UUID, _ provider: @escaping Authorization) async {
        if self.subjectID != subjectID { pending = pending.mapValues { var r = $0; r.user_id = nil; return r } }
        self.subjectID = subjectID; authorization = provider
        await flush()
    }
    public func clearAuthorization() { authorization = nil; subjectID = nil }

    public func enqueue(_ record: CatpawPushTokenRecord) async {
        pending[record.token] = record
        if let id = record.activity_id { activityTokens[id] = record.token }
        await flush()
    }

    /// Marks an ended activity's token inactive so the backend stops pushing to it.
    public func retire(activityID: String) async {
        guard let token = activityTokens.removeValue(forKey: activityID) else { return }
        var record = pending[token] ?? CatpawPushTokenRecord.liveActivity(token: token, activityID: activityID, taskID: "", conversationID: "")
        record.active = false; record.updated_at = Date(); pending[token] = record
        await flush()
    }

    public var queuedCount: Int { pending.count }

    private func flush() async {
        guard let authorization, let subjectID, let projectURL, let publishableKey, !pending.isEmpty else { return }
        for (token, var record) in pending {
            record.user_id = subjectID
            do {
                try await upsert(record, projectURL: projectURL, key: publishableKey, authorization: try await authorization())
                if pending[token]?.updated_at == record.updated_at { pending.removeValue(forKey: token) }
            } catch {
                return // keep queued; retried on the next enqueue/setAuthorization
            }
        }
    }

    private func upsert(_ record: CatpawPushTokenRecord, projectURL: URL, key: String, authorization: String) async throws {
        var components = URLComponents(url: projectURL.appendingPathComponent("rest/v1/device_push_tokens"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "token")]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue(authorization.hasPrefix("Bearer ") ? authorization : "Bearer " + authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(record)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }
}
