import Foundation

/// Synchronous acceptance covers model tasks that have not reached the service actor yet.
/// Tickets authorize only one local draft write in this fixed scope, never a server request.
struct ConversationLocalDraftTicket:Sendable {
    fileprivate let id:UUID
    fileprivate let registryID:UUID
}
final class ConversationLocalDraftDrains:@unchecked Sendable {
    typealias Drain = @MainActor @Sendable () async -> Bool
    private let scope:DataScope
    private let registryID=UUID()
    private let mutex=NSLock()
    private var closed=false
    private var drains:[UUID:Drain]=[:]
    private var tickets:Set<UUID>=[]
    init(scope:DataScope){self.scope=scope}
    func register(_ id:UUID,scope:DataScope,drain:@escaping Drain)->Bool {
        mutex.lock();defer{mutex.unlock()};guard !closed,self.scope==scope else {return false};drains[id]=drain;return true
    }
    func unregister(_ id:UUID){mutex.lock();defer{mutex.unlock()};drains.removeValue(forKey:id)}
    func accepts(_ id:UUID)->Bool {mutex.lock();defer{mutex.unlock()};return !closed && drains[id] != nil}
    func accept(_ id:UUID)->ConversationLocalDraftTicket? {
        mutex.lock();defer{mutex.unlock()};guard !closed,drains[id] != nil else {return nil}
        let ticket=UUID();tickets.insert(ticket);return .init(id:ticket,registryID:registryID)
    }
    func consume(_ ticket:ConversationLocalDraftTicket)->Bool {
        mutex.lock();defer{mutex.unlock()};return ticket.registryID==registryID && tickets.remove(ticket.id) != nil
    }
    func closeAndSnapshot()->[Drain] {mutex.lock();defer{mutex.unlock()};closed=true;return Array(drains.values)}
    func finish(){mutex.lock();defer{mutex.unlock()};drains.removeAll();tickets.removeAll()}
}
