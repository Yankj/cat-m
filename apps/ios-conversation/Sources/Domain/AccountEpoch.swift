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

/// p89i (shared with #90 proactive notifications/snoozes and #91 feedback posts): GENERIC "park + per-item user decision".
/// A subsystem that may hold account-bound work when the account goes away registers one `AccountParkedItemSource`.
///
/// Deterministic logout / account-switch order (the ONLY order; #90/#91 adopt it instead of their own logout paths):
///   1. synchronous `AccountEpoch` bump (+ credentials die) — nothing can commit under the leaving account from here;
///   2. `AccountParkedItems.collect(account: leaving)` — every source lists its parked items (in key order);
///   3. decision per item: the app's OWN data (chats, proactive cards/snoozes, feedback posts, ledger bookkeeping, queued
///      UI decisions, network tasks) carries an `automatic` decision — parked/isolated under the old account, never run
///      under the new one, never silently deleted, no prompt. Only items with EXTERNAL effects (EventKit events/reminders
///      the app created) have `automatic == nil` and go to the user (`Decider`, one shared UI); no decider (passive
///      invalidation, account switch, tests) or no answer → `.keep`. Every decision is logged;
///   4. `apply` per item, in collect order, each returns a log line;
///   5. `AccountChangeObservers.notify(previous:current:)` cleanups (unchanged API).
/// Semantics: `.keep` = the item stays parked for that account (not executed, not deleted) and is offered again when the
/// same account returns; `.cancel` = the source cancels / undoes it as far as it can without the leaving account's
/// authority, and says so in its log line.
public struct AccountParkedItem: Sendable, Equatable, Identifiable {
    public let source: String; public let key: String; public let title: String; public let detail: String
    /// nil = external effect → the user decides; otherwise the source's automatic decision (app-internal data).
    public let automatic: AccountParkedDecision?
    public var id: String { source + "/" + key }
    public init(source: String, key: String, title: String, detail: String = "", automatic: AccountParkedDecision? = nil) { self.source = source; self.key = key; self.title = title; self.detail = detail; self.automatic = automatic }
}
/// keep = leave it (parked for that account / external item left in place); cancel = cancel it, or undo the external effect.
public enum AccountParkedDecision: String, Sendable, Equatable { case keep, cancel }
@MainActor public protocol AccountParkedItemSource: AnyObject {
    /// Items `account` still has in this subsystem. Called AFTER the epoch bump; must not re-grant anything.
    func parkedItems(account: String) -> [AccountParkedItem]
    /// Apply the user's decision; returns one log line describing the effect.
    func apply(_ decision: AccountParkedDecision, to item: AccountParkedItem, account: String) async -> String
}
@MainActor public enum AccountParkedItems {
    public typealias Decider = @MainActor (_ items: [AccountParkedItem]) async -> [String: AccountParkedDecision]
    private static var sources: [String: AccountParkedItemSource] = [:]
    public static func register(_ key: String, _ source: AccountParkedItemSource) { sources[key] = source }
    public static func unregister(_ key: String) { sources[key] = nil }
    public static var registeredKeys: [String] { sources.keys.sorted() }
    /// Log sink (tests / diagnostics); every line is also NSLog'ed.
    public static var sink: ((String) -> Void)?
    public static func log(_ line: String) { sink?(line); NSLog("catpaw.account.parked %@", line) }
    /// Step 2. Items are tagged with their registration key as `source`.
    public static func collect(account: String?) -> [AccountParkedItem] {
        guard let account else { return [] }
        return registeredKeys.flatMap { k in (sources[k]?.parkedItems(account: account) ?? []).map { AccountParkedItem(source: k, key: $0.key, title: $0.title, detail: $0.detail, automatic: $0.automatic) } }
    }
    /// Steps 2–4. Call only AFTER the synchronous epoch bump. Returns the log lines (also written to `sink`).
    @discardableResult public static func resolve(account: String?, decider: Decider?) async -> [String] {
        guard let account else { return [] }
        let items = collect(account: account)
        guard !items.isEmpty else { return [] }
        var lines = ["parked: \(items.count) item(s) for leaving account"]
        let ask = items.filter { $0.automatic == nil }
        var answers: [String: AccountParkedDecision] = [:]
        if !ask.isEmpty {
            if let decider { answers = await decider(ask) } else { lines.append("no decider → external items default keep") }
        }
        for item in items {
            let d = item.automatic ?? answers[item.id] ?? .keep
            let effect = await sources[item.source]?.apply(d, to: item, account: account) ?? "source gone"
            lines.append("\(item.id) \(d.rawValue)\(item.automatic != nil ? " (auto)" : ""): \(effect)")
        }
        lines.forEach(log)
        return lines
    }
}
