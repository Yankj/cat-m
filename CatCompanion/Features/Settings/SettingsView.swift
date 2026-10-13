import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                Section("主动") {
                    Toggle("启用主动建议", isOn: Bindable(store).proactiveEnabled)
                    Toggle("勿扰模式", isOn: Bindable(store).doNotDisturb)
                }

                Section("确认策略") {
                    Text("低风险动作：自动执行并通知")
                    Text("中风险动作：预览后确认")
                    Text("高风险动作：必须二次确认")
                }
                .foregroundStyle(Theme.textSecondary)

                Section("动作日志") {
                    if store.actionLogs.isEmpty {
                        Text("暂无记录")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(store.actionLogs) { log in
                            VStack(alignment: .leading) {
                                Text(log.description)
                                Text(log.outcome)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}
