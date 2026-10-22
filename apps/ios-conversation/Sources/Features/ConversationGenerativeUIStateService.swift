import Foundation

/// Local presentation persistence only. No model, transport, admission, approval, task, or effect dependency.
public actor ConversationGenerativeUIStateService {
    public nonisolated let scope: DataScope
    private let repository: Repository
    private var generation = UUID()
    private var active = true
    private struct Lease { let recordID: UUID; var lastSequence: UInt64 = 0 }
    private struct Entry {
        let block: CGUIBlock
        let identity: CGUILocalStateIdentity
        var state: CGUILocalState
        var revision: Int?
        var dirty = false
        var readIssue: CGUIValidationError?
    }
    private var leases: [UUID: Lease] = [:]
    private var entries: [UUID: Entry] = [:]
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func unlock() { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
    public init(repository: Repository, scope: DataScope) { self.repository = repository; self.scope = scope }
    public func open(block: CGUIBlock) async throws -> CGUILocalStateSession {
        let key = try CGUILocalStateIdentity(scope: scope, block: block)
        await lock(); defer { unlock() }
        try ensureActive()
        let observedGeneration = generation
        let conversation = try await repository.record(block.identity.conversationID, scope: scope)
        guard conversation.conversation != nil else { throw catError.missing }
        let snapshot = await repository.read(scope: scope)
        try ensureActive(observedGeneration)
        let recordID = key.recordID
        var restored = false
        let dataChanged = snapshot.records.values.contains { record in
            guard record.header.deletedAt == nil, case .conversationUIState(let old) = record.payload else { return false }
            return old.identity.isSameLineage(as: key) && old.identity != key
        }
        if entries[recordID] == nil {
            var entry = Entry(block: block, identity: key, state: .defaults(for: block))
            if let record = snapshot.records[recordID] {
                guard record.header.deletedAt == nil else { throw catError.missing }
                entry.revision = record.header.revision
                do {
                    guard case .conversationUIState(let saved) = record.payload, saved.schemaVersion == 1,
                          record.header.scope == scope, saved.identity == key, saved.stateJSON.utf8.count <= CGUILimits.payloadBytes,
                          let state = saved.state else { throw CGUIValidationError("localState", "unsupported_or_mismatched_saved_state") }
                    try state.validate(for: block); entry.state = state; restored = true
                } catch { entry.readIssue = (error as? CGUIValidationError) ?? CGUIValidationError("localState", "invalid_saved_state") }
            }
            entries[recordID] = entry
        } else { restored = entries[recordID]?.revision != nil || entries[recordID]?.dirty == true }
        let handle = CGUILocalStateHandle(id: UUID(), identity: key, generation: generation)
        // A replacement editor adopts the staged draft, then revokes its predecessor's late callbacks.
        leases = leases.filter { $0.value.recordID != recordID }
        leases[handle.id] = Lease(recordID: recordID)
        let entry = entries[recordID]!
        return CGUILocalStateSession(handle: handle, initialState: entry.state, restored: restored, dataChanged: dataChanged && !restored, readIssue: entry.readIssue)
    }
    /// Stage synchronously in the actor before debouncing durable writes. Stale UI tasks cannot replace newer edits.
    public func stage(handle: CGUILocalStateHandle, state: CGUILocalState, editSequence: UInt64, explicitlyReset: Bool = false) async throws {
        await lock(); defer { unlock() }
        try stageLocked(handle: handle, state: state, editSequence: editSequence, explicitlyReset: explicitlyReset)
    }
    public func flush(conversationID: UUID? = nil) async throws {
        await lock(); defer { unlock() }
        try ensureActive()
        for id in entries.keys.sorted(by: { $0.uuidString < $1.uuidString }) where conversationID == nil || entries[id]?.identity.block.conversationID == conversationID {
            try await saveLocked(id)
        }
    }
    public func close(handle: CGUILocalStateHandle, state: CGUILocalState, editSequence: UInt64, explicitlyReset: Bool = false) async throws {
        await lock(); defer { unlock() }
        try stageLocked(handle: handle, state: state, editSequence: editSequence, explicitlyReset: explicitlyReset)
        guard let lease = leases[handle.id] else { throw CancellationError() }
        // Keep the lease and unsaved draft on failure so a foreground retry can recover it.
        try await saveLocked(lease.recordID)
        leases.removeValue(forKey: handle.id)
        if !leases.values.contains(where: { $0.recordID == lease.recordID }) { entries.removeValue(forKey: lease.recordID) }
    }
    /// Account/model disposal revokes handles immediately, including actor operations waiting on Repository.
    public func invalidate() {
        active = false; generation = UUID(); leases.removeAll(); entries.removeAll()
    }
    private func ensureActive(_ expected: UUID? = nil) throws {
        try Task.checkCancellation()
        guard active, expected == nil || expected == generation else { throw CancellationError() }
    }
    private func stageLocked(handle: CGUILocalStateHandle, state: CGUILocalState, editSequence: UInt64, explicitlyReset: Bool) throws {
        try ensureActive(handle.generation)
        guard handle.identity.scope == scope, var lease = leases[handle.id], lease.recordID == handle.identity.recordID,
              var entry = entries[lease.recordID], entry.identity == handle.identity else { throw CancellationError() }
        guard editSequence > lease.lastSequence else { return }
        try state.validate(for: entry.block)
        if entry.readIssue != nil, !explicitlyReset { throw CGUIValidationError("localState", "explicit_reset_required") }
        if explicitlyReset { entry.readIssue = nil }
        lease.lastSequence = editSequence
        entry.dirty = entry.dirty || entry.state != state || explicitlyReset
        entry.state = state; leases[handle.id] = lease; entries[lease.recordID] = entry
    }
    private func saveLocked(_ id: UUID) async throws {
        guard var entry = entries[id], entry.dirty else { return }
        let observedGeneration = generation
        let conversation = try await repository.record(entry.identity.block.conversationID, scope: scope)
        guard conversation.conversation != nil else { throw catError.missing }
        try ensureActive(observedGeneration)
        let payload = Payload.conversationUIState(CGUIStoredLocalState(identity: entry.identity, state: entry.state))
        let mutation: Mutation = entry.revision.map { .update(id, $0, payload) } ?? .create(id, payload)
        // Atomic CAS also fences conversation deletion while a stream or lifecycle transition is in flight.
        try await repository.commit(scope: scope, mutations: [.requireRevision(conversation.id, conversation.header.revision), mutation])
        // Cancellation after a durable commit cannot roll it back. Advance CAS before handling the next edit.
        guard active, generation == observedGeneration else { throw CancellationError() }
        entry.revision = (entry.revision ?? 0) + 1; entry.dirty = false; entries[id] = entry
    }
}
