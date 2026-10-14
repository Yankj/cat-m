import SwiftUI

/// A value reader of one immutable version. Task, account and HTTP authority remain outside this view.
@MainActor struct ConversationArtifactReaderView:View {
    let goal:ConversationGoalProjection
    let selectedArtifact:ConversationArtifactIdentity
    private let openEdit:((ConversationArtifactIdentity)->Void)?
    private let continueArtifact:((ConversationArtifactContinuationMode,ConversationArtifactIdentity)->Void)?
    private let reading:ConversationArtifactReading?
    private let failure:String?
    @State private var sourcesPresented=false
    @Environment(\.locale) private var locale
    private enum SourceEntry:Hashable {case footer,toolbar}
    @State private var sourceEntry:SourceEntry = .footer
    @AccessibilityFocusState private var sourceFocused:SourceEntry?
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    init(goal:ConversationGoalProjection,selectedArtifact:ConversationArtifactIdentity,openEdit:((ConversationArtifactIdentity)->Void)?=nil,continueArtifact:((ConversationArtifactContinuationMode,ConversationArtifactIdentity)->Void)?=nil) {
        self.goal=goal;self.selectedArtifact=selectedArtifact;self.openEdit=openEdit;self.continueArtifact=continueArtifact
        do {reading=try ConversationArtifactReading.resolve(goal:goal,selected:selectedArtifact);failure=nil}
        catch {reading=nil;failure=error.localizedDescription}
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                if let reading {
                    VStack(alignment:.leading,spacing:10) {
                        CatpawVersionedTitle(title:reading.title,version:"v\(reading.identity.version)",titleAccessibilityIdentifier:"chat.artifact.reader.title",versionAccessibilityIdentifier:"chat.artifact.reader.version")
                        if !reading.summary.isEmpty {Text(verbatim:reading.summary).font(.subheadline).foregroundStyle(CatpawColors.secondary).textSelection(.enabled)}
                    }
                    // Receipt links are separate controls. Report text never executes Markdown resources.
                    Text(verbatim:reading.content).font(.body).lineSpacing(6).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).accessibilityIdentifier("chat.artifact.reader.content")
                    if isUserRevision {Text(ui("你编辑的版本；来源保留原资料快照，新增内容尚未重新核验。")).font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.artifact.reader.userRevision")}
                    if let openEdit {Button(ui("编辑成果")){openEdit(reading.identity)}.touchTarget().accessibilityIdentifier("chat.artifact.reader.edit")}
                    if let continueArtifact {
                        VStack(alignment:.leading,spacing:12) {
                            Button(ui("请 Agent 修改这版")){continueArtifact(.reviseReport,reading.identity)}.touchTarget().accessibilityIdentifier("chat.artifact.reader.revise")
                            Button(ui("针对这版追问")){continueArtifact(.explainReport,reading.identity)}.touchTarget().accessibilityIdentifier("chat.artifact.reader.explain")
                        }
                    }
                    switch reading.sourceStatus {
                    case .none:Text(ui("这份成果暂无可展示的网页读取来源。")).font(.footnote).foregroundStyle(CatpawColors.secondary)
                    case .unverified:Text(ui("来源信息尚未验证，原正文仍可阅读。")).font(.footnote).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.artifact.reader.unverifiedSources")
                    case .verified:
                        Button(ui("查看已读来源")){sourceEntry = .footer;sourcesPresented=true}.touchTarget().accessibilityFocused($sourceFocused,equals:.footer).accessibilityIdentifier("chat.artifact.reader.sources")
                    }
                    VStack(alignment:.leading,spacing:8) {
                        if let updated=reading.updatedAt {Text(ui("成果更新时间")+" · "+updated.formatted(date:.abbreviated,time:.standard)).accessibilityIdentifier("chat.artifact.reader.updatedAt")}
                        else {Text(ui("成果更新时间未提供"))}
                        Text(ui("最近读取")+" · "+reading.observedAt.formatted(date:.abbreviated,time:.standard)).accessibilityIdentifier("chat.artifact.reader.observedAt")
                    }.font(.footnote).foregroundStyle(CatpawColors.secondary)
                    DisclosureGroup {
                        VStack(alignment:.leading,spacing:12) {
                            Text(ui("成果编号")+" · "+reading.identity.artifactID).textSelection(.enabled)
                            Text("SHA-256 "+reading.identity.contentHash).textSelection(.enabled).accessibilityIdentifier("chat.artifact.reader.hash")
                            ForEach(reading.history) {identity in
                                if identity==reading.identity {Text(ui("当前阅读版本")+" · v\(identity.version)")}
                                else {NavigationLink(destination:ConversationArtifactReaderView(goal:goal,selectedArtifact:identity,openEdit:openEdit,continueArtifact:continueArtifact)) {Text(ui("阅读版本")+" · v\(identity.version)")}.touchTarget().accessibilityIdentifier("chat.artifact.reader.history.v\(identity.version)")}
                            }
                        }.font(.footnote).padding(.top,10)
                    } label:{Text(ui("版本与核对信息")).accessibilityIdentifier("chat.artifact.reader.history")}
                } else {Text(failure.map{ui($0)} ?? ui("此成果版本尚未保存在本机。请返回原工作读取。")).foregroundStyle(CatpawColors.attention).accessibilityIdentifier("chat.artifact.reader.unavailable")}
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
        }.background(CatpawColors.background).accessibilityIdentifier("chat.artifact.reader.viewport").navigationTitle(ui("成果")).navigationBarTitleDisplayMode(.inline)
            .toolbar {if let reading {ToolbarItemGroup(placement:.primaryAction) {
                if let openEdit {Button {openEdit(reading.identity)} label:{Label(ui("编辑成果"),systemImage:"square.and.pencil")}.touchTarget().accessibilityLabel(ui("编辑成果")).accessibilityIdentifier("chat.artifact.reader.edit.toolbar")}
                if let continueArtifact {
                    Menu {
                        Button(ui("请 Agent 修改这版")){continueArtifact(.reviseReport,reading.identity)}.accessibilityIdentifier("chat.artifact.reader.revise.menu")
                        Button(ui("针对这版追问")){continueArtifact(.explainReport,reading.identity)}.accessibilityIdentifier("chat.artifact.reader.explain.menu")
                    } label:{Label(ui("针对当前版本继续"),systemImage:"bubble.left.and.text.bubble.right")}.touchTarget().accessibilityIdentifier("chat.artifact.reader.continue.toolbar")
                }
                if !reading.sources.isEmpty {Button {sourceEntry = .toolbar;sourcesPresented=true} label:{Label(ui("查看已读来源"),systemImage:"doc.text.magnifyingglass")}.touchTarget().accessibilityLabel(ui("查看已读来源")).accessibilityFocused($sourceFocused,equals:.toolbar)}
                ShareLink(item:reading.content){Label(ui("分享当前成果"),systemImage:"square.and.arrow.up")}.touchTarget().accessibilityLabel(ui("分享当前成果"))
            }}}
            .catpawSheet(isPresented:$sourcesPresented,onDismiss:{sourceFocused=sourceEntry}) {
                if let reading {ConversationArtifactSourceSheet(reading:reading)}
            }
    }
    private var isUserRevision:Bool {
        let artifact=(goal.artifacts+goal.artifactHistory).first{ConversationArtifactIdentity($0)==selectedArtifact}
        guard let body=artifact?.body,let root=try? JSONSerialization.jsonObject(with:Data(body.utf8)) as? [String:Any],let data=root["data"] as? [String:Any] else {return false}
        return data["source"] as? String=="user_revision"
    }
}
@MainActor private struct ConversationArtifactSourceSheet:View {
    let reading:ConversationArtifactReading
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    var body:some View {
        NavigationStack {
            List(reading.sources) {source in
                NavigationLink {
                    ConversationArtifactSourceDetail(source:source,identity:reading.identity)
                } label:{VStack(alignment:.leading,spacing:6) {
                    Text(verbatim:source.finalURL.host ?? source.sourceID).font(.body)
                    Text(verbatim:source.finalURL.absoluteString).font(.footnote).foregroundStyle(CatpawColors.secondary).fixedSize(horizontal:false,vertical:true)
                    Text(ui("读取时间")+" · "+source.readAt.formatted(date:.abbreviated,time:.standard)).font(.footnote).foregroundStyle(CatpawColors.secondary)
                }.padding(.vertical,6)}.accessibilityIdentifier("chat.artifact.source."+source.sourceID)
            }.navigationTitle(ui("已读来源")).navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction){Button(ui("完成")){dismiss()}.accessibilityIdentifier("chat.artifact.sources.close")}}
        }.presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium,.large]).presentationDragIndicator(.visible)
    }
}
@MainActor private struct ConversationArtifactSourceDetail:View {
    let source:ConversationArtifactSource
    let identity:ConversationArtifactIdentity
    @Environment(\.locale) private var locale
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:20) {
            CatpawVersionedTitle(title:source.finalURL.host ?? source.sourceID,version:ui("对应成果版本")+" · v\(identity.version)",versionAccessibilityIdentifier:"chat.artifact.source.version")
            Text(ui("读取时间")+" · "+source.readAt.formatted(date:.abbreviated,time:.standard)).textSelection(.enabled)
            field(ui("原始网址"),source.requestedURL.absoluteString)
            field(ui("实际读取网址"),source.finalURL.absoluteString)
            Link(ui("打开实际读取网页"),destination:source.finalURL).touchTarget().accessibilityIdentifier("chat.artifact.source.open")
            if let excerpt=source.excerpt,!excerpt.isEmpty {field(ui("读取摘录"),excerpt)}
            DisclosureGroup(ui("读取回执信息")) {VStack(alignment:.leading,spacing:8) {
                Text(ui("来源编号")+" · "+source.sourceID)
                Text(ui("读取编号")+" · "+source.readID.uuidString.lowercased())
                Text("SHA-256 "+source.contentHash)
            }.font(.footnote).textSelection(.enabled).padding(.top,8)}
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading)}.navigationTitle(ui("来源详情")).navigationBarTitleDisplayMode(.inline)
    }
    private func field(_ title:String,_ content:String)->some View {VStack(alignment:.leading,spacing:8){Text(title).font(.headline);Text(verbatim:content).textSelection(.enabled)}}
}
