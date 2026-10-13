# 长任务开发启动合同

2026-10-13。本文固定开发入口与启动条件，不维护实时进度。当前状态只见[master-plan](../../status/master-plan.md)。可复制的[长任务prompt](long-task-development-prompt.md)以本合同和下列规格执行；准备完成不等于产品验收完成。

## 1. 目标与范围

终版产品目标为FINAL-G3：FINAL-G1日常可信体验＋FINAL-G2具名版本／任务上的可测优势。当前基础运行定义仍为[AF-1-G3-UX1](goal.md)；AF-G5关闭18A／12U／3CP基础门，不能自动关闭更完整的终版目标。CGUI-1是本轮用户明确补充的对话能力，通过FQ细分纳入FINAL-G1，不替换基础卡身份或冻结HTTP。

| 开发输入 | 权威与验收 |
|---|---|
| 通用Agent行为 | [AF-1 spec](../../product/agent-foundation-spec.md)、[详细spec](spec-details.md)、[基础验收](../../acceptance/agent-foundation-acceptance.md) |
| 原生布局、输入、阅读和全状态 | [UX-1](../../design/ios-codex-experience-spec.md)、[12 UX用例](../../acceptance/ios-codex-experience-acceptance.md) |
| 本轮产品取舍 | [设计评审R1](../../design/product-experience-review-2026-10-13.md)是理由记录；体验承诺/默认值见FINAL-1，具体层级/交互见UX-1 R2，呈现选择见CGUI-1；原验收ID保留 |
| 视觉/运动实施 | [UX-1 R2附录](../../design/taste-visual-motion-r2.md)、[机器参数](../../design/taste-visual-motion-r2.json)、[可点按提案](../../design/prototypes/catpaw-taste/index.html)；原生SF/系统转场、有限运动/锚点/草稿与M01–M10并入原12U；提案不替代设备验收 |
| 连续交互与新视觉方向 | [UX-1 R4](../../design/native-interaction-motion-r4.md)、[视觉／参数](../../design/interaction-motion-r4.json)、[独立样机](../../design/prototypes/catpaw-motion-study-r4/index.html)及App专用skill方向图；重点跟手、反向打断、可取消返回、分档固定确认、锚点菜单和图片回源。系统物理／玻璃／触觉用原生API，原12U／10CG身份不变 |
| 移动端视觉与对话细节 | [R5](../../design/mobile-conversation-reference-r5.md)、[参数](../../design/mobile-conversation-reference-r5.json)、[新版样机](../../design/prototypes/catpaw-mobile-reference-r5/index.html)；亮蓝动作／深蓝本人消息、正文17行高1.6段间24起点、三态输入、来源与三类菜单；真实事件摘要／耗时／停止与暂停有独立合同，语音对话不纳入本轮。R4.1保留日期输入，R4机制保留 |
| 完整交互实施 | [UX-1 R3](../../design/interaction-scenarios-r3.md)、[42项场景表](../../design/interaction-scenarios-r3.json)、[14入口Demo](../../design/prototypes/catpaw-interaction-r3/index.html)；开合/手势/过程/稳定卡/表图/HIL逐项映射原12U和10CG，未新增产品门或启动Goal |
| 终版产品／视觉／技术与质量／优势 | [FINAL-1](../../product/catpaw-final-product-spec.md)、[FQ/BP验收](../../acceptance/catpaw-final-product-acceptance.md)及[机器合同](../../acceptance/catpaw-final-product-acceptance.json) |
| 对话内生成式交互 | [CGUI-1](../../design/conversation-generative-ui-spec.md)、[CG-A01–10](../../acceptance/conversation-generative-ui-acceptance.md)及[机器合同](../../acceptance/conversation-generative-ui-acceptance.json) |
| 计划与组合路径 | [W/D执行单元](plan.md)、[操作脚本](acceptance-scenarios.md)、[切片](../../status/delivery-slices.json)、[机器映射](contract.json) |
| 复用与证据身份 | [四仓](../../research/copilotkit-four-repo-decision-update-2026-10-13.md)、[Grok整合](../../research/grok-companion-integration-review-2026-10-13.md)、[UI/onboarding复核](../../research/copilotkit-conversation-ui-onboarding-review-2026-10-13.md)、[hash输入](goal-evidence-map.json) |

## 2. 开工条件与交付责任

