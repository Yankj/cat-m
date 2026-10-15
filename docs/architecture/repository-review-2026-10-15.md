# 代码分支与维护架构复核（2026-10-15）

本记录是源码与分支快照，不替代[唯一实时计划](../status/master-plan.md)或产品验收。维护边界沿用[目录角色](../development/repository-layout.json)、[分支规范](../development/branch-management.md)及[2026-10-13审查](repository-review-2026-10-13.md)。

## 分支处理结果与保留边界

- 远端 `main` 已按来源顺序通过 PR #10–16 整合至 `b2c5a392e08ab21677044ed9d576777fa80c15fc`。七个已整合的远端短分支由 GitHub 自动删除，完整提交仍在合并历史中。
- `fix/consent-handoff` 的 build 38 候选在 [PR #9](https://github.com/Yankj/catpaw-m/pull/9) 独立审查。自动审批拒绝最终合并，理由是它仍被识别为从旧 `main` 分叉的 31 提交大分支；不得换路径绕过。此前七次合并不受此拒绝影响。
- `feat/s05-bounded-work` 持有主工作区未提交计划，`fix/model-route-review` 持有独立路由候选；不清理其工作树。诊断快照、Grok 和 proactive 内核仍是来源/参考层，不并入当前生产宿主。旧 `legacy-local` 引用继续只读保留。
- 本地与远端同名发布提交的 Git SHA 不同。逐树核对已证明 build 38 以前对应本地候选的所有远端文本 blob 相同；本地多出的 22 张日期合成 PNG 是既有发布记录明确暂缓上传的媒体，不能因树 SHA 不同宣称源码冲突，也不能自行补传。

## 架构发现

| 优先级 | 可复核事实 | 后续改动与退出门槛 |
|---|---|---|
| P1 | `services/edge/supabase/functions/catpaw-api/index.ts` 是维护入口；独立 tick 仅在不可改写部署快照，API/tick 的 14 个同路径共享文件不同。 | 先画维护模块到两入口的来源表，再为 tick 建立受控维护入口；保留冻结快照，针对同任务恢复、租约和 unknown 跑双入口验证后才组成部署候选。 |
| P1 | `CatpawMApp` 的生产路径经过 `NativeAuthApplicationModel` 到 `ConversationFirstModel`；本地主仓与部署包、设备包不是同一身份。 | 每个候选绑定源码/tree、App 包、API/tick 包和验收记录；现有合成/静态检查不代替同版真实验收。 |
| P2 | `NativeAuthApplicationModel` 的本地只读恢复和已认证打开两处分别构造 Repository、Backend 与六类会话服务（约第 90–100、140–155 行）。重复接线容易让只读恢复与正式会话配置漂移。 | 抽一个保持相同存储命名空间与身份屏障的 composition factory，显式区分只读预览/已认证 admission；复验退出登录、冷恢复、跨账号与 unknown 原操作。 |
| P2 | `ConversationFirstModel.swift` 约 891 行同时协调输入、图片/模型许可、成果续改、任务控制、收件箱、队列和前后台；`ConversationFirstView.swift` 约 929 行承载对话、输入、菜单、详情路由。 | 随下一功能片抽出单一职责的可观察状态/服务与视图片段，保持 Model 只调 typed services；每次更新 Xcode 引用并跑受影响原生宿主与 UI 路径。 |
| P2 | `NativeChatHTTPBackend.swift` 约 1,011 行同时实现会话 SSE、许可、收件箱、计划、控制、动作、设备效果与成果改稿，并持有绑定/回执缓存。 | 保持同一个 actor、URLSession、认证与关闭屏障；按现有 protocol extension 拆文件和受控解码器，验证 wire 身份、一次 POST、原 operation GET 与 4xx/unknown 边界，不引入第二状态库。 |
| P2 | `AppModel/RootView/OpenMuseDemoView` 仍编入原生宿主，生产 `@main` 不实例化它们，但旧 `NativeTests` 仍用 `AppModel`。 | 先把旧测试/运行路径明确归档或迁出宿主目标，再移除已证实不可达的编译成员；不得删掉冻结 v1 来源或以“无生产引用”推定测试无价值。 |

## 资产与 AI 上下文处理

- 本次实际删减的是七个已整合远端短分支的活动入口。其代码由 `main` 合并历史保留，不需要再作为并列维护分支被检索。
- `apps/ios`、`apps/ios-openmuse-demo`、`services/facade/offline`、`deployed-baselines`、`vendor/openmuse`、根目录旧设计/研究和日期验收报告各有冻结、来源或证据职责；不按名称相似或文件大直接删除。
- 默认开发上下文只需根 README、`docs/status/master-plan.md` 的当前执行片、对应产品/验收合同、目标 App 或后端目录的 AGENTS 与被改源文件。历史报告、样机、部署快照和 22 张本地 PNG 仅在追溯特定证据时按路径读取；不批量装入提示上下文。
- 下次物理清理先生成“引用者、来源 hash、冻结身份、活跃目标成员、替代入口”清单，并在相同变更中跑目录/冻结/合同/敏感及受影响宿主检查。当前旧宿主代码和日期媒体不满足安全删除条件。

## 本轮验证范围

对应本地 build 38 源码树的目录、冻结源码、部署快照、AF/FINAL/CGUI 规划、敏感扫描和空白检查通过；七个已合入短分支的相同治理检查也分别在临时执行副本通过。日期证据保留各自原有范围。本轮没有新增真实模型、生产 SQL 多实例、物理手机或部署验证；上述架构调整是后续实现项，不是已完成重构。
