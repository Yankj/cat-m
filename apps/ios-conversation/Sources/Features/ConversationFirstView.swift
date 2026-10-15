import SwiftUI
import UIKit
import CatpawNavigation
import CatpawImageComposer

@MainActor struct ConversationFirstView: View {
    @ObservedObject var model: ConversationFirstModel
    @ObservedObject private var connectionMonitor = ConnectionMonitor.shared
    @StateObject private var composerChrome:ConversationComposerChromeAdapter
    @ObservedObject private var proactiveFeed = CatpawProactiveFeed.shared
    @StateObject private var attachmentUploader:LocalMockComposerAttachmentUploader
    var accountLabel: String? = nil
    var onSignOut: (() -> Void)? = nil
    var isAnonymousAccount = false
    var restrictToFrozenFixture = false
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}
    @State private var scrollTask:Task<Void,Never>?
    @StateObject private var readingAnchor=ConversationReadingAnchorCoordinator()
    @State private var followingLatest=true
    @State private var latestVisible=true
    @State private var sidebarPresented=false
    @State private var path:[ConversationHostDestination]=[]
    @AccessibilityFocusState private var menuFocused:Bool
    @State private var history = false
    @State private var settings = false
    @State private var conversationMenuPresented=false
    @State private var pendingConversationSettings=false
    @AccessibilityFocusState private var moreFocused:Bool
    @State private var confirmSignOut = false
    @State private var pendingMessagesPresented=false
    @State private var composerMeasurements:[String:CGFloat]=[:]
    @State private var composerLineCount=1
    @State private var pendingAttachmentIntentID:UUID?
    @State private var visibleViewport:CatpawVisibleViewport?
    @State private var composerContextPresented=false
    private enum ComposerContextAction {case modelConsent,imageConsent,acceptedWork,pendingMessages,settings,latest}
    @State private var pendingContextAction:(action:ComposerContextAction,conversation:UUID?,scope:UUID,modelIdentity:ObjectIdentifier)?
    @State private var contextJumpRequested=false
    @ScaledMetric(relativeTo: .footnote) private var followupRowHeight = 64.0
    @FocusState private var focused: Bool

    init(model:ConversationFirstModel,accountLabel:String?=nil,onSignOut:(()->Void)?=nil,
         isAnonymousAccount:Bool=false,restrictToFrozenFixture:Bool=false) {
        self.model=model
        let chrome=ConversationComposerChromeAdapter(model:model,sendsEnabled:!restrictToFrozenFixture)
        _composerChrome=StateObject(wrappedValue:chrome)
        _attachmentUploader=StateObject(wrappedValue:LocalMockComposerAttachmentUploader { [weak chrome] id,status in
            guard let chrome,let index=chrome.attachments.firstIndex(where:{$0.id==id}) else {return false}
            chrome.attachments[index].status=status
            return true
        })
        self.accountLabel=accountLabel
        self.onSignOut=onSignOut
        self.isAnonymousAccount=isAnonymousAccount
        self.restrictToFrozenFixture=restrictToFrozenFixture
    }
    #if DEBUG
    @ObservedObject private var probe=P0ExperienceProbe.shared
    #endif
    private var sidebarSnapshot:SidebarSnapshot {
        .init(contextID:model.scope.workspaceID.uuidString,selectedConversationID:model.conversationID,
              conversations:model.history.map{.init(id:$0.id,title:$0.title,preview:$0.conversation?.draftText,updatedAt:$0.header.updatedAt)},
              capabilities:.init(canCreateConversation:model.loaded && !model.busy && !model.isInputComposing,canSelectConversation:!model.busy && !model.isInputComposing,tasks:true,results:true,memory:model.loaded && model.memoryConfigured,settings:true),
              account:.init(name:accountLabel ?? ui("本机用户"),detail:isAnonymousAccount ? ui("未登录") : nil))
    }
    private func route(_ destination:SidebarDestination) {
        switch destination {
        case .newConversation:path=[];model.newConversation()
        case .conversation(let id):Task {do {try await model.select(id);path=[]}catch{model.error=error.localizedDescription}}
        case .tasks:path.append(.tasks)
        case .results:path.append(.results)
        case .settings:path.append(.settings)
        case .memory:if model.loaded && model.memoryConfigured {path.append(.memory)}
        }
    }
    private var conversationTitle:String {
        let title=model.history.first(where:{$0.id==model.conversationID})?.title.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return title.isEmpty ? ui("新对话") : title
    }
    private var r8Title:String { model.history.first(where:{$0.id==model.conversationID}) == nil ? "Catpaw" : shortConversationTitle }
    private var r8ModelLabel:String {
        switch ConversationModelRoute.current { case .automatic: return "Auto"; case .gemini: return "Gemini"; case .groq: return "Groq"; case .openrouter: return "OpenRouter"; case .agnes: return "Flash" }
    }
    private var conversationTitleMenu: some View {
        Menu {
            Section(ui("模型")) {
                ForEach(ConversationModelRoute.allCases) { route in
                    Button { route.select() } label: { if route == .current { Label(route.title, systemImage:"checkmark") } else { Text(route.title) } }
                }
            }
            Section {
                Label(connectionMonitor.state.labelKey.map{ui($0.key,arguments:$0.arguments)} ?? ui("连接正常"), systemImage: connectionMonitor.state == .online ? "wifi" : "wifi.slash")
                Button { path.append(.settings) } label: { Label(ui("设置"), systemImage:"slider.horizontal.3") }.accessibilityIdentifier("chat.settings")
            }
        } label: {
            HStack(spacing:5) {
                if connectionMonitor.state != .online {
                    Circle().fill(connectionMonitor.state == .offline ? CatpawColors.tertiary : CatpawBrand.paw).frame(width:6,height:6)
                        .accessibilityIdentifier("chat.title.statusDot")
                }
                Text(r8Title).font(CatpawTypography.Role.body.font.weight(.semibold)).foregroundStyle(CatpawColors.ink).lineLimit(1).truncationMode(.tail)
                Text(r8ModelLabel).font(CatpawTypography.Role.secondary.font.weight(.medium)).foregroundStyle(CatpawColors.tertiary).lineLimit(1)
                Image(systemName:"chevron.down").font(CatpawTypography.Role.caption.font.weight(.semibold)).imageScale(.small).foregroundStyle(CatpawColors.tertiary)
            }.frame(maxWidth:220).contentShape(Rectangle())
        }
        .accessibilityLabel(conversationTitle).accessibilityAddTraits(.isHeader).accessibilityIdentifier("chat.title")
    }
    private var shortConversationTitle:String {
        let line=String(conversationTitle.split(separator:"\n",maxSplits:1).first ?? Substring(conversationTitle))
        return line.count>18 ? String(line.prefix(18))+"…" : line
    }
    private var sidebarTheme:SidebarTheme {
        SidebarTheme.catpaw.typography(title:CatpawTypography.Role.title.font,heading:CatpawTypography.Role.heading.font,body:CatpawTypography.Role.body.font,secondary:CatpawTypography.Role.secondary.font,caption:CatpawTypography.Role.caption.font).brand(PawMark(size:26,shadow:false))
    }
    private var readingAnchorContext:ConversationReadingAnchorContext? {
        model.conversationID.map {ConversationReadingAnchorContext(profileID:model.scope.profileID,scopeID:model.scope.workspaceID,conversationID:$0)}
    }
    private var timelineRows:[ConversationTimelineProjection.Row] {
        guard let session=model.session else {return []}
        return ConversationTimelineProjection.rows(messages:displayMessages,turns:session.turns)
    }
    private enum RenderedTimelineRow:Identifiable {
        case message(ConversationTimelineProjection.Row),activity(ConversationTurnActivitySnapshot),proactive(CatpawProactiveFeed.Entry)
        var id:UUID {switch self {case .message(let row):return row.id;case .activity(let activity):return stableID("conversation-activity-\(activity.id)");case .proactive(let entry):return entry.rowID}}
        var turnID:UUID? {switch self {case .message(let row):return row.turnID;case .activity(let activity):return activity.id;case .proactive:return nil}}
    }
    private var renderedTimelineRows:[RenderedTimelineRow] {
        let rows=timelineRows
        guard let session=model.session else {return rows.map{.message($0)}}
        let activities=ConversationTurnActivityProjection.snapshots(session:session,rows:rows)
        let byTurn=Dictionary(uniqueKeysWithValues:activities.map{($0.id,$0)})
        var emitted=Set<UUID>(),result:[RenderedTimelineRow]=[]
        for row in rows {
            let activity=row.turnID.flatMap{byTurn[$0]}
            if row.message.role != .user,let activity,emitted.insert(activity.id).inserted {result.append(.activity(activity))}
            // Pending and plain tool receipts live in the single turn summary.
            // Actual task, result and interactive cards keep their original rows.
            let plainReceipt=row.presentation == .message && row.message.role == .tool &&
                !["present_cgui_v1","propose_memory_v1","create_task","revise_current_report_v1",ConversationRevisionWorkCodec.toolName].contains(row.message.toolName ?? "") && linkedGoal(row.message)==nil && row.message.failure==nil
            let emptyTerminal=row.presentation == .message && row.message.role == .assistant && row.message.toolName==nil && row.message.toolCallID==nil && row.message.complete && row.message.failure==nil && row.message.content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            if !emptyTerminal && (activity==nil || (row.presentation != .processPending && !plainReceipt)) {result.append(.message(row))}
            if row.message.role == .user,let activity,emitted.insert(activity.id).inserted {result.append(.activity(activity))}
        }
        for activity in activities where emitted.insert(activity.id).inserted {result.append(.activity(activity))}
        return Self.interleave(proactiveFeed.entries(for:model.conversationID),into:result)
    }
    /// True time order: an event goes after the last row whose time ≤ the event's `created_at`.
    /// Row time = message `createdAt` (local journal time); activity rows inherit the previous row's time.
    /// Legacy messages decode `.distantPast`, so they count as older than every event and cards never
    /// move above old history. Events at the same position keep `created_at` order.
    private static func interleave(_ entries:[CatpawProactiveFeed.Entry],into rows:[RenderedTimelineRow])->[RenderedTimelineRow] {
        guard !entries.isEmpty else {return rows}
        var times:[Date]=[],last=Date.distantPast
        for row in rows {
            if case .message(let message)=row {last=message.message.createdAt}
            times.append(last)
        }
        var after:[Int:[CatpawProactiveFeed.Entry]]=[:]   // -1 = before the first row
        for entry in entries.sorted(by:{$0.event.createdAt<$1.event.createdAt}) {
            let time=entry.event.createdAt
            let index=times.lastIndex(where:{$0<=time}) ?? -1
            after[index,default:[]].append(entry)
        }
        var out:[RenderedTimelineRow]=(after[-1] ?? []).map{.proactive($0)}
        for (index,row) in rows.enumerated() {out.append(row);out.append(contentsOf:(after[index] ?? []).map{.proactive($0)})}
        return out
    }
    private func renderedSpacing(_ row:RenderedTimelineRow,previous:RenderedTimelineRow?)->CGFloat {
        guard let previous else {return 0}
        if case .message(let next)=row,case .message(let prior)=previous {return timelineSpacing(next,previous:prior)}
        return row.turnID != nil && row.turnID==previous.turnID ? 8:24
    }
    @ViewBuilder private func renderedTimelineRow(_ row:RenderedTimelineRow)->some View {
        switch row {case .message(let message):timelineRow(message);case .activity(let activity):ConversationTurnActivity(activity:activity);case .proactive(let entry):ProactiveReminderCardView(entry:entry,feed:proactiveFeed)}
    }
    private var chatNavigation: some View {
        SidebarHost(isPresented:$sidebarPresented,isAtRoot:path.isEmpty && !conversationMenuPresented && !settings && !history && !pendingMessagesPresented && !composerContextPresented && !model.acceptedWorkReviewPresented && model.selectedTaskPlan == nil && model.selectedTaskActions == nil && model.selectedTaskControl == nil && model.pendingModelConsent == nil && model.pendingImageConsent == nil,
                    snapshot:sidebarSnapshot,theme:sidebarTheme,localize:{ui($0)},allowsContentPan:true,onWillOpen:{UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)},
                    onDismissed:{menuFocused=true},onSelect:route) {
        NavigationStack(path:$path) {
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let session = model.session {
                            if displayMessages.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(ui("想一起完成什么？")).font(CatpawTypography.Role.title.font.weight(.semibold)).accessibilityAddTraits(.isHeader)
                                    Text(ui("问一个问题，或说一件想做的事。")).foregroundStyle(CatpawColors.secondary)
                                }.padding(.top, textSize.isAccessibilitySize ? 24 : 64).padding(.bottom, 32).accessibilityIdentifier("chat.empty")
                            }
                            let rows=renderedTimelineRows
                            let turnTails=ConversationTurnUIRow.tails(rows.compactMap{row->(UUID,UUID?)? in if case .message(let m)=row {return (m.id,m.turnID)};return nil})
                            ForEach(Array(rows.enumerated()),id:\.element.id) { index,row in
                                VStack(alignment:.leading,spacing:0) {
                                    renderedTimelineRow(row)
                                    // Per-turn hook: approval card + catpaw.ui.v1 blocks after the turn's last message row.
                                    if let turn=row.turnID,turnTails[turn]==row.id {ConversationTurnUIRow(model:model,session:session,turnID:turn)}
                                }.padding(.top,renderedSpacing(row,previous:index>0 ? rows[index-1]:nil))
                                    .background(ConversationReadingAnchorMarker(id:row.id,context:readingAnchorContext,coordinator:readingAnchor).accessibilityHidden(true)).id(row.id)
                            }
                            if let pending = session.turns.last, [.dispatched,.running].contains(pending.state), !pending.awaitingApproval, pending.assistantMessageID == nil, !composerChrome.stoppedOperations.contains(pending.id),
                               !session.messages.contains(where:{ $0.role == .assistant && !$0.complete }) {
                                PendingThinkingRow(service:model.service,turn:pending).id("pending-\(pending.id)").padding(.top,12)
                            }
                            // Fallbacks for a turn with no message row yet; the feed lives in the generative host.
                            if !turnTails.keys.contains(session.turns.last?.id ?? UUID()) {ConversationApprovalHost(model:model,session:session)}   // catpaw.approval.v1 cards (A2)
                            ConversationGenerativeUIHost(model:model,session:session,inlineTurns:Set(turnTails.keys))   // catpaw.ui.v1 feed + orphan blocks
                            if let latest = session.turns.last, latest.state == .completed, !composerChrome.stoppedOperations.contains(latest.id) {
                                Color.clear.frame(width:1,height:1).accessibilityElement().accessibilityLabel(ui("回复完成")).accessibilityIdentifier("chat.reply.completed")
                            } else if let latest = session.turns.last, latest.state == .failed {
                                Text(ui("此轮回复未完成")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.reply.failed").padding(.top,8)
                            }
                            if let turn = session.unresolved, !turn.awaitingApproval, turn.state == .unknown || !model.sending {
                                Label(turn.error ?? ui("原请求状态待确认"), systemImage: "arrow.clockwise").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.unresolved")
                                Text(ui("发送结果尚未确认。先读取原请求，避免重复发送；草稿会保留。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.recoveryHelp")
                                Button(ui("读取原请求进展")) { model.readOriginal() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).disabled(model.busy).accessibilityHint(ui("只查询原请求，不重新发送消息")).accessibilityIdentifier("chat.observe")
                            }
                        } else { ProgressView(ui("打开对话")) }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                        .background(ConversationReadingAnchorTracker(context:readingAnchorContext,followingLatest:followingLatest,orderedIDs:renderedTimelineRows.map(\.id),coordinator:readingAnchor,onContentSizeChange:{[following = $followingLatest, pending = $scrollTask] in Self.scheduleScroll(proxy,following:following,pending:pending)}).accessibilityHidden(true))
                        .background(ConversationScrollObserver { distance,userScrolled in
                            latestVisible=distance <= 48
                            if userScrolled {
                                followingLatest=latestVisible
                                if !followingLatest {scrollTask?.cancel();scrollTask=nil}
                            }
                            #if DEBUG
                            probe.reading(followingLatest:followingLatest,distance:distance)
                            #endif
                        }.frame(width:0,height:0).accessibilityHidden(true))
                }.scrollDismissesKeyboard(.interactively)
                    .r9TopAlignedTranscript()
                    .accessibilityIdentifier("chat.transcript")
                    .onChange(of: model.session?.messages.last?.content) { _, _ in scheduleScroll(proxy) }
                    .onChange(of: displayMessages.count) { _, _ in scheduleScroll(proxy) }
                    .onChange(of:model.conversationID) { _,_ in
                        scrollTask?.cancel();scrollTask=nil;followingLatest=true;latestVisible=true
                        pendingAttachmentIntentID=nil
                        composerChrome.discardAttachments(using:attachmentUploader)
                        scheduleScroll(proxy)
                    }
                    .onChange(of:contextJumpRequested){_,_ in proxy.scrollTo("latest",anchor:.bottom)}
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ConversationConnectionStatusCapsule(service: model.service, scope: model.scope,
                                                            conversationID: model.conversationID,
                                                            reportError: { model.error = $0 })
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        composer(budget:composerBudget(viewport),jumpToLatest:{
                            followingLatest=true;scrollTask?.cancel();scrollTask=nil
                            proxy.scrollTo("latest",anchor:.bottom)
                        })
                    }
            }
            }.background(CatpawViewportObserver{visibleViewport=$0}.accessibilityHidden(true))
                .onPreferenceChange(ConversationComposerMeasurements.self){composerMeasurements=$0}
            .background(CatpawColors.background).navigationTitle(shortConversationTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // r8 top bar: three bare glyph elements, no per-button glass; whole bar turns glass only after scroll.
                ToolbarItem(placement:.topBarLeading) {
                    if path.isEmpty {
                        Button {sidebarPresented=true} label: {
                            TwoLineMenuGlyph().foregroundStyle(CatpawColors.ink).frame(width:44,height:44).contentShape(Rectangle())
                        }.buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(ui("打开侧栏")).accessibilityIdentifier("sidebar.open").accessibilityFocused($menuFocused)
                    }
                }.r8HiddenSharedBackground()
                ToolbarItem(placement:.principal) { conversationTitleMenu }
                ToolbarItem(placement:.topBarTrailing) {
                    Button { model.newConversation() } label: {
                        Image(systemName:"square.and.pencil").font(CatpawTypography.Role.heading.font).foregroundStyle(CatpawColors.ink).frame(width:44,height:44).contentShape(Rectangle())
                    }
                    .disabled(!model.loaded || model.busy || model.isInputComposing)
                    .accessibilityLabel(ui("新对话")).accessibilityIdentifier("chat.new").buttonStyle(CatpawPressButtonStyle())
                }.r8HiddenSharedBackground()
            }
            .toolbarBackground(.automatic, for:.navigationBar)
            .navigationDestination(for:ConversationHostDestination.self){destination in
                switch destination {
                case .settings:settingsSheet
                case .tasks:
                    if let service=model.inboxService {ConversationInboxView(service:service,mode:.tasks,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active},onReturn:{item in if await model.returnToReceivedWork(item){path=[];return .returned};return .unavailable(model.error.map{ui($0)} ?? ui("无法回到原对话。当前草稿仍保留，请重新读取后再试。"))})}
                    else {ConversationTaskList(model:model)}
                case .results:
                    if let service=model.inboxService {ConversationInboxView(service:service,mode:.results,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active},onReturn:{item in if await model.returnToReceivedWork(item){path=[];return .returned};return .unavailable(model.error.map{ui($0)} ?? ui("无法回到原对话。当前草稿仍保留，请重新读取后再试。"))})}
                    else {ConversationResultList(model:model)}
                case .memory:
                    if let service=model.memoryService {
                        // wave2 V1: new memory page; the reviewed-command page stays reachable as its advanced section.
                        MemoryLibraryView(backend:MemoryLibraryHub.backend ?? ConversationMemoryLibraryAdapter(service:service),advanced:AnyView(ConversationMemoryView(service:service,conversationID:model.conversationID,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active})))
                    }
                case .task(let id):ConversationTaskDetail(model:model,id:id,openArtifact:{artifact in path.append(.artifact(id,ConversationArtifactIdentity(artifact)))})
                case .artifact(let goal,let identity):ConversationArtifactDetail(model:model,goalID:goal,identity:identity,continueArtifact:{mode,selected in
                    Task{if await model.stageArtifactContinuation(goalID:goal,selection:selected,mode:mode){path=[]}}
                })
                }
            }
        }
        }
    }
    private func scheduleScroll(_ proxy:ScrollViewProxy) {
        Self.scheduleScroll(proxy,following:$followingLatest,pending:$scrollTask)
    }
    private static func scheduleScroll(_ proxy:ScrollViewProxy,following:Binding<Bool>,pending:Binding<Task<Void,Never>?>) {
        guard following.wrappedValue,pending.wrappedValue == nil else {return}
        pending.wrappedValue=Task {
            try? await Task.sleep(nanoseconds:100_000_000)
            guard !Task.isCancelled,following.wrappedValue else {return}
            P0ScrollTiming.scroll {proxy.scrollTo("latest",anchor:.bottom)}
            pending.wrappedValue=nil
        }
    }
    private var feedbackNavigation: some View {
        chatNavigation.tint(CatpawColors.ink).foregroundStyle(CatpawColors.ink)
            .sensoryFeedback(.selection, trigger: sidebarPresented, condition: { _, opened in opened })
            .sensoryFeedback(.selection, trigger: settings, condition: { _, opened in opened })
            .sensoryFeedback(.impact(weight:.light), trigger:model.enqueueing, condition: { _, accepted in accepted })
            .sensoryFeedback(.success, trigger: model.session?.turns.last?.state == .completed, condition: { _, completed in completed && model.sending })
            .sensoryFeedback(.warning, trigger: model.error != nil, condition: { _, present in present })
    }
    var body: some View {
        feedbackNavigation
        .modifier(ConversationConsentPresenter(model:model))
        .catpawSheet(isPresented:Binding(get:{model.acceptedWorkReviewPresented},set:{if !$0 {model.closeAcceptedWorkReview()}})) {
            ConversationAcceptedWorkReviewView(originalText:model.acceptedWorkReviewOriginalText,capability:model.acceptedWorkCapability,options:$model.acceptedWorkOptions,saving:model.acceptedWorkReviewSaving,error:model.acceptedWorkReviewError,confirm:model.confirmAcceptedWorkReview,close:model.closeAcceptedWorkReview,revisionTargetTitle:model.revisionWorkReviewTarget.map{$0.artifactTitle+" · v\($0.artifactReference.version)"},lockedToolPolicy:model.revisionWorkReviewPolicy?.toolPolicy,sourceLimitFloor:model.revisionWorkReviewPolicy?.sourceCount ?? 0)
                .interactiveDismissDisabled(model.acceptedWorkReviewSaving)
                .onChange(of:model.acceptedWorkOptions){_,_ in model.saveAcceptedWorkReviewOptions()}
        }
        .catpawSheet(isPresented: $history) { ConversationHistoryView(model: model).presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large]).presentationDragIndicator(.visible) }
        .catpawSheet(isPresented: $settings) { settingsSheet }
        .catpawSheet(item:$model.selectedTaskPlan) { reference in
            ConversationTaskPlanView(service:model.taskPlanService,reference:reference,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active})
        }
        .catpawSheet(item:$model.selectedTaskActions,onDismiss:{Task{await model.refresh()}}) {reference in
            ConversationTaskActionsView(service:model.taskActionService,reference:reference,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active}).environment(\.dynamicTypeSize,textSize)
        }
        .catpawSheet(item:$model.selectedTaskControl,onDismiss:{Task{await model.refresh()}}) {reference in
            ConversationTaskControlView(service:model.taskControlService,reference:reference,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active},onApplied:{envelope in try await model.recordAppliedTaskControl(envelope,reference:reference)}).environment(\.dynamicTypeSize,textSize)
        }
        .catpawSheet(isPresented:$composerContextPresented,onDismiss:completeContextAction) {composerContextSheet}
        .task { await model.start() }
        .task(id:model.conversationID) {
            proactiveFeed.currentAnchor={ [model] in
                guard let session=model.session else {return nil}
                return ConversationTimelineProjection.rows(messages:session.messages,turns:session.turns).last?.id
            }
            await proactiveFeed.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.willEnterForegroundNotification)) { _ in proactiveFeed.refreshSoon() }
        #if canImport(ActivityKit) && os(iOS)
        .task { await CatpawLiveActivityCoordinator.shared.observe(model.service) { [model] in model.conversationID } }
        #endif
        .onDisappear {scrollTask?.cancel();scrollTask=nil}
        .onChange(of:model.outgoingMessages) { _,intents in
            updateAttachmentAdmission(intents)
            #if DEBUG
            probe.update(model)
            #endif
        }
         .onChange(of: scene) { _, value in model.sceneChanged(value)
            #if DEBUG
            probe.scene(value)
            #endif
        }
        #if DEBUG
        .onAppear { probe.start();probe.update(model) }
        .onChange(of:model.draft) { _, _ in probe.update(model) }
        .onChange(of:model.session?.turns.last?.lastSequence) { _, _ in probe.update(model) }
        .overlay(alignment:.topTrailing) { if probe.enabled && CatpawDebugPresentation.showFixtureBadge() && P0ExperienceFixture.launchEnvironment["CATPAW_QA_VISUAL_REVIEW"] != "1" { VStack {
            Text("Synthetic offline fixture").font(.caption2).accessibilityIdentifier("qa.p0Fixture")
            Text("P0 probe").font(.caption2).accessibilityIdentifier("qa.p0Probe").accessibilityValue(probe.json)
            if P0PerformanceLog.shared.enabled {Button("Export metrics"){probe.exportMetrics()}.font(.caption2).accessibilityIdentifier("qa.p0Export")}
            if P0ExperienceFixture.scenario == "p0-ui-reading-growth" {
                Button {P0ExperienceFixture.readingGrowthStage += 1} label: {Text(verbatim:"Deliver next layout fixture result").font(CatpawTypography.Role.caption.font)}
                    .accessibilityIdentifier("qa.reading.grow")
            }
            if P0ExperienceFixture.scenario == "p0-ui-ime" { HStack {
                Button("Marked") { ConversationTextView.fixtureEditor?.becomeFirstResponder();ConversationTextView.fixtureEditor?.setMarkedText("nihao",selectedRange:NSRange(location:5,length:0));probe.update(model) }.accessibilityIdentifier("qa.p0IME.mark")
                Button("CmdReturn") { ConversationTextView.fixtureEditor?.commandSubmit();probe.update(model) }.accessibilityIdentifier("qa.p0IME.command")
                Button("Commit") { ConversationTextView.fixtureEditor?.unmarkText();probe.update(model) }.accessibilityIdentifier("qa.p0IME.commit")
            } }
        }.dynamicTypeSize(.large).padding(4).background(CatpawColors.panel).opacity(sidebarPresented ? 0 : 1).allowsHitTesting(!sidebarPresented).accessibilityHidden(sidebarPresented) } }
        #endif
        .overlay { if scene != .active || !UIApplication.shared.isProtectedDataAvailable { ZStack { CatpawColors.background.ignoresSafeArea(); Label(ui("解锁后查看对话"), systemImage: "lock.fill") }.accessibilityIdentifier("chat.privacyShield") } }
    }
    private var settingsSheet: some View {
        ConversationConnectionView(model: model,embedded:true)
            .safeAreaInset(edge:.bottom) { if onSignOut != nil { VStack(spacing:12) { if let accountLabel { Text(accountLabel).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }; Button(ui("退出此账号"), role:.destructive) { confirmSignOut = true }.touchTarget().accessibilityIdentifier("auth.signOut") }.padding().frame(maxWidth:.infinity).background(CatpawColors.background) } }
            .confirmationDialog(ui("退出此账号？"), isPresented:$confirmSignOut, titleVisibility:.visible) {
                Button(ui("确认退出"), role:.destructive) { path=[];settings = false;onSignOut?() }
                Button(ui("取消"), role:.cancel) { }
            } message: { Text(isAnonymousAccount ? ui("体验身份暂时无法找回。退出后，你将无法继续访问这些对话。") : ui("退出后需重新登录才能继续访问此账号的对话。")) }
            .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large]).presentationDragIndicator(.visible)
    }
    private var connectionSummary: String {
        switch model.connection.state {
        case .connected: model.connection.model ?? ui("已连接")
        case .providerUnverified: ui("服务可达")
        case .unavailable: ui("连接暂不可用")
        case .notConfigured: ui("模型未连接")
        }
    }
    private var draftTooLong: Bool { model.draft.utf16.count > 8000 }
    /// r8 meta line above the pill: only when there is a status.
    private var composerMetaText: String? {
        if draftTooLong { return ui("超出 8000 字") }
        if model.connectionLifecycle == .offline || model.connection.state == .unavailable || connectionMonitor.state == .offline || !connectionMonitor.waitingForNetwork.isEmpty { return ui("等待网络 · 恢复后自动发送") }
        if composerChrome.queuedDraftPreview != nil { return ui("已排队 · 当前回复结束后发送") }
        return nil
    }
    private var canSendDraft: Bool { !restrictToFrozenFixture && model.canAcceptDraft && !draftTooLong && composerChrome.attachmentsAreReady }
    private var composerIsDrafting:Bool { !model.draft.isEmpty || model.isInputComposing }
    private var composerControlSize:CGFloat { max(44,CatpawTypography.font(.body,size:textSize).lineHeight) }
    private func composerBudget(_ viewport:GeometryProxy)->CatpawTextViewport.ComposerBudget {
        let available=visibleViewport?.visibleBounds.height ?? viewport.size.height
        let lineHeight=CatpawTypography.font(.body,size:textSize).lineHeight
        let targetHeight=model.artifactContinuation == nil ? 0:max(52,composerMeasurements["targetAnchor"] ?? 52)
        // The shared allocator already reserves a 44pt single-row control. Drafting
        // adds a separate tool row, so reserve only that row's additional height.
        let toolHeight=composerControlSize
        let extraToolRow=composerIsDrafting ? toolHeight+8-max(0,44-lineHeight-16):0
        return CatpawTextViewport.composerBudget(available:max(0,available-extraToolRow),lineHeight:lineHeight,textInsets:16,targetHeight:targetHeight,desiredContextHeight:composerMeasurements["context"] ?? 0)
    }
    private func composer(budget:CatpawTextViewport.ComposerBudget,jumpToLatest:@escaping()->Void)->some View {
        return VStack(alignment:.leading,spacing:0) {
            // The picker remains mounted here while this viewport changes height.
            // A details picker shares the scoped draft and owns only its read ticket.
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    if !followingLatest && !latestVisible {
                        JumpToLatestButton(hasNewContent:model.sending,action:jumpToLatest)
                            .accessibilityHint(ui("返回对话底部，继续跟随新回复")).frame(maxWidth:.infinity)
                    }
                    composerContext(inDetails:false)
                }.frame(maxWidth:.infinity,alignment:.leading)
                    .background{GeometryReader{geometry in Color.clear.preference(key:ConversationComposerMeasurements.self,value:["context":geometry.size.height])}}
            }.scrollDismissesKeyboard(.never).frame(height:budget.contextHeight).clipped()
                .allowsHitTesting(budget.contextHeight>0 && !composerContextPresented).accessibilityHidden(budget.contextHeight==0 || composerContextPresented)
                .padding(.bottom,budget.contextHeight>0 ? 8:0).accessibilityIdentifier("chat.input.context.viewport")
            if let target=model.artifactContinuation,budget.showsTarget {
                artifactContinuationChip(target).padding(.bottom,8)
            }
            FloatingComposer(model:composerChrome,lineCount:composerLineCount,uploader:attachmentUploader,
                             trailingAccessory:AnyView(
                                ComposerDictationControls(model:model,responding:composerChrome.runState == .responding,canSend:canSendDraft,
                                                          size:composerControlSize,send:submitDraft,stop:{composerChrome.stop()})
                             ),
                             metaText:composerMetaText,metaWarning:draftTooLong,
                             onDetails:{ guard !model.isInputComposing else {return}; composerContextPresented=true }) {
                NativeConversationComposer(model:model,
                    enabled:!restrictToFrozenFixture && !model.switchingArtifactContinuation,
                    maximumVisibleHeight:min(budget.maximumTextHeight,ComposerMetrics.maxHeight(for:textSize)),
                    placeholder:composerChrome.runState == .responding ? ui("继续追问…") : ui("问问 Catpaw"),
                    lineCountChanged:{composerLineCount=$0},
                    addAttachments:{_ = composerChrome.addAttachments($0,using:attachmentUploader)},
                    submit:{if canSendDraft {submitDraft()}})
                    .background{GeometryReader{geometry in Color.clear.preference(key:ConversationComposerMeasurements.self,value:["text":geometry.size.height])}}
            }
                .onAppear{composerChrome.setSendAction(submitDraft)}
                .accessibilityElement(children:.contain).accessibilityIdentifier("chat.input.container")
        }.background(alignment:.topLeading) {
            if let target=model.artifactContinuation {
                // Measure in the same content-column width as the visible chip,
                // before outer padding. Keep this intrinsic measurement mounted
                // when the budget hides the chip, so visibility cannot reset it.
                artifactContinuationChip(target).frame(maxWidth:.infinity).fixedSize(horizontal:false,vertical:true)
                    .background{GeometryReader{geometry in Color.clear.preference(key:ConversationComposerMeasurements.self,value:["targetAnchor":geometry.size.height])}}
                    .hidden().accessibilityHidden(true).allowsHitTesting(false)
            }
        }.padding(.horizontal,4).padding(.top,budget.compactPadding ? 0:4)
            .background(LinearGradient(colors:[CatpawColors.background.opacity(0),CatpawColors.background],startPoint:.top,endPoint:UnitPoint(x:0.5,y:0.28)))
            .accessibilityElement(children:.contain).accessibilityIdentifier("chat.composer")
    }
    private func composerContextButton(budget:CatpawTextViewport.ComposerBudget)->some View {
        Button {
            guard !model.isInputComposing else {return};composerContextPresented=true
        } label:{
            Group {
                if let target=model.artifactContinuation,!budget.showsTarget {
                    Text("v\(target.artifactReference.version)").font(CatpawTypography.Role.caption.font).fixedSize()
                        .accessibilityLabel(target.artifactTitle+" · v\(target.artifactReference.version)")
                } else {Image(systemName:model.artifactContinuation == nil ? "info.circle":"info.circle.fill").font(CatpawTypography.Role.body.font)}
            }.touchTarget(minimum:composerControlSize)
        }.buttonStyle(CatpawPressButtonStyle()).disabled(model.isInputComposing)
            .accessibilityLabel(model.artifactContinuation.flatMap{!budget.showsTarget ? ($0.mode == .reviseReport ? ui("修改这版") : ui("追问这版"))+" · "+$0.artifactTitle+" · v\($0.artifactReference.version) · "+ui("查看输入详情"):nil} ?? ui("查看输入详情")).accessibilityIdentifier("chat.input.context.open")
            .accessibilityValue(model.artifactContinuationSendBlock.map{ui($0)} ?? model.error.map{ui($0)} ?? "")
    }
    private func composerContext(inDetails:Bool)->some View {
        VStack(alignment:.leading,spacing:8) {
            // Current restrictions and decisions precede secondary context.
            if let block=model.artifactContinuationSendBlock {
                Text(ui(block)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).fixedSize(horizontal:false,vertical:true)
                    .accessibilityLabel(ui(block)).accessibilityIdentifier(inDetails ? "chat.input.context.blocked" : "chat.artifact.continuation.blocked")
            }
            if let block=model.imageSendBlock,block != .unavailable {Text(ui(block.message)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("attachment.sendBlock")}
            if model.imageDraft.phase == .ready,model.imageCapability.available,!model.imageGate.imageConsentMatchesCurrentRoute {
                Button(ui("确认图片处理方式")){contextAction(.imageConsent,inDetails:inDetails)}.touchTarget().disabled(!model.canReviewImage).accessibilityIdentifier(inDetails ? "chat.input.context.imageConsent" : "image.consent.review")
            }
            if model.checkingImageConsent {Text(ui("正在读取图片处理方式…")).font(CatpawTypography.Role.caption.font).accessibilityIdentifier("image.consent.loading")}
            #if DEBUG
            if restrictToFrozenFixture { Text(ui("合成测试协议证据")).font(.caption2).accessibilityIdentifier("fixture.evidence").accessibilityValue(fixtureEvidence) }
            #endif
            if model.needsModelConsentReview {
                CatpawAdaptiveActions {
                    Text(ui("消息尚未发送，需要确认处理方式。")).font(CatpawTypography.Role.caption.font).fixedSize(horizontal:false,vertical:true)
                    Button(ui("确认发送许可")){contextAction(.modelConsent,inDetails:inDetails)}.touchTarget().disabled(!model.canReviewModelConsent).accessibilityIdentifier(inDetails ? "chat.input.context.modelConsent" : "chat.consent.review")
                }.padding(10).background(CatpawColors.input,in:RoundedRectangle(cornerRadius:12))
            }
            if !model.followups.pending.isEmpty {
                pendingStatusBar(inDetails:inDetails)
            }
            if model.checkingModelConsent { Text(ui("正在准备发送…")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.preparing") }
            if let error = model.error { Text(ui(error)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.error") }
            if draftTooLong {
                Text(ui("消息过长。请缩短后再发送（长度上限 8000）。"))
                    .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention)
                    .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.validation")
            }
            if let target=model.artifactContinuation {
                if !inDetails {Text(target.artifactTitle).font(CatpawTypography.Role.caption.font).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.input.context.targetTitle")}
                if target.taskTitle != target.artifactTitle {Text(target.taskTitle).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true)}
                if !model.continuationDraftSaved {Text(ui("正在保存本地输入…")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)}
            } else {
                ImageAttachmentPicker(draft:model.imageDraft,gate:model.imageGate,localize:{ui($0)}).id(model.scope.workspaceID.uuidString+(model.conversationID?.uuidString ?? ""))
                    // Keep its import ticket and selected-item state mounted. The
                    // compact + opens this same scoped draft in input details.
                    .frame(height:!inDetails && model.imageDraft.phase == .empty ? 0:nil).clipped()
                    .allowsHitTesting(inDetails || model.imageDraft.phase != .empty)
                    .accessibilityHidden(!inDetails && model.imageDraft.phase == .empty)
            }
            if inDetails, [.offline,.notConfigured].contains(model.connectionLifecycle) { Button {contextAction(.settings,inDetails:inDetails)} label: {
                HStack(spacing: 8) {
                    Circle().fill(model.connection.state == .connected ? CatpawColors.success : CatpawColors.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(connectionSummary).font(CatpawTypography.Role.caption.font)
                    Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                }.frame(minHeight:44).contentShape(Rectangle())
            }.buttonStyle(CatpawPressButtonStyle()).foregroundStyle(CatpawColors.secondary).accessibilityLabel(ui("模型连接设置")).accessibilityValue(connectionSummary).accessibilityIdentifier("chat.connection") }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    /// Compact pending-send strip above the composer: one 32pt line, hairline outline, no grey slab.
    /// The inline copy anchors the queue popover; the details copy routes through contextAction.
    @ViewBuilder private func pendingStatusBar(inDetails:Bool)->some View {
        let bar=Button {contextAction(.pendingMessages,inDetails:inDetails)} label: {
            HStack(spacing:6) {
                Image(systemName:model.followups.paused ? "pause.circle" : "clock").imageScale(.small).accessibilityHidden(true)
                Text(ui("待发送 · {0} 条",arguments:[String(model.followups.pending.count)])).fontWeight(.medium).foregroundStyle(CatpawColors.ink)
                Text(verbatim:"·").accessibilityHidden(true)
                Text(model.followups.paused ? ui("已暂停") : ui("等待当前回复")).lineLimit(1)
                Spacer(minLength:4)
                Image(systemName:"chevron.up").imageScale(.small).accessibilityHidden(true)
            }.font(CatpawTypography.Role.caption.font).padding(.horizontal,12).frame(minHeight:32)
                .overlay(Capsule().strokeBorder(CatpawColors.separator,lineWidth:0.5))
                .frame(minHeight:44).contentShape(Rectangle())
        }.foregroundStyle(CatpawColors.secondary).buttonStyle(CatpawPressButtonStyle())
            .accessibilityHint(ui("查看、编辑或暂停本机待发消息")).accessibilityIdentifier(inDetails ? "chat.input.context.pending" : "chat.pendingSummary")
        if inDetails {bar} else {
            bar.popover(isPresented:$pendingMessagesPresented,arrowEdge:.bottom) {
                ConversationPendingMessagesView(model:model)
                    .frame(minWidth:300,idealWidth:340,maxWidth:380)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
    private func artifactContinuationChip(_ target:ConversationArtifactContinuationReference)->some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(alignment:.center,spacing:8) {
                Text(target.mode == .reviseReport ? ui("修改这版") : ui("追问这版")).font(CatpawTypography.Role.caption.font.weight(.semibold))
                    .accessibilityLabel(target.mode == .reviseReport ? ui("请 Agent 修改这版") : ui("针对这版追问"))
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth:.infinity,alignment:.leading)
                Text("v\(target.artifactReference.version)").font(CatpawTypography.Role.caption.font).fixedSize()
                    .accessibilityLabel(target.artifactTitle+" · v\(target.artifactReference.version)").accessibilityIdentifier("chat.artifact.continuation.target")
                Button {Task{_ = await model.leaveArtifactContinuation()}} label:{Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle())}
                    .disabled(model.isInputComposing || model.switchingArtifactContinuation || model.enqueueing).buttonStyle(CatpawPressButtonStyle()).accessibilityLabel(ui("退出针对成果的输入")).accessibilityHint(ui("保留这份输入并恢复普通聊天草稿，不取消已提交的修改。"))
                    .accessibilityIdentifier("chat.artifact.continuation.leave")
            }
        }.padding(.horizontal,12).padding(.vertical,4).background(CatpawColors.input,in:RoundedRectangle(cornerRadius:12)).accessibilityElement(children:.contain)
    }
    private var composerContextSheet:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if !followingLatest && !latestVisible {Button(ui("回到最新")){contextAction(.latest,inDetails:true)}.touchTarget().accessibilityIdentifier("chat.input.context.latest")}
                    if let target=model.artifactContinuation {
                        Text(target.mode == .reviseReport ? ui("修改这版") : ui("追问这版")).font(CatpawTypography.Role.heading.font)
                            .accessibilityIdentifier("chat.input.context.intent")
                        CatpawVersionedTitle(title:target.artifactTitle,version:"v\(target.artifactReference.version)",versionAccessibilityIdentifier:"chat.input.context.version")
                        Button(ui("退出针对成果的输入")){Task{if await model.leaveArtifactContinuation(){composerContextPresented=false}}}
                            .touchTarget().disabled(model.isInputComposing || model.switchingArtifactContinuation || model.enqueueing).accessibilityIdentifier("chat.input.context.leave")
                    }
                    if model.revisionRequiresWorkReview {
                        Button(ui("核对本次修改的工作约定")){contextAction(.acceptedWork,inDetails:true)}.touchTarget().disabled(!model.canReviewRevisionWork).accessibilityHint(ui("先核对原请求、期限和调用次数，确认后才提交。")).accessibilityIdentifier("chat.input.context.revisionWork")
                    }
                    if model.artifactContinuation==nil && model.imageDraft.phase == .empty {
                        Button(ui("交给 Agent 完成")){contextAction(.acceptedWork,inDetails:true)}.touchTarget().disabled(!model.canReviewAcceptedWork).accessibilityHint(ui("先核对原请求、期限和调用次数，确认后才提交。")).accessibilityIdentifier("chat.input.context.acceptedWork")
                    }
                    composerContext(inDetails:true)
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }.background(CatpawColors.background).accessibilityIdentifier("chat.input.context.scroll").navigationTitle(ui("输入详情")).navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.confirmationAction){Button(ui("完成")){composerContextPresented=false}.touchTarget().accessibilityIdentifier("chat.input.context.close")}}
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .onAppear{UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)}
    }
    private func contextAction(_ action:ComposerContextAction,inDetails:Bool) {
        if inDetails {
            pendingContextAction=(action,model.conversationID,model.scope.workspaceID,ObjectIdentifier(model));composerContextPresented=false
        } else {performContextAction(action)}
    }
    private func completeContextAction() {
        guard let pending=pendingContextAction else {return};pendingContextAction=nil
        guard pending.conversation==model.conversationID,pending.scope==model.scope.workspaceID,pending.modelIdentity==ObjectIdentifier(model) else {return}
        performContextAction(pending.action)
    }
    private func performContextAction(_ action:ComposerContextAction) {
        switch action {
        case .modelConsent:model.requestModelConsentReview()
        case .imageConsent:model.requestImageConsent()
        case .acceptedWork:model.requestAcceptedWorkReview()
        case .pendingMessages:pendingMessagesPresented=true
        case .settings:path.append(.settings)
        case .latest:followingLatest=true;scrollTask?.cancel();scrollTask=nil;contextJumpRequested.toggle()
        }
    }
    #if DEBUG
    private var fixtureEvidence: String {
        guard let id = model.conversationID,let turn = model.session?.turns.last,let goal = model.session?.goals.values.first,let binding = goal.binding else { return "{}" }
        var values: [String:Any] = ["conversation_id":id.uuidString,"turn_id":turn.id.uuidString,"run_id":binding.run_id.uuidString,"task_id":binding.task_id,"projection_url":binding.projection_url,"state":goal.state.rawValue]
        values["artifact_history"] = goal.artifactHistory.map { ["artifact_id":$0.id,"version":$0.version,"hash":$0.contentHash] as [String:Any] }
        if let artifact = goal.artifacts.first { values["artifact_id"] = artifact.id; values["artifact_version"] = artifact.version; values["artifact_hash"] = artifact.contentHash }
        return (try? JSONSerialization.data(withJSONObject:values,options:.sortedKeys)).map { String(decoding:$0,as:UTF8.self) } ?? "{}"
    }
    #endif
    private var displayMessages:[ConversationTranscriptMessage] {
        #if DEBUG
        let timingStart=ProcessInfo.processInfo.systemUptime
        defer {P0PerformanceLog.shared.record("display_messages",start:timingStart,end:ProcessInfo.processInfo.systemUptime,main:true)}
        #endif
        var messages=model.session?.messages ?? []
        let pendingIDs=Set(model.followups.pending.map(\.id)),firstPending=model.followups.pending.first?.id
        for intent in model.outgoingMessages {
            // Follow-ups belong to the queue sheet, not to the admitted transcript.
            // The first permission intent still has a visible echo and persistent review action.
            let primaryAdmission=intent.id == firstPending && ((model.session?.unresolved == nil && !model.followups.paused) || intent.state == .awaitingPermission)
            if pendingIDs.contains(intent.id),!primaryAdmission {continue}
            if intent.state == .savingLocal,(model.sending || model.session?.unresolved != nil || !model.followups.pending.isEmpty) {continue}
            let id=stableID("conversation-user-\(intent.id)")
            if !messages.contains(where:{$0.id == id}) { messages.append(.init(id:id,role:.user,content:intent.text,image:intent.image)) }
        }
        // Older busy-retry journals could contain more than one user row for the
        // same operation. Current retries reuse operationID, so render it once.
        var seenOperations = Set<UUID>()
        return messages.filter { message in
            guard message.role == .user, let operation = operationID(message) else { return true }
            return seenOperations.insert(operation).inserted
        }
    }
    private func timelineSpacing(_ row:ConversationTimelineProjection.Row,previous:ConversationTimelineProjection.Row?)->CGFloat {
        guard let previous else {return 0}
        guard let turn=row.turnID,turn==previous.turnID else {return 24}
        let process=row.message.role == .tool || row.message.toolName != nil || previous.message.role == .tool || previous.message.toolName != nil
        return process ? 8:12
    }
    @ViewBuilder private func timelineRow(_ row:ConversationTimelineProjection.Row)->some View {
        switch row.presentation {
        case .message:messageView(row.message,turnID:row.turnID)
        case .processPending:
            Label(row.message.toolName == "agent_status" ? ui("读取任务进展…"):ui("正在处理请求…"),systemImage:"circle.dotted")
                .font(CatpawTypography.Role.caption.font).symbolRenderingMode(.monochrome)
                .foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.process.\(row.id)")
        case .fallback:
            VStack(alignment:.leading,spacing:4) {
                Label(ui("处理进展待核对"),systemImage:"exclamationmark.circle").font(CatpawTypography.Role.caption.font)
                    .symbolRenderingMode(.monochrome).foregroundStyle(CatpawColors.attention)
                if let failure=row.message.failure,!failure.isEmpty {
                    Text(verbatim:failure).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                }
                // observe() owns only unresolved-or-latest. Never bind a historical
                // process row to a different operation's read action.
                if let turnID=row.turnID,let current=model.session?.unresolved ?? model.session?.turns.last,
                   current.id==turnID,current.state != .notSent,current.state != .cancelledBeforeSend {
                    Button(ui("读取原请求进展")) {model.readOriginal()}
                        .touchTarget().buttonStyle(CatpawPressButtonStyle()).disabled(model.busy)
                        .accessibilityHint(ui("只查询原请求，不重新发送消息"))
                        .accessibilityIdentifier("chat.process.observe.\(row.id)")
                }
            }.accessibilityIdentifier("chat.process.\(row.id)")
        }
    }
    private func submitDraft() {
        if canSendDraft {followingLatest=true}
        let time=ProcessInfo.processInfo.systemUptime,old=Set(model.outgoingMessages.map(\.id))
        let hadAttachments = !composerChrome.attachments.isEmpty
        model.prepareSend()
        let admitted=model.outgoingMessages.last(where:{!old.contains($0.id)})
        if hadAttachments {pendingAttachmentIntentID=admitted?.id}
        #if DEBUG
        if let intent=admitted { probe.pressed(intent.id,at:time);probe.update(model) }
        #endif
    }
    private func updateAttachmentAdmission(_ intents:[OutgoingMessageIntent]) {
        guard let id=pendingAttachmentIntentID,
              let intent=intents.first(where:{$0.id==id}) else {return}
        switch intent.state {
        case .savingLocal:return
        case .failed:pendingAttachmentIntentID=nil
        case .queued,.awaitingPermission,.sending,.unknown:
            pendingAttachmentIntentID=nil
            composerChrome.discardAttachments(using:attachmentUploader)
        }
    }
    private func operationID(_ message:ConversationTranscriptMessage) -> UUID? {
        model.outgoingMessages.first(where:{stableID("conversation-user-\($0.id)") == message.id})?.id ?? model.session?.turns.first(where:{stableID("conversation-user-\($0.id)") == message.id})?.id
    }
    /// r9 bubble status: sent → nothing; queued/offline → nothing (pending strip owns it);
    /// sending → tiny spinner only after ~2 s without turn start; failed → red ! + "未发送·点按重试".
    enum BubbleStatus { case none, sending, failed }
    private func bubbleStatus(_ id:UUID) -> BubbleStatus {
        if let intent=model.outgoingMessages.first(where:{$0.id == id}) {
            switch intent.state { case .sending: return .sending; case .failed, .unknown: return .failed; default: return .none }
        }
        guard let turn = model.session?.turns.first(where:{$0.id == id}) else { return .none }
        if turn.state == .failed && turn.error != "cancelled" && turn.assistantMessageID == nil { return .failed }
        if turn.state == .dispatched && turn.lastSequence == 0 { return .sending }
        return .none
    }
    private func delivery(_ id:UUID) -> String {
        if let intent=model.outgoingMessages.first(where:{$0.id == id}) {
            switch intent.state {
            case .savingLocal:return ui("正在本机保存")
            case .queued:return ui("已保存在本机 · 待发送")
            case .awaitingPermission:return ui("等待许可")
            case .sending:return ui("发送中")
            case .unknown:return ui("确认发送状态")
            case .failed:return ui("本机保存未完成")
            }
        }
        return model.session?.turns.first(where:{$0.id == id})?.serverRequestHash == nil ? ui("发送中") : ui("已发送")
    }
    private func linkedGoal(_ message: ConversationTranscriptMessage) -> ConversationGoalProjection? {
        guard message.role == .tool, ["delegate_task","delegate_plan_v1","delegate_sources_v1"].contains(message.toolName ?? ""), let session = model.session,
              let binding = try? JSONDecoder().decode(ConversationTaskBinding.self, from: Data(message.content.utf8)),
              binding.conversation_id == session.conversationID, let goal = session.goals[binding.task_id], goal.binding?.run_id == binding.run_id else { return nil }
        return goal
    }
    @ViewBuilder private func messageView(_ message: ConversationTranscriptMessage,turnID:UUID?) -> some View {
        if message.role == .user {
            VStack(alignment:.trailing,spacing:4) {
                ConversationUserMessageLayout {
                    Text(message.content).font(CatpawTypography.Role.body.font).textSelection(.enabled)
                        .foregroundStyle(CatpawColors.userMessageInk).padding(.horizontal,14).padding(.vertical,9)
                        .background(CatpawColors.userMessageBackground,in:RoundedRectangle(cornerRadius:20,style:.continuous))
                }
                    .accessibilityIdentifier("chat.userMessage")
                    #if DEBUG
                    .background { if let id=operationID(message),probe.enabled { P0EchoWitness(operationID:id) } }
                    #endif
                if message.image != nil {Label(ui("附带图片"),systemImage:"photo").font(CatpawTypography.Role.caption.font).accessibilityIdentifier("chat.message.image")}
                if let id=operationID(message) {
                    if connectionMonitor.waitingForNetwork.contains(id) {
                        Text(ui("等待网络")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                            .accessibilityIdentifier("chat.waitingForNetwork")
                    }
                    switch bubbleStatus(id) {
                    case .none: EmptyView()
                    case .sending: DelayedSendingSpinner().accessibilityIdentifier("chat.bubble.sending")
                    case .failed:
                        Button { model.resumeFollowups() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(CatpawColors.attention).imageScale(.small)
                                Text(ui("未发送·点按重试")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention)
                            }
                        }.buttonStyle(CatpawPressButtonStyle()).accessibilityIdentifier("chat.bubble.retry")
                    }
                }
            }
        } else if message.role == .tool || message.toolName != nil {
            if message.toolName == "present_cgui_v1",let session=model.session {
                if message.role == .tool || !message.complete {
                    ConversationGenerativeUIMessageView(message:message,session:session,stateService:model.generativeUIStateService) {
                        followingLatest=false;scrollTask?.cancel();scrollTask=nil
                    }
                }
            }
            else if message.toolName=="propose_memory_v1" {
                if message.role == .tool || !message.complete || message.failure != nil {
                    if let failure=message.failure {Label(ui("记忆候选提取失败 · ")+failure,systemImage:"exclamationmark.circle").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention)}
                    else if message.role == .tool,let session=model.session,let receipt=try? ConversationMemoryProposalReceipt.transcript(message,session:session,serverScopeID:model.memoryService?.reference.serverScopeID) {
                        VStack(alignment:.leading,spacing:8) {
                            Label(receipt.candidates.isEmpty ? ui("没有新增记忆候选"):ui("记忆候选待确认"),systemImage:"brain").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.memoryProposal.pending")
                            if !receipt.candidates.isEmpty,model.memoryConfigured {Button(ui("查看记忆候选")){path.append(.memory)}.touchTarget().accessibilityIdentifier("chat.memoryProposal.open")}
                        }
                    }else{Label(message.role == .tool ? ui("记忆候选回执待核对"):ui("提取记忆候选…"),systemImage:"circle.dotted").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)}
                }
            }
            else if ["revise_current_report_v1",ConversationRevisionWorkCodec.toolName].contains(message.toolName ?? "") {
                if let failure=message.failure {Label(ui("修改请求失败 · ")+failure,systemImage:"exclamationmark.circle").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention)}
                else if message.role == .tool,let turn=model.session?.turns.first(where:{turn in
                    guard let receipt=turn.continuationReceipt else {return false}
                    return receipt.call_id==message.toolCallID && message.id==stableID("conversation-tool-result-\(turn.id)-\(receipt.call_id)") && (try? receipt.validate(request:turn.request,callID:receipt.call_id)) != nil
                }),let receipt=turn.continuationReceipt {
                    VStack(alignment:.leading,spacing:8) {
                        Label(ui("修改请求已受理"),systemImage:"checkmark.circle").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.revisionWork.accepted")
                        if model.session?.goals[receipt.task_id] != nil {Button(ui("查看修改进展")){path.append(.task(receipt.task_id))}.touchTarget().accessibilityIdentifier("chat.revisionWork.openTask")}
                    }
                } else if message.role == .tool || !message.complete {Label(message.role == .tool ? ui("修改回执待核对"):ui("正在核对修改请求…"),systemImage:"circle.dotted").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)}
            }
            else if message.toolName=="create_task" { if message.role == .tool || !message.complete { CreateTaskCardView(message:message) } }   // A2 task card
            else if let goal = linkedGoal(message) { ConversationGoalCard(goal: goal, busy: model.busy, refresh: model.readOriginal, openPlan: model.taskPlansConfigured && goal.binding != nil ? { model.openTaskPlan(goal) } : nil,openActions:model.taskReviewsConfigured && goal.binding != nil ? {model.openTaskActions(goal)} : nil,openControl:model.taskControlsConfigured && goal.binding != nil ? {model.openTaskControl(goal)} : nil,openArtifact:{artifact in path.append(.artifact(goal.id,ConversationArtifactIdentity(artifact)))}) }
            else if message.failure != nil { Label(ui("任务请求失败 · ") + (message.failure ?? ""), systemImage: "exclamationmark.circle").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention) }
            else { Label(message.toolName == "agent_status" ? (message.complete ? ui("任务进展已读取") : ui("读取任务进展…")) : (message.complete ? ui("任务请求已记录") : ui("等待后台保存任务…")), systemImage: message.complete ? "checkmark.circle" : "circle.dotted").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }

        } else {
            assistantMessage(message,turnID:turnID)
        }
    }
    @ViewBuilder private func assistantMessage(_ message:ConversationTranscriptMessage,turnID:UUID?)->some View {
        if let turnID,let turn=model.session?.turns.first(where:{$0.id==turnID}),usesPhasedAnswer(turn,message:message) {
            LivePhasedAnswerView(service:model.service,message:message,turn:turn,canQuote:!model.isInputComposing,
                                 onQuote:quote,onVerify:turn.state == .unknown ? {model.readOriginal()}:nil)
        } else {
            ConversationAnswerView(message:message,canQuote:!model.isInputComposing,quote:quote)
        }
    }
    private func usesPhasedAnswer(_ turn:ConversationTurnRecord,message:ConversationTranscriptMessage)->Bool {
        let live:[ConversationTurnRecord.State]=[.dispatched,.running,.unknown,.failed]
        return composerChrome.stoppedOperations.contains(turn.id) || (live.contains(turn.state) && !message.complete)
    }
    private func quote(_ text:String) {
        // Preserve the active IME transaction. Quoting is an explicit draft edit.
        guard !model.isInputComposing else {return}
        let excerpt=String(text.prefix(2000))
        let quotation=excerpt.split(separator:"\n",omittingEmptySubsequences:false).map {"> " + $0}.joined(separator:"\n")
        model.editDraft(model.draft.isEmpty ? quotation + "\n\n" : model.draft + "\n\n" + quotation + "\n\n")
    }
}

