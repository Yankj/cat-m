# PR #91 生产缺口（记忆 / 主动提醒 / 设备调用）

来源：Codex 评审 PR #91。合并前请对照。
## 服务端「使用记忆」开关契约
- 请求头 `X-Catpaw-Use-Memory: 0|1`（iOS 每轮对话发送，取值来自 `ConversationMemorySwitch`）。
- 缺省：沿用服务端设置（旧行为不变）。
- `0`：本轮召回快照为 disabled（`enabled:false`），不注入记忆、不提供记忆工具、不写 journal 片段。
- `1`：由服务端设置决定。任一方关闭即关闭。
- 其他取值：422，`error.code = use_memory_invalid`。
- 生效需要部署 edge（catpaw-api）。

## 剩余风险 / 生产缺口
1. 升级后，旧的明文收件箱卡片（`catpaw.proactive.inbox.v1`）不再显示（已删除，不迁移）。
2. 隔离的旧版记忆只有「导出」入口，没有「恢复进账号」入口（有意不合并，归属不明）。
3. feedback retry（ProactiveFeedbackSync.retryPending）没有可移植测试覆盖，只能在 Mac 上验证。
4. 以下改动在 Linux 测试环境里无法编译（依赖 EventKit / ActivityKit / UIKit），需要 Mac 构建验证：DeviceToolRouter、ProactiveEngine、CatpawLiveActivityCoordinator、MemoryLibraryView、ConversationSessionService、NativeChatHTTPBackend。
5. SwiftData 明文记忆行首次读取时改写为密文；这条迁移路径依赖 SwiftData，没有可移植测试。Release 构建没有 sealer 时拒绝写入；Debug 构建仍允许明文（供测试运行）。
6. 小组件快照（App Group 文件）未加密，只存脱敏字段（固定文案「小猫有一条提醒」「即将开始的日程」「打开小咪查看」、id、时间），不含标题、原因、地点。
7. 应用重启后恢复的轮次没有账号 token（不入 journal），这些轮次的 memory.used/update 会被丢弃（安全侧）。
8. SSE token 的测试走网络层入口 `ConversationSideChannelEvents.deliver`（NativeChatHTTPBackend 调用的同一函数）；完整的会话 send 路径只能在 Mac 原生测试里覆盖。
9. DeviceLedger 的账号隔离、登出清理、unknown 撤销不在本 PR，归 #89。
