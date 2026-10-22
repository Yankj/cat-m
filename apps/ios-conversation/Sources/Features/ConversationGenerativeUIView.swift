import SwiftUI
import Charts

/// Only complete registered tool results may become interactive presentation.
/// This view has no backend, approval or effect port. All controls are local.
@MainActor struct ConversationGenerativeUIMessageView: View {
    let message: ConversationTranscriptMessage
    let session: ConversationSession
    var stateService: ConversationGenerativeUIStateService? = nil
    var onInteraction: () -> Void = {}
    @Environment(\.locale) private var locale
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        if !message.complete || message.role != .tool {
            Text(ui("正在准备交互内容…")).font(.footnote).foregroundStyle(catColors.secondary)
        } else {
            switch CGUIRegistry.decode(Data(message.content.utf8)) {
            case .ready(let block):
                if matches(block.identity) {
                    ConversationGenerativeUIBlockView(block: block,stateService:stateService,onInteraction:onInteraction)
                        .id(stateService.flatMap { try? CGUILocalStateIdentity(scope:$0.scope,block:block).recordID }?.uuidString ?? block.identity.conversationID.uuidString + ":" + block.identity.turnID.uuidString + ":" + block.id + ":" + String(block.identity.dataRevision))
                } else { Text(ui("交互内容与当前对话不匹配，未启用操作。")).font(.footnote) }
            case .fallback(let fallback):
                VStack(alignment: .leading, spacing: 8) {
                    Text(ui("交互内容暂不可用")).font(.subheadline.weight(.medium))
                    Text(ui(fallback.text)).textSelection(.enabled)
                }.accessibilityIdentifier("chat.genui.fallback")
            }
        }
    }
    private func matches(_ identity: CGUIIdentity) -> Bool {
        guard identity.conversationID == session.conversationID,
              identity.blockID == message.toolCallID,
              session.turns.contains(where: { $0.id == identity.turnID }),
              message.id == stableID("conversation-tool-result-\(identity.turnID)-\(identity.blockID)") else { return false }
        if let artifact = identity.artifact {
            return session.goals.values.flatMap { $0.artifacts + $0.artifactHistory }.contains {
                $0.id == artifact.id && $0.version == artifact.version && $0.contentHash == artifact.contentHash
            }
        }
        return true
    }
}

