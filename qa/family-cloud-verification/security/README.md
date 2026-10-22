# Lane B：家庭安全与合同离线审查

本目录仅为独立 QA 交付。维护源码基线为 `789ad4feceb0680b8e2e5913083c5b834dc63db1`；产品、技术和执行文档固定于 `2419db9b98e2e3bc0e8c850da62418d216fd3bb8`。产品实现、共享协议和主计划没有修改。Node 为 v24.19.0；没有安装依赖或执行 Supabase、Auth、模型、APNs、部署及设备请求。

本轮完成的是普通有界离线验证，**不是实施 Goal，也不关闭 M0–M5**。`effective_model/effective_effort=null / UNVERIFIED`。辅助只读子代理的创建没有显式模型参数，配置偏差及独立复核记录见 `run-ledger.json`；不能声称所有代理均已按要求固定模型。

## 结果与分母

| 证据 | 数量与结果 | 能证明的边界 |
|---|---|---|
| FP-01–32 家庭权限用例 | 32 个具名虚构输入；oracle 一致性 32/32，**真实权限验收 0/32 已跑，全部 NOT_RUN** | 只是拟定策略的 fixture 自洽；不导入产品权限模块，不证明真实 Auth、PG 或 RLS |
| SP-01–09 当前记忆服务探针 | 9/9 预期行为成功复现；2 项支持性离线结果，7 项缺口 | 真实维护 service + 当前内存 store；不是 PG、模型质量或家庭实现签收 |
| LP-01 日志 canary | 1/1 注入路径复现；离线日志零内容门 **FAIL** | 捕获 logger 参数含合成标记；没有读取线上日志，不证明真实数据泄漏已经发生 |
| ST-01–16 源码证据 | 16/16 anchor 定位；44 个相关源码及相对依赖与固定 Git blob 哈希一致 | 只读源码定位；不把静态存在记为运行通过 |

所有联网替身均为本地函数，两个运行探针报告 `network_attempts=0`。测试输入只有虚构记录与固定合成 UUID。父 lane A 与本目录如覆盖同一记忆缺口，聚合时保留不同证据路径，不重复计为已关闭的验收项。

## 已复现的缺口

| ID | 本轮实际结果 | 固定基线源码位置 |
|---|---|---|
| SP-02 | 新纠正 PATCH 后，迟到旧正文 PATCH 仍为 200，旧内容最终胜出 | `agent-memory/service.mjs:55–60,181`；`agent-memory/pg-store.mjs:45–48` |
| SP-04 | 同 operation、异正文再次 memory_save 返回原 ID 与 saved，不产生请求 hash 冲突 | `agent-memory/service.mjs:40–48`；`agent-memory/memory-store.mjs:18–20` |
| SP-05 | 删除后重放同 operation 创建新 ID，内存中重新出现 1 行 | 同上及 `memory-store.mjs:26`；仅当前内存 store，不外推数据库 |
| SP-06 | 无 command ID 的手工 HTTP POST 重复两次，返回两个 201、两个不同 ID | `agent-memory/service.mjs:175–178`；未来家庭命令幂等不能由此继承 |
| SP-07 | memory_update 后内容已更正，但 source_turn_id、operation_id 仍是原来源，没有 previous_source_ref/version | `agent-memory/service.mjs:55–60,105` |
| SP-08 | takeFragments 后注入 insert 失败，剩余 fragments=0、journal=0 | `agent-memory/service.mjs:111–117`；`memory-store.mjs:31`；SQL DELETE 见 `pg-store.mjs:59–61` |
| SP-09 | verifyUser 注入 503，memory 路由返回 401 unauthorized | `agent-memory/service.mjs:160`；对照 `authority.mjs:145–147` 区分 503/401 |
| LP-01 | proactive logger 包含合成 canary；安全 logger/metrics 对照均不含 | `proactive/service.mjs:201`；`catpaw-proactive/index.ts:26,44`；JSON 保存布尔结果 |

上表路径除入口外均相对 `services/edge/supabase/functions/_shared/`。`SP-01` 验证当前内存 store 拒绝另一用户的 get/update/remove；`SP-03` 验证同 operation、同 payload 重放返回原 ID、0 新 events。它们不涵盖多家庭、撤权或真实 PG。

