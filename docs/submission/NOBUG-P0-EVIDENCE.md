# NoBug P0 质询 · 修复证据（branch fix/nobug-p0）

| 项 | Commit | 关键代码 |
|---|---|---|
| 1 本机记忆持久化 + 与 设置›记忆 同源 + 冷启动仍生效 + gate 打开迁移 | 6d4f394 | `MemoryLibrary.swift` MemoryLibraryStub(fileURL:) 每次变更原子写；`MemoryLibraryLocal.swift` shared + migrate；`MemorySavedChip.swift` Hub.local / pageBackend / reconcileLocal；`AgentMemoryLibraryBackend.swift` installAgentMemory 后自动 reconcile；`ProactiveEngine.leadTime` 读云端 + 本机 |
| 2 去掉假记忆 | e4f0504（默认空在 6d4f394） | `MemoryLibraryStub()` 默认 `items: []`；三处页面改 `MemoryLibraryHub.pageBackend`（空 → 未开通）；sample 仅 #Preview |
| 3 device_call 账本按 call_id 持久化 | f3b5442 + 143f468 | `DeviceCall.swift` DeviceCallStore：执行前持久化 `.running`+call，执行后先存 `.reportFailed(result)` 再上报；重启后 interrupted：幂等工具重跑（EKEvent/EKReminder notes 带 `catpaw call_id=` 先查重），compose 类上报 `interrupted_outcome_unknown`；`device-call.mjs` pending_timeout 改为 “status is unknown … verify before retrying” |
| 4 meituan + 枚举契约测试 | 4960e97 | `DeviceToolContract.shopURLs` imeituan:// + i.meituan.com；`services/edge/test/device-tool-client-contract.test.mjs` 覆盖每个服务端 enum 值、状态枚举、工具列表 |
| 5 calendar_list / contacts_search / unsupported / 工具协商 | 143f468 | `DeviceToolRouter.swift`；不支持 → `reason=unsupported_tool, retryable=false`；客户端发 `X-Catpaw-Device-Tools`，服务端 `parseDeviceTools` + offer 只提供已声明工具（无 header 的旧客户端行为不变） |
| 6 附近 POI + 路线 | f969f94 + 复验修复 | `Features/Nearby/*`：真实定位 → MKLocalSearch（3 km，不足 3 条扩到 8 km）→ 最多 5 条 + MKDirections ETA；回执行内 导航/打电话；无定位如实提示。**口味记忆的真实作用：只影响排序**（`NearbyRules.rank`：含「喜欢吃X」关键词靠前、含「不吃X」靠后，同分按距离），不改搜索词；出行记忆决定 ETA 交通方式。Why 只在排序真的用到口味时写「按口味记忆…调整了排序」。测试证明有/无口味记忆排序不同。 |
| CI + 单测 | 4212b9f, c8e1626 | `.github/workflows/ci.yml`：iOS job 在 macos-26 + 最新 Xcode（glassEffect 需要 iOS 26 SDK）；edge job 用 `services/edge/scripts/ci-node-tests.sh`。**CI 状态：两个 job 均绿 — https://github.com/Yankj/mimi/actions/runs/38901478826**。注意：edge 有 8 个文件需要 Deno/Postgres/真 jose，基线上本来就失败，已隔离（不是修好），跟踪在 https://github.com/Yankj/mimi/issues/81；其余 592 项全过。iOS 便携单测 `Scripts/test-nobug-p0.sh` 53 项全过。 |
| 复验 P1-3 记忆迁移幂等 | 复验修复 | `MemoryLibraryLocal.migrate`：按内容去重（create 成功但本地 forget 前崩溃，重跑不会重复）；create 返回空 id 视为失败；本地「使用记忆」关闭会带到云端；部分失败不再用本机库覆盖云端（`shouldSurfaceLocal` 仅在云端完全未开通且一条未迁移时） |
| 复验 P1-4 未确认结果自动重发 | 复验修复 | `DeviceCallStore.retryPendingReports`：submitter 安装后（冷启动）与每次回前台自动重发 `.reportFailed`，只重发不重执行；单测覆盖离线保持 pending、恢复后全部确认 |
| 复验 P1-5 真 EventKit 去重 | 复验修复 | `Tests/DeviceToolRouterEventKitTests.swift` 在 BE5C 模拟器跑 XCTest：同一 call_id 执行两次，日历/提醒各只有 1 条带标记（2/2 通过，日志 `qa/nobug/xctest-eventkit-be5c.log`） |

## 范围如实收窄
- 已完整：会议出发助理（ETA → 主动卡 → 提醒 → 告诉参会人 → 灵动岛倒计时）、附近 POI + 路线卡、设备工具 12 个。
- **日常规划（daily planning）：未实现，下一步。** 计划：calendar_list + reminders 读取 → 当日空档 → render_ui 时间轴卡。
- 未做（P1）：记忆注入 prompt 的注入防护测试、trace_id 全链路、.busy 路径说明。
