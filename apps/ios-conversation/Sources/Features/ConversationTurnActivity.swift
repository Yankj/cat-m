import SwiftUI

/// Presentation of persisted turn/tool facts only. This does not infer reasoning,
/// tool effects, task completion, elapsed time, or any permission to execute.
struct ConversationTurnActivitySnapshot:Identifiable,Equatable {
    enum Phase:Equatable {case sending,waiting,writing,processing,ended,needsReview
        var summaryKey:String {
            switch self {
            case .sending:return "正在发送…"
            case .waiting:return "正在等待回复"
            case .writing:return "正在回复…"
            case .processing:return "正在处理请求…"
            case .ended:return "本次回复已结束"
            case .needsReview:return "处理进展待核对"
            }
        }
    }
    struct ToolFact:Identifiable,Equatable {
        enum State:Equatable {case pending,received,needsReview
            var labelKey:String {switch self {case .pending:return "等待工具回执";case .received:return "已收到工具回执";case .needsReview:return "工具回执待核对"}}
        }
        let id:UUID
        let name:String
        let state:State
        let sourceMessageIDs:[UUID]
        var titleKey:String {
            switch name {
            case "delegate_task","delegate_plan_v1":return "创建工作计划"
            case "delegate_sources_v1":return "创建有来源工作"
            case "agent_status":return "读取任务进展"
            case "present_cgui_v1":return "准备交互内容"
            case "propose_memory_v1":return "提取记忆候选"
            case "revise_current_report_v1",ConversationRevisionWorkCodec.toolName:return "核对修改请求"
            default:return "工具处理"
            }
        }
    }
    let id:UUID
    let phase:Phase
    let tools:[ToolFact]
    let hasVisibleText:Bool
    let sourceMessageIDs:[UUID]
}

enum ConversationTurnActivityProjection {
    static func snapshots(session:ConversationSession,rows:[ConversationTimelineProjection.Row]?=nil)->[ConversationTurnActivitySnapshot] {
        let rows=rows ?? ConversationTimelineProjection.rows(messages:session.messages,turns:session.turns)
        let counts=Dictionary(grouping:session.turns,by:{$0.id}).mapValues(\.count)
        let grouped=Dictionary(grouping:rows.compactMap {row in row.turnID.map{($0,row)}},by:{$0.0})
        return session.turns.compactMap {turn in
            guard counts[turn.id]==1,turn.request.operationID==turn.id,
                  turn.request.conversationID==session.conversationID,turn.request.scope==session.scope else {return nil}
            let owned=grouped[turn.id]?.map(\.1) ?? []
            let tools=owned.filter{$0.message.role == .tool || $0.message.toolName != nil}.map {row in
                let state:ConversationTurnActivitySnapshot.ToolFact.State
                switch row.presentation {
                case .processPending:state = .pending
                case .message:state = row.message.role == .tool && row.sourceMessageIDs.count==2 ? .received:.needsReview
                case .fallback:state = .needsReview
                }
                return ConversationTurnActivitySnapshot.ToolFact(id:row.id,name:row.message.toolName ?? "",state:state,sourceMessageIDs:row.sourceMessageIDs)
            }
            let hasText=owned.contains {row in row.message.role == .assistant && row.message.toolName==nil && row.message.toolCallID==nil && !row.message.content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
            let phase:ConversationTurnActivitySnapshot.Phase
            switch turn.state {
            case .dispatched:phase = .sending
            case .running:
                if tools.contains(where:{$0.state == .needsReview}) {phase = .needsReview}
                else if tools.contains(where:{$0.state == .pending}) {phase = .processing}
                else {phase = hasText ? .writing:.waiting}
            case .completed:
                guard !tools.isEmpty else {return nil}
                phase = tools.allSatisfy{$0.state == .received} ? .ended:.needsReview
            case .failed,.unknown:
                // Existing recovery rows retain errors and the original GET action.
                guard !tools.isEmpty else {return nil};phase = .needsReview
            case .notSent,.cancelledBeforeSend:return nil
            }
            return ConversationTurnActivitySnapshot(id:turn.id,phase:phase,tools:tools,hasVisibleText:hasText,sourceMessageIDs:owned.flatMap(\.sourceMessageIDs))
        }
    }
}

@MainActor struct ConversationTurnActivity:View {
    let activity:ConversationTurnActivitySnapshot
    @State private var expanded=false
    @Environment(\.locale) private var locale
    private func ui(_ key:String)->String {AppLanguage(locale:locale).ui(key)}
    /// Live send/wait/write/process is already shown by PendingThinkingRow / LivePhasedAnswerView
    /// (presence + …). Emitting another "正在…" label next to them is the multi-status pile.
    private var inFlight:Bool {
        switch activity.phase {case .sending,.waiting,.writing,.processing:return true;default:return false}
    }
    var body:some View {
        Group {
            if inFlight {
                // PendingThinkingRow / LivePhasedAnswerView already owns the live visual.
                EmptyView()
            } else if activity.tools.isEmpty {
                Label(ui(activity.phase.summaryKey),systemImage:activity.phase == .needsReview ? "exclamationmark.circle":"checkmark.circle")
                    .font(CatpawTypography.Role.secondary.font)
                    .foregroundStyle(activity.phase == .needsReview ? CatpawColors.attention:CatpawColors.secondary)
                    .accessibilityIdentifier("chat.activity.summary."+activity.id.uuidString)
            } else {
                VStack(alignment:.leading,spacing:0) {
                    Button {expanded.toggle()} label:{
                        HStack(spacing:8) {
                            Label(ui(activity.phase.summaryKey),systemImage:activity.phase == .needsReview ? "exclamationmark.circle":"checklist")
                                .lineLimit(1)
                            Spacer(minLength:0)
                            Image(systemName:expanded ? "chevron.up":"chevron.down").accessibilityHidden(true)
                        }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(CatpawPressButtonStyle())
                        .accessibilityLabel(ui(activity.phase.summaryKey))
                        .accessibilityValue(expanded ? ui("已展开"):ui("已收起"))
                        .accessibilityHint(ui("查看本次工具记录"))
                        .accessibilityIdentifier("chat.activity.toggle."+activity.id.uuidString)
                    if expanded {
                        VStack(alignment:.leading,spacing:8) {
                            ForEach(activity.tools) {tool in
                                VStack(alignment:.leading,spacing:4) {
                                    Text(ui(tool.titleKey))
                                    Text(ui(tool.state.labelKey)).font(CatpawTypography.Role.caption.font)
                                }.accessibilityElement(children:.combine)
                                    .accessibilityIdentifier("chat.activity.tool."+tool.id.uuidString)
                            }
                        }.padding(.top,8)
                    }
                }.font(CatpawTypography.Role.secondary.font)
                    .foregroundStyle(activity.phase == .needsReview ? CatpawColors.attention:CatpawColors.secondary)
            }
        }
        .accessibilityElement(children:.contain)
        .accessibilityIdentifier("chat.activity."+activity.id.uuidString)
        .onChange(of:activity.id){_,_ in expanded=false}
    }
}