@MainActor private struct ConversationConnectionStatusCapsule: View {
    let service: ConversationSessionService
    let scope: DataScope
    let conversationID: UUID?
    let reportError: (String) -> Void
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionInFlight = false
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: locale).ui(key, arguments: arguments) }

    var body: some View {
        Group {
            if monitor.state != .online, let label = monitor.state.labelKey {
                HStack(spacing: 8) {
                    statusSymbol
                    Text(ui(label.key, arguments: label.arguments))
                        .font(CatpawTypography.Role.caption.font.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    action
                }
                .foregroundStyle(CatpawColors.ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: 680)
                .background(CatpawColors.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(CatpawColors.controlEdge))
                .padding(.horizontal, 20).padding(.vertical, 6)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .accessibilityIdentifier("chat.connectionStatus")
            }
        }
        .frame(maxWidth: .infinity)
        .animation(CatpawMotion.resolved(CatpawMotion.statusCapsule, reduceMotion), value: monitor.state)
    }

    @ViewBuilder private var statusSymbol: some View {
        switch monitor.state {
        case .offline: Image(systemName: "wifi.slash")
        case .reconnecting, .syncing: ProgressView().controlSize(.small)
        case .resumed: Image(systemName: "checkmark.circle.fill").foregroundStyle(CatpawColors.success)
        case .unreachable: Image(systemName: "exclamationmark.circle")
        case .busy: Image(systemName: "clock")
        case .online: EmptyView()
        }
    }

    @ViewBuilder private var action: some View {
        switch monitor.state {
        case .unreachable:
            Button(ui("继续获取")) { performContinue() }
                .buttonStyle(CatpawPressButtonStyle()).disabled(actionInFlight || conversationID == nil)
        case .busy:
            Button(ui("现在重试")) { performBusyRetry() }
                .buttonStyle(CatpawPressButtonStyle()).disabled(actionInFlight || conversationID == nil)
        default:
            EmptyView()
        }
    }

    private func performContinue() {
        guard let conversationID else { return }
        actionInFlight = true
        Task {
            defer { actionInFlight = false }
            do { try await service.continueFetching(scope: scope, conversationID: conversationID) }
            catch { reportError(error.localizedDescription) }
        }
    }

    private func performBusyRetry() {
        guard let conversationID else { return }
        actionInFlight = true
        Task {
            defer { actionInFlight = false }
            do { _ = try await service.retryBusy(scope: scope, conversationID: conversationID, route: ConversationModelRoute.current, automatic: false) }
            catch { reportError(error.localizedDescription) }
        }
    }
}

