# FINAL-G3 开发首片：续聊、写入租约与原生本地 GenUI

日期：2026-10-14。固定候选 `AF-W11-CGUI-20261014-01`，源码基线 `63447d1`，15项修改源码逐字节hash见[RESULT](evidence/agent-start-20261014/RESULT.json)。这是本轮日期证据；实时状态仅维护[master-plan](../status/master-plan.md)。本片不关闭 AF-G5、FINAL-G1–G3 或任一真实 CG 验收。

## 实际变化与用户行为

- 成功委派且没有正文的终结回执不再产生与服务端历史不符的空助手消息。旧日志仅在读取同一原操作的终结 sequence、message ID、hash后修正；保留任务投影、其他历史、非空正文和unknown语义。
- 维护后台在最后一笔 awaited write后、COMMIT前重新检查现有授权与租约。原请求受理、正文、工具结果、dispatch checkpoint及终结提交失去权威即回滚；不通知或调用模型。
- 对话回复可复制、使用系统分享、引用到既有草稿；引用保稿、不自动发送，输入法组合态不插入引用。
- 新增固定schema/registry与原生表格、bar/line图、时长预算和加权比较试算。精确十进制内核保留原值、负剩余和bankers两位展示；未知版本/字段、无来源或不适合原生绘图的数据可读降级。交互只在完整、同conversation/turn/call/revision的已登记数据上启用，不能提交Goal或effect。
- 本地试算和表格筛选在流式正文增长时保留修改，不追加请求。截图复查后把“回到最新”移到输入区上方的独立inset，避免覆盖阅读控件；保留现有阅读锚点和明确恢复跟随。

## 本轮验证层

| 验证 | 实际结果 | 证据边界 |
|---|---|---|
| 续聊持久化 / 队列 | 21 / 16项PASS | 合成事件、隔离文件存储；初始服务对新增续聊用例RED，修复后GREEN |
| GenUI精确算法与schema | 64项portable PASS；同矩阵1个原生XCTest PASS | 人工真值、数量/长度/额外字段/极大极小/身份来源边界；非模型生成 |
| 后台租约故障 | 5项RED→GREEN；Deno离线67项PASS | 真实维护类及工具/Store入口、合成事务与租约；只读既有public cache、deny-net，无生产SQL |
| 原生最终候选 | 6个XCTest、0失败、0跳过 | 2个核心测试方法（64+8内层案例）＋4个实际UI测试；iPhone17/iOS27.0 Simulator |
| 原生UI范围 | 引用保稿、试算19.00/负值/无效值、筛选预览外第6行、阅读锚点与回到底部PASS | 明确注入synthetic offline fixture，各路径1次合成reply；不是实际Auth/模型/云继续 |
| 构建/治理 | non-DEBUG SDK检查、69个App成员、713双语条目；Release模拟器0.3.0(17)构建PASS | 无新增依赖、生产配置复制或签名真机包；二进制hash固定 |

保留首轮与r2/r3失败、5/5通过后发现遮挡的截图复查，以及最终6/6回归记录。失败包括容器标识覆盖子控件标识、流式尾部隐藏早期卡片、导航遮挡下无键盘焦点；修正原生分组和测试的实际可见阅读区域后复验，不删除失败轨迹。

两张[试算截图](evidence/agent-start-20261014/duration-local-native.png)／[表格截图](evidence/agent-start-20261014/table-filter-native.png)来自最终XCTest附件，包含明确合成标记，原图、版本、来源与hash保留。运行输出和失败附件在忽略build/.build目录，未导出私人手机内容。

## 限制与后续

`present_cgui_v1`目前只是本地编译receiver及DEBUG离线fixture；native HTTP whitelist与后台producer未改变，不能称真实模型已可生成原生表图。Local View state尚未接冷启动持久恢复、同工作明确跟进；完整表sheet状态复用、图表实际操作矩阵、最大字号、VoiceOver、手势、真机帧性能仍需验证。

不可变部署快照仍为2026-10-13观察的API19/tick7，50/43文件和14项共享差异未改写；本片维护后台修复未部署。本轮实际Auth/模型/生产SQL/手机安装/部署/推送/付费计算均0。手机仍沿用先前获批的冻结build16，不把模拟器17当成可安装候选。现有路由配置保持OpenRouter→apodex free→Novita限定、fallback关闭；这是源码核对，不是provider实测。

W30只读审计确认持久task.plan目前为空，缺版本化修改、实际applied revision和同任务补充端口。下一片W30a先实现计划v1、CAS修改v2、accepted/applied分离和安全checkpoint应用，保留原operation/run/task身份及冻结请求；随后W31真实公开来源读取、W32精确审批、W33接管/撤权/unknown。AF-A07/CP-01与18A/12U/3CP/9FQ/10CG/七天日用/BP配对均保持未签收。
