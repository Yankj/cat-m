import Foundation

/// A proof of "which account, which sign-in" captured BEFORE an async operation.
public struct AccountToken: Sendable, Equatable, Hashable {
    public let account: String
    public let epoch: UInt64
}

/// Account generation barrier (Codex #89 / #90 / #91). One shared instance; injectable for tests.
///
/// Rule: capture a token before any await (network, ETA, permission prompt, lookup); immediately before any
/// persistent or system write (L2/UserDefaults/file, EventKit, notification, widget, Live Activity, upload) call
/// `commit(token) { write }`. The write runs only if the same account is still signed in in the same epoch.
/// - `signOut()` / `activate(account:)` with a different account bump the epoch synchronously, so every token captured
///   earlier is dead the moment sign-out starts — before any async cleanup.
/// - `commit` holds the lock for the duration of the write, so a concurrent bump waits for it to finish: a write is
///   either fully before the barrier or never happens. Keep the write short and synchronous; never await inside it,
///   and resolve the destination (e.g. the L2 store / key) from the token, not from "current".
/// - Thread-safe (recursive lock, so `capture`/`isValid` may be called from inside `commit`).
public final class AccountEpoch: @unchecked Sendable {
    public static let shared = AccountEpoch()
    private let lock = NSRecursiveLock()
    private var account: String?
    private var counter: UInt64 = 0

    public init(account: String? = nil) { self.account = account }

    /// Current epoch number (monotonic).
    public var epoch: UInt64 { lock.lock(); defer { lock.unlock() }; return counter }
    /// Signed-in account id, nil when signed out.
    public var currentAccount: String? { lock.lock(); defer { lock.unlock() }; return account }

    /// Token for the signed-in account; nil when signed out (→ callers must not start account-bound work).
    public func capture() -> AccountToken? {
        lock.lock(); defer { lock.unlock() }
        return account.map { AccountToken(account: $0, epoch: counter) }
    }
    /// Sign-in / restore / account switch. Same account → no-op (tokens stay valid); anything else bumps.
    public func activate(account new: String?) {
        lock.lock(); defer { lock.unlock() }
        guard new != account else { return }
        account = new; counter &+= 1
    }
    /// Call FIRST in sign-out, synchronously, before any await.
    public func signOut() { lock.lock(); defer { lock.unlock() }; account = nil; counter &+= 1 }
    /// Invalidate every outstanding token without changing the account (e.g. session restart, data wipe).
    public func bump() { lock.lock(); defer { lock.unlock() }; counter &+= 1 }

    public func isValid(_ token: AccountToken?) -> Bool {
        guard let token else { return false }
        lock.lock(); defer { lock.unlock() }
        return account == token.account && counter == token.epoch
    }
    /// Runs `write` only if `token` is still valid, atomically with respect to sign-out/switch. Returns nil if refused.
    @discardableResult public func commit<T>(_ token: AccountToken?, _ write: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard isValid(token) else { return nil }
        return try write()
    }
}

/// Hook point for account-bound subsystems (e.g. #90 `ProactiveEngine.shared.accountDidChange()`).
/// Order contract: the caller bumps `AccountEpoch` SYNCHRONOUSLY first (sign-out / passive invalidation / switch), then
/// awaits `notify`, which runs every registered async cleanup in key order. Cleanups must not re-grant anything; they only
/// tear down state of `previous`.
@MainActor public enum AccountChangeObservers {
    public typealias Cleanup = @MainActor (_ previous: String?, _ current: String?) async -> Void
    private static var observers: [String: Cleanup] = [:]
    public static func register(_ key: String, _ cleanup: @escaping Cleanup) { observers[key] = cleanup }
    public static func unregister(_ key: String) { observers[key] = nil }
    public static var registeredKeys: [String] { observers.keys.sorted() }
    /// Call only AFTER the synchronous epoch bump.
    public static func notify(previous: String?, current: String?) async {
        for key in observers.keys.sorted() { await observers[key]?(previous, current) }
    }
}
