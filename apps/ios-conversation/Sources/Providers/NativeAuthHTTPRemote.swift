import Foundation

public protocol NativeAuthHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public protocol NativeApplicationScopeResolving: Sendable {
    func applicationScope(accessToken: String, subject: UUID) async throws -> UUID
}
public struct NativeApplicationSessionError: Error, Sendable, LocalizedError {
    public let httpStatus: Int
    public let code: String?
    /// Workspace discovery is a read-only request. Transport timeouts, throttling and server
    /// availability failures may be retried without replaying a message, consent or effect.
    public var isRetryable: Bool { httpStatus == 408 || httpStatus == 429 || (500...599).contains(httpStatus) }
    /// Status/code stay available to policy and diagnostics, but never become end-user copy.
    public var errorDescription: String? {
        isRetryable ? "正在连接，恢复后会自动继续。" : "暂时无法打开工作区，本机对话仍会保留。"
    }
}
public final class NativeAuthURLTransport: NativeAuthHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: NativeAuthRejectRedirect(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count < 65536 else { throw NativeAuthError.invalidResponse }
            return (data, http)
        } catch is CancellationError { throw NativeAuthError.cancelled }
        catch let error as NativeAuthError { throw error }
        catch { throw NativeAuthError.unavailable }
    }
}
private final class NativeAuthRejectRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
/// HTTP contract from Supabase Auth's official OpenAPI. No SDK dependency or implicit session.
public struct NativeAuthHTTPRemote: NativeAuthRemote, NativeApplicationScopeResolving {
    private let configuration: NativeAuthConfiguration
    private let transport: any NativeAuthHTTPTransport
    private let now: @Sendable () -> Date
    public init(configuration: NativeAuthConfiguration, transport: any NativeAuthHTTPTransport = NativeAuthURLTransport(), now: @escaping @Sendable () -> Date = { Date() }) { self.configuration = configuration; self.transport = transport; self.now = now }
    public func signInAnonymously() async throws -> NativeAuthCredential {
        // Official signInAnonymously: POST /auth/v1/signup, no email/password.
        let data = try await call("signup",body:[:])
        guard let dto = try? JSONDecoder().decode(TokenDTO.self,from:data),dto.user.is_anonymous else { throw NativeAuthError.invalidResponse }
        return try credential(dto)
    }
    public func signUp(email: String, password: String) async throws -> NativeAuthRegistration {
        let data = try await call("signup",body:["email":email,"password":password])
        if let dto = try? JSONDecoder().decode(TokenDTO.self,from:data) {
            guard dto.token_type.lowercased() == "bearer",(1...86400).contains(dto.expires_in),!dto.user.is_anonymous else { throw NativeAuthError.invalidResponse }
            return .authenticated(.init(issuer:configuration.issuer,user:dto.user.value,accessToken:dto.access_token,refreshToken:dto.refresh_token,expiresAt:now().addingTimeInterval(TimeInterval(dto.expires_in))))
        }
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],object["access_token"] == nil,object["refresh_token"] == nil else { throw NativeAuthError.invalidResponse }
        let raw = object["user"] ?? object
        guard let bytes = try? JSONSerialization.data(withJSONObject:raw),let user = try? JSONDecoder().decode(UserDTO.self,from:bytes),!user.is_anonymous else { throw NativeAuthError.invalidResponse }
        return .emailConfirmationRequired
    }
    public func signIn(email: String, password: String) async throws -> NativeAuthCredential {
        try await token(grant: "password", body: ["email": email, "password": password])
    }
    public func refresh(refreshToken: String) async throws -> NativeAuthCredential {
        try await token(grant: "refresh_token", body: ["refresh_token": refreshToken])
    }
    private func token(grant: String, body: [String: String]) async throws -> NativeAuthCredential {
        let data = try await call("token", query: [URLQueryItem(name: "grant_type", value: grant)], body: body)
        guard let dto = try? JSONDecoder().decode(TokenDTO.self, from: data),grant != "password" || !dto.user.is_anonymous else { throw NativeAuthError.invalidResponse }
        return try credential(dto)
    }
    private func credential(_ dto: TokenDTO) throws -> NativeAuthCredential {
        guard dto.token_type.lowercased() == "bearer",(1...86400).contains(dto.expires_in) else { throw NativeAuthError.invalidResponse }
        return .init(issuer: configuration.issuer, user: dto.user.value, accessToken: dto.access_token, refreshToken: dto.refresh_token, expiresAt: now().addingTimeInterval(TimeInterval(dto.expires_in)))
    }
    public func user(accessToken: String) async throws -> NativeAuthUser {
        let data = try await call("user", token: accessToken)
        guard let dto = try? JSONDecoder().decode(UserDTO.self, from: data) else { throw NativeAuthError.invalidResponse }
        return dto.value
    }
    public func revokeApplicationSession(accessToken: String) async throws {
        let data = try await applicationCall("/catpaw/account/v1/logout",accessToken:accessToken,post:true)
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],object["schema_version"] as? Int == 1,object["revoked"] as? Bool == true else { throw NativeAuthError.invalidResponse }
    }
    public func applicationScope(accessToken: String, subject: UUID) async throws -> UUID {
        let data = try await applicationCall("/catpaw/account/v1/session",accessToken:accessToken)
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],object["schema_version"] as? Int == 1,
              (object["subject_id"] as? String).flatMap(UUID.init(uuidString:)) == subject,let scopes = object["scopes"] as? [[String:Any]] else { throw NativeAuthError.invalidResponse }
        let valid = scopes.compactMap { row -> UUID? in
            guard (row["permissions"] as? [String:Any])?["local_output"] as? Bool == true,(row["profile_id"] as? String).flatMap(UUID.init(uuidString:)) != nil,(row["workspace_id"] as? String).flatMap(UUID.init(uuidString:)) != nil else { return nil };return (row["scope_id"] as? String).flatMap(UUID.init(uuidString:))
        }
        if let selected = configuration.serverScopeID { guard valid.contains(selected) else { throw NativeAuthError.invalidResponse };return selected }
        guard valid.count == 1,let scope = valid.first else { throw NativeAuthError.invalidResponse };return scope
    }
    private func applicationCall(_ route: String, accessToken: String, post: Bool = false) async throws -> Data {
        var request = URLRequest(url:try NativeAPIBase.endpoint(base:configuration.backendOrigin,route:route));request.timeoutInterval = 10
        request.setValue("Bearer "+accessToken,forHTTPHeaderField:"Authorization");request.setValue(configuration.publishableKey,forHTTPHeaderField:"apikey");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if post { request.httpMethod = "POST";request.httpBody = Data("{}".utf8) }
        let (data,response) = try await transport.send(request)
        guard data.count < 65536,response.url == request.url else { throw NativeAuthError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let raw = object?["code"] as? String ?? (object?["error"] as? [String:Any])?["code"] as? String
            let code = raw.flatMap { $0.range(of:"^[a-z0-9_]{1,64}$",options:.regularExpression) != nil ? $0 : nil }
            throw NativeApplicationSessionError(httpStatus:response.statusCode,code:code)
        };return data
    }
    public func signOut(accessToken: String) async throws { _ = try await call("logout", query: [URLQueryItem(name: "scope", value: "local")], token: accessToken, body: [:]) }
    private func call(_ route: String, query: [URLQueryItem] = [], token: String? = nil, body: [String: String]? = nil) async throws -> Data {
        try Task.checkCancellation()
        var components = URLComponents(url: configuration.projectURL.appendingPathComponent("auth/v1/" + route), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.send(request)
        guard data.count < 65536, response.url == request.url else { throw NativeAuthError.invalidResponse }
        if !(200..<300).contains(response.statusCode),let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],let code = object["code"] as? String ?? object["error_code"] as? String {
            switch code {
            case "email_not_confirmed": throw NativeAuthError.emailNotConfirmed
            case "signup_disabled": throw NativeAuthError.signupUnavailable
            case "email_address_not_authorized", "email_not_authorized": throw NativeAuthError.emailNotAuthorized
            case "weak_password": throw NativeAuthError.weakPassword
            case "anonymous_provider_disabled", "anonymous_sign_ins_disabled": throw NativeAuthError.anonymousUnavailable
            default: break
            }
        }
        switch response.statusCode {
        case 200 where route != "logout": return data
        case 204 where route == "logout": return data
        case 400, 422: throw route == "token" && query.first?.value == "password" ? NativeAuthError.invalidCredentials : NativeAuthError.loginRequired
        case 401, 403: throw NativeAuthError.loginRequired
        case 429: throw NativeAuthError.rateLimited
        default: throw NativeAuthError.unavailable
        }
    }
    private struct UserDTO: Decodable {
        let id: UUID; let email: String?; let is_anonymous: Bool
        var value: NativeAuthUser { .init(id: id, email: email, isAnonymous: is_anonymous) }
    }
    private struct TokenDTO: Decodable { let access_token: String; let refresh_token: String; let token_type: String; let expires_in: Int; let user: UserDTO }
}

