import Foundation

public enum ConversationMemoryError:Error,LocalizedError,Sendable,Equatable {
    case unavailable,invalidResponse,busy,stale,originalNotFound,notSent,rejected
    public var errorDescription:String? {switch self {
    case .unavailable:return "记忆服务尚未连接，草稿会保留。"
    case .invalidResponse:return "记忆身份或回执不匹配，尚未确认结果。"
    case .busy:return "原记忆操作尚待核对，请勿重复提交。"
    case .stale:return "记忆已变化，请读取最新版本后重新核对。"
    case .originalNotFound:return "尚未找到原记忆操作，结果仍未知；不会重复发送。"
    case .notSent:return "记忆操作尚未发送，草稿会保留。"
    case .rejected:return "服务未接受本次记忆操作，请读取最新状态后重新核对。"
    }}
}
/// JSON memory values are data. No confidence percentage or executable markup.
public indirect enum ConversationMemoryValue:Codable,Sendable,Equatable {
    case null,bool(Bool),string(String),number(Double),array([Self]),object([String:Self])
    public init(from decoder:Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null}
        else if let v=try? c.decode(Bool.self){self = .bool(v)}
        else if let v=try? c.decode(String.self){self = .string(v)}
        else if let v=try? c.decode(Double.self),v.isFinite {self = .number(v)}
        else if let v=try? c.decode([Self].self){self = .array(v)}
        else {self = .object(try c.decode([String:Self].self))}
    }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self {case .null:try c.encodeNil();case .bool(let x):try c.encode(x);case .string(let x):try c.encode(x);case .number(let x):guard x.isFinite else {throw ConversationMemoryError.invalidResponse};try c.encode(x);case .array(let x):try c.encode(x);case .object(let x):try c.encode(x)}
    }
    public var readable:String {if case .string(let x)=self{return x};return (try? ConversationMemoryCodec.encoded(self)).map{String(decoding:$0,as:UTF8.self)} ?? ""}
}
public struct ConversationMemoryReference:Sendable,Equatable {
    public let scope:DataScope,serverScopeID:UUID,subjectID:UUID
    public init(scope:DataScope,serverScopeID:UUID,subjectID:UUID){self.scope=scope;self.serverScopeID=serverScopeID;self.subjectID=subjectID}
}
public struct ConversationMemoryEvidence:Codable,Sendable,Equatable {
    public var span_start:Int,span_end:Int
    public init(span_start:Int,span_end:Int){self.span_start=span_start;self.span_end=span_end}
}
public struct ConversationMemoryClaim:Codable,Sendable,Equatable {
    public var kind:String,predicate:String,value:ConversationMemoryValue,conditions:[String:ConversationMemoryValue],assertion:String,evidence:ConversationMemoryEvidence
    public var valid_from:String?,valid_until:String?,expires_at:String?
    public init(kind:String="preference",predicate:String,value:ConversationMemoryValue,conditions:[String:ConversationMemoryValue]=[:],evidence:ConversationMemoryEvidence,valid_from:String?=nil,valid_until:String?=nil,expires_at:String?=nil){self.kind=kind;self.predicate=predicate;self.value=value;self.conditions=conditions;assertion="explicit";self.evidence=evidence;self.valid_from=valid_from;self.valid_until=valid_until;self.expires_at=expires_at}
    public func validate(source:String?=nil) throws {
        guard ["fact","preference"].contains(kind),predicate.range(of:"^[a-z][a-z0-9_.]{0,79}$",options:.regularExpression) != nil,["explicit","inferred"].contains(assertion),evidence.span_start>=0,evidence.span_end>evidence.span_start,try ConversationMemoryCodec.encoded(value).count<=1000,try ConversationMemoryCodec.encoded(conditions).count<=1000 else {throw ConversationMemoryError.invalidResponse}
        if let source {guard evidence.span_end<=source.utf16.count else {throw ConversationMemoryError.invalidResponse}}
        for date in [valid_from,valid_until,expires_at].compactMap({$0}) {guard ConversationMemoryCodec.date(date) != nil else {throw ConversationMemoryError.invalidResponse}}
        if let from=valid_from,let until=valid_until {guard ConversationMemoryCodec.date(from)!<ConversationMemoryCodec.date(until)! else {throw ConversationMemoryError.invalidResponse}}
    }
}
public struct ConversationMemoryPreviousSource:Codable,Sendable,Equatable {public let id:UUID,content_hash:String}
public struct ConversationMemoryEntry:Codable,Sendable,Equatable,Identifiable {
    public let id:UUID,kind:String,predicate:String,value:ConversationMemoryValue,conditions:[String:ConversationMemoryValue],assertion:String,evidence:ConversationMemoryEvidence
    public let status:String,version:Int,source_id:UUID,source_hash:String,conversation_id:UUID,observed_at:String,recorded_at:String,memory_generation:Int
    public let temporal_state:String?,valid_from:String?,valid_until:String?,expires_at:String?,candidate_expires_at:String?,previous_source_ref:ConversationMemoryPreviousSource?
    public var claim:ConversationMemoryClaim {
        var x=ConversationMemoryClaim(kind:kind,predicate:predicate,value:value,conditions:conditions,evidence:evidence,valid_from:valid_from,valid_until:valid_until,expires_at:expires_at);x.assertion=assertion;return x
    }
}
public struct ConversationMemorySource:Codable,Sendable,Equatable,Identifiable {
    public let id:UUID,conversation_id:UUID,content_hash:String,type:String,trust:String,occurred_at:String,suppressed_for_memory:Bool,deleted_at:String?,command_id:UUID?,text:String?
}
public struct ConversationMemorySnapshot:Codable,Sendable,Equatable {
    public let schema_version:Int,contract:String,scope_id:UUID,subject_id:UUID,memory_generation:Int,enabled:Bool,claims:[ConversationMemoryEntry],candidates:[ConversationMemoryEntry],sources:[ConversationMemorySource]
    public func validate(_ reference:ConversationMemoryReference) throws {
        guard schema_version==1,contract==ConversationMemoryCodec.contract,scope_id==reference.serverScopeID,subject_id==reference.subjectID,(1...9_007_199_254_740_991).contains(memory_generation),claims.count<=2000,candidates.count<=2000,sources.count<=4000,Set(claims.map(\.id)).count==claims.count,Set(candidates.map(\.id)).count==candidates.count,Set(sources.map(\.id)).count==sources.count else {throw ConversationMemoryError.invalidResponse}
        for entry in claims+candidates {
            try entry.claim.validate()
            guard entry.version>0,entry.memory_generation>=0,entry.memory_generation<=memory_generation,ConversationMemoryCodec.isHash(entry.source_hash),ConversationMemoryCodec.date(entry.observed_at) != nil,ConversationMemoryCodec.date(entry.recorded_at) != nil,["active","disputed","proposed"].contains(entry.status),let source=sources.first(where:{$0.id==entry.source_id}),source.content_hash==entry.source_hash,source.conversation_id==entry.conversation_id else {throw ConversationMemoryError.invalidResponse}
        }
        for source in sources {try ConversationMemoryCodec.validateSource(source)}
    }
}
public enum ConversationMemoryCommandType:String,Codable,Sendable {case remember,correct,confirm,forget,set_enabled}
public struct ConversationMemoryCommand:Codable,Sendable,Equatable {
    public let type:ConversationMemoryCommandType
    public var conversation_id:UUID?,source_text:String?,claim:ConversationMemoryClaim?,target_id:UUID?,candidate_id:UUID?,expected_version:Int?,allow_relearn:Bool?,sensitive_consent:Bool?,no_relearn:Bool?,enabled:Bool?
    public init(type:ConversationMemoryCommandType){self.type=type}
    public func validate() throws {
        if let version=expected_version {guard (1..<9_007_199_254_740_991).contains(version) else {throw ConversationMemoryError.invalidResponse}}
        switch type {
        case .remember,.correct:
            guard conversation_id != nil,let text=source_text,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf16.count<=8000,let claim,claim.assertion=="explicit",allow_relearn != nil,sensitive_consent != nil,candidate_id==nil,no_relearn==nil,enabled==nil else {throw ConversationMemoryError.invalidResponse}
            try claim.validate(source:text)
            guard type == .correct ? target_id != nil && (expected_version ?? 0)>0 : target_id==nil && expected_version==nil else {throw ConversationMemoryError.invalidResponse}
        case .confirm:guard candidate_id != nil,(expected_version ?? 0)>0,allow_relearn != nil,sensitive_consent != nil,conversation_id==nil,source_text==nil,claim==nil,target_id==nil,no_relearn==nil,enabled==nil else {throw ConversationMemoryError.invalidResponse}
        case .forget:guard target_id != nil,(expected_version ?? 0)>0,no_relearn != nil,conversation_id==nil,source_text==nil,claim==nil,candidate_id==nil,allow_relearn==nil,sensitive_consent==nil,enabled==nil else {throw ConversationMemoryError.invalidResponse}
        case .set_enabled:guard enabled != nil,conversation_id==nil,source_text==nil,claim==nil,target_id==nil,candidate_id==nil,expected_version==nil,allow_relearn==nil,sensitive_consent==nil,no_relearn==nil else {throw ConversationMemoryError.invalidResponse}
        }
    }
}
public struct ConversationMemoryRequest:Codable,Sendable,Equatable,Identifiable {
    public let schema_version:Int,contract:String,operation_id:UUID,expected_memory_generation:Int,command:ConversationMemoryCommand
    public var id:UUID {operation_id}
    public init(operationID:UUID=UUID(),generation:Int,command:ConversationMemoryCommand) throws {try command.validate();guard (1...9_007_199_254_740_991).contains(generation) else {throw ConversationMemoryError.invalidResponse};schema_version=1;contract=ConversationMemoryCodec.contract;operation_id=operationID;expected_memory_generation=generation;self.command=command}
    public func requestHash() throws -> String {try ConversationCanonicalJSON.hash(ConversationMemoryCodec.encoded(self))}
}
public struct ConversationMemoryResult:Codable,Sendable,Equatable {
    public let memory_generation:Int,enabled:Bool,status:String,claim_id:UUID?,version:Int?,deletion_id:UUID?,purge_scope:String?,backups:String?,source_id:UUID?
}
public struct ConversationMemoryOperation:Codable,Sendable,Equatable {
    public let operation_id:UUID,request_hash:String,expected_memory_generation:Int,command_type:ConversationMemoryCommandType,accepted_at:String,result:ConversationMemoryResult
}
public struct ConversationMemoryReceipt:Codable,Sendable,Equatable {
    public let schema_version:Int,contract:String,scope_id:UUID,subject_id:UUID,operation:ConversationMemoryOperation
    public func validate(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) throws {
        try request.command.validate()
        let op=operation,r=op.result
        guard schema_version==1,contract==ConversationMemoryCodec.contract,scope_id==reference.serverScopeID,subject_id==reference.subjectID,op.operation_id==request.operation_id,op.request_hash==(try request.requestHash()),op.command_type==request.command.type,op.expected_memory_generation==request.expected_memory_generation,ConversationMemoryCodec.date(op.accepted_at) != nil,r.memory_generation>=request.expected_memory_generation else {throw ConversationMemoryError.invalidResponse}
        switch request.command.type {
        case .remember,.correct,.confirm:guard r.claim_id != nil,(r.version ?? 0)>0,["active","disputed"].contains(r.status) else {throw ConversationMemoryError.invalidResponse}
        case .forget:guard r.status=="purged",r.deletion_id != nil,r.purge_scope=="primary_memory_and_derived_index",r.backups=="not_verified" else {throw ConversationMemoryError.invalidResponse}
        case .set_enabled:guard r.enabled==request.command.enabled else {throw ConversationMemoryError.invalidResponse}
        }
        if request.command.type == .correct {guard r.claim_id==request.command.target_id,r.version==request.command.expected_version.map({$0+1}),r.source_id != nil else {throw ConversationMemoryError.invalidResponse}}
    }
}
public protocol ConversationMemoryBackend:Sendable {
    func close() async
    func readMemory(_ reference:ConversationMemoryReference) async throws -> ConversationMemorySnapshot
    func submitMemory(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt
    func readMemoryOperation(_ reference:ConversationMemoryReference,request:ConversationMemoryRequest) async throws -> ConversationMemoryReceipt
    func readMemorySource(_ reference:ConversationMemoryReference,id:UUID) async throws -> ConversationMemorySource
}
public enum ConversationMemoryCodec {
    public static let contract="catpaw.memory.v1"
    public static func encoded<T:Encodable>(_ value:T) throws -> Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)}
    public static func date(_ value:String)->Date? {let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.date(from:value) ?? ISO8601DateFormatter().date(from:value)}
    public static func isHash(_ value:String)->Bool {value.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil}
    public static func validateSource(_ source:ConversationMemorySource) throws {guard isHash(source.content_hash),date(source.occurred_at) != nil,["user_message","user_memory_command"].contains(source.type),source.trust=="user_direct",source.text.map({$0.utf16.count<=8000}) ?? true else {throw ConversationMemoryError.invalidResponse};if let text=source.text,source.deleted_at==nil {guard textHash(text)==source.content_hash else {throw ConversationMemoryError.invalidResponse}}}
}


