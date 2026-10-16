import Foundation

/// RED scaffold (replaced by the fix commit): API shape only, no barrier yet.
public struct AccountToken: Sendable, Equatable, Hashable { public let account: String; public let epoch: UInt64 }
public final class AccountEpoch: @unchecked Sendable {
    public static let shared = AccountEpoch()
    private var account: String?
    public init(account: String? = nil) { self.account = account }
    public func capture() -> AccountToken? { account.map { .init(account: $0, epoch: 0) } }
    public func activate(account: String?) { self.account = account }
    public func signOut() {}
    public func bump() {}
    public var epoch: UInt64 { 0 }
    public func isValid(_ token: AccountToken?) -> Bool { token != nil }
    @discardableResult public func commit<T>(_ token: AccountToken?, _ write: () throws -> T) rethrows -> T? { try write() }
}
