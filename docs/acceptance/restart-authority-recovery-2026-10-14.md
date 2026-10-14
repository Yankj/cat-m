# W33：同工作控制、原操作恢复与共享原生编辑层

日期：2026-10-14。候选 `AF-W33-CONTROL-20261014-06`，基线 `a444e4ff5af7da81132f1fe647d6379319913c7f`，分支 `feat/s03-authority-recovery`，本地原生版本 `0.3.0(22)`。源码、包、日志及截图 hash 见 [RESULT](evidence/authority-recovery-20261014/RESULT.json)，当前进度仅维护 [master-plan](../status/master-plan.md)。本片固定维护源码与离线证据，不签收真实 W33、CP-01、AF-G5 或 FINAL-G3。

## 用户行为与执行权威

用户从原工作卡打开暂停、恢复和撤回授权。暂停保留原许可；恢复仅针对同一个 Task，核对当前计划、许可、执行 revision 和来源；撤权退休租约并推进权限 epoch。已经发出但未确认的模型、来源读取或 effect 保持原编号，不能恢复后重发；缺少原结果身份也不能推断已解决。关闭页、切换对话、后台及冷启动都保留原提交和待核对入口，恢复只 GET 原 operation。

typed `catpaw.task-control.v1` 绑定原 Task/run/request hash、精确计划 revision/hash、grant epoch、execution revision 与 snapshot hash。后台复用 scoped Repository 事务，在关键 await 前后检查权威；GET 和重放零 kick。HTTP 取消、截止时间、跨 scope、损坏回执及完整身份错配均被拒绝。记录自 hash 正确不能替代冻结原意图的交叉绑定。页面通过应用服务操作，账号与 HTTP admission 仍由宿主及适配器组合。

两种维护 worker 共用执行栅栏：同 lease、尚未过期、控制 revision 和 authority hash 必须都匹配，最后 await 后仍检查。活跃租约不能被另一执行者接管；旧 heartbeat、错误收尾、put 与晚到结果不能覆盖已经提交的停止状态。dispatch 后 abort 保持 unknown，不能重排。修改来源 logout 暂停当前 revision，原受理来源 logout 撤权并取消；旧成果和 unknown 原编号保留。控制 journal 与孤儿记录进入删除库存。这些是离线注入证据，尚未证明真实 PostgreSQL 多实例。

已确认控制回执只触发原对话进展 GET，不直接宣布工作完成。关闭页、在 B 聊天、后台或重启后仍按原 A/run/receipt 定位；账号停止阻止晚到 GET 写入。失败有界退避，其他聊天可以继续。工作取消与外部结果未确认是两个事实；取消卡不能被晚到完成投影复活，撤权不宣称回滚已经发出的外部操作。

## 共用体验机制与剩余差异

SwiftUI 环境统一决定 UIKit 语义字体和 Dynamic Type category，关闭独立重复缩放。阅读标题换行，紧凑关联栏独立保留版本和完整朗读；Sheet 继承字号与 locale。对话和人工改稿共用编辑器，保留原文、选择区及 marked text，将 TextKit 字形布局缓存与 UIKit 视口、滚动尺寸提交分开，避免系统自动滚动动画覆盖光标。真实窗口、safe area、导航栏和键盘取边界交集，仅扣一次；可编辑行和 44pt 发送优先，低空间时通过详情找回上下文。

正在拖动、减速或中文组合时不接管用户滚动。inline 与详情相册共享同一 Draft；离开仅取消当前 ticket 未完成的读取，已接收数据由 Draft epoch 和账号作用域拥有编码。最大字号 unknown 页的展开按钮与每行原编号有独立 AX 身份，完整 SHA 和未确认状态仍可读。

八张 [截图与来源](evidence/authority-recovery-20261014/screenshots.json) 保留原字节；历史附件名字中的 v19/v20/v21 不是当前包身份，实际本轮包为 22。视觉复核发现最大字号工作卡长标题、状态同排过窄，英文词内断行；取消状态可读和行为通过，不构成整体视觉 PASS。部分活跃辅助文字仍直接使用 caption 12pt，完整图片预览环境未验，亚像素 extent 比较造成重复 viewport commit；完整长文编辑入口、物理 IME/VoiceOver/连续手势仍待交付和验收。不宣称全 App 字体与弹层已经根治；下一片用语义角色、源码检查门和共用自适应 header 统一收敛。

