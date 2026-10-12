# 第三小批：恢复派发屏障与临时 PostgreSQL 验证

2026-10-12，输入内核为 `95ab6cd877a62cc7de82896885d0c275c4a2503f`。同一 feature 分支上的视觉规格另以纯文档提交 `3b3a56fd7bae1f88720aaea0abd17a8fde1fa511` 归档，不包含本批代码。本批继续只做云端工程与合成数据；当前进度见[主计划](../status/master-plan.md)。

## 最小协议与实现

`RestoreDispatchBarrier` 是可信 composition port，不是实际外部服务。调用方注入 `readMarker` 与独立的恢复操作员 `authorizeBinding`；没有 HTTP 注册、服务创建、凭据或自动恢复检测。库内 `catpaw-recovery-bindings` 只是期望值，**同库的 tombstone/epoch 或复制表都不能提供独立恢复权威**。

外部 marker v1：`{schema_version, scope_id, authority_id, recovery_epoch, incarnation_id, state, valid_until}`。state 只能在需要的阶段匹配 locked/open；schema、scope、UUID、epoch和有效期都验证。读取失败、缺失、过期、作用域错误、库内 binding 缺失或不匹配，一律封住副作用。readMarker 必须是库外当前权威；静态环境常量、同库查询或缓存返回不是合格实现。现有 fixture 在 TestRepository.snapshot 之外保存 marker，仅验证注入契约，未证明真实外部持久性或身份验证。

可信人工流程：先将外部状态 locked，恢复/替换前更新 incarnation/epoch；在隔离态完成核对；显式授权 bind（scope事务、预期revision、review_id）；仍保持 locked；核验后由外部操作员打开。bind 不能在 open 状态执行，不能自动调用，review_id 仅为审计引用，不是授权秘密。marker 在授权及写入前后变化时回滚绑定。重新绑定增加 binding revision，旧 Action 的冻结指针不再匹配，即使库内 Goal/approval 全部来自旧备份也不能派发。

Proposal 摘要包含库外指针和 binding revision；客户端不能提供这个字段。派发 admission、executing checkpoint之后、adapter beforeEffect、settlement均重新比对；最后外部/DB读取后再检查原lease和control，不扩大既有Edge预算。已开始效果遇到锁定/标记变化只能记录 unknown，不声称召回效果。旧版本未带恢复指针的 Action 也拒绝派发。

`inspectEffectSynthetic` 在所有 gate 状态下允许已认证的同scope/subject只读查询 adapter 效果，不改变 Action/Goal/审批；查询前后复核身份与摘要。原 reconcile 仍仅查询外部效果、结算审计状态，不重派、不恢复权限。本批没有真实 adapter。

## 尚未满足的生产启用条件

1. 库外权威确实独立于被恢复数据库/备份，具备持久性、真实性、scope归属、当前版本与操作员权限验证。不能靠一个名称或保存两份表证明独立。
2. 所有PITR、快照恢复、副本切换和导入路径，在业务连接开放前锁定权威并更新 incarnation/epoch；启动时缺失权威保持关闭。必须证明恢复路径不会遗漏该步骤。
3. 操作员核对独立且最新的删除、撤权、未知/已发生效果及通知账本，补齐恢复库的屏障后才允许 bind/open。写一个新的marker并不能自动恢复这些事实。
4. 每个真实 adapter 的目标/参数hash、幂等键、接收端 fencing、效果查证/receipt 与 unknown 规则通过验收；标记检查和网络效果之间的竞态必须处理，已在途效果不能靠本地锁召回。
5. 生产角色/RLS、完整kernel接线、多进程/COMMIT确认丢失、崩溃/备份恢复、长期授权、held-out语义和原生回流另验；获得明确生产启用/部署授权。

**构造器仍拒绝 PostgresRepository，生产API没有import该kernel，真实adapter默认关闭。** 保留一个反例：如果整个库回滚而可信外部标记也未锁定/更新，指针仍可相等，合成意图可能重放。具名测试明确复现这一未覆盖恢复路径的风险；不把它算作恢复安全PASS。本批只证明“缺失/锁定/不匹配时封闭”及规范人工恢复路径，未证明自动发现所有回滚。

## 实际验证

Node47项、deny-net完整Deno Edge108项，无断言失败；各包含同一个上述反例，分别为46/107个功能安全断言＋1个风险复现。新11项覆盖缺失/不可用/过期/错误scope/版本、DB指针缺失或不匹配、整库回滚后外部锁/旋转、显式人工bind/旧批准失效、操作员竞态回滚、派发前后锁、最后DB读取时锁、reserve耗尽、客户端伪造指针与legacy无fence。真实模型、邮箱、Cron/tick、生产DB、部署及凭据均未操作。

当前Docker daemon可用，使用[Docker官方Postgres镜像](https://hub.docker.com/_/postgres)，固定digest `sha256:3645570cccdfa447589da9f57dd740faa29b30938e861289a5574b6ca6b03826`，实际PostgreSQL17.11、read committed。临时数据库在独立容器tmpfs，network=none、无端口发布、无host mount；仅容器loopback连接，不接受URL/env中的生产地址，没有设置密码或生成凭据。runner只消费已有官方Deno2.9.6/固定postgres3.4.7公开cache和本地固定镜像，不自动下载未知软件。测试结束已验证该容器不存在。

**真实PG 6项存储检查＋1项生产关闭检查，7/7：**

- 实际PostgresRepository scoped CAS两个竞争者只一胜者；跨scope更新null。
- 同一reserved connection内Goal、Event/sequence、public.records outbox注入异常后整体回滚。
- 实际BoundedStore竞争claim只一lease；过期/被替换的旧lease不能结算。
- 实际Facade delegation撤销与worker claim竞争；撤销后task cancelled/lease清空，旧提交被封住。
- scope行锁排序approval/revocation的CAS存储过程；实际pg_stat_activity观察Lock等待，最终批准expired。
- 并发notification insertIfAbsent由真实唯一约束仲裁；实际观察Lock等待，只一条存储记录。
- PostgresRepository仍被kernel生产构造器拒绝。

这里不是mock PG，但范围仍有限：使用临时superuser/minimal fixture schema，未测试生产RLS/专用角色；approval案例验证scope事务/CAS存储原语，不是已关闭的kernel全链路。没有真实远端通知一次性保证、多机/崩溃或COMMIT确认丢失、真实备份恢复。真实PG结果不把这些未验项改成通过。[Postgres锁文档](https://www.postgresql.org/docs/17/explicit-locking.html)只提供语义参考，结果来自实际执行。

```sh
CATPAW_DENO_BIN=<此前已校验的官方Deno> CATPAW_PUBLIC_NPM_CACHE=<固定公开cache> \
  sh scripts/test-goal-postgres.sh
CATPAW_DENO_BIN=<此前已校验的官方Deno> CATPAW_PUBLIC_NPM_CACHE=<固定公开cache> \
  sh scripts/test-edge-offline.sh
node --experimental-transform-types --test --test-reporter=tap \
  services/edge/test/proactive-goal-kernel.test.mjs services/edge/test/logout-owner-regression.test.mjs
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
git diff --check
git diff --cached --check
```

版本、源码和忽略原始日志SHA256见 [RESULT.json](evidence/proactive-restore-dispatch-barrier/RESULT.json)。只正常推送同一feature分支，commit/tree读回在交付报告；不merge/main、不改默认分支、不部署。