@MainActor struct ConversationGenerativeUIBlockView: View {
    let block: CGUIBlock
    var onInteraction: () -> Void = {}
    @StateObject private var editor: ConversationGenerativeUIEditor
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var fullTable = false
    init(block:CGUIBlock,stateService:ConversationGenerativeUIStateService? = nil,onInteraction:@escaping () -> Void = {}) {
        self.block=block;self.onInteraction=onInteraction
        _editor=StateObject(wrappedValue:ConversationGenerativeUIEditor(block:block,service:stateService))
    }
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(block.title).font(.body.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if !block.summary.isEmpty { Text(block.summary).fixedSize(horizontal: false, vertical: true) }
            if editor.loading { Text(ui("正在恢复本地选择…")).font(.footnote).foregroundStyle(catColors.secondary) }
            if editor.dataChanged { Text(ui("数据版本已更新；旧版本输入仍保留，当前使用新数据。")).font(.footnote).foregroundStyle(catColors.secondary) }
            if let issue=editor.issue { Text(localIssueText(issue)).font(.footnote).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.genui.localState.issue") }
            if let table = block.table {
                ConversationGenerativeUITableView(table: table, preview: true,state:editor.stateBinding,onInteraction:onInteraction,onReset:editor.reset).disabled(editor.loading)
                Button(ui("查看完整表")) { fullTable = true }.touchTarget().disabled(editor.loading).accessibilityIdentifier("chat.genui.fullTable")
                    .sheet(isPresented: $fullTable) {
                        NavigationStack {
                            ScrollView { ConversationGenerativeUITableView(table: table, preview: false,state:editor.stateBinding,onInteraction:onInteraction,onReset:editor.reset).padding(20).disabled(editor.loading) }
                                .navigationTitle(block.title).navigationBarTitleDisplayMode(.inline)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ui("完成")) { fullTable = false } } }
                        }.presentationDetents([.large]).presentationDragIndicator(.visible)
                    }
            }
            if let chart = block.chart { ConversationGenerativeUIChartView(chart: chart,state:editor.stateBinding,onInteraction:onInteraction,onReset:editor.reset).disabled(editor.loading) }
            if let calculator = block.calculator {
                if let duration = calculator.duration { ConversationDurationCalculatorView(input: duration,values:editor.binding(\.durationValues),onInteraction:onInteraction,onReset:editor.reset).disabled(editor.loading) }
                if let weighted = calculator.weighted { ConversationWeightedCalculatorView(input: weighted,weights:editor.binding(\.weightValues),onInteraction:onInteraction,onReset:editor.reset).disabled(editor.loading) }
            }
            DisclosureGroup(ui("来源与说明")) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(block.sources) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.label).font(.subheadline.weight(.medium))
                            if source.kind == .assumption { Text(ui("人工假设")).font(.footnote) }
                            if let reference = source.reference { Text(reference).font(.footnote).textSelection(.enabled) }
                        }
                    }
                }.foregroundStyle(catColors.secondary).padding(.top, 8)
            }.accessibilityIdentifier("chat.genui.sources")
        }.font(.body).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(catColors.ink).background(catColors.input, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
            .task {await editor.load()}
            .onDisappear {editor.disappear()}
            .onChange(of:scenePhase) {_,phase in if phase != .active {Task {await editor.flush()}}}
    }
    private func localIssueText(_ issue:ConversationGenerativeUILocalIssue) -> String {
        switch issue {
        case .restoreFailed:return ui("本地选择暂时无法恢复，原记录已保留；点重置后可重新保存。")
        case .readFailed:return ui("本地选择读取失败，原记录已保留。")
        case .saveFailed:return ui("本地选择尚未保存，输入仍保留。")
        }
    }
}

private enum ConversationGenerativeUILocalIssue {case restoreFailed,readFailed,saveFailed}
/// One editor drives the compact card and its detail sheet, including unfinished numeric text.
@MainActor private final class ConversationGenerativeUIEditor: ObservableObject {
    @Published private(set) var state:CGUILocalState
    @Published private(set) var loading:Bool
    @Published private(set) var issue:ConversationGenerativeUILocalIssue?
    @Published private(set) var dataChanged=false
    private let block:CGUIBlock
    private let service:ConversationGenerativeUIStateService?
    private var handle:CGUILocalStateHandle?
    private var sequence:UInt64=0
    private var generation=UUID()
    private var saveTask:Task<Void,Never>?
    private var closingTask:Task<Void,Never>?
    private var explicitReset=false
    init(block:CGUIBlock,service:ConversationGenerativeUIStateService?) {self.block=block;self.service=service;state = .defaults(for:block);loading=service != nil}
    var stateBinding:Binding<CGUILocalState> {Binding(get:{self.state},set:{self.replace($0)})}
    func binding<Value>(_ keyPath:WritableKeyPath<CGUILocalState,Value>) -> Binding<Value> {
        Binding(get:{self.state[keyPath:keyPath]},set:{value in var copy=self.state;copy[keyPath:keyPath]=value;self.replace(copy)})
    }
    func load() async {
        if let closingTask {await closingTask.value;self.closingTask=nil}
        guard let service,handle == nil else {return}
        guard !Task.isCancelled else {return}
        let epoch=UUID();generation=epoch;loading=true
        do {
            let restored=try await service.open(block:block)
            guard generation==epoch,!Task.isCancelled else {return}
            handle=restored.handle;state=restored.initialState;dataChanged=restored.dataChanged
            issue=restored.readIssue == nil ? nil : .restoreFailed
            loading=false
        } catch is CancellationError {if generation==epoch {loading=false}}
        catch {if generation==epoch {loading=false;issue = .readFailed}}
    }
    func replace(_ value:CGUILocalState) {
        guard !loading else {return}
        state=value;sequence += 1
        schedule()
    }
    func reset() {explicitReset=true;replace(.defaults(for:block))}
    private func schedule() {
        saveTask?.cancel()
        guard let service,let handle else {return}
        let value=state,edit=sequence,epoch=generation,reset=explicitReset
        saveTask=Task {
            do {
                try await service.stage(handle:handle,state:value,editSequence:edit,explicitlyReset:reset)
                try await Task.sleep(nanoseconds:300_000_000)
                try await service.flush(conversationID:handle.identity.block.conversationID)
                if generation==epoch,!Task.isCancelled {issue=nil;explicitReset=false}
            } catch is CancellationError { }
            catch {if generation==epoch,!Task.isCancelled {issue = .saveFailed}}
        }
    }
    func flush() async {
        saveTask?.cancel();saveTask=nil
        guard let service,let handle else {return}
        sequence += 1
        let value=state,edit=sequence,reset=explicitReset,epoch=generation
        do {
            try await service.stage(handle:handle,state:value,editSequence:edit,explicitlyReset:reset)
            try await service.flush(conversationID:handle.identity.block.conversationID)
            if generation==epoch {issue=nil;explicitReset=false}
        } catch is CancellationError { }
        catch {if generation==epoch {issue = .saveFailed}}
    }
    func disappear() {
        saveTask?.cancel();saveTask=nil;generation=UUID();loading=false
        guard let service,let handle else {return}
        self.handle=nil;sequence += 1
        let value=state,edit=sequence,reset=explicitReset,epoch=generation
        closingTask=Task {
            do {try await service.close(handle:handle,state:value,editSequence:edit,explicitlyReset:reset)}
            catch is CancellationError { }
            catch {if generation==epoch {issue = .saveFailed}}
        }
    }
}

