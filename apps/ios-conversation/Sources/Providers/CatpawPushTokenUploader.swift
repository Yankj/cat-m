import Foundation

/// Body of `PUT /devices/tokens` on Edge function `catpaw-proactive` (docs/backend/proactive-tasks.md):
/// `{device_id, kind, token, environment, bundle_id, activity_id?}`; server upserts into `proactive.device_push_tokens`.
public struct CatpawDeviceTokenRegistration: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case apns, liveActivityUpdate = "live_activity_update", liveActivityStart = "live_activity_start" }
    public var device_id: String
    public var kind: Kind
    public var token: String          // lowercase hex
    public var environment: String    // "sandbox" (DEBUG) | "production"
    public var bundle_id: String
    public var activity_id: String?

    public init(kind: Kind, token: Data, activityID: String? = nil, deviceID: String = CatpawDeviceIdentity.deviceID, bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        self.init(kind: kind, hexToken: token.map { String(format: "%02x", $0) }.joined(), activityID: activityID, deviceID: deviceID, bundleID: bundleID)
    }
    public init(kind: Kind, hexToken: String, activityID: String? = nil, deviceID: String = CatpawDeviceIdentity.deviceID, bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        device_id = deviceID; self.kind = kind; token = hexToken.lowercased(); environment = Self.apnsEnvironment; bundle_id = bundleID; activity_id = activityID
    }
    public static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
    /// Pending-queue key: one APNs token per device, one update token per activity.
    var queueKey: String { kind.rawValue + ":" + (activity_id ?? "") }
}

/// Stable per-install device id (not the advertising id, not identifierForVendor), stored in UserDefaults.
public enum CatpawDeviceIdentity {
    private static let key = "catpaw.push.deviceID"
    public static var deviceID: String {
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let v = UUID().uuidString.lowercased(); UserDefaults.standard.set(v, forKey: key); return v
    }
}

/// Queues device / Live Activity push tokens and sends them to `catpaw-proactive` once a bearer provider is set.
/// Wiring (owner of NativeAuthApplicationModel), after `AuthenticatedNativeChatCredentials` is built:
/// `await CatpawPushTokenUploader.shared.setAuthorization { try await credentials.authorization(scope: partition.scope) }`
/// and `await CatpawPushTokenUploader.shared.clearAuthorization()` on sign-out. Tokens never touch disk.
public actor CatpawPushTokenUploader {
    public static let shared = CatpawPushTokenUploader()
    public typealias Authorization = @Sendable () async throws -> String

    private var authorization: Authorization?
    private var pending: [String: CatpawDeviceTokenRegistration] = [:]
    private var lastSent: [String: CatpawDeviceTokenRegistration] = [:]
    private let session: URLSession
    private let endpoint: URL?

    /// `CatpawProactiveBaseURL` (Info.plist) overrides the default `<CatpawSupabaseProjectURL>/functions/v1/catpaw-proactive`.
    public init(session: URLSession = .shared, info: [String: Any]? = Bundle.main.infoDictionary) {
        self.session = session
        func url(_ key: String) -> URL? { (info?[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil } }
        let base = url("CatpawProactiveBaseURL") ?? url("CatpawSupabaseProjectURL")?.appendingPathComponent("functions/v1/catpaw-proactive")
        endpoint = base?.appendingPathComponent("devices/tokens")
    }

    public func setAuthorization(_ provider: @escaping Authorization) async {
        authorization = provider
        for (k, v) in lastSent where pending[k] == nil { pending[k] = v }   // re-register under the (possibly new) account
        await flush()
    }
    /// Sign-out: `DELETE /devices/tokens {device_id}` (all kinds) with the still-valid session, then forget auth.
    /// Already called first thing in `NativeAuthApplicationModel.signOut()`, so no extra hook is needed.
    public func clearAuthorization() async {
        if let authorization, let endpoint, let bearer = try? await authorization() {
            var request = URLRequest(url: endpoint, timeoutInterval: 10)
            request.httpMethod = "DELETE"
            request.setValue(bearer.hasPrefix("Bearer ") ? bearer : "Bearer " + bearer, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": CatpawDeviceIdentity.deviceID])
            _ = try? await session.data(for: request)
        }
        authorization = nil; pending.removeAll(); lastSent.removeAll()
    }
    /// Current bearer for other `catpaw-proactive` calls (shares the registered auth provider).
    public func bearer() async throws -> String {
        guard let authorization else { throw URLError(.userAuthenticationRequired) }
        let value = try await authorization()
        return value.hasPrefix("Bearer ") ? value : "Bearer " + value
    }

    public func enqueue(_ registration: CatpawDeviceTokenRegistration) async {
        guard lastSent[registration.queueKey] != registration || authorization == nil else { return }
        pending[registration.queueKey] = registration
        await flush()
    }
    /// Drops a finished activity's token locally; the server disables it on APNs 410 / BadDeviceToken.
    public func forgetActivity(_ activityID: String) {
        let key = CatpawDeviceTokenRegistration.Kind.liveActivityUpdate.rawValue + ":" + activityID
        pending.removeValue(forKey: key); lastSent.removeValue(forKey: key)
    }
    public var queuedCount: Int { pending.count }

    private func flush() async {
        guard let authorization, let endpoint, !pending.isEmpty else { return }
        for (key, registration) in pending {
            do {
                try await put(registration, to: endpoint, authorization: try await authorization())
                if pending[key] == registration { pending.removeValue(forKey: key) }
                lastSent[key] = registration
            } catch { return } // stays queued; retried on next enqueue / setAuthorization
        }
    }

    private func put(_ registration: CatpawDeviceTokenRegistration, to url: URL, authorization: String) async throws {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "PUT"
        request.setValue(authorization.hasPrefix("Bearer ") ? authorization : "Bearer " + authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }
}
