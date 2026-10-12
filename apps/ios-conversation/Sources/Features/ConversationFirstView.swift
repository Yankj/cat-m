import SwiftUI
import UIKit

@MainActor struct ConversationFirstView: View {
    @ObservedObject var model: ConversationFirstModel
    var accountLabel: String? = nil
    var onSignOut: (() -> Void)? = nil
    var isAnonymousAccount = false
    var restrictToFrozenFixture = false
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var history = false
    @State private var settings = false
    @State private var confirmSignOut = false
    @ScaledMetric(relativeTo: .footnote) private var followupRowHeight = 64.0
    @ScaledMetric(relativeTo: .body) private var sendSymbolSize = 19.0
    @FocusState private var focused: Bool
    #if DEBUG
    @ObservedObject private var probe=P0ExperienceProbe.shared
    #endif
    private var chatNavigation: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if let session = model.session {
                            if displayMessages.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("想一起完成什么？").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                                    Text("问一个问题，或说一件想做的事。").foregroundStyle(CatpawColors.secondary)
                                }.padding(.top, textSize.isAccessibilitySize ? 24 : 64).padding(.bottom, 32).accessibilityIdentifier("chat.empty")
                            }
                            ForEach(displayMessages) { message in messageView(message).id(message.id) }
                            if let latest = session.turns.last, latest.state == .completed {
                                Text("回复完成").font(.footnote).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.reply.completed")
                            } else if let latest = session.turns.last, latest.state == .failed {
                                Text("此轮回复未完成").font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.reply.failed")
                            }
                            if let turn = session.unresolved, turn.state == .unknown || !model.sending {
                                Label(turn.error ?? "原请求状态待确认", systemImage: "arrow.clockwise").font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.unresolved")
                                Text("发送结果尚未确认。先读取原请求，避免重复发送；草稿会保留。").font(.footnote).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.recoveryHelp")
                                Button("读取原请求进展") { model.readOriginal() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).disabled(model.busy).accessibilityHint("只查询原请求，不重新发送消息").accessibilityIdentifier("chat.observe")
                            }
                        } else { ProgressView("打开对话") }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.session?.messages.last?.content) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                    .onChange(of: displayMessages.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .background(CatpawColors.background).navigationTitle("Catpaw").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { history = true } label: { Image(systemName: "clock.arrow.circlepath").touchTarget() }.accessibilityLabel("对话历史").accessibilityIdentifier("chat.history").buttonStyle(CatpawPressButtonStyle()) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.newConversation() } label: { Image(systemName: "square.and.pencil").touchTarget() }.disabled(model.busy).accessibilityLabel("新对话").accessibilityIdentifier("chat.new").buttonStyle(CatpawPressButtonStyle())
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3").touchTarget() }.accessibilityLabel("设置").accessibilityIdentifier("chat.settings").buttonStyle(CatpawPressButtonStyle())
                }
            }
        }
    }
    private var feedbackNavigation: some View {
        chatNavigation.tint(CatpawColors.ink).foregroundStyle(CatpawColors.ink)
            .sensoryFeedback(.selection, trigger: history, condition: { _, opened in opened })
            .sensoryFeedback(.selection, trigger: settings, condition: { _, opened in opened })
            .sensoryFeedback(.impact(weight:.light), trigger:model.enqueueing, condition: { _, accepted in accepted })
            .sensoryFeedback(.success, trigger: model.session?.turns.last?.state == .completed, condition: { _, completed in completed && model.sending })
            .sensoryFeedback(.warning, trigger: model.error != nil, condition: { _, present in present })
    }
    var body: some View {
        feedbackNavigation
        .alert(item:$model.pendingModelConsent) { consent in
            Alert(title:Text(consent.title),message:Text(consent.body),primaryButton:.default(Text("允许此对话")) { model.allowPendingModelConsent(consent) },secondaryButton:.cancel(Text("暂不允许")) { model.deferModelConsent() })
        }
        .sheet(isPresented: $history) { ConversationHistoryView(model: model).presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $settings) { settingsSheet }
        .task { await model.start() }
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
            if P0ExperienceFixture.scenario == "p0-ui-ime" { HStack {
                Button("Marked") { ConversationTextView.fixtureEditor?.becomeFirstResponder();ConversationTextView.fixtureEditor?.setMarkedText("nihao",selectedRange:NSRange(location:5,length:0));probe.update(model) }.accessibilityIdentifier("qa.p0IME.mark")
                Button("CmdReturn") { ConversationTextView.fixtureEditor?.commandSubmit();probe.update(model) }.accessibilityIdentifier("qa.p0IME.command")
                Button("Commit") { ConversationTextView.fixtureEditor?.unmarkText();probe.update(model) }.accessibilityIdentifier("qa.p0IME.commit")
            } }
        }.padding(4).background(CatpawColors.panel) } }
        #endif
        .overlay { if scene != .active || !UIApplication.shared.isProtectedDataAvailable { ZStack { CatpawColors.background.ignoresSafeArea(); Label("解锁后查看对话", systemImage: "lock.fill") }.accessibilityIdentifier("chat.privacyShield") } }
    }
    private var settingsSheet: some View {
        ConversationConnectionView(model: model)
            .safeAreaInset(edge:.bottom) { if onSignOut != nil { VStack(spacing:12) { if let accountLabel { Text(accountLabel).font(.footnote).foregroundStyle(CatpawColors.secondary) }; Button("退出此账号", role:.destructive) { confirmSignOut = true }.touchTarget().accessibilityIdentifier("auth.signOut") }.padding().frame(maxWidth:.infinity).background(CatpawColors.background) } }
            .confirmationDialog("退出此账号？", isPresented:$confirmSignOut, titleVisibility:.visible) {
                Button("确认退出", role:.destructive) { settings = false; onSignOut?() }
                Button("取消", role:.cancel) { }
            } message: { Text(isAnonymousAccount ? "体验身份暂时无法找回。退出后，你将无法继续访问这些对话。" : "退出后需重新登录才能继续访问此账号的对话。") }
            .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large]).presentationDragIndicator(.visible)
    }
    private var connectionSummary: String {
        switch model.connection.state {
        case .connected: model.connection.model ?? "已连接"
        case .providerUnverified: "连接待验证"
        case .unavailable: "连接暂不可用"
        case .notConfigured: "模型未连接"
        }
    }
    private var draftTooLong: Bool { model.draft.utf16.count > 8000 }
    private var canSendDraft: Bool { !restrictToFrozenFixture && model.canAcceptDraft && !draftTooLong }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if DEBUG
            if restrictToFrozenFixture { Text("合成测试协议证据").font(.caption2).accessibilityIdentifier("fixture.evidence").accessibilityValue(fixtureEvidence) }
            #endif
            if model.followups.pending.count > 1 || (model.followups.paused && !model.followups.pending.isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.followups.paused ? "后续消息已暂停" : "后续消息 · 仅在前台发送").font(.caption).foregroundStyle(CatpawColors.secondary)
                    if !model.followups.pending.isEmpty { ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                    ForEach(model.followups.pending) { message in
                        HStack { Text(message.text).font(.footnote).lineLimit(2); Spacer(); Button { model.removeFollowup(message.id) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("移除后续消息").accessibilityIdentifier("chat.followup.remove." + message.id.uuidString) }
                    }
                    }
                    }.frame(height:min(CGFloat(model.followups.pending.count) * followupRowHeight,160)).scrollBounceBehavior(.basedOnSize) }
                    if model.followups.paused { Button("继续发送后续消息") { model.resumeFollowups() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).accessibilityIdentifier("chat.followup.resume").disabled(model.busy || model.session?.unresolved != nil || ![.connected, .providerUnverified].contains(model.connection.state)) }
                    else if !model.followups.pending.isEmpty { Button("暂停后续消息") { model.pauseFollowups() }.touchTarget().buttonStyle(CatpawPressButtonStyle()).accessibilityIdentifier("chat.followup.pause") }
                }.padding(12).background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            if model.checkingModelConsent { Text("正在准备发送…").font(.footnote).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.preparing") }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(CatpawColors.attention).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.error") }
            if draftTooLong {
                Text("消息过长。请缩短后再发送（长度上限 8000）。")
                    .font(.footnote).foregroundStyle(CatpawColors.attention)
                    .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.validation")
            }
            HStack(alignment: .bottom, spacing: 8) {
                NativeConversationComposer(model:model,enabled:!restrictToFrozenFixture,submit:submitDraft)
                Button(action:submitDraft) { Image(systemName: model.sending ? "clock.badge.checkmark" : "arrow.up").font(.system(size:min(sendSymbolSize,24),weight:.semibold)).foregroundStyle(canSendDraft ? CatpawColors.onInk : CatpawColors.secondary).frame(width: 44, height: 44).background(canSendDraft ? CatpawColors.ink : CatpawColors.input, in: Circle()) }
                    .buttonStyle(CatpawPressButtonStyle()).disabled(!canSendDraft)
                    .accessibilityLabel(model.sending ? "排队发送" : "发送").accessibilityHint(model.session?.unresolved?.state == .unknown ? "先读取原请求进展，当前草稿不会重发" : (model.sending ? "保存在后续消息队列，仅在前台发送" : "发送当前消息")).accessibilityIdentifier("chat.send")
            }.padding(.horizontal, 16).padding(.vertical, 8).background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 24)).overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(CatpawColors.separator) }
            if [.offline,.notConfigured].contains(model.connectionLifecycle) { Button { settings = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(model.connection.state == .connected ? CatpawColors.success : CatpawColors.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(connectionSummary).font(.caption)
                    Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                }.frame(minHeight:44).contentShape(Rectangle())
            }.buttonStyle(CatpawPressButtonStyle()).foregroundStyle(CatpawColors.secondary).accessibilityLabel("模型连接设置").accessibilityValue(connectionSummary).accessibilityIdentifier("chat.connection") }
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
        var messages=model.session?.messages ?? []
        for intent in model.outgoingMessages {
            let id=stableID("conversation-user-\(intent.id)")
            if !messages.contains(where:{$0.id == id}) { messages.append(.init(id:id,role:.user,content:intent.text)) }
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
            case .savingLocal:return "\u{6B63}\u{5728}\u{672C}\u{673A}\u{4FDD}\u{5B58}"
            case .queued:return "\u{5DF2}\u{4FDD}\u{5B58}\u{5728}\u{672C}\u{673A} \u{00B7} \u{5F85}\u{53D1}\u{9001}"
            case .awaitingPermission:return "\u{7B49}\u{5F85}\u{8BB8}\u{53EF}"
            case .sending:return "\u{53D1}\u{9001}\u{4E2D}"
            case .unknown:return "\u{786E}\u{8BA4}\u{53D1}\u{9001}\u{72B6}\u{6001}"
            case .failed:return "\u{672C}\u{673A}\u{4FDD}\u{5B58}\u{672A}\u{5B8C}\u{6210}"
            }
        }
        return model.session?.turns.first(where:{$0.id == id})?.serverRequestHash == nil ? "\u{53D1}\u{9001}\u{4E2D}" : "\u{5DF2}\u{53D1}\u{9001}"
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
                if let id=operationID(message) { Text(delivery(id)).font(.caption).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.pendingAdmission") }
            }
        } else if message.role == .tool || message.toolName != nil {
            if let goal = linkedGoal(message) { ConversationGoalCard(goal: goal, busy: model.busy, refresh: model.readOriginal) }
            else if message.failure != nil { Label("任务请求失败 · " + (message.failure ?? ""), systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(CatpawColors.attention) }
            else { Label(message.toolName == "agent_status" ? (message.complete ? "任务进展已读取" : "读取任务进展…") : (message.complete ? "任务请求已记录" : "等待后台保存任务…"), systemImage: message.complete ? "checkmark.circle" : "circle.dotted").font(.footnote).foregroundStyle(CatpawColors.secondary) }

        } else { Text(message.content).font(.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("chat.assistantMessage") }
    }
}
private struct ConversationGoalCard: View {
    let goal: ConversationGoalProjection
    let busy: Bool
    let refresh: () -> Void
    @State private var expanded = false
    private var status: String { switch goal.state { case .queued: "已排队"; case .working: "正在进行"; case .waitingInput: "等待反馈"; case .completed: "已完成"; case .failed: "需要处理"; case .paused: "已暂停"; case .cancelled: "已结束"; case .unknown: "状态待确认" } }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(goal.summary).textSelection(.enabled)
                ForEach(goal.artifacts) { artifact in DisclosureGroup(artifact.title + " · v\(artifact.version)") { Text(artifact.summary).font(.subheadline); Text(artifact.content).textSelection(.enabled); Text("SHA-256 " + artifact.contentHash).font(.caption2).textSelection(.enabled).accessibilityIdentifier("chat.artifact.hash." + artifact.id) }.accessibilityIdentifier("chat.artifact." + artifact.id) }
                Button("读取最新进展", action: refresh).touchTarget().disabled(busy)
                Text("最近读取 · " + goal.updatedAt.formatted()).font(.caption).foregroundStyle(CatpawColors.secondary)
            }.padding(.top, 10)
        } label: { HStack { Image(systemName: "circle.dotted"); Text(goal.title).font(.subheadline.weight(.medium)).fixedSize(horizontal:false,vertical:true); Spacer(); Text(status).font(.caption).foregroundStyle(CatpawColors.secondary) } }
            .padding(14).background(CatpawColors.panel, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("chat.goal.\(goal.id)")
    }
}
@MainActor private struct ConversationHistoryView: View {
    @ObservedObject var model: ConversationFirstModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(model.history) { record in
                Button { Task { do { try await model.select(record.id); dismiss() } catch { model.error = error.localizedDescription } } } label: { historyRow(record) }
                    .buttonStyle(.plain).disabled(model.busy)
                    .accessibilityIdentifier("chat.history.row." + record.id.uuidString)
                    .accessibilityLabel(historyLabel(record))
            }.accessibilityIdentifier("chat.historyList").navigationTitle("对话历史")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }

        }
    }
    private func historyLabel(_ record: StoredRecord) -> String {
        let draft = record.conversation?.draftText ?? ""
        return record.title + (draft.isEmpty ? "" : "，草稿，" + String(draft.prefix(80)))
    }
    private func historyRow(_ record: StoredRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.title).foregroundStyle(CatpawColors.ink)
            if let draft = record.conversation?.draftText, !draft.isEmpty {
                Text("草稿 · " + String(draft.prefix(80))).font(.caption).lineLimit(2).foregroundStyle(CatpawColors.secondary)
            }
            Text(record.header.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(CatpawColors.secondary)
        }
    }

}
@MainActor private struct ConversationConnectionView: View {
    @ObservedObject var model: ConversationFirstModel
    @Environment(\.dismiss) private var dismiss
    private var stateName: String {
        switch model.connection.state { case .notConfigured: "未连接"; case .providerUnverified: "待验证"; case .unavailable: "暂不可用"; case .connected: "已连接" }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("模型连接") {
                    LabeledContent("状态") { Text(stateName).foregroundStyle(CatpawColors.ink) }.accessibilityIdentifier("connection.state")

                    if let modelID = model.connection.model { LabeledContent("已验证模型") { Text(modelID).foregroundStyle(CatpawColors.secondary) } }
                    Text(model.connection.detail).font(.footnote)
                    Button("重新检查连接") { Task { await model.refreshConnection() } }.accessibilityIdentifier("connection.refresh")
                }
                Section("数据") { Text(model.connection.state == .notConfigured ? "当前未连接云端；输入保存在此设备。" : "此设备保存对话副本；发送的消息会交给已连接的云端服务处理。"); Text("离开 App 后不会发送排队中的消息。任务后台执行的状态需要重新读取确认。").font(.footnote) }
                Section { DisclosureGroup("诊断") { LabeledContent("服务",value:model.connection.provider); Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))"); Text(model.connection.state.rawValue).font(.caption).textSelection(.enabled) } }
                if model.connection.state == .notConfigured { Text("真实模型尚未配置；不会使用演示回复代替模型。").font(.footnote).foregroundStyle(CatpawColors.secondary) }
            }.foregroundStyle(CatpawColors.ink).navigationTitle("设置").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