// MARK: - OAuth (PKCE) — GitHub / Google via Supabase Auth. Additive; no existing route changes.
extension NativeAuthHTTPRemote: NativeOAuthRemote {
    /// POST /auth/v1/token?grant_type=pkce { auth_code, code_verifier }.
    public func exchangeOAuthCode(_ code: String, verifier: String) async throws -> NativeAuthCredential {
        _ = try NativeOAuthPKCE(verifier: verifier)
        let credential = try await token(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier])
        guard !credential.user.isAnonymous else { throw NativeAuthError.invalidResponse }
        return credential
    }
    public func linkIdentityURL(accessToken: String, provider: NativeOAuthProvider, pkce: NativeOAuthPKCE) async throws -> URL {
        try Task.checkCancellation()
        let request = NativeOAuthRequest.linkIdentityRequest(configuration: configuration, accessToken: accessToken, provider: provider, pkce: pkce)
        let (data, response) = try await transport.send(request)
        guard data.count < 65536, response.url == nil || response.url == request.url else { throw NativeAuthError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let raw = object?["error_code"] as? String ?? object?["code"] as? String
            throw NativeOAuthLinkError(code: raw.flatMap { $0.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil ? $0 : nil }, httpStatus: response.statusCode)
        }
        guard let text = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["url"] as? String, let url = URL(string: text) else { throw NativeAuthError.invalidResponse }
        return try NativeOAuthRequest.validateLinkAuthorizeURL(url, provider: provider)
    }
    public func identities(accessToken: String) async throws -> [NativeLinkedIdentity] {
        let data = try await call("user", token: accessToken)
        struct Identity: Decodable { let provider: String; let identity_data: [String: JSONScalar]? }
        struct Body: Decodable { let identities: [Identity]? }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw NativeAuthError.invalidResponse }
        return (body.identities ?? []).compactMap { i in
            guard i.provider.range(of: "^[a-z0-9_]{1,32}$", options: .regularExpression) != nil else { return nil }
            let label = i.identity_data?["user_name"]?.text ?? i.identity_data?["email"]?.text
            return .init(provider: i.provider, label: label.map { String($0.prefix(80)) })
        }
    }
}
public struct NativeOAuthLinkError: Error, Sendable, Equatable { public let code: String?; public let httpStatus: Int }
/// Tolerant decoder for identity_data values (strings matter; numbers/bools ignored).
struct JSONScalar: Decodable {
    let text: String?
    init(from decoder: Decoder) throws { text = try? decoder.singleValueContainer().decode(String.self) }
}
