import Foundation
import SwiftUI

/// The narrow session surface OAuth needs; NativeAuthSessionManager conforms. Test seam.
protocol NativeOAuthSessionDriving: Sendable {
    func snapshot() async -> NativeAuthSnapshot
    func signInWithOAuth(code: String, verifier: String) async throws
    func oauthLinkURL(provider: NativeOAuthProvider, pkce: NativeOAuthPKCE) async throws -> URL
    func completeOAuthLink(code: String, verifier: String) async throws
    func linkedIdentities() async throws -> [NativeLinkedIdentity]
}
extension NativeAuthSessionManager: NativeOAuthSessionDriving {}

@MainActor protocol NativeOAuthBrowsing: AnyObject { func start(_ url: URL) async throws -> URL }
extension NativeOAuthWebSession: NativeOAuthBrowsing {}

/// GitHub / Google entry + identity linking. Owns no credential: every token goes through the session
/// manager's verified persistence. Errors / cancel surface as one small capsule (`notice`), never a page.
@MainActor final class NativeOAuthCoordinator: ObservableObject {
    struct Notice: Equatable { let text: String; let isError: Bool }
    struct PendingSwitch: Equatable { let provider: NativeOAuthProvider; let discardsTrial: Bool }
    @Published private(set) var busy: NativeOAuthProvider?
    @Published var notice: Notice?
    @Published private(set) var identities: [NativeLinkedIdentity] = []
    @Published var pendingSwitch: PendingSwitch?

    private var session: (any NativeOAuthSessionDriving)?
    private var projectURL: URL?
    private let browser: any NativeOAuthBrowsing
    private let makePKCE: () throws -> NativeOAuthPKCE
    private var signOutAndPark: (@MainActor () async -> Void)?
    private var afterSignIn: (@MainActor () async -> Void)?

    init(browser: (any NativeOAuthBrowsing)? = nil, makePKCE: @escaping () throws -> NativeOAuthPKCE = { try NativeOAuthPKCE.generate() }) {
        self.browser = browser ?? NativeOAuthWebSession(); self.makePKCE = makePKCE
    }
    var isAvailable: Bool { session != nil && projectURL != nil }
    func bind(session: (any NativeOAuthSessionDriving)?, projectURL: URL?, signOutAndPark: @escaping @MainActor () async -> Void, afterSignIn: @escaping @MainActor () async -> Void) {
        self.session = session; self.projectURL = projectURL; self.signOutAndPark = signOutAndPark; self.afterSignIn = afterSignIn
    }

    func continueWith(_ provider: NativeOAuthProvider, intent: NativeAccountEntryPlan.Intent = .attach) async {
        guard busy == nil, let session else { return }
        let snap = await session.snapshot()
        let user = snap.phase == .authenticated ? snap.user : nil
        let linked = Set(identities.map(\.provider))
        await run(NativeAccountEntryPlan.plan(current: user, linked: linked, provider: provider, intent: intent), user: user)
    }
    /// User confirmed the switch dialog: leave via the normal sign-out (parks account data, EventKit prompt per
    /// trust rules), then sign in with the provider.
    func confirmSwitch() async {
        guard let pending = pendingSwitch, let session else { return }
        pendingSwitch = nil
        await signOutAndPark?()
        guard await session.snapshot().user == nil else { notice = .init(text: "退出未完成，请稍后重试。", isError: true); return }
        await run(.signIn(pending.provider), user: nil)
    }
    func refreshIdentities() async {
        guard let session, (await session.snapshot()).phase == .authenticated else { identities = []; return }
        identities = (try? await session.linkedIdentities()) ?? identities
    }

    private func run(_ plan: NativeAccountEntryPlan, user: NativeAuthUser?) async {
        guard let session, let projectURL else { notice = .init(text: "登录连接尚未配置。", isError: true); return }
        switch plan {
        case .alreadyLinked(let p): notice = .init(text: p == .github ? "已绑定 GitHub。" : "已绑定 Google。", isError: false)
        case .blocked(let text): notice = .init(text: text, isError: true)
        case .switchAccount(let p, let discards): pendingSwitch = .init(provider: p, discardsTrial: discards)
        case .signIn(let p):
            busy = p; defer { busy = nil }
            do {
                let pkce = try makePKCE()
                let callback = try NativeOAuthCallback.parse(try await browser.start(NativeOAuthRequest.authorizeURL(projectURL: projectURL, provider: p, pkce: pkce)))
                switch callback {
                case .cancelled: notice = .init(text: "登录已取消。", isError: false)
                case .failure: notice = .init(text: "登录未完成，请稍后重试。", isError: true)
                case .code(let code):
                    try await session.signInWithOAuth(code: code, verifier: pkce.verifier)
                    notice = nil
                    await afterSignIn?()
                    await refreshIdentities()
                }
            } catch { notice = Self.notice(for: error) }
        case .link(let p):
            guard let user else { return }
            busy = p; defer { busy = nil }
            do {
                let pkce = try makePKCE()
                let url = try await session.oauthLinkURL(provider: p, pkce: pkce)
                switch try NativeOAuthCallback.parse(try await browser.start(url)) {
                case .cancelled: notice = .init(text: "绑定已取消。", isError: false)
                case .failure(let code): await runFailure(NativeAccountEntryPlan.afterLinkFailure(code: code, current: user, provider: p))
                case .code(let code):
                    try await session.completeOAuthLink(code: code, verifier: pkce.verifier)
                    notice = .init(text: user.isAnonymous ? "已绑定，体验期间的对话都已保留。" : "已绑定。", isError: false)
                    await refreshIdentities()
                }
            } catch let e as NativeOAuthLinkError {
                await runFailure(NativeAccountEntryPlan.afterLinkFailure(code: e.code, current: user, provider: p))
            } catch { notice = Self.notice(for: error) }
        }
    }
    private func runFailure(_ plan: NativeAccountEntryPlan) async {
        if case .switchAccount(let p, let d) = plan { pendingSwitch = .init(provider: p, discardsTrial: d) } else { await run(plan, user: nil) }
    }
    static func notice(for error: Error) -> Notice {
        switch error as? NativeAuthError {
        case .cancelled?: return .init(text: "登录已取消。", isError: false)
        case let e?: return .init(text: e.localizedDescription, isError: true)
        case nil: return .init(text: "登录服务暂不可用，请稍后重试。", isError: true)
        }
    }
}

private struct NativeOAuthCoordinatorKey: EnvironmentKey { static let defaultValue: NativeOAuthCoordinator? = nil }
extension EnvironmentValues {
    /// nil in fixture / synthetic paths → OAuth UI simply does not render.
    var catpawOAuth: NativeOAuthCoordinator? { get { self[NativeOAuthCoordinatorKey.self] } set { self[NativeOAuthCoordinatorKey.self] = newValue } }
}
