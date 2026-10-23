import SwiftUI
import Combine

/// A local parenting workspace. Chat remains an optional helper and never confirms an arrangement.
@MainActor struct ParentingHomeView: View {
    @ObservedObject private var conversationModel: ConversationFirstModel
    @StateObject private var model: ParentingWorkspaceModel
    private let accountLabel: String?
    private let onSignOut: (() -> Void)?
    private let isAnonymousAccount: Bool
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: ParentingTab = .today
    @State private var selectedChildID: UUID?
    @State private var selectedGoalID: UUID?
    @State private var sheet: ParentingSheet?
    @State private var chatPresented = false
    @State private var settingsPresented = false
    @State private var deletion: ParentingDeletion?
    @State private var operations: [String: UUID] = [:]
    @State private var completedExpanded = false
    @State private var cancelledExpanded = false
    @State private var recordFilter: ParentingRecordFilter = .all
    @State private var now = Date()

    init(model: ConversationFirstModel, accountLabel: String? = nil,
         onSignOut: (() -> Void)? = nil, isAnonymousAccount: Bool = false) {
        _conversationModel = ObservedObject(wrappedValue: model)
        _model = StateObject(wrappedValue: ParentingWorkspaceModel(
            repository: model.repository, scope: model.scope, subjectID: model.trustedSubjectID))
        self.accountLabel = accountLabel
        self.onSignOut = onSignOut
        self.isAnonymousAccount = isAnonymousAccount
    }

    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var workspace: ParentingWorkspace { model.workspace }
    private var activeChild: ParentingChild? {
        workspace.children.first { $0.id == selectedChildID } ?? workspace.children.first
    }
    private var arrangements: [ParentingArrangement] {
        workspace.arrangements.filter { selectedChildID == nil || $0.childID == selectedChildID }
            .sorted { $0.dueAt < $1.dueAt }
    }
    private var childGoals: [ParentingGoal] {
        guard let child = activeChild else { return [] }
        return workspace.goals.filter { $0.childID == child.id }.sorted { $0.createdAt < $1.createdAt }
    }
    private var selectedGoal: ParentingGoal? { childGoals.first { $0.id == selectedGoalID } }

    var body: some View {
        NavigationStack {
            Group {
                if !model.loaded { loadState }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            if let error = model.error { errorBanner(error) }
                            switch tab {
                            case .today: todayContent
                            case .growth: growthContent
                            case .records: recordsContent
                            }
                            localStorageNote
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable { await model.load() }
                }
            }
            .background(catColors.background.ignoresSafeArea())
            .foregroundStyle(catColors.ink)
            .navigationTitle(ui(tab.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 7) {
                        BrandMark(size: 25, style: .fill)
                        Text(ui("小咪育儿")).font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { chatPresented = true } label: {
                        Image(systemName: "bubble.left.and.bubble.right").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(ui("打开辅助对话"))
                    .accessibilityIdentifier("parenting.chatHelper")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingsPresented = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(ui("育儿工作区设置"))
                    .accessibilityIdentifier("parenting.settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            .overlay(alignment: .top) {
                if model.loaded && model.busy {
                    ProgressView(ui("正在保存"))
                        .font(catTypography.Role.caption.font).padding(10)
                        .background(catColors.card, in: Capsule())
                        .accessibilityIdentifier("parenting.saving")
                }
            }
        }
        .tint(catColors.actionText)
        .task {
            openPendingRoute()
            await model.load()
        }
        .onChange(of: catRouteCenter.shared.pending) { _, _ in openPendingRoute() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { now = Date() }
        }
        .onChange(of: workspace.children.map(\.id)) { _, ids in
            if let selectedChildID, !ids.contains(selectedChildID) { self.selectedChildID = nil }
        }
        .onChange(of: activeChild?.id) { _, _ in
            if let selectedGoalID, !childGoals.contains(where: { $0.id == selectedGoalID }) { self.selectedGoalID = nil }
        }
        .onChange(of: workspace.goals.map(\.id)) { _, ids in
            if let selectedGoalID, !ids.contains(selectedGoalID) { self.selectedGoalID = nil }
        }
        .sheet(item: $sheet, onDismiss: openPendingRoute) { destination in
            ParentingEditorSheet(model: model, chat: conversationModel, destination: destination)
        }
        .sheet(isPresented: $chatPresented) {
            ConversationFirstView(model: conversationModel, accountLabel: accountLabel,
                                  onSignOut: onSignOut, isAnonymousAccount: isAnonymousAccount)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $settingsPresented, onDismiss: openPendingRoute) {
            ParentingSettingsView(model: model, accountLabel: accountLabel,
                                  isAnonymousAccount: isAnonymousAccount,
                                  onSignOut: onSignOut)
        }
        .alert(ui("确认删除？"), isPresented: deletionPresented, presenting: deletion) { target in
            Button(ui("删除"), role: .destructive) { delete(target) }
            Button(ui("取消"), role: .cancel) { deletion = nil }
        } message: { target in Text(ui(target.explanation)) }
        .modifier(catPrivacyShield(lockedText: ui("解锁后查看育儿记录"), identifier: "parenting.privacyShield"))
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(ParentingTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon).font(.title3.weight(tab == item ? .semibold : .regular))
                        Text(ui(item.title)).font(catTypography.Role.caption.font.weight(tab == item ? .semibold : .regular))
                    }
                    .foregroundStyle(tab == item ? catColors.actionText : catColors.calmSecondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(tab == item ? catColors.action.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? [.isSelected] : [])
                .accessibilityIdentifier("parenting.tab.\(item.rawValue)")
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
        .background(catColors.background)
        .overlay(alignment: .top) { Rectangle().fill(catColors.hairline).frame(height: 0.5) }
    }

    private var loadState: some View {
        VStack(spacing: 18) {
            BrandMark(size: 54, style: .fill)
            if let error = model.error {
                Text(ui("育儿工作区暂时无法打开")).font(.title3.weight(.semibold))
                Text(ui(error)).font(.subheadline).foregroundStyle(catColors.calmSecondary)
                    .multilineTextAlignment(.center)
                Button(ui("重试")) { Task { await model.load() } }
                    .buttonStyle(ParentingPrimaryButtonStyle())
                    .disabled(model.busy)
                    .accessibilityIdentifier("parenting.load.retry")
            } else {
                ProgressView()
                Text(ui("正在读取此设备上的育儿记录")).font(.subheadline)
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("parenting.loadState")
    }

    @ViewBuilder private var todayContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: now.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                        .font(catTypography.Role.caption.font.weight(.medium)).foregroundStyle(catColors.calmSecondary)
                    Text(ui("把今天的照顾，留给以后回看"))
                        .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(ui("记下安排和观察，慢慢看见孩子的变化。"))
                        .font(.subheadline).foregroundStyle(catColors.calmSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                BrandMark(size: 53, style: .fill).padding(12)
                    .background(catColors.action.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
            }
            if !workspace.children.isEmpty {
                Button { sheet = .newArrangement(selectedChildID, nil) } label: {
                    Label(ui("记一件事"), systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(ParentingPrimaryButtonStyle())
                .disabled(model.busy)
                .accessibilityIdentifier("parenting.addArrangement")
                Text(ui("先存为待确认，确认后才进入安排。"))
                    .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            }
        }
        if workspace.children.isEmpty { firstChildEmpty }
        else {
            childFilter
            arrangementSection("待确认", items: arrangements.filter { $0.state == .draft },
                               empty: "还没有待确认的事。记下一件事后，可以在这里核对。")
            arrangementSection("今天的安排", items: arrangements.filter { $0.state == .planned && Calendar.autoupdatingCurrent.isDate($0.dueAt, inSameDayAs: now) },
                               empty: "今天没有已确认的安排。可以留白，也可以记下一件事。")
            let overdue = arrangements.filter { $0.state == .planned && $0.dueAt < Calendar.autoupdatingCurrent.startOfDay(for: now) }
            if !overdue.isEmpty {
                arrangementSection("待重新安排", items: overdue,
                                   explanation: "时间已经过去，仍未标记完成。可调整时间或取消，不会自动算作完成。")
            }
            let tomorrow = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Calendar.autoupdatingCurrent.startOfDay(for: now)) ?? now
            let future = arrangements.filter { $0.state == .planned && $0.dueAt >= tomorrow }
            if !future.isEmpty { arrangementSection("以后的安排", items: future) }
            historySection
            todayGrowthPreview
            if workspace.suggestionsEnabled { suggestions }
            helperEntry
        }
    }

    private var childFilter: some View {
        Picker(ui("查看哪个孩子"), selection: $selectedChildID) {
            Text(ui("全部孩子")).tag(UUID?.none)
            ForEach(workspace.children) { child in Text(verbatim: child.name).tag(Optional(child.id)) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("parenting.childFilter")
    }

    private var firstChildEmpty: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: "leaf").font(.title).foregroundStyle(catColors.actionText).accessibilityHidden(true)
            Text(ui("从孩子的昵称开始")).font(.title3.weight(.semibold))
            Text(ui("不用填写生日和健康信息。添加昵称后，就能记录安排、观察与成长目标。"))
                .font(.subheadline).foregroundStyle(catColors.calmSecondary)
            Button(ui("添加孩子")) { sheet = .newChild }
                .buttonStyle(ParentingPrimaryButtonStyle()).disabled(model.busy)
                .accessibilityIdentifier("parenting.firstChild")
        }
        .parentingCard()
    }

    @ViewBuilder private func arrangementSection(_ title: String, items: [ParentingArrangement],
                                                empty: String? = nil, explanation: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui(title)).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let explanation {
                Text(ui(explanation)).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            }
            ForEach(items) { arrangement in arrangementCard(arrangement) }
            if items.isEmpty, let empty {
                Text(ui(empty)).font(.subheadline).foregroundStyle(catColors.calmSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).parentingCard()
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(isExpanded: $completedExpanded) {
                let items = arrangements.filter { $0.state == .completed }.reversed()
                if items.isEmpty { Text(ui("还没有完成的安排。" )).font(.subheadline).foregroundStyle(catColors.calmSecondary).padding(.top, 12) }
                ForEach(Array(items)) { item in arrangementCard(item).padding(.top, 10) }
            } label: { Label(ui("已完成的安排"), systemImage: "checkmark.circle").font(.subheadline.weight(.medium)) }
            DisclosureGroup(isExpanded: $cancelledExpanded) {
                let items = arrangements.filter { $0.state == .cancelled }.reversed()
                if items.isEmpty { Text(ui("还没有取消的安排。" )).font(.subheadline).foregroundStyle(catColors.calmSecondary).padding(.top, 12) }
                ForEach(Array(items)) { item in arrangementCard(item).padding(.top, 10) }
            } label: { Label(ui("已取消的安排"), systemImage: "minus.circle").font(.subheadline.weight(.medium)) }
        }
        .accessibilityIdentifier("parenting.arrangementHistory")
    }

    private func arrangementCard(_ item: ParentingArrangement) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: childName(item.childID) + " · " + item.dueAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline).foregroundStyle(catColors.calmSecondary)
                    if let goal = goalTitle(item.goalID) {
                        Label { Text(verbatim: goal) } icon: { Image(systemName: "leaf") }
                            .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    if item.state == .draft || item.state == .planned {
                        Button(ui("取消这件事"), systemImage: "minus.circle") {
                            perform(.cancelArrangement(id: item.id), key: "cancel.\(item.id)")
                        }
                    }
                    Button(ui("删除安排"), systemImage: "trash", role: .destructive) { deletion = .arrangement(item.id) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .disabled(model.busy)
                .accessibilityLabel(ui("安排操作"))
            }
            DisclosureGroup(ui("查看原始记录与时间")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: item.sourceText).font(.subheadline).textSelection(.enabled)
                    Text(ui("来源：家长填写")).font(catTypography.Role.caption.font)
                    Text(verbatim: ui("创建时间") + " · " + item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(catTypography.Role.caption.font)
                    if item.updatedAt != item.createdAt {
                        Text(verbatim: ui("更新时间") + " · " + item.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(catTypography.Role.caption.font)
                    }
                }
                .foregroundStyle(catColors.calmSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            .font(catTypography.Role.caption.font).tint(catColors.calmSecondary)
            if item.state == .draft {
                Text(ui("待确认 · 尚未进入安排")).font(catTypography.Role.caption.font).foregroundStyle(catColors.attention)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { arrangementConfirm(item); arrangementEdit(item) }
                    VStack(alignment: .leading, spacing: 8) { arrangementConfirm(item); arrangementEdit(item) }
                }
            } else if item.state == .planned {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { arrangementComplete(item); arrangementEdit(item) }
                    VStack(alignment: .leading, spacing: 8) { arrangementComplete(item); arrangementEdit(item) }
                }
            } else if item.state == .completed {
                Label(ui("家长已标记完成"), systemImage: "checkmark.circle").font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                if let record = workspace.records.first(where: { $0.arrangementID == item.id }) {
                    Button(ui("查看完成记录")) { tab = .records; selectedChildID = item.childID; recordFilter = .completion }
                        .font(.subheadline).frame(minHeight: 44)
                        .accessibilityIdentifier("parenting.completionRecord.\(record.id)")
                } else {
                    Text(ui("完成记录已删除。安排仍保留完成状态。"))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                }
            } else {
                Text(ui("已取消 · 不会作为待办或完成记录")).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                Button(ui("另记一件事")) { sheet = .newArrangement(item.childID, item.goalID) }
                    .font(.subheadline).frame(minHeight: 44).disabled(model.busy)
            }
        }
        .parentingCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("parenting.arrangement.\(item.id)")
    }

