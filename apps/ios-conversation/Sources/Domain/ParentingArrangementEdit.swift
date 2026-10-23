import Foundation

/// A local selection frozen before an edit request. Model output never supplies this identity.
public struct ParentingArrangementEditTarget: Codable, Sendable, Equatable {
    public var arrangement: ParentingArrangement
    public var workspaceRevision: Int

    public init(arrangement: ParentingArrangement, workspaceRevision: Int) {
        self.arrangement = arrangement
        self.workspaceRevision = workspaceRevision
    }

    public func matches(workspace: ParentingWorkspace) -> Bool {
        workspaceRevision == workspace.revision && workspace.arrangements.first(where: { $0.id == arrangement.id }) == arrangement
    }
}

/// The exact saved transition, encrypted with the arrangement and operation receipt.
public struct ParentingArrangementEdit: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var before: ParentingArrangement
    public var after: ParentingArrangement
    public var sourceText: String
    public var createdAt: Date
    public var revertedAt: Date?
    public var supersededAt: Date?

    public init(id: UUID, before: ParentingArrangement, after: ParentingArrangement, sourceText: String, createdAt: Date, revertedAt: Date? = nil, supersededAt: Date? = nil) {
        self.id = id
        self.before = before
        self.after = after
        self.sourceText = sourceText
        self.createdAt = createdAt
        self.revertedAt = revertedAt
        self.supersededAt = supersededAt
    }

    public func canUndo(in workspace: ParentingWorkspace) -> Bool {
        guard revertedAt == nil, supersededAt == nil,
              workspace.arrangements.first(where: { $0.id == after.id }) == after,
              workspace.children.contains(where: { $0.id == before.childID }) else { return false }
        if let goalID = before.goalID {
            return workspace.goals.contains(where: { $0.id == goalID && $0.childID == before.childID })
        }
        return true
    }
}

extension ParentingWorkspace {
    /// Only known start minutes can be compared: this does not establish overlapping durations.
    public func sameTimeConflicts(arrangementID: UUID, dueAt: Date) -> [ParentingArrangement] {
        guard dueAt.timeIntervalSince1970.isFinite else { return [] }
        let minute = floor(dueAt.timeIntervalSince1970 / 60)
        return arrangements.filter {
            $0.id != arrangementID && $0.state == .planned && floor($0.dueAt.timeIntervalSince1970 / 60) == minute
        }.sorted {
            if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
