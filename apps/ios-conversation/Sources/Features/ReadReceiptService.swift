import Foundation

extension WorkspaceService {
    public func markDocumentOpened(scope: DataScope, reference: DocumentReference, now: Date = Date()) async throws {
        let verified = try await readDocument(scope: scope, id: reference.documentID, version: reference.version)
        guard verified.0.contentHash == reference.contentHash else { throw CatpawError.conflict }
        try await repository.recordViewReceipt(scope: scope, reference: reference, now: now)
    }
}
extension Repository {
    // The existing-receipt check and durable create happen within one actor turn.
    func recordViewReceipt(scope: DataScope, reference: DocumentReference, now: Date) throws {
        let id = ViewReceipt.id(scope: scope, reference: reference)
        let snapshot = read(scope: scope)
        if let previous = snapshot.records[id], previous.header.deletedAt == nil {
            guard case .viewReceipt(let receipt) = previous.payload, receipt.userID == scope.profileID, receipt.document == reference else { throw CatpawError.conflict }
            return
        }
        try commit(operationID: stableID("open-\(id)"), scope: scope, mutations: [.create(id, .viewReceipt(ViewReceipt(userID: scope.profileID, document: reference, openedAt: now)))])
    }
}
extension StoreSnapshot {
    public func isViewed(scope: DataScope, reference: DocumentReference) -> Bool {
        guard let record = records[ViewReceipt.id(scope: scope, reference: reference)], record.header.scope == scope, record.header.deletedAt == nil,
              case .viewReceipt(let receipt) = record.payload else { return false }
        return receipt.userID == scope.profileID && receipt.document == reference
    }
}
