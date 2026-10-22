import SwiftUI

/// The editor calls a scoped application service; account, HTTP and revision authority stay outside.
@MainActor struct ConversationArtifactEditView:View {
    @StateObject private var model:ConversationArtifactEditModel
    private let admissionAllowed:()->Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var focusedField:String?
    @State private var confirmDiscard=false
    @State private var visibleViewport:catVisibleViewport?
    @State private var measuredFieldHeights:[String:CGFloat]=[:]
    @State private var measuredLabelHeights:[String:CGFloat]=[:]
    @StateObject private var editorInteraction=catEditorInteraction()
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    init(service:ConversationArtifactEditService,reference:ConversationArtifactEditReference,admissionAllowed:@escaping()->Bool={false},onApplied:(@MainActor (ConversationArtifactEditEnvelope) async throws -> Void)?=nil) {
        _model=StateObject(wrappedValue:ConversationArtifactEditModel(service:service,reference:reference,onApplied:onApplied));self.admissionAllowed=admissionAllowed
    }
    var body:some View {
        NavigationStack {
                VStack(spacing:0) {
                    GeometryReader { viewport in
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Text(ui("这是你的人工修改，不会重新调用模型或读取来源。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
                    if let base=model.base {
                        Text(ui("修改基于版本")+" · v\(base.version)").font(catTypography.Role.secondary.font).accessibilityIdentifier("chat.artifact.edit.baseVersion")
                        if let current=model.state.currentReference {Text(ui("当前成果版本")+" · v\(current.version)").font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary).accessibilityIdentifier("chat.artifact.edit.currentVersion")}
                        Text(base.sourceEvidenceBoundary == .suppliedContextOnly ? ui("沿用给定材料，改后正文未经重新核对。") : ui("来源沿用原版本快照，不为改后正文重新担保。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
                    } else if model.loading {ProgressView(ui("正在读取成果"))}
                    status
                    editor(ui("标题"),binding:Binding(get:{model.title},set:{guard model.canEditLocal else {return};model.title=$0;model.stageDraft()}),id:"title",preferredLines:3,viewportHeight:usableViewportHeight(viewport))
                    editor(ui("摘要"),binding:Binding(get:{model.summary},set:{guard model.canEditLocal else {return};model.summary=$0;model.stageDraft()}),id:"summary",preferredLines:3,viewportHeight:usableViewportHeight(viewport))
                    editor(ui("正文"),binding:Binding(get:{model.content},set:{guard model.canEditLocal else {return};model.content=$0;model.stageDraft()}),id:"content",preferredLines:6,viewportHeight:usableViewportHeight(viewport))
                    if let message=model.wireValidationMessage {Text(ui(message)).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.artifact.edit.validation")}
                    if let issue=model.draftSaveIssue {Text(ui(issue)).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.artifact.edit.unsaved")}
                    if model.hasConflict {
                        Text(ui("成果已有新版，原稿和输入仍保留。核对后才能换用新版继续。")).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.artifact.edit.conflict")
                        Button(ui("保留输入并明确换用新版")){Task{await model.rebase()}}.touchTarget().disabled(!model.freshlyRead || model.state.hasUnresolvedSubmission || model.loading || model.submitting).accessibilityIdentifier("chat.artifact.edit.rebase")
                    }
                    Button(model.state.hasUnresolvedSubmission ? ui("核对原修改") : ui("读取当前成果")){Task{await model.load(admissionAllowed:admissionAllowed())}}.touchTarget().disabled(model.loading || model.submitting || !admissionAllowed()).accessibilityIdentifier("chat.artifact.edit.refresh")
                    Button(ui("放弃草稿"),role:.destructive){confirmDiscard=true}.touchTarget().accessibilityIdentifier("chat.artifact.edit.discard")
                    DisclosureGroup(ui("版本与核对信息")){VStack(alignment:.leading,spacing:8){if let base=model.base {Text("SHA-256 "+base.contentHash).textSelection(.enabled)};if let receipt=model.state.submission?.receipt?.amendment {Text("Receipt SHA-256 "+receipt.receiptHash).textSelection(.enabled)}}.font(catTypography.Role.caption.font)}
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
                    .background(catEditorScrollObserver(interaction:editorInteraction).frame(width:0,height:0).accessibilityHidden(true))
            }.scrollDismissesKeyboard(.interactively).background(catColors.background).accessibilityIdentifier("chat.artifact.edit.viewport")
                .background(catViewportObserver{value in visibleViewport=value;editorInteraction.viewportChanged(value)}.accessibilityHidden(true))
                    }
                    footer
                }
                .onChange(of:focusedField){_,_ in editorInteraction.requestReveal()}
                .onPreferenceChange(ArtifactEditFieldHeightKey.self){heights in
                    let changed=focusedField.map{measuredFieldHeights[$0] != heights[$0]} ?? false
                    measuredFieldHeights=heights
                    if changed {editorInteraction.requestReveal()}
                }
                .onPreferenceChange(ArtifactEditLabelHeightKey.self){heights in measuredLabelHeights=heights}
                .navigationTitle(ui("修改成果")).navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction){Button(ui("关闭并保留草稿")){Task{if await model.close(){dismiss()}}}.touchTarget().disabled(model.preventDismiss).accessibilityIdentifier("chat.artifact.edit.close")}}
        }.presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(model.preventDismiss)
            .task{await model.load(admissionAllowed:admissionAllowed())}
            .onDisappear{Task{await model.flushDraft()}}
            .confirmationDialog(ui("放弃这份修改草稿？"),isPresented:$confirmDiscard,titleVisibility:.visible){Button(ui("放弃草稿"),role:.destructive){Task{if await model.discard(){dismiss()}}};Button(ui("取消"),role:.cancel){}}
    }
    private var footer:some View {
        catBottomActionArea {
                    Button {Task{await model.submit(admissionAllowed:admissionAllowed())}} label:{HStack{if model.submitting {ProgressView().tint(catColors.onInk)};catAdaptiveActionTitle(fullTitle:model.submitting ? ui("正在提交") : ui("保存为成果新版本"),compactTitle:model.submitting ? ui("正在提交") : ui("保存新版本")).fontWeight(.semibold)}.frame(maxWidth:.infinity,minHeight:44)}.buttonStyle(catPrimaryButtonStyle()).disabled(!model.canSubmit || !admissionAllowed()).accessibilityLabel(model.submitting ? ui("正在提交原修改，请勿重复发送。") : ui("保存为成果新版本")).accessibilityIdentifier("chat.artifact.edit.save")
                    if model.hasLocalIntentForDisplay || model.submitting || model.state.hasUnresolvedSubmission {
                        let state=draftStatus
                        Text(dynamicTypeSize.isAccessibilitySize ? state.compact : state.full).font(catTypography.Role.caption.font).foregroundStyle(state.attention ? catColors.attention : catColors.secondary).accessibilityLabel(state.full).accessibilityIdentifier("chat.artifact.edit.draftStatus")
                    }
        }
    }
    private func usableViewportHeight(_ geometry:GeometryProxy)->CGFloat {
        // The ScrollView and footer are siblings. UIKit reports the rendered
        // scroll bounds after keyboard layout; a GeometryProxy fallback is
        // already allocated by SwiftUI and must not deduct safe-area again.
        return visibleViewport?.visibleBounds.height ?? geometry.size.height
    }
    private var draftStatus:(compact:String,full:String,attention:Bool) {
        let unknown=model.state.hasUnresolvedSubmission
        let awaiting=ui("原修改待核对，草稿已保存在本机。")
        if let issue=model.draftSaveIssue {
            // Failed persistence is not an in-progress save. Preserve the original
            // operation's unresolved status without claiming the new raw was saved.
            let original=unknown ? ui("保存结果尚未确认。只核对原修改，不重复提交。") : ""
            return (ui("未保存"),ui(issue)+(original.isEmpty ? "" : " "+original),true)
        }
        if model.submitting {return (ui("正在提交"),ui("正在提交原修改，请勿重复发送。"),false)}
        if !model.draftSaved {
            let original=unknown ? ui("保存结果尚未确认。只核对原修改，不重复提交。") : ""
            return (ui("保稿中"),ui("正在保存本地修改草稿…")+(original.isEmpty ? "" : " "+original),false)
        }
        if unknown {
            if model.state.submission?.submittedDraft.content != model.raw {
                return (ui("新稿未提交"),ui("新稿尚未提交；原修改待核对，草稿已保存在本机。"),true)
            }
            return (ui("待核对"),awaiting,true)
        }
        return (ui("已保稿"),ui("修改草稿已保存在本机，尚未提交。"),false)
    }
    private func editor(_ title:String,binding:Binding<String>,id:String,preferredLines:Int,viewportHeight:CGFloat)->some View {
        let font=catTypography.font(size:dynamicTypeSize)
        let labelHeight=measuredLabelHeights[id] ?? catTypography.font(.heading,size:dynamicTypeSize).lineHeight
        let height=catTextViewport.editorHeight(preferred:font.lineHeight*CGFloat(preferredLines)+16,viewport:max(0,viewportHeight-catLayout.pageInset*2),labelHeight:labelHeight,spacing:8,lineHeight:font.lineHeight,textInsets:16)
        return VStack(alignment:.leading,spacing:8){
            Text(title).font(catTypography.Role.heading.font).fixedSize(horizontal:false,vertical:true)
                .background{GeometryReader{geometry in Color.clear.preference(key:ArtifactEditLabelHeightKey.self,value:[id:geometry.size.height])}}
            catTextEditor(text:binding,focused:Binding(get:{focusedField==id},set:{focused in if focused {focusedField=id} else if focusedField==id {focusedField=nil}}),accessibilityLabel:title,accessibilityIdentifier:"chat.artifact.edit."+id+"Field",enabled:model.base != nil && model.canEditLocal,interaction:editorInteraction)
                .frame(height:height).background(catColors.input,in:RoundedRectangle(cornerRadius:12))
        }.id("artifact-edit-field-"+id)
            .background{GeometryReader{geometry in Color.clear.preference(key:ArtifactEditFieldHeightKey.self,value:[id:geometry.size.height])}}
    }
    @ViewBuilder private var status:some View {
        if let submission=model.state.submission {
            switch submission.state {
            case .unknown:Text(ui("保存结果尚未确认。只核对原修改，不重复提交。")).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.artifact.edit.unknown")
            case .applied:if let version=submission.receipt?.artifact.version {Text(ui("人工修改已保存")+" · v\(version)").foregroundStyle(catColors.success).accessibilityIdentifier("chat.artifact.edit.applied")}
            case .rejected,.notSent:Text(ui("此次修改尚未保存，原输入仍保留。请先读取当前成果。")).foregroundStyle(catColors.attention)
            }
        }
        if !model.freshlyRead {Text(ui("显示本机保存的成果信息，尚未完成当前读取。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)}
        if model.state.latest?.editable==false {Text(ui("这份成果当前不能修改，草稿会保留。")).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention)}
        if let issue=model.deliveryIssue {Text(ui(issue)).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.artifact.edit.deliveryIssue")}
        if let error=model.error {Text(ui(error)).foregroundStyle(catColors.attention).textSelection(.enabled).accessibilityIdentifier("chat.artifact.edit.error")}
    }
}

private struct ArtifactEditFieldHeightKey:PreferenceKey {
    static var defaultValue:[String:CGFloat]=[:]
    static func reduce(value:inout [String:CGFloat],nextValue:()->[String:CGFloat]){value.merge(nextValue(),uniquingKeysWith:{_,next in next})}
}
private struct ArtifactEditLabelHeightKey:PreferenceKey {
    static var defaultValue:[String:CGFloat]=[:]
    static func reduce(value:inout [String:CGFloat],nextValue:()->[String:CGFloat]){value.merge(nextValue(),uniquingKeysWith:{_,next in next})}
}
