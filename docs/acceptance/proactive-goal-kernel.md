# 主动目标领域内核：首批合成验收

2026-10-12，基线 `c1e23c287dd0e1da36067dfea2f1712555f56d0d`，独立本地分支 `feat/proactive-goal-kernel`。需求和 gap 见[中文规格](../spec/proactive-goal-kernel-v1.md)；当前进度仍只在[主计划](../status/master-plan.md)。本记录不改变冻结修复版/P0 或 R1 产品验收。

本批扩展现有 Foundation goals/events、Record Store 的 actions/approval binding、execution binding 和 worker task lease。新增模块为 opt-in，构造器明确只接受 synthetic TestRepository；真实服务入口没有 import。外部真实 adapter、模型/用户内容、邮箱、Cron/tick、DB 迁移、部署、credentials 和 push 均未执行。

## 实际命令与证据

```sh
node --experimental-transform-types --test --test-reporter=tap \
  services/edge/test/proactive-goal-kernel.test.mjs \
  services/edge/test/logout-owner-regression.test.mjs
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
git diff --check
git diff --cached --check
```

本环境 Node `v24.19.0`，使用已安装运行时，未安装依赖。原始测试/检查日志留在忽略的 `services/edge/build/proactive-goal-kernel/`，精选记录带文件 SHA256/版本见 [RESULT.json](evidence/proactive-goal-kernel/RESULT.json)。

| 验证 | 本批结果/边界 |
|---|---|
| 新领域测试 | 23 PASS / 0 FAIL：旅行/报告、去重/乱序、修订冲突、CAS竞争、审批失效、跨 scope/同 scope异 subject、暂停/撤销/用户自行完成、失租/更换lease、session/consent、未知效果/新版本绕过、snapshot恢复、quiet抑制/过期通知取消、outbox原子回滚、最后授权await耗尽reserve、过期/否决/版本/真实adapter封闭、scoped SQL参数化 |
| 既有回归 | logout-owner-regression 1 PASS / 0 FAIL，保留 resource owner 与其他 session；两文件总 24/24 |
| Repository | 完整性、敏感信息与 diff 检查结果以 RESULT.json 的本批实际输出为准，不重写旧报告 |
| 模型/语义 | 未调用模型；未运行 held-out 语义评测；测试计数不是语义准确率 |
| 持久化/并发 | 仅 serialized TestRepository 的事务、CAS和snapshot恢复；SQL仅注入 serializer。无真实PG、多实例、进程crash、备份/删除验收 |
| 完整 Edge 回归 | 未运行原 Deno 62项。此云端无 Deno executable，也没有显式提供的公开 jose/postgres cache；现有离线脚本要求 cache，不能按规定联网补装 |
| 产品/云端运行 | 非真实模型、用户、手机、通知发送、部署或持续调度验收；被冻结修复版保持原验收状态 |

合成 fixture 使用固定时间、命名 UUID 与显式 await 的竞态 hook。测试直接用原 FencedWorkerStore CAS 建立 lease，不运行 TaskWorker.tick/start；adapter 效果账本与 Repository 分别 snapshot，恢复测试不把缺失回执当作未发生效果。

未来接线前的阻断项：生产 fresh authority/长期授权与 Goal/task绑定更新、独立PG并发和原子outbox、真实 source身份及revision、真实 adapter对账/交付证据、删除/备份屏障、held-out语义集、原生回流与另行授权的持续唤醒。首批是可复核的领域内核，不声明这些项已完成。
