# 验收标准与证据索引

当前阶段由 [M1–M6 Roadmap](../product/mimi-roadmap.md)定义；代码、自动测试、设备验证、线上验收分别见[主计划](../status/master-plan.md)。[M1 初始审查](family-companion/parenting-core-review.md)与[CI 接续](family-companion/parenting-ci-2026-10-23.md)保留固定候选事实。下列历史合同与报告继续可追溯，不用旧测试总数抵扣新产品验收。

重启验收合同：[18A基础](agent-foundation-acceptance.md)、[12U原生体验](ios-codex-experience-acceptance.md)、[FINAL-1质量与对照](catpaw-final-product-acceptance.md)、[CGUI-1对话细分](conversation-generative-ui-acceptance.md)。实际状态均查主计划；下面历史报告保留当时范围。

所有结果按实际层与源码身份报告：fixture、合成本地服务、原生设备/UI、真实云/模型/效果核验分别记账。成功终态、hash 对应和明确未验项是验收前提。最近未编译的修改不能沿用之前通过结果。

**当前产品验收、里程碑、owner、依赖与阻塞只维护在 [主交付计划](../status/master-plan.md)。** 本页保留历史报告和命令，不建立第二套当前状态。用户对旧Demo的产品否定与新conversation-first验收不能被下表局部PASS覆盖；真机安装、用户看到页面、计划/schema、adapter或测试计数都不代替同trace端到端证据。

当前必需放行条件：同版 **AF-A01–18、AF-U01–12、CP-01–03** 全部通过，见 [AF-1功能验收](agent-foundation-acceptance.md)、[UX验收](ios-codex-experience-acceptance.md)、[组合场景](../planning/AF-1/acceptance-scenarios.md)。[FINAL-1质量/对照](catpaw-final-product-acceptance.md)与[对话生成式UI细分](conversation-generative-ui-acceptance.md)是补充合同，不自动扩展真实调用或安装授权。

最近重启的局部证据：[许可](restart-permission-2026-10-13.md)、[阅读](restart-reading-2026-10-13.md)、[包](restart-build16-2026-10-13.md)、[安装](restart-install16-2026-10-13.md)、[队列](restart-queue-ux-2026-10-13.md)、[侧栏/草稿](restart-sidebar-drafts-2026-10-13.md)。各记录只证明其版本和层级，完整产品状态仍看主计划。

旧 R1–R3、A/B/C 清单和 v1/r2/r3 报告已退出当前放行入口，集中见 [历史归档索引](../archive/README.md)。下列原清单保留追溯。

<details>
<summary>历史三线清单、报告与复现命令（2026-10-12及以前）</summary>

[整体设计输入](../architecture/server-first-delivery-design.md)和[记忆A–L输入](../architecture/memory-brief-v1.md)保留参考；需先对齐现有Store/wire，不能从设计推定已实现。

## 历史三线验收清单

