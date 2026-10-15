import Foundation

/// A new reviewed decision for one exact revision. This is never inherited from
/// the original task's work grant and has no defaults that expand its scope.
public struct ConversationRevisionWorkSelection:Codable,Sendable,Equatable {
    public let authorization:ConversationAcceptedWorkSelection
    public let target:ConversationArtifactContinuationIntent
    public let originalText:String
    public let instructionHash:String,targetHash:String
    public var decisionID:UUID {authorization.decisionID}
    public var options:ConversationAcceptedWorkOptions {authorization.options}
    public init(authorization:ConversationAcceptedWorkSelection,target:ConversationArtifactContinuationIntent,originalText:String) throws {
        self.authorization=authorization;self.target=target;self.originalText=originalText
        instructionHash=textHash(originalText);targetHash=try ConversationRevisionWorkCodec.hash(ConversationRevisionWorkCodec.target(target))
        try validate()
    }
    public func validate() throws {
        try target.validate();try options.validate()
        guard target.intent == .reviseReport,!originalText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,originalText.utf16.count<=8000,
              ConversationTaskActionValidation.hash(authorization.routeHash),instructionHash==textHash(originalText),
              targetHash==(try ConversationRevisionWorkCodec.hash(ConversationRevisionWorkCodec.target(target))) else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
    }
    public func validate(capability:ConversationAcceptedWorkCapability,now:Date) throws {
        try validate();try authorization.validate(capability:capability,now:now)
    }
}

/// All material that will be sent is immutable before the first POST. Restoring
/// an unknown request validates these same bytes without renewing its deadline.
public struct ConversationRevisionWorkIntent:Codable,Sendable,Equatable {
    public let contract:String
    public let selection:ConversationRevisionWorkSelection
    public let localScope:DataScope
    public let conversationID,operationID:UUID
    public let expectedRevision,expectedGrantEpoch:Int
    public let originalBinding:ConversationTaskBinding
    public let turnBody,targetBody:ConversationTaskActionJSON
    public let inputHash,targetHash:String
    public init(request:ConversationTurnRequest,selection:ConversationRevisionWorkSelection,expectedRevision:Int,expectedGrantEpoch:Int) throws {
        try selection.validate()
        guard let binding=request.continuationOriginalBinding else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        contract=ConversationRevisionWorkCodec.contract;self.selection=selection;localScope=request.scope;conversationID=request.conversationID;operationID=request.operationID
        self.expectedRevision=expectedRevision;self.expectedGrantEpoch=expectedGrantEpoch;originalBinding=binding
        turnBody=try ConversationRevisionWorkCodec.turn(request,revision:expectedRevision,grant:expectedGrantEpoch)
        targetBody=try ConversationRevisionWorkCodec.target(selection.target);targetHash=selection.targetHash
        inputHash=try ConversationRevisionWorkCodec.hash(.object(["turn":turnBody,"target":targetBody]))
        try validate(request:request)
    }
    public var work:ConversationTaskActionJSON {get throws {
        try selection.validate()
        let a=selection.authorization,o=a.options
        return .object(["decision_id":.string(a.decisionID.uuidString.lowercased()),"input_hash":.string(inputHash),"route_hash":.string(a.routeHash),"tool_policy":.string(o.toolPolicy.rawValue),"not_after":.string(ConversationAcceptedWorkCodec.utc(o.notAfter)),"execution_budget_ms":.integer(o.executionBudgetMilliseconds),"limits":.object(["due":.integer(1),"model":.integer(o.modelLimit),"source":.integer(o.sourceLimit)])])
    }}
    public var workIntentHash:String {get throws {try ConversationRevisionWorkCodec.hash(work)}}
    public func validate(request:ConversationTurnRequest) throws {
        try validateFrozen()
        guard request.scope==localScope,request.conversationID==conversationID,request.operationID==operationID,
              request.image==nil,request.imageBytes==nil,request.acceptedWork==nil,request.continuation==selection.target,
              request.continuationOriginalBinding==originalBinding,request.continuationSubjectID==selection.authorization.subjectID,
              request.history.last?.content.utf8.elementsEqual(selection.originalText.utf8)==true,
              inputHash==(try ConversationRevisionWorkCodec.hash(.object(["turn":try ConversationRevisionWorkCodec.turn(request,revision:expectedRevision,grant:expectedGrantEpoch),"target":try ConversationRevisionWorkCodec.target(selection.target)]))) else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
    }
    /// First dispatch requires a currently valid, explicitly reviewed window.
    /// Original GET and receipt validation must use validate(request:) instead.
    public func validateForFirstPost(request:ConversationTurnRequest,capability:ConversationAcceptedWorkCapability,now:Date) throws {
        try validate(request:request);try selection.validate(capability:capability,now:now)
    }
    public func wrapper() throws -> Data {
        try validateFrozen()
        return try ConversationRevisionWorkCodec.data(.object(["schema_version":.integer(1),"contract":.string(contract),"turn":turnBody,"target":targetBody,"work":try work]))
    }
    public static func restore(_ data:Data,request:ConversationTurnRequest) throws -> Self {
        _=try ConversationStrictJSON.object(data,maxBytes:160_000)
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate(request:request);return value
    }
    private func validateFrozen() throws {
        try selection.validate();try ConversationRevisionWorkCodec.validateTurn(turnBody,operationID:operationID,originalText:selection.originalText,revision:expectedRevision,grant:expectedGrantEpoch)
        let a=selection.authorization,b=originalBinding,t=selection.target
        guard contract==ConversationRevisionWorkCodec.contract,b.scope_id==a.serverScopeID,b.conversation_id==conversationID,b.run_id==t.runID,b.task_id==t.taskID,b.grant_epoch==t.expectedGrantEpoch,ConversationTaskActionValidation.positive(b.delegation_revision),ConversationTaskActionValidation.hash(b.request_hash),!b.call_id.isEmpty,b.call_id.utf8.count<=256,
              ![operationID,conversationID,b.turn_id,b.delegation_id,b.operation_id,b.run_id].contains(a.decisionID),operationID != b.turn_id,operationID != b.operation_id,
              targetHash==selection.targetHash,targetHash==(try ConversationRevisionWorkCodec.hash(targetBody)),targetBody==(try ConversationRevisionWorkCodec.target(t)),
              inputHash==(try ConversationRevisionWorkCodec.hash(.object(["turn":turnBody,"target":targetBody]))) else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
    }
}

