import SwiftUI

enum OpenMuseDemoMode: String, CaseIterable { case fixture, loopback }

@MainActor final class OpenMuseDemoModel: ObservableObject {
    @Published var mode = OpenMuseDemoMode.fixture
    @Published var sessions: [OpenMuseTaskSession] = []
    @Published var busy = false
    @Published var connected = false
    @Published var error: String?
    @Published var preview: OpenMuseApprovalPreview?
    @Published var source: OpenMuseTaskSession?
    private let fixture: OpenMuseTaskService
    private let facade: OpenMuseTaskService
    private let http: OpenMuseFacadeHTTPTransport
    private var generation = 0
    init(repository: Repository, fixture: OpenMuseTaskService) {
        self.fixture = fixture
        // Compile-time composition, never a discovered URL, user credential or cloud fallback.
        http = OpenMuseFacadeHTTPTransport(configuration: try! OpenMuseFacadeConfiguration())
        facade = OpenMuseTaskService(repository: repository, transport: http)
    }
    var service: OpenMuseTaskService { mode == .fixture ? fixture : facade }
    var provenance: OpenMuseProvenance { mode == .fixture ? .fixtureTransport : .localSyntheticFacade }
    var mayWrite: Bool { mode == .fixture || connected }
    func load(recover: Bool = false) async {
        let selected = service, selectedProvenance = provenance, epoch = generation
        do {
            if recover { try await fixture.recover(scope: Profiles.demo) } // local only; no startup HTTP
            let values = try await selected.sessions(scope: Profiles.demo).filter { $0.provenance == selectedProvenance }
                .sorted { $0.request.input.operationID.uuidString < $1.request.input.operationID.uuidString }
            if epoch == generation { sessions = values }
        } catch { if epoch == generation { self.error = error.localizedDescription } }
    }
    func select(_ next: OpenMuseDemoMode) {
        guard !busy else { return }; generation += 1; preview = nil; source = nil; mode = next; error = nil
        Task { await load() }
    }
    func perform(_ action: @escaping (OpenMuseTaskService) async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        let selected = service, epoch = generation
        Task {
            do { try await action(selected) } catch { if epoch == generation { self.error = error.localizedDescription } }
            if epoch == generation { await load(); busy = false }
        }
    }
    func connect() {
        let epoch = generation
        perform { _ in try await self.http.inspectCapabilities(); if epoch == self.generation { self.connected = true } }
    }
    func prepare(environmentID: UUID) {
        perform { service in
            _ = try await service.prepare(OpenMuseTaskInput(scope: Profiles.demo, environmentID: environmentID,
                title: "Synthetic report", goal: "Summarize Alpha and Beta synthetic records.",
                requirements: "Use only built-in synthetic records. Prepare a local preview, never send externally.",
                stopConditions: ["Stop after a synthetic preview proposal."], syntheticFixture: .previewUnknown))
        }
    }
    func openPreview(_ session: OpenMuseTaskSession, proposalID: String) {
        let epoch = generation
        perform { service in
            let frozen = try await service.preview(operationID: session.request.input.operationID, scope: Profiles.demo, proposalID: proposalID)
            if epoch == self.generation { self.preview = frozen }
        }
    }
    func decide(_ frozen: OpenMuseApprovalPreview, decision: OpenMuseDecision) {
        preview = nil
        perform { service in _ = try await service.decide(frozen, decision: decision) }
    }
    func leave() async {
        generation += 1; preview = nil; source = nil
        let selected = service
        for session in sessions where session.admission != .notSent && session.control == .active {
            do { try await selected.stopObserving(operationID: session.request.input.operationID, scope: Profiles.demo) }
            catch { self.error = error.localizedDescription }
        }
        busy = false
    }
}

