import SwiftUI

@MainActor final class ConversationMemoryModel:ObservableObject {
    let service:ConversationMemoryService,conversationID:UUID?
    @Published private(set) var state:ConversationMemoryLocalState?
    @Published var draft=ConversationMemoryDraft()
    @Published var source:ConversationMemorySource?
    @Published var review:ConversationMemoryCommand?
    @Published var error:String?
    @Published private(set) var busy=false
    @Published private(set) var loadedFresh=false
    private var token=UUID(),draftTask:Task<Void,Never>?
    init(service:ConversationMemoryService,conversationID:UUID?){self.service=service;self.conversationID=conversationID}
    var canWrite:Bool {loadedFresh && !busy && state?.pending==nil}
    func load(admissionAllowed:Bool) async {
        guard !busy else {return};let current=token;busy=true;defer{if token==current{busy=false}}
        do {
            let firstLoad=state==nil
            let local=try await service.localState();guard token==current else{return};state=local;if firstLoad {draft=local.draft}
            guard admissionAllowed else {loadedFresh=false;return}
            let fresh=try await service.refresh();guard token==current else{return};state=fresh;loadedFresh=true;error=nil
        }catch is CancellationError {if token==current{loadedFresh=false}}catch{if token==current{loadedFresh=false;self.error=error.localizedDescription}}
    }
    func stageDraft(){draftTask?.cancel();guard let epoch=state?.draftEpoch else{return};let value=draft;draftTask=Task{do{try await Task.sleep(nanoseconds:200_000_000);try Task.checkCancellation();try await service.saveDraft(value,expectedDraftEpoch:epoch)}catch is CancellationError{}catch{self.error="记忆草稿尚未保存，请重新核对。"}}}
    func flush() async {let prior=draftTask,value=draft,epoch=state?.draftEpoch;prior?.cancel();await prior?.value;guard let epoch else{return};do{try await service.saveDraft(value,expectedDraftEpoch:epoch)}catch{self.error="记忆草稿尚未保存，请重新核对。"}}
    func editing(_ entry:ConversationMemoryEntry){draftTask?.cancel();draft = .init();draft.targetID=entry.id;draft.base=entry;draft.topic=entry.displayTitle;draft.text=entry.displayValue;draft.workspaceWide=entry.conditions.isEmpty;stageDraft()}
    func newDraft(){draftTask?.cancel();draft = .init();stageDraft()}
    func prepareSave(){
        guard canWrite,state?.latest?.enabled==true,let conversationID else {error="请先开启记忆并读取最新状态，再确认保存。";return}
        let text=draft.text,topic=draft.topic.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!topic.isEmpty else {error="请填写记忆主题与内容。";return}
        var command=ConversationMemoryCommand(type:draft.targetID==nil ? .remember:.correct)
        let conditions:[String:ConversationMemoryValue]=draft.workspaceWide ? [:]:["conversation_id":.string(conversationID.uuidString.lowercased())]
        let base=draft.base
        if let base {guard state?.latest?.claims.contains(where:{$0.id==base.id && $0.version==base.version && $0.conditions==base.conditions && $0.predicate==base.predicate})==true else {error=ConversationMemoryError.stale.localizedDescription;return}}
        command.conversation_id=conversationID;command.source_text=text;command.allow_relearn=false;command.sensitive_consent=false
        command.target_id=base?.id;command.expected_version=base?.version
        command.claim = .init(kind:base?.kind ?? "preference",predicate:base?.predicate ?? "user.note."+String(textHash(topic.lowercased()).prefix(32)),value:base.map{_ in .string(text)} ?? .object(["topic":.string(topic),"text":.string(text)]),conditions:base?.conditions ?? conditions,evidence:.init(span_start:0,span_end:text.utf16.count),valid_from:base?.valid_from,valid_until:base?.valid_until,expires_at:base?.expires_at)
        // Keep a structured note's topic when correcting its text; other typed
        // values are explicitly replaced by the reviewed user text.
        if let base,case .object(let values)=base.value,values["topic"] != nil {command.claim?.value = .object(["topic":values["topic"]!,"text":.string(text)])}
        do{try command.validate();review=command;error=nil}catch{self.error="记忆内容过长或格式不符，请精简后重新确认。"}
    }
    func prepareConfirm(_ entry:ConversationMemoryEntry){guard canWrite else{return};var command=ConversationMemoryCommand(type:.confirm);command.candidate_id=entry.id;command.expected_version=entry.version;command.allow_relearn=false;command.sensitive_consent=false;review=command}
    func prepareForget(_ entry:ConversationMemoryEntry){guard canWrite else{return};var command=ConversationMemoryCommand(type:.forget);command.target_id=entry.id;command.expected_version=entry.version;command.no_relearn=true;review=command}
    func prepareEnabled(_ enabled:Bool){guard canWrite else{return};var command=ConversationMemoryCommand(type:.set_enabled);command.enabled=enabled;review=command}
    func submit(admissionAllowed:Bool) async {
        guard admissionAllowed,canWrite,let command=review else{return};let current=token;busy=true;defer{if token==current{busy=false}}
        await flush()
        do {let result=try await service.submit(command);guard token==current else{return};state=result;draft=result.draft;review=nil;loadedFresh=false
            let fresh=try await service.refresh();guard token==current else{return};state=fresh;loadedFresh=true;error=nil
        }catch is CancellationError{}catch{if token==current{self.error=error.localizedDescription;state=try? await service.localState();review=nil;loadedFresh=false}}
    }
    func readOriginal(admissionAllowed:Bool) async {
        guard admissionAllowed,!busy else{return};let current=token;busy=true;defer{if current==token{busy=false}}
        do{let result=try await service.readOriginal();guard current==token else{return};state=result;draft=result.draft;loadedFresh=false;let fresh=try await service.refresh();guard current==token else{return};state=fresh;loadedFresh=true;error=nil}catch{if current==token{self.error=error.localizedDescription}}
    }
    func reopenNotSent() async {do{state=try await service.reopenNotSent();loadedFresh=false;error=nil}catch{self.error=error.localizedDescription}}
    func showSource(_ id:UUID,admissionAllowed:Bool) async {guard admissionAllowed,!busy else{return};let current=token;busy=true;defer{if current==token{busy=false}};do{let value=try await service.source(id);guard token==current else{return};source=value;error=nil}catch{if token==current{self.error=error.localizedDescription}}}
}
extension ConversationMemoryEntry {
    var displayTitle:String {if case .object(let values)=value,case .string(let x)=values["topic"]{return x};return predicate}
    var displayValue:String {if case .object(let values)=value,case .string(let x)=values["text"]{return x};return value.readable}
}
