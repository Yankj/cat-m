import SwiftUI

@MainActor private final class ConversationTaskActionsModel:ObservableObject {
    let service:ConversationTaskActionService
    let reference:ConversationTaskActionReference
    @Published var state=ConversationTaskActionLocalState()
    @Published var loading=false
    @Published var submitting=false
    @Published var freshlyRead=false
    @Published var error:String?
    private var generation=0
    init(service:ConversationTaskActionService,reference:ConversationTaskActionReference){self.service=service;self.reference=reference}
    func load(admissionAllowed:Bool) async {
        guard !loading,!submitting else {return};generation += 1;let epoch=generation
        loading=true;freshlyRead=false;defer{if epoch==generation {loading=false}}
        await service.setAdmissionAllowed(admissionAllowed)
        do {
            let local=try await service.localState(reference);guard epoch==generation else {return};state=local
            guard admissionAllowed else {return}
            let latest=try await service.refresh(reference);guard epoch==generation else {return};state=latest;freshlyRead=true;error=nil
        } catch {if epoch==generation {self.error=error.localizedDescription;freshlyRead=false}}
    }
    func decide(_ action:ConversationTaskActionSnapshot,decision:ConversationTaskActionDecision,admissionAllowed:Bool) async {
        guard canDecide(action),admissionAllowed else {return};submitting=true;let epoch=generation
        defer{if epoch==generation {submitting=false}}
        await service.setAdmissionAllowed(admissionAllowed)
        do {let latest=try await service.decide(reference,actionID:action.id,expectedDigest:action.action_digest,expectedRevision:action.revision,decision:decision);guard epoch==generation else {return};state=latest;error=nil}
        catch {guard epoch==generation else {return};if let saved=try? await service.localState(reference){state=saved};freshlyRead=false;self.error=error.localizedDescription}
    }
    func canDecide(_ action:ConversationTaskActionSnapshot)->Bool {freshlyRead && state.decisionAvailable && !loading && !submitting && !state.hasUnresolvedDecision && action.canDecide(at:Date())}
    func close(){generation += 1;freshlyRead=false}
}

