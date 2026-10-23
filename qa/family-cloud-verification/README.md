# 家庭产品独立验收资料 · 总入口

本目录供本机主 Goal 团队选取复验资料，**不是产品通过报告**。本次只追加三份产品资料和本索引，不重跑研发测试、不改产品源码或原有证据。

- 原云端验证交付：`b5d365f8c8cd49a0525f6ae76d18af74b9759567`，原 39 文件保持不变。[原始交接](HANDOFF.md) / [原文件清单](FILES.json)。
- 离线被测产品源：`789ad4feceb0680b8e2e5913083c5b834dc63db1`；引用方案：`2419db9b98e2e3bc0e8c850da62418d216fd3bb8`。不能把这些结果归到另一候选。
- **本机实际验收候选 SHA：未提供（NOT_PROVIDED）**。不知道本机当前修复状态，不据旧基线判定其当前通过或失败。

## 资料与证据状态

| 资料 | 已有结果 / 当前状态 | 入口及限制 |
|---|---|---|
| 原有选定离线技术测试 | 223 项：222 PASS / 0 FAIL / 1 SKIP | [交接汇总](HANDOFF.md)、[基线](BASELINE.json)；是 Node 选定集，不是原生/全套 Deno/真实 PG |
| 新增故障目标断言 | 18 项：6 PASS / 12 FAIL；相应当前行为探针 18/18 复现 | [离线报告](offline/REPORT.md)、[验收矩阵](offline/ACCEPTANCE-MATRIX.md)、[证据](offline/EVIDENCE.json)；探针复现成功不等于目标通过，不能把两组计为 36 个独立用例 |
| 安全及权限补充 | 32 个 fixture 自洽；真实权限 0/32 已执行、全部 NOT_RUN；9 项 service 探针和合成日志 canary 另列 | [安全报告](security/README.md)；不能将策略 oracle 当 RLS 通过，也没有真实家庭数据泄漏结论 |
| 12 个虚构家庭、36 条可观察断言 | **产品场景全部未执行** | [场景 Markdown](product/parenting-scenarios.md) / [JSON](product/parenting-scenarios.json)；需本机候选、逐条结果和证据，不能按文案或概念图签收 |
| 10 个交互状态、14 项 UI 检查 | **建议契约 / 检查项未执行** | [交互状态契约](product/interaction-state-contracts.md)；未运行 App、未核对真实回执，颜色对比度亦未实测 |
| 8-12 家庭小样本试用 | **试用计划，尚非已调研结果** | 见[场景文档中的试用计划](product/parenting-scenarios.md)；未招募、未执行、未对外发送，不能宣称用户验证或教育成效 |
| 语音、通知图片、异步时序 | **只有输入脚本规格，非真实素材/控制器** | 当前三份产品资料不含实际音频、图片或异步测试控制入口；缺素材时记 NOT_RUN，不把 text-only 或概念走查当真实多模态通过 |

三份产品资料均为虚构家庭示例，来自父会话 Library：`interaction-state-contracts.md` 对应 `libfile_2d88e3a4cf04819187ff51f1722ce4be`；`parenting-scenarios.md` 对应 `libfile_3de0d381072c8191aa8dedcf4efa40b7`；`parenting-scenarios.json` 对应 `libfile_94ba6d584bd08191b417883a0ce2b8f8`。本次按原字节归档，没有修改其内容或执行其中的测试方案。

## 给本机团队的用法与回传

产品实施由用户另一台本地任务负责。本补充包只供该任务的集成人选择合并或 cherry-pick，不自动修改其工作树、切换其分支或安排其执行顺序。本次相对原 `b5d365f8` 的增量仅为本索引和 `product/` 下三份资料。

本机可先安全取回分支，不改变当前检出内容：

```sh
git fetch origin test/family-cloud-verification
```

先明确完整候选 SHA、App/后端/协议版本和允许的验证范围，再选择相关断言。复验脚本和 candidate 参数使用方法见[原交接](HANDOFF.md)与[离线报告](offline/REPORT.md)；本次没有执行这些命令。失败、未实现、缺素材、环境阻塞和概念走查分开记录，不用通过数相互冲抵。

请按以下最小格式回传，每个断言或检查项目一行；无法运行也照实回传：

| SHA | 项目 | pass / fail / not_run | 证据 | 阻塞 |
|---|---|---|---|---|
| 完整候选 SHA；未提供则 NOT_PROVIDED | 如 S01 对应断言、交互状态 07 或 UI 检查项名称 | 明确一个结果，不留默认 pass | 脱敏截图/录屏/receipt/日志或报告路径，并标离线/真实 PG/真机层 | 无则写无；否则写缺素材、权限、入口、版本或已知失败及下一步 |

多组件时补 App 包版本/hash、后端包/配置/协议版本；不能把 QA 分支提交 SHA 当产品候选 SHA。未知写入先核对原 receipt，不为验收盲目重发。资料交付不代表本机已经接收安排，也不改变其 Goal 状态。
