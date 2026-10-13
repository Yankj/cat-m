import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("今日", systemImage: "sun.max") }

            MemoryView()
                .tabItem { Label("记忆", systemImage: "brain") }

            AssistantView()
                .tabItem { Label("对话", systemImage: "message") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(Theme.primary)
    }
}
