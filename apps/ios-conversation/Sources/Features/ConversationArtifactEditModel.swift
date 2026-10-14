import Foundation
import Combine

@MainActor final class ConversationArtifactEditModel:ObservableObject {
    let service:ConversationArtifactEditService
    let reference:ConversationArtifactEditReference
    private let onApplied:(@MainActor (ConversationArtifactEditEnvelope) async throws -> Void)?
    @Published private(set) var state=ConversationArtifactEditLocalState()
    @Published private(set) var loading=false
    @Published private(set) var submitting=false
    @Published private(set) var freshlyRead=false
    @Published private(set) var draftSaved=true
    @Published private(set) var draftSaveIssue:String?
    @Published private(set) var deliveryIssue:String?
    @Published var title:String
    @Published var summary:String
    @Published var content:String
    @Published var error:String?
    private var saves:Task<Void,Never>?
    private var editSequence=0
    private var readGeneration=0
    private var hasLocalIntent=false
    private var abandoned=false
    private let draftDrainID=UUID()
    @Published private(set) var tearingDown=false
    var hasLocalIntentForDisplay:Bool {hasLocalIntent}
    init(service:ConversationArtifactEditService,reference:ConversationArtifactEditReference,onApplied:(@MainActor (ConversationArtifactEditEnvelope) async throws -> Void)?=nil) {
        self.service=service;self.reference=reference;self.onApplied=onApplied;title=reference.artifact.title;summary=reference.artifact.summary;content=reference.artifact.content
        _=service.localDraftDrains.register(draftDrainID,scope:reference.scope){[weak self] in await self?.drainAcceptedLocalDrafts() ?? true}
    }
    deinit {service.localDraftDrains.unregister(draftDrainID)}
    var raw:ConversationArtifactEditContent {.init(title:title,summary:summary,content:content)}
    var base:ConversationArtifactEditSnapshot? {state.base(for:reference)}
    var hasConflict:Bool {
        guard let base,let current=state.currentReference else {return false}
        return base.versionReference != current || (state.latest.map{$0.planReference != base.planReference} ?? false)
    }
    var wireValidationMessage:String? {
        if title.utf16.count>160 {return "标题最多 160 字，修改草稿会保留。"}
        if summary.utf16.count>8000 {return "摘要最多 8000 字，修改草稿会保留。"}
        if content.utf16.count>16000 {return "正文最多 16000 字，修改草稿会保留。"}
        if (try? raw.validate())==nil {return "标题、摘要和正文不能为空，也不能含不支持的控制字符。"}
        return nil
    }
    var preventDismiss:Bool {!draftSaved}
    var canEditLocal:Bool {!abandoned && !tearingDown && service.localDraftDrains.accepts(draftDrainID)}
    var canSubmit:Bool {canEditLocal && base != nil && state.latest?.editable==true && freshlyRead && !hasConflict && !state.hasUnresolvedSubmission && !loading && !submitting && draftSaved && wireValidationMessage==nil && hasLocalIntent}
    func load(admissionAllowed:Bool) async {
        guard !loading,canEditLocal else {return};readGeneration += 1;let generation=readGeneration
        loading=true;defer{if generation==readGeneration {loading=false}}
        await flushDraft();await service.setAdmissionAllowed(admissionAllowed)
        do {
            let localSequence=editSequence
            let local=try await service.localState(reference)
            receive(local,preserveRaw:hasLocalIntent || localSequence != editSequence)
            guard admissionAllowed else {freshlyRead=false;return}
            let sequence=editSequence
            let latest=try await service.refresh(reference)
            guard generation==readGeneration,!abandoned else {return}
            receive(latest,preserveRaw:hasLocalIntent || sequence != editSequence)
            freshlyRead=await service.isFresh(reference);error=nil
            if let envelope=try await service.appliedEnvelope(reference) {await deliver(envelope)}
        } catch {if generation==readGeneration {freshlyRead=false;self.error=error.localizedDescription}}
    }
    @discardableResult func stageDraft() -> Bool {
        guard canEditLocal,let base else {return false}
        let sequence=editSequence+1
        let draft=ConversationArtifactEditDraft(baseReference:base.versionReference,planReference:base.planReference,content:raw,editSequence:sequence)
        do {try draft.content.validateLocal()} catch {hasLocalIntent=true;editSequence=sequence;draftSaved=false;state.drafts[reference.selection.id]=draft;draftSaveIssue=error.localizedDescription;return false}
        guard let ticket=service.localDraftDrains.accept(draftDrainID) else {return false}
        hasLocalIntent=true;editSequence=sequence;draftSaved=false;state.drafts[reference.selection.id]=draft
        draftSaveIssue=nil
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
        // Closing sealed synchronous admission; this captured queue contains no network work.
        await saves?.value
        return draftSaved
    }
    func flushDraft() async {
        if hasLocalIntent,!abandoned,(state.draft(for:reference)?.content != raw || (!draftSaved && draftSaveIssue != nil)) {stageDraft()}
        while let pending=saves {let sequence=editSequence;await pending.value;if sequence==editSequence {break}}
    }
    @discardableResult func close() async -> Bool {await flushDraft();return draftSaved}
    @discardableResult func discard() async -> Bool {
        await saves?.value
        do {try await service.discardDraft(reference);abandoned=true;draftSaved=true;draftSaveIssue=nil;hasLocalIntent=false;return true}
        catch {self.error=error.localizedDescription;return false}
    }
    func rebase() async {
        stageDraft();await flushDraft();guard draftSaved else {return}
        do {let incoming=try await service.rebaseDraft(reference);state=incoming;editSequence=max(editSequence,incoming.draft(for:reference)?.editSequence ?? 0);stageDraft();await flushDraft();error=nil}
        catch {self.error=error.localizedDescription}
    }
    func submit(admissionAllowed:Bool) async {
        guard admissionAllowed,canSubmit,!abandoned else {return};submitting=true;defer{submitting=false}
        await flushDraft();await service.setAdmissionAllowed(admissionAllowed)
        guard draftSaved,wireValidationMessage==nil else {return}
        let sequence=editSequence
        do {
            let envelope=try await service.submit(reference)
            let incoming=try await service.localState(reference)
            receive(incoming,preserveRaw:true,preserveDraft:sequence != editSequence)
            if sequence==editSequence {hasLocalIntent=false;draftSaved=true;draftSaveIssue=nil}
            freshlyRead=false;error=nil;await deliver(envelope)
        } catch {
            freshlyRead=false;self.error=error.localizedDescription
            if let incoming=try? await service.localState(reference) {receive(incoming,preserveRaw:true)}
        }
    }
    private func deliver(_ envelope:ConversationArtifactEditEnvelope) async {
        guard let onApplied else {return}
        do {try await onApplied(envelope);deliveryIssue=nil}
        catch {deliveryIssue="成果已保存，但工作展示尚未更新。请核对原修改。";self.error=error.localizedDescription}
    }
    private func receive(_ incoming:ConversationArtifactEditLocalState,preserveRaw:Bool,preserveDraft:Bool=true) {
        let localDraft=state.draft(for:reference)
        state=incoming
        if preserveRaw {
            let resolvedUnchanged=incoming.submission.map{$0.state == .applied && $0.submittedDraft==localDraft && incoming.draft(for:reference)==nil} ?? false
            if resolvedUnchanged {hasLocalIntent=false;draftSaved=true;draftSaveIssue=nil}
            else if let localDraft,hasLocalIntent,preserveDraft,(state.draft(for:reference).map{$0.editSequence<localDraft.editSequence} ?? true) {state.drafts[reference.selection.id]=localDraft}
            return
        }
        if let draft=state.draft(for:reference) {title=draft.content.title;summary=draft.content.summary;content=draft.content.content;editSequence=max(editSequence,draft.editSequence);hasLocalIntent=true}
        else if let base,let document=try? base.document() {title=document.title;summary=document.summary;content=document.content}
    }
}
