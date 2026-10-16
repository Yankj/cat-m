import SwiftUI
import Combine

/// Server-driven `catpaw.model-routes.v1` list. Falls back to `ModelRoutesFixture` until the Edge endpoint is deployed.
@MainActor final class ModelRouteCatalog: ObservableObject {
    static let shared = ModelRouteCatalog()
    @Published private(set) var contract: ModelRoutesContract?
    @Published private(set) var loading = false
    @Published private(set) var usingFixture = false
    /// Last actual route/model reported by SSE `model_route` (header label).
    @Published private(set) var lastEvent: ModelRouteEvent?
    @Published var notice: ConversationSystemNotice.Kind?
    private var fetcher: (@Sendable () async -> ModelRoutesContract?)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelRouteNotifications.event, object: nil, queue: .main) { note in
            guard let event = note.object as? ModelRouteEvent else { return }
            MainActor.assumeIsolated { ModelRouteCatalog.shared.receive(event) }
        })
        observers.append(center.addObserver(forName: ModelRouteNotifications.rejected, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                ModelRouteCatalog.shared.notice = .routeRejected
                Task { await ModelRouteCatalog.shared.refresh() }
            }
        })
    }
    var routes: [ModelRouteInfo] { contract?.routes ?? [] }
    func install(_ fetch: @escaping @Sendable () async -> ModelRoutesContract?) {
        fetcher = fetch
        Task { await refresh() }
    }
    func refresh() async {
        loading = true
        defer { loading = false }
        if let live = await fetcher?() { contract = live; usingFixture = false }
        else { contract = ModelRoutesFixture.contract; usingFixture = true }
        ModelRouteSelection.cache(routes)
        // Selection no longer listed → back to auto so headers stay valid.
        let current = ModelRouteSelection.route
        if current != ModelRouteSelection.autoID, !routes.contains(where: { $0.id == current }) { ModelRouteSelection.resetToAuto() }
        objectWillChange.send()
    }
    func receive(_ event: ModelRouteEvent) {
        lastEvent = event
        if event.failover == true { notice = .route(ModelRouteSelection.displayName(event.route)) }
    }
    func displayName(_ id: String) -> String { routes.first { $0.id == id }?.display_name ?? id }

    /// Single state source for the settings 「模型」 section and the home model menu.
    /// selected = the user's choice; actual = latest SSE `model_route` route (auto) or the choice;
    /// online = connection online AND the actual route is not reported offline/degraded.
    struct Presence: Equatable {
        let selectedID: String
        let actualID: String?
        let online: Bool
        let failover: Bool
    }
    func presence(connection: ConnectionStatusKind) -> Presence {
        let selected = ModelRouteSelection.route
        let actual: String? = selected == ModelRouteSelection.autoID ? lastEvent?.route : selected
        var routeOK = true
        if let a = actual, let info = routes.first(where: { $0.id == a }) { routeOK = info.statusKind == .online }
        else if selected == ModelRouteSelection.autoID, !routes.isEmpty { routeOK = routes.contains { $0.statusKind == .online } }
        return Presence(selectedID: selected, actualID: actual, online: connection == .online && routeOK, failover: lastEvent?.failover == true)
    }
}

