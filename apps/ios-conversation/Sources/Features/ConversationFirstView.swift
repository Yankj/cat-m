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
    @State private var sidebarPresented=false
    @State private var path:[ConversationHostDestination]=[]
    @AccessibilityFocusState private var menuFocused:Bool
    @State private var history = false
    @State private var settings = false
    @State private var confirmSignOut = false
    @State private var pendingMessagesExpanded=false
    @ScaledMetric(relativeTo: .footnote) private var followupRowHeight = 64.0
    @ScaledMetric(relativeTo: .body) private var sendSymbolSize = 19.0
    @FocusState private var focused: Bool
    #if DEBUG
    @ObservedObject private var probe=P0ExperienceProbe.shared
    #endif
    private var sidebarSnapshot:SidebarSnapshot {
        .init(contextID:model.scope.workspaceID.uuidString,selectedConversationID:model.conversationID,
              conversations:model.history.map{.init(id:$0.id,title:$0.title,preview:$0.conversation?.draftText)},
              capabilities:.init(canCreateConversation:model.loaded && !model.busy && !model.isInputComposing,canSelectConversation:!model.busy && !model.isInputComposing,tasks:true,results:true,memory:false,settings:true))
    }
    private func route(_ destination:SidebarDestination) {
        switch destination {
        case .newConversation:path=[];model.newConversation()
        case .conversation(let id):Task {do {try await model.select(id);path=[]}catch{model.error=error.localizedDescription}}
        case .tasks:path.append(.tasks)
        case .results:path.append(.results)
        case .settings:path.append(.settings)
        case .memory:break
        }
    }
    private var chatNavigation: some View {
        SidebarHost(isPresented:$sidebarPresented,isAtRoot:path.isEmpty && !settings && !history && model.pendingModelConsent == nil && model.pendingImageConsent == nil,
                    snapshot:sidebarSnapshot,localize:{ui($0)},onWillOpen:{UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)},
                    onDismissed:{menuFocused=true},onSelect:route) {
        NavigationStack(path:$path) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if let session = model.session {
                            if displayMessages.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(ui("想一起完成什么？")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                                    Text(ui("问一个问题，或说一件想做的事。")).foregroundStyle(CatpawColors.secondary)
                                }.padding(.top, textSize.isAccessibilitySize ? 24 : 64).padding(.bottom, 32).accessibilityIdentifier("chat.empty")
                            }
                            ForEach(displayMessages) { message in messageView(message).id(message.id) }
                            if let latest = session.turns.last, latest.state == .completed {
                                Text(ui("回复完成")).font(.footnote).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.reply.completed")
                            } else if let latest = session.turns.last, latest.state == .failed {
                                Text(ui("此轮回复未完成")).font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.reply.failed")
                            }
                            if let turn = session.unresolved, turn.state == .unknown || !model.sending {
                                Label(turn.error ?? ui("原请求状态待确认"), systemImage: "arrow.clockwise").font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.unresolved")
                                Text(ui("发送结果尚未确认。先读取原请求，避免重复发送；草稿会保留。")).font(.footnote).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.recoveryHelp")
                                Button(ui("读取原请求进展")) { model.readOriginal() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).disabled(model.busy).accessibilityHint(ui("只查询原请求，不重新发送消息")).accessibilityIdentifier("chat.observe")
                            }
                        } else { ProgressView(ui("打开对话")) }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.session?.messages.last?.content) { _, _ in scheduleScroll(proxy) }
                    .onChange(of: displayMessages.count) { _, _ in scheduleScroll(proxy) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
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
                case .task(let id):ConversationTaskDetail(model:model,id:id)
                case .artifact(let goal,let id):ConversationArtifactDetail(model:model,goalID:goal,artifactID:id)
                }
            }
        }
        }
    }
    private func scheduleScroll(_ proxy:ScrollViewProxy) {
        guard scrollTask == nil else {return}
        scrollTask=Task {try? await Task.sleep(nanoseconds:100_000_000);guard !Task.isCancelled else{return};P0ScrollTiming.scroll {proxy.scrollTo("latest",anchor:.bottom)};scrollTask=nil}
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
        .sheet(item:Binding(get:{model.pendingImageConsent},set:{value in if value==nil,model.pendingImageConsent != nil {model.cancelImageConsent()}})) {consent in
            ConversationImageConsentView(consent:consent,preview:model.imageDraft.attachment?.thumbnailData,caption:model.draft,saving:model.checkingImageConsent,allow:{confirmed in model.allowPendingImageConsent(consent,confirmed:confirmed)},cancel:model.cancelImageConsent)
                .presentationDetents([.large]).interactiveDismissDisabled(model.checkingImageConsent)
        }
        .sheet(isPresented: $history) { ConversationHistoryView(model: model).presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $settings) { settingsSheet }
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
            .safeAreaInset(edge:.bottom) { if onSignOut != nil { VStack(spacing:12) { if let accountLabel { Text(accountLabel).font(.footnote).foregroundStyle(CatpawColors.secondary) }; Button(ui("退出此账号"), role:.destructive) { confirmSignOut = true }.touchTarget().accessibilityIdentifier("auth.signOut") }.padding().frame(maxWidth:.infinity).background(CatpawColors.background) } }
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
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ImageAttachmentPicker(draft:model.imageDraft,gate:model.imageGate,localize:{ui($0)}).id(model.scope.workspaceID.uuidString+(model.conversationID?.uuidString ?? ""))
            if let block=model.imageSendBlock,block != .unavailable {Text(ui(block.message)).font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("attachment.sendBlock")}
            if model.imageDraft.phase == .ready,model.imageCapability.available,!model.imageGate.imageConsentMatchesCurrentRoute {
                Button(ui("确认图片处理方式")){model.requestImageConsent()}.disabled(!model.canReviewImage).accessibilityIdentifier("image.consent.review")
            }
            if model.checkingImageConsent {Text(ui("正在读取图片处理方式…")).font(.footnote).accessibilityIdentifier("image.consent.loading")}
            #if DEBUG
            if restrictToFrozenFixture { Text(ui("合成测试协议证据")).font(.caption2).accessibilityIdentifier("fixture.evidence").accessibilityValue(fixtureEvidence) }
            #endif
            if model.needsModelConsentReview {
                HStack(alignment:.center) {
                    Text(ui("消息尚未发送，需要确认处理方式。")).font(.footnote).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:8)
                    Button(ui("确认发送许可")){model.requestModelConsentReview()}.touchTarget().disabled(!model.canReviewModelConsent).accessibilityIdentifier("chat.consent.review")
                }.padding(10).background(CatpawColors.input,in:RoundedRectangle(cornerRadius:12))
            }
            if !model.followups.pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup(isExpanded:$pendingMessagesExpanded) {
                        ScrollView {VStack(alignment:.leading,spacing:8) {
                            ForEach(model.followups.pending) {message in
                                HStack {Text(message.text).font(.footnote).lineLimit(2);Spacer();Button {model.removeFollowup(message.id)} label:{Image(systemName:"xmark").frame(width:44,height:44)}.accessibilityLabel(ui("移除后续消息")).accessibilityIdentifier("chat.followup.remove."+message.id.uuidString)}
                            }
                        }}.frame(maxHeight:128)
                    } label: {Text(ui("待发送 · {0} 条",arguments:[String(model.followups.pending.count)])).font(.caption)}
                    .accessibilityIdentifier("chat.pendingSummary")
                    if model.followups.paused { Button(ui("继续发送后续消息")) { model.resumeFollowups() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).accessibilityIdentifier("chat.followup.resume").disabled(model.busy || model.session?.unresolved != nil || ![.connected, .providerUnverified].contains(model.connection.state)) }
                    else if !model.followups.pending.isEmpty { Button(ui("暂停后续消息")) { model.pauseFollowups() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).accessibilityIdentifier("chat.followup.pause") }
                }.padding(12).background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            if model.checkingModelConsent { Text(ui("正在准备发送…")).font(.footnote).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.preparing") }
            if let error = model.error { Text(ui(error)).font(.footnote).foregroundStyle(CatpawColors.attention).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.error") }
            if draftTooLong {
                Text(ui("消息过长。请缩短后再发送（长度上限 8000）。"))
                    .font(.footnote).foregroundStyle(CatpawColors.attention)
                    .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.validation")
            }
            HStack(alignment: .bottom, spacing: 8) {
                NativeConversationComposer(model:model,enabled:!restrictToFrozenFixture,submit:submitDraft)
                Button(action:submitDraft) { Image(systemName: model.sending ? "clock.badge.checkmark" : "arrow.up").font(.system(size:min(sendSymbolSize,24),weight:.semibold)).foregroundStyle(canSendDraft ? CatpawColors.onInk : CatpawColors.secondary).frame(width: 44, height: 44).background(canSendDraft ? CatpawColors.ink : CatpawColors.input, in: Circle()) }
                    .buttonStyle(CatpawPressButtonStyle()).disabled(!canSendDraft)
                    .accessibilityLabel(model.sending ? ui("排队发送") : ui("发送")).accessibilityHint(model.session?.unresolved?.state == .unknown ? ui("先读取原请求进展，当前草稿不会重发") : (model.sending ? ui("保存在后续消息队列，仅在前台发送") : ui("发送当前消息"))).accessibilityIdentifier("chat.send")
            }.padding(.horizontal, 16).padding(.vertical, 8).background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 24)).overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(CatpawColors.separator) }
            if [.offline,.notConfigured].contains(model.connectionLifecycle) { Button { path.append(.settings) } label: {
                HStack(spacing: 8) {
                    Circle().fill(model.connection.state == .connected ? CatpawColors.success : CatpawColors.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(connectionSummary).font(.caption)
                    Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                }.frame(minHeight:44).contentShape(Rectangle())
            }.buttonStyle(CatpawPressButtonStyle()).foregroundStyle(CatpawColors.secondary).accessibilityLabel(ui("模型连接设置")).accessibilityValue(connectionSummary).accessibilityIdentifier("chat.connection") }
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8).background(CatpawColors.background)
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
        for intent in model.outgoingMessages {
            let id=stableID("conversation-user-\(intent.id)")
            if !messages.contains(where:{$0.id == id}) { messages.append(.init(id:id,role:.user,content:intent.text,image:intent.image)) }
        }
        return messages
    }
    private func submitDraft() {
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
        guard message.role == .tool, message.toolName == "delegate_task", let session = model.session,
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
                if message.image != nil {Label(ui("附带图片"),systemImage:"photo").font(.caption).accessibilityIdentifier("chat.message.image")}
                if let id=operationID(message) { Text(delivery(id)).font(.caption).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.pendingAdmission") }
            }
        } else if message.role == .tool || message.toolName != nil {
            if let goal = linkedGoal(message) { ConversationGoalCard(goal: goal, busy: model.busy, refresh: model.readOriginal) }
            else if message.failure != nil { Label(ui("任务请求失败 · ") + (message.failure ?? ""), systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(CatpawColors.attention) }
            else { Label(message.toolName == "agent_status" ? (message.complete ? ui("任务进展已读取") : ui("读取任务进展…")) : (message.complete ? ui("任务请求已记录") : ui("等待后台保存任务…")), systemImage: message.complete ? "checkmark.circle" : "circle.dotted").font(.footnote).foregroundStyle(CatpawColors.secondary) }

        } else { StreamingConversationText(text:message.content,complete:message.complete) }
    }
}
private struct ConversationGoalCard: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

    let goal: ConversationGoalProjection
    let busy: Bool
    let refresh: () -> Void
    @State private var expanded = false
    private var status: String { switch goal.state { case .queued: ui("已排队"); case .working: ui("正在进行"); case .waitingInput: ui("等待反馈"); case .completed: ui("已完成"); case .failed: ui("需要处理"); case .paused: ui("已暂停"); case .cancelled: ui("已结束"); case .unknown: ui("状态待确认") } }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(goal.summary).textSelection(.enabled)
                ForEach(goal.artifacts) { artifact in DisclosureGroup(artifact.title + " · v\(artifact.version)") { Text(artifact.summary).font(.subheadline); Text(artifact.content).textSelection(.enabled); Text("SHA-256 " + artifact.contentHash).font(.caption2).textSelection(.enabled).accessibilityIdentifier("chat.artifact.hash." + artifact.id) }.accessibilityIdentifier("chat.artifact." + artifact.id) }
                Button(ui("读取最新进展"), action: refresh).touchTarget().disabled(busy)
                Text(ui("最近读取 · ") + goal.updatedAt.formatted()).font(.caption).foregroundStyle(CatpawColors.secondary)
            }.padding(.top, 10)
        } label: { HStack { Image(systemName: "circle.dotted"); Text(goal.title).font(.subheadline.weight(.medium)).fixedSize(horizontal:false,vertical:true); Spacer(); Text(status).font(.caption).foregroundStyle(CatpawColors.secondary) } }
            .padding(14).background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("chat.goal.\(goal.id)")
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
                Text(ui("草稿 · ") + String(draft.prefix(80))).font(.caption).lineLimit(2).foregroundStyle(CatpawColors.secondary)
            }
            Text(record.header.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(CatpawColors.secondary)
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
        switch model.connection.state { case .notConfigured: ui("未连接"); case .providerUnverified: ui("服务可达"); case .unavailable: ui("暂不可用"); case .connected: ui("回复已确认") }
    }
    var body:some View {
        if embedded {content} else {NavigationStack{content.toolbar{ToolbarItem(placement:.confirmationAction){Button(ui("完成")){dismiss()}}}}}
    }
    private var content:some View {
            Form {
                Section(ui("模型连接")) {
                    LabeledContent(ui("状态")) { Text(stateName).foregroundStyle(CatpawColors.ink) }.accessibilityIdentifier("connection.state")

                    if let modelID = model.connection.model { LabeledContent(ui("已验证模型")) { Text(modelID).foregroundStyle(CatpawColors.secondary) } }
                    Text(ui(model.connection.detail)).font(.footnote)
                    if let at=model.connection.verifiedReplyAt {LabeledContent(ui("最近确认回复"),value:at.formatted(date:.omitted,time:.shortened))}
                    Button(ui("重新检查连接")) { Task { await model.refreshConnection() } }.accessibilityIdentifier("connection.refresh")
                }
                Section(ui("数据")) { Text(model.connection.state == .notConfigured ? ui("当前未连接云端；输入保存在此设备。") : ui("此设备保存对话副本；发送的消息会交给已连接的云端服务处理。")); Text(ui("离开 App 后不会发送排队中的消息。任务后台执行的状态需要重新读取确认。")).font(.footnote) }
                Section { DisclosureGroup(ui("诊断")) { LabeledContent(ui("服务"),value:model.connection.provider); Text(ui("版本 {0} ({1})", arguments:[String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"),String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")])); Text(model.connection.state.rawValue).font(.caption).textSelection(.enabled) } }
                if model.connection.state == .notConfigured { Text(ui("真实模型尚未配置；不会使用演示回复代替模型。")).font(.footnote).foregroundStyle(CatpawColors.secondary) }
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

private enum ConversationHostDestination:Hashable {case settings,tasks,results,task(String),artifact(String,String)}
@MainActor private struct ConversationTaskList:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel
 var body:some View {List {
  if model.session?.goals.isEmpty != false {Text(ui("当前对话还没有任务"))}
  ForEach((model.session?.goals.values.map{$0} ?? []).sorted{$0.updatedAt>$1.updatedAt}){goal in NavigationLink(value:ConversationHostDestination.task(goal.id)){VStack(alignment:.leading){Text(goal.title);Text(goal.summary).font(.footnote)}}}
 }.navigationTitle(ui("任务")).accessibilityIdentifier("navigation.tasks")}
}
@MainActor private struct ConversationTaskDetail:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel;let id:String
 var body:some View {ScrollView {if let goal=model.session?.goals[id]{ConversationGoalCard(goal:goal,busy:model.busy,refresh:model.readOriginal).padding()}}.navigationTitle(ui("任务进展"))}
}
@MainActor private struct ConversationResultList:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel
 var body:some View {List {
  if model.session?.goals.values.flatMap({$0.artifacts}).isEmpty != false {Text(ui("当前对话还没有成果"))}
  ForEach((model.session?.goals.values.map{$0} ?? []).sorted{$0.id<$1.id}){goal in ForEach(goal.artifacts){artifact in NavigationLink(value:ConversationHostDestination.artifact(goal.id,artifact.id)){Text(artifact.title+" · v\(artifact.version)")}}}
 }.navigationTitle(ui("成果")).accessibilityIdentifier("navigation.results")}
}
@MainActor private struct ConversationArtifactDetail:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:uiLocale).ui(key,arguments:arguments)}

 @ObservedObject var model:ConversationFirstModel;let goalID:String;let artifactID:String
 var body:some View {ScrollView {if let artifact=model.session?.goals[goalID]?.artifacts.first(where:{$0.id==artifactID}) {VStack(alignment:.leading,spacing:16){Text(artifact.title).font(.title2);Text("v\(artifact.version)").font(.caption);StreamingConversationText(text:artifact.content,complete:true);Text(artifact.contentHash).font(.caption2)}}}.padding().navigationTitle(ui("成果"))}
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
                Text(ui("确认后返回输入区，点击发送才会传输图片。")).font(.footnote)
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
