import SwiftUI

/// Entry for the family surfaces (今天 / 我们家). Composition passes the existing authenticated
/// configuration + credentials; nothing new is created for accounts or tokens.
/// Not yet linked from the conversation sidebar: that hookup is a separate, build-verified slice.
struct FamilyRootView: View {
    @StateObject private var store: FamilyStore
    init(configuration: NativeChatConfiguration, credentials: any NativeChatSessionCredentials) {
        _store = StateObject(wrappedValue: FamilyStore(backend: FamilyHTTPBackend(configuration: configuration, credentials: credentials)))
    }
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
