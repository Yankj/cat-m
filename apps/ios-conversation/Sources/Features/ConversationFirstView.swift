import SwiftUI
import UIKit
import CatpawNavigation
import CatpawImageComposer

@MainActor struct ConversationFirstView: View {
    @ObservedObject var model: ConversationFirstModel
    var accountLabel: String? = nil
    var onSignOut: (() -> Void)? = nil
    var isAnonymousAccount = false
    var restrictToFrozenFixture = false
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}
    @State private var scrollTask:Task<Void,Never>?
    @State private var followingLatest=true
    @State private var latestVisible=true
    @State private var sidebarPresented=false
    @State private var path:[ConversationHostDestination]=[]
    @AccessibilityFocusState private var menuFocused:Bool
    @State private var history = false
    @State private var settings = false
    @State private var confirmSignOut = false
    @State private var pendingMessagesPresented=false
    @State private var composerMeasurements:[String:CGFloat]=[:]
    @State private var visibleViewport:CatpawVisibleViewport?
    @State private var composerContextPresented=false
    private enum ComposerContextAction {case modelConsent,imageConsent,acceptedWork,pendingMessages,settings,latest}
    @State private var pendingContextAction:(action:ComposerContextAction,conversation:UUID?,scope:UUID,modelIdentity:ObjectIdentifier)?
    @State private var contextJumpRequested=false
    @ScaledMetric(relativeTo: .footnote) private var followupRowHeight = 64.0
    @ScaledMetric(relativeTo: .body) private var sendSymbolSize = 19.0
    @FocusState private var focused: Bool
    #if DEBUG
    @ObservedObject private var probe=P0ExperienceProbe.shared
    #endif
    private var sidebarSnapshot:SidebarSnapshot {
        .init(contextID:model.scope.workspaceID.uuidString,selectedConversationID:model.conversationID,
              conversations:model.history.map{.init(id:$0.id,title:$0.title,preview:$0.conversation?.draftText)},
              capabilities:.init(canCreateConversation:model.loaded && !model.busy && !model.isInputComposing,canSelectConversation:!model.busy && !model.isInputComposing,tasks:true,results:true,memory:model.loaded && model.memoryConfigured,settings:true))
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
    private var sidebarTheme:SidebarTheme {
        SidebarTheme.catpaw.typography(title:CatpawTypography.Role.title.font,heading:CatpawTypography.Role.heading.font,body:CatpawTypography.Role.body.font,secondary:CatpawTypography.Role.secondary.font,caption:CatpawTypography.Role.caption.font)
    }
    private var chatNavigation: some View {
        SidebarHost(isPresented:$sidebarPresented,isAtRoot:path.isEmpty && !settings && !history && !pendingMessagesPresented && !composerContextPresented && !model.acceptedWorkReviewPresented && model.selectedTaskPlan == nil && model.selectedTaskActions == nil && model.selectedTaskControl == nil && model.pendingModelConsent == nil && model.pendingImageConsent == nil,
                    snapshot:sidebarSnapshot,theme:sidebarTheme,localize:{ui($0)},onWillOpen:{UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)},
                    onDismissed:{menuFocused=true},onSelect:route) {
        NavigationStack(path:$path) {
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if let session = model.session {
                            if displayMessages.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(ui("想一起完成什么？")).font(CatpawTypography.Role.title.font.weight(.semibold)).accessibilityAddTraits(.isHeader)
                                    Text(ui("问一个问题，或说一件想做的事。")).foregroundStyle(CatpawColors.secondary)
                                }.padding(.top, textSize.isAccessibilitySize ? 24 : 64).padding(.bottom, 32).accessibilityIdentifier("chat.empty")
                            }
                            ForEach(displayMessages) { message in messageView(message).id(message.id) }
                            if let latest = session.turns.last, latest.state == .completed {
                                Text(ui("回复完成")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.reply.completed")
                            } else if let latest = session.turns.last, latest.state == .failed {
                                Text(ui("此轮回复未完成")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.reply.failed")
                            }
                            if let turn = session.unresolved, turn.state == .unknown || !model.sending {
                                Label(turn.error ?? ui("原请求状态待确认"), systemImage: "arrow.clockwise").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.unresolved")
                                Text(ui("发送结果尚未确认。先读取原请求，避免重复发送；草稿会保留。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.recoveryHelp")
                                Button(ui("读取原请求进展")) { model.readOriginal() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).disabled(model.busy).accessibilityHint(ui("只查询原请求，不重新发送消息")).accessibilityIdentifier("chat.observe")
                            }
                        } else { ProgressView(ui("打开对话")) }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
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
                    .accessibilityIdentifier("chat.transcript")
                    .onChange(of: model.session?.messages.last?.content) { _, _ in scheduleScroll(proxy) }
                    .onChange(of: displayMessages.count) { _, _ in scheduleScroll(proxy) }
                    .onChange(of:model.conversationID) { _,_ in
                        scrollTask?.cancel();scrollTask=nil;followingLatest=true;latestVisible=true
                        scheduleScroll(proxy)
                    }
                    .onChange(of:contextJumpRequested){_,_ in proxy.scrollTo("latest",anchor:.bottom)}
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        composer(budget:composerBudget(viewport),jumpToLatest:{
                            followingLatest=true;scrollTask?.cancel();scrollTask=nil
                            proxy.scrollTo("latest",anchor:.bottom)
                        })
                    }
            }
            }.background(CatpawViewportObserver{visibleViewport=$0}.accessibilityHidden(true))
                .onPreferenceChange(ConversationComposerMeasurements.self){composerMeasurements=$0}
            .background(CatpawColors.background).navigationTitle("Catpaw").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { if path.isEmpty {SidebarMenuButton(localize:{ui($0)}) {sidebarPresented=true}.accessibilityFocused($menuFocused)} }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.newConversation() } label: { Image(systemName: "square.and.pencil").touchTarget() }.disabled(model.busy).accessibilityLabel(ui("新对话")).accessibilityIdentifier("chat.new").buttonStyle(CatpawPressButtonStyle())
                    Button { path.append(.settings) } label: { Image(systemName: "slider.horizontal.3").touchTarget() }.accessibilityLabel(ui("设置")).accessibilityIdentifier("chat.settings").buttonStyle(CatpawPressButtonStyle())
                }
            }
            .navigationDestination(for:ConversationHostDestination.self){destination in
                switch destination {
                case .settings:settingsSheet
                case .tasks:ConversationTaskList(model:model)
                case .results:ConversationResultList(model:model)
                case .memory:
                    if let service=model.memoryService {
                        ConversationMemoryView(service:service,conversationID:model.conversationID,admissionAllowed:{model.loaded && model.networkAdmissionAllowed && scene == .active})
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
        guard followingLatest,scrollTask == nil else {return}
        scrollTask=Task {try? await Task.sleep(nanoseconds:100_000_000);guard !Task.isCancelled,followingLatest else{return};P0ScrollTiming.scroll {proxy.scrollTo("latest",anchor:.bottom)};scrollTask=nil}
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
        .alert(item:$model.pendingModelConsent) { consent in
            Alert(title:Text(ui(consent.title)),message:Text(ui(consent.body)),primaryButton:.default(Text(ui("允许此对话"))) { model.allowPendingModelConsent(consent) },secondaryButton:.cancel(Text(ui("暂不允许"))) { model.deferModelConsent(consent) })
        }
        .catpawSheet(item:Binding(get:{model.pendingImageConsent},set:{value in if value==nil,model.pendingImageConsent != nil {model.cancelImageConsent()}})) {consent in
            ConversationImageConsentView(consent:consent,preview:model.imageDraft.attachment?.thumbnailData,caption:model.draft,saving:model.checkingImageConsent,allow:{confirmed in model.allowPendingImageConsent(consent,confirmed:confirmed)},cancel:model.cancelImageConsent)
                .presentationDetents([.large]).interactiveDismissDisabled(model.checkingImageConsent)
        }
        .catpawSheet(isPresented:Binding(get:{model.acceptedWorkReviewPresented},set:{if !$0 {model.closeAcceptedWorkReview()}})) {
            ConversationAcceptedWorkReviewView(originalText:model.acceptedWorkReviewOriginalText,capability:model.acceptedWorkCapability,options:$model.acceptedWorkOptions,saving:model.acceptedWorkReviewSaving,error:model.acceptedWorkReviewError,confirm:model.confirmAcceptedWorkReview,close:model.closeAcceptedWorkReview)
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
        .catpawSheet(isPresented:$pendingMessagesPresented) {
            ConversationPendingMessagesView(model:model)
                .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium,.large]).presentationDragIndicator(.visible)
        }
        .catpawSheet(isPresented:$composerContextPresented,onDismiss:completeContextAction) {composerContextSheet}
        .task { await model.start() }
        .onDisappear {scrollTask?.cancel();scrollTask=nil}
         .onChange(of: scene) { _, value in model.sceneChanged(value)
            #if DEBUG
            probe.scene(value)
            #endif
        }
        #if DEBUG
        .onAppear { probe.start();probe.update(model) }
        .onChange(of:model.outgoingMessages) { _, _ in probe.update(model) }
        .onChange(of:model.draft) { _, _ in probe.update(model) }
        .onChange(of:model.session?.turns.last?.lastSequence) { _, _ in probe.update(model) }
        .overlay(alignment:.topTrailing) { if probe.enabled { VStack {
            Text("Synthetic offline fixture").font(.caption2).accessibilityIdentifier("qa.p0Fixture")
            Text("P0 probe").font(.caption2).accessibilityIdentifier("qa.p0Probe").accessibilityValue(probe.json)
            if P0PerformanceLog.shared.enabled {Button("Export metrics"){probe.exportMetrics()}.font(.caption2).accessibilityIdentifier("qa.p0Export")}
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
    private var canSendDraft: Bool { !restrictToFrozenFixture && model.canAcceptDraft && !draftTooLong }
    private func composerBudget(_ viewport:GeometryProxy)->CatpawTextViewport.ComposerBudget {
        let available=visibleViewport?.visibleBounds.height ?? viewport.size.height
        let targetHeight=model.artifactContinuation == nil ? 0:max(52,composerMeasurements["targetAnchor"] ?? 52)
        return CatpawTextViewport.composerBudget(available:available,lineHeight:CatpawTypography.font(.body,size:textSize).lineHeight,textInsets:16,targetHeight:targetHeight,desiredContextHeight:composerMeasurements["context"] ?? 92)
    }
    private func composer(budget:CatpawTextViewport.ComposerBudget,jumpToLatest:@escaping()->Void)->some View {
        let contextNeedsDetails=budget.contextHeight<(composerMeasurements["context"] ?? 92)-0.5
        return VStack(alignment:.leading,spacing:0) {
            // The picker remains mounted here while this viewport changes height.
            // A details picker shares the scoped draft and owns only its read ticket.
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    if !followingLatest && !latestVisible {
                        Button(action:jumpToLatest){Label(ui("回到最新"),systemImage:"arrow.down").font(CatpawTypography.Role.caption.font).frame(minHeight:44)}
                            .buttonStyle(CatpawPressButtonStyle()).accessibilityHint(ui("返回对话底部，继续跟随新回复")).accessibilityIdentifier("chat.jumpToLatest")
                    }
                    composerContext(inDetails:false)
                }.frame(maxWidth:.infinity,alignment:.leading)
                    .background{GeometryReader{geometry in Color.clear.preference(key:ConversationComposerMeasurements.self,value:["context":geometry.size.height])}}
            }.scrollDismissesKeyboard(.never).frame(height:budget.contextHeight).clipped()
                .allowsHitTesting(budget.contextHeight>0 && !composerContextPresented).accessibilityHidden(budget.contextHeight==0 || composerContextPresented)
                .padding(.bottom,budget.contextHeight>0 ? 8:0).accessibilityIdentifier("chat.input.context.viewport")
            if let target=model.artifactContinuation,budget.showsTarget {
                artifactContinuationChip(target).padding(.bottom,8)
                    .background{GeometryReader{geometry in Color.clear.preference(key:ConversationComposerMeasurements.self,value:["targetAnchor":geometry.size.height-8])}}
            }
            HStack(alignment:.bottom,spacing:8) {
                if contextNeedsDetails || model.canReviewAcceptedWork || (model.artifactContinuation != nil && !budget.showsTarget) {
                    Button {
                        guard !model.isInputComposing else {return};composerContextPresented=true
                    } label:{
                        if let target=model.artifactContinuation,!budget.showsTarget {
                            Text("v\(target.artifactReference.version)").font(CatpawTypography.Role.caption.font).fixedSize().touchTarget()
                                .accessibilityLabel(target.artifactTitle+" · v\(target.artifactReference.version)")
                        } else {Image(systemName:"info.circle").font(.system(size:22)).touchTarget()}
                    }.buttonStyle(CatpawPressButtonStyle()).disabled(model.isInputComposing)
                        .accessibilityLabel(model.artifactContinuation.flatMap{!budget.showsTarget ? ($0.mode == .reviseReport ? ui("修改这版") : ui("追问这版"))+" · "+$0.artifactTitle+" · v\($0.artifactReference.version) · "+ui("查看输入详情"):nil} ?? ui("查看输入详情")).accessibilityIdentifier("chat.input.context.open")
                        .accessibilityValue(model.artifactContinuationSendBlock.map{ui($0)} ?? model.error.map{ui($0)} ?? "")
                }
                NativeConversationComposer(model:model,enabled:!restrictToFrozenFixture && !model.switchingArtifactContinuation,maximumVisibleHeight:budget.maximumTextHeight,submit:submitDraft)
                    .background{GeometryReader{geometry in Color.clear.preference(key:ConversationComposerMeasurements.self,value:["text":geometry.size.height])}}
                Button(action:submitDraft) { Image(systemName:model.sending ? "clock.badge.checkmark" : "arrow.up").font(.system(size:min(sendSymbolSize,24),weight:.semibold)).foregroundStyle(canSendDraft ? CatpawColors.onInk : CatpawColors.secondary).frame(width:44,height:44).background(canSendDraft ? CatpawColors.ink : CatpawColors.input,in:Circle()) }
                    .buttonStyle(CatpawPressButtonStyle()).disabled(!canSendDraft)
                    .accessibilityLabel(model.sending ? ui("排队发送") : ui("发送")).accessibilityHint(model.session?.unresolved?.state == .unknown ? ui("先读取原请求进展，当前草稿不会重发") : (model.sending ? ui("保存在后续消息队列，仅在前台发送") : ui("发送当前消息"))).accessibilityIdentifier("chat.send")
            }.padding(.horizontal,16).padding(.vertical,budget.compactPadding ? 0:8)
                .background(CatpawColors.panel,in:RoundedRectangle(cornerRadius:24)).overlay{RoundedRectangle(cornerRadius:24).strokeBorder(CatpawColors.separator)}
        }.padding(.horizontal,16).padding(.vertical,budget.compactPadding ? 0:8).background(CatpawColors.background)
            .accessibilityElement(children:.contain).accessibilityIdentifier("chat.composer")
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
                Button {contextAction(.pendingMessages,inDetails:inDetails)} label: {
                    HStack(spacing:8) {
                        Text(ui("待发送 · {0} 条",arguments:[String(model.followups.pending.count)]))
                        Text(model.followups.paused ? ui("已暂停") : ui("等待当前回复"))
                        Spacer(minLength:4)
                        Image(systemName:"chevron.right").accessibilityHidden(true)
                    }.font(CatpawTypography.Role.caption.font).frame(minHeight:44).contentShape(Rectangle())
                }.foregroundStyle(CatpawColors.secondary).buttonStyle(CatpawPressButtonStyle())
                    .accessibilityHint(ui("查看、编辑或暂停本机待发消息")).accessibilityIdentifier(inDetails ? "chat.input.context.pending" : "chat.pendingSummary")
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
            }
            if [.offline,.notConfigured].contains(model.connectionLifecycle) { Button {contextAction(.settings,inDetails:inDetails)} label: {
                HStack(spacing: 8) {
                    Circle().fill(model.connection.state == .connected ? CatpawColors.success : CatpawColors.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(connectionSummary).font(CatpawTypography.Role.caption.font)
                    Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                }.frame(minHeight:44).contentShape(Rectangle())
            }.buttonStyle(CatpawPressButtonStyle()).foregroundStyle(CatpawColors.secondary).accessibilityLabel(ui("模型连接设置")).accessibilityValue(connectionSummary).accessibilityIdentifier("chat.connection") }
        }.frame(maxWidth:.infinity,alignment:.leading)
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
        return messages
    }
    private func submitDraft() {
        if canSendDraft {followingLatest=true}
        let time=ProcessInfo.processInfo.systemUptime,old=Set(model.outgoingMessages.map(\.id))
        model.prepareSend()
        #if DEBUG
        if let intent=model.outgoingMessages.last,!old.contains(intent.id) { probe.pressed(intent.id,at:time);probe.update(model) }
        #endif
    }
    private func operationID(_ message:ConversationTranscriptMessage) -> UUID? {
        model.outgoingMessages.first(where:{stableID("conversation-user-\($0.id)") == message.id})?.id ?? model.session?.turns.first(where:{stableID("conversation-user-\($0.id)") == message.id})?.id
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
    @ViewBuilder private func messageView(_ message: ConversationTranscriptMessage) -> some View {
        if message.role == .user {
            VStack(alignment:.trailing,spacing:4) {
                HStack { Spacer(minLength:40);Text(message.content).textSelection(.enabled).padding(14).background(CatpawColors.input,in:RoundedRectangle(cornerRadius:20)) }
                    .accessibilityIdentifier("chat.userMessage")
                    #if DEBUG
                    .background { if let id=operationID(message),probe.enabled { P0EchoWitness(operationID:id) } }
                    #endif
                if message.image != nil {Label(ui("附带图片"),systemImage:"photo").font(CatpawTypography.Role.caption.font).accessibilityIdentifier("chat.message.image")}
                if let id=operationID(message) { Text(delivery(id)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.pendingAdmission") }
            }
        } else if message.role == .tool || message.toolName != nil {
            if message.toolName == "present_cgui_v1",let session=model.session {
                if message.role == .tool || !message.complete {
                    ConversationGenerativeUIMessageView(message:message,session:session,stateService:model.generativeUIStateService) {
                        followingLatest=false;scrollTask?.cancel();scrollTask=nil
                    }
                }
            }
            else if let goal = linkedGoal(message) { ConversationGoalCard(goal: goal, busy: model.busy, refresh: model.readOriginal, openPlan: model.taskPlansConfigured && goal.binding != nil ? { model.openTaskPlan(goal) } : nil,openActions:model.taskReviewsConfigured && goal.binding != nil ? {model.openTaskActions(goal)} : nil,openControl:model.taskControlsConfigured && goal.binding != nil ? {model.openTaskControl(goal)} : nil,openArtifact:{artifact in path.append(.artifact(goal.id,ConversationArtifactIdentity(artifact)))}) }
            else if message.failure != nil { Label(ui("任务请求失败 · ") + (message.failure ?? ""), systemImage: "exclamationmark.circle").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention) }
            else { Label(message.toolName == "agent_status" ? (message.complete ? ui("任务进展已读取") : ui("读取任务进展…")) : (message.complete ? ui("任务请求已记录") : ui("等待后台保存任务…")), systemImage: message.complete ? "checkmark.circle" : "circle.dotted").font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }

        } else {
            ConversationAnswerView(message:message,canQuote:!model.isInputComposing) { text in
                // Preserve the active IME transaction. Quoting is an explicit draft edit.
                guard !model.isInputComposing else {return}
                let excerpt=String(text.prefix(2000))
                let quotation=excerpt.split(separator:"\n",omittingEmptySubsequences:false).map {"> " + $0}.joined(separator:"\n")
                model.editDraft(model.draft.isEmpty ? quotation + "\n\n" : model.draft + "\n\n" + quotation + "\n\n")
            }
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
    var body:some View {
        NavigationStack {
            List {
                Section {
                    Text(ui("待发消息保存在本机，仅在 App 前台发送。编辑会暂停队列，保存或关闭不会继续发送。"))
                        .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    if let error {Text(ui(error)).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.followup.error")}
                    if model.followups.pending.isEmpty {Text(ui("没有待发消息")).accessibilityIdentifier("chat.followup.empty")}
                    ForEach(model.followups.pending) {message in
                        VStack(alignment:.leading,spacing:8) {
                            Text(message.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                            if message.image != nil {Text(ui("图片处理许可绑定当前文字。请移除后在输入器重新编辑。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)}
                            HStack {
                                Button {
                                    preparingEdit=true;error=nil
                                    Task {do {try await model.pauseQueueForEditing(message);editing=message} catch {self.error=error.localizedDescription};preparingEdit=false}
                                } label: {Label(ui("编辑并暂停队列"),systemImage:"pencil").frame(minHeight:44)}
                                    .disabled(preparingEdit || model.editingFollowup || message.image != nil)
                                    .accessibilityIdentifier("chat.followup.edit."+message.id.uuidString)
                                Spacer(minLength:8)
                                Button {model.removeFollowup(message.id)} label: {Image(systemName:"xmark").frame(width:44,height:44)}
                                    .disabled(preparingEdit || model.editingFollowup)
                                    .accessibilityLabel(ui("移除后续消息")).accessibilityIdentifier("chat.followup.remove."+message.id.uuidString)
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }.navigationTitle(ui("待发消息")).navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction){Button(ui("完成")){dismiss()}.accessibilityIdentifier("chat.followup.close")}}
                .safeAreaInset(edge:.bottom) {
                    if !model.followups.pending.isEmpty {
                        Group {
                            if model.followups.paused {
                                Button(ui("继续发送后续消息")){model.resumeFollowups()}.accessibilityIdentifier("chat.followup.resume")
                                    .disabled(model.busy || model.editingFollowup || preparingEdit || model.session?.unresolved != nil || ![.connected,.providerUnverified].contains(model.connection.state))
                            } else {Button(ui("暂停后续消息")){model.pauseFollowups()}.accessibilityIdentifier("chat.followup.pause").disabled(preparingEdit)}
                        }.touchTarget().buttonStyle(CatpawPressButtonStyle()).padding().frame(maxWidth:.infinity).background(CatpawColors.background)
                    }
                }
        }.catpawSheet(item:$editing) {message in ConversationPendingMessageEditor(model:model,message:message)}
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
                Section(ui("模型连接")) {
                    LabeledContent(ui("状态")) { Text(stateName).foregroundStyle(CatpawColors.ink) }.accessibilityIdentifier("connection.state")

                    if let modelID = model.connection.model { LabeledContent(ui("已验证模型")) { Text(modelID).foregroundStyle(CatpawColors.secondary) } }
                    Text(ui(model.connection.detail)).font(CatpawTypography.Role.caption.font)
                    if let at=model.connection.verifiedReplyAt {LabeledContent(ui("最近确认回复"),value:at.formatted(date:.omitted,time:.shortened))}
                    Button(ui("重新检查连接")) { Task { await model.refreshConnection() } }.accessibilityIdentifier("connection.refresh")
                }
                Section(ui("数据")) { Text(model.connection.state == .notConfigured ? ui("当前未连接云端；输入保存在此设备。") : ui("此设备保存对话副本；发送的消息会交给已连接的云端服务处理。")); Text(ui("离开 App 后不会发送排队中的消息。任务后台执行的状态需要重新读取确认。")).font(CatpawTypography.Role.caption.font) }
                Section { DisclosureGroup(ui("诊断")) { LabeledContent(ui("服务"),value:model.connection.provider); Text(ui("版本 {0} ({1})", arguments:[String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"),String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")])); Text(model.connection.state.rawValue).font(CatpawTypography.Role.caption.font).textSelection(.enabled) } }
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

@MainActor private struct ConversationImageConsentView:View {
    let consent:ConversationImageConsent
    let preview:Data?
    let caption:String
    let saving:Bool
    let allow:(Bool)->Void
    let cancel:()->Void
    @State private var confirmed=false
    @Environment(\.locale) private var locale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:locale).ui(key,arguments:arguments)}
    var body:some View {
        NavigationStack {
            ScrollView {VStack(alignment:.leading,spacing:20) {
                if let preview,let image=UIImage(data:preview) {Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:192).accessibilityLabel(ui("待确认的图片预览")).accessibilityIdentifier("image.consent.preview")}
                Text(caption).textSelection(.enabled)
                Text(ui(consent.body)).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("image.consent.notice")
                Toggle(ui(consent.confirmation),isOn:$confirmed).accessibilityIdentifier("image.consent.nonSensitive")
                Text(ui("确认后返回输入区，点击发送才会传输图片。")).font(CatpawTypography.Role.caption.font)
            }.padding()}
            .navigationTitle(ui(consent.title)).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge:.bottom) {VStack(spacing:12) {
                Button(ui(consent.allowLabel)){allow(confirmed)}.buttonStyle(.borderedProminent).disabled(!confirmed || saving).accessibilityIdentifier("image.consent.allow")
                Button(ui(consent.denyLabel),action:cancel).disabled(saving).accessibilityIdentifier("image.consent.cancel")
                if saving {ProgressView().accessibilityLabel(ui("正在保存确认…"))}
            }.padding().frame(maxWidth:.infinity).background(CatpawColors.background)}
        }.tint(CatpawColors.ink).foregroundStyle(CatpawColors.ink)
    }
}

private struct ConversationComposerMeasurements:PreferenceKey {
    static var defaultValue:[String:CGFloat]=[:]
    static func reduce(value:inout [String:CGFloat],nextValue:()->[String:CGFloat]) {value.merge(nextValue(),uniquingKeysWith:{_,next in next})}
}
