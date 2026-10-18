import AuthenticationServices
import UIKit

/// ASWebAuthenticationSession wrapper. Ephemeral (no shared Safari cookies), so every demo shows the provider
/// consent page and nothing leaks between accounts. Returns the raw callback URL; parsing is NativeOAuthCallback.
@MainActor final class NativeOAuthWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func start(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callback, error in
                self?.session = nil
                if let callback { continuation.resume(returning: callback); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { continuation.resume(throwing: NativeAuthError.cancelled); return }
                continuation.resume(throwing: NativeAuthError.unavailable)
            }
            let s: ASWebAuthenticationSession
            if #available(iOS 17.4, *) {
                s = ASWebAuthenticationSession(url: url, callback: .customScheme(NativeOAuthRedirect.scheme), completionHandler: completion)
            } else {
                s = ASWebAuthenticationSession(url: url, callbackURLScheme: NativeOAuthRedirect.scheme, completionHandler: completion)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = true
            session = s
            if !s.start() { session = nil; continuation.resume(throwing: NativeAuthError.unavailable) }
        }
    }
    func cancel() { session?.cancel(); session = nil }
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
