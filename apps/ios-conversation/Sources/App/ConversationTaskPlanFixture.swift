#if DEBUG
import Foundation

/// Explicit offline UI-test fixture. Not a production provider or fallback.
actor ConversationTaskPlanFixtureBackend:ConversationTaskPlanBackend {
    enum Mode:String {case applied,pending,unknown}
    private let mode:Mode
    private var plans:[UUID:ConversationTaskPlanSnapshot]=[:]
    private var receipts:[UUID:ConversationTaskPlanEnvelope]=[:]
    private var postIDs:[UUID]=[]
    private var readIDs:[UUID]=[]
    init(mode:Mode = .applied) {self.mode=mode}
    func readPlan(_ reference:ConversationTaskPlanReference) async throws -> ConversationTaskPlanEnvelope {.init(plan:try snapshot(reference))}
    func amendPlan(_ reference:ConversationTaskPlanReference,request:ConversationTaskPlanAmendRequest) async throws -> ConversationTaskPlanEnvelope {
        if let existing=receipts[request.operationID] {return existing}
        let previous=try snapshot(reference)
        guard previous.acceptedRevision==request.expectedRevision,previous.acceptedPlanHash==request.expectedPlanHash,request.expectedGrantEpoch==reference.binding.grant_epoch else {throw catError.conflict}
        try request.content.validate();postIDs.append(request.operationID)
        let state:ConversationTaskPlanApplicationState=mode == .applied ? .applied : (mode == .pending ? .pending : .blockedUnknown)
        let hash=try request.content.canonicalHash(),revision=previous.acceptedRevision+1
        let next=ConversationTaskPlanSnapshot(runID:reference.id,taskID:reference.binding.task_id,conversationID:reference.binding.conversation_id,acceptedRevision:revision,acceptedPlanHash:hash,appliedRevision:mode == .applied ? revision : previous.appliedRevision,appliedPlanHash:mode == .applied ? hash : previous.appliedPlanHash,applicationState:state,taskStatus:"scheduled",content:request.content,appliedContent:mode == .applied ? request.content : previous.appliedContent)
        let envelope=ConversationTaskPlanEnvelope(plan:next,amendment:.init(operationID:request.operationID,state:state,acceptedRevision:revision,acceptedPlanHash:hash))
        plans[reference.id]=next;receipts[request.operationID]=envelope
        if mode == .unknown {throw catError.unavailable("明确离线测试：修改响应中断，仅核对原操作。")}
        return envelope
    }
    func readAmendment(_ reference:ConversationTaskPlanReference,operationID:UUID) async throws -> ConversationTaskPlanEnvelope {
        readIDs.append(operationID);guard let envelope=receipts[operationID],envelope.plan.runID==reference.id else {throw catError.missing};return envelope
    }
    func counts()->([UUID],[UUID]) {(postIDs,readIDs)}
    private func snapshot(_ reference:ConversationTaskPlanReference) throws -> ConversationTaskPlanSnapshot {
        if let existing=plans[reference.id] {return existing}
        let content=ConversationTaskPlanContent(title:reference.title,goal:"使用给定虚构资料整理本地报告。",requirements:"仅使用对话中的虚构资料，标明人工假设。",stopConditions:["保存报告并核对完成条件后停止。"],steps:[.init(id:"compose",title:"撰写报告",detail:"使用给定信息整理结论。"),.init(id:"save",title:"保存成果",detail:"保存同一工作的报告版本。"),.init(id:"verify",title:"核验完成",detail:"核对成果与结束条件。")])
        let hash=try content.canonicalHash()
        let value=ConversationTaskPlanSnapshot(runID:reference.id,taskID:reference.binding.task_id,conversationID:reference.binding.conversation_id,acceptedRevision:1,acceptedPlanHash:hash,appliedRevision:1,appliedPlanHash:hash,applicationState:.applied,taskStatus:"scheduled",content:content,appliedContent:content)
        plans[reference.id]=value;return value
    }
}
#endif