    private func arrangementConfirm(_ item: ParentingArrangement) -> some View {
        Button(ui("确认安排")) { perform(.confirmArrangement(id: item.id), key: "confirm.\(item.id)") }
            .buttonStyle(ParentingPrimaryButtonStyle()).disabled(model.busy)
            .accessibilityIdentifier("parenting.confirm.\(item.id)")
    }
    private func arrangementEdit(_ item: ParentingArrangement) -> some View {
        Button(ui("调整安排")) { sheet = .editArrangement(item) }
            .buttonStyle(ParentingSecondaryButtonStyle()).disabled(model.busy)
    }
    private func arrangementComplete(_ item: ParentingArrangement) -> some View {
        Button(ui("完成并记录")) { sheet = .complete(item) }
            .buttonStyle(ParentingPrimaryButtonStyle()).disabled(model.busy)
            .accessibilityIdentifier("parenting.complete.\(item.id)")
    }

    @ViewBuilder private var growthContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ui("留一条成长的线索")).font(.title2.weight(.semibold))
            Text(ui("目标由你定义。安排是打算做的事，观察和完成记录是已经记下的事。"))
                .font(.subheadline).foregroundStyle(catColors.calmSecondary)
        }
        if workspace.children.isEmpty { firstChildEmpty }
        else {
            growthChildSelector
            if let child = activeChild {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "person.crop.circle").font(.largeTitle).foregroundStyle(catColors.actionText).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: child.name).font(.title3.weight(.semibold))
                        Text(verbatim: ui("开始记录于") + " " + child.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button(ui("修改昵称")) { sheet = .editChild(child) }
                        Button(ui("删除孩子"), role: .destructive) { deletion = .child(child.id) }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel(ui("孩子资料操作")).disabled(model.busy)
                }.parentingCard()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(ui("成长目标")).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button(ui("添加目标"), systemImage: "plus") { sheet = .newGoal(child.id) }
                            .font(.subheadline).frame(minHeight: 44).disabled(model.busy)
                    }
                    if childGoals.isEmpty {
                        Text(ui("还没有成长目标。也可以先记观察，之后再建立目标。"))
                            .font(.subheadline).foregroundStyle(catColors.calmSecondary).parentingCard()
                    } else {
                        ForEach(childGoals) { goal in
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    selectedGoalID = selectedGoalID == goal.id ? nil : goal.id
                                } label: {
                                    HStack(alignment: .top, spacing: 9) {
                                        Image(systemName: selectedGoalID == goal.id ? "leaf.fill" : "leaf")
                                            .foregroundStyle(catColors.actionText).padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(verbatim: goal.title).font(.headline).foregroundStyle(catColors.ink)
                                            Text(ui(selectedGoalID == goal.id ? "正在回顾这个目标" : "查看相关安排与记录"))
                                                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button(role: .destructive) { deletion = .goal(goal.id) } label: {
                                    Image(systemName: "trash").frame(width: 44, height: 44)
                                }.accessibilityLabel(ui("删除目标")).disabled(model.busy)
                            }.parentingCard()
                        }
                    }
                }
                growthReview(child)
            }
        }
    }

    private var growthChildSelector: some View {
        ViewThatFits(in: .horizontal) {
            HStack { growthPicker; Spacer(); addChildButton }
            VStack(alignment: .leading) { growthPicker; addChildButton }
        }
    }
    private var growthPicker: some View {
        Picker(ui("选择孩子"), selection: Binding(get: { activeChild?.id }, set: { selectedChildID = $0 })) {
            ForEach(workspace.children) { child in Text(verbatim: child.name).tag(Optional(child.id)) }
        }.pickerStyle(.menu)
    }
    private var addChildButton: some View {
        Button(ui("添加孩子"), systemImage: "plus") { sheet = .newChild }
            .font(.subheadline).frame(minHeight: 44).disabled(model.busy)
    }

    private func growthReview(_ child: ParentingChild) -> some View {
        let plans = workspace.arrangements.filter {
            $0.childID == child.id && (selectedGoal == nil || $0.goalID == selectedGoal?.id) && ($0.state == .draft || $0.state == .planned)
        }.sorted { $0.dueAt < $1.dueAt }
        let observations = workspace.records.filter {
            $0.childID == child.id && $0.kind == .observation && (selectedGoal == nil || $0.goalID == selectedGoal?.id)
        }.sorted { $0.createdAt > $1.createdAt }
        let completions = workspace.records.filter {
            $0.childID == child.id && $0.kind == .completion && (selectedGoal == nil || $0.goalID == selectedGoal?.id)
        }.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ui("成长回顾")).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if let goal = selectedGoal { Text(verbatim: goal.title).font(.subheadline).foregroundStyle(catColors.actionText) }
                    else { Text(ui("正在查看这个孩子的全部目标与未关联记录。" )).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary) }
                }
                Spacer()
                if selectedGoal != nil { Button(ui("查看全部")) { selectedGoalID = nil }.frame(minHeight: 44) }
            }
            arrangementSection("计划与待确认", items: plans, empty: "这个范围内还没有安排。")
            Button { sheet = .newArrangement(child.id, selectedGoal?.id) } label: {
                Label(ui(selectedGoal == nil ? "记一件事" : "为这个目标记一件事"), systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(ParentingSecondaryButtonStyle()).disabled(model.busy)
            reviewRecordSection("日常观察", records: observations, empty: "这个范围内还没有观察。")
            reviewRecordSection("家长完成记录", records: completions, empty: "这个范围内还没有完成记录。")
            Button { sheet = .newObservation(child.id, selectedGoal?.id) } label: {
                Label(ui("记下观察"), systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }.buttonStyle(ParentingSecondaryButtonStyle()).disabled(model.busy)
        }
    }

    @ViewBuilder private var recordsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(ui("把发生过的事留住")).font(.title2.weight(.semibold))
            Text(ui("日常观察和家长标记完成的内容分开保存，可回看原话、修正或删除。"))
                .font(.subheadline).foregroundStyle(catColors.calmSecondary)
        }
        if workspace.children.isEmpty { firstChildEmpty }
        else {
            Button { sheet = .newObservation(selectedChildID, nil) } label: {
                Label(ui("记下观察"), systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }.buttonStyle(ParentingPrimaryButtonStyle()).disabled(model.busy)
            childFilter
            Picker(ui("记录类型"), selection: $recordFilter) {
                ForEach(ParentingRecordFilter.allCases) { filter in Text(ui(filter.title)).tag(filter) }
            }.pickerStyle(.segmented)
            let records = workspace.records.filter {
                (selectedChildID == nil || $0.childID == selectedChildID) &&
                (recordFilter == .all || (recordFilter == .observation ? $0.kind == .observation : $0.kind == .completion))
            }.sorted { $0.createdAt > $1.createdAt }
            if records.isEmpty {
                Text(ui("这里还没有记录。观察可以直接保存；安排完成后会生成独立的完成记录。"))
                    .font(.subheadline).foregroundStyle(catColors.calmSecondary).parentingCard()
            }
            ForEach(records) { record in recordCard(record) }
        }
    }

    private func reviewRecordSection(_ title: String, records: [ParentingRecord], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui(title)).font(.headline).accessibilityAddTraits(.isHeader)
            if records.isEmpty { Text(ui(empty)).font(.subheadline).foregroundStyle(catColors.calmSecondary).parentingCard() }
            ForEach(records) { record in recordCard(record) }
        }
    }

    private func recordCard(_ record: ParentingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(ui(record.kind == .observation ? "日常观察" : "家长完成记录"),
                          systemImage: record.kind == .observation ? "text.bubble" : "checkmark.circle")
                        .font(catTypography.Role.caption.font.weight(.medium)).foregroundStyle(catColors.actionText)
                    Text(verbatim: childName(record.childID) + " · " + record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(ui("更正记录"), systemImage: "pencil") { sheet = .editRecord(record) }
                    Button(ui("删除记录"), systemImage: "trash", role: .destructive) { deletion = .record(record.id) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel(ui("记录操作")).disabled(model.busy)
            }
            Text(verbatim: record.text).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let goal = goalTitle(record.goalID) {
                Label { Text(verbatim: goal) } icon: { Image(systemName: "leaf") }
                    .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            }
            if let arrangementID = record.arrangementID {
                if let arrangement = workspace.arrangements.first(where: { $0.id == arrangementID }) {
                    Text(verbatim: ui("来自安排") + " · " + arrangement.title).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                } else {
                    Text(ui("原安排已删除，完成记录仍保留。" )).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                }
            } else if record.kind == .completion {
                Text(ui("原安排已删除，完成记录仍保留。" )).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            }
            DisclosureGroup(ui("查看来源与更正时间")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ui(record.kind == .observation ? "来源：家长观察" : "来源：家长标记完成" )).font(catTypography.Role.caption.font)
                    if record.sourceText.isEmpty {
                        Text(ui("家长确认完成，未填写补充说明。" )).font(.subheadline)
                    } else { Text(verbatim: record.sourceText).font(.subheadline).textSelection(.enabled) }
                    if record.updatedAt != record.createdAt {
                        Text(verbatim: ui("更正时间") + " · " + record.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(catTypography.Role.caption.font)
                    } else { Text(ui("尚未更正" )).font(catTypography.Role.caption.font) }
                }
                .foregroundStyle(catColors.calmSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(catTypography.Role.caption.font).tint(catColors.calmSecondary)
        }
        .parentingCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("parenting.record.\(record.id)")
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(ui("回顾提示"), systemImage: "sparkles").font(.headline)
                Spacer()
                Button(ui("关闭")) { perform(.setSuggestionsEnabled(false), key: "suggestions.off") }
                    .font(catTypography.Role.caption.font).frame(minHeight: 44).disabled(model.busy)
            }
            if arrangements.contains(where: { $0.state == .draft }) {
                Text(ui("你有待确认的事。可以先核对孩子、时间和内容，再决定是否安排。"))
                    .font(.subheadline).foregroundStyle(catColors.calmSecondary)
            } else if arrangements.contains(where: { $0.state == .planned && $0.dueAt < Calendar.autoupdatingCurrent.startOfDay(for: now) }) {
                Text(ui("有安排的时间已经过去。可以按实际情况调整、取消或记录完成。"))
                    .font(.subheadline).foregroundStyle(catColors.calmSecondary)
            } else if !workspace.goals.isEmpty {
                Text(ui("已保存成长目标。下次记录观察时，可以关联一个目标，方便以后回顾。"))
                    .font(.subheadline).foregroundStyle(catColors.calmSecondary)
            } else {
                Text(ui("已保存的安排会留在这里。完成后可写下实际发生的事，再回看记录。"))
                    .font(.subheadline).foregroundStyle(catColors.calmSecondary)
            }
            Text(ui("仅根据已保存内容整理，不评估孩子，不会自动创建或执行安排。"))
                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
        }.parentingCard()
    }

    @ViewBuilder private var todayGrowthPreview: some View {
        let goals = workspace.goals.filter { selectedChildID == nil || $0.childID == selectedChildID }
            .sorted { $0.createdAt > $1.createdAt }
        let observations = workspace.records.filter {
            $0.kind == .observation && (selectedChildID == nil || $0.childID == selectedChildID)
        }.sorted { $0.createdAt > $1.createdAt }
        if !goals.isEmpty || !observations.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(ui("成长也在日常里")).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let goal = goals.first {
                    Button {
                        selectedChildID = goal.childID
                        selectedGoalID = goal.id
                        tab = .growth
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(ui("孩子的小目标"), systemImage: "leaf").font(catTypography.Role.caption.font.weight(.medium))
                                .foregroundStyle(catColors.actionText)
                            Text(verbatim: goal.title).font(.headline).foregroundStyle(catColors.ink)
                            Text(verbatim: childName(goal.childID)).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                            Text(ui("去成长页回顾" )).font(catTypography.Role.caption.font).foregroundStyle(catColors.actionText)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).parentingCard()
                }
                if let record = observations.first {
                    Button {
                        selectedChildID = record.childID
                        recordFilter = .observation
                        tab = .records
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(ui("最近的成长观察"), systemImage: "text.bubble").font(catTypography.Role.caption.font.weight(.medium))
                                .foregroundStyle(catColors.actionText)
                            Text(verbatim: record.text).font(.subheadline).foregroundStyle(catColors.ink).lineLimit(3)
                            Text(verbatim: childName(record.childID) + " · " + record.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                            Text(ui("查看完整记录" )).font(catTypography.Role.caption.font).foregroundStyle(catColors.actionText)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).parentingCard()
                }
            }.accessibilityIdentifier("parenting.todayGrowthPreview")
        }
    }

    private var helperEntry: some View {
        Button { chatPresented = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right").font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ui("需要整理想法时，问问小咪")).font(.subheadline.weight(.medium))
                    Text(ui("打开辅助对话；对话不会自动变成安排。"))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(catTypography.Role.caption.font)
            }
            .foregroundStyle(catColors.ink).frame(minHeight: 50)
        }
        .buttonStyle(.plain).parentingCard()
        .accessibilityIdentifier("parenting.openChat")
    }

    private var localStorageNote: some View {
        Label(ui("仅在此设备加密保存 · 尚未云同步 · 本机安排不会发送提醒 · 保留直到你删除"), systemImage: "lock.shield")
            .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("parenting.storageBoundary")
    }
    private func errorBanner(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(ui("操作未完成"), systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
            Text(ui(error)).font(.subheadline)
            Text(ui("已填写的内容会保留。请在原操作处重试。" )).font(catTypography.Role.caption.font)
            Button(ui("重新读取本机记录")) { Task { await model.load() } }
                .font(catTypography.Role.caption.font).frame(minHeight: 44).disabled(model.busy)
            Button(ui("收起提示")) { model.error = nil }.font(catTypography.Role.caption.font).frame(minHeight: 44)
        }
        .foregroundStyle(catColors.failure).parentingCard()
        .accessibilityIdentifier("parenting.error")
    }

    private func childName(_ id: UUID) -> String { workspace.children.first { $0.id == id }?.name ?? ui("孩子已删除") }
    private func goalTitle(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return workspace.goals.first { $0.id == id }?.title
    }
    private func openPendingRoute() {
        guard sheet == nil, !settingsPresented, catRouteCenter.shared.pending != nil else { return }
        chatPresented = true
    }
    private func perform(_ command: ParentingCommand, key: String) {
        guard !model.busy else { return }
        let operationID = operations[key] ?? UUID()
        operations[key] = operationID
        Task { if await model.apply(command, operationID: operationID) { operations.removeValue(forKey: key) } }
    }
    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })
    }
    private func delete(_ target: ParentingDeletion) {
        switch target {
        case .child(let id): perform(.deleteChild(id: id), key: "deleteChild.\(id)")
        case .goal(let id): perform(.deleteGoal(id: id), key: "deleteGoal.\(id)")
        case .arrangement(let id): perform(.deleteArrangement(id: id), key: "deleteArrangement.\(id)")
        case .record(let id): perform(.deleteRecord(id: id), key: "deleteRecord.\(id)")
        }
    }
}

