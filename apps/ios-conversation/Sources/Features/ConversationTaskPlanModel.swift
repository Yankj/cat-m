import Foundation
import Combine

@MainActor final class ConversationTaskPlanModel:ObservableObject {
    let service:ConversationTaskPlanService
    let reference:ConversationTaskPlanReference
    @Published private(set) var state=ConversationTaskPlanLocalState()
    @Published private(set) var loading=false
    @Published private(set) var submitting=false
    @Published private(set) var freshlyRead=false
    @Published private(set) var editing=false
    @Published private(set) var draftSaved=true
    @Published private(set) var draftSaveIssue:String?
    @Published var goal=""
    @Published var requirements=""
    @Published var error:String?
    private var saves:Task<Void,Never>?
    private var readGeneration=0
    private var editSequence=0
    private let draftDrainID=UUID()
    @Published private(set) var tearingDown=false
    init(service:ConversationTaskPlanService,reference:ConversationTaskPlanReference) {
        self.service=service;self.reference=reference
        _=service.localDraftDrains.register(draftDrainID,scope:reference.scope){[weak self] in await self?.drainAcceptedLocalDrafts() ?? true}
    }
    deinit {service.localDraftDrains.unregister(draftDrainID)}
    var hasConflict:Bool {guard let draft=state.draft,let plan=state.snapshot else {return false};return draft.baseRevision != plan.acceptedRevision || draft.basePlanHash != plan.acceptedPlanHash}
    var canEdit:Bool {!tearingDown && service.localDraftDrains.accepts(draftDrainID) && state.snapshot?.editable==true && !state.hasUnresolvedSubmission}
    var wireValidationMessage:String? {
        if goal.utf16.count>4000 {return "目标最多 4000 字，修改草稿已保留。请缩短后保存修改。"}
        if requirements.utf16.count>4000 {return "具体要求最多 4000 字，修改草稿已保留。请缩短后保存修改。"}
        return nil
    }
    var preventDismiss:Bool {editing && !draftSaved}
    var canSubmit:Bool {canEdit && freshlyRead && !loading && !submitting && !hasConflict && draftSaved && ConversationTaskPlanContent.hasNonWhitespace(goal) && wireValidationMessage==nil}
    func load(admissionAllowed:Bool=true) async {
        guard !loading,!tearingDown,service.localDraftDrains.accepts(draftDrainID) else {return};readGeneration += 1;let generation=readGeneration
        loading=true;defer{if generation==readGeneration {loading=false}}
        await flushDraft()
        await service.setAdmissionAllowed(admissionAllowed)
        do {
            let localSequence=editSequence
            let local=try await service.localState(reference)
            receive(local,preserveLocalDraft:editing || localSequence != editSequence)
            guard admissionAllowed else {freshlyRead=false;return}
            let fetchSequence=editSequence
            let latest=try await service.refresh(reference)
            guard generation==readGeneration else {return};receive(latest,preserveLocalDraft:editing || fetchSequence != editSequence);freshlyRead=true;error=nil
        } catch {if generation==readGeneration {freshlyRead=false;self.error=error.localizedDescription}}
    }
    func beginEditing() {
        guard canEdit,let plan=state.snapshot else {return}
        editing=true
        if state.draft==nil {goal=plan.content.goal;requirements=plan.content.requirements}
        stageDraft()
    }
    @discardableResult func stageDraft() -> Bool {
        guard editing,!tearingDown,service.localDraftDrains.accepts(draftDrainID),let plan=state.snapshot else {return false}
        let sequence=editSequence+1
        let existing=state.draft
        let draft=ConversationTaskPlanDraft(baseRevision:existing?.baseRevision ?? plan.acceptedRevision,basePlanHash:existing?.basePlanHash ?? plan.acceptedPlanHash,goal:goal,requirements:requirements)
        guard draft.goal.utf16.count<=8000,draft.requirements.utf16.count<=8000 else {
            editSequence=sequence;draftSaved=false;state.drafts[String(draft.baseRevision)]=draft;state.activeDraftRevision=draft.baseRevision
            draftSaveIssue="本地修改草稿每项最多 8000 字。请缩短或明确放弃，尚未关闭编辑。";return false
        }
        guard let ticket=service.localDraftDrains.accept(draftDrainID) else {return false}
        editSequence=sequence;draftSaved=false;state.drafts[String(draft.baseRevision)]=draft;state.activeDraftRevision=draft.baseRevision;draftSaveIssue=nil
        let previous=saves,service=self.service,reference=self.reference
        saves=Task {
            await previous?.value
            do {try await service.saveDraft(reference,draft:draft,ticket:ticket);if sequence==self.editSequence {self.draftSaved=true;self.draftSaveIssue=nil}}
            catch {if sequence==self.editSequence {self.draftSaved=false;self.draftSaveIssue="修改草稿尚未保存，请重试或明确放弃。";self.error=error.localizedDescription}}
        }
        return true
    }
    private func drainAcceptedLocalDrafts() async -> Bool {
        tearingDown=true;freshlyRead=false;readGeneration += 1
        await saves?.value
        return draftSaved
    }
    func flushDraft() async {
        if editing,(state.draft?.goal != goal || state.draft?.requirements != requirements || (!draftSaved && draftSaveIssue != nil)) {stageDraft()}
        while let pending=saves {
            let sequence=editSequence;await pending.value
            if sequence==editSequence {break}
        }
    }
    @discardableResult func finishEditing() async -> Bool {await flushDraft();guard draftSaved else {return false};editing=false;return true}
    func discardDraft() async {
        await saves?.value
        do {try await service.discardDraft(reference);state=try await service.localState(reference);editing=false;draftSaved=true;draftSaveIssue=nil;restoreFields();error=nil}catch{self.error=error.localizedDescription}
    }
    func rebaseDraft() async {
        await flushDraft()
        guard draftSaved else {return}
        do {state=try await service.rebaseDraft(reference);restoreFields();error=nil}catch{self.error=error.localizedDescription}
    }
    func submit(admissionAllowed:Bool) async {
        guard admissionAllowed,canSubmit else {return};submitting=true;defer{submitting=false}
        await flushDraft();await service.setAdmissionAllowed(admissionAllowed)
        guard draftSaved,wireValidationMessage==nil else {return}
        let sequence=editSequence
        do {
            let latest=try await service.submit(reference)
            let continuedEditing=sequence != editSequence
            receive(latest,preserveLocalDraft:continuedEditing);editing=continuedEditing;error=nil
        } catch {
            freshlyRead=false
            self.error=error.localizedDescription
            if let latest=try? await service.localState(reference) {receive(latest,preserveLocalDraft:true)}
        }
    }
    private func restoreFields() {
        if let draft=state.draft {goal=draft.goal;requirements=draft.requirements}
        else if let plan=state.snapshot {goal=plan.content.goal;requirements=plan.content.requirements}
    }
    private func receive(_ incoming:ConversationTaskPlanLocalState,preserveLocalDraft:Bool) {
        if preserveLocalDraft {
            let drafts=state.drafts,active=state.activeDraftRevision
            state=incoming;state.drafts.merge(drafts){_,local in local};state.activeDraftRevision=active
        } else {state=incoming;restoreFields()}
    }
}
