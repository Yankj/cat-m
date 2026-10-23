# 初始化恢复首片：只读实施准备

2026-10-23。性质为候选方案，Root 仍处于 M0 准备；Model 拓扑及正式实施未确认。本 lane 不开始 code、不修改 Goal 或验收状态。没有执行测试、真实 SQL、模型、网络、部署或依赖安装。

## 唯一 owner 与最小路径

唯一责任 owner 是 Root（`/root`）：冻结行为、指定唯一实现写入者、审核候选。后续如委派，将本片整体交给一个明确 owner；不要由不同 writer 分拆缓存和资源生命周期。本 lane 只读准备，不认领产品写权限。

最小产品目标仅 `services/edge/supabase/functions/_shared/bootstrap.ts`。相邻 `postgres-pool.mjs`、`bootstrap-stores.mjs`、config 和 runtime factories 保持只读；不改角色检查、JSON binding、认证、模型路线、协议、外层 migrations 或现有测试/云报告。

先用原字节云 QA 与 ignored 执行副本补时序。若正式实施需要持久化新增测试，建议 Root 另外明确 `services/edge/supabase/functions/_shared/bootstrap-recovery.test.mjs`；这只是路径提议，当前未获得写权限，也不默认获得 `services/edge/test/`、`qa/` 或新 helper 文件权限。driver/loader 扩展限独立 ignored 执行副本，不能冒充产品实现。

## 已核对的控制流

`bootstrap.ts:14–30` 为每个 edgeHandler 保存 main、review、next-review 三个 Promise。首次请求建立 SQL/pool/repository/auth，再缓存 `verifyDedicatedPool(...).then(createRuntime)`；验证或构造 reject 后没有清槽，后续同槽请求一直 await 原 rejection。

`postgres-pool.mjs:13–20` 的 connect/reserve 在 try 之前；取得 reservation 后，角色与 JSON SELECT 在 try/finally 中，最后 release。reserve 未取得连接时没有 reservation 可释放；取得后，无论角色/JSON成功失败均应精确 release 一次。pgCompatiblePool 的 release 有本地幂等保护。重试不能跳过 dedicated role 检查、JSON OID 适配或 finally。

外层 request catch 不是初始化专用边界：还会捕获 selector/config 和同步 dispatch 抛错。末尾是 `return r.api(...)` / `r.tick(...)`，没有 `return await`，因此 dispatch 的异步 reject 不由该 catch 捕获。不能在最外层 catch 清 runtime，也不能顺手加 return-await 改变错误传播。

## 建议冻结的最小行为

1. 保留三个 lane，各持独立 flight/资源上下文；不同 API/tick edgeHandler 实例独立。保持 next-review 优先选择、subject/scope、现有路由与授权，不合并槽位或切换模型。
2. 同 lane 同时最多一个未结算初始化。先发布 attempt 身份，再执行可能同步抛错的构造阶段；首波100请求共享一个 attempt，而不是各自建池/验证。
3. 只由该初始化 attempt 自己的 rejection 路径按身份结算：槽仍指向自己才更新。确认没有未释放 reservation 才进入可重试的 failed-clean；无法确认释放则进入 quarantined，不能只清 Promise 当作可重试。所有旧等待者各返回本次失败，其迟到 catch/finally 不得清新 attempt/ready/quarantine。不能在每个请求 catch 或成功 finally 无条件清槽；不能留下孤立 rethrow catch/finally 引发 unhandled rejection。
4. 只有 empty 或满足同绑定条件的 failed-clean，后续新请求才能发起一次新 attempt；原失败请求不循环、递归初始化或重新处理 Request。恢复波仍 single-flight，成功后 warm cache 不再初始化。持续失败且释放已确认时，只由新的请求波触发新 attempt；没有后台 timer、自动重试队列或无限 loop。quarantined 不适用这条恢复路径。
5. 完整角色/JSON验证及 runtime factory 均成功后才 ready。factory 同步/异步失败都属于初始化失败；ready 后业务 api/tick 的同步/异步异常都不属于初始化失败，不归零、不重建、不重放 body。

## 资源与配置兼容边界

建议最小策略：**每个既有 lane 保留一个 owner 持有的 SQL/pool 资源上下文；失败且 reservation 释放已确认时，归零 flight 并进入 failed-clean，相同绑定的新请求可复用该 pool，重新完整验证和构造 runtime。释放不明则隔离该 lane。** 避免“清 Promise、每次 new postgres、丢掉旧 driver handle”的池累积。云 BOOT-02 允许 driverCreated=1，roleQueries/released仍各2，并不要求第二个 driver。成功 pool 不被任何旧失败或业务异常关闭。

