import Foundation

public enum NativeAuthError: Error, LocalizedError, Sendable {
    case notConfigured, invalidConfiguration, invalidCredentials, loginRequired, invalidResponse, busy, cancelled, storage, unavailable, rateLimited, callbackUnsupported, emailNotConfirmed, signupUnavailable, emailNotAuthorized, weakPassword, anonymousUnavailable, sessionRecoveryRequired
    public var errorDescription: String? {
        switch self {
        case .notConfigured, .invalidConfiguration: return "登录连接尚未配置。"
        case .invalidCredentials: return "邮箱或密码未通过验证。"
        case .loginRequired: return "登录已失效，请重新登录。"
        case .invalidResponse: return "登录响应未通过校验，请重新登录。"
        case .busy: return "登录请求正在处理，请稍候。"
        case .cancelled: return "登录已取消。"
        case .storage: return "安全存储暂不可用，请解锁后重试。"
        case .unavailable: return "登录服务暂不可用，请稍后重试。"
        case .rateLimited: return "请求过于频繁，请稍后再试。"
        case .emailNotConfirmed: return "邮箱尚未确认，请先点击确认邮件，再返回登录。"
        case .signupUnavailable: return "当前项目暂不接受注册，请联系项目维护者。"
        case .emailNotAuthorized: return "邮件服务不允许向此邮箱发信，请使用项目允许的邮箱或联系维护者配置邮件服务。"
        case .weakPassword: return "密码未满足服务要求，请使用更长且包含不同字符的密码。"
        case .anonymousUnavailable: return "体验登录暂不可用，请稍后重试。"
        case .sessionRecoveryRequired: return "这次会话需要重新开始，本机对话仍会保留。"
        case .callbackUnsupported: return "当前登录方式不接受外部链接中的会话。"
        }
    }
}
public struct NativeAuthConfiguration: Sendable {
    public let projectURL: URL
    public let publishableKey: String
    public let backendOrigin: URL
    public let serverScopeID: UUID?
    public var issuer: String { projectURL.appendingPathComponent("auth/v1").absoluteString }
    public init(projectURL: URL, publishableKey: String, backendOrigin: URL, serverScopeID: UUID? = nil) throws {
        guard let p = URLComponents(url: projectURL, resolvingAgainstBaseURL: false), p.scheme == "https", p.host?.range(of: "^[a-z0-9]{20}\\.supabase\\.co$", options: .regularExpression) != nil,
              p.user == nil, p.password == nil, p.query == nil, p.fragment == nil, p.port == nil || p.port == 443, p.path.isEmpty || p.path == "/",
              publishableKey.range(of: "^sb_publishable_[A-Za-z0-9_-]{10,2000}$", options: .regularExpression) != nil else { throw NativeAuthError.invalidConfiguration }
        try NativeAPIBase.validate(backendOrigin)
        self.projectURL = projectURL; self.publishableKey = publishableKey; self.backendOrigin = backendOrigin; self.serverScopeID = serverScopeID
    }
    public static func read(_ values: [String: String]) throws -> NativeAuthConfiguration? {
        let keys = ["CatpawSupabaseProjectURL", "CatpawSupabasePublishableKey", "CatpawBackendOrigin", "CatpawServerScopeID"]
        if keys.allSatisfy({ values[$0] == nil || values[$0]?.isEmpty == true }) { return nil }
        guard let project = values[keys[0]].flatMap(URL.init(string:)), let key = values[keys[1]], let origin = values[keys[2]].flatMap(URL.init(string:)) else { throw NativeAuthError.invalidConfiguration }
        let text = values[keys[3]] ?? "";let scope = text.isEmpty ? nil : UUID(uuidString:text)
        guard text.isEmpty || scope != nil else { throw NativeAuthError.invalidConfiguration }
        return try .init(projectURL: project, publishableKey: key, backendOrigin: origin, serverScopeID: scope)
    }
}
public struct NativeAuthUser: Codable, Sendable, Equatable {
    public let id: UUID
    public let email: String?
    public let isAnonymous: Bool
    public init(id: UUID, email: String? = nil, isAnonymous: Bool = false) { self.id = id; self.email = email; self.isAnonymous = isAnonymous }
}
public struct NativeAuthCredential: Codable, Sendable {
    public let issuer: String
    public let user: NativeAuthUser
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public init(issuer: String, user: NativeAuthUser, accessToken: String, refreshToken: String, expiresAt: Date) { self.issuer = issuer; self.user = user; self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt }
}
public struct NativeAuthSnapshot: Sendable, Equatable {
    public enum Phase: Sendable { case signedOut, restoring, signingIn, refreshing, authenticated, loginRequired, storageBlocked }
    public let phase: Phase
    public let user: NativeAuthUser?
    public let generation: Int
    public let message: String?
}
public enum NativeAuthRegistration: Sendable {
    case emailConfirmationRequired
    case authenticated(NativeAuthCredential)
}
public protocol NativeAuthRemote: Sendable {
    func signInAnonymously() async throws -> NativeAuthCredential
    func signUp(email: String, password: String) async throws -> NativeAuthRegistration
    func signIn(email: String, password: String) async throws -> NativeAuthCredential
    func refresh(refreshToken: String) async throws -> NativeAuthCredential
    func user(accessToken: String) async throws -> NativeAuthUser
    func signOut(accessToken: String) async throws
    func revokeApplicationSession(accessToken: String) async throws
}
public extension NativeAuthRemote {
    func signInAnonymously() async throws -> NativeAuthCredential { throw NativeAuthError.anonymousUnavailable }
    func signUp(email: String, password: String) async throws -> NativeAuthRegistration { throw NativeAuthError.signupUnavailable }
    func revokeApplicationSession(accessToken: String) async throws { throw NativeAuthError.notConfigured }
}
public protocol NativeAuthVault: Sendable {
    func load() throws -> NativeAuthCredential?
    func save(_ credential: NativeAuthCredential) throws
    func clear() throws
}
public protocol NativeAuthLogoutBarrier: Sendable {
    func isSignedOut() throws -> Bool
    func setSignedOut(_ value: Bool) throws
}
public struct AuthenticatedLocalPartition: Sendable, Equatable {
    public let subject: UUID
    public let namespace: String
    public let scope: DataScope
    public init(issuer: String, subject: UUID, serverScopeID: UUID) {
        self.subject = subject
        namespace = textHash(issuer + "|" + subject.uuidString.lowercased() + "|" + serverScopeID.uuidString.lowercased())
        let profile = stableID("auth-local-profile-" + namespace)
        scope = DataScope(profileID: profile, workspaceID: stableID("local-workspace-\(profile)"))
    }
}