规格已经固定产品方向、信息结构、六类工作卡／三种presentation／三类动作、流中状态、HIL、持久恢复、主动与记忆控制、正常／异常验收断言、算法真值和比较规则。机器检查必须确认映射、必需项和来源；实际检查结果写主计划。可审阅HTML提案和已保存手机观察作为设计输入，不替代原生操作。

维护入口为apps/ios-conversation；后端为services/edge/supabase/functions，现有两Swift包继续接宿主。启动先检查Git工作区／是否有活跃owner／最近证据，保留既有未提交文件，不能重建第二个App或覆写他人的独立checkout。采用一种对象／scope／revision权威贯通，不将通用底座拆成三套场景Demo。

开工首片是W10→W11→W12。每片先映射现有类型、wire和存储，给出改动界面与状态；缺失端口在该片做兼容扩展，不能先全局重写执行栈。纯本地GenUI schema／确定算法／renderer可在真实路由验收尚未完成时推进，但产品按钮只在能力成立时开放。

R1体验承诺为“把你交代的事变成可用成果；需要你时说清楚，回来时接得上”。原路由首片后，先贯通CP-01资料报告与同成果改稿，再按依赖完成CP-02/03；这只是价值展示顺序，所有必需范围与终版门槛保持。每片先说明当前事实、用户下一步、可修改/停止入口与返回/失败恢复；把默认值、正文/待决层级、修改草稿和可用成果一起交付，不只数组件。

规格分工：AF-1管领域与执行不变量，FINAL-1管产品承诺与质量，UX-1 R4管呈现机制与连续运动，R5管当前移动端配色、排版、输入、过程与菜单，R4.1保留日期输入；R3保留完整状态场景、R2保留日期视觉输入，CGUI-1管受控呈现/算法。冻结合同与既有人类授权边界优先；旧HTML/研究提案不能覆盖新版规格，发现与稳定ID不兼容的冲突先形成精确变更，不凭模糊“终版”重写执行栈。产品展示可以渐进开放已证实能力，不能以隐藏必需能力关闭Goal。

若后续用户复制prompt允许内部子agent，可按不同文件/明确端口分配独立单元，由主agent集成；不为并行创建其他用户聊天、不派发旧任务。启动读取运行Goal实际状态，`usageLimited`等需要用户恢复的状态不能由prompt或文档绕过，不能默默创建替代Goal。

每片输出可构建源码、适用回归、证据层／hash／限制和下一条用户路径；设计线同步。最终同候选需基础18A／12U／3CP、FQ-01–09、CG-A01–10、7天日用，以及满足具名规则的BP记录。任何必需FAIL／缺证据不得签收；不能因为上游测试或安装成功结束。

## 3. 已明确的外部边界

**“开发合同ready”只表示可开始持续开发；下面是实际验收／发布依赖，不是已经解决的资源。**

- 原route能力尚须按最新主计划核验；冻结build16和最多两次短文本的旧授权按已消耗次数读回，不可重复领取。结构／图片、性能样本、7天日用和竞品配对不是两次短探针的延伸授权。
- 新候选包安装／扩大真实测试／部署与新增依赖先形成具体版本、改动和验证清单，按既有人类授权处理；不要在准备候选前泛泛询问。未授权的外部阶段不阻挡独立源码与离线验证。
- 当前现有Supabase先行，新增计算预算0；独立调度、现有Cron／配额／实际套餐和托管可用性需真实核实。云电脑provider/region/可持续免费资源继续Proposed，不买新compute或用试用额度承诺长期免费。
- 即时未知变化APNs、第三方登录、任意MCP、开放脚本viewer、额外模型／Jev、CopilotKit Intelligence与CLI setup均不成为必需依赖。已有Inbox＋已知时间本地通知按原范围完成。
- 竞品实际版本／账户可用性、受控配对环境和日用测试窗口需具体清单；资源缺失记录未验，不能从官方宣传推导我方胜出。

遇外部阻碍，先保留原ID与证据，列出最小需要的输入／批准及原因，同时推进可独立工作；不得用合成结果填补真实验收。

## 4. 启动检查命令

使用已有工具，无安装和生产请求：

```sh
python3 scripts/check-agent-foundation-plan.py
python3 scripts/check-agent-foundation-goals.py
python3 scripts/check-final-product-plan.py
python3 scripts/check-conversation-ui-plan.py
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
```

通过后按变更运行必要的现有Swift/Xcode/Deno检查；不要为计数反复重跑，旧QA报告用独立执行副本。冻结来源／受控patch／MIT身份不改，私人手机原图留忽略目录并记来源与版本。运行状态只更新master-plan，日期证据不改写为当前事实。
