# 主动目标内核：921e693 对抗复核

2026-10-12，独立 `feat/proactive-goal-kernel`。审查输入为 `921e693c73555e9a54e0b99144a5c77ae014b7d0`；[首批记录](proactive-goal-kernel.md)保留该输入的24项/当时Deno NOT_RUN，不把新结果倒填旧证据。需求见[spec](../spec/proactive-goal-kernel-v1.md)，实时进度仅在[主计划](../status/master-plan.md)。本批没有UI、真实调度、生产DB或模型工作。

## 发现与修复

| 旧输入的对抗断言 | 实際复现 | 第二小批处理 |
|---|---|---|
| binding引用另一subject任务 | Goal撤销直接清掉task lease | 停止前核对run的subject/scope/operation/hash与task tag；不匹配时整笔事务拒绝，目标/受害任务不变 |
| binding引用另一scope任务 | Goal暂停仍操作同owner下的错误scope task | 同一核对覆盖scope，并沿原scope→delegation→task锁顺序；合成锁不是PG证明 |
| approved binding投影无Decision | 可直接派发合成效果 | 检验不可变用户Decision的Goal/version/actor/action digest，投影不独立授予权限 |
| 最后一次binding读取耗尽lease | invocation仍live时，已过期lease还能产生一次效果 | binding/Decision读取后再次检查捕获leaseUntil与control；仍仅合成time-hook验证 |
| 删除Goal后恢复旧Goal/批准 | 原Store remove/put可以复活批准并派发 | 新逻辑删除同事务写tombstone、CAS Goal并停止工作；最新tombstone存在时拒绝恢复执行，unknown可继续只读审计 |

旧实现针对前述5项断言：0 PASS / 5 FAIL。before日志对应冻结旧kernel＋新增前五项复现test；精选证据保存旧kernel SHA、before日志SHA、用例名称、命令及最终测试SHA。修改前测试文件的整体SHA未单独捕获，不把后续追加用例的SHA冒充原输入。原始日志在忽略build，不上传绝对环境路径或运行时依赖。

追加复核通过的规则：跨Goal/scope证据拒绝；并发approve/revoke终态无可用lease；竞争dispatch只有一个效果；未知状态正常snapshot重启不能重放；并发inbox publisher及仅恢复旧outbox、保留最新inbox账本时仍只有一条存储通知；删除事务后置授权失败整体回滚；删除Goal内容后unknown能凭tombstone审计而不能重派；被损坏的effect key不能绕开unknown意图保留或误导reconcile。

## 明确未解决的恢复风险

具名测试 `known limitation: rolling back ALL authority ledgers can replay; production restore requires independent barrier` 刻意恢复派发前整个snapshot，丢掉后来的tombstone和executing/unknown。用两个独立合成adapter的计数复现同一意图各执行一次。该测试成功复现风险，不是恢复安全PASS；主计划、精选结果将它单独记账。

本批逻辑删除不是物理删除。原Store受信维护接口直接remove/put绕开协议仍不安全；旧库全量恢复、跨备份删除清单、scope/session撤权epoch、外部效果账本及通知去重账本整体回滚，没有独立恢复屏障。真实adapter也尚无可验证幂等/receipt查询协议。必须先在恢复隔离态核对独立、最新的删除/撤权/效果清单；该恢复流程未实现。生产构造器保持拒绝，不能上线验证或宣称可安全恢复。

## 验证层与官方依赖

Node36项完成：35个功能/安全断言通过，1个已知不安全恢复的风险复现。Deno完整Edge97项完成：原62项＋此内核35项；96个功能/安全断言通过，1个相同剩余风险复现。0个测试断言失败。固定时间、命名fixture、故障hook；不使用模型输出相等作为语义准确率。

用户本批明确允许补官方Deno依赖。Deno2.9.6的Linux x86_64压缩包来自[官方发布](https://github.com/denoland/deno/releases/tag/v2.9.6)，按同一发布的`.sha256sum`校验：`394f07f4da2bebe6ce6f1e7ce0fa16429b29b08c35e3fac3fe25972676dff4b2`。二进制只放忽略build目录，不运行安装脚本、不写系统路径、不新增凭据。GitHub release API返回403后使用同一官方release公开资产和校验和，没有改用第三方下载源。jose6.2.12/postgres3.4.7从官方npm registry缓存，通过原deno.lock的frozen lock，未启用lifecycle scripts，lock/生产配置保持原字节。

```sh
# 依赖准备阶段仅缓存公开固定版本，不执行应用
DENO_DIR=<忽略build中的公开cache> <已校验的Deno> cache \
  --config supabase/functions/deno.json --frozen-lockfile \
  --node-modules-dir=none npm:jose@6.2.12 npm:postgres@3.4.7

# 既有脚本：cached-only / deny-net / ignore-env / no-prompt
CATPAW_DENO_BIN=<已校验的Deno> CATPAW_PUBLIC_NPM_CACHE=<公开cache> \
  sh scripts/test-edge-offline.sh
node --experimental-transform-types --test --test-reporter=tap \
  services/edge/test/proactive-goal-kernel.test.mjs services/edge/test/logout-owner-regression.test.mjs
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
git diff --check
git diff --cached --check
```

完整Edge回归只执行合成provider/session/store及已有测试中的合成worker推进，deny-net隔离，没有启动真实tick/Cron/服务。PostgresTransaction只有注入connection SQL/serializer断言。TestRepository全库串行且lock为空；因此97项不能证明PostgreSQL行锁/死锁、跨实例CAS、scope rows与public.records同连接原子提交、COMMIT确认丢失、RLS/隔离级别、进程crash或生产备份一致性。真实PG、物理删除/独立恢复屏障、held-out语义、真实adapter/接线均NOT_RUN。

源码、before/after日志、官方运行时与原lock的SHA256见 [RESULT.json](evidence/proactive-goal-adversarial-review/RESULT.json)。构建依赖和原始运行日志只保留在忽略的 `services/edge/build/proactive-goal-review/`。本批正常push仅此独立feature分支，远端commit/tree读回结果在交付中报告；不merge/main、不改默认分支、不部署。
