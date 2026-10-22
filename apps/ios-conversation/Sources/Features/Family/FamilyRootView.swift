import SwiftUI

/// Entry for the family surfaces (今天 / 我们家). Composition passes the existing authenticated
/// configuration + credentials; nothing new is created for accounts or tokens.
/// Linked from the account menu (「我们家」). DEBUG builds use FamilyDemoBackend (labelled 示例数据) until the family API is deployed.
struct FamilyRootView: View {
    @StateObject private var store: FamilyStore
    init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials) {
        _store = StateObject(wrappedValue: FamilyStore(backend: FamilyHTTPBackend(configuration: configuration, credentials: credentials)))
    }
    init(backend: any FamilyBackend) { _store = StateObject(wrappedValue: FamilyStore(backend: backend)) }
    var body: some View {
        TabView {
            NavigationStack { FamilyTodayView(store: store) }
                .tabItem { Label("今天", systemImage: "calendar") }
            NavigationStack { FamilyHomeView(store: store) }
                .tabItem { Label("我们家", systemImage: "person.2") }
        }
        .tint(catColors.action)
    }
}