private struct ConversationPendingMessagesView:View {
    @ObservedObject var model:ConversationFirstModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var editing:ConversationFollowup?
    @State private var preparingEdit=false
    @State private var error:String?
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    /// Rows are a single line; the list scrolls once it exceeds this cap.
    private static let rowHeight:CGFloat=44
    private static let maxListHeight:CGFloat=264
    private var listHeight:CGFloat {min(Self.maxListHeight,CGFloat(max(1,model.followups.pending.count))*Self.rowHeight)}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                Text(ui("待发送 · {0} 条").replacingOccurrences(of:"{0}",with:String(model.followups.pending.count)))
                    .font(CatpawTypography.Role.caption.font.weight(.semibold)).foregroundStyle(CatpawColors.ink)
                Spacer(minLength:8)
                if !model.followups.pending.isEmpty {
                    if model.followups.paused {
                        Button(ui("继续发送")){model.resumeFollowups()}.accessibilityIdentifier("chat.followup.resume")
                            .disabled(model.busy || model.editingFollowup || preparingEdit || model.session?.unresolved != nil || ![.connected,.providerUnverified].contains(model.connection.state))
                    } else {
                        Button(ui("暂停")){model.pauseFollowups()}.accessibilityIdentifier("chat.followup.pause").disabled(preparingEdit)
                    }
                }
                Button(ui("完成")){dismiss()}.accessibilityIdentifier("chat.followup.close")
            }.font(CatpawTypography.Role.caption.font).buttonStyle(.borderless).tint(CatpawColors.ink)
                .padding(.horizontal,14).frame(minHeight:40)
            Divider()
            ScrollView {
                LazyVStack(spacing:0) {
                    if model.followups.pending.isEmpty {
                        Text(ui("没有待发消息")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                            .frame(maxWidth:.infinity,minHeight:Self.rowHeight).accessibilityIdentifier("chat.followup.empty")
                    }
                    ForEach(model.followups.pending) {message in row(message)}
                }
            }.frame(height:listHeight).scrollBounceBehavior(.basedOnSize)
            if let error {
                Text(ui(error)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention)
                    .padding(.horizontal,14).padding(.vertical,6).accessibilityIdentifier("chat.followup.error")
            }
        }
        .background(CatpawColors.background)
        .accessibilityElement(children:.contain)
        .accessibilityHint(ui("待发消息保存在本机，仅在 App 前台发送。编辑会暂停队列，保存或关闭不会继续发送。"))
        .catpawSheet(item:$editing) {message in ConversationPendingMessageEditor(model:model,message:message)}
    }
    private func row(_ message:ConversationFollowup)->some View {
        HStack(spacing:4) {
            if message.image != nil {
                Image(systemName:"photo").imageScale(.small).foregroundStyle(CatpawColors.secondary).accessibilityLabel(ui("附带图片"))
            }
            Text(verbatim:message.text.replacingOccurrences(of:"\n",with:" ")).font(CatpawTypography.Role.body.font)
                .foregroundStyle(CatpawColors.ink).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth:.infinity,alignment:.leading)
            Button {
                preparingEdit=true;error=nil
                Task {do {try await model.pauseQueueForEditing(message);editing=message} catch {self.error=error.localizedDescription};preparingEdit=false}
            } label: {Image(systemName:"pencil").imageScale(.small).frame(width:32,height:Self.rowHeight).contentShape(Rectangle())}
                .disabled(preparingEdit || model.editingFollowup || message.image != nil)
                .accessibilityLabel(ui("编辑待发消息")).accessibilityIdentifier("chat.followup.edit."+message.id.uuidString)
            Button {model.removeFollowup(message.id)} label: {Image(systemName:"trash").imageScale(.small).frame(width:32,height:Self.rowHeight).contentShape(Rectangle())}
                .disabled(preparingEdit || model.editingFollowup)
                .accessibilityLabel(ui("移除后续消息")).accessibilityIdentifier("chat.followup.remove."+message.id.uuidString)
        }.buttonStyle(.borderless).foregroundStyle(CatpawColors.secondary)
            .padding(.leading,14).padding(.trailing,6).frame(height:Self.rowHeight)
            .overlay(alignment:.bottom){Divider().padding(.leading,14)}
    }
}
private struct ConversationPendingMessageEditor:View {
    @ObservedObject var model:ConversationFirstModel
    let message:ConversationFollowup
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var text:String
    @State private var saving=false
    @State private var error:String?
    init(model:ConversationFirstModel,message:ConversationFollowup) {self.model=model;self.message=message;_text=State(initialValue:message.text)}
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    private var valid:Bool {!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.utf16.count <= 8000}
    var body:some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:12) {
                Text(ui("队列已暂停。保存后仍需明确继续发送。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                TextEditor(text:$text).font(CatpawTypography.Role.body.font).accessibilityLabel(ui("待发消息内容")).accessibilityIdentifier("chat.followup.editor")
                if !valid {Text(ui("请输入不超过 8000 字符的内容。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention)}
                if let error {Text(ui(error)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.followup.editError")}
            }.padding().navigationTitle(ui("编辑待发消息")).navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.cancellationAction){Button(ui("取消")){dismiss()}.disabled(saving).accessibilityIdentifier("chat.followup.editCancel")}}
                .safeAreaInset(edge:.bottom) {
                    Button(saving ? ui("正在保存…") : ui("保存到队列")) {
                        saving=true;error=nil
                        Task {do {try await model.editFollowup(message,text:text);dismiss()} catch {self.error=error.localizedDescription};saving=false}
                    }.touchTarget().buttonStyle(CatpawPressButtonStyle()).disabled(!valid || saving)
                        .accessibilityIdentifier("chat.followup.save").padding().frame(maxWidth:.infinity).background(CatpawColors.background)
                }
        }.interactiveDismissDisabled(saving)
    }
}
@MainActor private struct ConversationHistoryView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

    @ObservedObject var model: ConversationFirstModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(model.history) { record in
                Button { Task { do { try await model.select(record.id); dismiss() } catch { model.error = error.localizedDescription } } } label: { historyRow(record) }
                    .buttonStyle(.plain).disabled(model.busy)
                    .accessibilityIdentifier("chat.history.row." + record.id.uuidString)
                    .accessibilityLabel(historyLabel(record))
            }.accessibilityIdentifier("chat.historyList").navigationTitle(ui("对话历史"))
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button(ui("完成")) { dismiss() } } }

        }
    }
    private func historyLabel(_ record: StoredRecord) -> String {
        let draft = record.conversation?.draftText ?? ""
        return record.title + (draft.isEmpty ? "" : ui("，草稿，") + String(draft.prefix(80)))
    }
    private func historyRow(_ record: StoredRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.title).foregroundStyle(CatpawColors.ink)
            if let draft = record.conversation?.draftText, !draft.isEmpty {
                Text(ui("草稿 · ") + String(draft.prefix(80))).font(CatpawTypography.Role.caption.font).lineLimit(2).foregroundStyle(CatpawColors.secondary)
            }
            Text(record.header.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
        }
    }

}
@MainActor private struct ConversationConnectionView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

    @ObservedObject var model: ConversationFirstModel
    var embedded=false
    @Environment(\.dismiss) private var dismiss
    private var stateName: String {
        if model.connectionLifecycle == .checking {return ui("正在检查连接")}
        if model.connectionLifecycle == .reconnecting {return ui("正在重新连接")}
        switch model.connection.state {
        case .notConfigured: return ui("未连接")
        case .providerUnverified: return ui("服务可达")
        case .unavailable: return ui("暂不可用")
        case .connected: return ui("回复已确认")
        }
    }
    var body:some View {
        if embedded {content} else {NavigationStack{content.toolbar{ToolbarItem(placement:.confirmationAction){Button(ui("完成")){dismiss()}}}}}
    }
    private var content:some View {
            Form {
                Section(ui("关于")) {
                    LabeledContent(ui("版本"), value:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—")
                        .textSelection(.enabled).accessibilityIdentifier("settings.appVersion")
                    LabeledContent(ui("构建号"), value:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—")
                        .textSelection(.enabled).accessibilityIdentifier("settings.appBuild")
                }
                Section(ui("模型连接")) {
                    LabeledContent(ui("状态")) { Text(stateName).foregroundStyle(CatpawColors.ink) }.accessibilityIdentifier("connection.state")

                    if let modelID = model.connection.model { LabeledContent(ui("已验证模型")) { Text(modelID).foregroundStyle(CatpawColors.secondary) } }
                    Text(ui(model.connection.detail)).font(CatpawTypography.Role.caption.font)
                    if let at=model.connection.verifiedReplyAt {LabeledContent(ui("最近确认回复"),value:at.formatted(date:.omitted,time:.shortened))}
                    Button(ui("重新检查连接")) { Task { await model.refreshConnection() } }.accessibilityIdentifier("connection.refresh")
                }
                #if DEBUG || DEVICE_TRIAL
                DeveloperModelRouteSection()
                Section(ui("调试")) { NavigationLink(ui("主动信号模拟")) { ProactiveSignalDebugView() }.accessibilityIdentifier("settings.debug.proactiveSignals") }
                #endif
                Section(ui("数据")) { Text(model.connection.state == .notConfigured ? ui("当前未连接云端；输入保存在此设备。") : ui("此设备保存对话副本；发送的消息会交给已连接的云端服务处理。")); Text(ui("离开 App 后不会发送排队中的消息。任务后台执行的状态需要重新读取确认。")).font(CatpawTypography.Role.caption.font) }
                Section { DisclosureGroup(ui("诊断")) { LabeledContent(ui("服务"),value:model.connection.provider); Text(model.connection.state.rawValue).font(CatpawTypography.Role.caption.font).textSelection(.enabled) } }
                if model.connection.state == .notConfigured { Text(ui("真实模型尚未配置；不会使用演示回复代替模型。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
            }.foregroundStyle(CatpawColors.ink).navigationTitle(ui("设置"))
    }
}

@MainActor private enum P0ScrollTiming {
 static func scroll(_ body:()->Void) {
  #if DEBUG
  P0PerformanceLog.shared.measure("scroll_to_latest",body)
  #else
  body()
  #endif
 }
}

private enum ConversationHostDestination:Hashable {case settings,tasks,results,memory,task(String),artifact(String,ConversationArtifactIdentity)}
@MainActor private struct ConversationTaskList:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel
 var body:some View {List {
  if model.session?.goals.isEmpty != false {Text(ui("当前对话还没有任务"))}
  ForEach((model.session?.goals.values.map{$0} ?? []).sorted{$0.updatedAt>$1.updatedAt}){goal in NavigationLink(value:ConversationHostDestination.task(goal.id)){VStack(alignment:.leading){Text(goal.title);Text(goal.summary).font(CatpawTypography.Role.caption.font)}}}
 }.navigationTitle(ui("任务")).accessibilityIdentifier("navigation.tasks")}
}
@MainActor private struct ConversationTaskDetail:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel;let id:String;let openArtifact:(ConversationArtifactProjection)->Void
 var body:some View {ScrollView {if let goal=model.session?.goals[id]{ConversationGoalCard(goal:goal,busy:model.busy,refresh:model.readOriginal,openPlan:model.taskPlansConfigured && goal.binding != nil ? {model.openTaskPlan(goal)} : nil,openActions:model.taskReviewsConfigured && goal.binding != nil ? {model.openTaskActions(goal)} : nil,openControl:model.taskControlsConfigured && goal.binding != nil ? {model.openTaskControl(goal)} : nil,openArtifact:openArtifact).padding()}}.navigationTitle(ui("任务进展"))}
}
@MainActor private struct ConversationResultList:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel
 var body:some View {List {
  if model.session?.goals.values.flatMap({$0.artifacts}).isEmpty != false {Text(ui("当前对话还没有成果"))}
  ForEach((model.session?.goals.values.map{$0} ?? []).sorted{$0.id<$1.id}){goal in ForEach(goal.artifacts){artifact in NavigationLink(value:ConversationHostDestination.artifact(goal.id,ConversationArtifactIdentity(artifact))){Text(artifact.title+" · v\(artifact.version)")}}}
 }.navigationTitle(ui("成果")).accessibilityIdentifier("navigation.results")}
}
@MainActor private struct ConversationArtifactDetail:View {
    @Environment(\.locale) private var uiLocale
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var editReference:ConversationArtifactEditReference?
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel;let goalID:String;let identity:ConversationArtifactIdentity;let continueArtifact:(ConversationArtifactContinuationMode,ConversationArtifactIdentity)->Void
 var body:some View {reader.catpawSheet(item:$editReference){reference in editor(reference)}}
 @ViewBuilder private var reader:some View {
    if let goal=model.session?.goals[goalID] {
        ConversationArtifactReaderView(goal:goal,selectedArtifact:identity,openEdit:model.artifactEditsConfigured ? {selected in openEdit(selected)} : nil,continueArtifact:model.trustedSubjectID != nil && goal.binding != nil ? continueArtifact : nil)
    } else {Text(ui("成果暂不可读"))}
 }
 private func editor(_ reference:ConversationArtifactEditReference)->some View {
    ConversationArtifactEditView(service:model.artifactEditService,reference:reference,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active},onApplied:{envelope in try await recordApplied(envelope,reference:reference)}).environment(\.dynamicTypeSize,textSize)
 }
 private func recordApplied(_ envelope:ConversationArtifactEditEnvelope,reference:ConversationArtifactEditReference) async throws {
    guard model.loaded,model.scope==reference.scope,model.trustedSubjectID==reference.subjectID,model.session?.conversationID==reference.binding.conversation_id else {throw CatpawError.scopeMismatch}
    try envelope.validate(reference:reference)
    guard envelope.amendment != nil else {throw ConversationArtifactEditError.invalidResponse}
    let value=try envelope.artifact.document()
    let artifact=ConversationArtifactProjection(id:envelope.artifact.artifactID,version:envelope.artifact.version,contentHash:envelope.artifact.contentHash,body:envelope.artifact.body,title:value.title,summary:value.summary,content:value.content)
    try await model.service.recordArtifactRevision(scope:reference.scope,binding:reference.binding,artifact:artifact)
    await model.refresh()
 }
 private func openEdit(_ selected:ConversationArtifactIdentity) {
    guard model.artifactEditsConfigured,let subject=model.trustedSubjectID,let goal=model.session?.goals[goalID],let binding=goal.binding,
          let artifact=(goal.artifacts+goal.artifactHistory).first(where:{ConversationArtifactIdentity($0)==selected}) else {return}
    editReference=ConversationArtifactEditReference(scope:model.scope,binding:binding,subjectID:subject,artifact:artifact)
 }
}