private enum ParentingTab: String, CaseIterable, Identifiable {
    case today, growth, records
    var id: String { rawValue }
    var title: String {
        switch self { case .today: "今天"; case .growth: "孩子与成长"; case .records: "记录" }
    }
    var icon: String {
        switch self { case .today: "sun.max"; case .growth: "leaf"; case .records: "book.closed" }
    }
}
private enum ParentingRecordFilter: String, CaseIterable, Identifiable {
    case all, observation, completion
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "全部记录"; case .observation: "日常观察"; case .completion: "家长完成" }
    }
}
private enum ParentingDeletion {
    case child(UUID), goal(UUID), arrangement(UUID), record(UUID)
    var explanation: String {
        switch self {
        case .child: "将删除这个孩子的资料、目标、全部安排和记录。删除后无法恢复。"
        case .goal: "只删除这个成长目标。相关安排和记录会保留，并解除目标关联。删除后无法恢复。"
        case .arrangement: "删除这条安排。已经生成的完成记录会独立保留。删除后无法恢复。"
        case .record: "删除这条记录。原安排的完成状态不会改变。删除后无法恢复。"
        }
    }
}
private enum ParentingSheet: Identifiable {
    case newChild, editChild(ParentingChild), newGoal(UUID)
    case newArrangement(UUID?, UUID?), editArrangement(ParentingArrangement), complete(ParentingArrangement)
    case newObservation(UUID?, UUID?), editRecord(ParentingRecord)
    var id: String {
        switch self {
        case .newChild: "newChild"
        case .editChild(let value): "child.\(value.id)"
        case .newGoal(let id): "goal.\(id)"
        case .newArrangement: "newArrangement"
        case .editArrangement(let value): "arrangement.\(value.id)"
        case .complete(let value): "complete.\(value.id)"
        case .newObservation: "observation"
        case .editRecord(let value): "record.\(value.id)"
        }
    }
}

