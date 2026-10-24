# M2：从原安排说改动

2026-10-23。接续 [育儿核心规格](parenting-core.md) 和 [逐步路线](parenting-milestones.md)，不改写独立治理分支的权威入口。M1 固定候选 `c37d82e8424fcaf323ab3cd96ea6bdd90084cbd4` 的 [CI40032353790](https://github.com/Yankj/mimi/actions/runs/40032353790) 已终态成功：69 模块、7 UI 全部通过，Edge 913 总数 / 911 通过 / 0 失败 / 2 跳过，另保留 12 个既有隔离文件。UI 使用真实 Home、Keychain/AES、SwiftData 和冷启动，身份及 AI transport 合成。此证据关闭 M1 代码与合成原生回归门，不代替真机、真实模型或生产验收。

## 逐片交付与完整退出门

同时间只集成 M2 的一个纵向切片：

1. **M2a 原安排改期与撤销**：选择现有安排 → 说本次改动 → 只读整理 → 完整日期/时间差异与澄清 → 显式确认持久保存 → 重启后仍可撤销。修复旧编辑表单覆盖后来修改的版本问题；同一钟点只提示可能冲突。
2. **M2b 有界周期和单次例外**：明确时区、当地钟点、每周日及截止日，稳定实例身份；仅这次改期/取消和本次及以后范围分开，不改写完成事实。实际 Calendar 运算覆盖 DST 缺失和重复钟点，不能固定加秒数。
3. **M2c 本机提醒**：用户明确选择提醒，独立权限、持久 desired generation、系统库存核对、改期/取消/撤销/完成/删除的一致清理，通知点击回原安排。提醒保存与设置成功分别呈现；真机锁屏和后台送达另验。

M2a 通过不等于 M2 完成。M2b/M2c 仍是本里程碑关闭门，不能用手工编辑或静态提醒卡替代。只沿现有分支及草稿 PR；不合并、部署、发版、调用生产服务、导出上传或混入独立治理提交。

## M2a 家长旅程

- 从安排的“调整”进入，看到原名称、孩子、目标及完整时间，选择对象后无需重录这些背景。原安排来源不被本次话语覆盖。
- 本次原话单独输入，例如“改到明天下午五点”。显式“让小咪整理改动”前说明将发送原名称、原时间、本次原话及本次解释时区；不自动附孩子档案、目标内容、历史观察或整个家庭日历。
- 候选只更改时间，名称、孩子、目标、状态和原始来源保持。完整显示“原来 → 调整后”及本次解释时区；必须先明确采用，再点击“确认调整”保存。
- 日期、钟点或上午/下午不明时保留原时间并显示澄清；不能默认今天、现在、旧钟点或自动应用 null。本片不解释“推迟半小时”、取消/周期指令或从全家事项中猜指代。
- 同一分钟已有其他已安排事项时列出名称与时间，标为“可能同一时间”。只有 dueAt，没有时长，不能声称检测了区间重叠或确认没有冲突；家长明确核对后才能保存。
- 保存失败保留本次输入和相同操作 ID；unknown 只读取原请求。取消、换输入、换账号、目标变化和晚到回复都不能填回旧候选。
- 保存后在原安排提供“撤销上次调整”，重启后仍能找到。撤销只逆转该次安排变动；期间手改、取消、完成或删除后拒绝旧撤销，不能覆盖事实或恢复整份旧账本。

## 单一集成人冻结的共享契约

root 维护本节及集成；实现者只按约定修改各自文件，变更接口先回报。

### 领域与持久化

- `ParentingArrangementEditTarget: Codable, Sendable, Equatable`：`arrangement: ParentingArrangement` 与 `workspaceRevision: Int`。完整快照来自本机选择，不接受模型返回身份。`matches(workspace:)` 同时检查 revision 和原安排完整值。
- `ParentingArrangementEdit: Identifiable, Codable, Sendable, Equatable`：`id: UUID`（changeID）、`before/after: ParentingArrangement`、`sourceText: String`（仅本次改动原话，手改可为空）、`createdAt: Date`、`revertedAt: Date?、supersededAt: Date?`。`after` 是已应用的精确结果，不是未来拟写状态。
- `ParentingWorkspace.editHistory: [ParentingArrangementEdit]`。保持 schemaVersion、preference key、sealed prefix、密钥和旧 command 编码；旧 JSON 缺此字段解码为空，显式 null 或类型错误拒绝，不能将旧账本读成空或改写旧 operation fingerprint。
- 新 command：`reviseArrangement(id: UUID, target: ParentingArrangementEditTarget, title: String, dueAt: Date, goalID: UUID?, sourceText: String, acknowledgedConflictIDs: [UUID])`。领域再次核对冻结 revision/快照、draft/planned 状态和引用，拒绝无变化。before/after/history 与安排在原加密事务中原子保存。
- 新 command：`undoArrangementEdit(id: UUID, acknowledgedConflictIDs: [UUID])`。只对未撤销、未被后续变更失效且当前安排精确等于 `after` 的记录执行，恢复 before 的相关字段并更新 updatedAt、revertedAt；期间变动则拒绝。后续同对象写入持久设置旧记录 supersededAt，即使相同时钟下 A→B→A 也不恢复撤销资格；canUndo(in:) 供 UI 共享。恢复原时间有同刻事项时同样需精确核对 acknowledgedConflictIDs，UI 对话期间冻结 expectedRevision。继续使用新 operationID 和已有 Store CAS/指纹去重，不恢复整个 workspace。
- `workspace.sameTimeConflicts(arrangementID:dueAt:)`：排除自身，返回其他 planned 且 dueAt 为同一分钟的安排；排序稳定。确认命令的 acknowledged IDs 必须与当下集合完全一致，无重复 ID。该提示不推断时长、照护者或可行性。
- 删除孩子/安排清除所属 editHistory；删除目标不得被撤销复活，历史中的引用须相应清除或撤销时拒绝无效引用。历史验证与旧数据兼容、账号 epoch、错误不发布成功均保持。
- `ParentingWorkspaceModel.apply` 增加 `expectedRevision: Int? = nil`（现有调用默认不变）。编辑表单用冻结 revision，而不是提交时最新值；领域 target 比对仍独立保留。

### 原位 AI 整理

- M2a 不改后端 endpoint/purpose/output v1 的严格七键结构，不放宽禁工具/记忆/动作、删除墓碑或 runtime-only 内容规则。只复用其“一个待核对安排建议”能力。
- `ParentingIntakeRequest`、`ParentingIntakeRecoveryReference`、`ParentingIntakeDraft` 以及 controller `request(...)` 增加可选 `editTarget: ParentingArrangementEditTarget? = nil`。旧记录缺字段按 nil 解码，**nil 分支的 prompt 必须与 M1 逐字相同**，确保原 ID 回查及完整请求比较兼容。
- edit 分支只在 prompt 额外发送原 title/dueAt 与本次解释时区；target ID/baseRevision 只保存在本机绑定，不必发送给模型。`time_evidence` 仍只在本次 sourceText 匹配，不能拿原时间充当新证据。模型 title 不应用，候选 title 使用 target 原名称。
- 新上下文与 Work、lastInput、retry、recovery、candidate 共同绑定。`isCurrentCandidate` 比较 context；UI 还要与当前冻结 target 及账本核对，不能把编辑恢复到新建表单或另一个安排。
- edit 模式增加有界时间语义核对：明确日期与钟点，上午/下午歧义、无效日期、相对日期与请求 now/zone 不符、DST 不存在或重复的本地钟点均不能自动填入。先支持明确 ISO 年月日＋24小时钟点、今天/明天/后天配明确日段或24小时钟点；其他表达显示可编辑澄清，不宣称全自然语言时间覆盖。真实模型能力另验，测试只 mock。
- null dueAt 是澄清，不清空原安排、不启用候选采用、不自行继承原时间。取消/unknown/恢复/删除与 M1 相同；本片不新增服务器原话副本或自动读取家庭档案。

## M2a 验收与证据层

必须调用真实产品接口，不复刻领域算法或以字符串存在代替行为：

- 旧 M1 JSON、操作回执及无 context 的原 prompt 兼容；新的编辑 context 加密冷读及原请求核对不串到新建/其他安排。
- 明确改期保留 ID/孩子/目标/原始来源，保存后冷读原对象和一次 history；失败回滚、同操作重复/并发、同 ID 不同内容、旧 revision/快照拒绝。
- 日期/日段歧义及 DST、来源证据不符、旧回复/账号/输入变化、取消后迟到、unknown 不能新发请求。
- 同时刻提示及明确核对；核对后账本变动使提案失效，不冒充区间重叠检测。
- 撤销冷读、重试幂等及期间手改/取消/完成/删除竞争；不得移除完成记录或复活目标。
- 至少一条真实 SwiftUI 旅程：原安排 → 显式整理许可 → 差异/采用/确认 → 同 ID 冷读 → 撤销 → 冷读原时间。保留 M1 的 69 模块和 7 UI 回归，新增方法按实际实现登记，不先报通过数量。

Linux 无 Swift/Xcode；静态、实际后端 mock 模块、SDK/XCTest、模拟器 UI、真机及线上结果分别记录。CI 通过不证明真实模型提取、真实家庭效果或通知送达。M2a 已按此合同完成本地实现并经独立只读审查；新增 14 项领域/Store 测试、16 项 request/parser/controller 测试及 1 条真实 UI 旅程，连同 M1 原有选择共 99 模块、8 UI 待新候选 SDK 执行。静态工程 241 源/4 targets、capabilities 13、品牌兼容 472、diff 与脚本语法通过；L10 前四段 1430 lookups/360 育儿声明/2111 双语条目及插值检查通过，最终 plist 阶段因 Linux 缺 plutil 未执行。敏感扫描无新增，保留原有图片及 OAuth 合成凭据两待审；layout/frozen 仍报既存迁站及历史 ReadoutPolicy pin，不在本片改动。此段为实现时的静态记录；随后913d9f9实际SDK编译通过，但99模块中1方法有2条Lord Howe断言失败，8 UI中6通过/2失败，尚未通过M2a回归门。具体终态、下一候选的偏移唯一性/44点命中/候选内时间标识修复见[日期CI证据](../../acceptance/family-companion/parenting-ci-2026-10-23.md#913d9f9m2a首次原生执行与确定修复)。M2b/M2c 尚未实现。


2026-10-24接续：1180815的Xcode编译、99模块及原有7 UI实际通过，新增改期UI取得候选后因测试先向下查名称、再默认向下找上方虚拟化采用按钮而失败。下一候选将原名称保留断言移到实际采用之后，顺着表单核对并保留全部保存/冷读/撤销断言；数值等待上限不变，没有新增方法或产品功能。完整证据及未验边界见[2026-10-24日期记录](../../acceptance/family-companion/parenting-ci-2026-10-24.md)。M2a仍待新SHA完整99+8通过，M2b/M2c未接入。