/// Only presentation geometry changes; editor, picker draft and send semantics
/// retain their identity as the first character or an IME composition arrives.
private struct ConversationComposerLayout:Layout {
    let drafting:Bool
    private let gap:CGFloat=8
    private func sizes(_ proposal:ProposedViewSize,_ subviews:Subviews)->(width:CGFloat,text:CGSize,leading:CGSize,send:CGSize) {
        let proposedWidth=proposal.width ?? CatpawLayout.readableWidth
        let width=proposedWidth.isFinite ? max(0,proposedWidth):CatpawLayout.readableWidth
        let leading=subviews[1].sizeThatFits(.unspecified),send=subviews[2].sizeThatFits(.unspecified)
        let textWidth=drafting ? width:max(0,width-leading.width-send.width-gap*2)
        let text=subviews[0].sizeThatFits(.init(width:textWidth,height:nil))
        return (width,text,leading,send)
    }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize {
        guard subviews.count==3 else {return .zero}
        let s=sizes(proposal,subviews)
        return .init(width:s.width,height:drafting ? s.text.height+gap+max(s.leading.height,s.send.height):max(s.text.height,max(s.leading.height,s.send.height)))
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        guard subviews.count==3 else {return}
        let s=sizes(.init(width:bounds.width,height:bounds.height),subviews)
        if drafting {
            subviews[0].place(at:.init(x:bounds.minX,y:bounds.minY),proposal:.init(width:bounds.width,height:s.text.height))
            subviews[1].place(at:.init(x:bounds.minX,y:bounds.maxY),anchor:.bottomLeading,proposal:.init(s.leading))
        } else {
            subviews[1].place(at:.init(x:bounds.minX,y:bounds.maxY),anchor:.bottomLeading,proposal:.init(s.leading))
            subviews[0].place(at:.init(x:bounds.minX+s.leading.width+gap,y:bounds.maxY),anchor:.bottomLeading,proposal:.init(width:s.text.width,height:s.text.height))
        }
        subviews[2].place(at:.init(x:bounds.maxX,y:bounds.maxY),anchor:.bottomTrailing,proposal:.init(s.send))
    }
}