private struct ParentingCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(catColors.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(catColors.hairline, lineWidth: 0.5))
    }
}
private extension View {
    func parentingCard() -> some View { modifier(ParentingCardModifier()) }
}
private struct ParentingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(catColors.calmGlyph)
            .padding(.horizontal, 17).padding(.vertical, 13).frame(minHeight: 46)
            .background(catColors.action.opacity(configuration.isPressed ? 0.76 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}
private struct ParentingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(catColors.ink)
            .padding(.horizontal, 15).padding(.vertical, 12).frame(minHeight: 46)
            .background(catColors.fillSelected.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor private struct ParentingEditorSheet: View {
    @ObservedObject var model: ParentingWorkspaceModel
    @ObservedObject var chat: ConversationFirstModel
    let destination: ParentingSheet
    @Environment(\.locale) private var locale
    var body: some View {
        Group {
            switch destination {
            case .newChild: ParentingNameEditor(model: model, mode: .child(nil))
            case .editChild(let child): ParentingNameEditor(model: model, mode: .child(child))
            case .newGoal(let childID): ParentingNameEditor(model: model, mode: .goal(childID))
            case .newArrangement(let childID, let goalID):
                ParentingArrangementEditor(model: model, chat: chat, childID: childID, goalID: goalID)
            case .editArrangement(let item):
                ParentingArrangementEditor(model: model, chat: chat, arrangement: item)
            case .newObservation(let childID, let goalID):
                ParentingRecordEditor(model: model, mode: .observation(childID, goalID))
            case .editRecord(let record): ParentingRecordEditor(model: model, mode: .edit(record))
            case .complete(let item): ParentingRecordEditor(model: model, mode: .completion(item))
            }
        }
        .modifier(catPrivacyShield(lockedText: AppLanguage(locale: locale).ui("解锁后查看育儿记录"), identifier: "parenting.editor.privacyShield"))
    }
}

@MainActor private struct ParentingNameEditor: View {
    enum Mode { case child(ParentingChild?), goal(UUID) }
    @ObservedObject var model: ParentingWorkspaceModel
    let mode: Mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var entityID = UUID()
    @State private var operationID = UUID()
    @State private var saving = false
    @State private var saveError: String?
    @State private var submittedCommand: ParentingCommand?
    @FocusState private var focused: Bool

    init(model: ParentingWorkspaceModel, mode: Mode) {
        self.model = model
        self.mode = mode
        if case .child(let child) = mode { _text = State(initialValue: child?.name ?? "") }
        else { _text = State(initialValue: "") }
    }
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var cleaned: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isChild: Bool { if case .child = mode { return true }; return false }
    private var maximum: Int { isChild ? 40 : 120 }
    private var validReference: Bool {
        switch mode {
        case .child(.none): true
        case .child(.some(let child)): model.workspace.children.contains { $0.id == child.id }
        case .goal(let id): model.workspace.children.contains { $0.id == id }
        }
    }
    private var title: String {
        switch mode {
        case .child(.some): "修改昵称"
        case .child(.none): "添加孩子"
        case .goal: "添加成长目标"
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(ui(isChild ? "孩子的昵称" : "你想持续关注什么"), text: $text, axis: .vertical)
                        .lineLimit(1...4).focused($focused)
                        .accessibilityIdentifier(isChild ? "parenting.child.name" : "parenting.goal.title")
                } header: { Text(ui(isChild ? "昵称" : "成长目标")) }
                footer: {
                    Text(ui(isChild ? "只填写你想使用的称呼，最多 40 字。" : "用自己的话写下想关注的变化，最多 120 字。目标可随时删除，不会自动生成任务。"))
                }
                if cleaned.count > maximum { ParentingFormIssue(message: isChild ? "昵称不能超过 40 字。" : "目标不能超过 120 字。") }
                if !validReference { ParentingFormIssue(message: "孩子资料已变更，请关闭此页后重新选择孩子。") }
                if let saveError { ParentingFormIssue(message: saveError); ParentingReloadButton(model: model) }
            }
            .scrollContentBackground(.hidden).background(catColors.background)
            .foregroundStyle(catColors.ink)
            .disabled(saving || model.busy)
            .navigationTitle(ui(title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { if saving { ProgressView() } else { Text(ui("保存")) } }
                        .disabled(!validReference || cleaned.isEmpty || cleaned.count > maximum || saving || model.busy)
                        .accessibilityIdentifier("parenting.name.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
        .tint(catColors.actionText)
    }
    private func save() {
        guard validReference, !saving, !model.busy, !cleaned.isEmpty, cleaned.count <= maximum else { return }
        let command: ParentingCommand
        switch mode {
        case .child(let child):
            if let child { command = .renameChild(id: child.id, name: cleaned) }
            else { command = .addChild(id: entityID, name: cleaned) }
        case .goal(let childID): command = .addGoal(id: entityID, childID: childID, title: cleaned)
        }
        if let submittedCommand, submittedCommand != command { operationID = UUID() }
        submittedCommand = command
        saving = true
        saveError = nil
        Task {
            let success = await model.apply(command, operationID: operationID)
            saving = false
            if success { dismiss() }
            else { saveError = model.error ?? "保存未完成，请重试。" }
        }
    }
}

@MainActor private struct ParentingArrangementEditor: View {
    @ObservedObject var model: ParentingWorkspaceModel
    @ObservedObject var chat: ConversationFirstModel
    @StateObject private var intake: ParentingInlineIntakeModel
    @StateObject private var admissionGate: ParentingEditorAdmissionGate
    let arrangement: ParentingArrangement?
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var entityID = UUID()
    @State private var operationID = UUID()
    @State private var childID: UUID?
    @State private var goalID: UUID?
    @State private var title: String
    @State private var sourceText: String
    @State private var dueAt: Date?
    @State private var clarification: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var timePresented = false
    @State private var imported = false
    @State private var discardConfirmation = false
    @State private var submittedCommand: ParentingCommand?
    @State private var intakeTask: Task<Void, Never>?
    @State private var intakeCallID: UUID?
    @State private var consentPresentation: ParentingInlineConsentPresentation?
    @State private var closingConsentID: UUID?
    @State private var recoveryRequested = false
    @State private var recoveredInput: ParentingRecoveredInput?
    @State private var recoveryNotice: String?
    @State private var cleanupRunning = false

    init(model: ParentingWorkspaceModel, chat: ConversationFirstModel,
         arrangement: ParentingArrangement? = nil, childID: UUID? = nil, goalID: UUID? = nil) {
        self.model = model
        self.chat = chat
        self.arrangement = arrangement
        let admissionGate = ParentingEditorAdmissionGate()
        _admissionGate = StateObject(wrappedValue: admissionGate)
        _intake = StateObject(wrappedValue: ParentingInlineIntakeModel(
            scope: chat.scope, subjectID: chat.trustedSubjectID, factory: chat.parentingIntakeFactory,
            admission: { [weak chat, weak admissionGate] in
                chat?.networkAdmissionAllowed == true && admissionGate?.active == true
            }))
        let onlyChild = model.workspace.children.count == 1 ? model.workspace.children.first?.id : nil
        _childID = State(initialValue: arrangement?.childID ?? childID ?? onlyChild)
        _goalID = State(initialValue: arrangement?.goalID ?? goalID)
        _title = State(initialValue: arrangement?.title ?? "")
        _sourceText = State(initialValue: arrangement?.sourceText ?? "")
        _dueAt = State(initialValue: arrangement?.dueAt)
    }
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var cleanedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanedSource: String { sourceText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        model.workspace.children.contains { $0.id == childID } &&
        !cleanedTitle.isEmpty && cleanedTitle.count <= 160 && dueAt != nil &&
        (arrangement != nil || (!cleanedSource.isEmpty && sourceText.count <= 8000)) && validReference
    }
    private var validReference: Bool {
        guard let arrangement else { return true }
        return model.workspace.arrangements.contains { $0.id == arrangement.id && ($0.state == .draft || $0.state == .planned) }
    }
    private var hasUnsavedChanges: Bool {
        if let arrangement {
            return title != arrangement.title || dueAt != arrangement.dueAt || goalID != arrangement.goalID
        }
        return !sourceText.isEmpty || !title.isEmpty || dueAt != nil || imported
    }
    var body: some View {
        let renderedConsentOwner = consentPresentation?.id ?? closingConsentID
        NavigationStack {
            Form {
                ParentingChildGoalFields(workspace: model.workspace, childID: $childID, goalID: $goalID,
                                         childEditable: arrangement == nil)
                if arrangement == nil {
                    sourceSection
                    inlineIntakeSection
                }
                if imported {
                    Section {
                        Text(ui("请核对整理结果。保存后仍是待确认，需要再次明确确认才进入安排。"))
                            .font(.subheadline).foregroundStyle(catColors.calmSecondary)
                        if let clarification, !clarification.isEmpty { Text(verbatim: clarification).font(.subheadline) }
                    } header: { Text(ui("AI 整理结果待核对 · 尚未保存")) }
                }
                Section {
                    TextField(ui("安排名称"), text: $title, axis: .vertical).lineLimit(1...5)
                        .accessibilityIdentifier("parenting.arrangement.title")
                    if arrangement == nil && cleanedTitle.isEmpty && !cleanedSource.isEmpty && cleanedSource.count <= 160 {
                        Button(ui("用原话作为安排名称")) { title = cleanedSource }.frame(minHeight: 44)
                    }
                    Button { timePresented = true } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(ui("安排时间")).foregroundStyle(catColors.ink)
                            Spacer()
                            if let dueAt {
                                Text(verbatim: dueAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(catColors.actionText).multilineTextAlignment(.trailing)
                            } else { Text(ui("请选择时间")).foregroundStyle(catColors.actionText) }
                        }.frame(minHeight: 44)
                    }
                    .disabled(consentPresentation != nil || intake.consent != nil)
                    .accessibilityIdentifier("parenting.arrangement.time")
                    if dueAt == nil {
                        Text(ui("还没有明确时间，请选择后再保存。"))
                            .font(catTypography.Role.caption.font).foregroundStyle(catColors.attention)
                    }
                    if cleanedTitle.count > 160 { ParentingFormIssue(message: "安排名称不能超过 160 字。") }
                } header: { Text(ui(arrangement == nil ? "核对安排内容" : "调整安排内容")) }
                footer: { Text(ui("安排只保存在本机，不会添加系统日历，也不会发送提醒。")) }
                if let arrangement {
                    Section {
                        Text(verbatim: arrangement.sourceText).font(.subheadline).textSelection(.enabled)
                        Text(ui("调整名称和时间不会覆盖当时填写的原话。"))
                            .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                    } header: { Text(ui("最初的原话")) }
                }
                if !validReference { ParentingFormIssue(message: "这条安排已变更或删除，请关闭此页后查看最新内容。") }
                if let saveError { ParentingFormIssue(message: saveError); ParentingReloadButton(model: model) }
                Section {
                    Button { save() } label: {
                        HStack {
                            if saving { ProgressView() }
                            Text(ui(saving ? "正在保存" : arrangement == nil ? "保存为待确认" : "保存调整"))
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(ParentingPrimaryButtonStyle())
                    .disabled(!valid || saving || model.busy || intake.busy || intakeCallID != nil)
                    .accessibilityIdentifier("parenting.arrangement.save")
                }.listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden).background(catColors.background)
            .foregroundStyle(catColors.ink).scrollDismissesKeyboard(.interactively)
            .disabled(saving || model.busy)
            .navigationTitle(ui(arrangement == nil ? "记一件事" : "调整安排"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ui("取消")) {
                        if hasUnsavedChanges { discardConfirmation = true } else { dismiss() }
                    }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving || hasUnsavedChanges)
            .alert(ui("放弃未保存的内容？"), isPresented: $discardConfirmation) {
                Button(ui("继续填写"), role: .cancel) { }
                Button(ui("放弃并关闭"), role: .destructive) { dismiss() }
            } message: { Text(ui("当前表单尚未保存。关闭后将丢弃填写内容并停止接收本次整理结果；已经发出的请求不保证在服务端停止。")) }
        }
        .tint(catColors.actionText)
        .onAppear { admissionGate.active = scenePhase == .active }
        .onChange(of: scenePhase) { _, phase in
            admissionGate.active = phase == .active
            if phase != .active { stopIntake() }
        }
        .onChange(of: sourceText) { _, _ in invalidateIntake() }
        .onChange(of: childID) { _, _ in invalidateIntake() }
        .onChange(of: goalID) { _, _ in invalidateIntake() }
        .onChange(of: intake.consentID) { _, _ in reconcileConsent() }
        .onChange(of: intake.recoveredRequest) { _, reference in
            if let reference { restoreInput(reference) }
        }
        .onDisappear {
            admissionGate.active = false
            stopIntake()
        }
        .sheet(isPresented: $timePresented, onDismiss: reconcileConsent) {
            ParentingTimePicker(initial: dueAt) { selected in dueAt = selected }
        }
        .sheet(item: consentBinding, onDismiss: { consentDidDismiss(owner: renderedConsentOwner) }) { presentation in
            ConversationModelConsentView(consent: presentation.consent,
                canAllow: intake.consentID == presentation.id && scenePhase == .active &&
                    admissionGate.active && chat.networkAdmissionAllowed && intakeCallID == nil,
                allow: {
                    runIntake(allowWhileBusy: true) { await intake.allowConsent(matchingID: presentation.id) }
                },
                deferConsent: { intake.deferConsent(matchingID: presentation.id) })
                .modifier(catPrivacyShield(lockedText: ui("解锁后查看育儿记录"), identifier: "parenting.inlineConsent.privacyShield"))
        }
    }

    private var sourceSection: some View {
        Section {
            TextEditor(text: $sourceText).frame(minHeight: 110)
                .accessibilityLabel(ui("想为孩子做的一件事"))
                .accessibilityIdentifier("parenting.arrangement.source")
            if sourceText.count > 3000 && sourceText.count <= 8000 {
                Text(ui("AI 整理最多接收 3000 字。你可以缩短原话，或直接手动填写安排。"))
                    .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            }
            if sourceText.count > 8000 { ParentingFormIssue(message: "原话不能超过 8000 字。") }
        } header: { Text(ui("先用自己的话交代一件事")) }
        footer: { Text(ui("本页内容尚未保存。可以让小咪在这里整理，也可以手动填写下方安排；整理结果需要你核对和采用。")) }
    }

    private var canRequestIntake: Bool {
        !cleanedSource.isEmpty && sourceText.count <= 3000 &&
            model.workspace.children.contains { $0.id == childID } &&
            !saving && !model.busy && !intake.busy && !intake.deletionPending &&
            intakeCallID == nil && scenePhase == .active
    }

    private var inlineIntakeSection: some View {
        Section {
            Text(ui("点击后，将发送选定原话及当前时间、时区到现有已选 AI 服务，不会自动附上家庭档案。需要发送许可时会先请你确认。"))
                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            Text(ui("原话与回复只在小咪服务端临时内存处理，不写入长期记忆，临时内容最多可读取 15 分钟。模型服务商的数据处理方式以发送许可中的说明为准。"))
                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            DisclosureGroup(ui("查看将发送的原话")) {
                Text(verbatim: sourceText).font(.subheadline).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.subheadline)
            DisclosureGroup(ui("整理记录的保存与清理")) {
                Text(ui("本机为中断恢复加密暂存本次整理记录。超过 24 小时不再恢复，到期记录在下次打开或清理时处理。"))
                    .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                Text(ui("采用、取消或修改原话会清理独立的临时整理记录；表单中的原话和已保存安排的来源不受影响。清理失败时会提示，并保留不含原话的清理重试标识。"))
                    .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                Text(ui("采用、取消或删除时会请求清理服务端临时内容，服务器仅保留请求标识和哈希以防重复。清理不能撤回已经发送给模型服务商的数据。"))
                    .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            }.font(.subheadline)
            switch intake.phase {
            case .idle, .ready, .cancelled:
                Button {
                    beginIntake()
                } label: { Label(ui("让小咪整理"), systemImage: "sparkles").frame(maxWidth: .infinity) }
                .buttonStyle(ParentingPrimaryButtonStyle()).disabled(!canRequestIntake)
                .accessibilityIdentifier("parenting.arrangement.aiIntake")
                if intake.phase == .cancelled {
                    Text(ui("已停止等待，本次结果不会填入。已经发出的请求不保证在服务端停止。"))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                }
            case .preparing, .sending:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(ui(intake.phase == .preparing ? "正在准备整理请求" : "小咪正在整理"))
                        .font(.subheadline)
                }.accessibilityIdentifier("parenting.inline.loading")
                stopIntakeButton
            case .awaitingConsent:
                Text(ui("等待你确认发送许可。未允许前不会发送这次整理。"))
                    .font(.subheadline).foregroundStyle(catColors.calmSecondary)
                Button(ui("查看发送许可")) { reconcileConsent() }.frame(minHeight: 44)
                stopIntakeButton
            case .failed:
                if let error = intake.error { ParentingFormIssue(message: error) }
                if intake.canRetry {
                    Button(ui("重试本次整理")) { runIntake { await intake.retry() } }
                        .frame(minHeight: 44).disabled(!canRequestIntake)
                        .accessibilityIdentifier("parenting.inline.retry")
                } else {
                    Button(ui("重新发起整理")) { beginIntake() }
                        .frame(minHeight: 44).disabled(!canRequestIntake)
                        .accessibilityIdentifier("parenting.inline.freshAttempt")
                }
            case .unknown:
                Text(ui("本次整理的结果尚未确认。请检查原请求，避免重复发送。"))
                    .font(.subheadline).foregroundStyle(catColors.attention)
                if let error = intake.error { ParentingFormIssue(message: error) }
                Button(ui("检查本次结果")) { runIntake { await intake.reconcile() } }
                    .frame(minHeight: 44).disabled(!canRequestIntake || !intake.canReconcile)
                    .accessibilityIdentifier("parenting.inline.reconcile")
                stopIntakeButton
            }
            if intake.phase == .ready, let candidate = intake.candidate {
                candidatePreview(candidate)
            }
            if let recoveryNotice {
                Text(ui(recoveryNotice)).font(.subheadline).foregroundStyle(catColors.calmSecondary)
                    .accessibilityIdentifier("parenting.inline.recoveryStatus")
            }
            if intake.recoveryAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Button(ui("恢复上次整理")) {
                        guard canRecoverIntake else { return }
                        recoveryRequested = true
                        recoveryNotice = nil
                        runIntake {
                            await intake.recover()
                            if let reference = intake.recoveredRequest { restoreInput(reference) }
                        }
                    }
                    .frame(minHeight: 44).disabled(!canRecoverIntake)
                    .accessibilityIdentifier("parenting.inline.recover")
                    Text(ui("读取上次整理，不会重新发送。点击会将上次的原话及孩子、目标选择带回此页，替换当前原话；安排名称和时间仍由你核对。"))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                    Text(ui("服务重启或 15 分钟后，服务端内容可能无法读取。恢复的本机原话可继续手动填写，不会因此在后台重复发送。"))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                }
            }
            if intake.deletionPending {
                VStack(alignment: .leading, spacing: 8) {
                    Label(ui("本次临时整理记录尚未完成清理"), systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(catColors.attention)
                    Text(ui("请先重试清理，再发起新的整理。表单原话和已保存的安排不受影响。"))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                    if let error = intake.deletionError { ParentingFormIssue(message: error) }
                    Button {
                        guard !cleanupRunning, !saving, !model.busy else { return }
                        cleanupRunning = true
                        Task {
                            await intake.retryDeletion()
                            cleanupRunning = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if cleanupRunning { ProgressView() }
                            Text(ui(cleanupRunning ? "正在重试清理" : "重试清理"))
                        }.frame(minHeight: 44)
                    }
                    .disabled(cleanupRunning || saving || model.busy || intakeCallID != nil)
                    .accessibilityIdentifier("parenting.inline.retryCleanup")
                }
                .accessibilityIdentifier("parenting.inline.cleanupPending")
            } else if intake.recoveryAvailable || intake.candidate != nil {
                Button(ui("删除本次整理记录"), role: .destructive) { deleteIntakeRecord() }
                    .frame(minHeight: 44).disabled(saving || model.busy || cleanupRunning)
                    .accessibilityIdentifier("parenting.inline.deleteRecord")
            }
        } header: { Text(ui("让小咪帮你整理")) }
        footer: { Text(ui("整理不会保存或确认安排，也不会创建日历或提醒。离开或切到后台会停止本页等待并尝试清理临时副本，不影响表单原话和已保存安排。")) }
    }

    private var stopIntakeButton: some View {
        Button(ui("停止等待本次整理")) { stopIntake() }.frame(minHeight: 44)
            .accessibilityIdentifier("parenting.inline.cancel")
    }

    private func candidatePreview(_ candidate: ParentingIntakeDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui("整理建议 · 尚未采用或保存")).font(.headline)
            Text(verbatim: candidate.title).font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            if let date = candidate.dueAt {
                Text(verbatim: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(catColors.calmSecondary)
            } else {
                Text(ui("时间待补充，采用后仍需选择明确时间。"))
                    .font(.subheadline).foregroundStyle(catColors.attention)
            }
            if let clarification = candidate.clarification, !clarification.isEmpty {
                Text(verbatim: clarification).font(.subheadline).foregroundStyle(catColors.calmSecondary)
            }
            Text(ui("采用后会替换下方的安排名称和时间。你可以继续修改，原话会保留。"))
                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            Button(ui("采用整理结果")) {
                guard matchesCurrentCandidate(candidate),
                      scenePhase == .active, !saving, !model.busy else { return }
                fillCandidate(candidate)
                intake.consumeCandidate()
            }
            .buttonStyle(ParentingSecondaryButtonStyle())
            .disabled(!matchesCurrentCandidate(candidate) || intakeCallID != nil || saving || model.busy)
            .accessibilityIdentifier("parenting.inline.adopt")
        }
        .padding(.vertical, 8).accessibilityIdentifier("parenting.inline.candidate")
    }

    private func fillCandidate(_ candidate: ParentingIntakeDraft) {
        title = candidate.title
        dueAt = candidate.dueAt
        clarification = candidate.clarification
        imported = true
        recoveryNotice = nil
        recoveredInput = nil
    }
    private func matchesCurrentCandidate(_ candidate: ParentingIntakeDraft) -> Bool {
        intake.isCurrentCandidate(candidate) && candidate.sourceText == sourceText &&
            candidate.childID == childID && candidate.goalID == goalID
    }
    private func beginIntake() {
        guard canRequestIntake, let childID else { return }
        let source = sourceText
        let selectedGoal = goalID
        recoveryRequested = false
        recoveryNotice = nil
        runIntake { await intake.request(sourceText: source, childID: childID, goalID: selectedGoal) }
    }
    private var canRecoverIntake: Bool {
        !saving && !model.busy && !intake.busy && !intake.deletionPending && intakeCallID == nil &&
            scenePhase == .active && intake.phase != .unknown && intake.consent == nil
    }
    private func restoreInput(_ reference: ParentingIntakeRecoveryReference) {
        guard recoveryRequested, scenePhase == .active, admissionGate.active, !saving, !model.busy else { return }
        let child = model.workspace.children.first { $0.id == reference.childID }
        let goal = model.workspace.goals.first { $0.id == reference.goalID && $0.childID == child?.id }
        let missingReference = child == nil || (reference.goalID != nil && goal == nil)
        let snapshot = ParentingRecoveredInput(sourceText: reference.sourceText, childID: child?.id, goalID: goal?.id)
        recoveredInput = snapshot
        recoveryRequested = false
        sourceText = snapshot.sourceText
        childID = snapshot.childID
        goalID = snapshot.goalID
        imported = false
        clarification = nil
        if missingReference {
            intake.invalidate()
            recoveryNotice = "上次的原话已带回，但关联的孩子或目标已删除。请明确改选后重新整理，也可以手动填写。"
        } else {
            recoveryNotice = "已读取上次整理。原话与选择已恢复；整理建议仍需你明确采用，才会填入安排。"
        }
    }
    private func runIntake(allowWhileBusy: Bool = false, _ action: @escaping @MainActor () async -> Void) {
        guard intakeCallID == nil, (allowWhileBusy || !intake.busy), !saving, !model.busy,
              scenePhase == .active, admissionGate.active else { return }
        let callID = UUID()
        intakeCallID = callID
        intakeTask = Task {
            defer {
                if intakeCallID == callID { intakeCallID = nil; intakeTask = nil }
            }
            guard !Task.isCancelled, intakeCallID == callID, admissionGate.active else { return }
            await action()
        }
    }
    private func stopIntake() {
        recoveryRequested = false
        recoveryNotice = nil
        recoveredInput = nil
        intake.cancel()
        intakeCallID = nil
        intakeTask?.cancel()
        intakeTask = nil
    }
    private func deleteIntakeRecord() {
        guard !saving, !model.busy else { return }
        recoveryRequested = false
        recoveredInput = nil
        recoveryNotice = nil
        intake.deleteLocalRecord()
        intakeCallID = nil
        intakeTask?.cancel()
        intakeTask = nil
    }
    private func invalidateIntake() {
        if let recoveredInput, recoveredInput.sourceText == sourceText,
           recoveredInput.childID == childID, recoveredInput.goalID == goalID { return }
        recoveredInput = nil
        recoveryRequested = false
        recoveryNotice = nil
        intake.invalidate()
        intakeCallID = nil
        intakeTask?.cancel()
        intakeTask = nil
        imported = false
        clarification = nil
    }
    private var consentBinding: Binding<ParentingInlineConsentPresentation?> {
        let renderedOwner = consentPresentation?.id
        return Binding(get: { consentPresentation }, set: { value in
            guard value == nil, let owner = renderedOwner,
                  consentPresentation?.id == owner, closingConsentID == nil else { return }
            closingConsentID = owner
            consentPresentation = nil
            intake.deferConsent(matchingID: owner)
        })
    }
    private func reconcileConsent() {
        if let active = consentPresentation {
            if active.id != intake.consentID {
                closingConsentID = active.id
                consentPresentation = nil
            }
            return
        }
        guard closingConsentID == nil, !timePresented, scenePhase == .active, admissionGate.active,
              let id = intake.consentID, let consent = intake.consent else { return }
        consentPresentation = .init(id: id, consent: consent)
    }
    private func consentDidDismiss(owner: UUID?) {
        guard let owner, closingConsentID == owner else { return }
        intake.deferConsent(matchingID: owner)
        closingConsentID = nil
        reconcileConsent()
    }
    private func save() {
        guard valid, !saving, !model.busy, !intake.busy, intakeCallID == nil, let childID, let dueAt else { return }
        let command: ParentingCommand
        if let arrangement {
            command = .editArrangement(id: arrangement.id, title: cleanedTitle, dueAt: dueAt, goalID: goalID)
        } else {
            command = .createDraft(id: entityID, childID: childID, title: cleanedTitle,
                                   dueAt: dueAt, goalID: goalID, sourceText: sourceText)
        }
        if let submittedCommand, submittedCommand != command { operationID = UUID() }
        submittedCommand = command
        saving = true
        saveError = nil
        Task {
            let success = await model.apply(command, operationID: operationID)
            saving = false
            if success { dismiss() }
            else { saveError = model.error ?? "保存未完成，请重试。" }
        }
    }
}

@MainActor private final class ParentingEditorAdmissionGate: ObservableObject {
    @Published var active = false
}
private struct ParentingInlineConsentPresentation: Identifiable {
    let id: UUID
    let consent: ConversationModelConsent
}
private struct ParentingRecoveredInput {
    let sourceText: String
    let childID: UUID?
    let goalID: UUID?
}

@MainActor private struct ParentingTimePicker: View {
    let onChoose: (Date) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Date
    init(initial: Date?, onChoose: @escaping (Date) -> Void) {
        self.onChoose = onChoose
        _selected = State(initialValue: initial ?? Date())
    }
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(ui("选择安排日期和时间"), selection: $selected, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .accessibilityIdentifier("parenting.timePicker")
                } footer: { Text(ui("只有点击“使用这个时间”，才会填写到安排中。")) }
                Section {
                    Text(verbatim: selected.formatted(date: .complete, time: .shortened))
                        .font(.headline).accessibilityIdentifier("parenting.timePreview")
                    Button(ui("使用这个时间")) { onChoose(selected); dismiss() }
                        .buttonStyle(ParentingPrimaryButtonStyle())
                        .accessibilityIdentifier("parenting.time.confirm")
                }
            }
            .scrollContentBackground(.hidden).background(catColors.background)
            .navigationTitle(ui("安排时间")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() } } }
        }.tint(catColors.actionText)
            .modifier(catPrivacyShield(lockedText: ui("解锁后查看育儿记录"), identifier: "parenting.time.privacyShield"))
    }
}

