import Foundation

// A semantic boundary until the facade HTTP contract is frozen. No endpoint or network implementation here.
public protocol OpenMuseTaskTransport: Sendable {
    var provenance: OpenMuseProvenance { get }
    func create(_ request: OpenMuseFrozenRequest) async throws -> OpenMuseTaskBinding
    func readOriginal(_ request: OpenMuseFrozenRequest, knownTaskID: String?) async throws -> OpenMuseTaskProjection
    func control(_ request: OpenMuseFrozenRequest, knownTaskID: String?, command: OpenMuseControlCommand, expectedRevision: Int, expectedGrantEpoch: Int) async throws -> OpenMuseControlReceipt
    func readApproval(_ request: OpenMuseFrozenRequest, taskID: String, proposalID: String) async throws -> OpenMuseApprovalSnapshot
    func decide(_ preview: OpenMuseApprovalPreview, decision: OpenMuseDecision) async throws -> OpenMuseDecisionReceipt
    func readReceipt(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt
    func checkReceiptEvidence(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt
}
public extension OpenMuseTaskTransport {
    func checkReceiptEvidence(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt {
        throw catError.unavailable("Independent/effect evidence check is unsupported by this transport.")
    }
}
public struct UnconfiguredOpenMuseTransport: OpenMuseTaskTransport {
    public let provenance: OpenMuseProvenance = .fixtureTransport
    public init() {}
    public func create(_ request: OpenMuseFrozenRequest) async throws -> OpenMuseTaskBinding { throw catError.unavailable("Facade HTTP contract/session is not configured.") }
    public func readOriginal(_ request: OpenMuseFrozenRequest, knownTaskID: String?) async throws -> OpenMuseTaskProjection { throw catError.unavailable("Facade authoritative read is not configured.") }
    public func control(_ request: OpenMuseFrozenRequest, knownTaskID: String?, command: OpenMuseControlCommand, expectedRevision: Int, expectedGrantEpoch: Int) async throws -> OpenMuseControlReceipt { throw catError.unavailable("Facade control/revocation is not configured; local fencing is not server revocation.") }
    public func readApproval(_ request: OpenMuseFrozenRequest, taskID: String, proposalID: String) async throws -> OpenMuseApprovalSnapshot { throw catError.unavailable("Minimal proposal GET is not configured.") }
    public func decide(_ preview: OpenMuseApprovalPreview, decision: OpenMuseDecision) async throws -> OpenMuseDecisionReceipt { throw catError.unavailable("Synthetic decision transport is not configured.") }
    public func readReceipt(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt { throw catError.unavailable("Original receipt reconciliation is not configured.") }
}
