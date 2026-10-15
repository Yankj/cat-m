import Foundation

public enum ConversationArtifactEditError:Error,LocalizedError,Sendable {
    case notConfigured,invalidResponse,busy,staleDraft,notEditable,notFresh,localDraftTooLong
    public var errorDescription:String? {
        switch self {
        case .notConfigured:return "成果修改服务尚未连接，修改草稿会保留。"
        case .invalidResponse:return "成果版本、来源或修改回执不匹配，尚未记录保存成功。"
        case .busy:return "原成果修改尚待核对，请勿重复提交。"
        case .staleDraft:return "成果已有新版，原修改草稿仍保留。请核对后明确换用新版。"
        case .notEditable:return "这份成果当前不能修改，草稿会保留。"
        case .notFresh:return "先读取当前成果，再保存修改。草稿会保留。"
        case .localDraftTooLong:return "本地修改草稿过长。请缩短或明确放弃，尚未关闭编辑。"
        }
    }
}
public struct ConversationArtifactEditReference:Identifiable,Sendable {
    public let scope:DataScope
    public let binding:ConversationTaskBinding
    public let subjectID:UUID
    public let artifact:ConversationArtifactProjection
    public var selection:ConversationArtifactIdentity {ConversationArtifactIdentity(artifact)}
    public var id:UUID {stableID("artifact-editor:\(scope.workspaceID):\(binding.conversation_id):\(binding.run_id):\(selection.id)")}
    public init(scope:DataScope,binding:ConversationTaskBinding,subjectID:UUID,artifact:ConversationArtifactProjection) {self.scope=scope;self.binding=binding;self.subjectID=subjectID;self.artifact=artifact}
}
public struct ConversationArtifactVersionReference:Codable,Sendable,Equatable {
    public let artifactID:String
    public let version:Int
    public let contentHash:String
    private enum CodingKeys:String,CodingKey {case artifactID="artifact_id",version,contentHash="content_hash"}
    public var identity:ConversationArtifactIdentity {.init(artifactID:artifactID,version:version,contentHash:contentHash)}
    public init(artifactID:String,version:Int,contentHash:String) {self.artifactID=artifactID;self.version=version;self.contentHash=contentHash}
    public init(_ identity:ConversationArtifactIdentity) {self.init(artifactID:identity.artifactID,version:identity.version,contentHash:identity.contentHash)}
    public func validate() throws {guard ConversationArtifactEditCodec.isHash(artifactID),ConversationArtifactEditCodec.validInteger(version),ConversationArtifactEditCodec.isHash(contentHash) else {throw ConversationArtifactEditError.invalidResponse}}
    fileprivate var canonicalValue:[String:Any] {["artifact_id":artifactID,"version":version,"content_hash":contentHash]}
}
public struct ConversationArtifactEditPlanReference:Codable,Sendable,Equatable {
    public let revision:Int
    public let planHash:String
    private enum CodingKeys:String,CodingKey {case revision,planHash="plan_hash"}
    public init(revision:Int,planHash:String) {self.revision=revision;self.planHash=planHash}
    public func validate() throws {guard ConversationArtifactEditCodec.validInteger(revision),ConversationArtifactEditCodec.isHash(planHash) else {throw ConversationArtifactEditError.invalidResponse}}
    fileprivate var canonicalValue:[String:Any] {["revision":revision,"plan_hash":planHash]}
}
public struct ConversationArtifactEditContent:Codable,Sendable,Equatable {
    public var title:String
    public var summary:String
    public var content:String
    public init(title:String,summary:String,content:String) {self.title=title;self.summary=summary;self.content=content}
    public func validate() throws {
        guard Self.validText(title,limit:160),Self.validText(summary,limit:8000),Self.validText(content,limit:16000) else {throw ConversationArtifactEditError.invalidResponse}
    }
    public func validateLocal() throws {guard title.utf16.count<=8000,summary.utf16.count<=16000,content.utf16.count<=32000 else {throw ConversationArtifactEditError.localDraftTooLong}}
    private static func validText(_ value:String,limit:Int)->Bool {ConversationTaskPlanContent.hasNonWhitespace(value) && value.utf16.count<=limit && !value.unicodeScalars.contains {switch $0.value {case 0...8,11,12,14...31,127:return true;default:return false}}}
    fileprivate var canonicalValue:[String:Any] {["title":title,"summary":summary,"content":content]}
}
public enum ConversationArtifactEditOrigin:String,Codable,Sendable {case agent;case userRevision="user_revision"}
public enum ConversationArtifactSourceBoundary:String,Codable,Sendable {case agentOriginal="agent_original",originalSnapshotOnly="original_snapshot_only",suppliedContextOnly="supplied_context_only"}
public struct ConversationArtifactEditSnapshot:Codable,Sendable,Equatable {
    public let artifactID:String
    public let scopeID:UUID
    public let subjectID:UUID
    public let sourceAuthHash:String
    public let runRequestHash:String
    public let delegationID:UUID
    public let delegationRevision:Int
    public let grantEpoch:Int
    public let runID:UUID
    public let taskID:String
    public let conversationID:UUID
    public let version:Int
    public let contentHash:String
    public let mimeType:String
    public let body:String
    public let createdAt:String
    public let planReference:ConversationArtifactEditPlanReference
    public let origin:ConversationArtifactEditOrigin
    public let isCurrent:Bool
    public let currentReference:ConversationArtifactVersionReference
    public let sourceEvidenceBoundary:ConversationArtifactSourceBoundary
    public let editable:Bool
    public let editBlockedReason:String?
    private enum CodingKeys:String,CodingKey {
        case version,body,origin,editable
        case artifactID="artifact_id",scopeID="scope_id",subjectID="subject_id",sourceAuthHash="source_auth_hash",runRequestHash="run_request_hash",delegationID="delegation_id",delegationRevision="delegation_revision",grantEpoch="grant_epoch",runID="run_id",taskID="task_id",conversationID="conversation_id",contentHash="content_hash",mimeType="mime_type",createdAt="created_at",planReference="plan_reference",isCurrent="is_current",currentReference="current_reference",sourceEvidenceBoundary="source_evidence_boundary",editBlockedReason="edit_blocked_reason"
    }
    public init(artifactID:String,scopeID:UUID,subjectID:UUID,sourceAuthHash:String,runRequestHash:String,delegationID:UUID,delegationRevision:Int,grantEpoch:Int,runID:UUID,taskID:String,conversationID:UUID,version:Int,contentHash:String,mimeType:String="application/json",body:String,createdAt:String,planReference:ConversationArtifactEditPlanReference,origin:ConversationArtifactEditOrigin,isCurrent:Bool,currentReference:ConversationArtifactVersionReference,sourceEvidenceBoundary:ConversationArtifactSourceBoundary,editable:Bool,editBlockedReason:String?=nil) {
        self.artifactID=artifactID;self.scopeID=scopeID;self.subjectID=subjectID;self.sourceAuthHash=sourceAuthHash;self.runRequestHash=runRequestHash;self.delegationID=delegationID;self.delegationRevision=delegationRevision;self.grantEpoch=grantEpoch;self.runID=runID;self.taskID=taskID;self.conversationID=conversationID;self.version=version;self.contentHash=contentHash;self.mimeType=mimeType;self.body=body;self.createdAt=createdAt;self.planReference=planReference;self.origin=origin;self.isCurrent=isCurrent;self.currentReference=currentReference;self.sourceEvidenceBoundary=sourceEvidenceBoundary;self.editable=editable;self.editBlockedReason=editBlockedReason
    }
    public var identity:ConversationArtifactIdentity {.init(artifactID:artifactID,version:version,contentHash:contentHash)}
    public var versionReference:ConversationArtifactVersionReference {.init(identity)}
    public func document() throws -> ConversationArtifactEditContent {try ConversationArtifactEditCodec.document(body)}
    public func validate(reference:ConversationArtifactEditReference) throws {
        let binding=reference.binding
        try versionReference.validate();try currentReference.validate();try planReference.validate()
        guard scopeID==binding.scope_id,subjectID==reference.subjectID,runID==binding.run_id,taskID==binding.task_id,conversationID==binding.conversation_id,
              artifactID==reference.artifact.id,runRequestHash==binding.request_hash,delegationID==binding.delegation_id,delegationRevision==binding.delegation_revision,grantEpoch==binding.grant_epoch,
              ConversationArtifactEditCodec.isHash(sourceAuthHash),ConversationArtifactEditCodec.isHash(runRequestHash),ConversationArtifactEditCodec.isHash(taskID),ConversationArtifactEditCodec.validInteger(grantEpoch),ConversationArtifactEditCodec.validInteger(delegationRevision),
              mimeType=="application/json",body.utf8.count<=256000,textHash(body)==contentHash,ConversationArtifactReading.utcDate(createdAt) != nil,
              currentReference.artifactID==artifactID,currentReference.version>=version,
              isCurrent ? currentReference==versionReference : currentReference.version>version,
              !editable || (isCurrent && editBlockedReason==nil),editBlockedReason.map({!$0.isEmpty && $0.utf16.count<=500}) ?? true else {throw ConversationArtifactEditError.invalidResponse}
        _ = try document()
        let data=try ConversationArtifactEditCodec.object(body)["data"] as! [String:Any]
        let sourced=data["source_contract"] as? String == "sourced-report-v1"
        if origin == .agent {guard sourceEvidenceBoundary == (sourced ? .agentOriginal : .suppliedContextOnly) else {throw ConversationArtifactEditError.invalidResponse}}
        else {
            try document().validate()
            guard sourceEvidenceBoundary == (sourced ? .originalSnapshotOnly : .suppliedContextOnly),data["source"] as? String == "user_revision",data["updated_at"] as? String==createdAt,
                  let revision=data["user_revision"] as? [String:Any],revision["author"] as? String=="user",revision["claims_verification"] as? String=="not_rechecked",revision["source_evidence_boundary"] as? String==sourceEvidenceBoundary.rawValue,
                  let operation=revision["operation_id"] as? String,UUID(uuidString:operation) != nil,
                  let base=try? ConversationArtifactEditCodec.decode(ConversationArtifactVersionReference.self,revision["base_reference"]),base.artifactID==artifactID,base.version<ConversationArtifactEditCodec.maxInteger,base.version+1==version,
                  let plan=try? ConversationArtifactEditCodec.decode(ConversationArtifactEditPlanReference.self,revision["plan_reference"]),plan==planReference,
                  let epoch=revision["grant_epoch"] as? NSNumber,CFGetTypeID(epoch) != CFBooleanGetTypeID(),epoch.intValue==grantEpoch,epoch.doubleValue==Double(grantEpoch),!sourced || data["citations"]==nil else {throw ConversationArtifactEditError.invalidResponse}
            try base.validate()
        }
    }
}
public struct ConversationArtifactEditAmendRequest:Codable,Sendable,Equatable {
    public let operationID:UUID
    public let expectedVersion:Int
    public let expectedContentHash:String
    public let expectedGrantEpoch:Int
    public let expectedPlanRevision:Int
    public let expectedPlanHash:String
    public let content:ConversationArtifactEditContent
    private enum CodingKeys:String,CodingKey {case content,operationID="operation_id",expectedVersion="expected_version",expectedContentHash="expected_content_hash",expectedGrantEpoch="expected_grant_epoch",expectedPlanRevision="expected_plan_revision",expectedPlanHash="expected_plan_hash"}
    public init(operationID:UUID,expectedVersion:Int,expectedContentHash:String,expectedGrantEpoch:Int,expectedPlanRevision:Int,expectedPlanHash:String,content:ConversationArtifactEditContent) {self.operationID=operationID;self.expectedVersion=expectedVersion;self.expectedContentHash=expectedContentHash;self.expectedGrantEpoch=expectedGrantEpoch;self.expectedPlanRevision=expectedPlanRevision;self.expectedPlanHash=expectedPlanHash;self.content=content}
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(operationID.uuidString.lowercased(),forKey:.operationID);try c.encode(expectedVersion,forKey:.expectedVersion);try c.encode(expectedContentHash,forKey:.expectedContentHash);try c.encode(expectedGrantEpoch,forKey:.expectedGrantEpoch);try c.encode(expectedPlanRevision,forKey:.expectedPlanRevision);try c.encode(expectedPlanHash,forKey:.expectedPlanHash);try c.encode(content,forKey:.content)
    }
}
public struct ConversationArtifactEditAmendment:Codable,Sendable,Equatable {
    public enum State:String,Codable,Sendable {case applied}
    public let operationID:UUID
    public let state:State
    public let scopeID:UUID
    public let subjectID:UUID
    public let runID:UUID
    public let taskID:String
    public let conversationID:UUID
    public let artifactID:String
    public let runRequestHash:String
    public let sourceAuthHash:String
    public let delegationID:UUID
    public let delegationRevision:Int
    public let grantEpoch:Int
    public let planReference:ConversationArtifactEditPlanReference
    public let baseReference:ConversationArtifactVersionReference
    public let resultReference:ConversationArtifactVersionReference
    public let content:ConversationArtifactEditContent
    public let origin:ConversationArtifactEditOrigin
    public let sourceEvidenceBoundary:ConversationArtifactSourceBoundary
    public let committedAt:String
    public let receiptHash:String
    private enum CodingKeys:String,CodingKey {case state,content,origin,operationID="operation_id",scopeID="scope_id",subjectID="subject_id",runID="run_id",taskID="task_id",conversationID="conversation_id",artifactID="artifact_id",runRequestHash="run_request_hash",sourceAuthHash="source_auth_hash",delegationID="delegation_id",delegationRevision="delegation_revision",grantEpoch="grant_epoch",planReference="plan_reference",baseReference="base_reference",resultReference="result_reference",sourceEvidenceBoundary="source_evidence_boundary",committedAt="committed_at",receiptHash="receipt_hash"}
    public init(operationID:UUID,state:State = .applied,scopeID:UUID,subjectID:UUID,runID:UUID,taskID:String,conversationID:UUID,artifactID:String,runRequestHash:String,sourceAuthHash:String,delegationID:UUID,delegationRevision:Int,grantEpoch:Int,planReference:ConversationArtifactEditPlanReference,baseReference:ConversationArtifactVersionReference,resultReference:ConversationArtifactVersionReference,content:ConversationArtifactEditContent,origin:ConversationArtifactEditOrigin = .userRevision,sourceEvidenceBoundary:ConversationArtifactSourceBoundary,committedAt:String,receiptHash:String) {self.operationID=operationID;self.state=state;self.scopeID=scopeID;self.subjectID=subjectID;self.runID=runID;self.taskID=taskID;self.conversationID=conversationID;self.artifactID=artifactID;self.runRequestHash=runRequestHash;self.sourceAuthHash=sourceAuthHash;self.delegationID=delegationID;self.delegationRevision=delegationRevision;self.grantEpoch=grantEpoch;self.planReference=planReference;self.baseReference=baseReference;self.resultReference=resultReference;self.content=content;self.origin=origin;self.sourceEvidenceBoundary=sourceEvidenceBoundary;self.committedAt=committedAt;self.receiptHash=receiptHash}
    public func canonicalHash() throws -> String {textHash(try ConversationArtifactEditCodec.canonicalString(canonicalValue))}
    public var canonicalValue:[String:Any] {[
        "operation_id":operationID.uuidString.lowercased(),"state":state.rawValue,"scope_id":scopeID.uuidString.lowercased(),"subject_id":subjectID.uuidString.lowercased(),"run_id":runID.uuidString.lowercased(),"task_id":taskID,"conversation_id":conversationID.uuidString.lowercased(),"artifact_id":artifactID,"run_request_hash":runRequestHash,"source_auth_hash":sourceAuthHash,"delegation_id":delegationID.uuidString.lowercased(),"delegation_revision":delegationRevision,"grant_epoch":grantEpoch,"plan_reference":planReference.canonicalValue,"base_reference":baseReference.canonicalValue,"result_reference":resultReference.canonicalValue,"content":content.canonicalValue,"origin":origin.rawValue,"source_evidence_boundary":sourceEvidenceBoundary.rawValue,"committed_at":committedAt
    ]}
}
public struct ConversationArtifactEditEnvelope:Codable,Sendable,Equatable {
    public let schemaVersion:Int
    public let contract:String
    public let artifact:ConversationArtifactEditSnapshot
    public let amendment:ConversationArtifactEditAmendment?
    private enum CodingKeys:String,CodingKey {case schemaVersion="schema_version",contract,artifact,amendment}
    public init(artifact:ConversationArtifactEditSnapshot,amendment:ConversationArtifactEditAmendment?=nil) {schemaVersion=1;contract="catpaw.task-artifact.v1";self.artifact=artifact;self.amendment=amendment}
    public func validate(reference:ConversationArtifactEditReference) throws {guard schemaVersion==1,contract=="catpaw.task-artifact.v1" else {throw ConversationArtifactEditError.invalidResponse};try artifact.validate(reference:reference)}
    public func validateApplied(reference:ConversationArtifactEditReference,request:ConversationArtifactEditAmendRequest,base:ConversationArtifactEditSnapshot) throws {
        try validate(reference:reference);try base.validate(reference:reference);try request.content.validate()
        guard let receipt=amendment,receipt.operationID==request.operationID,receipt.scopeID==base.scopeID,receipt.subjectID==base.subjectID,receipt.runID==base.runID,receipt.taskID==base.taskID,receipt.conversationID==base.conversationID,receipt.artifactID==base.artifactID,
              receipt.runRequestHash==base.runRequestHash,receipt.sourceAuthHash==base.sourceAuthHash,receipt.delegationID==base.delegationID,receipt.delegationRevision==base.delegationRevision,receipt.grantEpoch==base.grantEpoch,receipt.grantEpoch==request.expectedGrantEpoch,
              receipt.planReference==base.planReference,receipt.planReference.revision==request.expectedPlanRevision,receipt.planReference.planHash==request.expectedPlanHash,
              receipt.baseReference==base.versionReference,receipt.baseReference.version==request.expectedVersion,receipt.baseReference.contentHash==request.expectedContentHash,
              request.expectedVersion<ConversationArtifactEditCodec.maxInteger,receipt.resultReference==artifact.versionReference,artifact.version==request.expectedVersion+1,receipt.content==request.content,try artifact.document()==request.content,
              artifact.sourceAuthHash==base.sourceAuthHash,artifact.planReference==base.planReference,receipt.origin == .userRevision,artifact.origin == .userRevision,
              receipt.sourceEvidenceBoundary==artifact.sourceEvidenceBoundary,receipt.sourceEvidenceBoundary == (base.sourceEvidenceBoundary == .suppliedContextOnly ? .suppliedContextOnly : .originalSnapshotOnly),
              receipt.committedAt==artifact.createdAt,ConversationArtifactReading.utcDate(receipt.committedAt) != nil,ConversationArtifactEditCodec.isHash(receipt.receiptHash),try receipt.canonicalHash()==receipt.receiptHash else {throw ConversationArtifactEditError.invalidResponse}
        let expected=try ConversationArtifactEditCodec.revisedBody(base:base,request:request,committedAt:receipt.committedAt)
        guard artifact.body==expected,textHash(expected)==receipt.resultReference.contentHash else {throw ConversationArtifactEditError.invalidResponse}
    }
}
public protocol ConversationArtifactEditBackend:Sendable {
    func readArtifact(_ reference:ConversationArtifactEditReference,version:Int?) async throws -> ConversationArtifactEditEnvelope
    func amendArtifact(_ reference:ConversationArtifactEditReference,request:ConversationArtifactEditAmendRequest) async throws -> ConversationArtifactEditEnvelope
    func readAmendment(_ reference:ConversationArtifactEditReference,operationID:UUID) async throws -> ConversationArtifactEditEnvelope
}
public struct UnconfiguredConversationArtifactEditBackend:ConversationArtifactEditBackend {
    public init() {}
    public func readArtifact(_ reference:ConversationArtifactEditReference,version:Int?) async throws -> ConversationArtifactEditEnvelope {throw ConversationArtifactEditError.notConfigured}
    public func amendArtifact(_ reference:ConversationArtifactEditReference,request:ConversationArtifactEditAmendRequest) async throws -> ConversationArtifactEditEnvelope {throw ConversationArtifactEditError.notConfigured}
    public func readAmendment(_ reference:ConversationArtifactEditReference,operationID:UUID) async throws -> ConversationArtifactEditEnvelope {throw ConversationArtifactEditError.notConfigured}
}
public enum ConversationArtifactEditCodec {
    public static let maxInteger=9_007_199_254_740_991
    public static func validInteger(_ value:Int)->Bool {value>0 && value<=maxInteger}
    public static func isHash(_ value:String)->Bool {value.utf8.count==64 && value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
    public static func canonicalString(_ value:Any) throws -> String {String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)}
    public static func object(_ body:String) throws -> [String:Any] {
        let object:[String:Any]
        do {object=try ConversationStrictJSON.object(Data(body.utf8),maxBytes:1_000_000)} catch {throw ConversationArtifactEditError.invalidResponse}
        guard object["kind"] as? String=="report",object["data"] is [String:Any] else {throw ConversationArtifactEditError.invalidResponse};return object
    }
    public static func document(_ body:String) throws -> ConversationArtifactEditContent {
        let object=try object(body)
        guard let title=object["title"] as? String,let summary=object["summary"] as? String,let data=object["data"] as? [String:Any],let content=data["content"] as? String else {throw ConversationArtifactEditError.invalidResponse}
        guard title.utf16.count<=160,summary.utf16.count<=8000,content.utf16.count<=16000 else {throw ConversationArtifactEditError.invalidResponse}
        return ConversationArtifactEditContent(title:title,summary:summary,content:content)
    }
    public static func decode<T:Decodable>(_ type:T.Type,_ value:Any?) throws -> T {guard let value else {throw ConversationArtifactEditError.invalidResponse};return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))}
    /// Reconstruct the server's human revision while preserving the original source snapshot.
    public static func revisedBody(base:ConversationArtifactEditSnapshot,request:ConversationArtifactEditAmendRequest,committedAt:String) throws -> String {
        var data=try object(base.body)["data"] as! [String:Any]
        let boundary:ConversationArtifactSourceBoundary=base.sourceEvidenceBoundary == .suppliedContextOnly ? .suppliedContextOnly : .originalSnapshotOnly
        if boundary == .originalSnapshotOnly {
            if data["original_citations"]==nil || data["original_citations"] is NSNull {data["original_citations"]=data["citations"] ?? []}
            data.removeValue(forKey:"citations")
        }
        data["content"]=request.content.content;data["source"]="user_revision";data["updated_at"]=committedAt
        data["user_revision"]=["author":"user","operation_id":request.operationID.uuidString.lowercased(),"base_reference":base.versionReference.canonicalValue,"plan_reference":base.planReference.canonicalValue,"grant_epoch":base.grantEpoch,"source_evidence_boundary":boundary.rawValue,"claims_verification":"not_rechecked"]
        return try canonicalString(["kind":"report","title":request.content.title,"summary":request.content.summary,"data":data])
    }
}