/// Settings › 模型与接口. Selection persists and drives X-Catpaw-Route / X-Catpaw-Model.
struct ModelRoutesSettingsView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject private var catalog = ModelRouteCatalog.shared
    @AppStorage(ModelRouteSelection.routeKey) private var routeID = ModelRouteSelection.autoID
    @AppStorage(ModelRouteSelection.modelKey) private var modelID = ""

    var body: some View {
        Section {
            autoRow
            ForEach(catalog.routes) { routeRow($0) }
            Button { Task { await catalog.refresh() } } label: {
                HStack {
                    Text(ui("刷新路由状态"))
                    Spacer()
                    if catalog.loading { ProgressView().controlSize(.small) }
                }
            }
            .disabled(catalog.loading)
            .accessibilityIdentifier("settings.routes.refresh")
        } header: {
            Text(ui("模型与接口"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ui("只在服务端已同意的免费路由间选择；繁忙时是否切换由服务端配置决定。永不使用付费路由。密钥只在服务端。"))
                if catalog.usingFixture { Text(ui("示例路由（服务端接口未部署）")) }
            }
            .font(CatpawTypography.Role.caption.font)
        }
        .task { if catalog.contract == nil { await catalog.refresh() } }
    }

    private var autoRow: some View {
        Button { ModelRouteSelection.resetToAuto(); routeID = ModelRouteSelection.autoID; modelID = "" } label: {
            HStack(spacing: 10) {
                ConnectionStatusDot(kind: catalog.routes.contains { $0.statusKind == .online } ? .online : .offline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui("自动")).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                    if let chain = catalog.contract?.chain, !chain.isEmpty {
                        Text(chain.map(catalog.displayName).joined(separator: " → "))
                            .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                }
                Spacer(minLength: 0)
                if routeID == ModelRouteSelection.autoID { Image(systemName: "checkmark").foregroundStyle(CatpawColors.ink) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.route.auto")
    }

    private func statusText(_ r: ModelRouteInfo) -> String {
        switch r.status {
        case "online": return ui("在线")
        case "offline": return ui("离线")
        default: return ui("降级")
        }
    }

    @ViewBuilder private func routeRow(_ r: ModelRouteInfo) -> some View {
        let selected = routeID == r.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                ModelRouteSelection.select(route: r.id, model: r.defaultModel)
                routeID = r.id; modelID = r.defaultModel ?? ""
            } label: {
                HStack(spacing: 10) {
                    ConnectionStatusDot(kind: r.statusKind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.display_name).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                        Text(statusLine(r)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").foregroundStyle(CatpawColors.ink) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.route.\(r.id)")

            if selected, r.models.count > 1 {
                Picker(ui("模型"), selection: Binding(
                    get: { r.models.contains { $0.id == modelID } ? modelID : (r.defaultModel ?? "") },
                    set: { modelID = $0; ModelRouteSelection.select(route: r.id, model: $0) }
                )) { ForEach(r.models) { Text($0.id).tag($0.id) } }
                .accessibilityIdentifier("settings.route.\(r.id).model")
            } else if selected, let m = r.defaultModel {
                Text(m).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            }
            if let err = r.last_error {
                Text(ui("上次错误 {0}", arguments: [err.code + (err.at.map { " · " + $0.prefix(16).replacingOccurrences(of: "T", with: " ") } ?? "")]))
                    .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
            }
            if let url = r.policy_url.flatMap(URL.init(string:)) {
                Link(ui("隐私说明"), destination: url)
                    .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    .accessibilityIdentifier("settings.route.\(r.id).privacy")
            }
        }
        .padding(.vertical, 4)
    }

    private func statusLine(_ r: ModelRouteInfo) -> String {
        var parts = [statusText(r)]
        if let c = r.cooling_seconds, c > 0 { parts.append(ui("冷却 {0} 秒", arguments: [String(c)])) }
        if r.free == true { parts.append(ui("免费")) }
        return parts.joined(separator: " · ")
    }
}


/// Settings › 「模型」: one merged section (current line, re-check, radio list); privacy + tech details on sub-pages.
struct ModelSettingsSection: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject var model: ConversationFirstModel
    @ObservedObject private var catalog = ModelRouteCatalog.shared
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @AppStorage(ModelRouteSelection.routeKey) private var routeID = ModelRouteSelection.autoID
    @AppStorage(ModelRouteSelection.modelKey) private var modelID = ""
    @State private var refreshing = false

    private var presence: ModelRouteCatalog.Presence {
        _ = routeID
        return catalog.presence(connection: .from(monitor.state))
    }
    private var isAuto: Bool { routeID == ModelRouteSelection.autoID }

    /// 「当前：自动，实际在用 Gemini · 在线」
    private var currentLine: String {
        let p = presence
        let status = p.online ? ui("在线") : ui("未连接")
        if isAuto {
            if let a = p.actualID { return ui("当前：自动，实际在用 {0} · {1}", arguments: [catalog.displayName(a), status]) }
            return ui("当前：自动 · {0}", arguments: [status])
        }
        return ui("当前：{0} · {1}", arguments: [catalog.displayName(routeID), status])
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                ConnectionStatusDot(kind: presence.online ? .online : .offline, size: 10)
                Text(currentLine).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.model.current")
            Button {
                Task {
                    refreshing = true
                    await model.refreshConnection()
                    await catalog.refresh()
                    refreshing = false
                }
            } label: {
                HStack {
                    Text(ui("重新检查连接"))
                    Spacer()
                    if refreshing || model.connectionLifecycle == .checking { ProgressView().controlSize(.small) }
                }
            }
            .disabled(refreshing)
            .accessibilityIdentifier("connection.refresh")
            #if DEBUG || DEVICE_TRIAL
            autoRow
            ForEach(catalog.routes) { routeRow($0) }
            #endif
            NavigationLink { ModelPrivacyDetailView() } label: { Text(ui("隐私与数据")) }
                .accessibilityIdentifier("settings.model.privacy")
            NavigationLink { ModelConnectionDetailView(model: model) } label: { Text(ui("连接详情")) }
                .accessibilityIdentifier("settings.model.details")
        } header: {
            Text(ui("模型"))
        }
        .task { if catalog.contract == nil { await catalog.refresh() } }
    }

    /// Dot: live green only on the selected row and only when online; otherwise neutral.
    private func dot(selected: Bool) -> some View {
        Circle().fill(selected && presence.online ? ConnectionStatusKind.liveGreen : ConnectionStatusKind.neutralDot)
            .frame(width: 9, height: 9).accessibilityHidden(true)
    }

    private var autoRow: some View {
        Button { ModelRouteSelection.resetToAuto(); routeID = ModelRouteSelection.autoID; modelID = "" } label: {
            HStack(spacing: 10) {
                dot(selected: isAuto)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui("自动")).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                    if let chain = catalog.contract?.chain, !chain.isEmpty {
                        Text(ui("失败时依次切换：{0}", arguments: [chain.map(catalog.displayName).joined(separator: " → ")]))
                            .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isAuto { Image(systemName: "checkmark").foregroundStyle(CatpawColors.ink) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.route.auto")
    }

    private func subtitle(_ r: ModelRouteInfo, selected: Bool) -> String {
        if r.statusKind == .offline { return ui("离线") }
        if selected { return [presence.online ? ui("在线") : ui("未连接"), r.free == true ? ui("免费") : nil].compactMap { $0 }.joined(separator: " · ") }
        return r.free == true ? ui("免费 · 待选") : ui("待选")
    }

    @ViewBuilder private func routeRow(_ r: ModelRouteInfo) -> some View {
        let selected = routeID == r.id
        let inUse = isAuto && presence.actualID == r.id
        VStack(alignment: .leading, spacing: 6) {
            Button {
                ModelRouteSelection.select(route: r.id, model: r.defaultModel)
                routeID = r.id; modelID = r.defaultModel ?? ""
            } label: {
                HStack(spacing: 10) {
                    dot(selected: selected)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(r.display_name).font(CatpawTypography.Role.body.font).foregroundStyle(CatpawColors.ink)
                            if inUse {
                                Text(ui("实际在用"))
                                    .font(CatpawTypography.Role.caption.font.weight(.semibold))
                                    .foregroundStyle(CatpawColors.ink)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().strokeBorder(CatpawColors.secondary.opacity(0.5), lineWidth: 1))
                                    .accessibilityIdentifier("settings.route.\(r.id).inUse")
                            }
                        }
                        Text(subtitle(r, selected: selected)).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").foregroundStyle(CatpawColors.ink) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.route.\(r.id)")
            if selected, r.models.count > 1 {
                Picker(ui("模型"), selection: Binding(
                    get: { r.models.contains { $0.id == modelID } ? modelID : (r.defaultModel ?? "") },
                    set: { modelID = $0; ModelRouteSelection.select(route: r.id, model: $0) }
                )) { ForEach(r.models) { Text($0.id).tag($0.id) } }
                .accessibilityIdentifier("settings.route.\(r.id).model")
            }
        }
        .padding(.vertical, 2)
    }
}

/// 「隐私与数据」 detail page (moved out of the main section).
struct ModelPrivacyDetailView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject private var catalog = ModelRouteCatalog.shared
    var body: some View {
        Form {
            Section { Text(ui("只在服务端已同意的免费路由间选择；繁忙时是否切换由服务端配置决定。永不使用付费路由。密钥只在服务端。")) }
            ForEach(catalog.routes) { r in
                if r.data_note != nil || r.policy_url != nil {
                    Section(r.display_name) {
                        if let n = r.data_note { Text(n).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
                        if let url = r.policy_url.flatMap(URL.init(string:)) { Link(ui("隐私说明"), destination: url).accessibilityIdentifier("settings.route.\(r.id).privacy") }
                    }
                }
            }
        }
        .settingsCanvas()
        .foregroundStyle(CatpawColors.ink)
        .navigationTitle(ui("隐私与数据"))
    }
}

/// 「连接详情」 secondary page: tech info (verified model, last confirmed reply, route errors / cooling).
struct ModelConnectionDetailView: View {
    @Environment(\.locale) private var uiLocale
    private func ui(_ key: String, arguments: [String] = []) -> String { AppLanguage(locale: uiLocale).ui(key, arguments: arguments) }
    @ObservedObject var model: ConversationFirstModel
    @ObservedObject private var catalog = ModelRouteCatalog.shared
    @ObservedObject private var monitor = ConnectionMonitor.shared
    var body: some View {
        Form {
            Section {
                ConnectionStatusRow(kind: .from(monitor.state), detail: ui(model.connection.detail))
                    .accessibilityIdentifier("connection.state")
                if let m = model.connection.model { LabeledContent(ui("已验证模型")) { Text(m).foregroundStyle(CatpawColors.secondary) } }
                if let at = model.connection.verifiedReplyAt { LabeledContent(ui("最近确认回复"), value: at.formatted(date: .omitted, time: .shortened)) }
                if let e = catalog.lastEvent {
                    LabeledContent(ui("最近路由"), value: catalog.displayName(e.route) + (e.model.map { " · " + $0 } ?? ""))
                    if e.failover == true, let from = e.from, !from.isEmpty {
                        LabeledContent(ui("已切换"), value: from.map(catalog.displayName).joined(separator: " → ") + " → " + catalog.displayName(e.route))
                    }
                }
            }
            Section(ui("路由状态")) {
                ForEach(catalog.routes) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.display_name)
                        Text([r.status, r.cooling_seconds.flatMap { $0 > 0 ? ui("冷却 {0} 秒", arguments: [String($0)]) : nil },
                              r.last_error.map { ui("上次错误 {0}", arguments: [$0.code + ($0.at.map { " · " + $0.prefix(16).replacingOccurrences(of: "T", with: " ") } ?? "")]) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary)
                    }
                }
                if catalog.usingFixture { Text(ui("示例路由（服务端接口未部署）")).font(CatpawTypography.Role.caption.font).foregroundStyle(CatpawColors.secondary) }
            }
        }
        .settingsCanvas()
        .foregroundStyle(CatpawColors.ink)
        .navigationTitle(ui("连接详情"))
    }
}