这只证明句柄归属、池数有界和 reservation release 纪律，不证明真实驱动断网后能恢复。如果选择 dispose 后重建，必须另外冻结 pinned driver 的确切 end API、关闭时序/失败/超时和 pending 查询处理；云 driver 没有 end/close，BOOT绿色不能证明回收。不要用 `sql.end?.()` 或任意 timeout race 假装已关闭。

**现有配置语义：** `readConfig(get)` 每请求运行，但成功 Promise 没有 config key，ready 后一直用首次成功 runtime；missing/invalid config 早返回也不 evict ready。源码没有 hot reload/凭据轮换实现。本片保留成功缓存语义，不宣称热变更支持。

**先按状态冻结配置行为，不能统称 mismatch 都503：** 保留现有 selector/readConfig 的每请求校验顺序；missing/invalid 配置仍早返回既有503，不取消或 evict 任何其他状态。

| lane 状态 | 本次配置有效后的行为 |
|---|---|
| empty（没有已拥有的 SQL 资源） | 捕获本次上下文，创建一个 flight/资源；没有旧资源可混装 |
| pending(A) | 继续共享 A 的 flight，构造只用 A 的上下文；有效 B 请求也不能改写 A 或另建 B；不按 failed-clean 的 mismatch 规则拒绝它 |
| failed-clean(A)（无未释放 reservation） | 用下述精确语义投影比较；相同 A 才能复用资源新建 flight；B 不同则现有非敏感503，仍保留 A，既不 reserve 也不新建 SQL |
| ready(A) | 保留原成功缓存语义：有效 B 请求仍由 ready A 处理，不做热更新，也不因 B 不同改成503；业务异常不 evict A |
| quarantined(A) | 无论同 A 或不同 B，后续该 lane 均503，不再 reserve、verify、构造 runtime 或建 SQL；其他 lane 不受影响 |

**精确语义投影（仅内存，版本 v1）：** 第一次拥有资源时保存 `{lane, kind, selectedReviewIdentity, effectiveProactiveToolsGate, configProjection}`，factory 使用的私有配置拷贝必须来自同一捕获值。selectedReviewIdentity 区分 main/review/next-review，包含实际 subjectID/scopeID；effectiveProactiveToolsGate 是构造 store 时读取的 gate 的规范化有效值。get 返回的 secret/URL 字符串不裁剪、不降大小写，逐值精确比较。

configProjection 显式覆盖 readConfig 返回的全部字段：projectUrl、publishableKey、databaseUrl、sseTextIntervalMs、generativeUI、taskTools、featureAllowlist、agentMemory、deviceTools、proactiveSuggestionsSSE、proactive、schedulerSecret、attachmentStorage、publicSourcePolicy、visionContractEnabled、visionRoute、visionLiveEnabled、ready、missing、configurationIssues、authReady、modelKey、tickKey、guardKey、route、routeHash、freeChain、apns、chatBudgetMs、chatFinalizationReserveMs、tickBudgetMs、modelTimeoutMs、dailyCallLimit、dailyCallExempt。不能只比 database/project 或 routeHash；secret、APNs、storage、freeChain routes/secrets、预算或 gate 改变也能改变 factory 行为。

投影的递归规则是：primitive 保留类型/值并区分 null、undefined、字段缺失；数组保持长度和顺序；普通数据对象比较完整自有 key 集及各值，key 顺序无意义；不以对象 identity 判等。featureAllowlist 是 Set，投影其排序后的精确成员集合，并显式读取**非枚举自有 `.blocked`** 的存在性和对应 Set 的排序成员；dailyCallExempt 同样按成员集合比较。Set 插入顺序变化相等，成员增删则不等；不依赖 Object.keys/spread 捕获 blocked。保留这些字段的私有拷贝供 factory 使用，不能将可变 Set 引用或 getter 返回容器当作冻结快照；Object.freeze(Set) 本身不能冻结成员。投影未列的新 config 字段、未知自有属性/非枚举属性、accessor、function 或未知容器不静默跳过，empty/failed-clean 的候选上下文应 fail closed，待 owner 更新投影版本。不能直接 JSON.stringify、structuredClone 或浅比较充当此投影：前者丢 Set/blocked，structuredClone 不保留该自定义非枚举属性，浅比较会误判每次新 Set。

**getter 捕获边界：** 每个请求在 selector 之前建立一个仅该请求使用的惰性按 key memoizing getter，selectors→readConfig→有效 gate 捕获全过程都使用它；同 key 第一次读取的 string/undefined 被缓存，后续不再调用原 get。undefined 也必须缓存，不能用 `??` 触发二次读取；原 get 抛错仍传播为失败，不变成 undefined。构造上下文在首次 await/资源使用前完成，此后 factory 不再读原 getter。`bootstrap.ts:26` 的 late gate 必须改为读取该上下文，不能在 verify 后重新 get。

