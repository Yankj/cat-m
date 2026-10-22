import Foundation

actor RestartFixtureTransport: OpenMuseTaskTransport {
    nonisolated let provenance: OpenMuseProvenance = .fixtureTransport
    private var tasks: [String: OpenMuseTaskProjection] = [:]
    private var publicCreateRequests = 0
    private var holdRead = false
    private var pendingRead: CheckedContinuation<OpenMuseTaskProjection, Never>?
    private var pendingReady: CheckedContinuation<Void, Never>?
    private var bufferedProjection: OpenMuseTaskProjection?
    private var decisions: [String: OpenMuseDecisionReceipt] = [:]
    private var publicDecisionRequests = 0
    private var omitNextAdmission = false
    func loseNextAdmissionBeforeTaskExists() { omitNextAdmission = true }
    func create(_ request: OpenMuseFrozenRequest) async throws -> OpenMuseTaskBinding {
        publicCreateRequests += 1
        if omitNextAdmission { omitNextAdmission = false; throw catError.unavailable("Synthetic admission lost before task creation; original GET returns missing.") }
        let binding = OpenMuseTaskBinding(request: request, taskID: "synthetic-task-\(request.input.operationID)")
        var projection = OpenMuseTaskProjection(binding: binding, revision: 1, status: .running, workerRunID: "synthetic-worker-run")
        projection.grantRevision = request.input.grantRevision; projection.contextEpoch = request.input.contextEpoch
        tasks[request.requestHash] = projection
        return binding
    }
    func readOriginal(_ request: OpenMuseFrozenRequest, knownTaskID: String?) async throws -> OpenMuseTaskProjection {
        guard let value = tasks[request.requestHash], knownTaskID == nil || value.binding.taskID == knownTaskID else { throw catError.missing }
        if holdRead {
            holdRead = false; bufferedProjection = value
            return await withCheckedContinuation { continuation in
                pendingRead = continuation; pendingReady?.resume(); pendingReady = nil
            }
        }
        return value
    }
    func control(_ request: OpenMuseFrozenRequest, knownTaskID: String?, command: OpenMuseControlCommand, expectedRevision: Int, expectedGrantEpoch: Int) async throws -> OpenMuseControlReceipt {
        guard var value = tasks[request.requestHash] else { throw catError.missing }
        value.revision += 1; value.status = command == .pause ? .paused : command == .resume ? .running : .cancelled
        tasks[request.requestHash] = value
        return OpenMuseControlReceipt(binding: value.binding, control: command == .pause ? .paused : command == .resume ? .active : .revoked,
                                      grantRevision: expectedGrantEpoch + 1, contextEpoch: expectedGrantEpoch + 1, delegationRevision: expectedRevision + 1, requiresNewRun: command == .resume)
    }
    func holdNextRead() { holdRead = true }
    func waitForHeldRead() async {
        if pendingRead != nil { return }
        await withCheckedContinuation { pendingReady = $0 }
    }
    func releaseLateSuccess() {
        var value = bufferedProjection!; value.revision += 1; value.status = .succeeded
        pendingRead?.resume(returning: value); pendingRead = nil; bufferedProjection = nil
    }
    func publishApproval(_ request: OpenMuseFrozenRequest) throws {
        var value = tasks[request.requestHash]!
        let body = "synthetic-native-report-v1"
        let reference = OpenMuseArtifactReference(artifactID: "synthetic-report", version: 1, contentHash: "8fb2aec4bb96ff63addc87dce249b56b52c823791e2251f32de020f029f7b712")
        value.artifacts = [OpenMuseArtifactVersion(taskID: value.binding.taskID, reference: reference, title: "合成摘要", body: body)]
        value.approvals = [OpenMuseApprovalSnapshot(proposalID: "synthetic-proposal-v1", binding: value.binding, artifact: reference,
                           destination: "preview@example.invalid", grantID: request.input.grantID, grantRevision: 1, contextEpoch: 1,
                           serverHash: "synthetic-upstream-hash", serverActionDigest: "synthetic-facade-action-digest", expiresAt: Date().addingTimeInterval(3600))]
        value.revision += 1; value.status = .waitingApproval; tasks[request.requestHash] = value
    }
    func publishInvalidBody(_ request: OpenMuseFrozenRequest) {
        var value = tasks[request.requestHash]!
        let old = value.artifacts[0]
        value.artifacts = [OpenMuseArtifactVersion(taskID: old.taskID, reference: old.reference, title: old.title, body: "tampered bytes")]
        value.revision += 1; tasks[request.requestHash] = value
    }
    func publishV2(_ request: OpenMuseFrozenRequest) {
        var value = tasks[request.requestHash]!
        value.artifacts.append(OpenMuseArtifactVersion(taskID: value.binding.taskID,
            reference: OpenMuseArtifactReference(artifactID: "synthetic-report", version: 2, contentHash: "27f16dcc6ba6fdeda00b5b35a8c82bb1e59737c41693b8f06d3ab059d9bccb2d"),
            title: "合成摘要 v2", body: "synthetic-native-report-v2"))
        value.revision += 1; tasks[request.requestHash] = value
    }
    func createRequestCount() -> Int { publicCreateRequests }
    func decisionRequestCount() -> Int { publicDecisionRequests }
    func readApproval(_ request: OpenMuseFrozenRequest, taskID: String, proposalID: String) async throws -> OpenMuseApprovalSnapshot {
        guard let value = tasks[request.requestHash], value.binding.taskID == taskID,
              let approval = value.approvals.first(where: { $0.proposalID == proposalID }) else { throw catError.missing }
        return approval
    }
    func decide(_ preview: OpenMuseApprovalPreview, decision: OpenMuseDecision) async throws -> OpenMuseDecisionReceipt {
        publicDecisionRequests += 1
        decisions[preview.snapshot.proposalID] = OpenMuseDecisionReceipt(binding: preview.snapshot.binding, proposalID: preview.snapshot.proposalID,
            serverActionDigest: preview.snapshot.serverActionDigest, status: .accepted, providerStatus: "succeeded")
        throw catError.unavailable("synthetic response lost after a synthetic-only decision")
    }
    func readReceipt(_ request: OpenMuseFrozenRequest, approval: OpenMuseApprovalSnapshot) async throws -> OpenMuseDecisionReceipt {
        guard let receipt = decisions[approval.proposalID] else { throw catError.missing }
        return receipt
    }
}
func omCheck(_ value: Bool, _ description: String) throws {
    guard value else { throw catError.invalid("FAIL: " + description) }
    print("PASS: " + description)
}
@main struct OpenMuseTaskRunner {
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/openmuse-tests/fixture-disk")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("draft-restart.json")
            let repo = try Repository(persistence: FilePersistence(url: file))
            let transport = UnconfiguredOpenMuseTransport()
            let service = OpenMuseTaskService(repository: repo, transport: transport)
            let input = OpenMuseTaskInput(scope: Profiles.demo, environmentID: UUID(), title: "合成摘要", goal: "只处理example.invalid合成资料")
            let prepared = try await service.prepare(input)
            let restarted = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: file)), transport: transport)
            let restored = try await restarted.session(operationID: input.operationID, scope: input.scope)
            try omCheck(restored.request.requestHash == prepared.request.requestHash && restored.request.input.goal == input.goal && restored.admission == .notSent,
                        "a frozen draft is durable before admission and survives a new service/repository")
            let acceptedTransport = RestartFixtureTransport()
            let acceptedFile = root.appendingPathComponent("accepted-restart.json")
            let beforeQuit = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: acceptedFile)), transport: acceptedTransport)
            _ = try await beforeQuit.prepare(input)
            let admitted = try await beforeQuit.admit(operationID: input.operationID, scope: input.scope)
            let afterQuit = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: acceptedFile)), transport: acceptedTransport)
            try await afterQuit.recover(scope: input.scope)
            let resumed = try await afterQuit.refresh(operationID: input.operationID, scope: input.scope)
            let createRequests = await acceptedTransport.createRequestCount()
            try omCheck(resumed.serverTaskID == admitted.serverTaskID && resumed.projection?.status == .running && resumed.request.input.businessRunID == input.businessRunID && createRequests == 1,
                        "accepted task restart reads server authority without creating another task")
            await acceptedTransport.holdNextRead()
            let lateRead = Task { try await afterQuit.refresh(operationID: input.operationID, scope: input.scope) }
            await acceptedTransport.waitForHeldRead()
            let paused = try await afterQuit.control(operationID: input.operationID, scope: input.scope, command: .pause)
            await acceptedTransport.releaseLateSuccess()
            let afterLateRead = try await lateRead.value
            try omCheck(paused.control == .paused && afterLateRead.control == .paused && afterLateRead.projection?.status == .running && afterLateRead.serverControlConfirmed,
                        "a success read buffered before pause cannot publish after the control fence")
            let approvalTransport = RestartFixtureTransport()
            let approvals = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("approval-preview.json"))), transport: approvalTransport)
            let preparedApproval = try await approvals.prepare(input)
            _ = try await approvals.admit(operationID: input.operationID, scope: input.scope)
            try await approvalTransport.publishApproval(preparedApproval.request)
            _ = try await approvals.refresh(operationID: input.operationID, scope: input.scope)
            let preview = try await approvals.preview(operationID: input.operationID, scope: input.scope, proposalID: "synthetic-proposal-v1")
            try omCheck(preview.artifact.body == "synthetic-native-report-v1" && preview.artifact.reference.version == 1 && preview.snapshot.destination == "preview@example.invalid" && preview.artifact.reference == preview.snapshot.artifact,
                        "approval preview reads the same immutable server version/body/hash and destination")
            do { _ = try await approvals.decide(preview, decision: .approve) } catch { /* Expected: lost fixture transport response. */ }
            let unknownDecision = try await approvals.session(operationID: input.operationID, scope: input.scope)
            try omCheck(unknownDecision.approvals["synthetic-proposal-v1"]?.state == .unknown,
                        "lost decision response retains a consumed original approval as unknown")
            let restartedApprovals = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("approval-preview.json"))), transport: approvalTransport)
            try await restartedApprovals.recover(scope: input.scope)
            let receipt = try await restartedApprovals.reconcileReceipt(operationID: input.operationID, scope: input.scope, proposalID: "synthetic-proposal-v1")
            do { _ = try await restartedApprovals.decide(preview, decision: .approve) } catch { }
            let decisionRequests = await approvalTransport.decisionRequestCount()
            try omCheck(receipt.approvals["synthetic-proposal-v1"]?.state == .accepted && receipt.approvals["synthetic-proposal-v1"]?.receipt?.providerStatus == "succeeded" && decisionRequests == 1,
                        "restart reconciles original receipt without repeating a decision or claiming independent verification")
            let ephemeralTransport = RestartFixtureTransport()
            let ephemeralService = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("ephemeral.json"))), transport: ephemeralTransport)
            _ = try await ephemeralService.prepare(input); _ = try await ephemeralService.admit(operationID: input.operationID, scope: input.scope)
            _ = try await ephemeralService.refresh(operationID: input.operationID, scope: input.scope)
            let stream = try await ephemeralService.bindEphemeral(operationID: input.operationID, scope: input.scope, threadID: "synthetic-thread", aguiRunID: "synthetic-agui-run")
            _ = try await ephemeralService.applyEphemeral(OpenMuseEphemeralEvent(type: "TOOL_CALL_START", aguiRunID: "synthetic-agui-run"), operationID: input.operationID, scope: input.scope, observationEpoch: stream.observationEpoch)
            let finishedTurn = try await ephemeralService.applyEphemeral(OpenMuseEphemeralEvent(type: "RUN_FINISHED", aguiRunID: "synthetic-agui-run"), operationID: input.operationID, scope: input.scope, observationEpoch: stream.observationEpoch)
            let toolDecisions = await ephemeralTransport.decisionRequestCount()
            try omCheck(finishedTurn.projection?.status == .running && finishedTurn.ephemeral?.terminal == true && finishedTurn.ephemeral?.sawToolProposal == true && finishedTurn.needsRead && finishedTurn.artifactHistory.isEmpty && toolDecisions == 0,
                        "AG-UI turn completion and tool proposals require task reads, never task completion or tool execution")
            let resumedDelegation = try await afterQuit.control(operationID: input.operationID, scope: input.scope, command: .resume)
            let fresh = try await afterQuit.prepareFreshRunAfterResume(operationID: input.operationID, scope: input.scope)
            let createBeforeExplicitRun = await acceptedTransport.createRequestCount()
            try omCheck(resumedDelegation.control == .paused && resumedDelegation.resumeRequiresNewRun && fresh.request.input.operationID != input.operationID && fresh.request.input.businessRunID != input.businessRunID && fresh.request.input.delegationID == input.delegationID && fresh.request.input.grantRevision == 3 && fresh.admission == .notSent && createBeforeExplicitRun == 1,
                        "resume never reactivates old Run; fresh scope-bound identities are only prepared until explicit admission")
            let failingParent = root.appendingPathComponent("save-failure", isDirectory: true)
            let saveRepo = try Repository(persistence: FilePersistence(url: failingParent.appendingPathComponent("state.json")))
            let savePeer = RestartFixtureTransport(), saveService = OpenMuseTaskService(repository: saveRepo, transport: savePeer)
            _ = try await saveService.prepare(input)
            let beforeSave = await saveRepo.read(scope: input.scope)
            try FileManager.default.moveItem(at: failingParent, to: root.appendingPathComponent("preserved-before-failure"))
            try Data("blocks directory creation".utf8).write(to: failingParent)
            var saveRejected = false
            do { _ = try await saveService.admit(operationID: input.operationID, scope: input.scope) } catch { saveRejected = true }
            let afterSave = await saveRepo.read(scope: input.scope), saveRequests = await savePeer.createRequestCount()
            let savedDraft = try await saveService.session(operationID: input.operationID, scope: input.scope)
            try omCheck(saveRejected && beforeSave.sequence == afterSave.sequence && savedDraft.admission == .notSent && saveRequests == 0,
                        "actual disk save failure rolls back dispatch and sequence before any transport call")
            let missingPeer = RestartFixtureTransport()
            let missingService = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("missing-original.json"))), transport: missingPeer)
            _ = try await missingService.prepare(input); await missingPeer.loseNextAdmissionBeforeTaskExists()
            do { _ = try await missingService.admit(operationID: input.operationID, scope: input.scope) } catch { }
            do { _ = try await missingService.refresh(operationID: input.operationID, scope: input.scope) } catch { }
            do { _ = try await missingService.admit(operationID: input.operationID, scope: input.scope) } catch { }
            let missingSession = try await missingService.session(operationID: input.operationID, scope: input.scope), missingCreates = await missingPeer.createRequestCount()
            try omCheck(missingSession.admission == .unknown && missingSession.needsRead && missingCreates == 1,
                        "unknown admission plus original missing result never authorizes another create")
            let versionPeer = RestartFixtureTransport()
            let versionService = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("versions.json"))), transport: versionPeer)
            let versionDraft = try await versionService.prepare(input); _ = try await versionService.admit(operationID: input.operationID, scope: input.scope)
            try await versionPeer.publishApproval(versionDraft.request); _ = try await versionService.refresh(operationID: input.operationID, scope: input.scope)
            let originalPreview = try await versionService.preview(operationID: input.operationID, scope: input.scope, proposalID: "synthetic-proposal-v1")
            await versionPeer.publishV2(versionDraft.request)
            let newVersion = try await versionService.refresh(operationID: input.operationID, scope: input.scope)
            do { _ = try await versionService.decide(originalPreview, decision: .approve) } catch { }
            let versionDecisions = await versionPeer.decisionRequestCount()
            try omCheck(newVersion.artifactHistory.count == 2 && newVersion.approvals["synthetic-proposal-v1"]?.state == .invalidated && versionDecisions == 0,
                        "new artifact version preserves v1 and invalidates the old approval without dispatch")
            await versionPeer.publishInvalidBody(versionDraft.request)
            var corruptRejected = false
            do { _ = try await versionService.refresh(operationID: input.operationID, scope: input.scope) } catch { corruptRejected = true }
            let retainedVersion = try await versionService.session(operationID: input.operationID, scope: input.scope)
            try omCheck(corruptRejected && retainedVersion.artifactHistory.count == 2 && retainedVersion.artifactHistory[0].body == "synthetic-native-report-v1" && retainedVersion.needsRead,
                        "corrupt server body is rejected atomically while previously checked artifact versions survive")
            let revokePeer = RestartFixtureTransport()
            let revokeService = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: root.appendingPathComponent("revocation.json"))), transport: revokePeer)
            _ = try await revokeService.prepare(input); _ = try await revokeService.admit(operationID: input.operationID, scope: input.scope)
            _ = try await revokeService.refresh(operationID: input.operationID, scope: input.scope)
            await revokePeer.holdNextRead()
            let lateRevokedRead = Task { try await revokeService.refresh(operationID: input.operationID, scope: input.scope) }
            await revokePeer.waitForHeldRead(); _ = try await revokeService.control(operationID: input.operationID, scope: input.scope, command: .revoke)
            await revokePeer.releaseLateSuccess(); let revoked = try await lateRevokedRead.value
            var resumeRejected = false, wrongScopeRejected = false
            do { _ = try await revokeService.control(operationID: input.operationID, scope: input.scope, command: .resume) } catch { resumeRejected = true }
            do { _ = try await revokeService.session(operationID: input.operationID, scope: Profiles.user) } catch { wrongScopeRejected = true }
            try omCheck(revoked.control == .revoked && revoked.projection?.status == .running && resumeRejected && wrongScopeRejected,
                        "revocation fences a late success, blocks silent regrant, and rejects another local scope")
            let fixtureFile = root.appendingPathComponent("named-peer.json"), fixtureClient = root.appendingPathComponent("named-client.json")
            let named = try OpenMuseFixtureTransport(stateURL: fixtureFile)
            let namedService = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: fixtureClient)), transport: named)
            _ = try await namedService.prepare(input); _ = try await namedService.admit(operationID: input.operationID, scope: input.scope)
            _ = try await namedService.refresh(operationID: input.operationID, scope: input.scope)
            let namedRestore = OpenMuseTaskService(repository: try Repository(persistence: FilePersistence(url: fixtureClient)), transport: try OpenMuseFixtureTransport(stateURL: fixtureFile))
            try await namedRestore.recover(scope: input.scope)
            let namedRead = try await namedRestore.refresh(operationID: input.operationID, scope: input.scope)
            try omCheck(namedRead.projection?.status == .waitingApproval && namedRead.artifactHistory.first?.body.contains("Alpha synthetic record") == true && namedRead.provenance == .fixtureTransport,
                        "named fixture and client use independent disk files and restore their original synthetic result")
            let bridgeInput = OpenMuseTaskInput(scope: Profiles.demo, environmentID: input.environmentID, title: "Bridge synthetic test", goal: "Fixed synthetic records only")
            _ = try await namedService.prepare(bridgeInput)
            let bridge = OpenMuseAgentProvider(service: namedService)
            let context = ProviderContext(scope: Profiles.demo, operationID: bridgeInput.operationID, environmentID: bridgeInput.environmentID,
                providerID: OpenMuseAgentProvider.providerID, runtimeEpoch: 1, authorizationReferences: [])
            var admissionEvents = 0, unexpectedCompletion = false
            for try await event in try await bridge.start(TaskRequest(context: context, taskID: OpenMuseAgentProvider.nativeTaskID(operationID: bridgeInput.operationID), taskRevision: 1)) {
                admissionEvents += 1
                if case .accepted = event.payload { } else { unexpectedCompletion = true }
                if event.reality != .simulated { unexpectedCompletion = true }
            }
            let bridgeRead = try await bridge.observe(operationID: bridgeInput.operationID, context: context)
            if case .progress = bridgeRead.payload { } else { unexpectedCompletion = true }
            let bridgeStop = try await bridge.cancel(operationID: bridgeInput.operationID, context: context)
            if case .outcomeUnknown = bridgeStop.payload { } else { unexpectedCompletion = true }
            var staleBridgeRejected = false
            do { _ = try await bridge.observe(operationID: bridgeInput.operationID, context: context) } catch { staleBridgeRejected = true }
            try omCheck(admissionEvents == 1 && !unexpectedCompletion && staleBridgeRejected,
                        "AgentProvider bridge EOF is admission-only; status and observation cancellation never claim task completion, remote verification or business cancellation")
            print("layer=pure_fixture_transport external_requests=0 real_cloud=0 real_model=0")
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
