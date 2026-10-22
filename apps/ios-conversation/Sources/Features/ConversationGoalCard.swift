import SwiftUI

struct ConversationGoalCard:View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key:String)->String {AppLanguage(locale:uiLocale).ui(key)}
    let goal:ConversationGoalProjection
    let busy:Bool
    let refresh:()->Void
    var openPlan:(()->Void)?=nil
    var openActions:(()->Void)?=nil
    var openControl:(()->Void)?=nil
    var openArtifact:((ConversationArtifactProjection)->Void)?=nil
    @State private var expanded=false
    private var status:String {switch goal.state {case .queued:ui("已排队");case .working:ui("正在进行");case .waitingInput:ui("等待反馈");case .completed:ui("已完成");case .failed:ui("需要处理");case .paused:ui("已暂停");case .cancelled:ui("已取消");case .unknown:ui("状态待确认")}}
    var body:some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:10) {
                Text(ui(goal.summary)).textSelection(.enabled)
                if let openPlan {Button(ui("查看计划"),action:openPlan).touchTarget().accessibilityIdentifier("chat.goal.plan."+goal.id)}
                if let openActions {Button(ui("查看审批事项"),action:openActions).touchTarget().accessibilityIdentifier("chat.goal.actions."+goal.id)}
                if let openControl {Button(ui("暂停、恢复或撤回授权"),action:openControl).touchTarget().accessibilityIdentifier("chat.goal.control."+goal.id)}
                ForEach(goal.artifacts) {artifact in
                    VStack(alignment:.leading,spacing:6) {
                        Text(artifact.title+" · v\(artifact.version)").font(catTypography.Role.secondary.font.weight(.medium))
                        Text(artifact.summary).font(catTypography.Role.secondary.font).textSelection(.enabled)
                        if let openArtifact {
                            Button(ui("查看成果")) {openArtifact(artifact)}.touchTarget().accessibilityIdentifier("chat.artifact.open."+artifact.id)
                        } else {
                            DisclosureGroup(ui("成果内容")) {Text(artifact.content).textSelection(.enabled)}
                        }
                    }.accessibilityElement(children:.contain).accessibilityIdentifier("chat.artifact."+artifact.id)
                }
                Button(ui("读取最新进展"),action:refresh).touchTarget().disabled(busy)
                Text(ui("最近读取 · ")+goal.updatedAt.formatted()).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
            }.padding(.top,10)
        } label:{catAdaptiveHeader(title:goal.title,detail:status,symbol:"circle.dotted",titleRole:.secondary,weight:.medium)}
            .padding(14).background(catColors.panel,in:RoundedRectangle(cornerRadius:16)).accessibilityElement(children:.contain).accessibilityIdentifier("chat.goal.\(goal.id)")
    }
}
