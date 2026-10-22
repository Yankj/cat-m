# 家庭成长 Goal：M0 准备与缺陷基线

日期：2026-10-23。本记录固定当日输入、运行端与离线反例，不维护实时状态；实时进度只见[主计划](../../status/master-plan.md)。本轮没有产品实现、真实模型评测、设备安装或生产变更，M0/M1 均未签收。

产品源码基线 `789ad4fe`；规划输入 `2419db9b`。远端 main / docs 分支经 fetch 与 ls-remote 读回；native/functions 没有规划分支额外改动。主目录和既有工作树保留。本轮产物在独立 `docs/family-m0`，QA、记忆用例和来源审计各有独立工作树；按明确文件整合。

## 可审阅产物

- [执行契约](../../design/family-companion/m0-contract.md)：角色/写入所有权、确认/回执/unknown、权限与版本围栏、分阶段质量与延迟策略、回退边界。
- [初始验收矩阵](acceptance-matrix-v1.json)：37 项家庭要求，保留 18 AF-A、12 AF-U、3 CP、9 FQ、8 BP、10 CG 共 60 项原合同。所有产品项缺本轮同版证据，未用旧通过数填绿。
- [可靠性矩阵](reliability-matrix-v1.json)：固定 M1 输入、目标、当日反例和证据层。
- [运行端回执](run-2026-10-23.json)、[输入哈希](inputs-2026-10-23.json)。原生 Goal 从本线程工具读回 active；没有另造 goal_id 或修改旧暂停线程。
- [100条固定记忆集](memory-cases-v1.json)、[评分定义](memory-evaluation-v1.md)与[独立审阅](memory-review-2026-10-23.json)：50个正查询、52个gold引用、50个纯负例，安全分母100；M0结构审阅不代表M3质量通过。

## 复现结果与限制

| 反例 | 本轮实际结果 | 层级 |
|---|---|---|
| 初始化失败缓存 | 首次 503，依赖恢复后同 handler 仍 503，仅验证一次；新 handler 可 200。100 并发成功对照只创建一次 runtime，100 并发失败后仍不能恢复 | 真实 bootstrap 原字节，直接依赖全部 stub；无 SQL/Auth |
| 取消竞态 | 100 次先完成取消、后释放假模型的交错，100 个新提醒事件及 100 次假 sender 调用 | 真实 service + 合成存储/model/APNs；零真实通知 |
| claim 后恢复 | 保留合成 store 重建 service，随后两个 tick 均无法重领、没有事件 | 非真实进程崩溃/PG 重启；SQL 仅静态佐证 |
| 写入失败 | insertEvent 注入一次错误，next_fire_at 被清空、fire_count 增加，无提醒事件且无法重领 | 真实 service + 合成存储错误 |
| 日志隐私 | 假模型/写入错误标记进入 log callback；原生源码把 payload/error 前缀记为 public | 后端合成执行 + 原生静态；未抓设备日志 |

QA 独立执行后，Root 将四份探针复制到自己的 ignored build 执行目录，以干净环境和禁网 guard 独立重放，结果 JSON 字节 hash 完全相同：bootstrap `fe3c98609995888b045a8a4397886be6e6288a0b20b2c0d23cd236c5f1606430`；reminder `549d3682e0a4a1798ced106ceac55923400cc4485f4278cc2d0f5a50b1fc3d5e`。探针 exit 0 表示反例收集完成，不是产品门通过。原始探针/日志只在忽略的 `build/family-m0-audit`。

既有定向测试 40 项：22 PASS / 18 PG SKIP / 0 FAIL；通过的是既有 push-generation 路径，不能代替 reminder occurrence。无已明确提供的 Deno/公开依赖缓存，本轮不安装；Deno 全套和真实 PG 未运行。原生历史 528/27/4 未重跑或重记为当前结果。

## 当前托管身份

通过已有 Supabase 连接只读获取管理元数据/源文件，未执行 SQL 或函数、未读取用户记录/密钥。项目管理状态 ACTIVE_HEALTHY 不等于产品端到端健康。API56、tick16、proactive10 的包 hash 与21条迁移历史见[管理元数据](hosted-metadata-2026-10-23.json)。

[源码清单](hosted-source-manifest-2026-10-23.json)固定每个返回文件的 hash。tick 的43文件中，14相同、28不同、1本地缺失；API/proactive 返回打包 entrypoint，不能把字节不同推断为业务差异，也不能宣布逐源一致。迁移只读到历史版本/名称，未证明 SQL 一致；runtime 配置未读。本轮未重写历史 deployed-baselines。

