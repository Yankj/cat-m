#if DEBUG
import Foundation

/// A durable offline server fixture. It never performs HTTP, Auth, model work or source reads.
public actor ConversationArtifactEditFixtureBackend:ConversationArtifactEditBackend {
    public enum Mode:Sendable {case applied,unknown}
    private struct Storage:Codable,Sendable {
        var versions:[String:[String:ConversationArtifactEditSnapshot]]=[:]
        var heads:[String:Int]=[:]
        var requests:[String:ConversationArtifactEditAmendRequest]=[:]
        var receipts:[String:ConversationArtifactEditEnvelope]=[:]
        var postOperations:[UUID]=[]
        var readOperations:[UUID]=[]
        var reads=0
        var lostResponses:Set<UUID>=[]
    }
    private let url:URL
    private let mode:Mode
    private let statsUpdated:@Sendable ([String:Int]) async -> Void
    private var storage:Storage
    public init(url:URL,mode:Mode = .applied,statsUpdated:@escaping @Sendable ([String:Int]) async -> Void={_ in}) throws {
        self.url=url;self.mode=mode;self.statsUpdated=statsUpdated
        storage=FileManager.default.fileExists(atPath:url.path) ? try JSONDecoder().decode(Storage.self,from:Data(contentsOf:url)) : Storage()
    }
    public func publishStats() async {await statsUpdated(stats())}
    public func stats()->[String:Int] {["artifact_posts":storage.postOperations.count,"artifact_reads":storage.reads,"artifact_committed_revisions":storage.receipts.count]}
    public func operations()->(posts:[UUID],reads:[UUID]) {(storage.postOperations,storage.readOperations)}
    public func readArtifact(_ reference:ConversationArtifactEditReference,version:Int?) async throws -> ConversationArtifactEditEnvelope {
        try seed(reference)
        let work=key(reference),selected=version ?? storage.heads[work]!
        guard let snapshot=storage.versions[work]?[String(selected)],let head=storage.versions[work]?[String(storage.heads[work]!)] else {throw catError.missing}
        var next=storage;next.reads += 1;try persist(next);await publishStats()
        return .init(artifact:point(snapshot,to:head))
    }
    public func amendArtifact(_ reference:ConversationArtifactEditReference,request:ConversationArtifactEditAmendRequest) async throws -> ConversationArtifactEditEnvelope {
        try seed(reference);try request.content.validate()
        let work=key(reference),operation=request.operationID.uuidString.lowercased()
        var next=storage;next.postOperations.append(request.operationID)
        if let old=next.receipts[operation] {
            guard next.requests[operation]==request else {throw catError.conflict}
            try persist(next);await publishStats();return old
        }
        guard let head=storage.versions[work]?[String(storage.heads[work]!)],head.version==request.expectedVersion,head.contentHash==request.expectedContentHash,head.grantEpoch==request.expectedGrantEpoch,head.planReference.revision==request.expectedPlanRevision,head.planReference.planHash==request.expectedPlanHash else {try persist(next);await publishStats();throw catError.conflict}
        let stamp="2026-10-14T03:00:00.000Z",body=try ConversationArtifactEditCodec.revisedBody(base:head,request:request,committedAt:stamp)
        let identity=ConversationArtifactVersionReference(artifactID:head.artifactID,version:head.version+1,contentHash:textHash(body)),boundary:ConversationArtifactSourceBoundary=head.sourceEvidenceBoundary == .suppliedContextOnly ? .suppliedContextOnly : .originalSnapshotOnly
        let artifact=copy(head,body:body,createdAt:stamp,origin:.userRevision,identity:identity,current:identity,boundary:boundary)
        let unhashed=ConversationArtifactEditAmendment(operationID:request.operationID,scopeID:head.scopeID,subjectID:head.subjectID,runID:head.runID,taskID:head.taskID,conversationID:head.conversationID,artifactID:head.artifactID,runRequestHash:head.runRequestHash,sourceAuthHash:head.sourceAuthHash,delegationID:head.delegationID,delegationRevision:head.delegationRevision,grantEpoch:head.grantEpoch,planReference:head.planReference,baseReference:head.versionReference,resultReference:identity,content:request.content,sourceEvidenceBoundary:boundary,committedAt:stamp,receiptHash:"")
        var receiptObject=unhashed.canonicalValue;receiptObject["receipt_hash"]=try unhashed.canonicalHash()
        let receipt=try ConversationArtifactEditCodec.decode(ConversationArtifactEditAmendment.self,receiptObject),envelope=ConversationArtifactEditEnvelope(artifact:artifact,amendment:receipt)
        try envelope.validateApplied(reference:reference,request:request,base:head)
        next.versions[work]?[String(artifact.version)]=artifact;next.heads[work]=artifact.version;next.requests[operation]=request;next.receipts[operation]=envelope
        let lose=mode == .unknown && !next.lostResponses.contains(request.operationID)
        if lose {next.lostResponses.insert(request.operationID)}
        // The fake server receipt is durable before the deliberately lost response.
        try persist(next);await publishStats()
        if lose {throw URLError(.networkConnectionLost)}
        return envelope
    }
    public func readAmendment(_ reference:ConversationArtifactEditReference,operationID:UUID) async throws -> ConversationArtifactEditEnvelope {
        try seed(reference)
        let operation=operationID.uuidString.lowercased(),work=key(reference)
        guard let receipt=storage.receipts[operation],receipt.artifact.runID==reference.binding.run_id,receipt.artifact.artifactID==reference.artifact.id,let head=storage.versions[work]?[String(storage.heads[work]!)] else {throw catError.missing}
        var next=storage;next.reads += 1;next.readOperations.append(operationID);try persist(next);await publishStats()
        return .init(artifact:point(receipt.artifact,to:head),amendment:receipt.amendment)
    }
    private func seed(_ reference:ConversationArtifactEditReference) throws {
        let work=key(reference)
        if let snapshots=storage.versions[work],!snapshots.isEmpty {return}
        let root=try ConversationArtifactEditCodec.object(reference.artifact.body),data=root["data"] as! [String:Any]
        let stamp=(data["updated_at"] as? String).flatMap{ConversationArtifactReading.utcDate($0)==nil ? nil : $0} ?? "2026-10-14T02:01:00.000Z"
        let snapshot=ConversationArtifactEditSnapshot(artifactID:reference.artifact.id,scopeID:reference.binding.scope_id,subjectID:stableID("P0-task-review-subject"),sourceAuthHash:textHash("P0-task-review-source"),runRequestHash:reference.binding.request_hash,delegationID:reference.binding.delegation_id,delegationRevision:reference.binding.delegation_revision,grantEpoch:reference.binding.grant_epoch,runID:reference.binding.run_id,taskID:reference.binding.task_id,conversationID:reference.binding.conversation_id,version:reference.artifact.version,contentHash:reference.artifact.contentHash,body:reference.artifact.body,createdAt:stamp,planReference:.init(revision:1,planHash:textHash("P0-task-review-plan")),origin:.agent,isCurrent:true,currentReference:.init(reference.selection),sourceEvidenceBoundary:data["source_contract"] as? String == "sourced-report-v1" ? .agentOriginal : .suppliedContextOnly,editable:true)
        try snapshot.validate(reference:reference)
        var next=storage;next.versions[work]=[String(snapshot.version):snapshot];next.heads[work]=snapshot.version;try persist(next)
    }
    private func point(_ snapshot:ConversationArtifactEditSnapshot,to head:ConversationArtifactEditSnapshot)->ConversationArtifactEditSnapshot {copy(snapshot,body:snapshot.body,createdAt:snapshot.createdAt,origin:snapshot.origin,identity:snapshot.versionReference,current:head.versionReference,boundary:snapshot.sourceEvidenceBoundary)}
    private func copy(_ snapshot:ConversationArtifactEditSnapshot,body:String,createdAt:String,origin:ConversationArtifactEditOrigin,identity:ConversationArtifactVersionReference,current:ConversationArtifactVersionReference,boundary:ConversationArtifactSourceBoundary)->ConversationArtifactEditSnapshot {
        .init(artifactID:identity.artifactID,scopeID:snapshot.scopeID,subjectID:snapshot.subjectID,sourceAuthHash:snapshot.sourceAuthHash,runRequestHash:snapshot.runRequestHash,delegationID:snapshot.delegationID,delegationRevision:snapshot.delegationRevision,grantEpoch:snapshot.grantEpoch,runID:snapshot.runID,taskID:snapshot.taskID,conversationID:snapshot.conversationID,version:identity.version,contentHash:identity.contentHash,body:body,createdAt:createdAt,planReference:snapshot.planReference,origin:origin,isCurrent:identity==current,currentReference:current,sourceEvidenceBoundary:boundary,editable:identity==current,editBlockedReason:identity==current ? nil : "artifact_version_conflict")
    }
    private func persist(_ next:Storage) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(next).write(to:url,options:.atomic);storage=next
    }
    private func key(_ reference:ConversationArtifactEditReference)->String {"\(reference.binding.scope_id):\(reference.binding.run_id):\(reference.artifact.id)"}
}
#endif