public struct ConversationRevisionWorkGrantReference:Codable,Sendable,Equatable {
    public let schema_version:Int,contract:String,grant_id:UUID,terms_hash:String
    public init(grantID:UUID,termsHash:String) throws {schema_version=2;contract=ConversationRevisionWorkCodec.grantContract;grant_id=grantID;terms_hash=termsHash;try validate()}
    public func validate() throws {guard schema_version==2,contract==ConversationRevisionWorkCodec.grantContract,ConversationTaskActionValidation.hash(terms_hash) else {throw ConversationSessionError.invalidEvent}}
}

/// An outer work receipt binds the new decision and grant to the existing v1
/// revision receipt. Dynamic revision state never changes its immutable digest.
public struct ConversationRevisionWorkReceipt:Codable,Sendable,Equatable {
    public let schema_version:Int,contract:String,decision_id:UUID,input_hash:String,target_hash:String,work_intent_hash:String
    public let revision:ConversationTaskRevisionReceipt
    public let grant_reference:ConversationRevisionWorkGrantReference
    public let grant_receipt_hash:String,receipt_hash:String
    private static let keys:Set<String>=["schema_version","contract","decision_id","input_hash","target_hash","work_intent_hash","revision","grant_reference","grant_receipt_hash","receipt_hash"]
    public static func decode(_ data:Data) throws -> Self {
        let raw=try ConversationStrictJSON.object(data,maxBytes:32000),required=ConversationTaskRevisionReceipt.immutableKeys.union(["receipt_hash","state"])
        guard Set(raw.keys)==keys,let grant=raw["grant_reference"] as? [String:Any],Set(grant.keys)==["schema_version","contract","grant_id","terms_hash"],
              let revision=raw["revision"] as? [String:Any],required.isSubset(of:Set(revision.keys)),Set(revision.keys).isSubset(of:required.union(["result_reference","result_receipt_hash"])) else {throw ConversationSessionError.invalidEvent}
        for key in ["base_reference","result_reference"] {
            if let value=revision[key],!(value is NSNull) {guard let reference=value as? [String:Any],Set(reference.keys)==["artifact_id","version","content_hash"] else {throw ConversationSessionError.invalidEvent}}
        }
        for key in ["base_plan_reference","accepted_plan_reference"] {guard let reference=revision[key] as? [String:Any],Set(reference.keys)==["revision","plan_hash"] else {throw ConversationSessionError.invalidEvent}}
        return try JSONDecoder().decode(Self.self,from:data)
    }
    public func immutableHash() throws -> String {
        guard case .object(var fields)=try ConversationTaskActionJSON.value(self) else {throw ConversationSessionError.invalidEvent}
        fields.removeValue(forKey:"receipt_hash");fields.removeValue(forKey:"revision");fields["revision_receipt_hash"] = .string(revision.receipt_hash)
        // Protocol UUID values use the same lowercase form as request/target
        // identities. JSONEncoder's native UUID spelling is uppercase.
        fields["decision_id"] = .string(decision_id.uuidString.lowercased())
        fields["grant_reference"] = .object(["schema_version":.integer(grant_reference.schema_version),"contract":.string(grant_reference.contract),"grant_id":.string(grant_reference.grant_id.uuidString.lowercased()),"terms_hash":.string(grant_reference.terms_hash)])
        return try ConversationRevisionWorkCodec.hash(.object(fields))
    }
    public func validate(request:ConversationTurnRequest,intent:ConversationRevisionWorkIntent,callID:String,sourceAuthHash:String?=nil) throws {
        try intent.validate(request:request);try grant_reference.validate();try revision.validate(request:request,callID:callID,sourceAuthHash:sourceAuthHash)
        guard schema_version==1,contract==ConversationRevisionWorkCodec.contract,decision_id==intent.selection.decisionID,grant_reference.grant_id==decision_id,
              input_hash==intent.inputHash,target_hash==intent.targetHash,work_intent_hash==(try intent.workIntentHash),
              [input_hash,target_hash,work_intent_hash,grant_receipt_hash,receipt_hash].allSatisfy(ConversationTaskActionValidation.hash),
              try immutableHash()==receipt_hash else {throw ConversationSessionError.invalidEvent}
    }
}
public enum ConversationRevisionWorkCodec {
    public static let contract="catpaw.task-revision-work.v1",grantContract="catpaw.task-work-grant.v2",toolName="revise_current_report_work_v1",maxWrapperBytes=48000
    static func data(_ value:ConversationTaskActionJSON) throws -> Data {try ConversationCanonicalJSON.data(ConversationTaskActionJSON.encoded(value),maxBytes:maxWrapperBytes)}
    static func hash(_ value:ConversationTaskActionJSON) throws -> String {bytesHash(try data(value))}
    static func target(_ target:ConversationArtifactContinuationIntent) throws -> ConversationTaskActionJSON {
        try target.validate();guard target.intent == .reviseReport else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        return try JSONDecoder().decode(ConversationTaskActionJSON.self,from:JSONSerialization.data(withJSONObject:target.canonicalValue,options:[.sortedKeys,.withoutEscapingSlashes]))
    }
    static func turn(_ request:ConversationTurnRequest,revision:Int,grant:Int) throws -> ConversationTaskActionJSON {
        guard request.image==nil,request.imageBytes==nil,request.acceptedWork==nil,request.continuation?.intent == .reviseReport,request.continuationOriginalBinding != nil,request.continuationSubjectID != nil,
              let message=request.history.last,message.role == .user else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        let value=ConversationTaskActionJSON.object(["turn_id":.string(request.operationID.uuidString.lowercased()),"expected_revision":.integer(revision),"expected_grant_epoch":.integer(grant),"message":.object(["id":.string(message.id.uuidString.lowercased()),"text":.string(message.content)]),"context":.array(request.context.map{.object(["id":.string($0.id),"text":.string($0.text)])})])
        try validateTurn(value,operationID:request.operationID,originalText:message.content,revision:revision,grant:grant);return value
    }
    static func validateTurn(_ value:ConversationTaskActionJSON,operationID:UUID,originalText:String,revision:Int,grant:Int) throws {
        guard ConversationTaskActionValidation.positive(revision),ConversationTaskActionValidation.positive(grant),case .object(let turn)=value,
              Set(turn.keys)==["turn_id","expected_revision","expected_grant_epoch","message","context"],turn["turn_id"] == .string(operationID.uuidString.lowercased()),turn["expected_revision"] == .integer(revision),turn["expected_grant_epoch"] == .integer(grant),
              case .object(let message)=turn["message"],Set(message.keys)==["id","text"],case .string(let id)=message["id"],ConversationTaskActionValidation.uuid(id),id != operationID.uuidString.lowercased(),
              case .string(let text)=message["text"],text.utf8.elementsEqual(originalText.utf8),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf16.count<=8000,
              case .array(let context)=turn["context"],context.count<=8,try ConversationTaskActionJSON.encoded(value).count<=40000 else {throw ConversationAcceptedWorkError.invalidFrozenIntent}
        var seen=Set<String>()
        for row in context {guard case .object(let item)=row,Set(item.keys)==["id","text"],case .string(let id)=item["id"],!id.isEmpty,id.utf16.count<=80,seen.insert(id).inserted,case .string(let text)=item["text"],text.utf16.count<=8000 else {throw ConversationAcceptedWorkError.invalidFrozenIntent}}
    }
}