这只保证每请求同 key 一致及 await 后不再取值，**不宣称多个不同 key 是环境事务式原子快照**。不同 key 的首次读取时刻可不同；稳定环境仍是现有 handler 使用前提。没有环境 revision/批量快照接口时，不新增这种保证或支持热配置。failed-clean 比较的是上述完整捕获的有效上下文，pending/ready 则按状态表保持旧缓存语义。

投影/比较只在内存进行，不输出/持久化 URL、配置、secret、完整配置 hash 或 credential-derived marker。测试A/B配置全部合成；回执只写 context_same/context_mismatch、cleanup_confirmed/quarantined 等布尔/固定阶段码，不写成员或值。进一步热变更支持属于独立冻结事项。

createRuntime 失败后，只有验证 reservation 释放已确认时才保留同绑定 pool 进入 failed-clean；不发布部分 runtime，丢弃局部 repository/auth/runtime 对象，下次同绑定完整重构。补故障测试确认构造没有 retain job、Auth/模型调用、业务 SQL 或 dispatch；发现副作用须先拆可安全重试阶段。

**cleanup-failed quarantine：** reserve 尚未返回 client，且能证明本 attempt 未获得 reservation，可视为无 reservation 待释放。已取得 client 则必须沿当前同步 release 合同观察到原 release 正常返回，才能记 cleanup_confirmed；不靠异常 message、finally 已进入、release 已调用或 Promise 已结算推断。release 抛错、出现未跟踪异步 release/拒绝、重复或未知清理结算、无法确定是否仍持有 reservation，都使该 lane 进入 quarantined。保留 owner 的 SQL/pool 句柄及不可混用的上下文；可以结算旧 rejected flight，但 quarantine 标志绝不能随之归零。后续所有该 lane 请求保持503，**不再 reserve、不创建 SQL/pool、不验证或构造 runtime**，也不自动尝试 end/close、timer 清除或自建新 handler。只有另一个明确的新 edgeHandler 生命周期能独立尝试；本片不启动部署/重启。其他两个 lane 保持各自状态。实现必须能从资源生命周期观察清理状态；若只靠现有 verify 的最终 rejection 不能区分 release 失败，不能据此默认为 failed-clean。真实 driver 关闭/泄漏仍未验证。

## 错误与重放边界

保持 configuration_missing/configuration_invalid 的503、driverCreated=0。初始化失败保持现有 schema_version=1、server_configuration_or_database_unavailable、retryable:false；不泄露异常 message/stack/URL/SQL/凭据。不把 retryable 改true，不借新错误码授予客户端自动重发写命令。

后续请求重新初始化只是局部可用性：初始化失败时原请求 dispatch=0；恢复后的显式新请求仍由原权限和幂等合同决定执行。已经进入 api/tick 的写请求，无论返回失败或响应丢失，都没有初始化层自动重放许可。保留原 operation/turn/effect 的 unknown→原ID GET核对，不重新消费 body、不造新身份/请求ID，不改账本或执行 authority。

不新增退避 SLA。BOOT-02 的下一波立即恢复是当前提案目标，真实连接、排队、超时/退避仍需冻结。不要用 Promise.race 超时清槽却放任旧初始化继续；这会产生多个 flight/孤儿资源。生产 hang 上界不能由测试timeout冒充。

## 云 BOOT 覆盖与假修复风险

BOOT-01：100 healthy health 请求共享一次初始化，driver/reserve/release均1。BOOT-02：**单个**角色查询失败的响应和release结束后，再来100个健康请求；目标100恢复，roleQueries/released各2、constructor≤2。BOOT-03：缺配置503、不建driver。只覆盖 main API /healthz。

补充时序使用独立 BR 编号和分母，不能静默改变云18项：

