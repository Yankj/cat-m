import Foundation
import SwiftUI
import os
import Combine
import CatpawImageComposer

struct OutgoingMessageIntent: Identifiable, Equatable {
    enum State: String { case savingLocal, queued, awaitingPermission, sending, unknown, failed }
    let id: UUID
    let text: String
    var image:ConversationImageReceipt? = nil
    var continuation:ConversationArtifactContinuationIntent? = nil
    var acceptedWork:ConversationAcceptedWorkSelection? = nil
    var revisionWork:ConversationRevisionWorkSelection? = nil
    var state: State
    var error: String?
}
enum ConversationConnectionLifecycle: String { case checking, available, reconnecting, offline, notConfigured }
enum ConversationObserverLifecycle: String { case foregroundIdle, streaming, reconnecting, background, unknown }

private let sendLog=Logger(subsystem:"catpaw",category:"send")
@MainActor final class ConversationFirstModel: ObservableObject {
    let repository: Repository
    let service: ConversationSessionService
    let taskPlanService:ConversationTaskPlanService
    let artifactEditService:ConversationArtifactEditService
    let taskControlService:ConversationTaskControlService
    let inboxService:ConversationInboxService?
    let memoryService:ConversationMemoryService?
    let memoryConfigured:Bool
    let taskControlsConfigured:Bool
    @Published var selectedTaskControl:ConversationTaskControlReference?
    let taskActionService:ConversationTaskActionService
    let taskReviewsConfigured:Bool
    let artifactEditsConfigured:Bool
    let trustedSubjectID:UUID?
    let artifactContinuationService:ConversationArtifactContinuationService
    let acceptedWorkDraftService:ConversationAcceptedWorkDraftService
    @Published private(set) var acceptedWorkReviewOriginalText=""
    @Published private(set) var revisionWorkReviewTarget:ConversationArtifactContinuationReference?
    @Published var acceptedWorkReviewPresented=false
    @Published private(set) var acceptedWorkDraft:ConversationAcceptedWorkDraft?
    @Published var acceptedWorkOptions=ConversationAcceptedWorkOptions(notAfter:Date().addingTimeInterval(3600),executionBudgetMilliseconds:60_000,modelLimit:3,sourceLimit:0,toolPolicy:.localOutput)
    @Published private(set) var acceptedWorkCapability=ConversationAcceptedWorkCapability()
    @Published private(set) var acceptedWorkReviewSaving=false
    @Published private(set) var acceptedWorkReviewError:String?
    private var acceptedWorkReviewTask:Task<Void,Never>?
    private var acceptedWorkReviewToken:UUID?
    private var acceptedWorkConfirming=false
    private var acceptedWorkDraftTask:Task<Void,Never>?
    @Published private(set) var artifactContinuation:ConversationArtifactContinuationReference?
    @Published private(set) var switchingArtifactContinuation=false
    @Published private(set) var continuationDraftSaved=true
    private var continuationEditSequence=0
    private var continuationClosing=false
    private var ordinaryContinuationImage:ImageAttachmentDraft?
    @Published var selectedTaskActions:ConversationTaskActionReference?
    let generativeUIStateService:ConversationGenerativeUIStateService
    let taskPlansConfigured:Bool
    @Published var selectedTaskPlan:ConversationTaskPlanReference?
    let imageStore:any ConversationImageByteStore
    let scope: DataScope
    @Published private(set) var imageDraft=ImageAttachmentDraft()
    private var imageDrafts:[UUID:ImageAttachmentDraft]=[:]
    @Published private(set) var imageCapability=ConversationImageCapability()
    private var imageSubscription:AnyCancellable?
    @Published var pendingImageConsent:ConversationImageConsent?
    @Published private(set) var imageConsentReviewToken:UUID?
    @Published private(set) var checkingImageConsent=false
    private var imageConsentTask:Task<Void,Never>?
    private var imageRecoveryTask:Task<Void,Never>?
    private var imageRecoveryToken:UUID?
    private var imageReview:ImageReview?
    private var imageConsentReview:ConversationImageConsent?
    private var consumedImageConsentReviewToken:UUID?
    private var approvedImage:ApprovedImage?
    private var imageConsentEpoch=UUID()
    private var cleanedImageOperations:Set<UUID>=[]
    private var recoveredImageOperation:UUID?
    private var recoveredImageReceipt:String?
    private var recoveredImageCaption:String?
    /// 重试 on a failed image turn: restore that image + its own caption, then send through the normal path (consent included).
    private var retrySendAfterRestore:UUID?
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
    var canAcceptDraft: Bool { !continuationClosing && !switchingArtifactContinuation && artifactContinuationSendBlock==nil && (imageDraft.phase == .empty || canAdmitImage) && imageSendBlock == nil && loaded && !isInputComposing && session?.unresolved?.state != .unknown && !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && draft.utf16.count <= 8000 && outgoingMessages.count < 20 }
    var artifactContinuationSendBlock:String? {
        guard let reference=artifactContinuation else {return nil}
        guard service.supportsArtifactContinuations,let subject=trustedSubjectID,service.artifactContinuationSubjectID==subject else {return "当前连接暂不支持针对成果继续，草稿已保留。"}
        guard reference.planReference != nil else {return "请先读取这项工作的最新计划，再选择要继续的成果版本。"}
        guard let goal=session?.goals[reference.goalID],(goal.sourceAuthorizationCurrent != false || (reference.mode == .reviseReport && goal.revisionRequiresNewWork==true)),goal.binding==reference.binding else {return "这项工作当前不能继续，原版本和输入会保留。"}
        if reference.mode == .reviseReport,goal.revisionRequiresNewWork==true,goal.revisionWorkPolicy==nil {return "工作约定读取未完成，原文和草稿会保留。"}
        guard goal.planReference==reference.planReference else {return "工作计划已变化。请核对后重新选择成果版本，当前输入会保留。"}
        if reference.mode == .reviseReport,let latest=goal.artifacts.first(where:{$0.id==reference.artifactReference.artifactID}),ConversationArtifactVersionReference(ConversationArtifactIdentity(latest)) != reference.artifactReference {return "成果已有新版。请核对后重新选择，当前输入会保留。"}
        return nil
    }
    @Published var pendingModelConsent: ConversationModelConsent?
    @Published private(set) var modelConsentReviewToken:UUID?
    @Published private(set) var checkingModelConsent = false
    @Published private(set) var isInputComposing = false
    @Published var draft = ""
    @Published var error: String?
    /// Set when the server says the daily model quota is used up. Sends are held in the composer (never piled
    /// into the paused outbox) and a neutral system notice explains when it resets.
    @Published var quotaNotice: Bool = false
    /// True while the latest turn failed on the daily quota (SSE) or a send was refused for it.
    var quotaReached: Bool { quotaNotice || (session?.turns.last.map { $0.state == .failed && ConversationTerminalServerError.isQuota($0.error) } ?? false) }
    func retryAfterQuota() {
        quotaNotice=false;error=nil
        if draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let last=session?.turns.last, last.state == .failed, ConversationTerminalServerError.isQuota(last.error),
           let text=session?.messages.last(where:{ $0.role == .user })?.content { editDraft(text) }
        if !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { send() }
    }
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
    private struct TaskControlDelivery {
        let reference:ConversationTaskControlReference
        let receipt:ConversationTaskControlReceipt
        var failures=0
        var nextAttemptAt=Date.distantPast
        var key:String {reference.id.uuidString.lowercased()+":"+receipt.operation_id+":"+receipt.receipt_hash}
    }
    private var pendingTaskControlDeliveries:[UUID:TaskControlDelivery]=[:]
    private var deliveredTaskControlReceipts:Set<String>=[]
    private var taskControlDeliveryTask:Task<Void,Never>?
    private var taskControlDeliveryToken:UUID?
    private var taskControlDeliveryGeneration=0
    init(repository:Repository,service:ConversationSessionService,scope:DataScope = Profiles.user,imageStore:any ConversationImageByteStore = MemoryConversationImageByteStore(),taskPlanService:ConversationTaskPlanService?=nil,artifactEditService:ConversationArtifactEditService?=nil,taskActionService:ConversationTaskActionService?=nil,taskControlService:ConversationTaskControlService?=nil,memoryService:ConversationMemoryService?=nil,inboxService:ConversationInboxService?=nil,subjectID:UUID?=nil) {
        self.repository=repository;self.service=service;self.scope=scope;self.imageStore=imageStore
        self.taskPlansConfigured=taskPlanService != nil
        self.taskPlanService=taskPlanService ?? ConversationTaskPlanService(repository:repository,scope:scope)
        self.artifactEditService=artifactEditService ?? ConversationArtifactEditService(repository:repository,scope:scope)
        self.taskActionService=taskActionService ?? ConversationTaskActionService(repository:repository,scope:scope)
        self.taskControlService=taskControlService ?? ConversationTaskControlService(repository:repository,scope:scope)
        self.taskControlsConfigured=taskControlService != nil && subjectID != nil
        let validMemory=memoryService?.reference.scope==scope && memoryService?.reference.subjectID==subjectID && subjectID != nil
        self.memoryService=validMemory ? memoryService : nil
        self.memoryConfigured=validMemory
        MemoryLibraryHub.install(validMemory ? memoryService : nil) // wave2 V1: backend for the inline 已记住 chip
        self.inboxService=inboxService?.reference.scope==scope && inboxService?.reference.subjectID==subjectID ? inboxService : nil
        self.trustedSubjectID=subjectID
        self.acceptedWorkDraftService=ConversationAcceptedWorkDraftService(repository:repository,scope:scope,subjectID:subjectID)
        self.artifactContinuationService=ConversationArtifactContinuationService(repository:repository,scope:scope,subjectID:subjectID)
        self.taskReviewsConfigured=taskActionService != nil && subjectID != nil
        self.artifactEditsConfigured=artifactEditService != nil && subjectID != nil
        self.generativeUIStateService=ConversationGenerativeUIStateService(repository:repository,scope:scope)
        subscribeToImageDraft()
    }
    var canReviewAcceptedWork:Bool {
        loaded && foreground && networkAdmissionAllowed && !busy && !enqueueing && !isInputComposing && artifactContinuation==nil && imageDraft.phase == .empty && session?.unresolved==nil && session?.pendingUnsent==nil && followups.pending.isEmpty && !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && draft.utf16.count<=8000 && !acceptedWorkReviewSaving
    }
    var revisionWorkReviewPolicy:ConversationRevisionWorkPolicy? {revisionWorkReviewTarget.flatMap{session?.goals[$0.goalID]?.revisionWorkPolicy}}
    var revisionRequiresWorkReview:Bool {artifactContinuation?.mode == .reviseReport && artifactContinuation.flatMap{session?.goals[$0.goalID]?.revisionRequiresNewWork}==true}
    var canReviewRevisionWork:Bool {
        loaded && foreground && networkAdmissionAllowed && !busy && !enqueueing && !isInputComposing && revisionRequiresWorkReview && artifactContinuationSendBlock==nil && imageDraft.phase == .empty && session?.unresolved==nil && session?.pendingUnsent==nil && followups.pending.isEmpty && !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && draft.utf16.count<=8000 && !acceptedWorkReviewSaving
    }
    func requestAcceptedWorkReview() {
        guard canReviewAcceptedWork || canReviewRevisionWork,let id=conversationID else {return}
        let reviewTarget=canReviewRevisionWork ? artifactContinuation:nil
        let target:ConversationArtifactContinuationIntent?
        do {target=try reviewTarget?.sendIntent()}catch{self.error=error.localizedDescription;return}
        let policy=reviewTarget.flatMap{session?.goals[$0.goalID]?.revisionWorkPolicy}
        guard reviewTarget==nil || policy != nil else {return}
        revisionWorkReviewTarget=reviewTarget
        acceptedWorkReviewTask?.cancel();let token=UUID(),raw=draft
        acceptedWorkReviewToken=token;acceptedWorkReviewOriginalText=raw;acceptedWorkCapability = .init();acceptedWorkReviewError=nil;acceptedWorkReviewPresented=true;acceptedWorkReviewSaving=true
        acceptedWorkReviewTask=Task {
            defer {if acceptedWorkReviewToken==token {acceptedWorkReviewSaving=false;acceptedWorkReviewTask=nil}}
            do {
                let saved=try await acceptedWorkDraftService.read(conversationID:id)
                guard !Task.isCancelled,acceptedWorkReviewToken==token,conversationID==id,loaded else {return}
                let matches=saved?.raw.utf8.elementsEqual(raw.utf8)==true && saved?.revisionTarget==target && (policy==nil || (saved.map{(try? policy!.validate(options:$0.options)) != nil} ?? false))
                let value=matches ? saved! : ConversationAcceptedWorkDraft(conversationID:id,raw:raw,options:.init(notAfter:Date().addingTimeInterval(3600),executionBudgetMilliseconds:60_000,modelLimit:3,sourceLimit:policy?.sourceCount ?? 0,toolPolicy:policy?.toolPolicy ?? .localOutput),revisionTarget:target)
                try await acceptedWorkDraftService.save(value,replaceUnconfirmed:!matches);try Task.checkCancellation()
                guard acceptedWorkReviewToken==token,conversationID==id,loaded else {return}
                acceptedWorkDraft=value;acceptedWorkOptions=value.options
                let capability:ConversationAcceptedWorkCapability
                if target==nil {capability=try await service.acceptedWorkCapability(scope:scope,conversationID:id)}else{capability=try await service.revisionWorkCapability(scope:scope,conversationID:id)}
                guard !Task.isCancelled,acceptedWorkReviewToken==token,conversationID==id,loaded,foreground,networkAdmissionAllowed else {return}
                acceptedWorkCapability=capability
            } catch is CancellationError {} catch {if acceptedWorkReviewToken==token {acceptedWorkReviewError="工作约定读取未完成，原文和草稿会保留。"}}
        }
    }
    func saveAcceptedWorkReviewOptions() {
        guard acceptedWorkReviewPresented,!acceptedWorkReviewSaving,var value=acceptedWorkDraft else {return}
        value.options=acceptedWorkOptions;acceptedWorkDraft=value;acceptedWorkDraftTask?.cancel()
        acceptedWorkDraftTask=Task {do {try await Task.sleep(nanoseconds:200_000_000);try Task.checkCancellation();try await acceptedWorkDraftService.save(value)}catch is CancellationError {}catch{acceptedWorkReviewError="工作约定尚未保存，请重新核对。"}}
    }
    func closeAcceptedWorkReview() {
        guard !acceptedWorkConfirming else {return}
        acceptedWorkReviewSaving=false;acceptedWorkReviewPresented=false;acceptedWorkReviewToken=nil;acceptedWorkReviewTask?.cancel();acceptedWorkReviewTask=nil;acceptedWorkDraftTask?.cancel()
        if var value=acceptedWorkDraft {value.options=acceptedWorkOptions;acceptedWorkDraft=value;acceptedWorkDraftTask=Task{do{try await acceptedWorkDraftService.save(value)}catch{self.error="工作约定尚未保存，请重新核对。"}}}
    }
    func confirmAcceptedWorkReview() {
        guard canReviewAcceptedWork || canReviewRevisionWork,acceptedWorkReviewPresented,let id=conversationID,var value=acceptedWorkDraft,value.conversationID==id,value.raw.utf8.elementsEqual(draft.utf8),acceptedWorkCapability.subjectID==trustedSubjectID else {return}
        if revisionWorkReviewTarget==nil {guard value.revisionTarget==nil,artifactContinuation==nil else {return}}
        else {guard revisionWorkReviewTarget==artifactContinuation,canReviewRevisionWork,let target=try? artifactContinuation?.sendIntent(),value.revisionTarget==target else {return}}
        value.options=acceptedWorkOptions
        let selection:ConversationAcceptedWorkSelection
        do {selection=try .init(decisionID:value.id,options:value.options,capability:acceptedWorkCapability);try selection.validate(capability:acceptedWorkCapability,now:Date())}catch{acceptedWorkReviewError="工作约定超出当前服务范围，请调整后确认。";return}
        acceptedWorkDraftTask?.cancel();acceptedWorkReviewSaving=true;acceptedWorkConfirming=true;let token=acceptedWorkReviewToken
        acceptedWorkReviewTask=Task {
            defer {acceptedWorkConfirming=false;if acceptedWorkReviewToken==token {acceptedWorkReviewSaving=false;acceptedWorkReviewTask=nil}}
            do {
                try await acceptedWorkDraftService.save(value);try Task.checkCancellation()
                guard acceptedWorkReviewToken==token,conversationID==id,draft.utf8.elementsEqual(value.raw.utf8),loaded,foreground,networkAdmissionAllowed else {return}
                acceptedWorkDraft=value
                if let target=value.revisionTarget {
                    guard revisionWorkReviewTarget==artifactContinuation,revisionRequiresWorkReview,artifactContinuationSendBlock==nil else {return}
                    guard let policy=revisionWorkReviewPolicy else {throw ConversationAcceptedWorkError.invalidSelection};try policy.validate(options:selection.options)
                    let revision=try ConversationRevisionWorkSelection(authorization:selection,target:target,originalText:value.raw)
                    prepareSend(revisionWork:revision,reviewDraft:value)
                } else {prepareSend(acceptedWork:selection,reviewDraft:value)}
                acceptedWorkReviewPresented=false
            }catch is CancellationError {}catch{acceptedWorkReviewError="工作约定尚未保存，请重新核对。"}
        }
    }
    func openTaskPlan(_ goal:ConversationGoalProjection) {
        guard taskPlansConfigured,loaded,let binding=goal.binding,session?.conversationID==binding.conversation_id else {return}
        selectedTaskPlan=ConversationTaskPlanReference(scope:scope,binding:binding,title:goal.title)
    }
    func openTaskControl(_ goal:ConversationGoalProjection) {
        guard taskControlsConfigured,loaded,let binding=goal.binding,let subject=trustedSubjectID,session?.conversationID==binding.conversation_id else {return}
        selectedTaskControl=ConversationTaskControlReference(scope:scope,binding:binding,subjectID:subject.uuidString.lowercased(),title:goal.title)
    }
    /// A confirmed receipt schedules an original-conversation GET. It never projects task completion.
    /// Closing the sheet or switching conversations cannot retarget or discard this delivery.
    func recordAppliedTaskControl(_ envelope:ConversationTaskControlEnvelope,reference:ConversationTaskControlReference) async throws {
        guard loaded,!continuationClosing,reference.scope==scope,reference.subjectID==trustedSubjectID?.uuidString.lowercased(),let receipt=envelope.operation else {throw ConversationTaskControlError.invalidResponse}
        let state=try await taskControlService.localState(reference)
        guard loaded,!continuationClosing,let submission=state.submissions[receipt.operation_id],submission.state == .applied,submission.receipt==receipt else {throw ConversationTaskControlError.invalidResponse}
        try envelope.validateApplied(reference:reference,request:submission.request,base:submission.base)
        queueTaskControlDelivery(reference:reference,receipt:receipt)
        drainTaskControlDeliveries()
    }
    private func queueTaskControlDelivery(reference:ConversationTaskControlReference,receipt:ConversationTaskControlReceipt) {
        let delivery=TaskControlDelivery(reference:reference,receipt:receipt)
        guard !deliveredTaskControlReceipts.contains(delivery.key) else {return}
        if let prior=pendingTaskControlDeliveries[reference.id],prior.key==delivery.key || prior.receipt.accepted_execution_revision>receipt.accepted_execution_revision {return}
        pendingTaskControlDeliveries[reference.id]=delivery
    }
    /// The existing scoped journal is the durable source after process loss. Re-reading it grants no HTTP authority.
    private func restoreAppliedTaskControlDeliveries(_ saved:ConversationSession) async {
        guard loaded,!continuationClosing,taskControlsConfigured,let subject=trustedSubjectID else {return}
        for goal in saved.goals.values {
            guard loaded,!continuationClosing else {return}
            guard let binding=goal.binding,binding.conversation_id==saved.conversationID else {continue}
            let reference=ConversationTaskControlReference(scope:scope,binding:binding,subjectID:subject.uuidString.lowercased(),title:goal.title)
            if let envelope=try? await taskControlService.appliedEnvelope(reference),let receipt=envelope.operation,loaded,!continuationClosing {queueTaskControlDelivery(reference:reference,receipt:receipt)}
        }
    }
    private func restoreAppliedTaskControlDeliveriesAcrossConversations() async {
        guard loaded,!continuationClosing,taskControlsConfigured else {return}
        // Every candidate comes from this account's existing local conversation journal.
        // A receipt in conversation A must remain findable when B was selected at process loss.
        let selected=session,records=history
        if let selected {await restoreAppliedTaskControlDeliveries(selected)}
        for record in records where record.id != selected?.conversationID {
            guard loaded,!continuationClosing else {return}
            if let saved=try? await service.read(scope:scope,conversationID:record.id) {await restoreAppliedTaskControlDeliveries(saved)}
        }
    }
    @discardableResult private func drainTaskControlDeliveries()->Bool {
        guard loaded,!continuationClosing,foreground,networkAdmissionAllowed,!busy,taskControlDeliveryTask==nil,
              let delivery=pendingTaskControlDeliveries.values.filter({$0.nextAttemptAt<=Date()}).sorted(by:{$0.key<$1.key}).first else {return false}
        let token=UUID(),generation=taskControlDeliveryGeneration
        taskControlDeliveryToken=token;flightID=token;busy=true;observerLifecycle = .reconnecting
        taskControlDeliveryTask=Task {
            defer {
                if taskControlDeliveryToken==token {
                    taskControlDeliveryTask=nil;taskControlDeliveryToken=nil
                    if flightID==token {flightID=nil;busy=false;observerLifecycle=session?.unresolved == nil ? .foregroundIdle : .unknown}
                }
            }
            do {
                let original=try await service.read(scope:scope,conversationID:delivery.reference.binding.conversation_id)
                guard original.goals[delivery.reference.binding.task_id]?.binding==delivery.reference.binding else {throw ConversationTaskControlError.invalidResponse}
                guard taskControlDeliveryMayCommit(token:token,generation:generation) else {return}
                // The entire original request/history is already durable; this is the existing GET recovery path.
                try await service.observe(scope:scope,conversationID:delivery.reference.binding.conversation_id)
                guard taskControlDeliveryMayCommit(token:token,generation:generation) else {return}
                deliveredTaskControlReceipts.insert(delivery.key)
                if pendingTaskControlDeliveries[delivery.reference.id]?.key==delivery.key {pendingTaskControlDeliveries[delivery.reference.id]=nil}
                if conversationID==delivery.reference.binding.conversation_id {await refresh(rebuildHistory:false)}
            } catch is CancellationError { }
            catch ConversationSessionError.busy {deferTaskControlDelivery(delivery,token:token,generation:generation,busy:true)}
            catch {
                deferTaskControlDelivery(delivery,token:token,generation:generation,busy:false)
                if taskControlDeliveryMayCommit(token:token,generation:generation),conversationID==delivery.reference.binding.conversation_id {self.error=error.localizedDescription}
            }
        }
        return true
    }
    private func deferTaskControlDelivery(_ delivery:TaskControlDelivery,token:UUID,generation:Int,busy:Bool) {
        guard taskControlDeliveryMayCommit(token:token,generation:generation),var saved=pendingTaskControlDeliveries[delivery.reference.id],saved.key==delivery.key else {return}
        if !busy {saved.failures=min(saved.failures+1,5)}
        saved.nextAttemptAt=Date().addingTimeInterval(busy ? 2:min(60,pow(2,Double(saved.failures))*2));pendingTaskControlDeliveries[delivery.reference.id]=saved
    }
    private func taskControlDeliveryMayCommit(token:UUID,generation:Int)->Bool {
        !Task.isCancelled && loaded && !continuationClosing && foreground && networkAdmissionAllowed && taskControlDeliveryGeneration==generation && taskControlDeliveryToken==token && flightID==token
    }
    private func stopTaskControlDelivery() {
        taskControlDeliveryGeneration += 1;taskControlDeliveryTask?.cancel();taskControlDeliveryTask=nil
        if let token=taskControlDeliveryToken,flightID==token {flightID=nil;busy=false}
        taskControlDeliveryToken=nil
    }
    func openTaskActions(_ goal:ConversationGoalProjection) {
        guard taskReviewsConfigured,loaded,let binding=goal.binding,let subject=trustedSubjectID,session?.conversationID==binding.conversation_id else {return}
        selectedTaskActions=ConversationTaskActionReference(scope:scope,binding:binding,subjectID:subject.uuidString.lowercased(),title:goal.title)
    }
    /// Local selection only. It does not inspect a server, request permission or send a turn.
    func stageArtifactContinuation(goalID:String,selection:ConversationArtifactIdentity,mode:ConversationArtifactContinuationMode) async -> Bool {
        guard loaded,!continuationClosing,!switchingArtifactContinuation,!enqueueing,!isInputComposing,let id=conversationID,let subject=trustedSubjectID,
              let goal=session?.goals[goalID],let binding=goal.binding,binding.conversation_id==id,
              let artifact=(goal.artifacts+goal.artifactHistory).first(where:{ConversationArtifactIdentity($0)==selection}),textHash(artifact.body)==selection.contentHash else {return false}
        switchingArtifactContinuation=true;defer{switchingArtifactContinuation=false}
        let reference=ConversationArtifactContinuationReference(scope:scope,subjectID:subject,goalID:goalID,binding:binding,artifactReference:.init(selection),planReference:goal.planReference,mode:mode,taskTitle:goal.title,artifactTitle:artifact.title)
        do {
            await persistenceTask?.value;try await flushDraft()
            guard loaded,!continuationClosing,!isInputComposing,conversationID==id else {return false}
            let sequence=continuationEditSequence,raw=draft,prior=artifactContinuation.map{ConversationArtifactContinuationDraft(reference:$0,raw:raw,editSequence:sequence)}
            let saved=try await artifactContinuationService.activate(reference,ordinaryDraft:artifactContinuation==nil ? raw : nil,priorDraft:prior)
            guard loaded,!continuationClosing,!isInputComposing,conversationID==id,sequence==continuationEditSequence,draft==raw else {return false}
            if artifactContinuation==nil {ordinaryContinuationImage=imageDraft;imageDraft=ImageAttachmentDraft();subscribeToImageDraft();cancelImageConsent();approvedImage=nil}
            artifactContinuation=reference;draft=saved.activeDraft?.raw ?? "";continuationEditSequence=saved.activeDraft?.editSequence ?? 0;continuationDraftSaved=true
            return true
        } catch {self.error=error.localizedDescription;return false}
    }
    func leaveArtifactContinuation() async -> Bool {
        guard let reference=artifactContinuation,!continuationClosing,!switchingArtifactContinuation,!enqueueing,!isInputComposing else {return false}
        switchingArtifactContinuation=true;defer{switchingArtifactContinuation=false}
        do {
            await persistenceTask?.value;try await flushDraft()
            let raw=draft,sequence=continuationEditSequence
            let ordinary=try await artifactContinuationService.leave(.init(reference:reference,raw:raw,editSequence:sequence))
            guard !continuationClosing,!isInputComposing,artifactContinuation==reference,draft==raw,continuationEditSequence==sequence else {return false}
            artifactContinuation=nil;draft=ordinary;imageDraft=ordinaryContinuationImage ?? ImageAttachmentDraft();ordinaryContinuationImage=nil;subscribeToImageDraft();continuationDraftSaved=true
            return true
        } catch {self.error=error.localizedDescription;return false}
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
        // The user replaced / removed a recovered image: that turn's caption leaves the composer (no 「这张呢？这张图里有什么？」).
        if recoveredImageOperation != nil,let receipt=recoveredImageReceipt,imageDraft.attachment?.id != receipt {
            let stripped=ConversationCaptionPolicy.strippingRecovered(draft:draft,caption:recoveredImageCaption)
            if stripped != draft {editDraft(stripped)}
            recoveredImageOperation=nil;recoveredImageReceipt=nil;recoveredImageCaption=nil
        }
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
                imageConsentReview=consent;imageConsentReviewToken=UUID();consumedImageConsentReviewToken=nil;pendingImageConsent=consent
            } catch {if imageConsentEpoch==epoch {self.error=error.localizedDescription;cancelImageConsent()}}
        }
    }
    func matchesImageConsent(_ consent:ConversationImageConsent,reviewToken:UUID)->Bool {
        guard imageConsentReviewToken==reviewToken,imageConsentReview==consent,
              let review=imageReview,reviewMatches(review),consent.routeHash==imageCapability.routeHash else {return false}
        return true
    }
    @discardableResult func cancelImageConsent(matching consent:ConversationImageConsent,reviewToken:UUID)->Bool {
        guard !checkingImageConsent,matchesImageConsent(consent,reviewToken:reviewToken) else {return false}
        cancelImageConsent();return true
    }
    func allowPendingImageConsent(_ consent:ConversationImageConsent,confirmed:Bool,reviewToken:UUID?=nil) {
        guard confirmed,!checkingImageConsent,let currentToken=imageConsentReviewToken,
              reviewToken.map({$0==currentToken}) ?? true,
              consumedImageConsentReviewToken != currentToken,matchesImageConsent(consent,reviewToken:currentToken),
              let review=imageReview else {return}
        // Consume the decision synchronously. Keep the current presentation token
        // while saving, but neither a repeated button callback nor an old sheet
        // cancellation can start a second consent POST or cancel this new owner.
        consumedImageConsentReviewToken=currentToken
        imageConsentTask?.cancel();let epoch=UUID();imageConsentEpoch=epoch;checkingImageConsent=true
        imageConsentTask=Task {
            defer {if imageConsentEpoch==epoch {checkingImageConsent=false}}
            do {
                let revision=try await service.allowImageConsent(scope:scope,consent:consent,nonSensitiveConfirmed:true)
                guard imageConsentEpoch==epoch,reviewMatches(review),!Task.isCancelled,revision==consent.expectedRevision+1 else {return}
                approvedImage = .init(conversation:review.conversation,preview:review.preview,hash:review.hash,captionHash:review.captionHash,route:consent.routeHash,revision:revision)
                imageReview=nil;imageConsentReview=nil;imageConsentReviewToken=nil;consumedImageConsentReviewToken=nil;pendingImageConsent=nil
            } catch {if imageConsentEpoch==epoch {self.error=error.localizedDescription;cancelImageConsent()}}
        }
    }
    func cancelImageConsent() {
        let hadReview=imageReview != nil
        imageConsentEpoch=UUID();imageConsentTask?.cancel();imageConsentTask=nil;imageReview=nil;imageConsentReview=nil;imageConsentReviewToken=nil;consumedImageConsentReviewToken=nil;pendingImageConsent=nil;checkingImageConsent=false;approvedImage=nil
        if hadReview {pendingModelConsent=nil;modelConsentReview=nil;modelConsentReviewToken=nil}
    }
    private func recoverOrCleanImage(_ current:ConversationSession) {
        for turn in current.turns where turn.state == .completed && turn.request.image != nil && !cleanedImageOperations.contains(turn.id) {
            cleanedImageOperations.insert(turn.id)
            if imageDraft.attachment?.id==turn.request.image?.receipt.id {imageDraft.clear()}
            if recoveredImageOperation==turn.id {if draft==turn.request.history.last?.content {editDraft("")};recoveredImageOperation=nil}
            Task {try? await imageStore.remove(conversationID:current.conversationID,operationID:turn.id)}
        }
        guard loaded,imageRecoveryTask==nil,imageDraft.phase == .empty else {return}
        let forced=retrySendAfterRestore.flatMap{id in current.turns.first(where:{$0.id==id && $0.request.image != nil})}.map{($0.id,$0.request.image!,$0.request.history.last?.content ?? "")}
        let candidate=forced ?? (followups.paused ? followups.pending.first(where:{$0.image != nil}) : nil).map{($0.id,$0.image!,$0.text)} ?? current.turns.last(where:{[.unknown,.failed,.notSent].contains($0.state) && $0.request.image != nil}).map{($0.id,$0.request.image!,$0.request.history.last?.content ?? "")}
        guard let (operation,reference,text)=candidate else {return}
        let id=current.conversationID,generation=sceneGeneration,token=UUID();imageRecoveryToken=token
        imageRecoveryTask=Task {
            defer {if imageRecoveryToken==token {imageRecoveryTask=nil;imageRecoveryToken=nil}}
            do {
                let bytes=try await imageStore.read(reference:reference,conversationID:id,operationID:operation)
                let receipt=reference.receipt
                let packet=try await SystemImageAttachmentEncoder().restoreEncoded(bytes,id:receipt.id,mimeType:receipt.mime_type,sha256:receipt.sha256,sizeBytes:receipt.size_bytes,width:receipt.width,height:receipt.height)
                guard !Task.isCancelled,conversationID==id,sceneGeneration==generation,loaded,imageDraft.phase == .empty,packet.sha256==reference.receipt.sha256 else {return}
                let unresolved=(followups.paused && followups.pending.contains(where:{$0.id==operation})) || session?.turns.contains(where:{$0.id==operation && [.unknown,.failed,.notSent].contains($0.state)})==true
                guard unresolved else {return};approvedImage=nil;imageDraft.restorePrepared(packet);recoveredImageOperation=operation;recoveredImageReceipt=receipt.id
                // Captions never merge: the failed turn's caption only goes into an empty composer (or replaces it for 重试).
                let retrying=retrySendAfterRestore==operation;retrySendAfterRestore=nil
                draft=retrying ? text : ConversationCaptionPolicy.restored(draft:draft,caption:text);recoveredImageCaption=draft==text ? text : nil
                if retrying {send()}
            } catch {if conversationID==id,loaded,!Task.isCancelled {self.error="本机图片读取未完成，原请求已保留。"}}
        }
    }
    func start() async {
        guard !loaded else { return }
        do {
            let id=try await service.openLatest(scope:scope);try await select(id)
            let snapshot=await repository.read(scope:scope)
            subscription=Task { [weak self,repository,scope] in
                for await notice in await repository.changes(scope:scope,after:snapshot.sequence) { guard let self,!Task.isCancelled else { return };let latest=await repository.read(scope:scope);if !notice.recordIDs.isEmpty,notice.recordIDs.allSatisfy({latest.records[$0]?.payload.kind=="conversationUIState"}) {continue};let headerChanged=notice.recordIDs.contains(where:{id in self.history.contains(where:{$0.id == id}) || id == self.conversationID});await self.refresh(rebuildHistory:headerChanged) }
            }
            // A start that was still awaiting openLatest when the model was deactivated (logout) must not revive it.
            guard !continuationClosing else { subscription?.cancel(); subscription=nil; return }
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
            for value in durable where !outgoingMessages.contains(where:{$0.id == value.id}) { outgoingMessages.append(.init(id:value.id,text:value.text,image:value.image?.receipt,continuation:value.continuation,acceptedWork:value.acceptedWork,revisionWork:value.revisionWork,state:.queued,error:nil)) }
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
    func select(_ id:UUID,admission:(()->Bool)?=nil) async throws {
        quotaNotice=false
        func ensureSelection() throws {try Task.checkCancellation();guard !isInputComposing,admission?() != false else {throw CancellationError()}}
        try ensureSelection()
        guard !busy,!isInputComposing else { throw ConversationSessionError.busy }
        if conversationID == id { return }
        await persistenceTask?.value;try ensureSelection()
        guard !busy,!isInputComposing else { throw ConversationSessionError.busy }
        busy=true;defer { busy=false }
        if let prior=conversationID {try await generativeUIStateService.flush(conversationID:prior)}
        acceptedWorkDraftTask?.cancel();await acceptedWorkDraftTask?.value;try ensureSelection()
        if var review=acceptedWorkDraft {review.options=acceptedWorkOptions;try await acceptedWorkDraftService.save(review)}
        try await flushDraft();let saved=try await repository.record(id,scope:scope),selected=try await service.read(scope:scope,conversationID:id)
        try ensureSelection()
        let targetWorkDraft=try await acceptedWorkDraftService.read(conversationID:id)
        try ensureSelection()
        let composer=try await artifactContinuationService.state(conversationID:id)
        try ensureSelection()
        let selectionReceipt=try await service.prepareNavigationSelection(scope:scope,conversationID:id)
        do {try ensureSelection()} catch {
            let original=error
            do {try await service.rollbackNavigationSelection(scope:scope,receipt:selectionReceipt)}
            catch {throw CatpawError.unavailable("原对话未切换，但本机恢复点未能还原。当前草稿仍保留。")}
            throw original
        }
        // Commit all presentation state together after target reads and the last
        // lifecycle gate. An interrupted read cannot leave B with A's queue/draft.
        permissionTask?.cancel();permissionID=nil;authorizeRerun=false;pendingModelConsent=nil;modelConsentReview=nil;modelConsentReviewToken=nil;checkingModelConsent=false;consentReady=false
        queue=ConversationFollowupQueueService(repository:repository,scope:scope,conversationID:id)
        acceptedWorkReviewTask?.cancel();acceptedWorkReviewTask=nil;acceptedWorkReviewToken=nil;acceptedWorkReviewPresented=false;acceptedWorkReviewSaving=false;acceptedWorkCapability = .init();revisionWorkReviewTarget=nil
        acceptedWorkDraftTask?.cancel();acceptedWorkDraftTask=nil;acceptedWorkDraft=targetWorkDraft
        if let value=acceptedWorkDraft {acceptedWorkOptions=value.options}
        cancelImageConsent();imageRecoveryTask?.cancel();imageRecoveryTask=nil;imageRecoveryToken=nil
        if let prior=conversationID {
            let ordinary=ordinaryContinuationImage ?? imageDraft
            if ordinary.phase == .empty {imageDrafts.removeValue(forKey:prior)}
            else {ordinary.cancelProcessing();imageDrafts[prior]=ordinary}
        }
        imageDraft=imageDrafts.removeValue(forKey:id) ?? ImageAttachmentDraft();subscribeToImageDraft()
        recoveredImageOperation=nil;imageCapability=ConversationImageCapability()
        artifactContinuation=composer.activeDraft?.reference;continuationEditSequence=composer.activeDraft?.editSequence ?? 0;ordinaryContinuationImage=nil
        if let active=composer.activeDraft {ordinaryContinuationImage=imageDraft;imageDraft=ImageAttachmentDraft();subscribeToImageDraft();draft=active.raw}else{draft=saved.conversation?.draftText ?? ""}
        continuationDraftSaved=true
        conversationID=id;session=selected;outgoingMessages=[];tapTimes=[:];isInputComposing=false;error=nil;await refresh();if loaded && foreground && networkAdmissionAllowed {connectionTask?.cancel();connectionTask=Task{await refreshConnection()};syncServerTranscript(id)}
        if loaded,let session {await restoreAppliedTaskControlDeliveries(session);drainTaskControlDeliveries()}
    }
    /// Explicit navigation from the scope inbox; inspection never calls this.
    func returnToReceivedWork(_ item:ConversationInboxItem) async -> Bool {
        guard let inboxService,loaded,foreground,networkAdmissionAllowed,!busy,!isInputComposing else {return false}
        let generation=sceneGeneration,origin=conversationID
        func current()->Bool {loaded && foreground && networkAdmissionAllowed && sceneGeneration==generation && conversationID==origin && !Task.isCancelled}
        do {
            let goal=try await inboxService.resolve(item:item)
            guard current() else {return false}
            let original=try await service.read(scope:scope,conversationID:item.binding.conversation_id)
            guard current(),original.goals[item.binding.task_id]?.binding==item.binding else {throw ConversationInboxError.invalidResponse}
            try await service.recordReceivedGoal(scope:scope,goal:goal)
            guard current() else {return false}
            try await select(item.binding.conversation_id,admission:current)
            return loaded && foreground && networkAdmissionAllowed && sceneGeneration==generation && conversationID==item.binding.conversation_id
        } catch CatpawError.missing {
            if current(){error="原对话尚未保存在本机，可继续查阅这份成果。"}
            return false
        } catch {if current(){self.error=error.localizedDescription};return false}
    }
    func newConversation() { guard !isInputComposing else { return };Task { do { await persistenceTask?.value;try await flushDraft();let id=try await service.create(scope:scope);try await select(id) } catch { self.error=error.localizedDescription } } }
    func updateInputComposition(_ active:Bool) { guard active != isInputComposing else { return };isInputComposing=active }
    /// One-tap prompts (starter cards, follow-up chips) fill an EMPTY composer and then take the Send path.
    /// Nothing typed, queued or sent yet (an account-neutral launch chat may then be swapped for the account's own).
    var isPristine: Bool { draft.isEmpty && outgoingMessages.isEmpty && (session?.turns.isEmpty ?? true) && imageDraft.phase == .empty }
    /// `canAcceptDraft` itself requires a non-empty draft, so it can only be checked after the fill; a refused fill is rolled back.
    func stageQuickSend(_ text:String?, attachmentsEmpty:Bool = true) -> Bool {
        guard let text,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!busy,draft.isEmpty,attachmentsEmpty else {return false}
        editDraft(text)
        guard canAcceptDraft else {editDraft("");return false}
        return true
    }
    func editDraft(_ text:String) {
        guard !continuationClosing else {return}
        draft=text;imageSelectionChanged();draftTask?.cancel();guard let id=conversationID else { return }
        if let reference=artifactContinuation {
            continuationEditSequence += 1;continuationDraftSaved=false
            let value=ConversationArtifactContinuationDraft(reference:reference,raw:text,editSequence:continuationEditSequence),previous=persistenceTask
            draftTask=Task {do {try await Task.sleep(nanoseconds:300_000_000);try Task.checkCancellation();await previous?.value;try Task.checkCancellation();try await artifactContinuationService.saveDraft(value);if artifactContinuation==reference,draft==text,continuationEditSequence==value.editSequence {continuationDraftSaved=true}}catch is CancellationError{}catch{self.error=error.localizedDescription}}
        } else {draftTask=Task { do { try await Task.sleep(nanoseconds:300_000_000);try Task.checkCancellation();try await service.saveDraft(scope:scope,conversationID:id,text:text) } catch is CancellationError { } catch { self.error=error.localizedDescription } }}
    }
    func flushDraft() async throws { acceptedWorkDraftTask?.cancel();await acceptedWorkDraftTask?.value;if var review=acceptedWorkDraft {review.options=acceptedWorkOptions;try await acceptedWorkDraftService.save(review)};draftTask?.cancel();draftTask=nil;if let reference=artifactContinuation {try await artifactContinuationService.saveDraft(.init(reference:reference,raw:draft,editSequence:continuationEditSequence));continuationDraftSaved=true}else if let id=conversationID { try await service.saveDraft(scope:scope,conversationID:id,text:draft) } }
    // This synchronous capture is local intent, never a server admission or successful send.
    func prepareSend(acceptedWork:ConversationAcceptedWorkSelection?=nil,revisionWork:ConversationRevisionWorkSelection?=nil,reviewDraft:ConversationAcceptedWorkDraft?=nil) {
        if let block=artifactContinuationSendBlock {error=block;return}
        if revisionRequiresWorkReview,revisionWork==nil {requestAcceptedWorkReview();return}
        if let block=imageSendBlock { error=block.message;return }
        if quotaNotice { return }   // keep the draft; the quota notice offers 重试
        guard canAcceptDraft,let id=conversationID,let queue else { sendLog.info("catpaw.send prepare rejected canAccept=\(self.canAcceptDraft, privacy: .public) loaded=\(self.loaded, privacy: .public) conv=\(self.conversationID != nil, privacy: .public) queue=\(self.queue != nil, privacy: .public)");return }
        let tap=ProcessInfo.processInfo.systemUptime
        let prepared=imageDraft.attachment
        let payload:ConversationVisionPayload?
        if let prepared {
            guard imageDraft.phase == .ready,let approvedImage,approvedImageMatchesDraft else {return}
            let receipt=ConversationImageReceipt(id:UUID(),mimeType:prepared.mimeType,sha256:prepared.sha256,size:prepared.encodedData.count,width:prepared.width,height:prepared.height)
            payload = .init(reference:.init(receipt:receipt,routeHash:approvedImage.route,consentRevision:approvedImage.revision),bytes:prepared.encodedData)
        } else {payload=nil}
        let target=artifactContinuation
        let continuation:ConversationArtifactContinuationIntent?
        do {continuation=try target?.sendIntent()}catch{self.error=error.localizedDescription;return}
        guard acceptedWork==nil || (payload==nil && target==nil && reviewDraft?.raw==draft) else {return}
        guard revisionWork==nil || (acceptedWork==nil && payload==nil && target==revisionWorkReviewTarget && continuation==revisionWork?.target && revisionWork?.originalText.utf8.elementsEqual(draft.utf8)==true && reviewDraft?.revisionTarget==continuation) else {return}
        let message=ConversationFollowup(text:draft,image:payload?.reference,continuation:continuation,acceptedWork:acceptedWork,revisionWork:revisionWork)
        draftTask?.cancel();draftTask=nil
        tapTimes[message.id]=tap;outgoingMessages.append(.init(id:message.id,text:message.text,image:payload?.reference.receipt,continuation:continuation,acceptedWork:acceptedWork,revisionWork:revisionWork,state:.savingLocal,error:nil));draft="";if target != nil {continuationEditSequence += 1;continuationDraftSaved=false}
        savingCount += 1;enqueueing=true;tapToLocalPublishMs=(ProcessInfo.processInfo.systemUptime-tap)*1000
        let previous=persistenceTask
        persistenceTask=Task {
            await previous?.value
            defer { savingCount -= 1;enqueueing=savingCount > 0 }
            do {
                if let payload {try await imageStore.save(payload,conversationID:id,operationID:message.id)}
                if let target {
                    let remaining=ConversationArtifactContinuationDraft(reference:target,raw:draft,editSequence:continuationEditSequence)
                    try await queue.enqueue(message,remainingContinuationDraft:remaining,continuationService:artifactContinuationService,acceptedWorkDraft:reviewDraft,acceptedWorkDraftService:reviewDraft==nil ? nil:acceptedWorkDraftService)
                    if artifactContinuation==target,draft==remaining.raw,continuationEditSequence==remaining.editSequence {continuationDraftSaved=true}
                } else {try await queue.enqueue(message,remainingDraft:draft,acceptedWorkDraft:reviewDraft,acceptedWorkDraftService:reviewDraft==nil ? nil : acceptedWorkDraftService)}
                if let prepared,imageDraft.attachment?.id==prepared.id,imageDraft.attachment?.sha256==prepared.sha256 {imageDraft.clear();approvedImage=nil}
                guard conversationID == id else { return }
                if acceptedWork != nil || revisionWork != nil {acceptedWorkDraft=nil;revisionWorkReviewTarget=nil}
                setIntent(message.id,.queued);await refresh()
                sendLog.info("catpaw.send enqueued fg=\(self.foreground, privacy: .public) inflight=\(self.permissionTask != nil, privacy: .public)")
                if foreground { authorizePending() }
            } catch {
                if payload != nil {try? await imageStore.remove(conversationID:id,operationID:message.id)}
                setIntent(message.id,.failed,error:error.localizedDescription)
                if artifactContinuation==target,draft.isEmpty {draft=message.text;if target != nil {continuationEditSequence += 1;continuationDraftSaved=false}};self.error="本机保存未完成，内容已保留。"
            }
        }
    }
    func send() { prepareSend() }
    func outgoingDidRender(_ id:UUID) { if let time=tapTimes.removeValue(forKey:id) { tapToFirstRenderedMs=(ProcessInfo.processInfo.systemUptime-time)*1000 } }
    private func setIntent(_ id:UUID,_ state:OutgoingMessageIntent.State,error:String?=nil) { if let i=outgoingMessages.firstIndex(where:{$0.id == id}) { outgoingMessages[i].state=state;outgoingMessages[i].error=error } }
    // p89j-1 root cause: start()/resumeForeground launches a consent check that reads the queue BEFORE a just-tapped
    // send is enqueued (pending=0 -> "authorize skipped"). The post-enqueue authorizePending() then hit
    // `permissionTask == nil` and returned silently, so the message sat queued with no consent sheet and nothing
    // re-triggered it. A request arriving while a check is in flight is now coalesced and re-run when that check ends.
    private var authorizeRerun=false
    private func authorizePending() {
        guard networkAdmissionAllowed,foreground,loaded,pendingModelConsent == nil,let id=conversationID else { sendLog.info("catpaw.send authorize rejected admission=\(self.networkAdmissionAllowed, privacy: .public) fg=\(self.foreground, privacy: .public) loaded=\(self.loaded, privacy: .public) pendingConsent=\(self.pendingModelConsent != nil, privacy: .public)");return }
        if permissionTask != nil { authorizeRerun=true;sendLog.info("catpaw.send authorize coalesced (consent check in flight)");return }
        authorizeRerun=false
        if consentReady { drainQueue();return }
        let token=UUID();permissionID=token;checkingModelConsent=true
        permissionTask=Task {
            defer { if permissionID == token { permissionTask=nil;checkingModelConsent=false;if authorizeRerun,!Task.isCancelled { authorizeRerun=false;sendLog.info("catpaw.send authorize rerun after in-flight check");authorizePending() } } }
            do {
                var state=try await queue?.state()
                // A preflight hold (send threw before the turn was journaled: readiness timeout, admission
                // briefly closed during auth refresh) is transient. Nothing else resumes it, so a fresh send
                // or consent check must, otherwise every later message queues silently behind it.
                if try await queue?.resumePreflightHold() == true { sendLog.info("catpaw.send resumed preflight hold");state=try await queue?.state() }
                if let s0=state,s0.paused || s0.pending.isEmpty, !Task.isCancelled,permissionID == token,conversationID == id {
                    // Gap 2: an old conversation whose consent is already granted must not show the
                    // consent re-ask banner just because its queue is paused/empty; mark ready silently.
                    if let granted=try? await { () async throws -> Bool in try await service.modelConsent(scope:scope,conversationID:id) == nil }(), granted {
                        consentReady=true
                        if s0.paused,s0.pauseReason == .background || s0.pauseReason == .preflight { try? await queue?.resume();state=try await queue?.state() }
                    }
                }
                guard !Task.isCancelled,permissionID == token,foreground,conversationID == id,let state,!state.pending.isEmpty,!state.paused else { if consentReady { drainQueue() };sendLog.info("catpaw.send authorize skipped paused=\(state?.paused ?? false, privacy: .public) pending=\(state?.pending.count ?? -1, privacy: .public) tokenOK=\(self.permissionID == token, privacy: .public) fg=\(self.foreground, privacy: .public) ready=\(self.consentReady, privacy: .public) busy=\(self.busy, privacy: .public)");return }
                let consent=try await service.modelConsent(scope:scope,conversationID:id)
                guard !Task.isCancelled,permissionID == token,foreground,conversationID == id else { return }
                if let consent { presentModelConsent(consent);for i in outgoingMessages.indices where outgoingMessages[i].state == .queued { outgoingMessages[i].state = .awaitingPermission } }
                else { consentReady=true;drainQueue() }
            } catch { if permissionID == token { self.error="尚未发送；连接或许可读取未完成，本机消息已保留。" } }
        }
    }
    func matchesModelConsent(_ consent:ConversationModelConsent,reviewToken:UUID)->Bool {
        guard loaded,foreground,networkAdmissionAllowed,conversationID==consent.conversationID,
              modelConsentReviewToken==reviewToken,let review=modelConsentReview else {return false}
        return sameModelConsent(review,consent)
    }
    private func sameModelConsent(_ first:ConversationModelConsent,_ second:ConversationModelConsent)->Bool {
        first.conversationID==second.conversationID && first.routeHash==second.routeHash && first.expectedRevision==second.expectedRevision && first.title==second.title && first.body==second.body
    }
    func allowPendingModelConsent(_ consent:ConversationModelConsent,reviewToken:UUID?=nil) {
        guard networkAdmissionAllowed,foreground,loaded,conversationID == consent.conversationID,
              reviewToken.map({modelConsentReviewToken==$0}) ?? true,
              let review=modelConsentReview,review.conversationID==consent.conversationID,
              review.routeHash==consent.routeHash,review.expectedRevision==consent.expectedRevision,
              review.title==consent.title,review.body==consent.body else {sendLog.info("catpaw.send allow rejected review=\(self.modelConsentReview != nil, privacy: .public)");return}
        sendLog.info("catpaw.send allow accepted")
        modelConsentReview=nil;modelConsentReviewToken=nil
        permissionTask?.cancel();let token=UUID();permissionID=token;checkingModelConsent=true;pendingModelConsent=nil
        permissionTask=Task {
            defer { if permissionID == token { permissionTask=nil;checkingModelConsent=false } }
            do { try await service.allowModelConsent(scope:scope,consent:consent);guard !Task.isCancelled,permissionID == token,foreground,conversationID == consent.conversationID else { return };consentReady=true;if imageReview != nil {fetchImageConsent()} else {drainQueue()} }
            catch { sendLog.error("catpaw.send allow failed \(String(describing:error), privacy: .public)");if permissionID == token { self.error="许可保存未确认，本机消息已保留，未发送。" } }
        }
    }
    private func presentModelConsent(_ consent:ConversationModelConsent) {
        modelConsentReview=consent;modelConsentReviewToken=UUID();pendingModelConsent=consent
    }
    /// chat-ux-1505 #1: a different route may carry a different disclosure (route_hash). Drop the cached "consent ok" so
    /// the next send re-reads model-consent (cheap when still valid; shows the sheet when the hash changed).
    func modelRouteChanged() { guard modelConsentReview == nil else { return }; consentReady = false; objectWillChange.send() }
    var needsModelConsentReview:Bool {!consentReady && (modelConsentReview != nil || !followups.pending.isEmpty)}
    var canReviewModelConsent:Bool {loaded && foreground && networkAdmissionAllowed && !checkingModelConsent && !busy && session?.unresolved==nil}
    func requestModelConsentReview() {
        guard canReviewModelConsent else{return}
        if let review=modelConsentReview,review.conversationID==conversationID {presentModelConsent(review);return}
        if followups.paused {resumeFollowups()} else {authorizePending()}
    }
    @discardableResult func deferModelConsent(_ consent:ConversationModelConsent?=nil,reviewToken:UUID?=nil)->Bool {
        if let consent {
            guard let review=modelConsentReview,sameModelConsent(review,consent),
                  reviewToken.map({matchesModelConsent(consent,reviewToken:$0)}) ?? true else {return false}
        } else if reviewToken != nil {return false}
        modelConsentReview=nil;modelConsentReviewToken=nil;pendingModelConsent=nil;consentReady=false
        if imageReview != nil {cancelImageConsent()}
        let reviewQueue=queue,reviewConversation=conversationID
        Task {
            try? await reviewQueue?.pause()
            guard loaded,conversationID==reviewConversation else {return}
            await refresh()
        }
        return true
    }
    private var canDispatchFollowup:Bool { loaded && foreground && networkAdmissionAllowed }
    private func drainQueue() {
        guard networkAdmissionAllowed,foreground,let id=conversationID,let queue,!busy,session?.unresolved == nil else { sendLog.info("catpaw.send drain skipped admit=\(self.networkAdmissionAllowed, privacy: .public) fg=\(self.foreground, privacy: .public) busy=\(self.busy, privacy: .public) unresolved=\(self.session?.unresolved != nil, privacy: .public)");return }
        sendLog.info("catpaw.send drain start")
        let token=UUID();flightID=token;busy=true;sending=true;observerLifecycle = .streaming;error=nil
        turnTask=Task {
            defer { if flightID == token { flightID=nil;busy=false;sending=false;observerLifecycle=session?.unresolved == nil ? .foregroundIdle : .unknown } }
            do {
                if try await queue.resumePreflightHold() { sendLog.info("catpaw.send resumed preflight hold before drain") }
                if try await queue.recoverFromTerminalFailure(session:session) { sendLog.info("catpaw.send unpaused queue behind a terminal failure") }
                try await queue.flush { [service,scope,imageStore,weak self] message in
                    guard !Task.isCancelled,await self?.canDispatchFollowup == true else { return .heldBeforeAdmission }
                    await self?.setIntent(message.id,.sending)
                    do {
                        let image:ConversationVisionPayload?
                        if let reference=message.image {let bytes=try await imageStore.read(reference:reference,conversationID:id,operationID:message.id);image = .init(reference:reference,bytes:bytes)} else {image=nil}
                        guard !Task.isCancelled,await self?.canDispatchFollowup == true else {return .heldBeforeAdmission}
                        sendLog.info("catpaw.send dispatch");let t0=Date();defer { sendLog.info("catpaw.send dispatch end \(Date().timeIntervalSince(t0), privacy: .public)s") }
                        _=try await service.send(scope:scope,conversationID:id,text:message.text,operationID:message.id,preserveDraft:true,image:image,continuation:message.continuation,acceptedWork:message.acceptedWork,revisionWork:message.revisionWork);return .sent
                    }
                    catch {
                        sendLog.error("catpaw.send dispatch failed \(String(describing:error).prefix(160), privacy: .public)")
                        if case ConversationDispatchFailure.notSent(let code)=error,ConversationTerminalServerError.isQuota(code) { await self?.markQuota();return .heldBeforeAdmission }
                        let saved=try await service.read(scope:scope,conversationID:id)
                        if !saved.turns.contains(where:{$0.id == message.id}) || saved.turns.first(where:{$0.id == message.id})?.state == .notSent { sendLog.error("catpaw.send held before admission: \(String(describing:error), privacy: .public)");return .heldBeforeAdmission }
                        // Admitted and ended by the server (rate_limited / failed): the bubble offers 重试 / 删除; the queue goes on.
                        if ConversationFollowupRecovery.isTerminalFailure(saved.turns.first(where:{$0.id == message.id})) { await self?.setIntent(message.id,.failed,error:nil);return .failedTerminal }
                        throw error
                    }
                }
                guard flightID == token else { return };var state=try await queue.state()
                if quotaNotice { state=try await returnQueuedToDraft(queue,conversationID:id) }
                if state.paused && !quotaNotice && !state.pending.isEmpty { error=state.pauseReason == .preflight ? "消息尚未发送，已保留在本机；再次发送或确认许可后会自动重试。" : "尚未发送的消息已保留，恢复连接后继续。";if draft.isEmpty,artifactContinuation==nil,state.pending.first?.continuation==nil { draft=state.pending.first?.text ?? "" } }
            } catch { if flightID == token { self.error=error.localizedDescription } }
            if !quotaNotice { /* keep notice across refresh */ }
            guard flightID == token else { return };await refresh()
        }
    }
    private func markQuota() { quotaNotice=true;error=nil }
    /// Quota reached: hand every queued (unsent) message back to the composer instead of a paused outbox.
    private func returnQueuedToDraft(_ queue:ConversationFollowupQueueService,conversationID id:UUID) async throws -> ConversationFollowupState {
        let state=try await queue.state()
        let plain=state.pending.filter { $0.continuation == nil && $0.acceptedWork == nil && $0.revisionWork == nil && $0.image == nil }
        guard !plain.isEmpty else { return state }
        let texts=plain.map(\.text)
        for message in plain {
            try? await service.discardUnsent(scope:scope,conversationID:id,operationID:message.id)
            try await queue.remove(message.id)
            outgoingMessages.removeAll { $0.id == message.id }
        }
        let joined=texts.joined(separator:"\n")
        draft=draft.isEmpty ? joined : draft+"\n"+joined
        try? await queue.resume()
        return try await queue.state()
    }
    func pauseFollowups() { Task { do { try await queue?.pause();await refresh() } catch { self.error=error.localizedDescription } } }
    func pauseQueueForEditing(_ message:ConversationFollowup) async throws {
        guard loaded,foreground,!editingFollowup,let queue,let id=conversationID else {throw ConversationSessionError.busy}
        try await queue.pause();await refresh()
        guard conversationID == id,followups.pending.contains(message) else {throw CatpawError.conflict}
    }
    func editFollowup(_ message:ConversationFollowup,text:String) async throws {
        guard loaded,foreground,!editingFollowup,let queue,let id=conversationID else {throw ConversationSessionError.busy}
        editingFollowup=true;defer {editingFollowup=false}
        _=try await queue.edit(message,text:text,session:service)
        guard conversationID == id else {return}
        outgoingMessages.removeAll {$0.id == message.id};await refresh()
    }
    func removeFollowup(_ id:UUID) { Task { do { if let conversationID { try await service.discardUnsent(scope:scope,conversationID:conversationID,operationID:id) };try await queue?.remove(id);if let conversationID {try await imageStore.remove(conversationID:conversationID,operationID:id)};outgoingMessages.removeAll { $0.id == id };await refresh() } catch { self.error=error.localizedDescription } } }
    /// 「发送失败 · 重试」 on a turn bubble: really re-sends. A plain rate-limited turn restarts in place on the server;
    /// an image turn is restored with its own caption and sent again; another failed text turn is sent as a new message.
    func retryFailedTurn(_ id:UUID) {
        guard let cid=conversationID,let turn=session?.turns.first(where:{$0.id == id}),turn.state == .failed,turn.assistantMessageID == nil else { resumeFollowups();return }
        let text=turn.request.history.last?.content ?? ""
        if turn.request.image != nil {
            guard imageDraft.phase == .empty else { error="请先发送或移除输入框里的图片，再重试这条消息。";return }
            guard draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || draft == recoveredImageCaption else { error="请先发送或清空输入框里的文字，再重试这条消息。";return }
            retrySendAfterRestore=id;imageRecoveryTask?.cancel();imageRecoveryTask=nil;imageRecoveryToken=nil
            if let current=session {recoverOrCleanImage(current)}
            return
        }
        Task {
            do {
                if turn.error == "rate_limited",try await service.retryBusy(scope:scope,conversationID:cid) != nil { await refresh();return }
                guard draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { self.error="请先发送或清空输入框里的文字，再重试这条消息。";return }
                editDraft(text);send()
            } catch { self.error=error.localizedDescription }
        }
    }
    /// 「删除」 on a failed turn.
    func deleteFailedTurn(_ id:UUID) {
        guard let cid=conversationID else { return }
        Task {
            do {
                _=try await service.dismissFailed(scope:scope,conversationID:cid,operationID:id)
                try? await imageStore.remove(conversationID:cid,operationID:id)
                if recoveredImageOperation==id {
                    let stripped=ConversationCaptionPolicy.strippingRecovered(draft:draft,caption:recoveredImageCaption)
                    imageDraft.clear();if stripped != draft {editDraft(stripped)}
                    recoveredImageOperation=nil;recoveredImageReceipt=nil;recoveredImageCaption=nil
                }
                outgoingMessages.removeAll { $0.id == id };await refresh()
            } catch { self.error=error.localizedDescription }
        }
    }
    func resumeFollowups() {
        guard foreground,!busy,!editingFollowup,session?.unresolved == nil,let queue else { return }
        Task { do {
            let state=try await queue.state()
            if let original=state.inflight,let id=conversationID { let saved=try await service.read(scope:scope,conversationID:id);try await queue.reconcileInflight(admitted:saved.turns.contains { $0.id == original.id && ![.notSent,.cancelledBeforeSend].contains($0.state) }) }
            try await queue.resume();await refresh();authorizePending()
        } catch { self.error=error.localizedDescription } }
    }
    private var servicesAdmissionAllowed:Bool {loaded && networkAdmissionAllowed && foreground}
    private func synchronizeServiceAdmission(forceClosed:Bool=false) async {
        // Re-evaluate after every actor hop. A suspended foreground update cannot
        // reopen another service using a Boolean captured before logout/background.
        await taskPlanService.setAdmissionAllowed(!forceClosed && servicesAdmissionAllowed)
        await artifactEditService.setAdmissionAllowed(!forceClosed && servicesAdmissionAllowed)
        await taskActionService.setAdmissionAllowed(!forceClosed && servicesAdmissionAllowed)
        await taskControlService.setAdmissionAllowed(!forceClosed && servicesAdmissionAllowed)
        await memoryService?.setAdmissionAllowed(!forceClosed && servicesAdmissionAllowed)
        await inboxService?.setAdmissionAllowed(!forceClosed && servicesAdmissionAllowed)
    }
    func setNetworkAdmissionAllowed(_ allowed:Bool) {
        guard allowed != networkAdmissionAllowed else { return };networkAdmissionAllowed=allowed
        Task {await synchronizeServiceAdmission()}
        if allowed { Task { await resumeForeground();authorizePending() } }
        else { cancelImageConsent();stopTaskControlDelivery();permissionTask?.cancel();permissionTask=nil;permissionID=nil;authorizeRerun=false;checkingModelConsent=false;pendingModelConsent=nil;modelConsentReview=nil;modelConsentReviewToken=nil;connectionProbeID=UUID();connectionTask?.cancel();connectionLifecycle = .checking }
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
            // v1 17:55: a turn that just resolved (completed, failed, or settled 「结果待核对」) frees the conversation;
            // flush what queued behind it (「待发送 · 等待当前回复」) instead of waiting for the next relaunch.
            if session?.unresolved == nil { authorizePending() }
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
    /// Pull-merge server-only messages (e.g. an outbox turn admitted without write-back) so they show in the UI.
    private func syncServerTranscript(_ id:UUID) {
        Task { [service,scope,weak self] in
            do { let added=try await service.syncServerTranscript(scope:scope,conversationID:id)
                let current=await self?.conversationID
                if added, current == id { await self?.refresh() } }
            catch { sendLog.info("catpaw.send transcript sync on open skipped: \(String(describing:error), privacy: .public)") }
        }
    }
    func resumeForeground() async {
        guard loaded else { return };sceneGeneration += 1;let generation=sceneGeneration;foreground=true
        await enterForeground(generation:generation)
    }
    private func enterForeground(generation:Int) async {
        guard loaded,generation == sceneGeneration,foreground else { return }
        await haltTask?.value;guard generation == sceneGeneration,foreground else { return }
        await synchronizeServiceAdmission()
        if networkAdmissionAllowed,let id=conversationID { syncServerTranscript(id) }
        foregroundTask?.cancel();connectionTask?.cancel()
        // Reachability is informative; it must not block GET of the exact unresolved turn.
        connectionTask=Task { await refreshConnection() }
        await refresh()
        guard generation == sceneGeneration,foreground else { return }
        // A queue persisted as 「已暂停」 behind a failed / rate-limited turn (survived a relaunch) is unpaused.
        if let queue,let current=session,(try? await queue.recoverFromTerminalFailure(session:current)) == true { await refresh();guard generation == sceneGeneration,foreground else { return } }
        await restoreAppliedTaskControlDeliveriesAcrossConversations()
        guard generation == sceneGeneration,foreground else {return}
        for id in pendingTaskControlDeliveries.keys {pendingTaskControlDeliveries[id]?.nextAttemptAt = .distantPast}
        drainTaskControlDeliveries()
        if session?.unresolved != nil { if session?.unresolved?.awaitingApproval != true { readOriginal() } } else { await resumeBackgroundQueueIfSafe();authorizePending() }
        foregroundTask=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.foreground,self.sceneGeneration == generation else { return }
                if !self.busy,let session=self.session {
                    if self.drainTaskControlDeliveries() { }
                    // A turn suspended on our own approval/device card has nothing new to read until we answer; re-observing
                    // it every tick held the conversation busy and made submitDeviceResult fail with .busy ("结果还没告诉小猫").
                    else if session.unresolved?.awaitingApproval == true { }
                    else if session.unresolved != nil || session.goals.values.contains(where:{[.queued,.working,.waitingInput,.unknown].contains($0.state)}) { self.readOriginal() }
                    else {
                        // R7: due busy auto-retry (once) and offline outbox drain, both service-owned.
                        if let id=self.conversationID, self.networkAdmissionAllowed, await self.service.foregroundTick(scope:self.scope,conversationID:id) { await self.refresh() }
                        await self.resumeBackgroundQueueIfSafe()
                        // v1 18:20: consent can land (carried or allowed) while another flight holds `busy` (new-chat
                        // select(), a task-control delivery); drainQueue() then skips and nothing re-ran it, so the
                        // message sat at 「待发送 · 等待当前回复」 until relaunch. Idle tick is the safety net.
                        if self.consentReady,self.permissionTask == nil,!self.followups.pending.isEmpty,!self.followups.paused,self.followups.inflight == nil { sendLog.info("catpaw.send tick drain (queued behind idle conversation)");self.drainQueue() }
                    }
                }
                do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { return }
            }
        }
    }
    func suspend() async {
        await beginSuspension().value
    }
    private func beginSuspension() -> Task<Void,Never> {
        cancelImageConsent();sceneGeneration += 1;foreground=false;stopTaskControlDelivery();foregroundTask?.cancel();foregroundTask=nil;connectionTask?.cancel()
        permissionTask?.cancel();permissionTask=nil;permissionID=nil;authorizeRerun=false;checkingModelConsent=false;pendingModelConsent=nil;modelConsentReview=nil;modelConsentReviewToken=nil;connectionProbeID=UUID()
        let old=turnTask;turnTask=nil;flightID=nil;busy=false;sending=false;observerLifecycle = .background
        let id=conversationID,service=self.service,scope=self.scope,queue=self.queue
        let previous=haltTask,persistence=persistenceTask
        let generation=sceneGeneration
        let task=Task {
            await previous?.value
            await synchronizeServiceAdmission(forceClosed:true)
            try? await generativeUIStateService.flush(conversationID:id)
            do { if let id { try await service.stopObserving(scope:scope,conversationID:id) };old?.cancel();try await queue?.pause(reason:.background) }
            catch { old?.cancel() }
            await persistence?.value
            guard generation == sceneGeneration else { return }
            do { try await flushDraft() } catch { self.error=error.localizedDescription }
        }
        haltTask=task;return task
    }
    @discardableResult func deactivate() async -> Bool {
        // Close admission before any await; a queued foreground Task cannot revive logout.
        acceptedWorkReviewTask?.cancel();acceptedWorkReviewTask=nil;acceptedWorkReviewToken=nil;acceptedWorkDraftTask?.cancel();acceptedWorkDraftTask=nil;acceptedWorkReviewPresented=false;acceptedWorkReviewSaving=false
        continuationClosing=true;loaded=false;networkAdmissionAllowed=false;stopTaskControlDelivery();pendingTaskControlDeliveries.removeAll();deliveredTaskControlReceipts.removeAll();cancelImageConsent();imageRecoveryTask?.cancel();imageRecoveryTask=nil;imageRecoveryToken=nil
        selectedTaskPlan=nil;selectedTaskActions=nil
        let planDraftsSaved=await taskPlanService.invalidate()
        let artifactDraftsSaved=await artifactEditService.invalidate()
        await taskActionService.invalidate();await taskControlService.invalidate();selectedTaskControl=nil
        await memoryService?.invalidate()
        MemoryLibraryHub.reset() // wave2 V1
        await inboxService?.invalidate()
        imageDraft.clear();for value in imageDrafts.values {value.clear()};imageDrafts.removeAll();imageCapability=ConversationImageCapability()
        await suspend();subscription?.cancel();subscription=nil;draftTask?.cancel();draftTask=nil
        let composerSaved:Bool
        do {try await flushDraft();composerSaved=true}catch{composerSaved=false}
        await acceptedWorkDraftService.invalidate();acceptedWorkDraft=nil;acceptedWorkCapability = .init()
        await artifactContinuationService.invalidate();artifactContinuation=nil;ordinaryContinuationImage?.clear();ordinaryContinuationImage=nil
        await generativeUIStateService.invalidate()
        draft="";history=[];session=nil;conversationID=nil;followups=ConversationFollowupState();queue=nil;outgoingMessages=[];tapTimes=[:];isInputComposing=false;error=nil;loaded=false
        return planDraftsSaved && artifactDraftsSaved && composerSaved
    }
}
