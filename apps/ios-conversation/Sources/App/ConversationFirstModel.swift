import Foundation
import SwiftUI

struct OutgoingMessageIntent: Identifiable, Equatable {
    enum State: String { case savingLocal, queued, awaitingPermission, sending, unknown, failed }
    let id: UUID
    let text: String
    var state: State
    var error: String?
}
enum ConversationConnectionLifecycle: String { case checking, available, reconnecting, offline, notConfigured }
enum ConversationObserverLifecycle: String { case foregroundIdle, streaming, reconnecting, background, unknown }

@MainActor final class ConversationFirstModel: ObservableObject {
    let repository: Repository
    let service: ConversationSessionService
    let scope: DataScope
    @Published private(set) var conversationID: UUID?
    @Published private(set) var session: ConversationSession?
    @Published private(set) var history: [StoredRecord] = []
    @Published private(set) var followups = ConversationFollowupState()
    @Published private(set) var outgoingMessages: [OutgoingMessageIntent] = []
    @Published private(set) var connectionLifecycle: ConversationConnectionLifecycle = .checking
    @Published private(set) var observerLifecycle: ConversationObserverLifecycle = .foregroundIdle
    @Published private(set) var tapToLocalPublishMs: Double?
    @Published private(set) var tapToFirstRenderedMs: Double?
    private var tapTimes: [UUID: TimeInterval] = [:]
    private var queue: ConversationFollowupQueueService?
    @Published private(set) var sending = false
    @Published private(set) var enqueueing = false
    var canAcceptDraft: Bool { loaded && !isInputComposing && !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && draft.utf16.count <= 8000 && outgoingMessages.count < 20 }
    @Published var pendingModelConsent: ConversationModelConsent?
    @Published private(set) var checkingModelConsent = false
    @Published private(set) var isInputComposing = false
    @Published var draft = ""
    @Published var error: String?
    @Published private(set) var networkAdmissionAllowed = true
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var connection = ConversationConnection(state:.notConfigured,provider:"OpenRouter",detail:"连接正在检查。")
    private var subscription: Task<Void,Never>?
    private var draftTask: Task<Void,Never>?
    private var foregroundTask: Task<Void,Never>?
    private var turnTask: Task<Void,Never>?
    private var permissionTask: Task<Void,Never>?
    private var persistenceTask: Task<Void,Never>?
    private var connectionTask: Task<Void,Never>?
    private var haltTask: Task<Void,Never>?
    private var flightID: UUID?
    private var permissionID: UUID?
    private var sceneGeneration = 0
    private var refreshGeneration = 0
    private var foreground = true
    private var savingCount = 0
    private var consentReady = false
    init(repository:Repository,service:ConversationSessionService,scope:DataScope = Profiles.user) { self.repository=repository;self.service=service;self.scope=scope }
    func start() async {
        guard !loaded else { return }
        do {
            let id=try await service.openLatest(scope:scope);try await select(id)
            let snapshot=await repository.read(scope:scope)
            subscription=Task { [weak self,repository,scope] in
                for await _ in await repository.changes(scope:scope,after:snapshot.sequence) { guard let self,!Task.isCancelled else { return };await self.refresh() }
            }
            loaded=true;await resumeForeground()
        } catch { self.error=error.localizedDescription }
    }
    func refresh() async {
        guard let id=conversationID else { return }
        refreshGeneration += 1;let generation=refreshGeneration
        do {
            let snapshot=await repository.read(scope:scope)
            history=snapshot.list("conversation",scope:scope).filter { snapshot.records[stableID("conversation-first-journal-\($0.id)")] != nil }
            let current=try await service.read(scope:scope,conversationID:id)
            let queued=try await queue?.state() ?? ConversationFollowupState()
            guard conversationID == id,refreshGeneration == generation else { return };session=current;followups=queued
            let durable=(queued.pending + [queued.inflight].compactMap { $0 })
            let unresolvedIDs=Set(current.turns.filter { [.unknown,.notSent].contains($0.state) }.map(\.id))
            outgoingMessages=outgoingMessages.filter { value in
                value.state == .savingLocal || value.state == .failed || durable.contains(where:{$0.id == value.id}) || unresolvedIDs.contains(value.id)
            }
            for value in durable where !outgoingMessages.contains(where:{$0.id == value.id}) { outgoingMessages.append(.init(id:value.id,text:value.text,state:.queued,error:nil)) }
            for i in outgoingMessages.indices {
                let value=outgoingMessages[i]
                if let turn=current.turns.first(where:{$0.id == value.id}) {
                    switch turn.state { case .unknown: outgoingMessages[i].state = .unknown;case .notSent: outgoingMessages[i].state = .queued;default: break }
                }
            }
            if foreground,!busy,current.unresolved == nil { observerLifecycle = .foregroundIdle }
        } catch { self.error=error.localizedDescription }
    }
    func select(_ id:UUID) async throws {
        guard !busy,!isInputComposing else { throw ConversationSessionError.busy }
        await persistenceTask?.value
        guard !busy,!isInputComposing else { throw ConversationSessionError.busy }
        busy=true;defer { busy=false }
        try await flushDraft();let saved=try await repository.record(id,scope:scope),selected=try await service.read(scope:scope,conversationID:id)
        try await service.rememberSelection(scope:scope,conversationID:id)
        permissionTask?.cancel();permissionID=nil;pendingModelConsent=nil;checkingModelConsent=false;consentReady=false
        queue=ConversationFollowupQueueService(repository:repository,scope:scope,conversationID:id)
        conversationID=id;session=selected;draft=saved.conversation?.draftText ?? "";outgoingMessages=[];tapTimes=[:];isInputComposing=false;error=nil;await refresh()
    }
    func newConversation() { guard !isInputComposing else { return };Task { do { await persistenceTask?.value;try await flushDraft();let id=try await service.create(scope:scope);try await select(id) } catch { self.error=error.localizedDescription } } }
    func updateInputComposition(_ active:Bool) { guard active != isInputComposing else { return };isInputComposing=active }
    func editDraft(_ text:String) {
        draft=text;draftTask?.cancel();guard let id=conversationID else { return }
        draftTask=Task { do { try await Task.sleep(nanoseconds:300_000_000);try Task.checkCancellation();try await service.saveDraft(scope:scope,conversationID:id,text:text) } catch is CancellationError { } catch { self.error=error.localizedDescription } }
    }
    func flushDraft() async throws { draftTask?.cancel();draftTask=nil;if let id=conversationID { try await service.saveDraft(scope:scope,conversationID:id,text:draft) } }
    // This synchronous capture is local intent, never a server admission or successful send.
    func prepareSend() {
        guard canAcceptDraft,let id=conversationID,let queue else { return }
        let tap=ProcessInfo.processInfo.systemUptime,message=ConversationFollowup(text:draft)
        draftTask?.cancel();draftTask=nil
        tapTimes[message.id]=tap;outgoingMessages.append(.init(id:message.id,text:message.text,state:.savingLocal,error:nil));draft=""
        savingCount += 1;enqueueing=true;tapToLocalPublishMs=(ProcessInfo.processInfo.systemUptime-tap)*1000
        let previous=persistenceTask
        persistenceTask=Task {
            await previous?.value
            defer { savingCount -= 1;enqueueing=savingCount > 0 }
            do {
                try await queue.enqueue(message,remainingDraft:draft)
                guard conversationID == id else { return }
                setIntent(message.id,.queued);await refresh()
                if foreground { authorizePending() }
            } catch {
                setIntent(message.id,.failed,error:error.localizedDescription)
                if draft.isEmpty { draft=message.text };self.error="本机保存未完成，内容已保留。"
            }
        }
    }
    func send() { prepareSend() }
    func outgoingDidRender(_ id:UUID) { if let time=tapTimes.removeValue(forKey:id) { tapToFirstRenderedMs=(ProcessInfo.processInfo.systemUptime-time)*1000 } }
    private func setIntent(_ id:UUID,_ state:OutgoingMessageIntent.State,error:String?=nil) { if let i=outgoingMessages.firstIndex(where:{$0.id == id}) { outgoingMessages[i].state=state;outgoingMessages[i].error=error } }
    private func authorizePending() {
        guard networkAdmissionAllowed,foreground,loaded,permissionTask == nil,pendingModelConsent == nil,let id=conversationID else { return }
        if consentReady { drainQueue();return }
        let token=UUID();permissionID=token;checkingModelConsent=true
        permissionTask=Task {
            defer { if permissionID == token { permissionTask=nil;checkingModelConsent=false } }
            do {
                let state=try await queue?.state()
                guard !Task.isCancelled,permissionID == token,foreground,conversationID == id,let state,!state.pending.isEmpty,!state.paused else { return }
                let consent=try await service.modelConsent(scope:scope,conversationID:id)
                guard !Task.isCancelled,permissionID == token,foreground,conversationID == id else { return }
                if let consent { pendingModelConsent=consent;for i in outgoingMessages.indices where outgoingMessages[i].state == .queued { outgoingMessages[i].state = .awaitingPermission } }
                else { consentReady=true;drainQueue() }
            } catch { if permissionID == token { self.error="尚未发送；连接或许可读取未完成，本机消息已保留。" } }
        }
    }
    func allowPendingModelConsent(_ consent:ConversationModelConsent) {
        guard foreground,conversationID == consent.conversationID,loaded,pendingModelConsent?.routeHash == consent.routeHash else { return }
        permissionTask?.cancel();let token=UUID();permissionID=token;checkingModelConsent=true;pendingModelConsent=nil
        permissionTask=Task {
            defer { if permissionID == token { permissionTask=nil;checkingModelConsent=false } }
            do { try await service.allowModelConsent(scope:scope,consent:consent);guard !Task.isCancelled,permissionID == token,foreground,conversationID == consent.conversationID else { return };consentReady=true;drainQueue() }
            catch { if permissionID == token { self.error="许可保存未确认，本机消息已保留，未发送。" } }
        }
    }
    func deferModelConsent() { pendingModelConsent=nil;consentReady=false;Task { try? await queue?.pause();await refresh() } }
    private var canDispatchFollowup:Bool { loaded && foreground && networkAdmissionAllowed }
    private func drainQueue() {
        guard networkAdmissionAllowed,foreground,let id=conversationID,let queue,!busy,session?.unresolved == nil else { return }
        let token=UUID();flightID=token;busy=true;sending=true;observerLifecycle = .streaming;error=nil
        turnTask=Task {
            defer { if flightID == token { flightID=nil;busy=false;sending=false;observerLifecycle=session?.unresolved == nil ? .foregroundIdle : .unknown } }
            do {
                try await queue.flush { [service,scope,weak self] message in
                    guard !Task.isCancelled,await self?.canDispatchFollowup == true else { return .heldBeforeAdmission }
                    await self?.setIntent(message.id,.sending)
                    do { _=try await service.send(scope:scope,conversationID:id,text:message.text,operationID:message.id,preserveDraft:true);return .sent }
                    catch {
                        let saved=try await service.read(scope:scope,conversationID:id)
                        if !saved.turns.contains(where:{$0.id == message.id}) || saved.turns.first(where:{$0.id == message.id})?.state == .notSent { return .heldBeforeAdmission }
                        throw error
                    }
                }
                guard flightID == token else { return };let state=try await queue.state()
                if state.paused && !state.pending.isEmpty { error="尚未发送的消息已保留，恢复连接后继续。";if draft.isEmpty { draft=state.pending.first?.text ?? "" } }
            } catch { if flightID == token { self.error=error.localizedDescription } }
            guard flightID == token else { return };await refresh()
        }
    }
    func pauseFollowups() { Task { do { try await queue?.pause();await refresh() } catch { self.error=error.localizedDescription } } }
    func removeFollowup(_ id:UUID) { Task { do { if let conversationID { try await service.discardUnsent(scope:scope,conversationID:conversationID,operationID:id) };try await queue?.remove(id);outgoingMessages.removeAll { $0.id == id };await refresh() } catch { self.error=error.localizedDescription } } }
    func resumeFollowups() {
        guard foreground,!busy,session?.unresolved == nil,let queue else { return }
        Task { do {
            let state=try await queue.state()
            if let original=state.inflight,let id=conversationID { let saved=try await service.read(scope:scope,conversationID:id);try await queue.reconcileInflight(admitted:saved.turns.contains { $0.id == original.id && ![.notSent,.cancelledBeforeSend].contains($0.state) }) }
            try await queue.resume();await refresh();authorizePending()
        } catch { self.error=error.localizedDescription } }
    }
    func setNetworkAdmissionAllowed(_ allowed:Bool) {
        guard allowed != networkAdmissionAllowed else { return };networkAdmissionAllowed=allowed
        if allowed { Task { await resumeForeground();authorizePending() } }
        else { permissionTask?.cancel();permissionTask=nil;permissionID=nil;checkingModelConsent=false;connectionLifecycle = .checking }
    }
    func refreshConnection() async {
        guard networkAdmissionAllowed else { connectionLifecycle = .checking;return }
        let generation=sceneGeneration
        connectionLifecycle = session?.unresolved == nil ? .checking : .reconnecting
        let value=await service.connection(scope:scope)
        guard generation == sceneGeneration else { return };connection=value
        switch value.state { case .connected,.providerUnverified:connectionLifecycle = .available;case .unavailable:connectionLifecycle = .offline;case .notConfigured:connectionLifecycle = .notConfigured }
    }
    func readOriginal() {
        guard networkAdmissionAllowed,foreground,let id=conversationID,!busy else { return }
        let token=UUID();flightID=token;busy=true;observerLifecycle = .reconnecting
        turnTask=Task {
            defer { if flightID == token { flightID=nil;busy=false;observerLifecycle=session?.unresolved == nil ? .foregroundIdle : .unknown } }
            do { try await service.observe(scope:scope,conversationID:id);guard flightID == token else { return };error=nil }
            catch is CancellationError { }
            catch { if flightID == token { self.error=error.localizedDescription } }
            guard flightID == token else { return };await refresh()
            guard flightID == token else { return };flightID=nil;busy=false;observerLifecycle=session?.unresolved == nil ? .foregroundIdle : .unknown
            await resumeBackgroundQueueIfSafe()
        }
    }
    private func resumeBackgroundQueueIfSafe() async {
        guard foreground,session?.unresolved == nil,let queue else { return }
        do {
            let state=try await queue.state();guard state.pauseReason == .background else { return }
            if let original=state.inflight {
                let admitted=session?.turns.contains(where:{$0.id == original.id && ![.notSent,.cancelledBeforeSend].contains($0.state)}) == true
                try await queue.reconcileInflight(admitted:admitted)
            }
            try await queue.resume(backgroundOnly:true);await refresh();authorizePending()
        } catch ConversationSessionError.busy { /* The old queue drain is still unwinding; the foreground loop retries read-only reconciliation. */ }
        catch { self.error=error.localizedDescription }
    }
    func sceneChanged(_ phase:ScenePhase) {
        // Capture intent synchronously, so delayed scene Tasks cannot invert active/background.
        switch phase {
        case .active:sceneGeneration += 1;foreground=true;let generation=sceneGeneration;Task { await enterForeground(generation:generation) }
        case .background:let finish=beginSuspension();Task { await finish.value }
        case .inactive:Task { try? await flushDraft() }
        @unknown default:break
        }
    }
    func resumeForeground() async {
        guard loaded else { return };sceneGeneration += 1;let generation=sceneGeneration;foreground=true
        await enterForeground(generation:generation)
    }
    private func enterForeground(generation:Int) async {
        guard loaded,generation == sceneGeneration,foreground else { return }
        await haltTask?.value;guard generation == sceneGeneration,foreground else { return }
        foregroundTask?.cancel();connectionTask?.cancel()
        // Reachability is informative; it must not block GET of the exact unresolved turn.
        connectionTask=Task { await refreshConnection() }
        await refresh()
        guard generation == sceneGeneration,foreground else { return }
        if session?.unresolved != nil { readOriginal() } else { await resumeBackgroundQueueIfSafe() }
        foregroundTask=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.foreground,self.sceneGeneration == generation else { return }
                if !self.busy,let session=self.session {
                    if session.unresolved != nil || session.goals.values.contains(where:{[.queued,.working,.waitingInput,.unknown].contains($0.state)}) { self.readOriginal() }
                    else { await self.resumeBackgroundQueueIfSafe() }
                }
                do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { return }
            }
        }
    }
    func suspend() async {
        await beginSuspension().value
    }
    private func beginSuspension() -> Task<Void,Never> {
        sceneGeneration += 1;foreground=false;foregroundTask?.cancel();foregroundTask=nil;connectionTask?.cancel()
        permissionTask?.cancel();permissionTask=nil;permissionID=nil;checkingModelConsent=false;pendingModelConsent=nil
        let old=turnTask;turnTask=nil;flightID=nil;busy=false;sending=false;observerLifecycle = .background
        let id=conversationID,service=self.service,scope=self.scope,queue=self.queue
        let previous=haltTask,persistence=persistenceTask
        let generation=sceneGeneration
        let task=Task {
            await previous?.value
            do { if let id { try await service.stopObserving(scope:scope,conversationID:id) };old?.cancel();try await queue?.pause(reason:.background) }
            catch { old?.cancel() }
            await persistence?.value
            guard generation == sceneGeneration else { return }
            do { try await flushDraft() } catch { self.error=error.localizedDescription }
        }
        haltTask=task;return task
    }
    func deactivate() async {
        // Close admission before any await; a queued foreground Task cannot revive logout.
        loaded=false;networkAdmissionAllowed=false
        await suspend();subscription?.cancel();subscription=nil;draftTask?.cancel();draftTask=nil
        draft="";history=[];session=nil;conversationID=nil;followups=ConversationFollowupState();queue=nil;outgoingMessages=[];tapTimes=[:];isInputComposing=false;error=nil;loaded=false
    }
}
