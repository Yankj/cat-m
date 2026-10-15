# W31 / W32：同成果人工改稿与原生精确审批恢复

日期：2026-10-14。候选 `AF-W31-REVIEW-20261014-04`，基线 `483f7ad9db0101bf4929d671f2448726e4be6348`，分支 `feat/s03-result-amendments`，原生版本 `0.3.0(20)`。本记录固定该候选的源码与离线验证；当前进度仅见 [master-plan](../status/master-plan.md)。证据限离线维护实现与原生 Simulator，不能签收 W31/W32、CP-01 或 FINAL-G3。

## 用户行为与实现

用户从选定成果版本进入原生编辑 sheet，分别修改标题、摘要与正文。修改草稿与聊天输入独立保存，关闭重开保留原始输入；已提交但结果未知时，只核对原 operation，不能再次 POST。用户可以继续保存新草稿，但页面明确区分新稿未提交与原修改待核对。成果已有新版时，不偷偷换基线；先读取，再由用户明确保留输入并换用新版。

维护 API 的 `catpaw.task-artifact.v1` 将三字段人工改稿绑定原 scope、subject、run、task、artifact、版本、正文 hash、许可 epoch 与计划 revision/hash。事务内同时写入不可变新版、head、任务投影和原 operation 回执，失效旧动作；原请求和旧来源快照不改写，也不调用模型、重读来源或唤醒 worker。新增论述未经重新核对，原引用只能说明原版本的来源。人工保存不是任务状态完成，也不是自然语言模型改稿。

原生动作 sheet 展示精确时间、时区、提醒、目标、来源、计划、成果和到期，批准或拒绝使用预先持久保存的 UUID 与 payload hash。关闭不作决定；unknown 冷启动只读原决定。目标核验未配置时不能批准。`approved` 只保留批准事实并停在 `waiting_device`；`execution_authorized=false`，没有 EventKit 写入或系统效果回执。

UI 只调用 typed application services。实际 NativeChatHTTPBackend 提供有界 URLSession 端口、凭据和 scope 核验、严格 JSON、exact 回执与原 operation 读取；未发送、明确拒绝、已应用与未知分别处理。错误状态或模糊 HTTP 不能产生成功。许可、前后台、退出登录和 HTTP admission 同步传给计划、成果与审批服务。

## 审查发现与恢复边界

独立审查复现：负向来源状态之后，晚到旧版、同版和更高版投影会重新露出成果。修复在原 frozen binding 内持久保存 `sourceAuthorizationCurrent=false` 的不可逆屏障；迟到投影不能恢复 current head、完成态或补入未见历史。正常获授权的更高版本仍能合并，选定阅读版本不跟随 head。

实际 AuthApplication 曾先等待本地模型 detach，再关闭 manager；等待期间 refresh 能重新挂回 chat、保留 token 并推迟 barrier。修复先同步清空引用和网络 admission，立即关闭 manager generation/credential/barrier，与本地排空并行；所有跨 await 的会话挂接检查独立 lifecycle epoch。实际宿主 SwiftData/Manager 回归覆盖 held refresh、held drain、注销与正常重新登录。

成果和计划模型的异步保存队列曾在 forced logout 时丢掉已接受的最后输入。现在按 scope 同步登记一次性保存 ticket，先拒绝新输入，等待此前已接受的本地保存队列，再完成 invalidation；网络不占本地草稿锁，并发 invalidation 共用结果。磁盘写入失败会报告未保存，普通关闭/下拉受限，内存原文保留。**如果磁盘持续失败后强制退出，最后输入仍不能保证冷启动找回**；本片没有新持久化恢复底座，不关闭日常可靠性门。

真实 URLProtocol 负向用例发现 Swift `String.contains` 对 CRLF grapheme 的检查漏过 header 控制字节；改为 UTF-8 CR/LF 检查及 8192-byte 上界。CR、LF、CRLF 与超长凭据均在发请求前拒绝，调用数为零。严格 JSON 同时拒绝转义后重复 key、非法数字、过深结构及尾部垃圾，保留合法但 Unicode 正规化不同的 key。

