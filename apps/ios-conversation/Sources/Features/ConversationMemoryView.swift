import SwiftUI

/// Server memory management, reachable from the conversation's existing native
/// navigation. This view has no account, HTTP, extraction or execution authority.
@MainActor struct ConversationMemoryView:View {
    @StateObject private var model:ConversationMemoryModel
    private let admissionAllowed:@MainActor()->Bool
    @Environment(\.locale) private var locale
    private enum DraftField:Hashable {case topic,text}
    @FocusState private var focusedField:DraftField?
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    init(service:ConversationMemoryService,conversationID:UUID?,admissionAllowed:@escaping @MainActor()->Bool={false}){_model=StateObject(wrappedValue:ConversationMemoryModel(service:service,conversationID:conversationID));self.admissionAllowed=admissionAllowed}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:CatpawLayout.sectionGap) {
                Text(ui("记忆用于已选择范围的后续对话。候选须确认；关闭利用不会删除原记录。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true)
                if !model.loadedFresh {Text(ui("显示本机保存状态；读取最新状态后才能修改。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("memory.cached")}
                if let snapshot=model.state?.latest {
                    SectionHeading(title:snapshot.enabled ? ui("记忆利用已开启"):ui("记忆利用已关闭"))
                    Button(snapshot.enabled ? ui("关闭记忆利用"):ui("开启记忆利用")){model.prepareEnabled(!snapshot.enabled)}.touchTarget().disabled(!model.canWrite).accessibilityIdentifier("memory.enabled.change")
                    if !snapshot.claims.isEmpty {SectionHeading(title:ui("已确认记忆"));ForEach(snapshot.claims){entry in memory(entry,candidate:false)}}
                    if !snapshot.candidates.isEmpty {SectionHeading(title:ui("待确认候选"));ForEach(snapshot.candidates){entry in memory(entry,candidate:true)}}
                    if snapshot.claims.isEmpty && snapshot.candidates.isEmpty {Text(ui("还没有记忆。你可以在这里明确保存一条偏好。")).font(CatpawTypography.Role.body.font).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("memory.empty")}
                    editor.disabled(!(snapshot.enabled && model.canWrite))
                }
                if let pending=model.state?.pending {
                    Text(ui("原记忆操作结果尚未确认。只读取原操作，不重复发送。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("memory.unknown")
                    Button(ui("核对原记忆操作")){Task{await model.readOriginal(admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.busy || !admissionAllowed()).accessibilityIdentifier("memory.observe")
                    if pending.notSent {Button(ui("重新核对未受理内容")){Task{await model.reopenNotSent()}}.touchTarget().disabled(model.busy).accessibilityIdentifier("memory.reopenNotSent")}
                }
                if let receipt=model.state?.lastReceipt {
                    Text(ui("记忆变更已获服务回执。")).font(CatpawTypography.Role.secondary.font).accessibilityIdentifier("memory.applied")
                    if receipt.operation.command_type == .forget {Text(ui("主记忆及派生索引已清除；备份清除尚未核验。原对话历史不会在此删除。")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true)}
                }
                if let error=model.error {Text(ui(error)).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.attention).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("memory.error")}
                Button(ui("读取最新记忆")){Task{await model.load(admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.busy || !admissionAllowed()).accessibilityIdentifier("memory.refresh")
            }.padding(CatpawLayout.pageInset).frame(maxWidth:CatpawLayout.readableWidth,alignment:.leading).frame(maxWidth:.infinity)
        }.scrollDismissesKeyboard(.interactively).background(CatpawColors.background).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink).navigationTitle(ui("记忆")).navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("memory.viewport")
            .task{await model.load(admissionAllowed:admissionAllowed())}.onDisappear{Task{await model.flush()}}
            .catpawSheet(isPresented:Binding(get:{model.review != nil},set:{if !$0 && !model.busy{model.review=nil}})){reviewSheet.interactiveDismissDisabled(model.busy)}
            .catpawSheet(item:$model.source){source in sourceSheet(source)}
    }
    private var editor:some View {
        VStack(alignment:.leading,spacing:12) {
            SectionHeading(title:model.draft.targetID==nil ? ui("明确保存一条记忆"):ui("更正这条记忆"))
            if model.draft.targetID != nil {Text(ui("更正保留原范围与来源引用，使用本次输入作为新的更正来源。")).font(CatpawTypography.Role.secondary.font).fixedSize(horizontal:false,vertical:true)}
            TextField(ui("记忆主题"),text:$model.draft.topic,axis:.vertical).textFieldStyle(.roundedBorder).focused($focusedField,equals:.topic).disabled(model.draft.targetID != nil).accessibilityIdentifier("memory.draft.topic")
            TextField(ui("想记住的内容"),text:$model.draft.text,axis:.vertical).textFieldStyle(.roundedBorder).focused($focusedField,equals:.text).accessibilityIdentifier("memory.draft.text")
            if model.draft.targetID==nil {Picker(ui("使用范围"),selection:$model.draft.workspaceWide){Text(ui("仅当前对话")).tag(false);Text(ui("当前工作区的对话")).tag(true)}.pickerStyle(.inline).accessibilityIdentifier("memory.draft.scope")}
            Button(ui("核对并保存记忆")){focusedField=nil;model.prepareSave()}.touchTarget().disabled(model.conversationID==nil).accessibilityIdentifier("memory.draft.review")
            if model.draft.targetID != nil {Button(ui("放弃此草稿并新建"),role:.destructive){model.newDraft()}.touchTarget()}
        }.onChange(of:model.draft){_,_ in model.stageDraft()}
    }
    private func memory(_ entry:ConversationMemoryEntry,candidate:Bool)->some View {
        VStack(alignment:.leading,spacing:12) {
            SectionHeading(title:entry.displayTitle)
            Text(verbatim:entry.displayValue).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            Text(candidate ? ui("候选内容尚未作为已确认事实使用") : entry.status=="disputed" ? ui("存在冲突，不能当作确定事实") : entry.temporal_state=="out_of_time" ? ui("已超出有效时间") : ui("用户已确认")).font(CatpawTypography.Role.secondary.font).foregroundStyle(CatpawColors.secondary)
            Text(entry.conditions.isEmpty ? ui("范围：当前工作区的对话"):ui("范围：按原记录条件使用")).font(CatpawTypography.Role.secondary.font)
            conditions(entry.conditions)
            Text(verbatim:entry.recorded_at).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            CatpawAdaptiveActions {
                Button(ui("查看记忆来源")){Task{await model.showSource(entry.source_id,admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.busy || !admissionAllowed()).accessibilityIdentifier("memory.source."+entry.id.uuidString.lowercased())
                if candidate {Button(ui("确认这条候选")){model.prepareConfirm(entry)}.touchTarget().disabled(!model.canWrite || model.state?.latest?.enabled != true).accessibilityIdentifier("memory.confirm."+entry.id.uuidString.lowercased())}
                else {Button(ui("更正")){model.editing(entry)}.touchTarget().disabled(!model.canWrite).accessibilityIdentifier("memory.correct."+entry.id.uuidString.lowercased());Button(ui("忘记"),role:.destructive){model.prepareForget(entry)}.touchTarget().disabled(!model.canWrite).accessibilityIdentifier("memory.forget."+entry.id.uuidString.lowercased())}
            }
            if let previous=entry.previous_source_ref {Button(ui("查看更正前来源")){Task{await model.showSource(previous.id,admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.busy || !admissionAllowed())}
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(CatpawColors.panel,in:RoundedRectangle(cornerRadius:CatpawLayout.controlRadius)).accessibilityElement(children:.contain).accessibilityIdentifier("memory.entry."+entry.id.uuidString.lowercased())
    }
    private var reviewSheet:some View {
        NavigationStack {
            VStack(spacing:0) {
                ScrollView {VStack(alignment:.leading,spacing:24) {
                    if let command=model.review {
                        Text(ui("确认后才提交这一次变更；关闭会保留草稿。")).fixedSize(horizontal:false,vertical:true)
                        switch command.type {
                        case .set_enabled:Text(command.enabled==true ? ui("开启后，后续对话可使用已确认且范围匹配的记忆。"):ui("关闭后暂停记忆利用，已有记录仍可查看和忘记。"))
                        case .forget:Text(ui("忘记这条记忆并阻止旧来源再次学回；不会删除原对话。")).fixedSize(horizontal:false,vertical:true)
                        case .confirm:Text(ui("将原候选确认为记忆，来源与使用条件保持原记录。"))
                        case .remember,.correct:
                            Text(verbatim:command.source_text ?? "").fixedSize(horizontal:false,vertical:true).textSelection(.enabled).accessibilityIdentifier("memory.review.original")
                            Text(command.claim?.conditions.isEmpty==true ? ui("范围：当前工作区的对话"):ui("范围：仅当前对话或原记录条件"))
                        }
                        if let entry=((model.state?.latest?.claims ?? [])+(model.state?.latest?.candidates ?? [])).first(where:{$0.id==command.target_id || $0.id==command.candidate_id}) {
                            Text(verbatim:entry.displayTitle).font(CatpawTypography.Role.heading.font)
                            Text(verbatim:entry.displayValue).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                            Text(verbatim:"v\(entry.version)").font(CatpawTypography.Role.secondary.font)
                            Text(entry.conditions.isEmpty ? ui("范围：当前工作区的对话"):ui("范围：按原记录条件使用"))
                            conditions(entry.conditions)
                        }
                        if let claim=command.claim {conditions(claim.conditions)}
                        if command.type == .remember || command.type == .correct || command.type == .confirm {Toggle(ui("我确认此内容可作为敏感记忆保存"),isOn:Binding(get:{model.review?.sensitive_consent==true},set:{model.review?.sensitive_consent=$0}));Toggle(ui("允许重新学习曾明确忘记的主题"),isOn:Binding(get:{model.review?.allow_relearn==true},set:{model.review?.allow_relearn=$0}))}
                    }
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)}
                CatpawBottomActionArea {Button{Task{await model.submit(admissionAllowed:admissionAllowed())}}label:{CatpawAdaptiveActionTitle(fullTitle:ui("确认提交这次记忆变更"),compactTitle:ui("确认")).frame(maxWidth:.infinity,minHeight:44)}.buttonStyle(CatpawPrimaryButtonStyle()).accessibilityLabel(ui("确认提交这次记忆变更")).disabled(model.busy || !admissionAllowed()).accessibilityIdentifier("memory.review.confirm")}
            }.navigationTitle(ui("确认记忆变更")).navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.confirmationAction){Button(ui("关闭")){model.review=nil}.touchTarget().disabled(model.busy).accessibilityIdentifier("memory.review.close")}}
        }.font(CatpawTypography.Role.body.font).presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private func conditions(_ values:[String:ConversationMemoryValue])->some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(values.keys.sorted(),id:\.self){key in
                if key=="conversation_id" {Text(ui("限定对话")+" · "+(values[key]?.readable ?? "")).font(CatpawTypography.Role.secondary.font).fixedSize(horizontal:false,vertical:true)}
                else {Text(verbatim:key+" · "+(values[key]?.readable ?? "")).font(CatpawTypography.Role.secondary.font).fixedSize(horizontal:false,vertical:true)}
            }
        }
    }
    private func sourceSheet(_ source:ConversationMemorySource)->some View {
        NavigationStack {ScrollView {VStack(alignment:.leading,spacing:20) {
            Text(source.type=="user_memory_command" ? ui("来源：用户明确记忆命令"):ui("来源：用户原对话消息")).font(CatpawTypography.Role.heading.font)
            Text(verbatim:source.text ?? "").font(CatpawTypography.Role.body.font).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).accessibilityIdentifier("memory.source.text")
            Text(verbatim:source.occurred_at).font(CatpawTypography.Role.secondary.font)
            Text("SHA-256 "+source.content_hash).font(CatpawTypography.Role.caption.font).textSelection(.enabled)
            if source.suppressed_for_memory {Text(ui("此来源已停用于记忆提取，保留原文供核对。")).font(CatpawTypography.Role.secondary.font)}
        }.padding(20)}.navigationTitle(ui("记忆来源")).navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.confirmationAction){Button(ui("关闭")){model.source=nil}.touchTarget().accessibilityIdentifier("memory.source.close")}}}.presentationDetents([.large])
    }
}
