import Foundation
import SwiftUI
import Combine
import CatpawImageComposer

struct OutgoingMessageIntent: Identifiable, Equatable {
    enum State: String { case savingLocal, queued, awaitingPermission, sending, unknown, failed }
    let id: UUID
    let text: String
    var image:ConversationImageReceipt? = nil
    var state: State
    var error: String?
}
enum ConversationConnectionLifecycle: String { case checking, available, reconnecting, offline, notConfigured }
enum ConversationObserverLifecycle: String { case foregroundIdle, streaming, reconnecting, background, unknown }

@MainActor final class ConversationFirstModel: ObservableObject {
    let repository: Repository
    let service: ConversationSessionService
    let imageStore:any ConversationImageByteStore
    let scope: DataScope
    @Published private(set) var imageDraft=ImageAttachmentDraft()
    private var imageDrafts:[UUID:ImageAttachmentDraft]=[:]
    @Published private(set) var imageCapability=ConversationImageCapability()
    private var imageSubscription:AnyCancellable?
    @Published var pendingImageConsent:ConversationImageConsent?
    @Published private(set) var checkingImageConsent=false
    private var imageConsentTask:Task<Void,Never>?
    private var imageRecoveryTask:Task<Void,Never>?
    private var imageRecoveryToken:UUID?
    private var imageReview:ImageReview?
    private var approvedImage:ApprovedImage?
    private var imageConsentEpoch=UUID()
    private var cleanedImageOperations:Set<UUID>=[]
    private var recoveredImageOperation:UUID?
    private struct ImageReview {let conversation:UUID;let preview:UUID;let hash:String;let captionHash:String;let generation:Int}
    private struct ApprovedImage {let conversation:UUID;let preview:UUID;let hash:String;let captionHash:String;let route:String;let revision:Int}

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
    @Published private(set) var editingFollowup = false
    var imageGate:ImageSendGate { .init(available:imageCapability.available,liveTransmissionAvailable:imageCapability.liveTransmissionAvailable,textConsentGranted:consentReady,imageConsentMatchesCurrentRoute:approvedImageMatchesDraft) }
    var imageSendBlock:ImageSendBlock? { imageDraft.phase == .empty ? nil : imageDraft.sendBlock(caption:draft,messageID:UUID(),gate:imageGate) }
    var canAcceptDraft: Bool { (imageDraft.phase == .empty || canAdmitImage) && imageSendBlock == nil && loaded && !isInputComposing && session?.unresolved?.state != .unknown && !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && draft.utf16.count <= 8000 && outgoingMessages.count < 20 }
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
    private var modelConsentReview:ConversationModelConsent?
    private var connectionProbeID=UUID()
    private var reflectedReplyID:UUID?
    init(repository:Repository,service:ConversationSessionService,scope:DataScope = Profiles.user,imageStore:any ConversationImageByteStore = MemoryConversationImageByteStore()) {
        self.repository=repository;self.service=service;self.scope=scope;self.imageStore=imageStore
        subscribeToImageDraft()
    }
    private func subscribeToImageDraft() {
        imageSubscription?.cancel()
        imageSubscription=imageDraft.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.imageSelectionChanged();self?.objectWillChange.send() } }
    }
    private var approvedImageMatchesDraft:Bool {
        guard let a=approvedImage,let p=imageDraft.attachment else {return false}
        return a.conversation==conversationID && a.preview==p.id && a.hash==p.sha256 && a.captionHash==textHash(draft) && a.route==imageCapability.routeHash
    }
    private var canAdmitImage:Bool {loaded && foreground && networkAdmissionAllowed && !busy && !enqueueing && session?.unresolved==nil && session?.pendingUnsent==nil && followups.pending.isEmpty && followups.inflight==nil}
    var canReviewImage:Bool {canAdmitImage && imageCapability.available && imageCapability.liveTransmissionAvailable && imageDraft.phase == .ready && !isInputComposing && !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !checkingImageConsent}
    private func imageSelectionChanged() {
        if let review=imageReview,!reviewMatches(review) {cancelImageConsent()}
        if !approvedImageMatchesDraft {approvedImage=nil}
    }
    private func reviewMatches(_ value:ImageReview)->Bool {
        loaded && foreground && networkAdmissionAllowed && value.conversation==conversationID && value.generation==sceneGeneration && imageDraft.phase == .ready && imageDraft.attachment?.id==value.preview && imageDraft.attachment?.sha256==value.hash && textHash(draft)==value.captionHash
    }
    func requestImageConsent() {
        guard canReviewImage,let id=conversationID,let preview=imageDraft.attachment else {return}
        cancelImageConsent();imageReview = .init(conversation:id,preview:preview.id,hash:preview.sha256,captionHash:textHash(draft),generation:sceneGeneration)
        let epoch=imageConsentEpoch;checkingImageConsent=true
        imageConsentTask=Task {
            defer {if imageConsentEpoch==epoch {checkingImageConsent=false}}
            do {
                if !consentReady {
                    let consent=try await service.modelConsent(scope:scope,conversationID:id)
                    guard imageConsentEpoch==epoch,let review=imageReview,reviewMatches(review),!Task.isCancelled else {return}
                    if let consent {presentModelConsent(consent);return};consentReady=true
                }
                fetchImageConsent()
            } catch {if imageConsentEpoch==epoch {self.error=error.localizedDescription;cancelImageConsent()}}
        }
    }
    private func fetchImageConsent() {
        guard let review=imageReview,reviewMatches(review),consentReady else {cancelImageConsent();return}
        let epoch=UUID();imageConsentEpoch=epoch;checkingImageConsent=true
        imageConsentTask=Task {
            defer {if imageConsentEpoch==epoch {checkingImageConsent=false}}
            do {
                let consent=try await service.imageConsent(scope:scope,conversationID:review.conversation,previewID:review.preview,previewHash:review.hash)
                guard imageConsentEpoch==epoch,reviewMatches(review),!Task.isCancelled,consent.conversationID==review.conversation,consent.previewID==review.preview,consent.previewHash==review.hash,consent.routeHash==imageCapability.routeHash else {return}
                pendingImageConsent=consent
            } catch {if imageConsentEpoch==epoch {self.error=error.localizedDescription;cancelImageConsent()}}
        }
    }
    func allowPendingImageConsent(_ consent:ConversationImageConsent,confirmed:Bool) {
        guard confirmed,pendingImageConsent==consent,let review=imageReview,reviewMatches(review),consent.routeHash==imageCapability.routeHash else {return}
        imageConsentTask?.cancel();let epoch=UUID();imageConsentEpoch=epoch;checkingImageConsent=true
        imageConsentTask=Task {
            defer {if imageConsentEpoch==epoch {checkingImageConsent=false}}
            do {
                let revision=try await service.allowImageConsent(scope:scope,consent:consent,nonSensitiveConfirmed:true)
                guard imageConsentEpoch==epoch,reviewMatches(review),!Task.isCancelled,revision==consent.expectedRevision+1 else {return}
                approvedImage = .init(conversation:review.conversation,preview:review.preview,hash:review.hash,captionHash:review.captionHash,route:consent.routeHash,revision:revision)
                imageReview=nil;pendingImageConsent=nil
            } catch {if imageConsentEpoch==epoch {self.error=error.localizedDescription;cancelImageConsent()}}
        }
    }
    func cancelImageConsent() {
        let hadReview=imageReview != nil
        imageConsentEpoch=UUID();imageConsentTask?.cancel();imageConsentTask=nil;imageReview=nil;pendingImageConsent=nil;checkingImageConsent=false;approvedImage=nil
        if hadReview {pendingModelConsent=nil;modelConsentReview=nil}
    }
    private func recoverOrCleanImage(_ current:ConversationSession) {
        for turn in current.turns where turn.state == .completed && turn.request.image != nil && !cleanedImageOperations.contains(turn.id) {
            cleanedImageOperations.insert(turn.id)
            if imageDraft.attachment?.id==turn.request.image?.receipt.id {imageDraft.clear()}
            if recoveredImageOperation==turn.id {if draft==turn.request.history.last?.content {editDraft("")};recoveredImageOperation=nil}
            Task {try? await imageStore.remove(conversationID:current.conversationID,operationID:turn.id)}
        }
        guard imageRecoveryTask==nil,imageDraft.phase == .empty else {return}
        let candidate=(followups.paused ? followups.pending.first(where:{$0.image != nil}) : nil).map{($0.id,$0.image!,$0.text)} ?? current.turns.last(where:{[.unknown,.failed,.notSent].contains($0.state) && $0.request.image != nil}).map{($0.id,$0.request.image!,$0.request.history.last?.content ?? "")}
        guard let (operation,reference,text)=candidate else {return}
        let id=current.conversationID,generation=sceneGeneration,token=UUID();imageRecoveryToken=token
        imageRecoveryTask=Task {
            defer {if imageRecoveryToken==token {imageRecoveryTask=nil;imageRecoveryToken=nil}}
            do {
                let bytes=try await imageStore.read(reference:reference,conversationID:id,operationID:operation)
                let packet=try await SystemImageAttachmentEncoder().encode(bytes,id:reference.receipt.id,format:.png,limits:.init())
                guard !Task.isCancelled,conversationID==id,sceneGeneration==generation,loaded,imageDraft.phase == .empty,packet.sha256==reference.receipt.sha256 else {return}
                let unresolved=(followups.paused && followups.pending.contains(where:{$0.id==operation})) || session?.turns.contains(where:{$0.id==operation && [.unknown,.failed,.notSent].contains($0.state)})==true
                guard unresolved else {return};imageDraft.restorePrepared(packet);recoveredImageOperation=operation;if draft.isEmpty {draft=text}
            } catch {if conversationID==id,loaded,!Task.isCancelled {self.error="本机图片读取未完成，原请求已保留。"}}
        }
    }
    func start() async {
        guard !loaded else { return }
        do {
            let id=try await service.openLatest(scope:scope);try await select(id)
            let snapshot=await repository.read(scope:scope)
            subscription=Task { [weak self,repository,scope] in
                for await notice in await repository.changes(scope:scope,after:snapshot.sequence) { guard let self,!Task.isCancelled else { return };let headerChanged=notice.recordIDs.contains(where:{id in self.history.contains(where:{$0.id == id}) || id == self.conversationID});await self.refresh(rebuildHistory:headerChanged) }
            }
            loaded=true;await resumeForeground()
        } catch { self.error=error.localizedDescription }
    }
    func refresh(rebuildHistory:Bool = true) async {
        guard let id=conversationID else { return }
        refreshGeneration += 1;let generation=refreshGeneration
        do {
            if rebuildHistory {
            let snapshot=await repository.read(scope:scope)
            #if DEBUG
            let historyStart=ProcessInfo.processInfo.systemUptime
            #endif
            history=snapshot.list("conversation",scope:scope).filter { snapshot.records[stableID("conversation-first-journal-\($0.id)")] != nil }
            #if DEBUG
            P0PerformanceLog.shared.record("history_rebuild",start:historyStart,end:ProcessInfo.processInfo.systemUptime,main:true,count:history.count)
            #endif
            }
            let current=try await service.read(scope:scope,conversationID:id)
            let queued=try await queue?.state() ?? ConversationFollowupState()
            guard conversationID == id,refreshGeneration == generation else { return };session=current;followups=queued
            let durable=(queued.pending + [queued.inflight].compactMap { $0 })
            let unresolvedIDs=Set(current.turns.filter { [.unknown,.notSent].contains($0.state) }.map(\.id))
            outgoingMessages=outgoingMessages.filter { value in
                value.state == .savingLocal || value.state == .failed || durable.contains(where:{$0.id == value.id}) || unresolvedIDs.contains(value.id)
            }
            for value in durable where !outgoingMessages.contains(where:{$0.id == value.id}) { outgoingMessages.append(.init(id:value.id,text:value.text,image:value.image?.receipt,state:.queued,error:nil)) }
            for i in outgoingMessages.indices {
                let value=outgoingMessages[i]
                if let turn=current.turns.first(where:{$0.id == value.id}) {
                    switch turn.state { case .unknown: outgoingMessages[i].state = .unknown;case .notSent: outgoingMessages[i].state = .queued;default: break }
                }
            }
            if foreground,!busy,current.unresolved == nil { observerLifecycle = .foregroundIdle }
            recoverOrCleanImage(current)
            if let completed=current.turns.last(where:{$0.state == .completed}),reflectedReplyID != completed.id,
               let evidence=await service.recordedReplyEvidence(scope:scope),conversationID==id,refreshGeneration==generation,foreground,networkAdmissionAllowed {
                reflectedReplyID=completed.id;connection=evidence;connectionLifecycle = .available
            }
        } catch { self.error=error.localizedDescription }
    }
    func select(_ id:UUID) async throws {
        guard !busy,!isInputComposing else { throw ConversationSessionError.busy }
        if conversationID == id { return }
        await persistenceTask?.value
        guard !busy,!isInputComposing else { throw ConversationSessionError.busy }
        busy=true;defer { busy=false }
        try await flushDraft();let saved=try await repository.record(id,scope:scope),selected=try await service.read(scope:scope,conversationID:id)
        try await service.rememberSelection(scope:scope,conversationID:id)
        permissionTask?.cancel();permissionID=nil;pendingModelConsent=nil;modelConsentReview=nil;checkingModelConsent=false;consentReady=false
        queue=ConversationFollowupQueueService(repository:repository,scope:scope,conversationID:id)
        cancelImageConsent();imageRecoveryTask?.cancel();imageRecoveryTask=nil;imageRecoveryToken=nil
        if let prior=conversationID {
            if imageDraft.phase == .empty {imageDrafts.removeValue(forKey:prior)}
            else {imageDraft.cancelProcessing();imageDrafts[prior]=imageDraft}
        }
        imageDraft=imageDrafts.removeValue(forKey:id) ?? ImageAttachmentDraft();subscribeToImageDraft()
        recoveredImageOperation=nil;imageCapability=ConversationImageCapability()
        conversationID=id;session=selected;draft=saved.conversation?.draftText ?? "";outgoingMessages=[];tapTimes=[:];isInputComposing=false;error=nil;await refresh();if loaded && foreground && networkAdmissionAllowed {connectionTask?.cancel();connectionTask=Task{await refreshConnection()}}
    }
    func newConversation() { guard !isInputComposing else { return };Task { do { await persistenceTask?.value;try await flushDraft();let id=try await service.create(scope:scope);try await select(id) } catch { self.error=error.localizedDescription } } }
    func updateInputComposition(_ active:Bool) { guard active != isInputComposing else { return };isInputComposing=active }
    func editDraft(_ text:String) {
        draft=text;imageSelectionChanged();draftTask?.cancel();guard let id=conversationID else { return }
        draftTask=Task { do { try await Task.sleep(nanoseconds:300_000_000);try Task.checkCancellation();try await service.saveDraft(scope:scope,conversationID:id,text:text) } catch is CancellationError { } catch { self.error=error.localizedDescription } }
    }
    func flushDraft() async throws { draftTask?.cancel();draftTask=nil;if let id=conversationID { try await service.saveDraft(scope:scope,conversationID:id,text:draft) } }
    // This synchronous capture is local intent, never a server admission or successful send.
    func prepareSend() {
        if let block=imageSendBlock { error=block.message;return }
        guard canAcceptDraft,let id=conversationID,let queue else { return }
        let tap=ProcessInfo.processInfo.systemUptime
        let prepared=imageDraft.attachment
        let payload:ConversationVisionPayload?
        if let prepared {
            guard imageDraft.phase == .ready,let approvedImage,approvedImageMatchesDraft else {return}
            let receipt=ConversationImageReceipt(id:UUID(),mimeType:prepared.mimeType,sha256:prepared.sha256,size:prepared.encodedData.count,width:prepared.width,height:prepared.height)
            payload = .init(reference:.init(receipt:receipt,routeHash:approvedImage.route,consentRevision:approvedImage.revision),bytes:prepared.encodedData)
        } else {payload=nil}
        let message=ConversationFollowup(text:draft,image:payload?.reference)
        draftTask?.cancel();draftTask=nil
        tapTimes[message.id]=tap;outgoingMessages.append(.init(id:message.id,text:message.text,image:payload?.reference.receipt,state:.savingLocal,error:nil));draft=""
        savingCount += 1;enqueueing=true;tapToLocalPublishMs=(ProcessInfo.processInfo.systemUptime-tap)*1000
        let previous=persistenceTask
        persistenceTask=Task {
            await previous?.value
            defer { savingCount -= 1;enqueueing=savingCount > 0 }
            do {
                if let payload {try await imageStore.save(payload,conversationID:id,operationID:message.id)}
                try await queue.enqueue(message,remainingDraft:draft)
                if let prepared,imageDraft.attachment?.id==prepared.id,imageDraft.attachment?.sha256==prepared.sha256 {imageDraft.clear();approvedImage=nil}
                guard conversationID == id else { return }
                setIntent(message.id,.queued);await refresh()
                if foreground { authorizePending() }
            } catch {
                if payload != nil {try? await imageStore.remove(conversationID:id,operationID:message.id)}
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
                if let consent { presentModelConsent(consent);for i in outgoingMessages.indices where outgoingMessages[i].state == .queued { outgoingMessages[i].state = .awaitingPermission } }
                else { consentReady=true;drainQueue() }
            } catch { if permissionID == token { self.error="尚未发送；连接或许可读取未完成，本机消息已保留。" } }
        }
    }
    func allowPendingModelConsent(_ consent:ConversationModelConsent) {
        guard networkAdmissionAllowed,foreground,loaded,conversationID == consent.conversationID,
              let review=modelConsentReview,review.conversationID==consent.conversationID,
              review.routeHash==consent.routeHash,review.expectedRevision==consent.expectedRevision,
              review.title==consent.title,review.body==consent.body else {return}
        modelConsentReview=nil
        permissionTask?.cancel();let token=UUID();permissionID=token;checkingModelConsent=true;pendingModelConsent=nil
        permissionTask=Task {
            defer { if permissionID == token { permissionTask=nil;checkingModelConsent=false } }
            do { try await service.allowModelConsent(scope:scope,consent:consent);guard !Task.isCancelled,permissionID == token,foreground,conversationID == consent.conversationID else { return };consentReady=true;if imageReview != nil {fetchImageConsent()} else {drainQueue()} }
            catch { if permissionID == token { self.error="许可保存未确认，本机消息已保留，未发送。" } }
        }
    }
    private func presentModelConsent(_ consent:ConversationModelConsent) {
        modelConsentReview=consent;pendingModelConsent=consent
    }
    var needsModelConsentReview:Bool {!consentReady && (modelConsentReview != nil || !followups.pending.isEmpty)}
    var canReviewModelConsent:Bool {loaded && foreground && networkAdmissionAllowed && !checkingModelConsent && !busy && session?.unresolved==nil}
    func requestModelConsentReview() {
        guard canReviewModelConsent else{return}
        if let review=modelConsentReview,review.conversationID==conversationID {pendingModelConsent=review;return}
        if followups.paused {resumeFollowups()} else {authorizePending()}
    }
    func deferModelConsent(_ consent:ConversationModelConsent?=nil) {
        if let consent {guard modelConsentReview?.conversationID==consent.conversationID,modelConsentReview?.routeHash==consent.routeHash,modelConsentReview?.expectedRevision==consent.expectedRevision else{return}}
        modelConsentReview=nil;pendingModelConsent=nil;consentReady=false
        if imageReview != nil {cancelImageConsent()}
        Task {try? await queue?.pause();await refresh()}
    }
    private var canDispatchFollowup:Bool { loaded && foreground && networkAdmissionAllowed }
    private func drainQueue() {
        guard networkAdmissionAllowed,foreground,let id=conversationID,let queue,!busy,session?.unresolved == nil else { return }
        let token=UUID();flightID=token;busy=true;sending=true;observerLifecycle = .streaming;error=nil
        turnTask=Task {
            defer { if flightID == token { flightID=nil;busy=false;sending=false;observerLifecycle=session?.unresolved == nil ? .foregroundIdle : .unknown } }
            do {
                try await queue.flush { [service,scope,imageStore,weak self] message in
                    guard !Task.isCancelled,await self?.canDispatchFollowup == true else { return .heldBeforeAdmission }
                    await self?.setIntent(message.id,.sending)
                    do {
                        let image:ConversationVisionPayload?
                        if let reference=message.image {let bytes=try await imageStore.read(reference:reference,conversationID:id,operationID:message.id);image = .init(reference:reference,bytes:bytes)} else {image=nil}
                        guard !Task.isCancelled,await self?.canDispatchFollowup == true else {return .heldBeforeAdmission}
                        _=try await service.send(scope:scope,conversationID:id,text:message.text,operationID:message.id,preserveDraft:true,image:image);return .sent
                    }
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
    func pauseQueueForEditing(_ message:ConversationFollowup) async throws {
        guard loaded,foreground,!editingFollowup,let queue,let id=conversationID else {throw ConversationSessionError.busy}
        try await queue.pause();await refresh()
        guard conversationID == id,followups.pending.contains(where:{$0.id == message.id && $0.text == message.text && $0.image == message.image}) else {throw CatpawError.conflict}
    }
    func editFollowup(_ message:ConversationFollowup,text:String) async throws {
        guard loaded,foreground,!editingFollowup,let queue,let id=conversationID else {throw ConversationSessionError.busy}
        editingFollowup=true;defer {editingFollowup=false}
        _=try await queue.edit(message,text:text,session:service)
        guard conversationID == id else {return}
        outgoingMessages.removeAll {$0.id == message.id};await refresh()
    }
    func removeFollowup(_ id:UUID) { Task { do { if let conversationID { try await service.discardUnsent(scope:scope,conversationID:conversationID,operationID:id) };try await queue?.remove(id);if let conversationID {try await imageStore.remove(conversationID:conversationID,operationID:id)};outgoingMessages.removeAll { $0.id == id };await refresh() } catch { self.error=error.localizedDescription } } }
    func resumeFollowups() {
        guard foreground,!busy,!editingFollowup,session?.unresolved == nil,let queue else { return }
        Task { do {
            let state=try await queue.state()
            if let original=state.inflight,let id=conversationID { let saved=try await service.read(scope:scope,conversationID:id);try await queue.reconcileInflight(admitted:saved.turns.contains { $0.id == original.id && ![.notSent,.cancelledBeforeSend].contains($0.state) }) }
            try await queue.resume();await refresh();authorizePending()
        } catch { self.error=error.localizedDescription } }
    }
    func setNetworkAdmissionAllowed(_ allowed:Bool) {
        guard allowed != networkAdmissionAllowed else { return };networkAdmissionAllowed=allowed
        if allowed { Task { await resumeForeground();authorizePending() } }
        else { permissionTask?.cancel();permissionTask=nil;permissionID=nil;checkingModelConsent=false;pendingModelConsent=nil;modelConsentReview=nil;connectionProbeID=UUID();connectionTask?.cancel();connectionLifecycle = .checking }
    }
    func refreshConnection() async {
        guard foreground,networkAdmissionAllowed else {connectionLifecycle = .checking;return}
        let generation=sceneGeneration,probe=UUID(),id=conversationID;connectionProbeID=probe
        connectionLifecycle = session?.unresolved == nil ? .checking : .reconnecting
        for attempt in 0..<3 {
            guard !Task.isCancelled,foreground,networkAdmissionAllowed,generation==sceneGeneration,connectionProbeID==probe else{return}
            let value=await service.connection(scope:scope)
            guard !Task.isCancelled,foreground,networkAdmissionAllowed,generation==sceneGeneration,connectionProbeID==probe else{return}
            connection=value
            switch value.state {case .connected,.providerUnverified:connectionLifecycle = .available;case .unavailable:connectionLifecycle = .offline;case .notConfigured:connectionLifecycle = .notConfigured}
            if value.state != .unavailable || attempt==2 {break}
            connectionLifecycle = .reconnecting
            do {try await Task.sleep(nanoseconds:attempt==0 ? 500_000_000 : 1_000_000_000)} catch{return}
        }
        // Optional image metadata never delays publishing basic connectivity.
        if let id,conversationID==id,connectionLifecycle == .available {
            do {let capability=try await service.imageCapabilities(scope:scope,conversationID:id)
                guard !Task.isCancelled,foreground,networkAdmissionAllowed,generation==sceneGeneration,connectionProbeID==probe,conversationID==id else{return};imageCapability=capability
            } catch {if foreground,networkAdmissionAllowed,generation==sceneGeneration,connectionProbeID==probe,conversationID==id {imageCapability=ConversationImageCapability(state:"unavailable",detail:error.localizedDescription)}}
        }
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
        case .background:cancelImageConsent();let finish=beginSuspension();Task { await finish.value }
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
        if session?.unresolved != nil { readOriginal() } else { await resumeBackgroundQueueIfSafe();authorizePending() }
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
        cancelImageConsent();sceneGeneration += 1;foreground=false;foregroundTask?.cancel();foregroundTask=nil;connectionTask?.cancel()
        permissionTask?.cancel();permissionTask=nil;permissionID=nil;checkingModelConsent=false;pendingModelConsent=nil;modelConsentReview=nil;connectionProbeID=UUID()
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
        loaded=false;networkAdmissionAllowed=false;cancelImageConsent();imageRecoveryTask?.cancel();imageRecoveryTask=nil;imageRecoveryToken=nil
        imageDraft.clear();for value in imageDrafts.values {value.clear()};imageDrafts.removeAll();imageCapability=ConversationImageCapability()
        await suspend();subscription?.cancel();subscription=nil;draftTask?.cancel();draftTask=nil
        draft="";history=[];session=nil;conversationID=nil;followups=ConversationFollowupState();queue=nil;outgoingMessages=[];tapTimes=[:];isInputComposing=false;error=nil;loaded=false
    }
}
