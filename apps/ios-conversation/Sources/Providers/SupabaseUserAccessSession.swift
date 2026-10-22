import Foundation

/// Supplies only the access JWT returned by a real Supabase Auth flow.
/// This client never derives identity, membership or authority from JWT claims.
public actor SupabaseUserAccessSession: NativeChatSessionCredentials {
    public let issuer: URL
    private let scope: DataScope
    private var accessToken: String?
    private var expiresAt: Date?
    public init(projectURL: URL, localScope: DataScope) throws {
        guard let c = URLComponents(url: projectURL, resolvingAgainstBaseURL: false), c.scheme == "https", c.host?.range(of: "^[a-z0-9]{20}\\.supabase\\.co$", options: .regularExpression) != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { throw catError.invalid("需要已核实的 Supabase 项目 URL。") }
        issuer = projectURL.appendingPathComponent("auth/v1"); scope = localScope
    }
    public func updateFromAuth(accessToken: String, expiresAt: Date) throws {
        // Shape is a transport check, not signature/identity verification.
        guard accessToken.utf8.count < 8192, accessToken.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ConversationSessionError.notConfigured }
        self.accessToken = accessToken; self.expiresAt = expiresAt
    }
    public func clear() { accessToken = nil; expiresAt = nil }
    public func authorization(scope: DataScope) async throws -> String {
        guard scope == self.scope else { throw catError.scopeMismatch }
        guard let accessToken, let expiresAt, expiresAt > Date() else { clear(); throw ConversationSessionError.notConfigured }
        return "Bearer " + accessToken
    }
}
