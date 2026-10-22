import SwiftUI

/// A review of an explicit user choice. The host owns the draft, exact original
/// request and durable admission operation; this view never creates or retries it.
@MainActor struct ConversationAcceptedWorkReviewView:View {
    let originalText:String
    let revisionTargetTitle:String?
    let lockedToolPolicy:ConversationAcceptedWorkToolPolicy?
    let sourceLimitFloor:Int
    let capability:ConversationAcceptedWorkCapability
    @Binding var options:ConversationAcceptedWorkOptions
    let saving:Bool
    let error:String?
    let confirm:()->Void
    let close:()->Void
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var detailsExpanded=false

    init(originalText:String,capability:ConversationAcceptedWorkCapability,options:Binding<ConversationAcceptedWorkOptions>,saving:Bool,error:String?,confirm:@escaping()->Void,close:@escaping()->Void,revisionTargetTitle:String?=nil,lockedToolPolicy:ConversationAcceptedWorkToolPolicy?=nil,sourceLimitFloor:Int=0){self.revisionTargetTitle=revisionTargetTitle;self.lockedToolPolicy=lockedToolPolicy;self.sourceLimitFloor=sourceLimitFloor;
        self.originalText=originalText;self.capability=capability;_options=options
        self.saving=saving;self.error=error;self.confirm=confirm;self.close=close
    }
    private func ui(_ key:String,arguments:[String]=[])->String {AppLanguage(locale:locale).ui(key,arguments:arguments)}
    private func count(_ value:Int)->String {ui("{0} 次",arguments:[value.formatted(.number.locale(locale))])}
    private var budget:String {ui("{0} 秒",arguments:[(Double(options.executionBudgetMilliseconds)/1000).formatted(.number.locale(locale).precision(.fractionLength(0...3)))])}
    private var deadline:String {
        let formatter=DateFormatter();formatter.locale=locale;formatter.timeZone=timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMMdjmmsszzzz")
        return formatter.string(from:options.notAfter)
    }
    private var scopeTitle:String {options.toolPolicy == .localOutput ? ui("仅整理已提供文字") : ui("读取我给的公开链接")}
    private var validationMessage:String? {
        guard capability.available else {return ui("当前服务尚不支持有限工作受理，草稿会保留。")}
        if options.toolPolicy == .publicSources && !capability.publicSourcesAvailable {return ui("当前服务不支持读取公开链接，请改为仅整理已提供文字。")}
        if let lockedToolPolicy,options.toolPolicy != lockedToolPolicy || options.sourceLimit<sourceLimitFloor {return ui("工作约定超出当前服务范围，请调整后确认。")}
        let remaining=options.notAfter.timeIntervalSinceNow
        if !remaining.isFinite || remaining<=0 {return ui("截止时间已过，请选择未来时间。")}
        if remaining>Double(capability.maxLifetimeSeconds) {return ui("截止时间须在未来 {0} 小时内。",arguments:[(Double(capability.maxLifetimeSeconds)/3600).formatted(.number.locale(locale))])}
        if options.executionBudgetMilliseconds<1 || options.executionBudgetMilliseconds>capability.maxBudgetMilliseconds || options.modelLimit<0 || options.modelLimit>capability.maxModel || options.sourceLimit<0 || options.sourceLimit>capability.maxSource || options.toolPolicy == .localOutput && options.sourceLimit != 0 {return ui("工作约定超出当前服务范围，请调整后确认。")}
        if Double(options.executionBudgetMilliseconds)>remaining*1000 {return ui("累计执行预算超过截止前的剩余时间，请调整约定。")}
        return nil
    }
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                ScrollView {
                    VStack(alignment:.leading,spacing:catLayout.sectionGap) {
                        Text(ui("尚未发送；确认后才提交原请求。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.acceptedWork.notSent")
                        if let revisionTargetTitle {
                            VStack(alignment:.leading,spacing:12) {
                                SectionHeading(title:ui("本次修改的成果"))
                                Text(verbatim:revisionTargetTitle).font(catTypography.Role.body.font).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.revisionWork.target")
                                Text(ui("本次修改沿用原任务和所选版本，需要新的期限、预算与执行范围；不会沿用原工作的额度。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.revisionWork.newAuthority")
                            }
                        }
                        VStack(alignment:.leading,spacing:12) {
                            SectionHeading(title:ui("原请求"))
                            Text(verbatim:originalText).font(catTypography.Role.body.font).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).accessibilityIdentifier("chat.acceptedWork.originalText")
                        }
                        scopeSelection
                        VStack(alignment:.leading,spacing:12) {
                            SectionHeading(title:ui("截至时间"))
                            // Do not clamp an expired draft to a new date. The host
                            // validates the actual clock again before admission.
                            catAdaptiveActions {
                                DatePicker(ui("截至日期"),selection:$options.notAfter,displayedComponents:[.date]).labelsHidden().datePickerStyle(.compact).font(catTypography.Role.body.font).touchTarget().accessibilityLabel(ui("截至日期")).accessibilityIdentifier("chat.acceptedWork.deadlineDate").disabled(saving)
                                DatePicker(ui("截至时刻"),selection:$options.notAfter,displayedComponents:[.hourAndMinute]).labelsHidden().datePickerStyle(.compact).font(catTypography.Role.body.font).touchTarget().accessibilityLabel(ui("截至时刻")).accessibilityIdentifier("chat.acceptedWork.deadlineTime").disabled(saving)
                            }
                        }
                        numberChoice(title:ui("最多模型次数"),value:count(options.modelLimit),identifier:"modelLimit") {
                            Stepper(ui("最多模型次数"),value:$options.modelLimit,in:0...max(0,capability.maxModel)).labelsHidden().touchTarget().accessibilityLabel(ui("最多模型次数")).accessibilityValue(count(options.modelLimit)).accessibilityIdentifier("chat.acceptedWork.modelLimit").disabled(saving)
                        }
                        DisclosureGroup(isExpanded:$detailsExpanded) {
                            VStack(alignment:.leading,spacing:24) {
                                numberChoice(title:ui("累计执行预算"),value:budget,identifier:"executionBudget") {
                                    Stepper(ui("累计执行预算"),value:$options.executionBudgetMilliseconds,in:1...max(1,capability.maxBudgetMilliseconds),step:1000).labelsHidden().touchTarget().accessibilityLabel(ui("累计执行预算")).accessibilityValue(budget).accessibilityIdentifier("chat.acceptedWork.executionBudget").disabled(saving)
                                }
                                if options.toolPolicy == .publicSources {
                                    numberChoice(title:ui("最多来源次数"),value:count(options.sourceLimit),identifier:"sourceLimit") {
                                        Stepper(ui("最多来源次数"),value:$options.sourceLimit,in:min(sourceLimitFloor,max(0,capability.maxSource))...max(0,capability.maxSource)).labelsHidden().touchTarget().accessibilityLabel(ui("最多来源次数")).accessibilityValue(count(options.sourceLimit)).accessibilityIdentifier("chat.acceptedWork.sourceLimit").disabled(saving)
                                    }
                                }
                                Text(ui("执行预算是本次工作的累计上限，暂停与恢复不会延长期限或补回额度。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal:false,vertical:true)
                                Text(ui("模型次数只约束已受理的这份工作；理解原请求的本次对话调用另受现有许可约束。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal:false,vertical:true)
                            }.padding(.top,12)
                        } label:{Text(ui("更多工作约定")).font(catTypography.Role.heading.font).fixedSize(horizontal:false,vertical:true).frame(minHeight:44,alignment:.leading).accessibilityIdentifier("chat.acceptedWork.details")}
                            .accessibilityElement(children:.contain)
                        completeSummary
                        if let validationMessage {Text(verbatim:validationMessage).font(catTypography.Role.secondary.font).foregroundStyle(catColors.attention).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.acceptedWork.validation")}
                        if let error {Text(ui(error)).font(catTypography.Role.secondary.font).foregroundStyle(catColors.attention).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).accessibilityIdentifier("chat.acceptedWork.error")}
                    }.padding(catLayout.pageInset).frame(maxWidth:catLayout.readableWidth,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)
                }.background(catColors.background).accessibilityIdentifier("chat.acceptedWork.viewport")
                catBottomActionArea {
                    Button {
                        guard !saving,validationMessage == nil,!originalText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
                        confirm()
                    } label:{
                        HStack(spacing:8) {
                            if saving {ProgressView().tint(catColors.onInk).accessibilityHidden(true)}
                            catAdaptiveActionTitle(fullTitle:saving ? ui("正在确认工作约定") : ui("确认并提交原请求"),compactTitle:saving ? ui("正在提交") : ui("确认")).frame(maxWidth:.infinity)
                        }.frame(maxWidth:.infinity,minHeight:44)
                    }.buttonStyle(catPrimaryButtonStyle()).disabled(saving || validationMessage != nil || originalText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityLabel(saving ? ui("正在确认工作约定") : ui("确认并提交原请求")).accessibilityIdentifier("chat.acceptedWork.confirm")
                }
            }.font(catTypography.Role.body.font).foregroundStyle(catColors.ink)
                .navigationTitle(ui("确认工作约定")).navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction){Button(ui("关闭"),action:close).touchTarget().accessibilityLabel(ui("关闭并保留草稿")).accessibilityIdentifier("chat.acceptedWork.close")}}
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private var scopeSelection:some View {
        VStack(alignment:.leading,spacing:12) {
            SectionHeading(title:ui("执行范围"))
            if lockedToolPolicy==nil || lockedToolPolicy == .localOutput {policyChoice(.localOutput,title:ui("仅整理已提供文字"),identifier:"localOutput")}
            if capability.publicSourcesAvailable && (lockedToolPolicy==nil || lockedToolPolicy == .publicSources) {
                policyChoice(.publicSources,title:ui("读取我给的公开链接"),identifier:"publicSources")
            } else if options.toolPolicy == .publicSources {Text(verbatim:scopeTitle).font(catTypography.Role.body.font).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("chat.acceptedWork.scope")}
            if options.toolPolicy == .publicSources {Text(ui("只读取原请求中明确提供的公开链接，不自主搜索。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal:false,vertical:true)}
            Text(ui("只生成本地文本成果，不执行外部写入。")).font(catTypography.Role.secondary.font).foregroundStyle(catColors.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func policyChoice(_ policy:ConversationAcceptedWorkToolPolicy,title:String,identifier:String)->some View {
        Button {
            guard !saving,lockedToolPolicy==nil || lockedToolPolicy==policy else {return}
            options.toolPolicy=policy
            if policy == .localOutput {options.sourceLimit=0}
        } label:{
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Image(systemName:options.toolPolicy == policy ? "checkmark.circle.fill" : "circle").foregroundStyle(options.toolPolicy == policy ? catColors.accent : catColors.secondary).accessibilityHidden(true)
                Text(verbatim:title).font(catTypography.Role.body.font).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
            }.padding(12).frame(maxWidth:.infinity,minHeight:44,alignment:.leading).background(options.toolPolicy == policy ? catColors.input : catColors.background,in:RoundedRectangle(cornerRadius:catLayout.controlRadius))
        }.buttonStyle(catPressButtonStyle()).disabled(saving).accessibilityAddTraits(options.toolPolicy == policy ? .isSelected : []).accessibilityIdentifier("chat.acceptedWork.scope."+identifier)
    }
    private func numberChoice<Control:View>(title:String,value:String,identifier:String,@ViewBuilder control:()->Control)->some View {
        VStack(alignment:.leading,spacing:8) {
            Text(verbatim:title).font(catTypography.Role.heading.font).fixedSize(horizontal:false,vertical:true)
            catAdaptiveActions {
                Text(verbatim:value).font(catTypography.Role.body.font).monospacedDigit().fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("chat.acceptedWork."+identifier+"Value")
                control()
            }
        }.accessibilityElement(children:.contain)
    }
    private var completeSummary:some View {
        VStack(alignment:.leading,spacing:12) {
            SectionHeading(title:ui("受理前完整核对"))
            summary(ui("执行范围"),scopeTitle,id:"scope")
            summary(ui("截至时间"),deadline,id:"deadline")
            summary(ui("最多模型次数"),count(options.modelLimit),id:"modelLimit")
            summary(ui("累计执行预算"),budget,id:"executionBudget")
            summary(ui("最多来源次数"),count(options.sourceLimit),id:"sourceLimit")
        }
    }
    private func summary(_ title:String,_ value:String,id:String)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(verbatim:title).font(catTypography.Role.caption.font).foregroundStyle(catColors.secondary)
            Text(verbatim:value).font(catTypography.Role.body.font).fixedSize(horizontal:false,vertical:true)
        }.accessibilityElement(children:.combine).accessibilityIdentifier("chat.acceptedWork.summary."+id)
    }
}