@MainActor private struct ParentingChildGoalFields: View {
    let workspace: ParentingWorkspace
    @Binding var childID: UUID?
    @Binding var goalID: UUID?
    var childEditable = true
    @Environment(\.locale) private var locale
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var goals: [ParentingGoal] { workspace.goals.filter { $0.childID == childID } }
    var body: some View {
        Section {
            if childEditable {
                Picker(ui("孩子"), selection: $childID) {
                    Text(ui("请选择孩子")).tag(UUID?.none)
                    ForEach(workspace.children) { child in Text(verbatim: child.name).tag(Optional(child.id)) }
                }.accessibilityIdentifier("parenting.editor.child")
            } else {
                LabeledContent(ui("孩子")) {
                    Text(verbatim: workspace.children.first { $0.id == childID }?.name ?? ui("孩子已删除"))
                }
            }
            Picker(ui("关联成长目标"), selection: $goalID) {
                Text(ui("不关联目标")).tag(UUID?.none)
                ForEach(goals) { goal in Text(verbatim: goal.title).tag(Optional(goal.id)) }
            }.accessibilityIdentifier("parenting.editor.goal")
        } footer: { Text(ui("成长目标可选，不影响保存。")) }
        .onChange(of: childID) { _, _ in
            if let goalID, !goals.contains(where: { $0.id == goalID }) { self.goalID = nil }
        }
        .onChange(of: workspace.goals.map(\.id)) { _, _ in
            if let goalID, !goals.contains(where: { $0.id == goalID }) { self.goalID = nil }
        }
        .onChange(of: workspace.children.map(\.id)) { _, ids in
            if childEditable, let childID, !ids.contains(childID) { self.childID = nil }
        }
    }
}