| 时序 | 必须观察 |
|---|---|
| BR-01 首波100并发同次失败，再恢复100并发 | 每波1 flight；首波100×503、次波100×200；无100池或unhandled rejection |
| BR-02 多次失败波，恢复后的第二个warm波 | 每波至多1验证；池数有界；warm不新建/重验，防每请求清槽 |
| BR-03 旧等待者清理迟于新attempt启动 | 旧身份不能清/关新flight或ready |
| BR-04 reserve拒绝；角色query拒绝/不合规角色；JSON query拒绝/类型错 | 全部fail closed；未取得release0，取得后release1；恢复完整重验role+JSON |
| BR-05 SQL/repository/auth构造抛错；verify后factory同步/异步reject | 无毒Promise、丢失句柄、部分ready；无retain/job/业务dispatch |
| BR-06 ready api/tick同步throw、异步reject、一次写入后响应异常 | ready保留；调用1次；无重建/重放；不加return-await改变错误语义 |
| BR-07 三lane混合，一个失败另两个成功；独立tick handler | 各槽/资源/subject/route隔离；synthetic factory，不发真实probe |
| BR-08 failed-clean A 后仅 database/project/secret/gate/review identity/allowlist/非枚举 blocked/dailyCallExempt 任一变化 | 精确不等→503、reserve/SQL/factory 增量0；成员相同但新 Set/不同插入顺序须相等并可恢复。单独 blocked 变化必须被检测，不能由 JSON.stringify 骗过；不记录配置/成员 |
| BR-09 empty/pending/failed-clean/ready/quarantined逐态配置反例，含 readyA+有效B、pendingA+有效B、missing→valid、valid→invalid→valid | ready/pending B保留/共享A；只有failed-clean按绑定mismatch拒绝；quarantine总503；空槽无旧资源可混装；早返回不evict/取消 |
| BR-10 release抛错/拒绝/不明/重复结算后，同A和不同B各再100请求，另两lane继续healthy | 该lane进入quarantine；后续100均503，reserve/SQL/verify/factory增量全0、句柄仍由owner持有；旧callback不清quarantine；新handler单独成功不能被说成旧handler已恢复 |
| BR-11 各失败错误含合成secret marker | HTTP/诊断无marker、URL、SQL；仅现有machine response |
| BR-12 POST/tick初始化失败与恢复前后，body消费计数 | 失败dispatch0；显式新请求至多1；原请求不内部重放；unknown不重发 |
| BR-13 selector/readConfig/late gate重复读取同key的mutable getter，以及等待者取消/长期pending | 每请求原getter同key只调用1次，含undefined；不同key不假称原子快照；await后原get增量0；单等待者取消不取消shared init、pending无第二flight；Set对象不是引用判等/JSON判等 |

云 driver 的 JSON结果固定、typed仅value透传，BOOT不检查jsonQueries/参数；删除JSON验证也可能骗过它。它检查reservation double-release，却看不到真实socket、总池连接、end/close或hang。仅清runtime、吞验证失败、假health200、绕过真实factory、重置计数、换新handler都不是合格修复。实际 JSON序列化另有既有 postgres-json-binding 测试，但不是本轮写范围。

## 离线入口与回退

在 Root 独立 candidate 执行工作树，以原字节 QA、既有Node24、清环境和预载guard执行。以下只测 BOOT+SAFE 四项，没有runner candidate guard，外层回执必须补完整候选SHA、functions tree/源hash、QA提交/hash、命令、Node、分母和stdout hash；原始TAP存新ignored build：

已存在的 Node24 可执行路径由调用者设为 `FAMILY_QA_NODE`；路径是本机环境输入，不下载或安装运行时。

```sh
env -i PATH="$PATH" TZ=UTC FAMILY_QA_MODE=targets "$FAMILY_QA_NODE" --import ./qa/family-cloud-verification/offline/offline-prelude.mjs --import ./qa/family-cloud-verification/offline/offline-loader.mjs --test --test-reporter=tap --test-concurrency=1 ./qa/family-cloud-verification/offline/bootstrap.test.mjs ./qa/family-cloud-verification/offline/network-guard.test.mjs
```

正式候选明确且维护字节一致后保留原18分母复验：

```sh
env -i PATH="$PATH" TZ=UTC "$FAMILY_QA_NODE" qa/family-cloud-verification/offline/run.mjs targets --candidate <reviewed-full-40-character-candidate-SHA>
```

BR时序独立版本/分母；不改云REPORT/EVIDENCE。只修BOOT-02不能使其他记忆/提醒目标通过，全18项仍应保留实际FAIL。现有20套wrapper可按原入口作相邻回归；postgres-json-binding只在已明确提供的pinned公共依赖cache可用时运行，否则NOT_RUN，不安装或以简单stub代替真实serializer。

真实PG角色/JSON/多实例、资源关闭/超时、Auth和用户写路径均仍NOT_RUN。BOOT绿色不能关闭M0、原Goal或AF/家庭产品验收。

正式实施后的回退只撤回本片已review的bootstrap变更及明确纳入的测试，以新审阅提交保留历史；不reset其他owner字节、不回滚M0文档/旧报告、不动schema/数据/配置/模型路线。回退会重现BOOT-02已知失败，照实保留FAIL。本计划没有部署/手机动作授权。

来源与18项静态输入见[来源清单](../../acceptance/family-companion/bootstrap-plan-sources-2026-10-23.json)。本稿由只读方案整理，仅将个人机器绝对路径替换为运行时变量；仍为实施提案。
