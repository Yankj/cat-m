import Foundation

public enum ConversationTaskPlanError: Error, LocalizedError, Sendable {
    case notConfigured, invalidResponse, busy, staleDraft,notEditable
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "计划服务尚未连接。修改草稿会保留。"
        case .invalidResponse: return "计划版本或对象不匹配，未记录生效。"
        case .busy: return "原修改正在核对，请先读取其结果。"
        case .staleDraft: return "计划已更新，修改草稿仍在。请核对新版本后继续。"
        case .notEditable:return "这项工作当前不能修改计划。草稿会保留。"
        }
    }
}
public struct ConversationTaskPlanReference: Identifiable, Sendable, Equatable {
    public var id: UUID { binding.run_id }
    public let scope: DataScope
    public let binding: ConversationTaskBinding
    public let title: String
    public init(scope: DataScope, binding: ConversationTaskBinding, title: String) { self.scope=scope;self.binding=binding;self.title=title }
}
public struct ConversationTaskPlanStep: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public init(id: String, title: String, detail: String) { self.id=id;self.title=title;self.detail=detail }
}
public struct ConversationTaskPlanContent: Codable, Sendable, Equatable {
    public var title: String
    public var goal: String
    public var requirements: String
    public var stopConditions: [String]
    public var steps: [ConversationTaskPlanStep]
    private enum CodingKeys: String, CodingKey { case title,goal,requirements,steps;case stopConditions="stop_conditions" }
    public init(title: String, goal: String, requirements: String, stopConditions: [String], steps: [ConversationTaskPlanStep]) {self.title=title;self.goal=goal;self.requirements=requirements;self.stopConditions=stopConditions;self.steps=steps}
    public func canonicalHash() throws -> String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return textHash(String(decoding:try encoder.encode(self),as:UTF8.self))
    }
    public func validate() throws {
        guard Self.hasNonWhitespace(title),title.utf16.count<=160,
              Self.hasNonWhitespace(goal),goal.utf16.count<=4000,
              requirements.utf16.count<=4000,
              !stopConditions.isEmpty,stopConditions.count<=10,stopConditions.allSatisfy({Self.hasNonWhitespace($0) && $0.utf16.count<=300}),
              steps.map(\.id)==["compose","save","verify"],steps.allSatisfy({Self.hasNonWhitespace($0.title) && $0.title.utf16.count<=200 && $0.detail.utf16.count<=4000}) else {throw ConversationTaskPlanError.invalidResponse}
    }
    /// Match the server's ECMAScript trim predicate, including BOM and excluding NEL.
    public static func hasNonWhitespace(_ value:String)->Bool {
        value.unicodeScalars.contains {scalar in
            switch scalar.value {
            case 0x0009...0x000D,0x0020,0x00A0,0x1680,0x2000...0x200A,0x2028,0x2029,0x202F,0x205F,0x3000,0xFEFF:return false
            default:return true
            }
        }
    }
}
public enum ConversationTaskPlanApplicationState: String, Codable, Sendable {case applied,pending;case blockedUnknown="blocked_unknown"}
public struct ConversationTaskPlanStepReceipt: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {case modelResponse="model_response",artifactSaved="artifact_saved",completionValidated="completion_validated"}
    public enum Status: String, Codable, Sendable {case succeeded}
    public let stepID:String
    public let planRevision:Int
    public let planHash:String
    public let status:Status
    public let receiptKind:Kind
    public let receiptHash:String
    public let createdAt:String
    private enum CodingKeys:String,CodingKey {case status;case stepID="step_id",planRevision="plan_revision",planHash="plan_hash",receiptKind="receipt_kind",receiptHash="receipt_hash",createdAt="created_at"}
    public init(stepID:String,planRevision:Int,planHash:String,status:Status = .succeeded,receiptKind:Kind,receiptHash:String,createdAt:String) {self.stepID=stepID;self.planRevision=planRevision;self.planHash=planHash;self.status=status;self.receiptKind=receiptKind;self.receiptHash=receiptHash;self.createdAt=createdAt}
}
public struct ConversationTaskPlanSnapshot: Codable, Sendable, Equatable {
    public let runID:UUID
    public let taskID:String
    public let conversationID:UUID
    public let acceptedRevision:Int
    public let acceptedPlanHash:String
    public let appliedRevision:Int
    public let appliedPlanHash:String
    public let applicationState:ConversationTaskPlanApplicationState
    public let taskStatus:String
    public let content:ConversationTaskPlanContent
    public let appliedContent:ConversationTaskPlanContent
    public let stepReceipts:[ConversationTaskPlanStepReceipt]
    private enum CodingKeys:String,CodingKey {case content;case runID="run_id",taskID="task_id",conversationID="conversation_id",acceptedRevision="accepted_revision",acceptedPlanHash="accepted_plan_hash",appliedRevision="applied_revision",appliedPlanHash="applied_plan_hash",applicationState="application_state",taskStatus="task_status",appliedContent="applied_content",stepReceipts="step_receipts"}
    public init(runID:UUID,taskID:String,conversationID:UUID,acceptedRevision:Int,acceptedPlanHash:String,appliedRevision:Int,appliedPlanHash:String,applicationState:ConversationTaskPlanApplicationState,taskStatus:String,content:ConversationTaskPlanContent,appliedContent:ConversationTaskPlanContent,stepReceipts:[ConversationTaskPlanStepReceipt]=[]) {self.runID=runID;self.taskID=taskID;self.conversationID=conversationID;self.acceptedRevision=acceptedRevision;self.acceptedPlanHash=acceptedPlanHash;self.appliedRevision=appliedRevision;self.appliedPlanHash=appliedPlanHash;self.applicationState=applicationState;self.taskStatus=taskStatus;self.content=content;self.appliedContent=appliedContent;self.stepReceipts=stepReceipts}
    public func validate(reference:ConversationTaskPlanReference) throws {
        try content.validate();try appliedContent.validate()
        guard runID==reference.binding.run_id,taskID==reference.binding.task_id,conversationID==reference.binding.conversation_id,
              appliedRevision>0,acceptedRevision>=appliedRevision,
              try content.canonicalHash()==acceptedPlanHash,try appliedContent.canonicalHash()==appliedPlanHash,
              ["queued","scheduled","running","waiting_input","waiting_approval","paused","succeeded","failed","cancelled","outcome_unknown"].contains(taskStatus),stepReceipts.count<=3,
              Set(stepReceipts.map(\.stepID)).count==stepReceipts.count,
              stepReceipts.allSatisfy({Self.validReceipt($0,revision:appliedRevision,hash:appliedPlanHash)}) else {throw ConversationTaskPlanError.invalidResponse}
        if applicationState == .applied {guard acceptedRevision==appliedRevision,acceptedPlanHash==appliedPlanHash,content==appliedContent else {throw ConversationTaskPlanError.invalidResponse}}
        if applicationState == .pending {guard acceptedRevision>appliedRevision else {throw ConversationTaskPlanError.invalidResponse}}
    }
    public var editable:Bool {applicationState == .applied && ["queued","scheduled","running","waiting_input","waiting_approval"].contains(taskStatus)}
    private static func validReceipt(_ receipt:ConversationTaskPlanStepReceipt,revision:Int,hash:String)->Bool {
        let kind:[String:ConversationTaskPlanStepReceipt.Kind]=["compose":.modelResponse,"save":.artifactSaved,"verify":.completionValidated]
        let format=ISO8601DateFormatter();format.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard !receipt.createdAt.hasPrefix("0000-"),receipt.createdAt.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$",options:.regularExpression) != nil,let date=format.date(from:receipt.createdAt),format.string(from:date)==receipt.createdAt else {return false}
        return kind[receipt.stepID]==receipt.receiptKind && receipt.planRevision==revision && receipt.planHash==hash && receipt.receiptHash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
    }
}
public struct ConversationTaskPlanAmendRequest: Codable, Sendable, Equatable {
    public let operationID:UUID
    public let expectedRevision:Int
    public let expectedPlanHash:String
    public let expectedGrantEpoch:Int
    public let content:ConversationTaskPlanContent
    private enum CodingKeys:String,CodingKey {case content;case operationID="operation_id",expectedRevision="expected_revision",expectedPlanHash="expected_plan_hash",expectedGrantEpoch="expected_grant_epoch"}
    public init(operationID:UUID,expectedRevision:Int,expectedPlanHash:String,expectedGrantEpoch:Int,content:ConversationTaskPlanContent) {self.operationID=operationID;self.expectedRevision=expectedRevision;self.expectedPlanHash=expectedPlanHash;self.expectedGrantEpoch=expectedGrantEpoch;self.content=content}
}
public struct ConversationTaskPlanAmendment: Codable, Sendable, Equatable {
    public let operationID:UUID
    public let state:ConversationTaskPlanApplicationState
    public let acceptedRevision:Int
    public let acceptedPlanHash:String
    private enum CodingKeys:String,CodingKey {case state;case operationID="operation_id",acceptedRevision="accepted_revision",acceptedPlanHash="accepted_plan_hash"}
    public init(operationID:UUID,state:ConversationTaskPlanApplicationState,acceptedRevision:Int,acceptedPlanHash:String) {self.operationID=operationID;self.state=state;self.acceptedRevision=acceptedRevision;self.acceptedPlanHash=acceptedPlanHash}
}
public struct ConversationTaskPlanEnvelope: Codable, Sendable {
    public let schemaVersion:Int
    public let contract:String
    public let plan:ConversationTaskPlanSnapshot
    public let amendment:ConversationTaskPlanAmendment?
    private enum CodingKeys:String,CodingKey {case contract,plan,amendment;case schemaVersion="schema_version"}
    public init(plan:ConversationTaskPlanSnapshot,amendment:ConversationTaskPlanAmendment?=nil) {self.schemaVersion=1;self.contract="catpaw.task-plan.v1";self.plan=plan;self.amendment=amendment}
}
public protocol ConversationTaskPlanBackend:Sendable {
    func readPlan(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanEnvelope
    func amendPlan(_ reference:ConversationTaskPlanReference,request:ConversationTaskPlanAmendRequest) async throws -> ConversationTaskPlanEnvelope
    func readAmendment(_ reference:ConversationTaskPlanReference,operationID:UUID) async throws -> ConversationTaskPlanEnvelope
}
public struct UnconfiguredConversationTaskPlanBackend:ConversationTaskPlanBackend {
    public init() {}
    public func readPlan(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanEnvelope {throw ConversationTaskPlanError.notConfigured}
    public func amendPlan(_ reference:ConversationTaskPlanReference,request:ConversationTaskPlanAmendRequest) async throws -> ConversationTaskPlanEnvelope {throw ConversationTaskPlanError.notConfigured}
    public func readAmendment(_ reference:ConversationTaskPlanReference,operationID:UUID) async throws -> ConversationTaskPlanEnvelope {throw ConversationTaskPlanError.notConfigured}
}