@MainActor private struct ParentingRecordEditor: View {
    enum Mode {
        case observation(UUID?, UUID?)
        case edit(ParentingRecord)
        case completion(ParentingArrangement)
    }
    @ObservedObject var model: ParentingWorkspaceModel
    let mode: Mode
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var entityID = UUID()
    @State private var operationID = UUID()
    @State private var childID: UUID?
    @State private var goalID: UUID?
    @State private var text: String
    @State private var saving = false
    @State private var saveError: String?
    @State private var submittedCommand: ParentingCommand?

    init(model: ParentingWorkspaceModel, mode: Mode) {
        self.model = model
        self.mode = mode
        switch mode {
        case .observation(let childID, let goalID):
            let onlyChild = model.workspace.children.count == 1 ? model.workspace.children.first?.id : nil
            _childID = State(initialValue: childID ?? onlyChild)
            _goalID = State(initialValue: goalID)
            _text = State(initialValue: "")
        case .edit(let record):
            _childID = State(initialValue: record.childID)
            _goalID = State(initialValue: record.goalID)
            _text = State(initialValue: record.text)
        case .completion(let arrangement):
            _childID = State(initialValue: arrangement.childID)
            _goalID = State(initialValue: arrangement.goalID)
            _text = State(initialValue: "")
        }
    }
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    private var cleaned: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var completion: Bool { if case .completion = mode { return true }; return false }
    private var isNewObservation: Bool { if case .observation = mode { return true }; return false }
    private var title: String {
        switch mode { case .observation: "记下观察"; case .edit: "更正记录"; case .completion: "完成并记录" }
    }
    private var valid: Bool {
        model.workspace.children.contains { $0.id == childID } && text.count <= 8000 && (completion || !cleaned.isEmpty) && validReference
    }
    private var validReference: Bool {
        switch mode {
        case .observation: true
        case .edit(let record): model.workspace.records.contains { $0.id == record.id }
        case .completion(let arrangement): model.workspace.arrangements.contains { $0.id == arrangement.id && $0.state == .planned }
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if isNewObservation {
                    ParentingChildGoalFields(workspace: model.workspace, childID: $childID, goalID: $goalID)
                }
                if case .completion(let arrangement) = mode {
                    Section {
                        Text(verbatim: arrangement.title).font(.headline)
                        Text(verbatim: arrangement.dueAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(catColors.calmSecondary)
                        Text(ui("这表示由家长确认完成，不代表已核验孩子的成长结果。"))
                            .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                    } header: { Text(ui("要标记完成的安排")) }
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 150)
                        .accessibilityLabel(ui(completion ? "完成说明，可选" : "记录内容"))
                        .accessibilityIdentifier("parenting.record.text")
                    if text.count > 8000 { ParentingFormIssue(message: "记录不能超过 8000 字。") }
                } header: { Text(ui(completion ? "实际发生了什么（可选）" : "写下实际发生的事")) }
                footer: {
                    Text(ui(completion ? "不填写说明时，将用安排名称生成一条家长完成记录。" : "用自己的话记录看到或听到的事。最多 8000 字，不会自动变成安排。"))
                }
                if case .edit(let record) = mode {
                    Section {
                        if record.sourceText.isEmpty { Text(ui("家长确认完成，未填写补充说明。")) }
                        else { Text(verbatim: record.sourceText).textSelection(.enabled) }
                        Text(verbatim: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                    } header: { Text(ui("最初保存的内容")) }
                    footer: { Text(ui("更正只更新记录正文，最初的内容与创建时间会保留。")) }
                }
                if !validReference { ParentingFormIssue(message: "原记录或安排已变更，请关闭此页后查看最新内容。") }
                if let saveError { ParentingFormIssue(message: saveError); ParentingReloadButton(model: model) }
                Section {
                    Button { save() } label: {
                        HStack {
                            if saving { ProgressView() }
                            Text(ui(saving ? "正在保存" : completion ? "确认完成并保存记录" : "保存记录"))
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(ParentingPrimaryButtonStyle())
                        .disabled(!valid || saving || model.busy)
                        .accessibilityIdentifier("parenting.record.save")
                }.listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden).background(catColors.background)
            .foregroundStyle(catColors.ink).scrollDismissesKeyboard(.interactively)
            .disabled(saving || model.busy)
            .navigationTitle(ui(title)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ui("取消")) { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
        }.tint(catColors.actionText)
    }
    private func save() {
        guard valid, !saving, !model.busy, let childID else { return }
        let command: ParentingCommand
        switch mode {
        case .observation: command = .addObservation(id: entityID, childID: childID, goalID: goalID, text: text)
        case .edit(let record): command = .editRecord(id: record.id, text: text)
        case .completion(let arrangement): command = .completeArrangement(id: arrangement.id, recordID: entityID, note: text)
        }
        if let submittedCommand, submittedCommand != command { operationID = UUID() }
        submittedCommand = command
        saving = true
        saveError = nil
        Task {
            let success = await model.apply(command, operationID: operationID)
            saving = false
            if success { dismiss() }
            else { saveError = model.error ?? "保存未完成，请重试。" }
        }
    }
}

private struct ParentingFormIssue: View {
    let message: String
    @Environment(\.locale) private var locale
    var body: some View {
        Text(AppLanguage(locale: locale).ui(message)).font(.subheadline)
            .foregroundStyle(catColors.failure)
            .accessibilityIdentifier("parenting.form.error")
    }
}

@MainActor private struct ParentingReloadButton: View {
    @ObservedObject var model: ParentingWorkspaceModel
    @Environment(\.locale) private var locale
    @State private var message: String?
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(ui("重新读取本机记录")) {
                guard !model.busy else { return }
                Task {
                    await model.load()
                    message = model.error ?? "已重新读取。请核对填写内容，再点击保存。"
                }
            }.frame(minHeight: 44).disabled(model.busy)
            Text(ui("重新读取会保留表单内容，不会自动重试保存。"))
                .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
            if let message { Text(ui(message)).font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary) }
        }
    }
}

