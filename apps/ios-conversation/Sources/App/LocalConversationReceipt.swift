import Foundation

/// A prior local workspace receipt, never a cloud credential or Auth identity.
struct LocalConversationReceipt: Codable {
    let issuer: String
    let subject: UUID
    let serverScopeID: UUID
    /// Optional local metadata; older three-field receipts remain readable by both old and new clients.
    /// A provisional scope must never receive a writable parenting ledger.
    let canonicalScope: Bool?
    init(issuer: String, subject: UUID, serverScopeID: UUID, canonicalScope: Bool? = nil) {
        self.issuer = issuer; self.subject = subject; self.serverScopeID = serverScopeID; self.canonicalScope = canonicalScope
    }
    func partition(candidate:NativeAuthCredential?,signedOut:Bool,expectedIssuer:String) -> AuthenticatedLocalPartition? {
        guard !signedOut,issuer == expectedIssuer,let candidate,candidate.issuer == issuer,candidate.user.id == subject else { return nil }
        return .init(issuer:issuer,subject:subject,serverScopeID:serverScopeID)
    }
}
