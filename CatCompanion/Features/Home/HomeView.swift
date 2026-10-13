import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if store.proactiveItems.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.proactiveItems) { item in
                            ProactiveCard(
                                item: item,
                                onConfirm: { store.confirmProactive(item) },
                                onDismiss: { store.dismissProactive(item) }
                            )
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("今日")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("猫伴")
                .font(.title.bold())
            Text(store.proactiveEnabled ? "有 \(store.proactiveItems.count) 条主动建议" : "主动已关闭")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无主动建议",
            systemImage: "checkmark.circle",
            description: Text("有需要时我会在这里出现")
        )
        .foregroundStyle(Theme.textSecondary)
    }
}
