import SwiftUI

@MainActor struct ConversationTaskControlView:View {
    @StateObject private var model:ConversationTaskControlModel
    private let admissionAllowed:()->Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    init(service:ConversationTaskControlService,reference:ConversationTaskControlReference,admissionAllowed:@escaping()->Bool = {false},onApplied:(@MainActor (ConversationTaskControlEnvelope) async throws -> Void)?=nil){_model=StateObject(wrappedValue:ConversationTaskControlModel(service:service,reference:reference,onApplied:onApplied));self.admissionAllowed=admissionAllowed}
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    if let value=model.state.latest {
                        CatpawVersionedTitle(title:model.reference.title,version:ui("计划版本")+" · v\(value.plan_reference.revision)",layout:.reading,titleAccessibilityIdentifier:"chat.control.title",versionAccessibilityIdentifier:"chat.control.planVersion")
                        Text(status(value.task_status)).font(CatpawTypography.Role.heading.font).accessibilityIdentifier("chat.control.status")
                        if !model.freshlyRead {Text(ui("显示已保存状态；当前性尚未核对。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.control.saved")}
                        if let reason=value.blocked_reason {Text(reasonText(reason)).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.control.reason")}
                        if !value.source_authorization_current {Text(ui("原来源许可已变化，不能恢复这份工作。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.control.sourceUnavailable")}
                        if !value.unresolved_operations.isEmpty {Text(ui("已有发出但未确认的操作；恢复前必须核对原结果，不重复执行。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.control.unknownOperations")}
                        controls(value)
                        unresolved(value)
                        metadata(value)
                    } else {
                        Text(model.reference.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        if !model.loading {Text(ui("当前没有已核对的工作状态。")).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.control.empty")}
                    }
                    if model.loading {ProgressView(ui("正在读取工作状态"))}
                    if model.submitting {ProgressView(ui("正在申请控制，尚未确认结果")).accessibilityIdentifier("chat.control.submitting")}
                    if let error=model.error {Text(ui(error)).foregroundStyle(CatpawColors.attention).textSelection(.enabled).accessibilityIdentifier("chat.control.error")}
                    if let issue=model.deliveryIssue {Text(ui(issue)).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.control.delivery")}
                    if model.freshlyRead && !model.state.controlAvailable {Text(ui("当前服务尚不支持控制工作，可继续查看状态。")).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.control.unavailable")}
                    submissions
                    Button(model.state.hasUnresolvedSubmission ? ui("核对原控制") : ui("读取最新状态")){Task{await model.load(admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.loading || model.submitting || !admissionAllowed()).accessibilityIdentifier("chat.control.refresh")
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }.background(CatpawColors.background)
                .navigationTitle(ui("工作控制")).navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.confirmationAction){Button(ui("完成")){model.close();dismiss()}.accessibilityIdentifier("chat.control.close")}}
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .task {await model.load(admissionAllowed:admissionAllowed())}
            .onDisappear {model.close()}
    }
    private func controls(_ value:ConversationTaskControlSnapshot)->some View {
        VStack(alignment:.leading,spacing:16) {
            Text(ui("暂停保留原许可；撤回授权会停止后续步骤。已发出的操作仍须核对，不能借此回滚。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
            if !value.terminal {
                controlButton(.pause,ui("暂停工作"),identifier:"chat.control.pause")
                controlButton(.resume,ui("恢复已暂停工作"),identifier:"chat.control.resume")
                controlButton(.revoke,ui("撤回这份工作授权"),identifier:"chat.control.revoke",destructive:true)
            }
        }.accessibilityElement(children:.contain)
    }
    private func controlButton(_ action:ConversationTaskControlAction,_ label:String,identifier:String,destructive:Bool=false)->some View {
        Button(role:destructive ? .destructive : nil){Task{await model.submit(action,admissionAllowed:admissionAllowed())}} label:{Text(label).frame(maxWidth:.infinity).touchTarget()}
            .buttonStyle(.bordered).disabled(!model.canSubmit(action) || !admissionAllowed()).accessibilityIdentifier(identifier)
    }
    @ViewBuilder private func unresolved(_ value:ConversationTaskControlSnapshot)->some View {
        if !value.unresolved_operations.isEmpty {
            DisclosureGroup {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(value.unresolved_operations){operation in
                        VStack(alignment:.leading,spacing:4){Text(operationKind(operation.kind)).font(CatpawTypography.Role.heading.font);Text(ui("原操作编号")+" · "+operation.operation_id).font(CatpawTypography.Role.caption.font).textSelection(.enabled);Text(ui("状态")+" · "+operationState(operation.state)).font(CatpawTypography.Role.caption.font)}.accessibilityElement(children:.combine).accessibilityIdentifier("chat.control.unknown."+operation.id)
                    }
                }
            } label: {
                Text(ui("原操作编号")+" · \(value.unresolved_operations.count)").accessibilityIdentifier("chat.control.originalOperations")
            }.accessibilityElement(children:.contain)
        }
    }
    private var submissions:some View {
        VStack(alignment:.leading,spacing:16) {
            ForEach(model.state.orderedSubmissions){submission in
                VStack(alignment:.leading,spacing:8) {
                    Text(submissionStatus(submission)).font(CatpawTypography.Role.secondary.font).foregroundStyle(submission.state == .applied ? CatpawColors.secondary : CatpawColors.attention).accessibilityIdentifier("chat.control.submission."+submission.id)
                    Text(ui("本次原控制编号")+" · "+submission.id).font(CatpawTypography.Role.caption.font).textSelection(.enabled).accessibilityIdentifier("chat.control.operation."+submission.id)
                    if let receipt=submission.receipt {Text(ui("控制版本")+" · v\(receipt.accepted_execution_revision)").font(CatpawTypography.Role.caption.font);Text(ui("回执核对时间")+" · "+receipt.applied_at).font(CatpawTypography.Role.caption.font)}
                }
            }
        }
    }
    private func metadata(_ value:ConversationTaskControlSnapshot)->some View {
        DisclosureGroup(ui("精确绑定与核对信息")) {
            VStack(alignment:.leading,spacing:8) {
                Text(ui("工作编号")+" · "+value.task_id)
                Text(ui("原工作编号")+" · "+value.run_id)
                Text(ui("账户编号")+" · "+value.subject_id)
                Text(ui("分区编号")+" · "+value.scope_id)
                Text(ui("对话编号")+" · "+value.conversation_id)
                Text(ui("原请求哈希")+" · "+value.run_request_hash)
                Text(ui("控制版本")+" · v\(value.execution_revision)")
                Text(ui("计划版本")+" · v\(value.plan_reference.revision)")
                Text(ui("计划哈希")+" · "+value.plan_reference.plan_hash)
                Text(ui("许可版本")+" · v\(value.grant_epoch)")
                Text(ui("当前许可版本")+" · v\(value.authority_reference.grant_epoch)")
                Text("SHA-256 "+value.snapshot_hash)
            }.font(CatpawTypography.Role.caption.font).textSelection(.enabled)
        }.accessibilityIdentifier("chat.control.metadata")
    }
    private func status(_ raw:String)->String {switch raw {case "paused":return ui("工作已暂停");case "cancelled":return ui("工作已取消");case "scheduled","queued":return ui("工作已排队");case "running":return ui("工作进行中");case "waiting_input":return ui("工作等待输入");case "outcome_unknown":return ui("结果尚未确认");case "succeeded":return ui("工作已完成");case "failed":return ui("工作失败");default:return ui("工作状态尚未确认")}}
    private func reasonText(_ raw:String)->String {switch raw {case "user_paused":return ui("工作已按申请暂停；恢复仍受原许可和当前计划约束。");case "grant_changed":return ui("原工作授权已变化，不能恢复这份工作。");case "original_outcome_unknown":return ui("原操作结果尚未确认，请先核对原结果。");case "original_outcome_identity_missing":return ui("原操作身份记录不足，无法确认结果；不能恢复或重复执行。");case "original_source_not_current","revision_source_not_current","source_not_current":return ui("原来源许可已变化，不能恢复这份工作。");case "memory_generation_superseded":return ui("记忆范围已变化，不能恢复这份工作。");default:return ui("工作当前不允许恢复，请读取最新状态。")}}
    private func operationKind(_ raw:String)->String {switch raw {case "model":return ui("模型请求");case "public_source":return ui("公开来源读取");default:return ui("外部操作")}}
    private func operationState(_ raw:String)->String {switch raw {case "dispatched":return ui("已发出，结果尚未确认");case "executing":return ui("执行中，结果尚未确认");default:return ui("结果尚未确认")}}
    private func submissionStatus(_ submission:ConversationTaskControlSubmission)->String {switch submission.state {
    case .unknown:return submission.issue == .originalNotFound ? ui("尚未找到原控制记录；结果仍未知，请继续核对。") : ui("控制结果尚未确认；只核对原控制，请勿重复提交。")
    case .notSent:return ui("控制尚未发送，工作状态未获确认。")
    case .rejected:return ui("控制未获受理；请读取最新状态后核对。")
    case .applied:switch submission.request.action {case .pause:return ui("暂停回执已保存；以最新工作状态为准。");case .resume:return ui("恢复回执已保存；不代表成果已完成。");case .revoke:return ui("撤回授权回执已保存；已发出的操作仍须核对。")}
    }}
}
