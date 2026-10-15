import Foundation

/// Read-only discovery and verified projections. No task store, authority cache,
/// conversation creation, delivery journal or dispatch lives in this service.
public actor ConversationInboxService {
    public nonisolated let reference:ConversationInboxReference
    private let backend:any ConversationInboxBackend
    private var items:[ConversationInboxItem]=[]
    private var nextCursor:String?
    private var fresh=false,admitted=false,closed=false,loadingMore=false
    private var generation=0
    private var consumedCursors=Set<String>()
    private let pageLimit=20
    public init(reference:ConversationInboxReference,backend:any ConversationInboxBackend) {self.reference=reference;self.backend=backend}
    public func snapshot()->ConversationInboxSnapshot {.init(items:items,nextCursor:nextCursor,isFresh:fresh)}
    public func setAdmissionAllowed(_ allowed:Bool) {
        if !allowed {generation+=1;fresh=false;loadingMore=false}
        admitted=allowed && !closed
    }
    public func invalidate() {generation+=1;admitted=false;closed=true;items=[];nextCursor=nil;fresh=false;loadingMore=false;consumedCursors=[]}
    public func refresh() async throws -> ConversationInboxSnapshot {
        try ensure(generation);generation+=1;let epoch=generation;loadingMore=false;fresh=false
        do {
            let page=try await backend.readInbox(reference:reference,cursor:nil,limit:pageLimit);try ensure(epoch)
            try page.validate(reference,limit:pageLimit)
            items=page.items;nextCursor=page.nextCursor;consumedCursors=[];fresh=true;return snapshot()
        } catch {handle(error,epoch:epoch);throw error}
    }
    public func loadMore() async throws -> ConversationInboxSnapshot {
        let epoch=generation;try ensure(epoch)
        guard !loadingMore else {throw ConversationInboxError.busy}
        guard let cursor=nextCursor else {return snapshot()}
        guard fresh,!consumedCursors.contains(cursor) else {throw ConversationInboxError.stale}
        loadingMore=true
        defer {if generation==epoch {loadingMore=false}}
        do {
            let page=try await backend.readInbox(reference:reference,cursor:cursor,limit:pageLimit);try ensure(epoch)
            try page.validate(reference,limit:pageLimit)
            let existing=Set(items.map(\.id))
            guard page.items.allSatisfy({!existing.contains($0.id)}),page.nextCursor != cursor,
                  page.nextCursor.map({!consumedCursors.contains($0)}) ?? true else {throw ConversationInboxError.invalidResponse}
            items+=page.items;nextCursor=page.nextCursor;consumedCursors.insert(cursor);fresh=true;return snapshot()
        } catch {handle(error,epoch:epoch);throw error}
    }
    public func resolve(item:ConversationInboxItem) async throws -> ConversationGoalProjection {
        let epoch=generation;try ensure(epoch);try item.validate(reference)
        guard items.contains(item) else {throw ConversationInboxError.stale}
        do {
            let goal=try await backend.readReceivedTask(reference:reference,item:item);try ensure(epoch)
            guard items.contains(item) else {throw ConversationInboxError.stale}
            try item.validateResolved(goal,reference:reference);return goal
        } catch {handle(error,epoch:epoch);throw error}
    }
    private func ensure(_ epoch:Int) throws {
        try Task.checkCancellation()
        guard !closed,admitted else {throw ConversationInboxError.closed}
        guard generation==epoch else {throw CancellationError()}
    }
    private func handle(_ error:Error,epoch:Int) {
        guard generation==epoch,!closed else {return}
        fresh=false
        if error as? ConversationInboxError == .accessDenied {generation+=1;items=[];nextCursor=nil;consumedCursors=[];loadingMore=false}
    }
}