@MainActor private struct ParentingSettingsView: View {
    @ObservedObject var model: ParentingWorkspaceModel
    let accountLabel: String?
    let isAnonymousAccount: Bool
    let onSignOut: (() -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var operationID = UUID()
    @State private var signOutConfirmation = false
    @State private var signingOut = false
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(ui("当前账户")) { Text(verbatim: accountLabel ?? ui(isAnonymousAccount ? "未登录" : "本机账户")) }
                    if let onSignOut {
                        Button(ui("退出登录"), role: .destructive) { signOutConfirmation = true }
                            .disabled(model.busy || signingOut)
                            .alert(ui("退出登录？"), isPresented: $signOutConfirmation) {
                                Button(ui("取消"), role: .cancel) { }
                                Button(ui("退出登录"), role: .destructive) {
                                    guard !signingOut, !model.busy else { return }
                                    signingOut = true
                                    dismiss()
                                    onSignOut()
                                }
                            } message: {
                                Text(ui(isAnonymousAccount
                                    ? "体验身份暂时无法找回。退出后，育儿记录仍加密保留在本机，但你可能无法再次访问。"
                                    : "此设备上的育儿记录会加密保留，重新登录同一账户后可继续查看。"))
                            }
                    }
                } header: { Text(ui("账户")) }
                Section {
                    Toggle(ui("显示回顾提示"), isOn: Binding(
                        get: { model.workspace.suggestionsEnabled },
                        set: { value in
                            guard !model.busy else { return }
                            Task {
                                if await model.apply(.setSuggestionsEnabled(value), operationID: operationID) { operationID = UUID() }
                            }
                        }))
                        .disabled(model.busy || !model.loaded)
                        .accessibilityIdentifier("parenting.suggestions.toggle")
                    Text(ui("仅根据已保存的安排和目标整理提示，可随时关闭。不会评估孩子，也不会自动执行任何事。"))
                        .font(catTypography.Role.caption.font).foregroundStyle(catColors.calmSecondary)
                } header: { Text(ui("回顾提示")) }
                Section {
                    Text(ui("育儿资料仅在此设备加密保存，尚未云同步。更换设备不会自动带回这些记录。"))
                    Text(ui("本机安排不会添加系统日历，也不会发送提醒。记录会保留直到你主动删除。"))
                    Text(ui("辅助对话沿用现有模型连接和发送授权。只有你明确发送的内容才会交给已连接的服务处理。"))
                    Button(ui("重新读取本机记录")) { Task { await model.load() } }
                        .frame(minHeight: 44).disabled(model.busy)
                    if let error = model.error { ParentingFormIssue(message: error) }
                } header: { Text(ui("数据与边界")) }
                Section {
                    let info = AppBuildInfo.current
                    LabeledContent(ui("版本")) { Text(verbatim: info.version ?? "—") }
                    LabeledContent(ui("构建")) { Text(verbatim: info.build ?? "—") }
                } header: { Text(ui("关于")) }
            }
            .scrollContentBackground(.hidden).background(catColors.background)
            .foregroundStyle(catColors.ink)
            .navigationTitle(ui("育儿工作区设置")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ui("完成")) { dismiss() } } }
        }.tint(catColors.actionText)
            .modifier(catPrivacyShield(lockedText: ui("解锁后查看育儿记录"), identifier: "parenting.settings.privacyShield"))
    }
}
