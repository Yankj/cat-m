import Foundation

public actor OpenMuseTaskService {
    public nonisolated let provenance: OpenMuseProvenance
    private let repository: Repository
    private let transport: any OpenMuseTaskTransport
    public init(repository: Repository, transport: any OpenMuseTaskTransport) { self.repository = repository; self.transport = transport; provenance = transport.provenance }
    public func prepare(_ input: OpenMuseTaskInput) async throws -> OpenMuseTaskSession {
        let frozen = try OpenMuseFrozenRequest(input)
        let id = Self.recordID(input.operationID)
        if (await repository.read(scope: input.scope)).records[id] != nil {
            let old = try await session(operationID: input.operationID, scope: input.scope)
            guard old.request.requestHash == frozen.requestHash else { throw CatpawError.conflict }
            return old
        }
        let value = OpenMuseTaskSession(request: frozen, provenance: transport.provenance)
        try await repository.commit(scope: input.scope, mutations: [.create(id, try Self.payload(value))])
        return value
    }
    public func session(operationID: UUID, scope: DataScope) async throws -> OpenMuseTaskSession {
        try Self.decode(await repository.record(Self.recordID(operationID), scope: scope), operationID: operationID, scope: scope)
    }
    public func admit(operationID: UUID, scope: DataScope) async throws -> OpenMuseTaskSession {
        let (record, current) = try await load(operationID, scope)
        guard current.admission == .notSent, current.control == .active, current.provenance == transport.provenance else {
            throw CatpawError.invalid("Read the original admission; accepted/unknown requests cannot be created again.")
        }
        var dispatched = current; dispatched.admission = .dispatchCommitted; dispatched.needsRead = true
        // No transport invocation occurs before durable commit. An interrupted dispatch is never retried.
        try await save(dispatched, revision: record.header.revision)
        do {
            let binding = try await transport.create(dispatched.request)
            try binding.validate(dispatched.request)
            let (latestRecord, latest) = try await load(operationID, scope)
            guard Self.sameObservation(dispatched, latest) else { return latest }
            var accepted = latest; accepted.admission = .accepted; accepted.serverTaskID = binding.taskID
            try await save(accepted, revision: latestRecord.header.revision)
            return accepted
        } catch {
            let (latestRecord, latest) = try await load(operationID, scope)
            if Self.sameObservation(dispatched, latest) {
                var unknown = latest; unknown.admission = .unknown; unknown.needsRead = true
                unknown.note = "Creation result unknown; read the original operation without resending."
                try await save(unknown, revision: latestRecord.header.revision)
            }
            throw error
        }
    }
    public func refresh(operationID: UUID, scope: DataScope) async throws -> OpenMuseTaskSession {
        let (record, current) = try await load(operationID, scope)
        guard current.admission != .notSent, current.control == .active, current.provenance == transport.provenance else {
            throw CatpawError.invalid("No active admitted task is available for authoritative read.")
        }
        var observing = current; observing.readGeneration += 1; observing.needsRead = true
        try await save(observing, revision: record.header.revision)
        do {
            let projection = try await transport.readOriginal(observing.request, knownTaskID: observing.serverTaskID)
            let (latestRecord, latest) = try await load(operationID, scope)
            guard Self.sameObservation(observing, latest), observing.readGeneration == latest.readGeneration else { return latest }
            try projection.binding.validate(latest.request)
            if !projection.authorizationCurrent {
                var fenced = latest; fenced.control = .paused; fenced.observationEpoch += 1; fenced.needsRead = true
                Self.markDispatchesUnknown(&fenced); fenced.note = "The server Run authorization is superseded; old results are not published."
                try await save(fenced, revision: latestRecord.header.revision); return fenced
            }
            guard latest.serverTaskID == nil || latest.serverTaskID == projection.binding.taskID,
                  (!projection.hasAuthoritativeRevision || projection.revision > 0), projection.attempts >= 0,
                  projection.grantRevision == latest.grantRevision, projection.contextEpoch == latest.contextEpoch else { throw CatpawError.corrupt("Invalid original task projection or grant/epoch.") }
            let hash = try openMuseDigest(projection)
            if let old = latest.projection {
                guard projection.hasAuthoritativeRevision == old.hasAuthoritativeRevision,
                      (!projection.hasAuthoritativeRevision || projection.revision >= old.revision), projection.attempts >= old.attempts,
                      (!projection.hasAuthoritativeRevision || projection.revision != old.revision || latest.projectionHash == hash),
                      !projection.workerAttempts.isEmpty || latest.observedWorkerRunID == nil || projection.attempts == old.attempts,
                      projection.binding.serverRequestHash == old.binding.serverRequestHash,
                      projection.binding.remoteScope == old.binding.remoteScope,
                      !old.status.terminal || (projection.status == old.status && projection.attempts == old.attempts) else {
                    throw CatpawError.conflict
                }
            }
            if projection.workerAttempts.isEmpty, let observed = latest.observedWorkerRunID, let incoming = projection.workerRunID, observed != incoming { throw CatpawError.conflict }
            try Self.validateWorkerAttempts(projection, previous: latest.projection, request: latest.request)
            var next = latest; next.admission = .accepted; next.serverTaskID = projection.binding.taskID
            next.projection = projection; next.projectionHash = hash; next.needsRead = false; next.note = nil
            next.observedWorkerRunID = latest.observedWorkerRunID ?? projection.workerRunID
            try Self.mergeArtifactsAndApprovals(projection, into: &next)
            try await save(next, revision: latestRecord.header.revision)
            return next
        } catch {
            let (latestRecord, latest) = try await load(operationID, scope)
            if Self.sameObservation(observing, latest), observing.readGeneration == latest.readGeneration {
                var unknown = latest; unknown.needsRead = true
                unknown.note = "Original task read unresolved; retained last authority and did not resend creation."
                try await save(unknown, revision: latestRecord.header.revision)
            }
            throw error
        }
    }
    public func refreshUntilStable(operationID: UUID, scope: DataScope, maxReads: Int = 3) async throws -> OpenMuseTaskSession {
        guard (1...5).contains(maxReads) else { throw CatpawError.invalid("Authoritative read budget must be between one and five.") }
        for _ in 0..<maxReads {
            try Task.checkCancellation()
            do { return try await refresh(operationID: operationID, scope: scope) }
            catch is OpenMuseSnapshotReadChanged { } // only changing references retry; hash/scope/grant failures remain failures
        }
        // Every rejected read retained the last checked projection and needsRead=true. No busy task or write retry remains.
        throw OpenMuseReadBudgetExhausted(attemptedReads: maxReads)
    }
    public func recover(scope: DataScope) async throws {
        let records = (await repository.read(scope: scope)).list("preference", scope: scope)
        for r in records {
            guard case .preference(let p) = r.payload, p.key.hasPrefix("openmuse_session:"),
                  let operation = UUID(uuidString: String(p.key.dropFirst("openmuse_session:".count))) else { continue }
            let (record, value) = try await load(operation, scope)
            guard value.admission != .notSent else { continue }
            var recovered = value; recovered.observationEpoch += 1; recovered.needsRead = true
            if recovered.admission == .dispatchCommitted { recovered.admission = .unknown }
            Self.markDispatchesUnknown(&recovered)
            recovered.note = "App restarted; only read the original persistent task."
            try await save(recovered, revision: record.header.revision)
        }
    }
    public func control(operationID: UUID, scope: DataScope, command: OpenMuseControlCommand) async throws -> OpenMuseTaskSession {
        let (record, current) = try await load(operationID, scope)
        guard current.admission != .notSent, current.provenance == transport.provenance,
              current.control != .revoked,
              command != .pause || current.control == .active,
              command != .resume || (current.control == .paused && current.serverControlConfirmed && !current.resumeRequiresNewRun) else {
            throw CatpawError.invalid("Control is unavailable; a revoked grant cannot be resumed or silently regranted.")
        }
        var fenced = current; fenced.observationEpoch += 1; fenced.serverControlConfirmed = false; fenced.needsRead = true
        // A resume remains paused until its authority read/receipt confirms the same grant.
        if command == .pause { fenced.control = .paused }
        if command == .revoke { fenced.control = .revoked }
        if fenced.admission == .dispatchCommitted { fenced.admission = .unknown }
        Self.markDispatchesUnknown(&fenced)
        try await save(fenced, revision: record.header.revision)
        do {
            let receipt = try await transport.control(fenced.request, knownTaskID: fenced.serverTaskID, command: command,
                                                      expectedRevision: fenced.delegationRevision, expectedGrantEpoch: fenced.grantRevision)
            try receipt.binding.validate(fenced.request)
            let (latestRecord, latest) = try await load(operationID, scope)
            guard latest.observationEpoch == fenced.observationEpoch else { return latest }
            let expected: OpenMuseLocalControl = command == .pause ? .paused : command == .resume ? .active : .revoked
            guard receipt.control == expected, latest.serverTaskID == nil || latest.serverTaskID == receipt.binding.taskID,
                  receipt.contextEpoch >= latest.contextEpoch,
                  receipt.grantRevision > latest.grantRevision, receipt.delegationRevision > latest.delegationRevision else {
                throw CatpawError.corrupt("Control receipt changed the scope, grant or requested control.")
            }
            var confirmed = latest; confirmed.control = expected; confirmed.serverControlConfirmed = true
            confirmed.contextEpoch = receipt.contextEpoch; confirmed.grantRevision = receipt.grantRevision
            confirmed.delegationRevision = receipt.delegationRevision; confirmed.resumeRequiresNewRun = receipt.requiresNewRun
            if receipt.requiresNewRun { confirmed.control = .paused }
            for id in Array(confirmed.approvals.keys) where confirmed.approvals[id]?.state == .pending { confirmed.approvals[id]?.state = .invalidated }
            confirmed.serverTaskID = receipt.binding.taskID
            confirmed.note = receipt.requiresNewRun ? "Delegation resumed; its old Run stays fenced. Explicit new Run admission is required." : nil
            try await save(confirmed, revision: latestRecord.header.revision)
            return confirmed
        } catch {
            let (latestRecord, latest) = try await load(operationID, scope)
            if latest.observationEpoch == fenced.observationEpoch {
                var unresolved = latest; unresolved.note = "Local observation fenced; server control/revocation is unconfirmed."
                try await save(unresolved, revision: latestRecord.header.revision)
            }
            throw error
        }
    }
    public func stopObserving(operationID: UUID, scope: DataScope) async throws {
        let (record, current) = try await load(operationID, scope)
        var stopped = current; stopped.observationEpoch += 1; stopped.needsRead = true
        if stopped.admission == .dispatchCommitted { stopped.admission = .unknown }
        Self.markDispatchesUnknown(&stopped)
        stopped.note = "Observation disconnected; original server task is retained, not cancelled."
        try await save(stopped, revision: record.header.revision)
    }
    public func prepareFreshRunAfterResume(operationID: UUID, scope: DataScope) async throws -> OpenMuseTaskSession {
        let (record, current) = try await load(operationID, scope)
        guard current.control == .paused, current.resumeRequiresNewRun, current.serverControlConfirmed else {
            throw CatpawError.invalid("A revoked/unconfirmed grant cannot prepare a resumed Run.")
        }
        var parent = current
        let nextOperation = current.nextRunOperationID ?? UUID()
        if current.nextRunOperationID == nil {
            parent.nextRunOperationID = nextOperation; try await save(parent, revision: record.header.revision)
        }
        let original = parent.request.input
        let input = OpenMuseTaskInput(scope: scope, operationID: nextOperation, businessRunID: stableID("openmuse-resume-run-\(nextOperation)"),
            delegationID: original.delegationID, delegationRevision: parent.delegationRevision, environmentID: original.environmentID,
            grantID: original.grantID, grantRevision: parent.grantRevision, contextEpoch: parent.contextEpoch,
            title: original.title, goal: original.goal, requirements: original.requirements, stopConditions: original.stopConditions,
            syntheticDataOnly: true, syntheticFixture: original.syntheticFixture)
        // Preparing a durable draft is not a create call and does not reactivate the old Run.
        return try await prepare(input)
    }
    public func preview(operationID: UUID, scope: DataScope, proposalID: String, now: Date = Date()) async throws -> OpenMuseApprovalPreview {
        let current = try await session(operationID: operationID, scope: scope)
        guard current.control == .active, !current.needsRead,
              let approval = current.approvals[proposalID], approval.state == .pending else { throw CatpawError.invalid("Read the current pending proposal before previewing.") }
        try Self.validateApproval(approval.snapshot, in: current, now: now)
        guard let artifact = current.artifactHistory.first(where: { $0.reference == approval.snapshot.artifact }) else { throw CatpawError.missing }
        try artifact.validate(taskID: approval.snapshot.binding.taskID)
        return try OpenMuseApprovalPreview(snapshot: approval.snapshot, artifact: artifact, observationEpoch: current.observationEpoch)
    }
    public func decide(_ preview: OpenMuseApprovalPreview, decision: OpenMuseDecision, now: Date = Date()) async throws -> OpenMuseTaskSession {
        let operation = preview.snapshot.binding.operationID, scope = preview.snapshot.binding.scope
        let current = try await session(operationID: operation, scope: scope)
        try Self.validatePreview(preview, in: current, now: now)
        guard current.provenance == transport.provenance else { throw CatpawError.scopeMismatch }
        // Minimal original proposal GET; never the broad upstream workspace read.
        let authoritative = try await transport.readApproval(current.request, taskID: preview.snapshot.binding.taskID, proposalID: preview.snapshot.proposalID)
        guard try openMuseDigest(authoritative) == preview.snapshotDigest else { throw CatpawError.conflict }
        let (record, latest) = try await load(operation, scope)
        try Self.validatePreview(preview, in: latest, now: now)
        var dispatched = latest
        dispatched.approvals[preview.snapshot.proposalID]?.state = .dispatchCommitted
        dispatched.approvals[preview.snapshot.proposalID]?.decision = decision
        try await save(dispatched, revision: record.header.revision)
        let afterCommit = try await session(operationID: operation, scope: scope)
        guard Self.sameObservation(dispatched, afterCommit) else { return afterCommit }
        do {
            let receipt = try await transport.decide(preview, decision: decision)
            try Self.validateReceipt(receipt, for: preview.snapshot, request: dispatched.request)
            let (latestRecord, currentAfterTransport) = try await load(operation, scope)
            guard Self.sameObservation(dispatched, currentAfterTransport) else { return currentAfterTransport }
            var next = currentAfterTransport
            next.approvals[receipt.proposalID]?.state = receipt.status
            next.approvals[receipt.proposalID]?.receipt = receipt; next.needsRead = true
            try await save(next, revision: latestRecord.header.revision)
            return next
        } catch {
            let (latestRecord, currentAfterTransport) = try await load(operation, scope)
            if Self.sameObservation(dispatched, currentAfterTransport) {
                var unknown = currentAfterTransport
                unknown.approvals[preview.snapshot.proposalID]?.state = .unknown; unknown.needsRead = true
                unknown.note = "Decision response unknown; consumed original proposal is retained for receipt GET."
                try await save(unknown, revision: latestRecord.header.revision)
            }
            throw error
        }
    }
    public func reconcileReceipt(operationID: UUID, scope: DataScope, proposalID: String, performEvidenceCheck: Bool = false) async throws -> OpenMuseTaskSession {
        let current = try await session(operationID: operationID, scope: scope)
        guard current.provenance == transport.provenance, let approval = current.approvals[proposalID],
              [.dispatchCommitted, .unknown, .accepted].contains(approval.state) else { throw CatpawError.invalid("Only the consumed original receipt can be reconciled.") }
        let receipt: OpenMuseDecisionReceipt
        if performEvidenceCheck { receipt = try await transport.checkReceiptEvidence(current.request, approval: approval.snapshot) }
        else { receipt = try await transport.readReceipt(current.request, approval: approval.snapshot) }
        try Self.validateReceipt(receipt, for: approval.snapshot, request: current.request)
        let (record, latest) = try await load(operationID, scope)
        guard let original = latest.approvals[proposalID], try openMuseDigest(original.snapshot) == openMuseDigest(approval.snapshot) else { throw CatpawError.conflict }
        var reconciled = latest; reconciled.approvals[proposalID]?.state = receipt.status
        reconciled.approvals[proposalID]?.receipt = receipt
        reconciled.note = "Server receipt assertion read; no independent side-effect verification."
        try await save(reconciled, revision: record.header.revision)
        return reconciled
    }
    public func bindEphemeral(operationID: UUID, scope: DataScope, threadID: String, aguiRunID: String) async throws -> OpenMuseTaskSession {
        let (record, current) = try await load(operationID, scope)
        guard current.control == .active, current.admission == .accepted, !threadID.isEmpty, !aguiRunID.isEmpty,
              ![operationID.uuidString.lowercased(), current.request.input.businessRunID.uuidString.lowercased(), current.serverTaskID?.lowercased() ?? ""].contains(aguiRunID.lowercased()) else {
            throw CatpawError.invalid("AG-UI run must have its own identity and cannot authorize a persistent task.")
        }
        var next = current; next.ephemeral = OpenMuseEphemeralObservation(threadID: threadID, aguiRunID: aguiRunID)
        try await save(next, revision: record.header.revision); return next
    }
    public func applyEphemeral(_ event: OpenMuseEphemeralEvent, operationID: UUID, scope: DataScope, observationEpoch: Int) async throws -> OpenMuseTaskSession {
        let (record, current) = try await load(operationID, scope)
        guard current.control == .active, current.observationEpoch == observationEpoch,
              var stream = current.ephemeral, !stream.terminal,
              event.aguiRunID == nil || event.aguiRunID == stream.aguiRunID,
              event.threadID == nil || event.threadID == stream.threadID else { throw CatpawError.conflict }
        var next = current
        switch event.type {
        case "TEXT_MESSAGE_CHUNK", "TEXT_MESSAGE_CONTENT":
            guard let delta = event.delta, stream.advisoryText.utf8.count + delta.utf8.count <= 1024 * 1024 else { throw CatpawError.corrupt("Invalid ephemeral text delta.") }
            stream.advisoryText += delta
        case "RUN_FINISHED", "RUN_ERROR":
            stream.terminal = true; next.needsRead = true
        default:
            if event.type.hasPrefix("TOOL_CALL_") { stream.sawToolProposal = true }
            else if !stream.unsupportedEventTypes.contains(event.type), stream.unsupportedEventTypes.count < 32 { stream.unsupportedEventTypes.append(event.type) }
            next.needsRead = true
        }
        // Advisory stream text never becomes an Artifact, decision or persistent Task terminal.
        next.ephemeral = stream
        try await save(next, revision: record.header.revision); return next
    }
    private static func validatePreview(_ preview: OpenMuseApprovalPreview, in session: OpenMuseTaskSession, now: Date) throws {
        try validateApproval(preview.snapshot, in: session, now: now)
        guard !session.needsRead, session.observationEpoch == preview.observationEpoch,
              let journal = session.approvals[preview.snapshot.proposalID], journal.state == .pending,
              preview.snapshotDigest == (try openMuseDigest(preview.snapshot)), preview.snapshotDigest == (try openMuseDigest(journal.snapshot)),
              preview.artifact.reference == preview.snapshot.artifact,
              session.artifactHistory.contains(preview.artifact) else { throw CatpawError.invalid("The displayed approval changed or has already been consumed.") }
        try preview.artifact.validate(taskID: preview.snapshot.binding.taskID)
        let unresolvedSamePurpose = session.approvals.values.contains {
            $0.snapshot.proposalID != preview.snapshot.proposalID && [.dispatchCommitted, .unknown, .accepted].contains($0.state) &&
            $0.snapshot.artifact.artifactID == preview.snapshot.artifact.artifactID && $0.snapshot.destination == preview.snapshot.destination && $0.snapshot.toolID == preview.snapshot.toolID
        }
        guard !unresolvedSamePurpose else { throw CatpawError.invalid("Reconcile the original action for this destination before a new decision.") }
    }
    private static func validateReceipt(_ receipt: OpenMuseDecisionReceipt, for snapshot: OpenMuseApprovalSnapshot, request: OpenMuseFrozenRequest) throws {
        try receipt.binding.validate(request)
        guard receipt.binding.taskID == snapshot.binding.taskID, receipt.proposalID == snapshot.proposalID,
              receipt.serverActionDigest == snapshot.serverActionDigest, [.accepted, .unknown, .denied].contains(receipt.status) else {
            throw CatpawError.corrupt("Original receipt binding is invalid; HTTP success is not verification.")
        }
    }
    private static func markDispatchesUnknown(_ session: inout OpenMuseTaskSession) {
        for id in Array(session.approvals.keys) where session.approvals[id]?.state == .dispatchCommitted { session.approvals[id]?.state = .unknown }
    }
    private static func mergeArtifactsAndApprovals(_ projection: OpenMuseTaskProjection, into session: inout OpenMuseTaskSession) throws {
        guard projection.artifacts.count <= 128, projection.approvals.count <= 32,
              projection.artifacts.reduce(0, { $0 + $1.body.utf8.count }) <= 4 * 1024 * 1024 else {
            throw CatpawError.corrupt("Projection exceeds the declared client read budget.")
        }
        var versionKeys = Set<String>()
        for artifact in projection.artifacts {
            try artifact.validate(taskID: projection.binding.taskID)
            let key = "\(artifact.reference.artifactID):\(artifact.reference.version)"
            guard versionKeys.insert(key).inserted else { throw CatpawError.corrupt("Duplicate artifact version.") }
            if let existing = session.artifactHistory.first(where: { $0.reference.artifactID == artifact.reference.artifactID && $0.reference.version == artifact.reference.version }) {
                guard existing == artifact else { throw CatpawError.corrupt("Server changed an immutable artifact version.") }
            } else { session.artifactHistory.append(artifact) }
        }
        var proposalIDs = Set<String>()
        for snapshot in projection.approvals {
            try snapshot.binding.validate(session.request)
            guard proposalIDs.insert(snapshot.proposalID).inserted, snapshot.binding.taskID == projection.binding.taskID,
                  !snapshot.proposalID.isEmpty, !snapshot.serverHash.isEmpty, !snapshot.serverActionDigest.isEmpty,
                  Self.allowedSyntheticEffect(snapshot),
                  snapshot.argumentsHash == textHash(snapshot.argumentsJSON),
                  snapshot.grantID == session.request.input.grantID, snapshot.grantRevision == session.grantRevision,
                  snapshot.contextEpoch == session.contextEpoch,
                  session.artifactHistory.contains(where: { $0.reference == snapshot.artifact }),
                  (try JSONSerialization.jsonObject(with: Data(snapshot.argumentsJSON.utf8))) is [String: Any] else {
                throw CatpawError.corrupt("Invalid version-bound synthetic proposal.")
            }
            if let wire = snapshot.wireActionBindingJSON { guard textHash(wire) == snapshot.serverActionDigest else { throw CatpawError.corrupt("Facade action digest mismatch.") } }
            if let existing = session.approvals[snapshot.proposalID] {
                guard try openMuseDigest(existing.snapshot) == openMuseDigest(snapshot) else { throw CatpawError.conflict }
            } else { session.approvals[snapshot.proposalID] = OpenMuseApprovalJournal(snapshot: snapshot) }
        }
        for receipt in projection.approvalReceipts {
            guard let approval = session.approvals[receipt.proposalID] else { throw CatpawError.corrupt("Receipt lacks its original approval.") }
            try validateReceipt(receipt, for: approval.snapshot, request: session.request)
            session.approvals[receipt.proposalID]?.state = receipt.status; session.approvals[receipt.proposalID]?.receipt = receipt
        }
        for id in session.approvals.keys {
            guard var approval = session.approvals[id], approval.state == .pending else { continue }
            let latest = session.artifactHistory.filter { $0.reference.artifactID == approval.snapshot.artifact.artifactID }.max { $0.reference.version < $1.reference.version }
            if latest?.reference != approval.snapshot.artifact || approval.snapshot.expiresAt <= Date() { approval.state = .invalidated; session.approvals[id] = approval }
        }
    }
    private static func validateApproval(_ approval: OpenMuseApprovalSnapshot, in session: OpenMuseTaskSession, now: Date) throws {
        try approval.binding.validate(session.request)
        let latest = session.artifactHistory.filter { $0.reference.artifactID == approval.artifact.artifactID }.max { $0.reference.version < $1.reference.version }
        guard session.control == .active, session.admission == .accepted, approval.binding.taskID == session.serverTaskID,
              approval.grantID == session.request.input.grantID, approval.grantRevision == session.grantRevision,
              approval.contextEpoch == session.contextEpoch, now < approval.expiresAt,
              latest?.reference == approval.artifact, approval.argumentsHash == textHash(approval.argumentsJSON),
              Self.allowedSyntheticEffect(approval) else { throw CatpawError.invalid("Preview is expired, changed, paused or revoked.") }
    }
    private static func allowedSyntheticEffect(_ snapshot: OpenMuseApprovalSnapshot) -> Bool {
        snapshot.policyVersion == "synthetic-only-v1" && ((snapshot.effectClass == "synthetic_noop" && snapshot.toolID == "synthetic.noop") ||
        (snapshot.effectClass == "synthetic_preview" && snapshot.toolID == "catpaw.preview"))
    }
    private static func validateWorkerAttempts(_ projection: OpenMuseTaskProjection, previous: OpenMuseTaskProjection?, request: OpenMuseFrozenRequest) throws {
        guard projection.workerAttempts.count <= 128, Set(projection.workerAttempts.map(\.upstreamRunID)).count == projection.workerAttempts.count else { throw CatpawError.corrupt("Duplicate worker attempts.") }
        for attempt in projection.workerAttempts {
            guard !attempt.upstreamRunID.isEmpty, ![request.input.operationID.uuidString.lowercased(), request.input.businessRunID.uuidString.lowercased(), projection.binding.taskID.lowercased()].contains(attempt.upstreamRunID.lowercased()) else { throw CatpawError.corrupt("Worker attempt conflates a stable business identity.") }
        }
        for old in previous?.workerAttempts ?? [] {
            guard let current = projection.workerAttempts.first(where: { $0.upstreamRunID == old.upstreamRunID }), current.startedAt == old.startedAt,
                  old.finishedAt == nil || current == old else { throw CatpawError.conflict }
        }
    }
    public func sessions(scope: DataScope) async throws -> [OpenMuseTaskSession] {
        let records = (await repository.read(scope: scope)).list("preference", scope: scope)
        return try records.compactMap { record in
            guard case .preference(let p) = record.payload, p.key.hasPrefix("openmuse_session:"),
                  let operation = UUID(uuidString: String(p.key.dropFirst("openmuse_session:".count))) else { return nil }
            return try Self.decode(record, operationID: operation, scope: scope)
        }
    }
    private func load(_ operation: UUID, _ scope: DataScope) async throws -> (StoredRecord, OpenMuseTaskSession) {
        let record = try await repository.record(Self.recordID(operation), scope: scope)
        return (record, try Self.decode(record, operationID: operation, scope: scope))
    }
    private func save(_ value: OpenMuseTaskSession, revision: Int) async throws {
        try await repository.commit(scope: value.request.input.scope, mutations: [.update(Self.recordID(value.request.input.operationID), revision, try Self.payload(value))])
    }
    private static func sameObservation(_ a: OpenMuseTaskSession, _ b: OpenMuseTaskSession) -> Bool {
        a.request.requestHash == b.request.requestHash && a.observationEpoch == b.observationEpoch && b.control == .active
    }
    private static func recordID(_ operationID: UUID) -> UUID { stableID("openmuse-session-\(operationID)") }
    private static func payload(_ value: OpenMuseTaskSession) throws -> Payload {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .preference(Preference(key: "openmuse_session:\(value.request.input.operationID)", value: String(decoding: try encoder.encode(value), as: UTF8.self)))
    }
    private static func decode(_ record: StoredRecord, operationID: UUID, scope: DataScope) throws -> OpenMuseTaskSession {
        guard case .preference(let p) = record.payload, p.key == "openmuse_session:\(operationID)" else { throw CatpawError.corrupt("Invalid OpenMuse durable session.") }
        let value = try JSONDecoder().decode(OpenMuseTaskSession.self, from: Data(p.value.utf8))
        try value.request.validate()
        guard value.request.input.operationID == operationID, value.request.input.scope == scope else { throw CatpawError.scopeMismatch }
        return value
    }
}
