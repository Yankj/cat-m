import Foundation
import CryptoKit
import Security

/// Supabase OAuth (PKCE) contracts for GitHub / Google. Portable: no UIKit, no network.
/// The provider client secret never reaches the app; Supabase Auth holds it. The app only
/// owns a one-shot PKCE verifier (memory only) and the `catpawm://auth-callback` redirect.
public enum NativeOAuthProvider: String, CaseIterable, Sendable, Codable, Hashable {
    case github, google
    public var displayName: String { self == .github ? "GitHub" : "Google" }
    /// Hosts an identity-link authorize URL returned by Supabase may point at.
    var authorizeHosts: Set<String> { self == .github ? ["github.com"] : ["accounts.google.com"] }
}

public enum NativeOAuthRedirect {
    public static let scheme = "catpawm"
    public static let host = "auth-callback"
    public static let url = URL(string: "catpawm://auth-callback")!
}

public struct NativeOAuthPKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public static let method = "s256"
    /// RFC 7636: 43...128 unreserved characters.
    public init(verifier: String) throws {
        guard (43...128).contains(verifier.utf8.count),
              verifier.range(of: "^[A-Za-z0-9._~-]+$", options: .regularExpression) != nil else { throw NativeAuthError.invalidConfiguration }
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    public static func generate(random: (Int) throws -> Data = Self.secureRandom) throws -> NativeOAuthPKCE {
        let bytes = try random(48)
        guard bytes.count == 48 else { throw NativeAuthError.storage }
        return try .init(verifier: base64URL(bytes))   // 64 chars
    }
    public static func secureRandom(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NativeAuthError.storage }
        return data
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum NativeOAuthCallback: Sendable, Equatable {
    case code(String)
    case cancelled
    /// Supabase `error_code` (e.g. identity_already_exists, manual_linking_disabled), already allow-list sanitised.
    case failure(code: String?)

    /// Accepts only `catpawm://auth-callback?code=…` (PKCE) or an error redirect. Implicit-flow tokens in the
    /// fragment are refused: a session must never ride in a URL.
    public static func parse(_ url: URL) throws -> NativeOAuthCallback {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == NativeOAuthRedirect.scheme, c.host?.lowercased() == NativeOAuthRedirect.host,
              c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty || c.path == "/" else { throw NativeAuthError.callbackUnsupported }
        var items: [String: String] = [:]
        for item in (c.queryItems ?? []) + (URLComponents(string: "x:?" + (c.fragment ?? ""))?.queryItems ?? []) {
            guard items[item.name] == nil else { throw NativeAuthError.invalidResponse }   // duplicate params are ambiguous
            items[item.name] = item.value ?? ""
        }
        if items["access_token"] != nil || items["refresh_token"] != nil { throw NativeAuthError.callbackUnsupported }
        if let error = items["error"] {
            let raw = items["error_code"] ?? error
            let code = raw.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil ? raw : nil
            return code == "access_denied" ? .cancelled : .failure(code: code)
        }
        guard let code = items["code"], code.range(of: "^[A-Za-z0-9._-]{8,512}$", options: .regularExpression) != nil else { throw NativeAuthError.invalidResponse }
        return .code(code)
    }
}

public enum NativeOAuthRequest {
    /// GET {project}/auth/v1/authorize — opened in ASWebAuthenticationSession.
    public static func authorizeURL(projectURL: URL, provider: NativeOAuthProvider, pkce: NativeOAuthPKCE, redirect: URL = NativeOAuthRedirect.url) -> URL {
        var c = URLComponents(url: projectURL.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "provider", value: provider.rawValue), .init(name: "redirect_to", value: redirect.absoluteString),
                        .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: NativeOAuthPKCE.method)]
        return c.url!
    }
    /// GET {project}/auth/v1/user/identities/authorize (bearer) → JSON { url } — supabase-js `linkIdentity`.
    public static func linkIdentityRequest(configuration: NativeAuthConfiguration, accessToken: String, provider: NativeOAuthProvider, pkce: NativeOAuthPKCE) -> URLRequest {
        var c = URLComponents(url: configuration.projectURL.appendingPathComponent("auth/v1/user/identities/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "provider", value: provider.rawValue), .init(name: "redirect_to", value: NativeOAuthRedirect.url.absoluteString),
                        .init(name: "code_challenge", value: pkce.challenge), .init(name: "code_challenge_method", value: NativeOAuthPKCE.method),
                        .init(name: "skip_http_redirect", value: "true")]
        var r = URLRequest(url: c.url!)
        r.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }
    /// The link response URL must be an https provider authorize page (never an arbitrary host).
    public static func validateLinkAuthorizeURL(_ url: URL, provider: NativeOAuthProvider) throws -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", let host = c.host?.lowercased(),
              provider.authorizeHosts.contains(host), c.user == nil, c.password == nil else { throw NativeAuthError.invalidResponse }
        return url
    }
}

public struct NativeLinkedIdentity: Sendable, Equatable, Hashable {
    public let provider: String
    public let label: String?
    public init(provider: String, label: String?) { self.provider = provider; self.label = label }
}

public protocol NativeOAuthRemote: Sendable {
    func exchangeOAuthCode(_ code: String, verifier: String) async throws -> NativeAuthCredential
    func linkIdentityURL(accessToken: String, provider: NativeOAuthProvider, pkce: NativeOAuthPKCE) async throws -> URL
    func identities(accessToken: String) async throws -> [NativeLinkedIdentity]
}

/// Link-vs-switch decision. Linking keeps the same auth subject, so the account-bound local partition
/// (AuthenticatedLocalPartition is keyed by subject) and every trial conversation carry over untouched.
/// Signing in to a *different* account goes through the existing sign-out → park → restore flow.
public enum NativeAccountEntryPlan: Sendable, Equatable {
    case signIn(NativeOAuthProvider)                         // nobody signed in
    case link(NativeOAuthProvider)                           // trial or permanent account adds this provider
    case alreadyLinked(NativeOAuthProvider)
    case switchAccount(NativeOAuthProvider, discardsTrial: Bool)
    case blocked(String)

    public enum Intent: Sendable { case attach, useOtherAccount }

    public static func plan(current: NativeAuthUser?, linked: Set<String>, provider: NativeOAuthProvider, intent: Intent) -> NativeAccountEntryPlan {
        guard let current else { return .signIn(provider) }
        switch intent {
        case .attach: return linked.contains(provider.rawValue) ? .alreadyLinked(provider) : .link(provider)
        case .useOtherAccount: return .switchAccount(provider, discardsTrial: current.isAnonymous)
        }
    }
    /// Maps a failed link callback / API code to the next step.
    public static func afterLinkFailure(code: String?, current: NativeAuthUser, provider: NativeOAuthProvider) -> NativeAccountEntryPlan {
        switch code {
        case "identity_already_exists", "identity_already_linked", "email_exists", "user_already_exists":
            return .switchAccount(provider, discardsTrial: current.isAnonymous)
        case "manual_linking_disabled": return .blocked("账号绑定暂未开放。")
        case "provider_disabled", "oauth_provider_not_supported": return .blocked("该登录方式暂未开放。")
        default: return .blocked("绑定未完成，请稍后重试。")
        }
    }
}