/// The cap is relative to the padded readable column, including on wide devices.
private struct ConversationUserMessageLayout:Layout {
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize {
        guard let text=subviews.first else {return .zero}
        let proposedWidth=proposal.width ?? CatpawLayout.readableWidth
        let width=proposedWidth.isFinite ? max(0,proposedWidth):CatpawLayout.readableWidth
        return .init(width:width,height:text.sizeThatFits(.init(width:width*0.75,height:nil)).height)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        guard let text=subviews.first else {return}
        let size=text.sizeThatFits(.init(width:bounds.width*0.75,height:nil))
        text.place(at:.init(x:bounds.maxX,y:bounds.minY),anchor:.topTrailing,proposal:.init(size))
    }
}

private struct ConversationComposerMeasurements:PreferenceKey {
    static var defaultValue:[String:CGFloat]=[:]
    static func reduce(value:inout [String:CGFloat],nextValue:()->[String:CGFloat]) {value.merge(nextValue(),uniquingKeysWith:{_,next in next})}
}


private extension ToolbarContent {
    /// iOS 26: stop the system from wrapping bar buttons in a shared glass capsule (r8).
    @ToolbarContentBuilder func r8HiddenSharedBackground() -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
        #else
        self
        #endif
    }
}

private extension View {
    /// Short transcripts start right under the nav bar; long/streaming ones still follow the bottom via scrollTo.
    @ViewBuilder func r9TopAlignedTranscript() -> some View {
        if #available(iOS 18.0, *) { self.defaultScrollAnchor(.top, for: .alignment) } else { self }
    }
}

/// Shows a tiny spinner only if sending lasts longer than ~2 s.
private struct DelayedSendingSpinner: View {
    @State private var visible = false
    var body: some View {
        ProgressView().controlSize(.mini).opacity(visible ? 1 : 0)
            .task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation(.easeOut(duration: 0.2)) { visible = true } }
    }
}