@MainActor struct OpenMuseDemoView: View {
    @ObservedObject var appModel: AppModel
    @StateObject private var demo: OpenMuseDemoModel
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var phase
    private func ui(_ key: String) -> String { AppLanguage(locale: locale).ui(key) }
    init(model: AppModel) {
        appModel = model
        _demo = StateObject(wrappedValue: OpenMuseDemoModel(repository: model.repository, fixture: model.openMuseFixtureService))
    }
    var body: some View {
        Page {
            if appModel.scope != Profiles.demo {
                EmptyState(title: ui("仅演示数据分区可用"), detail: ui("在设置开启演示数据分区，并切换到本机。"))
            } else {
                Panel {
                    Text(ui("合成任务演示")).font(.title2.weight(.semibold))
                    Text(ui("固定合成资料，主动提交；真实云端与模型尚未接入。")).font(.subheadline).foregroundStyle(CatpawColors.secondary)
                    Picker(ui("执行来源"), selection: Binding(get: { demo.mode }, set: { demo.select($0) })) {
                        Text(ui("具名 Fixture")).tag(OpenMuseDemoMode.fixture)
                        Text(ui("本机 Facade · 8796")).tag(OpenMuseDemoMode.loopback)
                    }.pickerStyle(.menu).disabled(demo.busy).accessibilityIdentifier("openmuse.mode")
                    if demo.mode == .loopback {
                        Text(ui("仅连接 127.0.0.1:8796。合成身份不是账号授权。")).font(.footnote).foregroundStyle(CatpawColors.secondary)
                        Button(ui("检查本机服务")) { demo.connect() }.touchTarget().disabled(demo.busy)
                            .accessibilityIdentifier("openmuse.connect")
                        if demo.connected { StatusLabel(text: ui("合同能力已读回 · 本机合成服务"), tone: .success) }
                    } else { StatusLabel(text: ui("纯 Fixture · 无网络与真实模型"), tone: .attention) }
                    Button(ui("准备合成任务")) { demo.prepare(environmentID: appModel.environmentID) }
                        .primaryAction().disabled(demo.busy || !demo.mayWrite).accessibilityIdentifier("openmuse.prepare")
                }
                if let error = demo.error { Panel { Text(ui("操作未完成")).font(.headline); Text(error).font(.footnote).textSelection(.enabled).foregroundStyle(CatpawColors.failure) }.accessibilityIdentifier("openmuse.error") }
                if demo.sessions.isEmpty { EmptyState(title: ui("尚无任务"), detail: ui("先保存独立身份与冻结请求，再主动提交。")) }
                ForEach(demo.sessions, id: \.request.input.operationID) { session in recovery(session) }
            }
        }
        .navigationTitle(ui("OpenMuse · 合成 Demo"))
        .task { if appModel.scope == Profiles.demo { await demo.load(recover: true) } }
        .onDisappear { Task { await demo.leave() } }
        .onChange(of: phase) { _, next in
            if next != .active { Task { await demo.leave() } }
            else { Task { await demo.load() } }
        }
        .sheet(isPresented: Binding(get: { demo.preview != nil }, set: { if !$0 { demo.preview = nil } })) {
            if let frozen = demo.preview { approval(frozen) }
        }
        .sheet(isPresented: Binding(get: { demo.source != nil }, set: { if !$0 { demo.source = nil } })) {
            if let session = demo.source { provenance(session) }
        }
    }
    private func state(_ s: OpenMuseTaskSession) -> String {
        if s.control == .revoked { return ui("已撤权 · 保留原记录") }
        if s.resumeRequiresNewRun { return ui("恢复已确认 · 旧 Run 保持暂停") }
        if s.control == .paused { return ui("已暂停 · 迟到结果受栅栏保护") }
        if s.admission == .notSent { return ui("请求已保存 · 尚未提交") }
        if s.admission == .unknown || s.admission == .dispatchCommitted { return ui("接纳结果未知 · 仅读回原任务") }
        if s.needsRead { return ui("等待读回原任务") }
        switch s.projection?.status {
        case .waitingApproval: return ui("待审批 · 查看冻结预览")
        case .outcomeUnknown: return ui("效果未知 · 核验优先")
        case .succeeded: return ui("服务记录完成 · 独立效果未核验")
        case .failed: return ui("服务记录失败")
        case .cancelled: return ui("服务记录已取消")
        default: return ui("进行中 · 以任务读回为准")
        }
    }
    private func recovery(_ s: OpenMuseTaskSession) -> some View {
        let op = s.request.input.operationID
        return Panel {
            Text(ui("恢复与进度")).font(.headline)
            StatusLabel(text: state(s), symbol: s.needsRead ? "arrow.clockwise" : "circle.fill", tone: s.needsRead ? .attention : .active)
                .accessibilityIdentifier("openmuse.state.\(op)")
            DisclosureGroup(ui("独立身份与冻结请求")) {
                identity("Operation", op.uuidString); identity("Business Run", s.request.input.businessRunID.uuidString)
                identity("Delegation", s.request.input.delegationID.uuidString)
                identity("Server Task", s.serverTaskID ?? "—")
                identity("Client request SHA-256", s.request.requestHash)
                identity("Server request SHA-256", s.projection?.binding.serverRequestHash ?? "—")
            }.font(.footnote).tint(CatpawColors.accent)
            if let note = s.note { Text(note).font(.footnote).foregroundStyle(CatpawColors.secondary) }
            if s.admission == .notSent {
                Button(ui("提交已保存请求")) { demo.perform { _ = try await $0.admit(operationID: op, scope: Profiles.demo) } }
                    .primaryAction().disabled(demo.busy || !demo.mayWrite).accessibilityIdentifier("openmuse.admit.\(op)")
            } else if s.control == .active {
                Button(ui("读取原任务")) { demo.perform { _ = try await $0.refreshUntilStable(operationID: op, scope: Profiles.demo) } }
                    .touchTarget().disabled(demo.busy).accessibilityIdentifier("openmuse.read.\(op)")
                HStack {
                    Button(ui("暂停委托")) { demo.perform { _ = try await $0.control(operationID: op, scope: Profiles.demo, command: .pause) } }.touchTarget()
                    Button(ui("撤销授权"), role: .destructive) { demo.perform { _ = try await $0.control(operationID: op, scope: Profiles.demo, command: .revoke) } }.touchTarget()
                }.disabled(demo.busy || !demo.mayWrite)
            } else if s.control == .paused, s.serverControlConfirmed {
                if s.resumeRequiresNewRun {
                    Text(ui("新 Run 需要显式准备与提交；旧任务不会重新派发。")).font(.footnote).foregroundStyle(CatpawColors.secondary)
                    Button(ui("准备新 Run")) { demo.perform { _ = try await $0.prepareFreshRunAfterResume(operationID: op, scope: Profiles.demo) } }.touchTarget().disabled(demo.busy)
                } else {
                    Button(ui("恢复委托 · 准备新 Run")) { demo.perform { _ = try await $0.control(operationID: op, scope: Profiles.demo, command: .resume) } }.touchTarget().disabled(demo.busy || !demo.mayWrite)
                }
            }
            if s.control != .active, !s.serverControlConfirmed {
                Text(ui("本机已拦截；服务控制结果未确认。保持原记录，等待诊断。")).font(.footnote).foregroundStyle(CatpawColors.attention)
            }
            ForEach(s.approvals.keys.sorted(), id: \.self) { id in
                if let entry = s.approvals[id] {
                    Divider()
                    if entry.state == .pending {
                        Button(ui("查看审批预览")) { demo.openPreview(s, proposalID: id) }.touchTarget()
                            .disabled(demo.busy || s.needsRead || s.control != .active).accessibilityIdentifier("openmuse.preview.\(op)")
                    } else {
                        Text(entry.state.rawValue).font(.subheadline.weight(.semibold)).accessibilityIdentifier("openmuse.receiptState.\(op)")
                        Text(ui("审批已消费；不会提供重新发送。")).font(.footnote).foregroundStyle(CatpawColors.secondary)
                        if [.accepted, .unknown, .dispatchCommitted].contains(entry.state) {
                            Button(ui("读回原审批回执")) { demo.perform { _ = try await $0.reconcileReceipt(operationID: op, scope: Profiles.demo, proposalID: id) } }.touchTarget().disabled(demo.busy).accessibilityIdentifier("openmuse.receipt.\(op)")
                            Button(ui("检查本机效果记录")) { demo.perform { _ = try await $0.reconcileReceipt(operationID: op, scope: Profiles.demo, proposalID: id, performEvidenceCheck: true) } }.touchTarget().disabled(demo.busy).accessibilityIdentifier("openmuse.check.\(op)")
                        }
                        if let receipt = entry.receipt {
                            Text(receipt.providerStatus).font(.caption).foregroundStyle(CatpawColors.secondary)
                            ForEach(receipt.verificationEvidence, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                    }
                }
            }
            if !s.artifactHistory.isEmpty {
                Button(ui("成果与来源")) { demo.source = s }.touchTarget().accessibilityIdentifier("openmuse.source.\(op)")
            }
        }
    }
    private func approval(_ frozen: OpenMuseApprovalPreview) -> some View {
        NavigationStack {
            Page {
                Panel {
                    Text(ui("审批预览")).font(.title2.weight(.semibold))
                    Text(ui("仅本机合成预览。确认绑定当前正文、版本、hash 与目的地。")).font(.subheadline).foregroundStyle(CatpawColors.secondary)
                    identity(ui("目的地"), frozen.snapshot.destination)
                    identity(ui("成果版本"), "v\(frozen.artifact.reference.version)")
                    identity("SHA-256", frozen.artifact.reference.contentHash)
                    identity("Action digest", frozen.snapshot.serverActionDigest)
                    Text(frozen.artifact.body).textSelection(.enabled).accessibilityIdentifier("openmuse.previewBody")
                }
                Button(ui("确认本机合成预览")) { demo.decide(frozen, decision: .approve) }.primaryAction().disabled(demo.busy).accessibilityIdentifier("openmuse.approve")
                Button(ui("拒绝此审批"), role: .destructive) { demo.decide(frozen, decision: .deny) }.touchTarget().disabled(demo.busy)
            }.navigationTitle(ui("审批预览")).toolbar { Button(ui("关闭")) { demo.preview = nil } }
        }.tint(CatpawColors.accent)
    }
    private func provenance(_ s: OpenMuseTaskSession) -> some View {
        NavigationStack {
            Page {
                Panel {
                    Text(ui("成果与来源")).font(.title2.weight(.semibold))
                    StatusLabel(text: s.provenance == .fixtureTransport ? ui("纯 Fixture · 无网络与真实模型") : ui("本机合成 Facade · 真实云模型未验证"), tone: .attention)
                    Text(ui("本机服务记录不证明云端持久执行或独立副作用核验。")).font(.footnote).foregroundStyle(CatpawColors.secondary)
                    identity("Execution layer", s.projection?.executionLayer ?? s.provenance.rawValue)
                    identity("Server Task", s.serverTaskID ?? "—")
                    identity("Worker attempts", String(s.projection?.attempts ?? 0))
                }
                ForEach(s.artifactHistory, id: \.reference) { artifact in
                    Panel {
                        Text(artifact.title).font(.headline)
                        identity(ui("成果版本"), "v\(artifact.reference.version)")
                        identity("SHA-256", artifact.reference.contentHash)
                        Text(artifact.body).textSelection(.enabled).accessibilityIdentifier("openmuse.artifactBody")
                    }
                }
            }.navigationTitle(ui("成果与来源")).toolbar { Button(ui("关闭")) { demo.source = nil } }
        }.tint(CatpawColors.accent)
    }
    private func identity(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(CatpawColors.secondary)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
