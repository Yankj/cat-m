import Foundation

/// A prior local workspace receipt, never a cloud credential or Auth identity.
struct LocalConversationReceipt: Codable {
    let issuer: String
    let subject: UUID
    let serverScopeID: UUID
    func partition(candidate:NativeAuthCredential?,signedOut:Bool,expectedIssuer:String) -> AuthenticatedLocalPartition? {
        guard !signedOut,issuer == expectedIssuer,let candidate,candidate.issuer == issuer,candidate.user.id == subject else { return nil }
        return .init(issuer:issuer,subject:subject,serverScopeID:serverScopeID)
    }
}