## 静态发现与未验证范围

固定 base 没有 `_shared/family/` 路径，`api.mjs` 也没有 `/catpaw/family/v1` 字面路由。现有 `authority.mjs:45–55` 会回读账号 session 与 scope membership，但这不是技术方案要求的家庭 role、visibility、permissions revision 和复合父子 FK。

`20261016110000_feature_enrollment.sql:102–108` 给 `catpaw_records` 的 agent-memory 策略使用 `using(true)`，写表还有 `with check(true)`。`agent-memory/pg-store.mjs:42–57` 明确按 user_id 过滤。这说明应用过滤是当前关键隔离层；**不能声称数据库策略对该角色独立按租户围栏，也不能据此断言线上已可越权**。实际 grants、运行角色、迁移状态、RLS 行为均未访问。

原生 `ConversationSessionService.swift:351,684,695` 把 payload/error 的描述前缀按 `.public` 写日志。`ConversationSessionContracts.swift:328–331` 的 payload 能携带正文、工具参数、错误及推理摘要。本轮只做静态定位，没有 Swift/OS 日志运行，不能宣称某段内容已在设备泄露或以截断日志算脱敏。

`catpaw.agent-memory.v1` 与 source-backed `catpaw.memory.v1` 是两条契约（`agent-memory/contract.mjs:1–3`）。后者在 `core/integration/server-foundation/src/foundation.mjs:205–250` 有来源、version、generation 和 previous_source_ref 门槛；不能用后者替前者签收。家庭记忆仍需来源类型、来源 revision、对象、可见性、有效期、纠正链、删除派生清除和迟到 job 围栏的同一权威证据。

`proactive/decision.mjs:267–270` 采用 idemGet→执行→idemPut，`proactive/pg-store.mjs:60–61` 的 put 使用 ON CONFLICT DO NOTHING。此处仅发现真实并发证明缺口，没有制造数据库并发效果。`core/src/device-effect-service.mjs:82–86,148–173` 为 dispatched/unknown 提供不重发语义；`proactive/service.mjs:81–85` 和 `proactive/pg-store.mjs:76–79` 对已尝试发送的恢复采用 outcome_unknown。真实多实例 lease、撤权穿插和设备 receipt 仍为 NOT_RUN。

合同依据：技术方案 `:131–149`（私聊/缓存/unknown）、`:179–185`（家庭隔离）、`:198–223`（命令/receipt）、`:254–268`（记忆来源/纠正/删除）及执行 Goal `:46–50,91–100`（阶段与证据层）。以上引用均固定于 contract SHA，文档中的历史成绩没有计入本轮。

## 复现命令

从本专用工作树根运行：

```sh
node qa/family-cloud-verification/security/run-fixtures.mjs
node qa/family-cloud-verification/security/run-source-probes.mjs
node qa/family-cloud-verification/security/run-log-probe.mjs
node qa/family-cloud-verification/security/source-audit.mjs
```

所有脚本仅读源码和打印 JSON；已保存的对应结果为 `fixture-results.json`、`source-probe-results.json`、`log-probe-results.json`、`source-audit-results.json`。运行前用 `source-pin.mjs` 将实际读取源码及静态字面相对 import 依赖逐文件与固定 base 比较，允许 QA 提交后的 HEAD 不同；产品字节不匹配时拒绝继续。源码基线与验证提交不能混同。

仓库检查在本 lane 工作树全部退出 0：`check-repository-layout.py`、`check-repository.py`、`check-deployed-source.py`、`scan-repository.py` 和 `git diff --check`。敏感扫描为 1,793 files、65,756,131 bytes、0 blocking hits、0 manual review hits；这是扫描当时的目录分母，后添 QA 汇总文件会改变分母。原始命令摘要见 `verification-results.json`。

`acceptance-checklist.json` 给出家庭权限、幂等、unknown、记忆与日志的后续冻结/真实验收要求。未跑的项目不转成 PASS。没有被自动审批拒绝、等待审批或结果不明的操作；剩余 blocker 为家庭实现尚不存在、真实 PG/Auth 与设备/模型不在本轮授权范围、effective 模型证明缺失。由 root 决定最终提交和推送；本 lane 不自行提交。
