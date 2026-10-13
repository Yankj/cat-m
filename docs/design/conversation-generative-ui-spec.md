# 对话内生成式交互规格

版本：CGUI-1，2026-10-13。用户新增输入为 OpenIntelligentUI 与 CopilotKit onboarding 链接。本文是[FINAL-1](../product/catpaw-final-product-spec.md)的必需对话体验细分，配套[验收](../acceptance/conversation-generative-ui-acceptance.md)。当前运行AF-1-G3-UX1及原18A／12U／3CP身份保留，执行状态仅见[master-plan](../status/master-plan.md)。

对话内操作的开合、就绪、输入、受理/生效、表图点选及HIL详见[UX-1 R3交互附录](interaction-scenarios-r3.md)和[可操作提案](prototypes/catpaw-interaction-r3/index.html)；本CGUI-1的六卡、算法、三类动作与边界仍为权威。合成卡片事件不能替代真实结构闭环。

## 1. 采用决策与来源身份

**对话可以同时包含可读正文、工作卡与可交互回答。首版采用注册式SwiftUI组件，不要求先迁移到React或安装CopilotKit。** OpenIntelligentUI提供组件登记、结构参数、流式呈现、局部交互和回同会话的参考；当前固定main仍为`9c982df1a16b734a49d8dd9d1c29b0e4b1b1805b`，见[源码核读](../research/openintelligentui-code-review-2026-10-13.md)及[本次决策](../research/copilotkit-conversation-ui-onboarding-review-2026-10-13.md)。