## 固定验证与保留的失败

最终 **80/80 单元（r4）＋20/20 实际 Simulator UI（r3）**，100 个不重复方法、零最终跳过。生产源码相同，r4 唯一输入变化是旧队列测试加强异步等待及 fresh 持久存储核验，没有强制 refresh 或修改产品代码。**r3 整轮仍是 99/100 FAIL**，没有改写为整轮 PASS；各方法所属执行见 [native-cases](evidence/authority-recovery-20261014/native-cases.json)。

225 维护后台离线、其中 17 控制专项、22 原生恢复场景、8 实际 URLSession 适配场景、图片 Draft 包 18 项通过，证据层不相加。Release 无签名 Simulator `0.3.0(22)`、非 DEBUG SDK 类型检查、99 宿主成员、968 双语通过。232 原生输入、84 维护后台输入、八张合成截图、包及日志 hash 固定于 RESULT；冻结依赖另由仓库完整性检查固定。目录、冻结/MIT/精确 patch、部署快照、AF/FINAL/CG 合同、敏感与空白检查结果见 RESULT。

保留首轮 92 方法失败及 r2 的 97/100：两个共享 caret 方法和最大字号原操作 AX 行身份失败。六项实际 UIKit 单元与一项 AX UI 定向分别 GREEN，原断言保留；长文观察两个真实显示帧，证据不再硬编码 PASS。r3 旧队列检查仅等待 `!enqueueing`，不足以保证 repository 订阅的 UI 投影已完成；测试补原 UUID/原文、producer 实际队列、自然 UI、拒绝登录前后 fresh SwiftData 重开，同一原消息保持未发。五项控制投影夹具改用真实 `session.create`，未放宽生产服务。

后台早期在同一事务注入暂停后整体回滚，错误诊断保留并更正；真正复现的是活跃 lease 接管及 dispatch 后误重排。回执自 hash 正确但原意图错配的 20 个变体、公共来源 unknown 库存遗漏、unknown 原身份缺失的 RED→GREEN 均留证。

[长文测量](evidence/authority-recovery-20261014/layout-metrics.json) 保留全部运行：44,960 UTF-8 字节、30 次真实 `insertText`、60 个显示帧。隔离 r5 同步 p95 为 10.89ms，最终 r4 为 10.75ms；同时 Release 构建的 r3 为 519.69ms。差异归因未证明，不能只挑较低值宣布性能 PASS；两个显示帧的 settled 时间也不是输入 callback 延迟。139 次 viewport commit 的重复提交待优化；物理设备性能门 NOT_RUN。

## 旧手机版本和未验范围

手机仍为冻结 `0.3.0(16)`，与本地 22 分开。用户允许恢复或创建一个匿名体验身份后正常 App 进入，经手工允许原文“Reply only: received.”，显示已发送而回复失败 `free_model_unavailable`；第一条额度已用，第二条未用。脱敏 API19 聚合日志显示许可与 turn 各 POST 200 一次，受理/dispatch/provider admission 各一次；在 provider_stream 失败，无 first delta。现有路由公开 endpoint 元数据当时为空，与部署 adapter 的上游 404 映射一致；原 provider 正文未取得，不能断言永久不可用。零价替代 endpoint 的隐私兼容性尚未证明，没有切换或付费回退。私人设备观察和原始日志保留 ignored local-audit，未导出账号或认证材料。

没有新增手机包、安装、部署、推送、依赖、凭据或计算支出。API19/tick7 冻结差异保留，维护源码未冒充同版部署。真实 PG 竞争/重启、同候选模型/来源、系统 effect、物理可访问性与性能、独立跨两个 due、记忆、日程、GenUI producer、七天日用及竞品配对均未完成。

W50 后续先有限持久 work grant，再独立 due；过期 JWT 仍不能创建新命令，预算跨 tick/due 累计，unknown 不退款或重发，最后合法调用仍可有界收尾。W60 先版本化执行合同，旧 review-only 批准不因新版获得写权；日历和本地通知分别持久结果，unknown 只核对。新后台原语属于下一候选 WIP，未纳入本片或接入产品。长期 FINAL-G3 保持 ACTIVE。
