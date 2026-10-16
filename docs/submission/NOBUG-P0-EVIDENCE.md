# NoBug P0 质询 · 修复证据（branch fix/nobug-p0）

| 项 | Commit | 关键代码 |
|---|---|---|
| 1 本机记忆持久化 + 与 设置›记忆 同源 + 冷启动仍生效 + gate 打开迁移 | 6d4f394 | `MemoryLibrary.swift` MemoryLibraryStub(fileURL:) 每次变更原子写；`MemoryLibraryLocal.swift` shared + migrate；`MemorySavedChip.swift` Hub.local / pageBackend / reconcileLocal；`AgentMemoryLibraryBackend.swift` installAgentMemory 后自动 reconcile；`ProactiveEngine.leadTime` 读云端 + 本机 |
| 2 去掉假记忆 | e4f0504（默认空在 6d4f394） | `MemoryLibraryStub()` 默认 `items: []`；三处页面改 `MemoryLibraryHub.pageBackend`（空 → 未开通）；sample 仅 #Preview |
| 3 device_call 账本按 call_id 持久化 | f3b5442 + 143f468 | `DeviceCall.swift` DeviceCallStore：执行前持久化 `.running`+call，执行后先存 `.reportFailed(result)` 再上报；重启后 interrupted：幂等工具重跑（EKEvent/EKReminder notes 带 `catpaw call_id=` 先查重），compose 类上报 `interrupted_outcome_unknown`；`device-call.mjs` pending_timeout 改为 “status is unknown … verify before retrying” |
| 4 meituan + 枚举契约测试 | 4960e97 | `DeviceToolContract.shopURLs` imeituan:// + i.meituan.com；`services/edge/test/device-tool-client-contract.test.mjs` 覆盖每个服务端 enum 值、状态枚举、工具列表 |
| 5 calendar_list / contacts_search / unsupported / 工具协商 | 143f468 | `DeviceToolRouter.swift`；不支持 → `reason=unsupported_tool, retryable=false`；客户端发 `X-Catpaw-Device-Tools`，服务端 `parseDeviceTools` + offer 只提供已声明工具（无 header 的旧客户端行为不变） |
| 6 附近 POI + 路线 | f969f94 | `Features/Nearby/*`：真实定位 → MKLocalSearch 3–5 → MKDirections ETA；回执行内 导航/打电话；Why 引用口味/出行记忆；无定位如实提示 |
| CI + 单测 | 4212b9f | `.github/workflows/ci.yml`；`Scripts/test-nobug-p0.sh`（40 项）；`node --import ./test/support/node-strip-loader.mjs --test test/*.test.mjs` |

## 范围如实收窄
- 已完整：会议出发助理（ETA → 主动卡 → 提醒 → 告诉参会人 → 灵动岛倒计时）、附近 POI + 路线卡、设备工具 12 个。
- **日常规划（daily planning）：未实现，下一步。** 计划：calendar_list + reminders 读取 → 当日空档 → render_ui 时间轴卡。
- 未做（P1）：记忆注入 prompt 的注入防护测试、trace_id 全链路、.busy 路径说明。