第二项[onboarding链接](https://copilotkit.ai/onboarding-prompts/b0c0b78b9383)实际返回CLI接入提示词，并非第二个开源框架。它关联浏览器setup的run，要求使用动态latest CLI逐步执行，提及CopilotKit Intelligence的持久投递；本次只读，未执行。未见该run完整配置、最终依赖、收费／托管方案，不能据链接推定已选集成方式。来源与响应hash见[manifest](../research/copilotkit-conversation-ui-source-manifest-2026-10-13.json)。

采用其“检查宿主、明确接入范围、逐步验证”的方法。直接SDK接入、Intelligence、任意生成HTML/JS与新provider均另过互通／资源门；原模型route、Supabase领域权威和零新增计算预算保持。原生GenUI实现可先推进，不以CLI安装作为开工前提。

## 2. 产品范围：工作卡与交互回答组合

六类领域卡choice/form/plan/approval/artifact/comparison继续保持身份。新增的是这些卡或正文内容块的**presentation**，不将每种图表变成新的任务／审批对象，也不把普通回答强制变卡。

呈现选择遵循UX-1设计修订R1：比较多个同口径选项时用表；观察同数据趋势时用图；用户确需改变变量并理解结果时才用试算器。短事实和没有可靠数据的解释优先正文，格式偏好采用可修改默认值；不为展示全部组件而向用户索取无关参数。需要试算时说明假设和适用范围，不将算法可算等同建议可靠。本规则归CG-A01/06/08，不新增presentation或计算内核。

| 呈现 | 本轮必需行为 | 领域映射 |
|---|---|---|
| table | 有来源的数据表，排序／筛选；可恢复原表；只表格自身横滚 | artifact/comparison中的数据视图 |
| chart | 同数据的柱状或折线图；选择序列／数据点，显示原值、单位和来源；能回表格 | artifact/comparison的原生图表 |
| calculator | 注册的确定计算内核，少量字段／滑杆，输入变化立即重算；显示假设、单位与验证错误 | form中的本地试算，结果可形成artifact/comparison |
| explanation | 正文＋分步展开／表图／试算组合；选择变量帮助理解 | 正文与以上presentation组合，不新增任意代码能力 |

首版内核固定为`duration_budget_v1`（总时长、保留时长、步骤数量与单步时长，得到剩余时长）和`weighted_comparison_v1`（已有维度得分与用户权重归一化加权）。输入范围、单位、公式及版本可查；模型不能生成新的可执行公式或将示例得分包装成竞品事实。图、表、计算结果使用同一数据版本。

时长字段统一minutes：总时长／保留／单步0–10080，步骤数量整数0–200；剩余＝总时长−保留−步骤数量×单步，可为负并说明超额。加权比较为2–12方案、1–12维度，已提供得分0–100、权重0–100且总权重>0；结果＝Σ(得分×权重)/Σ权重。十进制计算，展示至两位小数、不改原值；舍入规则固定bankers，公式版本随数据保存。

任意3D、动态外部地图、任意HTML/JS、CDN依赖或新的计算内核是后续扩展。数据来自用户提供、已读取成果或明确人工假设；无数据时询问或给正文，不造实时统计、来源和价格。

## 3. 三类交互必须分开

| 动作类别 | 正常行为 | 不得发生 |
|---|---|---|
| local_interaction | 排序、筛选、选择数据点、展开解释、调整参数；本地立即响应，不追加模型请求 | 自动创建turn/run、保存记忆、创建日程或改变任务完成状态 |
| agent_followup | 原生“用此方案继续／请解释这个结果”明确提交，携选中值、来源版本与原会话引用 | 滑杆每变化一次发一条请求；模型生成内容自行触发发送；将传输结束当决定受理 |
| domain_command | 改计划、审批、日历／记忆写，沿原typed command、revision、权限与effect核对 | presentation或JS直接调用写工具，旧版本批准新内容 |

点击跟进先500ms内本地反馈，防双击；未发送时可保存明确草稿，切页／重启不伪装已送达。服务端受理后恢复只读取原operation；unknown不自动重发。改稿与跟进都关联原conversation及领域工作，没有Task的解释型回答不强制新建Task。

“同工作继续”不等于同SSE run内双向通信。AG-UI的参数结束仍须schema校验，frontend结果通常在后续run/resume回传；协议不是任意mid-run用户回传通道。界面可以在其他正文仍流时收取决定，服务端在新turn/run或安全checkpoint接续；分别展示“已受理／待安全点应用”，不宣称已经改变正在执行的工具。

## 4. 数据契约与受控registry

以下是展示语义，不直接改写冻结v1/v2 HTTP。落地先输出现有Swift类型→API事件／snapshot→存储字段的映射；缺失字段用可选版本化payload或独立能力接口兼容，旧客户端仍能显示正文和成果链接。注册信息来自已编译组件，服务器按客户端能力清单选择；陌生presentation／schemaVersion不得执行。

| 字段 | 必需语义 |
|---|---|
| identity | stable blockID/cardID、conversationID、turn引用；适用时objectID／objectRevision、artifact version/hash |
| presentation | table/chart/calculator、schemaVersion、registered renderer／kernel版本 |
| data | 单位、列／序列／字段、完整输入、来源引用或明确假设标记；不可执行文本作为数据 |
| local_state | 排序／筛选／权重／当前选择，按账号scope＋会话＋block＋数据revision分区；可重置 |
| actions | 已登记的三类动作与允许字段；agent_followup显式意图；domain_command引用真实action／revision |
| fallback | 可读说明＋原数据表／成果入口；无有效参数时无写按钮 |

边界固定：一个完整结构payload UTF-8≤64KiB；表≤12列×200行，单元格≤2000字符；图≤4个序列，每序列≤200点；source引用≤20项；标题≤200字符，标签≤80字符。超限不静默删数据，提供摘要与完整成果入口。数字必须有限且单位匹配；计算器禁止NaN/Infinity、除零、负步骤数及全零权重，错误定位字段，不伪造有效结果。

registry负责decode/validate、renderer、local reducer、允许action和fallback。持续文本、参数结束、对象已保存、用户已读、决定已受理、effect已完成分别记录。模型选择呈现不扩大权限。

### 首片接入映射

| 现有端口 | 首选接入与兼容边界 |
|---|---|
| [ConversationSessionContracts](../../apps/ios-conversation/Sources/Domain/ConversationSessionContracts.swift) 的toolStarted/toolResult | toolStarted只投影稳定占位；已登记展示tool的完整toolResult.content经有界JSON校验投影。其后正文可继续流；不虚构现有wire已有参数delta或双向mid-run通道 |
| ConversationToolResult.callID / committedGoals | callID关联稳定block；已保存领域对象只来自committedGoals或真实读取，展示参数不能制造“已完成任务” |
| ConversationArtifactProjection.id/version/contentHash/content | 持久成果的CGUI描述与来源随版本保存并核对hash，历史由真实投影重读；不能只保存React或客户端RAM状态 |
| [ConversationFirstModel](../../apps/ios-conversation/Sources/App/ConversationFirstModel.swift)、[原生HTTP](../../apps/ios-conversation/Sources/Providers/NativeChatHTTPBackend.swift) | 既有operation/epoch/sequence和账号分区护住事件；新增presentation projection／local state独立于执行权威，普通Send与跟进意图明确区分 |

首选新客户端经现有可兼容context/capability边界协商CGUI-1，再开放登记的展示tool；未声明能力的旧客户端继续获得正文／成果入口，不裸露JSON当回答。是否能沿现有toolResult.content完整承载，应在W12/W70先固定实际编解码映射与样例；若不可兼容，版本化可选接口，不篡改冻结合同。这是实施入口选择，不宣称相关tool与协商字段已部署。

## 5. 流式布局与恢复

参数生成中显示稳定占位和摘要，不逐字符重建表单。合法完整presentation可以呈现；已可调参数／已编辑的字段不因后续token回退。需要持久决定的卡只有权威对象就绪后可提交；部分参数、版本冲突或未知schema只读。

表图在正文同一列中显示，复杂内容可一次点按进原生详情，返回保留锚点和本地选择。不自动展开大图吞掉屏幕。正文仍可选择、复制；图表有标题、单位、来源、数据点说明与完整数据表替代入口；44pt触达、成对浅深色、最大辅助字号、VoiceOver和Reduce Motion沿UX-1。

首屏顺序固定为标题／简短解释→关键结果与单位→紧邻的必要参数或数据→来源／假设／公式说明→重置与显式跟进。重置是次动作，跟进是唯一主动作；不把schema、hash或工具路由放主阅读层，版本与诊断可展开。卡沿UX-1的20pt外边距、16pt内距、20pt圆角、17pt系统body及成对语义色，不为每种图表新增强色。

表在对话内先展示最多5行和已选择的主要列，注明总行列数，“查看完整表”一次点按进原生详情；压缩预览不删除源数据，排序／筛选作用于完整合法数据集，结果计数可见。图表普通字号约220pt高，选点的原值／单位以可读行显示；大字号允许增高或切数据表，不依赖hover。计算器默认同时显示结果与最多4个核心输入，数字键盘支持完成／单位／错误，滑杆另有等价文本输入；最大字号按钮纵排。数据点的小标记不作为唯一44pt操作入口，提供原生序列／点选择或数据表行。

历史保存内容／数据引用与版本，不保存临时签名URL。本地试算状态按数据revision保存；重开若数据已变化，说明差异并提供重置／显式重用，不能把旧输入当新版本的批准。已删除／换scope／切页后的迟到回包不投射；控件点击与增量更新不抢输入焦点或阅读位置。

## 6. 两条必需演示路径

**解释与试算：**输入人工时间预算→正文解释＋原生计算器→改变三项参数→立即得到正确剩余时长且零新请求→明确点“用此方案继续”→一次受理原会话的新turn→按选择生成说明／计划。结果是试算不是已创建日程；若继续创建日程，重新进入真实精确审批。

**成果探索：**给定三份公开资料→真实读取后形成有来源的比较成果→对话内同版本table/chart→排序、筛选、选择点并核对原值→离开／重开恢复→“按当前权重解释”一次跟进原工作→修改范围／成果冲突时保留输入。未知、超限、非数值或缺来源时可读降级。

至少一条路径有真实现有模型→结构输出→原生交互→持久跟进→同工作继续的证据。图表、算法边界和异常矩阵可离线回放补验；回放不替代真实闭环。后续真实调用须固定数量／预算／停止条件，不借本spec扩大当前两次短文本许可。

## 7. 实施切片与采用门

W12/D20补稳定内容块／增量投影，W30/D30同工作跟进，W31/D30来源／数据版本，W32/W33维持决定／effect，W70/D30/D50 registry与table/chart/calculator原生呈现，W71汇总CG-A01–10。不把所有GenUI推迟到S07末尾；S01验证与纯本地组件可分别推进。

正式CopilotKit SDK／AG-UI adapter采用前，固定包／许可／来源，验证一条同会话正常路径、协议失败、重开、数据隔离和现有HTTP兼容；证明减少实现成本或增加确定体验收益。新增依赖、Intelligence项目／账号／托管、CLI onboarding配置与任何外发信息形成具体变更清单后按现有授权处理。SDK不是持久审批／调度的替代品。

开放Web可视化只保留实验方向：独立无凭据viewer、固定资源、网络／bridge边界、原生显式跟进，实际隔离另验。不在本轮必需原生GenUI中运行模型生成的任意脚本，不由Web层决定执行成功。
