import Foundation

/// An unconfirmed local review. It never proves server admission or execution authority.
public struct ConversationAcceptedWorkDraft:Codable,Sendable,Equatable,Identifiable {
    public let id:UUID
    public let conversationID:UUID
    public let raw:String
    public var options:ConversationAcceptedWorkOptions
    public let revisionTarget:ConversationArtifactContinuationIntent?
    public init(id:UUID=UUID(),conversationID:UUID,raw:String,options:ConversationAcceptedWorkOptions,revisionTarget:ConversationArtifactContinuationIntent?=nil) {self.revisionTarget=revisionTarget;
        self.id=id;self.conversationID=conversationID;self.raw=raw;self.options=options
    }
}

/// Owns scoped review persistence only. The existing queue owns the confirmed message transaction.
public actor ConversationAcceptedWorkDraftService {
    private let repository:Repository
    public nonisolated let scope:DataScope
    private let subjectID:UUID?
    private var closed=false,locked=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    private struct State:Codable {let schemaVersion:Int;let subjectID:UUID?;var draft:ConversationAcceptedWorkDraft?}
    private struct Loaded {var state:State;let record:StoredRecord?;let conversation:StoredRecord}
    public init(repository:Repository,scope:DataScope,subjectID:UUID?) {self.repository=repository;self.scope=scope;self.subjectID=subjectID}
    private func lock() async {if !locked {locked=true;return};await withCheckedContinuation{waiters.append($0)}}
    private func unlock(){if waiters.isEmpty{locked=false}else{waiters.removeFirst().resume()}}
    private static func recordID(_ id:UUID)->UUID {stableID("accepted-work-review:\(id)")}
    private static func key(_ id:UUID)->String {"accepted_work_review:\(id)"}
    public func read(conversationID:UUID) async throws -> ConversationAcceptedWorkDraft? {
        await lock();defer{unlock()};return try await load(conversationID).state.draft
    }
    public func save(_ draft:ConversationAcceptedWorkDraft,replaceUnconfirmed:Bool=false) async throws {
        await lock();defer{unlock()}
        guard !draft.raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,draft.raw.utf16.count<=8000 else {throw ConversationSessionError.invalidEvent}
        var loaded=try await load(draft.conversationID)
        if let prior=loaded.state.draft,!replaceUnconfirmed {guard prior.id==draft.id,prior.raw.utf8.elementsEqual(draft.raw.utf8),prior.revisionTarget==draft.revisionTarget else {throw CatpawError.conflict}}
        loaded.state.draft=draft
        try Task.checkCancellation()
        try await repository.commit(scope:scope,mutations:[.requireRevision(loaded.conversation.id,loaded.conversation.header.revision),try mutation(loaded)])
    }
    func revisionQueueMutation(draft:ConversationAcceptedWorkDraft,selection:ConversationRevisionWorkSelection) async throws -> Mutation {
        guard draft.revisionTarget==selection.target,draft.raw.utf8.elementsEqual(selection.originalText.utf8) else {throw CatpawError.conflict}
        return try await queueMutation(draft:draft,selection:selection.authorization)
    }
    /// Clearing the review commits only with the queue's exact confirmed selection and original text.
    func queueMutation(draft:ConversationAcceptedWorkDraft,selection:ConversationAcceptedWorkSelection) async throws -> Mutation {
        await lock();defer{unlock()}
        var loaded=try await load(draft.conversationID)
        guard loaded.state.draft==draft,draft.id==selection.decisionID,draft.options==selection.options,
              subjectID==selection.subjectID else {throw CatpawError.conflict}
        loaded.state.draft=nil
        try Task.checkCancellation();return try mutation(loaded)
    }
    public func invalidate() async {await lock();defer{unlock()};closed=true}
    private func load(_ id:UUID) async throws -> Loaded {
        guard !closed else {throw CancellationError()}
        let conversation=try await repository.record(id,scope:scope)
        guard conversation.conversation != nil else {throw CatpawError.missing}
        let record:StoredRecord
        do {record=try await repository.record(Self.recordID(id),scope:scope)}catch CatpawError.missing{return .init(state:.init(schemaVersion:1,subjectID:subjectID,draft:nil),record:nil,conversation:conversation)}
        guard case .preference(let value)=record.payload,value.key==Self.key(id),value.value.utf8.count<=100000 else {throw ConversationSessionError.invalidEvent}
        let state=try JSONDecoder().decode(State.self,from:Data(value.value.utf8))
        guard state.schemaVersion==1,state.subjectID==subjectID,state.draft==nil || (state.draft?.conversationID==id && (state.draft?.raw.utf16.count ?? 0)<=8000) else {throw ConversationSessionError.invalidEvent}
        return .init(state:state,record:record,conversation:conversation)
    }
    private func mutation(_ loaded:Loaded) throws -> Mutation {
        guard !closed else {throw CancellationError()}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data=try encoder.encode(loaded.state);guard data.count<=100000 else {throw ConversationSessionError.invalidEvent}
        let payload=Payload.preference(.init(key:Self.key(loaded.conversation.id),value:String(decoding:data,as:UTF8.self)))
        return loaded.record.map{.update($0.id,$0.header.revision,payload)} ?? .create(Self.recordID(loaded.conversation.id),payload)
    }
}
