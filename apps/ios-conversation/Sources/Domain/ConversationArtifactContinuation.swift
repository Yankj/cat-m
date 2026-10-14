import Foundation

/// Explicit user choice. Model wording and ordinary context never acquire revision authority.
public enum ConversationArtifactContinuationMode:String,Codable,Sendable,Equatable {
    case reviseReport="revise_report",explainReport="explain_report"
}
public enum ConversationArtifactContinuationError:Error,LocalizedError {
    case invalidReference,missingPlan,unsupported,closed,staleDraft
    public var errorDescription:String? {
        switch self {
        case .invalidReference:return "这份成果的版本信息尚未核对，原输入会保留。"
        case .missingPlan:return "请先读取这项工作的最新计划，再选择要继续的成果版本。"
        case .unsupported:return "当前连接暂不支持针对成果继续，草稿已保留。"
        case .closed:return "当前会话已关闭，原输入会保留。"
        case .staleDraft:return "输入已更新，请保留当前内容后重试。"
        }
    }
}

/// Additive request target. Original task binding stays separate from the new conversation turn.
public struct ConversationArtifactContinuationIntent:Codable,Sendable,Equatable {
    public let intent:ConversationArtifactContinuationMode
    public let runID:UUID
    public let taskID:String
    public let artifactReference:ConversationArtifactVersionReference
    public let expectedGrantEpoch:Int
    public let expectedPlanRevision:Int
    public let expectedPlanHash:String
    private enum CodingKeys:String,CodingKey {
        case intent,runID="run_id",taskID="task_id",artifactReference="artifact_reference",expectedGrantEpoch="expected_grant_epoch",expectedPlanRevision="expected_plan_revision",expectedPlanHash="expected_plan_hash"
    }
    public init(intent:ConversationArtifactContinuationMode,runID:UUID,taskID:String,artifactReference:ConversationArtifactVersionReference,expectedGrantEpoch:Int,expectedPlanRevision:Int,expectedPlanHash:String) {
        self.intent=intent;self.runID=runID;self.taskID=taskID;self.artifactReference=artifactReference;self.expectedGrantEpoch=expectedGrantEpoch;self.expectedPlanRevision=expectedPlanRevision;self.expectedPlanHash=expectedPlanHash
    }
    public func validate() throws {
        guard Self.hash(taskID),Self.hash(artifactReference.artifactID),Self.hash(artifactReference.contentHash),artifactReference.version>0,
              expectedGrantEpoch>0,expectedPlanRevision>0,Self.hash(expectedPlanHash),
              [artifactReference.version,expectedGrantEpoch,expectedPlanRevision].allSatisfy({$0<=9_007_199_254_740_991}) else {throw ConversationArtifactContinuationError.invalidReference}
    }
    public var canonicalValue:[String:Any] {
        ["intent":intent.rawValue,"run_id":runID.uuidString.lowercased(),"task_id":taskID,"artifact_reference":["artifact_id":artifactReference.artifactID,"version":artifactReference.version,"content_hash":artifactReference.contentHash],"expected_grant_epoch":expectedGrantEpoch,"expected_plan_revision":expectedPlanRevision,"expected_plan_hash":expectedPlanHash]
    }
    private static func hash(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
}

/// Local, account-scoped selection. Titles are presentation; identity and expectations are immutable.
public struct ConversationArtifactContinuationReference:Codable,Sendable,Equatable,Identifiable {
    public let scope:DataScope
    public let subjectID:UUID
    public let goalID:String
    public let binding:ConversationTaskBinding
    public let artifactReference:ConversationArtifactVersionReference
    public let planReference:ConversationArtifactEditPlanReference?
    public let mode:ConversationArtifactContinuationMode
    public let taskTitle:String
    public let artifactTitle:String
    public var id:UUID {stableID("artifact-continuation:\(scope.workspaceID):\(subjectID):\(binding.scope_id):\(binding.run_id):\(binding.request_hash):\(binding.grant_epoch):\(artifactReference.artifactID):\(artifactReference.version):\(artifactReference.contentHash):\(planReference?.revision ?? 0):\(planReference?.planHash ?? "unconfirmed"):\(mode.rawValue)")}
    public init(scope:DataScope,subjectID:UUID,goalID:String,binding:ConversationTaskBinding,artifactReference:ConversationArtifactVersionReference,planReference:ConversationArtifactEditPlanReference?,mode:ConversationArtifactContinuationMode,taskTitle:String,artifactTitle:String) {
        self.scope=scope;self.subjectID=subjectID;self.goalID=goalID;self.binding=binding;self.artifactReference=artifactReference;self.planReference=planReference;self.mode=mode;self.taskTitle=taskTitle;self.artifactTitle=artifactTitle
    }
    public func validate(scope expectedScope:DataScope,subjectID expectedSubject:UUID,conversationID:UUID) throws {
        // Account partition UUID and real server scope UUID are intentionally distinct.
        guard scope==expectedScope,subjectID==expectedSubject,binding.conversation_id==conversationID,
              !goalID.isEmpty,goalID.utf16.count<=400,taskTitle.utf16.count<=8000,artifactTitle.utf16.count<=8000,
              binding.delegation_revision>0,binding.grant_epoch>0 else {throw ConversationArtifactContinuationError.invalidReference}
        let plan=planReference ?? .init(revision:1,planHash:String(repeating:"0",count:64))
        try ConversationArtifactContinuationIntent(intent:mode,runID:binding.run_id,taskID:binding.task_id,artifactReference:artifactReference,expectedGrantEpoch:binding.grant_epoch,expectedPlanRevision:plan.revision,expectedPlanHash:plan.planHash).validate()
    }
    public func sendIntent() throws -> ConversationArtifactContinuationIntent {
        guard let planReference else {throw ConversationArtifactContinuationError.missingPlan}
        let value=ConversationArtifactContinuationIntent(intent:mode,runID:binding.run_id,taskID:binding.task_id,artifactReference:artifactReference,expectedGrantEpoch:binding.grant_epoch,expectedPlanRevision:planReference.revision,expectedPlanHash:planReference.planHash)
        try value.validate();return value
    }
}

public struct ConversationArtifactContinuationDraft:Codable,Sendable,Equatable {
    public let reference:ConversationArtifactContinuationReference
    public let raw:String
    public let editSequence:Int
    public init(reference:ConversationArtifactContinuationReference,raw:String,editSequence:Int) {self.reference=reference;self.raw=raw;self.editSequence=editSequence}
}
public struct ConversationArtifactContinuationComposerState:Codable,Sendable,Equatable {
    public var schemaVersion=1
    public var activeReferenceID:UUID?
    public var drafts:[String:ConversationArtifactContinuationDraft]=[:]
    public init() {}
    public var activeDraft:ConversationArtifactContinuationDraft? {activeReferenceID.flatMap{drafts[$0.uuidString.lowercased()]}}
}