@MainActor private struct ConversationGenerativeUITableView: View {
    let table: CGUITable
    let preview: Bool
    @Binding var state:CGUILocalState
    var onInteraction: () -> Void = {}
    var onReset: () -> Void = {}
    @Environment(\.locale) private var locale
    private func ui(_ key: String, _ arguments: [String] = []) -> String { AppLanguage(locale: locale).ui(key, arguments: arguments) }
    private var rows: [CGUITableRow] {
        let filter=state.tableFilter,sortColumn=table.columns.firstIndex(where:{$0.id == state.sortColumnID}) ?? -1
        var result = table.rows.filter { filter.isEmpty || $0.cells.contains { $0.readableValue.localizedCaseInsensitiveContains(filter) } }
        if table.columns.indices.contains(sortColumn) {
            result.sort {
                let a = $0.cells[sortColumn], b = $1.cells[sortColumn]
                let comparison: ComparisonResult
                if let av=a.number,let bv=b.number {
                    // Decimal parsing keeps numeric sorting separate from drawing approximations.
                    comparison = av.compared(to:bv)
                } else { comparison = a.readableValue.localizedStandardCompare(b.readableValue) }
                if comparison == .orderedSame {return $0.id < $1.id}
                return state.sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(ui("筛选表格"), text: $state.tableFilter,onEditingChanged:{editing in if editing {onInteraction()}}).textFieldStyle(.roundedBorder).frame(minHeight: 44)
                .accessibilityIdentifier(preview ? "chat.genui.filter" : "chat.genui.fullFilter")
            Text(ui("显示 {0} / {1} 行", [String(rows.count),String(table.rows.count)])).font(.footnote).foregroundStyle(catColors.secondary)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                            Button {
                                onInteraction()
                                var copy=state
                                if copy.sortColumnID == column.id {copy.sortAscending.toggle()} else {copy.sortColumnID=column.id;copy.sortAscending=true}
                                state=copy
                            } label: { Text(column.label + (column.unit.map {" (" + $0 + ")"} ?? "") + (state.sortColumnID == column.id ? (state.sortAscending ? " ↑" : " ↓") : ""))
                                    .font(.subheadline.weight(.semibold)).frame(width: 140, alignment: .leading).frame(minHeight: 44) }
                                .buttonStyle(catPressButtonStyle())
                                .accessibilityHint(ui("按此列排序"))
                        }
                    }
                    ForEach(Array(rows.prefix(preview ? 5 : rows.count))) { row in
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell.readableValue).textSelection(.enabled).frame(width: 140, alignment: .leading).padding(.vertical, 12)
                            }
                        }
                    }
                }
            }.accessibilityIdentifier("chat.genui.table")
            Button(ui("重置")) {onInteraction();onReset()}.touchTarget().accessibilityIdentifier("chat.genui.table.reset")
        }
    }
}

