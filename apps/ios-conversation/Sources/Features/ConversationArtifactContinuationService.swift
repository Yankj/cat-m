import Foundation

/// Scoped local composer storage. It owns no account, network, model or task lifecycle.
public actor ConversationArtifactContinuationService {
    public nonisolated let scope:DataScope
    public nonisolated let subjectID:UUID?
    private let repository:Repository
    private var closed=false
    private var locked=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock(){if waiters.isEmpty{locked=false}else{waiters.removeFirst().resume()}}
    public init(repository:Repository,scope:DataScope,subjectID:UUID?) {self.repository=repository;self.scope=scope;self.subjectID=subjectID}
    static func recordID(_ conversationID:UUID)->UUID {stableID("artifact-continuation-composer:\(conversationID)")}
    static func key(_ conversationID:UUID)->String {"artifact_continuation_composer:\(conversationID)"}
    public func state(conversationID:UUID) async throws -> ConversationArtifactContinuationComposerState {
        await lock();defer{unlock()};return try await load(conversationID).state
    }
    public func activate(_ reference:ConversationArtifactContinuationReference,ordinaryDraft:String?,priorDraft:ConversationArtifactContinuationDraft?=nil) async throws -> ConversationArtifactContinuationComposerState {
        await lock();defer{unlock()};try validate(reference)
        var loaded=try await load(reference.binding.conversation_id)
        if let priorDraft {try merge(priorDraft,into:&loaded.state)}
        let id=reference.id.uuidString.lowercased()
        if let saved=loaded.state.drafts[id] {guard saved.reference==reference else {throw ConversationArtifactContinuationError.invalidReference}}
        else {loaded.state.drafts[id] = .init(reference:reference,raw:"",editSequence:0)}
        loaded.state.activeReferenceID=reference.id
        var additional:[Mutation]=[]
        if let ordinaryDraft {
            guard var conversation=loaded.conversation.conversation else {throw catError.missing}
            conversation.draftText=ordinaryDraft
            additional=[.update(loaded.conversation.id,loaded.conversation.header.revision,.core(.conversation(conversation)))]
        }
        try await commit(loaded,additional:additional);return loaded.state
    }
    public func saveDraft(_ draft:ConversationArtifactContinuationDraft) async throws {
        await lock();defer{unlock()};try validate(draft.reference)
        var loaded=try await load(draft.reference.binding.conversation_id)
        try merge(draft,into:&loaded.state);try await commit(loaded)
    }
    /// Leaving targets only unsent input. It never cancels an admitted or unknown operation.
    public func leave(_ draft:ConversationArtifactContinuationDraft) async throws -> String {
        await lock();defer{unlock()};try validate(draft.reference)
        var loaded=try await load(draft.reference.binding.conversation_id)
        try merge(draft,into:&loaded.state)
        guard loaded.state.activeReferenceID==draft.reference.id else {throw ConversationArtifactContinuationError.staleDraft}
        loaded.state.activeReferenceID=nil;try await commit(loaded)
        return loaded.conversation.conversation?.draftText ?? ""
    }
    /// Queue owns the final transaction; composer clearing cannot commit without the immutable message.
    func queueMutation(remainingDraft:ConversationArtifactContinuationDraft,intent:ConversationArtifactContinuationIntent) async throws -> Mutation {
        await lock();defer{unlock()};try validate(remainingDraft.reference)
        guard try remainingDraft.reference.sendIntent()==intent else {throw ConversationArtifactContinuationError.invalidReference}
        var loaded=try await load(remainingDraft.reference.binding.conversation_id)
        guard loaded.state.activeReferenceID==remainingDraft.reference.id else {throw ConversationArtifactContinuationError.staleDraft}
        try merge(remainingDraft,into:&loaded.state);return try mutation(loaded)
    }
    public func invalidate() async {await lock();defer{unlock()};closed=true}
    private struct Loaded {var state:ConversationArtifactContinuationComposerState;let record:StoredRecord?;let conversation:StoredRecord}
    private func validate(_ reference:ConversationArtifactContinuationReference) throws {
        guard !closed else {throw ConversationArtifactContinuationError.closed}
        guard let subjectID else {throw ConversationArtifactContinuationError.unsupported}
        try reference.validate(scope:scope,subjectID:subjectID,conversationID:reference.binding.conversation_id)
    }
    private func load(_ conversationID:UUID) async throws -> Loaded {
        guard !closed else {throw ConversationArtifactContinuationError.closed}
        let conversation=try await repository.record(conversationID,scope:scope)
        guard conversation.conversation != nil else {throw catError.missing}
        let record:StoredRecord
        do {record=try await repository.record(Self.recordID(conversationID),scope:scope)}catch catError.missing{return .init(state:.init(),record:nil,conversation:conversation)}
        guard case .preference(let preference)=record.payload,preference.key==Self.key(conversationID),preference.value.utf8.count<=1_000_000 else {throw ConversationArtifactContinuationError.invalidReference}
        let state=try JSONDecoder().decode(ConversationArtifactContinuationComposerState.self,from:Data(preference.value.utf8))
        guard state.schemaVersion==1,state.drafts.count<=20,state.activeReferenceID==nil || state.activeDraft != nil else {throw ConversationArtifactContinuationError.invalidReference}
        for (key,draft) in state.drafts {try validate(draft.reference);guard key==draft.reference.id.uuidString.lowercased(),draft.reference.binding.conversation_id==conversationID,draft.raw.utf16.count<=32000,draft.editSequence>=0 else {throw ConversationArtifactContinuationError.invalidReference}}
        return .init(state:state,record:record,conversation:conversation)
    }
    private func merge(_ draft:ConversationArtifactContinuationDraft,into state:inout ConversationArtifactContinuationComposerState) throws {
        try validate(draft.reference)
        guard draft.raw.utf16.count<=32000,draft.editSequence>=0 else {throw ConversationArtifactContinuationError.invalidReference}
        let id=draft.reference.id.uuidString.lowercased()
        if let saved=state.drafts[id] {guard saved.reference==draft.reference,saved.editSequence<=draft.editSequence,saved.editSequence != draft.editSequence || saved.raw==draft.raw else {throw ConversationArtifactContinuationError.staleDraft}}
        guard state.drafts[id] != nil || state.drafts.count<20 else {throw ConversationArtifactContinuationError.invalidReference}
        state.drafts[id]=draft
    }
    private func mutation(_ loaded:Loaded) throws -> Mutation {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data=try encoder.encode(loaded.state);guard data.count<=1_000_000 else {throw ConversationArtifactContinuationError.invalidReference}
        let payload=Payload.preference(Preference(key:Self.key(loaded.conversation.id),value:String(decoding:data,as:UTF8.self)))
        return loaded.record.map{.update($0.id,$0.header.revision,payload)} ?? .create(Self.recordID(loaded.conversation.id),payload)
    }
    private func commit(_ loaded:Loaded,additional:[Mutation]=[]) async throws {try await repository.commit(scope:scope,mutations:[.requireRevision(loaded.conversation.id,loaded.conversation.header.revision),try mutation(loaded)]+additional)}
}
