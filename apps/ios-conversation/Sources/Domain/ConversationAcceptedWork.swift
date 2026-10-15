import Foundation
import CoreFoundation

public enum ConversationAcceptedWorkError:Error,LocalizedError,Sendable {
    case unavailable,invalidSelection,invalidFrozenIntent,expired,changedSnapshot
    public var errorDescription:String? {switch self {
    case .unavailable:return "后台尚不支持明确受理有限工作，原文已保留。"
    case .invalidSelection:return "本次工作范围或账号已变化，请重新核对后确认。"
    case .invalidFrozenIntent:return "原有限请求与保存的范围不匹配，未重新发送。"
    case .expired:return "原工作期限已到或不足以覆盖执行预算，未扩大期限。"
    case .changedSnapshot:return "原对话版本或授权已变化，未修改原有限请求。"
    }}
}
public enum ConversationAcceptedWorkToolPolicy:String,Codable,Sendable {case localOutput="local_output_v1",publicSources="public_sources_v1"}
/// Explicit values chosen by the user. The bounds are ceilings, never consent or defaults.
public struct ConversationAcceptedWorkOptions:Codable,Sendable,Equatable {
    public var notAfter:Date
    public var executionBudgetMilliseconds:Int
    public var modelLimit:Int
    public var sourceLimit:Int
    public var toolPolicy:ConversationAcceptedWorkToolPolicy
    public init(notAfter:Date,executionBudgetMilliseconds:Int,modelLimit:Int,sourceLimit:Int,toolPolicy:ConversationAcceptedWorkToolPolicy) {self.notAfter=notAfter;self.executionBudgetMilliseconds=executionBudgetMilliseconds;self.modelLimit=modelLimit;self.sourceLimit=sourceLimit;self.toolPolicy=toolPolicy}
    public func validate(now:Date?=nil) throws {
        guard notAfter.timeIntervalSince1970.isFinite,notAfter.timeIntervalSince1970>=0,notAfter.timeIntervalSince1970<4_133_980_800,
              (1...300_000).contains(executionBudgetMilliseconds),(0...20).contains(modelLimit),(0...12).contains(sourceLimit),toolPolicy != .localOutput || sourceLimit==0 else {throw ConversationAcceptedWorkError.invalidSelection}
        if let now {
            let deadline=try ConversationAcceptedWorkCodec.instant(ConversationAcceptedWorkCodec.utc(notAfter)),window=deadline.timeIntervalSince(now)*1000
            guard window>0,window<=86_400_000,Double(executionBudgetMilliseconds)<=window else {throw ConversationAcceptedWorkError.expired}
        }
    }
}
public struct ConversationAcceptedWorkCapability:Sendable,Equatable {
    public let available:Bool
    public let routeHash:String?
    public let subjectID:UUID?
    public let serverScopeID:UUID?
    public let publicSourcesAvailable:Bool
    public var maxBudgetMilliseconds:Int {300_000}
    public var maxModel:Int {20}
    public var maxSource:Int {12}
    public var maxLifetimeSeconds:Int {86_400}
    public init(available:Bool=false,routeHash:String?=nil,subjectID:UUID?=nil,serverScopeID:UUID?=nil,publicSourcesAvailable:Bool=false) {self.available=available;self.routeHash=routeHash;self.subjectID=subjectID;self.serverScopeID=serverScopeID;self.publicSourcesAvailable=publicSourcesAvailable}
}
/// Durable confirmation binding. It is separate from model-processing consent.
public struct ConversationAcceptedWorkSelection:Codable,Sendable,Equatable {
    public let decisionID:UUID
    public let options:ConversationAcceptedWorkOptions
    public let routeHash:String
    public let subjectID:UUID
    public let serverScopeID:UUID
    public init(decisionID:UUID,options:ConversationAcceptedWorkOptions,capability:ConversationAcceptedWorkCapability) throws {
        guard capability.available,let routeHash=capability.routeHash,let subjectID=capability.subjectID,let serverScopeID=capability.serverScopeID,options.toolPolicy != .publicSources || capability.publicSourcesAvailable else {throw ConversationAcceptedWorkError.unavailable}
        try options.validate();guard ConversationTaskActionValidation.hash(routeHash) else {throw ConversationAcceptedWorkError.invalidSelection}
        self.decisionID=decisionID;self.options=options;self.routeHash=routeHash;self.subjectID=subjectID;self.serverScopeID=serverScopeID
    }
    public func validate(capability:ConversationAcceptedWorkCapability,now:Date) throws {
        try options.validate(now:now)
        guard capability.available,capability.routeHash==routeHash,capability.subjectID==subjectID,capability.serverScopeID==serverScopeID,options.toolPolicy != .publicSources || capability.publicSourcesAvailable else {throw ConversationAcceptedWorkError.invalidSelection}
    }
}
/// Exact turn JSON and decision are frozen before the request journal's first POST.
/// Reading this Codable value cannot grant work or allocate another operation.
public struct ConversationAcceptedWorkIntent:Codable,Sendable,Equatable {
    public let contract:String
    public let selection:ConversationAcceptedWorkSelection
    public let localScope:DataScope
    public let conversationID,operationID:UUID
    public let expectedRevision,expectedGrantEpoch:Int
    public let turnBody:ConversationTaskActionJSON
    public let inputHash:String
    public init(request:ConversationTurnRequest,selection:ConversationAcceptedWorkSelection,expectedRevision:Int,expectedGrantEpoch:Int) throws {
        try selection.options.validate()
        let turn=try ConversationAcceptedWorkCodec.turn(request,revision:expectedRevision,grant:expectedGrantEpoch)
        contract=ConversationAcceptedWorkCodec.contract;self.selection=selection;localScope=request.scope;conversationID=request.conversationID;operationID=request.operationID;self.expectedRevision=expectedRevision;self.expectedGrantEpoch=expectedGrantEpoch;turnBody=turn;inputHash=try turn.digest()
    }
    public var work:ConversationTaskActionJSON {get throws {
        try selection.options.validate()
        return .object(["decision_id":.string(selection.decisionID.uuidString.lowercased()),"input_hash":.string(inputHash),"route_hash":.string(selection.routeHash),"tool_policy":.string(selection.options.toolPolicy.rawValue),"not_after":.string(ConversationAcceptedWorkCodec.utc(selection.options.notAfter)),"execution_budget_ms":.integer(selection.options.executionBudgetMilliseconds),"limits":.object(["due":.integer(1),"model":.integer(selection.options.modelLimit),"source":.integer(selection.options.sourceLimit)])])
    }}
    public func validate(request:ConversationTurnRequest) throws {
        guard contract==ConversationAcceptedWorkCodec.contract,localScope==request.scope,conversationID==request.conversationID,operationID==request.operationID,
              ConversationTaskActionValidation.hash(selection.routeHash),ConversationTaskActionValidation.hash(inputHash),selection.decisionID != operationID,
              inputHash==(try turnBody.digest()),inputHash==(try ConversationAcceptedWorkCodec.turn(request,revision:expectedRevision,grant:expectedGrantEpoch).digest()) else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        try selection.options.validate()
        _=try wrapper()
    }
    public func wrapper() throws -> Data {
        let value=ConversationTaskActionJSON.object(["schema_version":.integer(1),"contract":.string(contract),"turn":turnBody,"work":try work])
        let data=try ConversationTaskActionJSON.encoded(value);guard data.count<=42_000 else {throw ConversationAcceptedWorkError.invalidFrozenIntent};return data
    }
}
public enum ConversationAcceptedWorkCodec {
    public static let contract="catpaw.accepted-work-intent.v1",grantContract="catpaw.task-work-grant.v1"
    public static func utc(_ date:Date)->String {let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];f.timeZone=TimeZone(secondsFromGMT:0);return f.string(from:date)}
    public static func instant(_ value:String) throws -> Date {guard let d=ConversationTaskActionValidation.utc(value),utc(d)==value,d.timeIntervalSince1970>=0,d.timeIntervalSince1970<4_133_980_800 else {throw ConversationAcceptedWorkError.invalidFrozenIntent};return d}
    static func turn(_ request:ConversationTurnRequest,revision:Int,grant:Int) throws -> ConversationTaskActionJSON {
        guard ConversationTaskActionValidation.positive(revision),ConversationTaskActionValidation.positive(grant),request.image==nil,request.imageBytes==nil,request.continuation==nil,request.continuationOriginalBinding==nil,request.continuationSubjectID==nil,
              let message=request.history.last,message.role == .user,message.id != request.operationID,!message.content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,message.content.utf16.count<=8000,
              request.context.count<=8,Set(request.context.map(\.id)).count==request.context.count,request.context.allSatisfy({!$0.id.isEmpty && $0.id.utf16.count<=80 && $0.text.utf16.count<=8000}) else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        let value=ConversationTaskActionJSON.object(["turn_id":.string(request.operationID.uuidString.lowercased()),"expected_revision":.integer(revision),"expected_grant_epoch":.integer(grant),"message":.object(["id":.string(message.id.uuidString.lowercased()),"text":.string(message.content)]),"context":.array(request.context.map{.object(["id":.string($0.id),"text":.string($0.text)])})])
        guard try ConversationTaskActionJSON.encoded(value).count<=40_000 else {throw ConversationAcceptedWorkError.invalidFrozenIntent};return value
    }
    private static func boolean(_ raw:Any?)->Bool? {guard let n=raw as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {return nil};return n.boolValue}
    public static func capability(readiness:Data,modelRoute:Data,subjectID:UUID,serverScopeID:UUID) throws -> ConversationAcceptedWorkCapability {
        let ready=try ConversationStrictJSON.object(readiness,maxBytes:128_000),metadata=try ConversationStrictJSON.object(modelRoute,maxBytes:128_000)
        guard let schema=ready["schema_version"] as? NSNumber,CFGetTypeID(schema) != CFBooleanGetTypeID(),schema.doubleValue==1,boolean(ready["ready"])==true,
              let caps=ready["chat_capabilities"] as? [String:Any],let capSchema=caps["schema_version"] as? NSNumber,CFGetTypeID(capSchema) != CFBooleanGetTypeID(),capSchema.doubleValue==1,let work=caps["accepted_work"] as? [String:Any],work["contract"] as? String==contract,work["grant_contract"] as? String==grantContract,
              boolean(work["enabled"])==true,boolean(work["single_run"])==true,boolean(work["limits_explicit"])==true,boolean(work["unknown_resend"])==false,work["execution"] as? String=="bounded_single_step_v1",
              let metadataSchema=metadata["schema_version"] as? NSNumber,CFGetTypeID(metadataSchema) != CFBooleanGetTypeID(),metadataSchema.doubleValue==1,let route=metadata["route"] as? [String:Any],let hash=metadata["route_hash"] as? String,ConversationTaskActionValidation.hash(hash),
              let routeID=route["id"] as? String,!routeID.isEmpty,routeID.utf8.count<=128,ready["model_route"] as? String==routeID,boolean(route["free"])==true,let policy=route["routing_policy"] as? [String:Any],boolean(policy["allow_fallbacks"])==false,
              metadata["consent_default"] as? String=="deny",boolean(metadata["sensitive_confirmation_default"])==false,
              hash==(try ConversationDeviceEffectsCodec.canonicalHashJSON(JSONSerialization.data(withJSONObject:route,options:[.sortedKeys,.withoutEscapingSlashes]))) else {return .init()}
        let sources=caps["public_sources"] as? [String:Any]
        let publicAvailable=boolean(sources?["enabled"])==true && boolean(sources?["limited_to_user_urls"])==true && ConversationTaskActionValidation.hash(sources?["policy_hash"] as? String ?? "")
        return .init(available:true,routeHash:hash,subjectID:subjectID,serverScopeID:serverScopeID,publicSourcesAvailable:publicAvailable)
    }
    public static func validateOriginal(_ turn:[String:Any],request:ConversationTurnRequest) throws {
        guard let intent=request.acceptedWork else {return};try intent.validate(request:request)
        guard let frozen=turn["work_intent"] as? [String:Any],Set(frozen.keys)==Set(["schema_version","contract","decision_id","input_hash","route_hash","tool_policy","not_after","execution_budget_ms","limits","subject_id","scope_id","conversation_id","conversation_epoch","turn_id","message_id","admitted_at"]),
              let admitted=frozen["admitted_at"] as? String,let epoch=frozen["conversation_epoch"] as? NSNumber,CFGetTypeID(epoch) != CFBooleanGetTypeID(),epoch.doubleValue==Double(intent.expectedGrantEpoch),
              frozen["subject_id"] as? String==intent.selection.subjectID.uuidString.lowercased(),frozen["scope_id"] as? String==intent.selection.serverScopeID.uuidString.lowercased(),frozen["conversation_id"] as? String==request.conversationID.uuidString.lowercased(),frozen["turn_id"] as? String==request.operationID.uuidString.lowercased(),frozen["message_id"] as? String==request.history.last?.id.uuidString.lowercased() else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        var expected=try intent.work.decoded([String:ConversationTaskActionJSON].self)
        expected["schema_version"] = .integer(1);expected["contract"] = .string(contract);expected["subject_id"] = .string(intent.selection.subjectID.uuidString.lowercased());expected["scope_id"] = .string(intent.selection.serverScopeID.uuidString.lowercased());expected["conversation_id"] = .string(request.conversationID.uuidString.lowercased());expected["conversation_epoch"] = .integer(intent.expectedGrantEpoch);expected["turn_id"] = .string(request.operationID.uuidString.lowercased());expected["message_id"] = .string(request.history.last!.id.uuidString.lowercased());expected["admitted_at"] = .string(admitted)
        guard try ConversationDeviceEffectsCodec.canonicalHashJSON(JSONSerialization.data(withJSONObject:frozen,options:[.sortedKeys,.withoutEscapingSlashes]))==ConversationTaskActionJSON.object(expected).digest() else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        let acceptedAt=try instant(admitted);try intent.selection.options.validate(now:acceptedAt)
    }
}