@MainActor private struct ConversationGenerativeUIChartView: View {
    let chart: CGUIChart
    @Binding var state:CGUILocalState
    var onInteraction: () -> Void = {}
    var onReset: () -> Void = {}
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var textSize
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var drawable:Bool {
        guard let zero=try? CGUIDecimal("0") else {return false}
        return chart.series.flatMap(\.points).allSatisfy {point in
            point.value.doubleValue.isFinite && (point.value.doubleValue != 0 || point.value.compared(to:zero) == .orderedSame)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if drawable {
            Chart {
                ForEach(chart.series) { series in
                    ForEach(Array(series.points.enumerated()), id: \.element.id) { index, point in
                        if chart.kind == .bar {
                            BarMark(x: .value("Label",point.label),y: .value(chart.unit,point.value.doubleValue))
                                .foregroundStyle(by: .value("Series",series.label))
                        } else {
                            LineMark(x: .value("Index",index),y: .value(chart.unit,point.value.doubleValue))
                                .foregroundStyle(by: .value("Series",series.label))
                        }
                    }
                }
            }.frame(height: textSize.isAccessibilitySize ? 300 : 220)
                .accessibilityLabel(ui("图表；原值见下方数据选择"))
            } else { Text(ui("这些数值无法准确绘图，请查看原始数据表。")).font(.footnote).foregroundStyle(catColors.secondary) }
            Picker(ui("数据序列"), selection: Binding(get:{state.selectedSeriesID ?? ""},set:{id in
                onInteraction();var copy=state;copy.selectedSeriesID=id;copy.selectedPointID=chart.series.first(where:{$0.id == id})?.points.first?.id;state=copy
            })) {
                ForEach(chart.series) { series in Text(series.label).tag(series.id) }
            }.frame(minHeight: 44)
            if let series=chart.series.first(where:{$0.id == state.selectedSeriesID}) {
                Picker(ui("数据点"), selection: Binding(get:{state.selectedPointID ?? ""},set:{id in onInteraction();var copy=state;copy.selectedPointID=id;state=copy})) {
                    ForEach(series.points) {point in Text(point.label).tag(point.id)}
                }.frame(minHeight: 44)
                if let point=series.points.first(where:{$0.id == state.selectedPointID}) {
                    Text(point.label + ": " + point.value.rawValue + " " + chart.unit).textSelection(.enabled)
                        .accessibilityIdentifier("chat.genui.pointValue")
                }
            }
            Button(ui("重置")) {onInteraction();onReset()}.touchTarget().accessibilityIdentifier("chat.genui.chart.reset")
            DisclosureGroup(ui("查看数据表")) {
                ForEach(chart.series) { series in
                    Text(series.label).font(.subheadline.weight(.semibold))
                    ForEach(series.points) { point in Text(point.label + ": " + point.value.rawValue + " " + chart.unit).textSelection(.enabled) }
                }
            }
        }
    }
}