@MainActor struct ConversationTaskActionsView:View {
    @StateObject private var model:ConversationTaskActionsModel
    private let admissionAllowed:()->Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var textSize
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    init(service:ConversationTaskActionService,reference:ConversationTaskActionReference,admissionAllowed:@escaping()->Bool = {false}){_model=StateObject(wrappedValue:ConversationTaskActionsModel(service:service,reference:reference));self.admissionAllowed=admissionAllowed}
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Text(model.reference.title).font(catTypography.Role.title.font.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(ui("批准仅记录这份精确事项的决定；设备执行结果会另行核对。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                    if let error=model.error {Text(ui(error)).foregroundStyle(catColors.attention).textSelection(.enabled).accessibilityIdentifier("chat.actions.error")}
                    if model.loading {ProgressView(ui("正在读取审批事项"))}
                    if !model.freshlyRead && !model.state.actions.isEmpty {Text(ui("显示已保存事项；当前性尚未核对。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.actions.saved")}
                    if model.state.actions.isEmpty && !model.loading {Text(ui("当前没有可查看的审批事项。")).foregroundStyle(catColors.secondary).accessibilityIdentifier("chat.actions.empty")}
                    if model.freshlyRead && !model.state.decisionAvailable {Text(ui("当前服务尚不支持提交决定，可继续查看事项。")).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.actions.unavailable")}
                    ForEach(model.state.actions){action in actionCard(action)}
                    Button(model.state.hasUnresolvedDecision ? ui("核对原决定") : ui("读取最新事项")){Task{await model.load(admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.loading || model.submitting || !admissionAllowed()).accessibilityIdentifier("chat.actions.refresh")
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }.background(catColors.background)
                .navigationTitle(ui("待决定事项")).navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.confirmationAction){Button(ui("完成")){model.close();dismiss()}.accessibilityIdentifier("chat.actions.close")}}
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .task {await model.load(admissionAllowed:admissionAllowed())}
            .onDisappear {model.close()}
    }
    private func actionCard(_ action:ConversationTaskActionSnapshot)->some View {
        VStack(alignment:.leading,spacing:16) {
            if let parameters=action.calendarParameters,let target=action.calendarTarget {
                Text(parameters.title).font(catTypography.Role.heading.font).accessibilityIdentifier("chat.action.title."+action.id)
                Text(ui("新建日历事件")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary)
                detail(ui("日历"),target.calendar_display_name)
                detail(ui("开始时间"),calendarTime(parameters.start_at,timeZone:parameters.time_zone)).accessibilityElement(children:.combine).accessibilityIdentifier("chat.action.start."+action.id)
                detail(ui("结束时间"),calendarTime(parameters.end_at,timeZone:parameters.time_zone)).accessibilityElement(children:.combine).accessibilityIdentifier("chat.action.end."+action.id)
                detail(ui("时区"),parameters.time_zone)
                detail(ui("提醒"),reminder(parameters.reminder_offset_seconds)).accessibilityElement(children:.combine).accessibilityIdentifier("chat.action.reminder."+action.id)
                DisclosureGroup(ui("设备与日历身份")) {VStack(alignment:.leading,spacing:8){detail(ui("设备编号"),target.device_id);detail(ui("环境编号"),target.environment_id);detail(ui("日历编号"),target.calendar_id);Text("SHA-256 "+target.calendar_snapshot_hash)}.font(catTypography.Role.caption.font).textSelection(.enabled)}
            } else {
                Text(ui("此版本无法决定这类事项，保留原始内容供查看。")).foregroundStyle(catColors.attention);Text(action.frozen.kind).font(catTypography.Role.heading.font)
                DisclosureGroup(ui("原始事项内容")){if let data=try? ConversationTaskActionJSON.encoded(action.frozen) {Text(String(decoding:data,as:UTF8.self)).font(catTypography.Role.caption.font).textSelection(.enabled)}}
            }
            Text(status(action)).font(catTypography.Role.secondary.font.weight(.medium)).foregroundStyle(action.approval_status=="approved" ? catColors.success : catColors.secondary).accessibilityIdentifier("chat.action.status."+action.id)
            Text(ui("决定期限")+" · "+calendarTime(action.frozen.expires_at,timeZone:action.calendarParameters?.time_zone ?? "UTC")).font(catTypography.Role.caption.font).accessibilityIdentifier("chat.action.expiry."+action.id)
            if let reason=action.invalidation_reason {Text(reasonText(reason)).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.action.invalidated."+action.id)}
            if let submission=model.state.submissions[action.id] {submissionSummary(submission)}
            if action.isSupported && action.approval_status=="pending" {
                if textSize.isAccessibilitySize {VStack(spacing:12){decisionButtons(action)}} else {HStack(spacing:12){decisionButtons(action)}}
            }
            DisclosureGroup(ui("精确绑定与核对信息")) {
                VStack(alignment:.leading,spacing:8) {
                    Text(ui("事项编号")+" · "+action.id).accessibilityIdentifier("chat.action.id."+action.id)
                    Text(ui("事项版本")+" · v\(action.revision)")
                    Text("SHA-256 "+action.action_digest).accessibilityIdentifier("chat.action.digest."+action.id)
                    Text(ui("参数哈希")+" · "+action.frozen.parameters_hash)
                    Text(ui("计划版本")+" · v\(action.frozen.plan_reference.revision)")
                    Text(ui("计划哈希")+" · "+action.frozen.plan_reference.plan_hash)
                    Text(ui("决定期限")+" (UTC) · "+action.frozen.expires_at)
                    if let parameters=action.calendarParameters {
                        Text(ui("精确开始时间")+" · "+parameters.start_at).accessibilityIdentifier("chat.action.exactStart."+action.id)
                        Text(ui("精确结束时间")+" · "+parameters.end_at).accessibilityIdentifier("chat.action.exactEnd."+action.id)
                        Text(ui("提醒偏移（秒）")+" · "+(parameters.reminder_offset_seconds.map(String.init) ?? ui("无提醒")))
                    }
                    if let artifact=action.frozen.artifact_reference {Text(ui("成果版本")+" · "+artifact.artifact_id+" v\(artifact.version)");Text("SHA-256 "+artifact.content_hash)}
                    Text(ui("工作编号")+" · "+action.frozen.task_id)
                    Text(ui("账户编号")+" · "+action.frozen.subject_id)
                    Text(ui("分区编号")+" · "+action.frozen.scope_id)
                    Text(ui("对话编号")+" · "+action.frozen.conversation_id)
                    Text(ui("原消息编号")+" · "+action.frozen.turn_id)
                    Text(ui("原工作编号")+" · "+action.frozen.run_id)
                    Text(ui("原请求哈希")+" · "+action.frozen.request_hash)
                    Text(ui("委派编号")+" · "+action.frozen.delegation_id)
                    Text(ui("委派版本")+" · v\(action.frozen.delegation_revision)")
                    Text(ui("许可版本")+" · v\(action.frozen.grant_epoch)")
                    if let operation=action.decision_operation_id {Text(ui("原决定编号")+" · "+operation).accessibilityIdentifier("chat.action.operation."+action.id)}
                    if let submission=model.state.submissions[action.id] {
                        Text(ui("本次原决定编号")+" · "+submission.request.operationID.uuidString.lowercased()).accessibilityIdentifier("chat.action.localOperation."+action.id)
                    }
                }.font(catTypography.Role.caption.font).textSelection(.enabled)
            }.accessibilityElement(children:.contain).accessibilityIdentifier("chat.action.metadata."+action.id)
        }.padding(16).background(catColors.input,in:RoundedRectangle(cornerRadius:16)).accessibilityElement(children:.contain).accessibilityIdentifier("chat.action.card."+action.id)
    }
    private func detail(_ title:String,_ value:String)->some View {VStack(alignment:.leading,spacing:4){Text(verbatim:title).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary);Text(value).textSelection(.enabled)}}
    @ViewBuilder private func decisionButtons(_ action:ConversationTaskActionSnapshot)->some View {
        Button(role:.destructive){Task{await model.decide(action,decision:.deny,admissionAllowed:admissionAllowed())}} label:{Text(ui("拒绝")).frame(maxWidth:.infinity,minHeight:44)}.touchTarget().buttonStyle(.bordered).buttonBorderShape(.roundedRectangle).disabled(!model.canDecide(action) || !admissionAllowed()).accessibilityIdentifier("chat.action.deny."+action.id)
        Button{Task{await model.decide(action,decision:.approve,admissionAllowed:admissionAllowed())}} label:{Text(ui("批准这份事项")).frame(maxWidth:.infinity,minHeight:44)}.touchTarget().buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle).disabled(!model.canDecide(action) || !admissionAllowed()).accessibilityIdentifier("chat.action.approve."+action.id)
    }
    private func calendarTime(_ exact:String,timeZone:String)->String {
        guard let date=ConversationTaskActionValidation.utc(exact),let zone=TimeZone(identifier:timeZone) else {return exact}
        let formatter=DateFormatter();formatter.locale=locale;formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone=zone;formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEEjmmss")
        return formatter.string(from:date)
    }
    private func reminder(_ offset:Int?)->String {
        guard let offset else {return ui("无提醒")};if offset==0 {return ui("开始时提醒")}
        let seconds = -offset
        if seconds%86400==0 {return ui("开始前 {0} 天").replacingOccurrences(of:"{0}",with:String(seconds/86400))}
        if seconds%3600==0 {return ui("开始前 {0} 小时").replacingOccurrences(of:"{0}",with:String(seconds/3600))}
        if seconds%60==0 {return ui("开始前 {0} 分钟").replacingOccurrences(of:"{0}",with:String(seconds/60))}
        return ui("开始前 {0} 秒").replacingOccurrences(of:"{0}",with:String(seconds))
    }
    private func status(_ action:ConversationTaskActionSnapshot)->String {switch action.approval_status {
    case "approved":return action.effect.status=="waiting_device" ? ui("已批准；等待设备，尚未执行。") : ui("已批准；当前授权已失效，尚未执行。")
    case "denied":return ui("已拒绝；尚未执行。")
    case "expired":return ui("已过期；尚未决定或执行。")
    case "invalidated":return ui("事项已失效；尚未执行。")
    case "pending":return action.canDecide(at:Date()) ? ui("等待你的决定；尚未执行。") : ui("事项已过期或当前性不足；尚未执行。")
    default:return ui("未知事项状态；仅供查看。")
    }}
    private func reasonText(_ reason:String)->String {switch reason {
    case "expired":return ui("决定期限已过，请读取最新事项。")
    case "newer_parameters":return ui("目标或参数已有新版，这份事项不能批准。")
    case "plan_changed":return ui("计划已变化，这份事项不能批准。")
    case "artifact_changed":return ui("成果版本已变化，这份事项不能批准。")
    case "grant_changed","source_authority_changed":return ui("原许可已变化，这份事项不能批准。")
    case "task_not_active":return ui("工作当前不可执行，这份事项不能批准。")
    default:return ui("当前性无法确认，这份事项不能批准。")
    }}
    @ViewBuilder private func submissionSummary(_ submission:ConversationTaskActionSubmission)->some View {
        switch submission.state {
        case .unknown:Text(submission.issue == .originalNotFound ? ui("尚未找到原决定记录；结果仍未知，请继续核对或寻求帮助。") : ui("决定结果尚未确认；只核对原决定，请勿重复提交。")).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.action.unknown."+submission.actionID)
        case .notSent:Text(ui("决定尚未发送；这份事项仍保留。")).foregroundStyle(catColors.attention)
        case .rejected:Text(ui("决定未获受理；请读取最新事项后核对。")).foregroundStyle(catColors.attention)
        case .accepted:EmptyView()
        }
    }
}
