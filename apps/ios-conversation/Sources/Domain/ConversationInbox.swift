import Foundation

public enum ConversationInboxError:Error,LocalizedError,Sendable,Equatable {
    case accessDenied,invalidResponse,busy,stale,unavailable,closed
    public var errorDescription:String? {switch self {
    case .accessDenied:return "当前账号不能读取这份工作，旧的查收快照已移除。"
    case .invalidResponse:return "查收记录或成果身份核对失败，请重新读取。"
    case .busy:return "正在读取下一页，请稍候。"
    case .stale:return "查收列表已变化，请重新读取后打开。"
    case .unavailable:return "当前连接暂不支持跨对话查收。"
    case .closed:return "查收已停止，请在当前账号恢复连接后读取。"
    }}
}
/// Local partition and server scope are distinct identities. This conveys no grant.
public struct ConversationInboxReference:Sendable,Equatable {
    public let scope:DataScope
    public let serverScopeID:UUID
    public let subjectID:UUID
    public init(scope:DataScope,serverScopeID:UUID,subjectID:UUID) {self.scope=scope;self.serverScopeID=serverScopeID;self.subjectID=subjectID}
}
public enum ConversationInboxTaskStatus:String,Codable,Sendable {
    case queued,scheduled,running,succeeded,failed,outcomeUnknown="outcome_unknown",waitingInput="waiting_input",waitingApproval="waiting_approval",paused,cancelled,interrupted
}
public enum ConversationInboxAuthorizationState:String,Codable,Sendable {case current,superseded}
public struct ConversationInboxArtifactReference:Codable,Sendable,Equatable,Hashable,Identifiable {
    public let artifactID:String
    public let version:Int
    public let contentHash:String
    public var id:String {artifactID+":"+String(version)+":"+contentHash}
    private enum CodingKeys:String,CodingKey {case artifactID="artifact_id",version,contentHash="content_hash"}
    public init(artifactID:String,version:Int,contentHash:String) {self.artifactID=artifactID;self.version=version;self.contentHash=contentHash}
    public var identity:ConversationArtifactIdentity {.init(artifactID:artifactID,version:version,contentHash:contentHash)}
    public func validate() throws {
        guard ConversationInboxValidation.hash(artifactID),ConversationInboxValidation.positive(version),ConversationInboxValidation.hash(contentHash) else {throw ConversationInboxError.invalidResponse}
    }
}
public struct ConversationInboxItem:Codable,Sendable,Equatable,Identifiable {
    public let binding:ConversationTaskBinding
    public let title:String
    public let createdAt:String
    public let updatedAt:String
    public let taskStatus:ConversationInboxTaskStatus
    public let authorizationState:ConversationInboxAuthorizationState
    public let artifacts:[ConversationInboxArtifactReference]
    public let planReference:ConversationArtifactEditPlanReference?
    public let pendingActionCount:Int
    public var id:UUID {binding.run_id}
    private enum CodingKeys:String,CodingKey {case binding,title,createdAt="created_at",updatedAt="updated_at",taskStatus="task_status",authorizationState="authorization_state",artifacts,planReference="plan_reference",pendingActionCount="pending_action_count"}
    public init(binding:ConversationTaskBinding,title:String,createdAt:String,updatedAt:String,taskStatus:ConversationInboxTaskStatus,authorizationState:ConversationInboxAuthorizationState,artifacts:[ConversationInboxArtifactReference],planReference:ConversationArtifactEditPlanReference?,pendingActionCount:Int) {
        self.binding=binding;self.title=title;self.createdAt=createdAt;self.updatedAt=updatedAt;self.taskStatus=taskStatus;self.authorizationState=authorizationState;self.artifacts=artifacts;self.planReference=planReference;self.pendingActionCount=pendingActionCount
    }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(binding,forKey:.binding);try c.encode(title,forKey:.title);try c.encode(createdAt,forKey:.createdAt);try c.encode(updatedAt,forKey:.updatedAt)
        try c.encode(taskStatus,forKey:.taskStatus);try c.encode(authorizationState,forKey:.authorizationState);try c.encode(artifacts,forKey:.artifacts)
        try c.encode(planReference,forKey:.planReference);try c.encode(pendingActionCount,forKey:.pendingActionCount)
    }
    public func validate(_ reference:ConversationInboxReference) throws {
        try ConversationInboxValidation.binding(binding,reference:reference)
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.utf8.count<=512,
              let created=ConversationInboxValidation.utc(createdAt),let updated=ConversationInboxValidation.utc(updatedAt),updated>=created,
              ConversationInboxValidation.nonnegative(pendingActionCount),artifacts.count<=100,
              Set(artifacts.map(\.artifactID)).count==artifacts.count else {throw ConversationInboxError.invalidResponse}
        for artifact in artifacts {try artifact.validate()}
        if let planReference {guard ConversationInboxValidation.positive(planReference.revision),ConversationInboxValidation.hash(planReference.planHash) else {throw ConversationInboxError.invalidResponse}}
    }
    /// An old list reference can remain in history after a newer head is read.
    /// Validate exact bytes without promoting the old version to the current head.
    public func validateResolved(_ goal:ConversationGoalProjection,reference:ConversationInboxReference) throws {
        try validate(reference)
        guard goal.id==binding.task_id,goal.binding==binding,ConversationInboxValidation.positive(goal.revision),
              Set(goal.artifacts.map(\.id)).count==goal.artifacts.count else {throw ConversationInboxError.invalidResponse}
        var versions:[String:ConversationArtifactProjection]=[:]
        for artifact in goal.artifacts+goal.artifactHistory {
            let ref=ConversationInboxArtifactReference(artifactID:artifact.id,version:artifact.version,contentHash:artifact.contentHash)
            try ref.validate()
            guard artifact.body.utf8.count<=1_000_000,textHash(artifact.body)==artifact.contentHash,
                  let object=try? ConversationStrictJSON.object(Data(artifact.body.utf8),maxBytes:1_000_000),
                  let data=object["data"] as? [String:Any],object["title"] as? String==artifact.title,
                  object["summary"] as? String==artifact.summary,data["content"] as? String==artifact.content else {throw ConversationInboxError.invalidResponse}
            let key=artifact.id+":"+String(artifact.version)
            if let old=versions[key] {guard old.contentHash==artifact.contentHash,old.body==artifact.body else {throw ConversationInboxError.invalidResponse}}
            versions[key]=artifact
        }
        for expected in artifacts {
            guard let actual=versions[expected.artifactID+":"+String(expected.version)],actual.contentHash==expected.contentHash else {throw ConversationInboxError.stale}
        }
    }
}
public struct ConversationInboxPage:Codable,Sendable {
    public static let contractName="catpaw.inbox.v1"
    public let schemaVersion:Int
    public let contract:String
    public let scopeID:UUID
    public let subjectID:UUID
    public let items:[ConversationInboxItem]
    public let nextCursor:String?
    private enum CodingKeys:String,CodingKey {case schemaVersion="schema_version",contract,scopeID="scope_id",subjectID="subject_id",items,nextCursor="next_cursor"}
    public init(scopeID:UUID,subjectID:UUID,items:[ConversationInboxItem],nextCursor:String?=nil) {schemaVersion=1;contract=Self.contractName;self.scopeID=scopeID;self.subjectID=subjectID;self.items=items;self.nextCursor=nextCursor}
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(schemaVersion,forKey:.schemaVersion);try c.encode(contract,forKey:.contract);try c.encode(scopeID,forKey:.scopeID);try c.encode(subjectID,forKey:.subjectID);try c.encode(items,forKey:.items);try c.encode(nextCursor,forKey:.nextCursor)
    }
    public func validate(_ reference:ConversationInboxReference,limit:Int=50) throws {
        guard (1...50).contains(limit),schemaVersion==1,contract==Self.contractName,scopeID==reference.serverScopeID,subjectID==reference.subjectID,
              items.count<=limit,Set(items.map(\.id)).count==items.count,ConversationInboxValidation.cursor(nextCursor) else {throw ConversationInboxError.invalidResponse}
        for item in items {try item.validate(reference)}
    }
    /// The adapter uses this before publishing typed data; duplicate/unknown keys
    /// and JSON booleans masquerading as integers never reach presentation.
    public static func decode(_ bytes:Data,reference:ConversationInboxReference,limit:Int=50) throws -> Self {
        do {
            let object=try ConversationStrictJSON.object(bytes,maxBytes:2_000_000)
            guard Set(object.keys)==["schema_version","contract","scope_id","subject_id","items","next_cursor"],let rows=object["items"] as? [[String:Any]] else {throw ConversationInboxError.invalidResponse}
            for row in rows {
                guard Set(row.keys)==["binding","title","created_at","updated_at","task_status","authorization_state","artifacts","plan_reference","pending_action_count"],
                      let binding=row["binding"] as? [String:Any],Set(binding.keys)==["scope_id","conversation_id","turn_id","call_id","delegation_id","operation_id","run_id","task_id","request_hash","delegation_revision","grant_epoch","projection_url"],
                      let artifacts=row["artifacts"] as? [[String:Any]],artifacts.allSatisfy({Set($0.keys)==["artifact_id","version","content_hash"]}) else {throw ConversationInboxError.invalidResponse}
                if !(row["plan_reference"] is NSNull) {guard let plan=row["plan_reference"] as? [String:Any],Set(plan.keys)==["revision","plan_hash"] else {throw ConversationInboxError.invalidResponse}}
            }
            let page=try JSONDecoder().decode(Self.self,from:bytes);try page.validate(reference,limit:limit);return page
        } catch {throw ConversationInboxError.invalidResponse}
    }
}
public protocol ConversationInboxBackend:Sendable {
    func readInbox(reference:ConversationInboxReference,cursor:String?,limit:Int) async throws -> ConversationInboxPage
    func readReceivedTask(reference:ConversationInboxReference,item:ConversationInboxItem) async throws -> ConversationGoalProjection
}
public struct ConversationInboxSnapshot:Sendable {
    public let items:[ConversationInboxItem]
    public let nextCursor:String?
    public let isFresh:Bool
    public init(items:[ConversationInboxItem]=[],nextCursor:String?=nil,isFresh:Bool=false) {self.items=items;self.nextCursor=nextCursor;self.isFresh=isFresh}
}
private enum ConversationInboxValidation {
    static func hash(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    static func positive(_ value:Int)->Bool {value>0 && value<=9_007_199_254_740_991}
    static func nonnegative(_ value:Int)->Bool {value>=0 && value<=9_007_199_254_740_991}
    static func cursor(_ value:String?)->Bool {guard let value else {return true};return !value.isEmpty && value.utf8.count<=4096 && value.unicodeScalars.allSatisfy{!CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)}}
    static func utc(_ value:String)->Date? {
        guard value.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,9})?Z$",options:.regularExpression) != nil else {return nil}
        let formatter=ISO8601DateFormatter();formatter.formatOptions=value.contains(".") ? [.withInternetDateTime,.withFractionalSeconds]:[.withInternetDateTime]
        guard let date=formatter.date(from:value),String(formatter.string(from:date).prefix(19))==String(value.prefix(19)) else {return nil};return date
    }
    static func binding(_ b:ConversationTaskBinding,reference:ConversationInboxReference) throws {
        guard b.scope_id==reference.serverScopeID,Set([b.conversation_id,b.turn_id,b.delegation_id,b.operation_id,b.run_id]).count==5,
              !b.call_id.isEmpty,b.call_id.utf8.count<=256,!b.call_id.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),
              b.task_id.range(of:"^[A-Za-z0-9._-]{1,256}$",options:.regularExpression) != nil,hash(b.request_hash),positive(b.delegation_revision),positive(b.grant_epoch),
              b.projection_url=="/catpaw/v1/scopes/"+reference.serverScopeID.uuidString.lowercased()+"/runs/"+b.run_id.uuidString.lowercased() else {throw ConversationInboxError.invalidResponse}
    }
}