@MainActor private struct ConversationDurationCalculatorView: View {
    let input: CGUIDurationBudgetInput
    let onInteraction: () -> Void
    let onReset: () -> Void
    @Binding var values: [String]
    @Environment(\.locale) private var locale
    private func ui(_ key: String) -> String {AppLanguage(locale:locale).ui(key)}
    init(input: CGUIDurationBudgetInput,values:Binding<[String]>,onInteraction:@escaping () -> Void = {},onReset:@escaping () -> Void = {}) {
        self.input=input
        self.onInteraction=onInteraction
        self.onReset=onReset;_values=values
    }
    private var result: CGUIDurationBudgetResult? {
        guard let steps=Int(values[2]),let total=try? CGUIDecimal(values[0]),let reserved=try? CGUIDecimal(values[1]),let perStep=try? CGUIDecimal(values[3]),
              let result=try? CGUICalculator.duration(.init(total:total,reserved:reserved,stepCount:steps,perStep:perStep)) else {return nil}
        return result
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if let result {
                Text(ui("剩余时间") + ": " + result.displayRemaining + " " + ui("分钟")).font(.body.weight(.semibold)).accessibilityIdentifier("chat.genui.duration.result")
                if result.isOverBudget {
                    Text(ui("已超出总时长，请调整参数。")).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.genui.duration.overBudget")
                    if result.displayRemaining == "0.00" {Text(result.remaining.rawValue + " " + ui("分钟")).font(.footnote).textSelection(.enabled)}
                }
            } else {Text(ui("请输入范围内的数值；步骤数量须为整数。")).foregroundStyle(catColors.attention).accessibilityIdentifier("chat.genui.duration.error")}
            ForEach(0..<4,id:\.self) {index in
                VStack(alignment:.leading,spacing:4) {
                    Text(fieldLabel(index)).font(.subheadline)
                    TextField("",text:$values[index],onEditingChanged:{editing in if editing {onInteraction()}}).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(minHeight:44)
                        .accessibilityLabel(fieldLabel(index))
                        .accessibilityIdentifier("chat.genui.duration.field."+String(index))
                }
            }
            Text(ui("剩余 = 总时长 − 保留 − 步骤数 × 单步时长")).font(.footnote).foregroundStyle(catColors.secondary)
            Text(ui("仅本地试算，不创建日程或发送请求。")).font(.footnote).foregroundStyle(catColors.secondary)
            Button(ui("重置")) {onInteraction();onReset()}
                .touchTarget().accessibilityIdentifier("chat.genui.duration.reset")
        }
    }
    private func fieldLabel(_ index:Int)->String {
        switch index {
        case 0:return ui("总时长（分钟）")
        case 1:return ui("保留时长（分钟）")
        case 2:return ui("步骤数量")
        default:return ui("单步时长（分钟）")
        }
    }
}

@MainActor private struct ConversationWeightedCalculatorView: View {
    let input: CGUIWeightedComparisonInput
    let onInteraction: () -> Void
    let onReset: () -> Void
    @Binding var weights: [String]
    @Environment(\.locale) private var locale
    private func ui(_ key: String) -> String {AppLanguage(locale:locale).ui(key)}
    init(input:CGUIWeightedComparisonInput,weights:Binding<[String]>,onInteraction:@escaping () -> Void = {},onReset:@escaping () -> Void = {}) {self.input=input;self.onInteraction=onInteraction;self.onReset=onReset;_weights=weights}
    private var results: [CGUIWeightedResult]? {
        guard let dimensions=try? input.dimensions.enumerated().map({index,dimension in CGUIWeightedDimension(id:dimension.id,label:dimension.label,weight:try CGUIDecimal(weights[index]))}) else {return nil}
        return try? CGUICalculator.weighted(.init(dimensions:dimensions,options:input.options))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if let results {
                ForEach(results,id:\.optionID) {result in
                    Text((input.options.first {$0.id == result.optionID}?.label ?? result.optionID) + ": " + result.displayScore + " / 100").textSelection(.enabled)
                }
            } else {Text(ui("权重须为 0–100，且总权重不能为零。")).foregroundStyle(catColors.attention)}
            ForEach(Array(input.dimensions.enumerated()),id:\.element.id) {index,dimension in
                VStack(alignment:.leading,spacing:4) {
                    Text(dimension.label).font(.subheadline)
                    TextField(ui("权重"),text:$weights[index],onEditingChanged:{editing in if editing {onInteraction()}}).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(minHeight:44)
                        .accessibilityLabel(dimension.label + " " + ui("权重"))
                }
            }
            Text(ui("加权结果 = 得分 × 权重之和 / 总权重")).font(.footnote).foregroundStyle(catColors.secondary)
            Text(ui("仅本地试算，不创建日程或发送请求。")).font(.footnote).foregroundStyle(catColors.secondary)
            Button(ui("重置")) {onInteraction();onReset()}.touchTarget()
        }
    }
}