原生初轮保留编译/选择器和 DEBUG probe 失败。其后全部 18 项成果测试曾通过，但截图发现最大字号下 footer 将聚焦正文挤到仅剩标题可见；没有把该 PASS 当作体验关闭。保留实际可见高度 21.33pt 的 RED。缩短可见状态及保存按钮并保留完整 VoiceOver 描述、按焦点/布局滚动后，三 UI 再通过且容器可见 227pt，但截图仍发现最后输入与光标被 safeAreaInset 底栏遮住。这个第二次视觉失败也保留；容器尺寸断言不能代替实际可编辑性。后续把底栏移到 ScrollView 同级布局、按实际 viewport 限制文本框高度，并核对合成末行标记与光标。未知状态不再误写“尚未提交”。统一回归初轮因真实截图发现主动中断；仅已执行 50 单元通过，整轮不计 PASS。最终 r7 按实际全局 viewport、safe area 与底栏边界约束文本框，最大字号正文可见 147pt，末行 END 标记和光标在底栏上方；保存与关闭目标为 91.33pt／44pt。状态短标签用 Pending，完整 VoiceOver 描述仍明确原修改待核对。截图、容器尺寸与触控边界分别记录，未验证真机全矩阵。

无签名 Simulator 的第二轮集成为 **61／64 PASS、3 FAIL**。三个 Auth UI 在初次登录写 Keychain 时失败，实际系统探针复现 `OSStatus -34018`；没有跳过或改用 fake vault 将其算作通过。手工 ad-hoc 包也启动失败并保留。随后使用仓库既有 SimulatorFixtureAcceptance 模板，由 Xcode 生成仅本地 Simulator 的 ad-hoc 测试包，真实 Keychain round-trip 和账号切换先通过；未使用真实证书、开发者账号、profile 或手机签名。

冷恢复旧 UI 断言要求自己的稿在远端验证期间隐藏，与既有 `DeviceTrialNativeTests.testP0ExistingLocalConversationAppearsWhileAuthValidationIsHeld` 的合同冲突。只更正 UI 检查：同 issuer／subject、未退出登录的本地 receipt 可读自己的稿，实际 phase=restoring、validated user=nil、HTTP admission=false、turns=0；验证有效后同稿保留，确认撤销后移除聊天页面。另保留 foreign subject／issuer／logout receipt 禁止打开以及 manager authorization 拒绝的单元验证。生产 receipt 规则未改；冷恢复合成夹具与首次登录一样使用 Unconfigured backend，避免 `.invalid` 的无效网络尝试。DEBUG probe 分别观察 Auth 和聊天模型，并在聊天页与登录页读真实状态；撤销必须准确到 loginRequired，任意错误不能算通过。探针不提供授权；turns:0 仅为本地 session 可见数量，不替代实际 transport／effect 计数。初版探针只观察 App 层相位，可能漏掉模型自身更新且退出后缺少相位见证，因此该轮主动中断并保留，后续重新固定源码验证。

## 验证与下一步

最终 **67／67 原生 PASS（53 单元方法＋14 实际 UI，0 失败／跳过）**，Release Simulator 0.3.0(20) 构建成功。90 宿主 source memberships／3 targets、895 双语及目录、冻结来源、部署快照、AF／FINAL／CG规划、敏感和空白检查通过。168项原生固定输入、50项改动 source/test、包／日志 hash及九张最终合成截图 provenance 见 [RESULT](evidence/task-review-20261014/RESULT.json)。不同层测试数不相加；SwiftData／实际URLSession／实际Keychain与合成远端／Store分别标记。本片后台 184 项离线回归已通过：156 既有、20 新改稿 kernel 与 8 实际维护 HTTP；HTTP/模型/Store 均为显式合成端口，未调用生产 Auth、公开来源、模型或 PG。

下一片优先贯通自然语言对选定成果的修改：明确 exact artifact target、新 turn 冻结完整原请求、现有模型完整 round、同 task 新版和 continuation 关系；普通提问不能隐式改稿，不能用新 delegate task 冒充原工作延续。随后补 W33 真实接管/撤权/unknown，以及依赖明确的记忆、GenUI producer、变化跟进与本地日程。

本片未安装、部署、推送、切换 provider、添加依赖或凭据，新增计算费用为零。冻结 build16 最多两次正常 App 短文本仍为零次；Release Simulator 候选不扩展原手机授权。真实同版模型/来源/SQL、实际日历效果、独立调度、真机手势/动效/可访问性、七天日用和具名竞品配对仍未验证；AF-G5、FINAL-G1/G2/G3 必需门保持未关闭，Goal ACTIVE。