/// Explicit API base; preserves a Supabase Edge function prefix without changing wire route IDs.
public enum NativeAPIBase {
    public static func validate(_ url: URL, allowLoopback: Bool = false) throws {
        guard let c = URLComponents(url:url,resolvingAgainstBaseURL:false),let host = c.host,!host.isEmpty,
              c.scheme == "https" || (allowLoopback && c.scheme == "http" && ["127.0.0.1","localhost","::1"].contains(host)),
              c.user == nil,c.password == nil,c.query == nil,c.fragment == nil,
              c.percentEncodedPath == c.path,
              c.path.isEmpty || c.path == "/" || c.path.range(of:"^/functions/v1/[A-Za-z0-9_-]{1,64}/?$",options:.regularExpression) != nil else { throw NativeAuthError.invalidConfiguration }
    }
    public static func endpoint(base: URL, route: String) throws -> URL {
        guard route.hasPrefix("/"),!route.hasPrefix("//"),let relative = URLComponents(string:route),
              relative.scheme == nil,relative.host == nil,relative.fragment == nil,
              !relative.path.split(separator:"/").contains(where:{$0 == "." || $0 == ".."}),
              var result = URLComponents(url:base,resolvingAgainstBaseURL:false) else { throw NativeAuthError.invalidConfiguration }
        let prefix = result.percentEncodedPath.hasSuffix("/") ? String(result.percentEncodedPath.dropLast()) : result.percentEncodedPath
        result.percentEncodedPath = prefix + relative.percentEncodedPath;result.percentEncodedQuery = relative.percentEncodedQuery
        guard let url = result.url else { throw NativeAuthError.invalidConfiguration };return url
    }
}
