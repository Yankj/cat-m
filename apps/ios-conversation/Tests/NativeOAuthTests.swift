import XCTest
@testable import CatpawM

/// feat/oauth-github-google: PKCE, callback parsing, authorize URLs, link-vs-switch decision, session link invariants.
final class NativeOAuthTests: XCTestCase {
    private func config() throws -> NativeAuthConfiguration { try .init(projectURL:URL(string:"https://abcdefghijklmnopqrst.supabase.co")!,publishableKey:"sb_publishable_test_public_value",backendOrigin:URL(string:"https://backend.example.invalid")!) }

    func testPKCEChallengeIsBase64URLSHA256() throws {
        let p = try NativeOAuthPKCE(verifier: "dBjftJeZ4CVP-mJ92K1qW8hHIy3cdVHpDE9obnl8LZ0")
        XCTAssertEqual(p.challenge, "B8-0QAoYW3wDWSiw9mHcK5KL5vTJQfJN6J4gW0k1es0")
        XCTAssertThrowsError(try NativeOAuthPKCE(verifier: "short"))
        XCTAssertThrowsError(try NativeOAuthPKCE(verifier: String(repeating: "a", count: 129)))
        XCTAssertThrowsError(try NativeOAuthPKCE(verifier: String(repeating: "a", count: 42) + "+"))
    }
    func testGeneratedPKCEIsUniqueAndValidLength() throws {
        let a = try NativeOAuthPKCE.generate(), b = try NativeOAuthPKCE.generate()
        XCTAssertNotEqual(a.verifier, b.verifier); XCTAssertEqual(a.verifier.count, 64)
        XCTAssertThrowsError(try NativeOAuthPKCE.generate(random: { _ in Data(count: 3) }))
    }
    func testAuthorizeURLCarriesPKCEAndRedirect() throws {
        let p = try NativeOAuthPKCE(verifier: String(repeating: "v", count: 50))
        let url = NativeOAuthRequest.authorizeURL(projectURL: try config().projectURL, provider: .github, pkce: p)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(c.host, "abcdefghijklmnopqrst.supabase.co"); XCTAssertEqual(c.path, "/auth/v1/authorize")
        XCTAssertEqual(q, ["provider": "github", "redirect_to": "catpawm://auth-callback", "code_challenge": p.challenge, "code_challenge_method": "s256"])
        XCTAssertFalse(url.absoluteString.contains(p.verifier), "verifier never leaves the device")
    }
    func testLinkRequestIsBearerSkipRedirect() throws {
        let p = try NativeOAuthPKCE(verifier: String(repeating: "v", count: 50))
        let r = NativeOAuthRequest.linkIdentityRequest(configuration: try config(), accessToken: "a.b.c", provider: .google, pkce: p)
        XCTAssertEqual(r.url?.path, "/auth/v1/user/identities/authorize")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer a.b.c")
        XCTAssertTrue(r.url!.query!.contains("skip_http_redirect=true")); XCTAssertTrue(r.url!.query!.contains("provider=google"))
        XCTAssertNoThrow(try NativeOAuthRequest.validateLinkAuthorizeURL(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?x=1")!, provider: .google))
        XCTAssertThrowsError(try NativeOAuthRequest.validateLinkAuthorizeURL(URL(string: "https://evil.example/o")!, provider: .google))
        XCTAssertThrowsError(try NativeOAuthRequest.validateLinkAuthorizeURL(URL(string: "http://github.com/login/oauth/authorize")!, provider: .github))
    }
    func testCallbackParsing() throws {
        XCTAssertEqual(try NativeOAuthCallback.parse(URL(string: "catpawm://auth-callback?code=8b7f2a4e-1111-2222-3333-444455556666")!), .code("8b7f2a4e-1111-2222-3333-444455556666"))
        XCTAssertEqual(try NativeOAuthCallback.parse(URL(string: "catpawm://auth-callback?error=access_denied&error_description=user+cancelled")!), .cancelled)
        XCTAssertEqual(try NativeOAuthCallback.parse(URL(string: "catpawm://auth-callback#error=server_error&error_code=identity_already_exists")!), .failure(code: "identity_already_exists"))
        XCTAssertEqual(try NativeOAuthCallback.parse(URL(string: "catpawm://auth-callback?error=x&error_code=Bad%20Code")!), .failure(code: nil))
        for bad in ["catpawm://auth-callback#access_token=a.b.c&refresh_token=r", "catpawm://other?code=12345678", "evil://auth-callback?code=12345678",
                    "catpawm://auth-callback?code=12345678&code=87654321", "catpawm://auth-callback?code=<script>", "catpawm://auth-callback"] {
            XCTAssertThrowsError(try NativeOAuthCallback.parse(URL(string: bad)!), bad)
        }
    }
    func testLinkVersusSwitchDecision() {
        let trial = NativeAuthUser(id: UUID(), isAnonymous: true), perm = NativeAuthUser(id: UUID(), email: "a@b.c")
        XCTAssertEqual(NativeAccountEntryPlan.plan(current: nil, linked: [], provider: .github, intent: .attach), .signIn(.github))
        XCTAssertEqual(NativeAccountEntryPlan.plan(current: trial, linked: ["anonymous"], provider: .github, intent: .attach), .link(.github))
        XCTAssertEqual(NativeAccountEntryPlan.plan(current: perm, linked: ["github"], provider: .github, intent: .attach), .alreadyLinked(.github))
        XCTAssertEqual(NativeAccountEntryPlan.plan(current: perm, linked: ["github"], provider: .google, intent: .attach), .link(.google))
        XCTAssertEqual(NativeAccountEntryPlan.plan(current: trial, linked: [], provider: .google, intent: .useOtherAccount), .switchAccount(.google, discardsTrial: true))
        XCTAssertEqual(NativeAccountEntryPlan.afterLinkFailure(code: "identity_already_exists", current: trial, provider: .github), .switchAccount(.github, discardsTrial: true))
        XCTAssertEqual(NativeAccountEntryPlan.afterLinkFailure(code: "identity_already_exists", current: perm, provider: .github), .switchAccount(.github, discardsTrial: false))
        XCTAssertEqual(NativeAccountEntryPlan.afterLinkFailure(code: "manual_linking_disabled", current: trial, provider: .github), .blocked("账号绑定暂未开放。"))
    }
    // MARK: session manager
    func testOAuthSignInPersistsVerifiedPermanentCredential() async throws {
        let c = try config(), id = UUID(), storage = AuthTestStorage()
        let remote = OAuthFakeRemote(issuer: c.issuer, anonymous: nil, oauthSubject: id)
        let m = NativeAuthSessionManager(configuration: c, remote: remote, vault: storage, barrier: storage)
        try await m.signInWithOAuth(code: "code-12345678", verifier: String(repeating: "v", count: 50))
        let s = await m.snapshot()
        XCTAssertEqual(s.phase, .authenticated); XCTAssertEqual(s.user?.id, id); XCTAssertEqual(s.user?.isAnonymous, false)
        XCTAssertEqual(try storage.load()?.user.id, id); XCTAssertFalse(try storage.isSignedOut())
    }
    func testLinkKeepsSubjectAndUpgradesTrial() async throws {
        let c = try config(), id = UUID(), storage = AuthTestStorage()
        let remote = OAuthFakeRemote(issuer: c.issuer, anonymous: id, oauthSubject: id)
        let m = NativeAuthSessionManager(configuration: c, remote: remote, vault: storage, barrier: storage)
        try await m.startExperience()
        let before = await m.snapshot(); XCTAssertEqual(before.user?.isAnonymous, true)
        _ = try await m.oauthLinkURL(provider: .github, pkce: try NativeOAuthPKCE(verifier: String(repeating: "v", count: 50)))
        try await m.completeOAuthLink(code: "code-12345678", verifier: String(repeating: "v", count: 50))
        let after = await m.snapshot()
        XCTAssertEqual(after.user?.id, id, "same subject → same AuthenticatedLocalPartition → trial data carries over")
        XCTAssertEqual(after.user?.isAnonymous, false); XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(try storage.load()?.user.isAnonymous, false)
    }
    func testLinkRejectsDifferentSubject() async throws {
        let c = try config(), storage = AuthTestStorage()
        let remote = OAuthFakeRemote(issuer: c.issuer, anonymous: UUID(), oauthSubject: UUID())
        let m = NativeAuthSessionManager(configuration: c, remote: remote, vault: storage, barrier: storage)
        try await m.startExperience()
        let trial = await m.snapshot().user
        do { try await m.completeOAuthLink(code: "code-12345678", verifier: String(repeating: "v", count: 50)); XCTFail("must not switch subject") }
        catch NativeAuthError.invalidResponse { }
        let afterUser = await m.snapshot().user; XCTAssertEqual(afterUser, trial); XCTAssertEqual(try storage.load()?.user, trial)
    }
    func testSignInWhileSignedInIsBusy() async throws {
        let c = try config(), storage = AuthTestStorage(), id = UUID()
        let m = NativeAuthSessionManager(configuration: c, remote: OAuthFakeRemote(issuer: c.issuer, anonymous: id, oauthSubject: UUID()), vault: storage, barrier: storage)
        try await m.startExperience()
        do { try await m.signInWithOAuth(code: "code-12345678", verifier: String(repeating: "v", count: 50)); XCTFail() } catch NativeAuthError.busy { }
        let still = await m.snapshot().user?.id; XCTAssertEqual(still, id)
    }
}

actor OAuthFakeRemote: NativeAuthRemote, NativeOAuthRemote {
    let issuer: String; let anonymous: UUID?; let oauthSubject: UUID
    private var linked = false
    init(issuer: String, anonymous: UUID?, oauthSubject: UUID) { self.issuer = issuer; self.anonymous = anonymous; self.oauthSubject = oauthSubject }
    private func cred(_ id: UUID, anon: Bool) -> NativeAuthCredential { .init(issuer: issuer, user: .init(id: id, isAnonymous: anon), accessToken: "oauth.\(anon ? "anon" : "perm").sig", refreshToken: "r-\(id.uuidString)", expiresAt: Date().addingTimeInterval(3600)) }
    func signInAnonymously() async throws -> NativeAuthCredential { cred(anonymous!, anon: true) }
    func signIn(email: String, password: String) async throws -> NativeAuthCredential { throw NativeAuthError.invalidCredentials }
    func refresh(refreshToken: String) async throws -> NativeAuthCredential { throw NativeAuthError.unavailable }
    func user(accessToken: String) async throws -> NativeAuthUser { accessToken.contains("anon") ? .init(id: anonymous!, isAnonymous: true) : .init(id: oauthSubject) }
    func signOut(accessToken: String) async throws { }
    func exchangeOAuthCode(_ code: String, verifier: String) async throws -> NativeAuthCredential { cred(oauthSubject, anon: false) }
    func linkIdentityURL(accessToken: String, provider: NativeOAuthProvider, pkce: NativeOAuthPKCE) async throws -> URL { linked = true; return URL(string: "https://github.com/login/oauth/authorize")! }
    func identities(accessToken: String) async throws -> [NativeLinkedIdentity] { [.init(provider: "github", label: "demo")] }
}