Supabase [TLS 兼容变化](https://supabase.com/changelog/cbc-tls-ciphers-deprecated)与[Postgres 17.11 变化](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes)已作为后续运行环境复核输入；本轮没有运行检测 SQL，也不据此归因业务缺陷。Codex [Goal 文档](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)仅解释能力；当前 active 结论来自本线程 get_goal，模型结论来自匹配本次 turn 的本机平台记录，不来自模型自述。

## 独立审阅与剩余门

QA 对执行契约首稿指出保留/保存策略未定、M0冻结评分与M3跑模型含义混淆、故障矩阵缺固定入口。已补策略未决范围、明确实际质量分数属于M3并接故障矩阵。当时复核契约hash `d15b9a6d08cca5315b845875215505bd441f096a64961a28a2f0951164387adf`，未发现新增权限/unknown/评分/范围漏洞。最终稿仅追加第四个独立来源审计工作树，最终hash见输入清单；这不是M0通过。

Root 本次平台记录为 `gpt-6-astra / ultra`，与准备稿要求不同，已向用户提出协调拓扑选择；三名本地准备代理为 `gpt-6.1-sol / ultra`，按各自本次 turn_context 核对。dot 未有可识别消息入口；CUA 对 ChatGPT App 访问被安全限制拒绝，未换方式绕过。云端模型/Goal/任务环境仍未验证，不能把本地准备代理计作云端实施。

M0 剩余包括模型分工决定、dot/云端可访问任务、产品保存/保留与清扫策略、完整协议 schema 的 owner 对齐、部署源码/迁移/运行配置对账。质量输入已完成独立审阅与Root结构重放，并固定最终hash。下一实施优先片为初始化恢复，随后 reminder occurrence/取消/写入事务、隐私与 trace；本轮只准备，不开启代码改造。

## 固定输入的最终整合

记忆首稿曾存在候选数量不足/顺序泄题，以及动作前已预置终态的问题，独立评审已阻止假通过。最终正例各有9或10个有效候选并按opaque ID固定散列排序；68个动作具备前态、后态、原操作identity与回执要求。Root精确复制已审阅两文件并重放结构检查，100条唯一语义样本、引用与版本无结构错误；不读查询的前6负控macro为0.72、micro为38/52，只验证语料不能靠原顺序直接满分，不是产品召回成绩。最终数据hash `23f0ffc74c71ab7947440e41da08ae405b3b0d52f3375f2ce0611a7dbfb21c74`；评分稿hash `7e8047215c6fc8c6da242fc45c4090bbd1e3ed5ab56e11efab75aba694fe2259`。

AF Goal检查首轮在产品基线失败，[24项漂移记录](goal-input-drift-2026-10-23.json)保持原样。独立来源审计确认旧hash对应`cb3bc90`、当前变更全部由品牌提交`4dafaeac`引入；22项为品牌/路径/配对符号替换，另两个历史原型各有6处稳定目录URL被误替换。Root逐字重放全部替换规则，恢复总计12处既有链接，保留新品牌显示与JS符号，再以[逐项来源对齐记录](source-alignment-2026-10-23.json)更新当前输入map。原2026-10-13日期、采用/限制/验收映射与旧Git字节保留；checker和扫描豁免未放宽。原严格AF Goal检查复跑通过，只证明规划输入一致，不改变产品验收。

最终独立整合审阅为0 findings，45项输入hash与24项来源对齐hash匹配。布局、冻结源、部署快照完整性、AF切片、AF Goal、FINAL、CG七项检查通过；敏感扫描1808个候选文件，0 blocking、0 manual review，未扩豁免；`git diff --check`通过。治理结果不替代产品验收。

整合收口时，用户转交dot的云端独立验证分支 `test/family-cloud-verification@b5d365f8c8cd49a0525f6ae76d18af74b9759567`。已fetch并优先读取HANDOFF；该分支相对789ad4fe只增加39个QA资产，没有产品或共享协议改动。云端18项新断言中的12个FAIL、既有222PASS/1SKIP及32个权限NOT_RUN属于不同分母；先保留旧基线结果，随后在固定本机候选上另行复跑。交接资产已收到不代表云端effective model/Goal已验证；新家庭场景与交互合同尚待用户给统一入口。