/// A proposal receipt contains immutable references only. It never confirms a
/// memory, creates a task, or carries model-supplied memory values into the UI.
public struct ConversationMemoryProposalReceipt:Codable,Sendable,Equatable {
    public struct Candidate:Codable,Sendable,Equatable,Identifiable {public let id:UUID,version:Int}
    public let schema_version:Int,contract:String,scope_id:UUID,conversation_id:UUID,turn_id:UUID,source_id:UUID,source_hash:String,memory_generation:Int,job_id:UUID,candidates:[Candidate],status:String,confirmed:Bool
    public static let contractName="catpaw.memory-proposal.v1"
    private static let keys:Set<String>=["schema_version","contract","scope_id","conversation_id","turn_id","source_id","source_hash","memory_generation","job_id","candidates","status","confirmed"]
    public static func decode(_ data:Data,request:ConversationTurnRequest?=nil,serverScopeID:UUID?=nil) throws -> Self {
        let object=try ConversationStrictJSON.object(data,maxBytes:16000)
        guard Set(object.keys)==keys,let rows=object["candidates"] as? [[String:Any]],rows.allSatisfy({Set($0.keys)==["id","version"]}) else {throw ConversationSessionError.invalidEvent}
        let value=try JSONDecoder().decode(Self.self,from:data)
        try value.validate(request:request,serverScopeID:serverScopeID);return value
    }
    public func validate(request:ConversationTurnRequest?=nil,serverScopeID:UUID?=nil) throws {
        guard schema_version==1,contract==Self.contractName,status=="proposed",confirmed==false,
              (1...9_007_199_254_740_991).contains(memory_generation),ConversationMemoryCodec.isHash(source_hash),
              candidates.count<=6,Set(candidates.map(\.id)).count==candidates.count,candidates.allSatisfy({(1...9_007_199_254_740_991).contains($0.version)}),
              serverScopeID==nil || scope_id==serverScopeID else {throw ConversationSessionError.invalidEvent}
        if let request {
            guard request.continuation==nil,request.image==nil,request.acceptedWork==nil,
                  conversation_id==request.conversationID,turn_id==request.operationID,
                  let user=request.history.last,user.role == .user,user.id==source_id,textHash(user.content)==source_hash else {throw ConversationSessionError.invalidEvent}
        }
    }
    public static func transcript(_ message:ConversationTranscriptMessage,session:ConversationSession,serverScopeID:UUID?=nil) throws -> Self {
        guard message.role == .tool,message.toolName=="propose_memory_v1",message.complete,message.failure==nil,let call=message.toolCallID else {throw ConversationSessionError.invalidEvent}
        let value=try decode(Data(message.content.utf8),serverScopeID:serverScopeID)
        guard value.conversation_id==session.conversationID,let turn=session.turns.first(where:{$0.id==value.turn_id}),
              turn.request.scope==session.scope,message.id==stableID("conversation-tool-result-\(value.turn_id)-\(call)") else {throw ConversationSessionError.invalidEvent}
        try value.validate(request:turn.request,serverScopeID:serverScopeID);return value
    }
}