产品放行按 [对应spec的US1–US4与R1–R3](../product/conversation-first-delivery-spec.md#阶段放行与开发切片)。R1须真实短任务成果回到原对话/最小收件箱并完成最后体验；R2须可靠持续执行和可查看/更正/删除记忆；R3为后置系统入口/语音。聊天、唯一binding或安装通过不能单独关闭R1。当前结果统一见主计划。

R1前台P0补为[连续多模态MM01–MM05](r1-continuous-multimodal-issues.md)：即时本地响应、真流式、前后台自动同turn恢复、图片真正送视觉模型、实时查询或诚实不可用；同真机同会话连续自然场景通过后才可重判R1。用户build13产品失败不能被旧短CATPAW_OK/9原生/50便携覆盖；原通过保留限定范围。

此表定义测试要求，不维护第二套实时结果；owner、执行顺序、当前PASS/FAIL/BLOCKED/NOT RUN和调用预算统一见 [主计划](../status/master-plan.md)。每个通过必须绑定最后源码/部署/build与实际环境，源码存在、签名、ready200或模型片段均不能替代完整终态。

| ID | 必验场景 | 必留证据 / 不接受的替代 |
|---|---|---|
| A1 匿名身份/初始化 | 既有身份登录→Keychain→重启；重复bootstrap同scope；跨subject/scope拒绝，logout/撤权阻止新读写 | Auth与应用scope分别给结果；身份/请求计数仅记关联与保全，不保存token/个人资料。拒绝检查用合成身份先跑，不为补测试擅自新建真实用户 |
| A2 连续多模态/流式 | 按MM01–05验同真机连续文字/图片/长回复/实时问题，真实增量、完整终态、前台自动同turn snapshot/cursor和继续观察；provider/DB/网络异常分别验 | 本地/首包/渲染时序、附件/model真实视觉输入、来源/查询时间或诚实不可用、同IDs与provider计数；假打字、占位图片、固定短标记、重复技术恢复/任务进度均不能替代 |
| A3 真任务/产物 | 同对话真实tool_result绑定→原Worker→progress/artifact version/hash→权威succeeded；重开恢复；重复观察/取消/撤权不重复效果 | 同conversation/turn/task/run与产物body/hash；chat完成、fixture注入成果、模型“已完成”均不能替代。明确真实模型所需额度，不能默扩预算 |
| B1 可靠调度/任务授权 | 获准tick后验独立云调用方HMAC/时间窗/nonce、并发lease/ack、COMMIT不确定与恢复；创建session到期、任务授权到期/撤销须分别验 | 批准记录、实际云调用方/部署/job/queue版本。不能以Cron跳过认证；可撤销任务授权先评审。无pg_cron/pg_net或无调用方不能称已调度；未批准不部署 |
| B2 记忆/遗忘 | 跨会话记住→带来源context；更正后旧值退出；forget后旧summary/迟到job/索引不复活；generation/隐私/授权/预算有效 | capture/job/消费者/buildContext/真实chat接线与同源引用；本地合成和真实PG隔离/恢复分别验。表/端口存在不代表产品链已通 |
| B3 收件箱/通知 | 任务结算、ack、事件cursor与outbox原子提交/回滚；删除屏障/去重/撤权/unknown不重发；App内结果收件箱打开原任务 | 先验demo收件箱；20/83离线候选不代替HTTP/原生接线或真实PG。APNs另需Apple能力/设备注册/发送链路，不含私密正文；outbox记录不等于用户收到 |
| C1 iOS连续交互 | 即时回显、选图/预览/取消、中文IME/长文/键盘、队列/unknown、流中后台/前台自动续接、重开与网络切换；保留账号/存储失败回归 | 最后build真机录像/时序和精确case、同ID/provider计数；mock/Simulator/手机分层。用户失败先记账，不用旧离线/native或要求手动技术操作覆盖 |
| C2 手机安装 | 目标可用设备实际安装/启动已签名build；bundle/Keychain/用户容器保全；真机同trace复验A1–A3 | 签名产物与安装build对应、安装/启动/实际设备环境；未安装不能由签名/Simulator通过抵扣，不卸载/清数据制造通过 |

正式D01另须：Mac真实关机、iPhone只用蜂窝发新聊天/创建任务，云端持续处理已accepted任务；手机离线/杀App后重连恢复原IDs和成果。需要可靠云调度、正式会话/授权及真机证据，不由单项通过替代。

匿名用户也使用authenticated数据库角色，不能只用角色判断资源归属；同subject/scope/RLS仍须验。[Supabase匿名登录官方说明](https://supabase.com/docs/guides/auth/auth-anonymous)。格式/绑定validator不认证成果事实可靠性；来源外断言与内容评测另记。

## 历史报告

| 基线/记录 | 结果 | 证据/边界 |
|---|---|---|
| [iOS 已交付 v1](ios-v1.md) | 历史领域186、Node23；完整合并28原生用例，随后视觉修正3个指定场景与最终构建 | 最终/修正前源码 hash 分开保留；未在本轮运行 Simulator |
| [façade r2](facade-r2.md) | 独立历史38+17=55；另离线29 | 精选 TAP 与实际用例；真实 SQL/云/模型未验 |
| [OpenMuse 原生Demo r3](openmuse-r3.md) | 最后源码15 fixture +5重放、iOSbuild、四客户端/四服务HTTP、2原生UI通过 | 最终101项source/194项归档hash；只证明合成本地Demo |
| [仓库准备检查](repository-preparation.md) | 本轮复制/路径/来源/扫描与安全本地回归 | 是可移植资产核验，不扩称端到端验收 |

## 历史资产可复现命令

从仓库根，使用已有 Python/Swift 和 Node 22.17.1+：

```sh
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
zsh apps/ios/Scripts/check-source.sh
zsh apps/ios/Scripts/test-portable.sh
zsh apps/ios/Scripts/test-gateway-portable.sh contract
node --experimental-transform-types --test services/facade/test/facade.test.mjs services/facade/qa/tests/negative.test.mjs services/facade/qa/tests/edges.test.mjs
node services/offline/tests/run.mjs
```

上面不启动 Simulator 或监听服务。领域检查使用 Codable driver；macOS typecheck/iOS parse 不代表 SDK 编译。HTTP/重启回归需显式 loopback 监听，见 [服务 README](../../services/facade/README.md)；本轮没有启动它们。原生 `test-ios.sh` 需调用者提供已有 Xcode/Simulator，设备值留在本地环境。

r3复制后无监听回归：`zsh apps/ios-openmuse-demo/Scripts/test-openmuse-portable.sh`、`zsh apps/ios-openmuse-demo/Scripts/test-openmuse-snapshot.sh`。工程检查和HTTP工具编译见 [r3 README](../../apps/ios-openmuse-demo/README.md)；真实HTTP/UI终态来自客户端任务，本轮未重跑。

</details>

## 新结果登记

按当前AF/UX/CP验收ID与主计划切片登记，每项只用PASS / FAIL / BLOCKED / NOT RUN。记录owner与独立执行者、日期、source commit或manifest、部署版本/客户端build、命令或精确case、环境/工具、provider/model与实际调用/剩余预算、同interaction的request/turn/task关联、证据、失败/skip和未覆盖边界。旧A/B/C、M2a/M2b、r9属于历史口径，不沿用为当前任务编号或调用额度。

检查代码或读取owner合同不记runtime PASS；不能假成功或回退fixture；私人资料遵守当前对话同意/敏感确认与路由策略，synthetic-only测试不得混入真实资料。历史报告留存原口径，新主线最后修改未重验则保持NOT RUN或对应BLOCKED。待终态交付后才建立新的验收记录并由主计划链接，不能提前创建“已通过”报告。
