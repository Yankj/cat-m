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
