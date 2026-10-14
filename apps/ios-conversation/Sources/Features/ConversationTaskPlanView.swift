import SwiftUI

@MainActor struct ConversationTaskPlanView:View {
    @StateObject private var model:ConversationTaskPlanModel
    private let admissionAllowed:()->Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var confirmDiscard=false
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    init(service:ConversationTaskPlanService,reference:ConversationTaskPlanReference,admissionAllowed:@escaping()->Bool = {false}) {
        _model=StateObject(wrappedValue:ConversationTaskPlanModel(service:service,reference:reference));self.admissionAllowed=admissionAllowed
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    if let plan=model.state.snapshot {
                        VStack(alignment:.leading,spacing:10) {
                            Text(plan.content.title).font(CatpawTypography.Role.title.font.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            Text(ui("计划版本")+" · v\(plan.acceptedRevision)").font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.plan.revision")
                            stateSummary(plan)
                        }
                        if let error=model.error {Text(error).foregroundStyle(CatpawColors.attention).textSelection(.enabled).accessibilityIdentifier("chat.plan.error")}
                        if model.editing {editor} else {
                            detail(ui("目标"),plan.content.goal)
                            detail(ui("具体要求"),plan.content.requirements)
                            if model.state.draft != nil {Text(ui("修改草稿已保留；尚未提交。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.plan.savedDraft")}
                            if model.canEdit {
                                Button(ui("修改要求")) {model.beginEditing()}.touchTarget().accessibilityIdentifier("chat.plan.edit")
                            }
                        }
                        VStack(alignment:.leading,spacing:16) {
                            Text(ui("当前执行版本")+" · v\(plan.appliedRevision)").font(CatpawTypography.Role.heading.font)
                            ForEach(plan.appliedContent.steps) {step in
                                HStack(alignment:.top,spacing:12) {
                                    let confirmed=plan.stepReceipts.contains {$0.stepID==step.id}
                                    Image(systemName:confirmed ? "checkmark.circle" : "circle").foregroundStyle(confirmed ? CatpawColors.success : CatpawColors.secondary)
                                    VStack(alignment:.leading,spacing:6) {Text(step.title).font(CatpawTypography.Role.body.font.weight(.medium));if !step.detail.isEmpty {Text(step.detail).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)}}
                                }.accessibilityElement(children:.combine).accessibilityIdentifier("chat.plan.step."+step.id)
                            }
                        }
                        VStack(alignment:.leading,spacing:8) {Text(ui("结束条件")).font(CatpawTypography.Role.heading.font);ForEach(Array(plan.content.stopConditions.enumerated()),id:\.offset) {_,condition in Text(condition).textSelection(.enabled)}}
                        DisclosureGroup(ui("版本与核对信息")) {VStack(alignment:.leading,spacing:8) {Text("SHA-256 "+plan.acceptedPlanHash);Text(ui("工作编号")+": "+plan.taskID)}.font(CatpawTypography.Role.caption.font).textSelection(.enabled)}
                    } else {
                        if model.loading {ProgressView(ui("正在读取计划"))}
                        else {Text(model.error ?? ui("计划尚未读取。")).foregroundStyle(CatpawColors.secondary)}
                    }
                    Button(model.state.hasUnresolvedSubmission ? ui("核对原修改") : ui("读取最新计划")) {Task{await model.load(admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.loading || model.submitting || !admissionAllowed()).accessibilityIdentifier("chat.plan.refresh")
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }.background(CatpawColors.background)
                .navigationTitle(ui("工作计划")).navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button(ui("完成")) {Task{if await model.finishEditing() {dismiss()}}}.accessibilityIdentifier("chat.plan.close")}}
                .safeAreaInset(edge:.bottom) {if model.editing {editorActions}}
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.preventDismiss)
            .task {await model.load(admissionAllowed:admissionAllowed())}
            .onDisappear {Task{await model.flushDraft()}}
            .confirmationDialog(ui("放弃这份修改草稿？"),isPresented:$confirmDiscard,titleVisibility:.visible) {Button(ui("放弃草稿"),role:.destructive){Task{await model.discardDraft()}};Button(ui("取消"),role:.cancel){}}
    }
    private var editor:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(ui("修改此工作，聊天草稿会保留。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            Text(ui("目标")).font(CatpawTypography.Role.heading.font)
            TextEditor(text:$model.goal).frame(minHeight:110).padding(8).background(CatpawColors.input,in:RoundedRectangle(cornerRadius:12)).accessibilityLabel(ui("目标")).accessibilityIdentifier("chat.plan.goalField").onChange(of:model.goal){_,_ in model.stageDraft()}
            Text(ui("具体要求")).font(CatpawTypography.Role.heading.font)
            TextEditor(text:$model.requirements).frame(minHeight:140).padding(8).background(CatpawColors.input,in:RoundedRectangle(cornerRadius:12)).accessibilityLabel(ui("具体要求")).accessibilityIdentifier("chat.plan.requirementsField").onChange(of:model.requirements){_,_ in model.stageDraft()}
            if let message=model.wireValidationMessage {Text(ui(message)).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.plan.lengthError")}
            if let message=model.draftSaveIssue {Text(ui(message)).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.plan.unsaved")}
            if model.hasConflict {
                Text(ui("计划已更新；草稿仍保留，请核对版本。")).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.plan.conflict")
                Button(ui("保留草稿并以新版继续")){Task{await model.rebaseDraft()}}.touchTarget().disabled(!model.freshlyRead || model.state.hasUnresolvedSubmission)
            }
            Button(ui("放弃草稿"),role:.destructive){confirmDiscard=true}.touchTarget()
        }
    }
    private var editorActions:some View {
        VStack(spacing:8) {
            Button {Task{await model.submit(admissionAllowed:admissionAllowed())}} label:{HStack {if model.submitting {ProgressView()};Text(ui("保存修改")).fontWeight(.semibold)}.frame(maxWidth:.infinity).frame(minHeight:44)}.buttonStyle(.borderedProminent).disabled(!model.canSubmit || !admissionAllowed()).accessibilityIdentifier("chat.plan.save")
            Button(ui("返回计划，保留草稿")){Task{await model.finishEditing()}}.touchTarget().accessibilityIdentifier("chat.plan.keepDraft")
        }.padding(.horizontal,20).padding(.vertical,10).background(.regularMaterial)
    }
    @ViewBuilder private func stateSummary(_ plan:ConversationTaskPlanSnapshot)->some View {
        if let submission=model.state.submission {
            switch submission.state {
            case .unknown:Text(ui("修改结果尚未确认。只核对原修改，请勿重复提交。")).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.plan.unknown")
            case .pending:Text(ui("修改已受理，等待在安全点生效。")).foregroundStyle(CatpawColors.secondary).accessibilityIdentifier("chat.plan.pending")
            case .applied:Text(ui("修改已在安全点生效。")).foregroundStyle(CatpawColors.success).accessibilityIdentifier("chat.plan.applied")
            case .rejected,.notSent:Text(submission.message ?? ui("修改尚未提交；草稿已保留。")).foregroundStyle(CatpawColors.attention)
            }
        } else if plan.applicationState == .pending {Text(ui("新计划已受理，当前仍执行上一版本。")).foregroundStyle(CatpawColors.secondary)}
        else if plan.applicationState == .blockedUnknown {Text(ui("工作结果未知，先核对原工作。")).foregroundStyle(CatpawColors.attention)}
        if !model.freshlyRead {Text(ui("显示已保存计划；尚未完成当前读取。")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)}
    }
    private func detail(_ title:String,_ body:String)->some View {VStack(alignment:.leading,spacing:8){Text(title).font(CatpawTypography.Role.heading.font);Text(body).textSelection(.enabled)}}
}
