# Trigger、图片恢复与原生设备执行候选39 · 2026-10-15

固定候选 `AF-TRIGGER-DEVICE-IMAGE-20261015-39-R3`，源码已提交同步，**0.3.0(39) 仅构建冻结，未覆盖用户38**。这是生产源码/原生组件交付的日期证据，完整主动MVP未Ready；当前状态只见 [master-plan](../status/master-plan.md)。

| 实际实现 | 这版已验证的行为 | 尚未贯通 |
|---|---|---|
| W50配置与due | 真实维护API持久配置、同subject/scope原run/task/request绑定；原命令GET、去重due账本、暂停/撤回/期限与预算；source-first事务围栏 | 明确configured、execution_authorized:false、scheduler_connected:false。旧single_run完全不扩大；没有新run/模型执行、Cron、W51变化游标/通知outbox |
| W20恢复 | 既有JPEG错误重编PNG会改变hash；现严格核原容器/MIME/尺寸/长度/hash并保留原encodedData，仅派生缩略图。冷恢复不恢复图片许可、不重POST；迟到A读不污染B | 维护API仍image_input:false，无实际vision handler/已验证视觉路由；真实像素模型与手机未验 |
| W60/61执行端 | fresh typed permit→持久OS意图→同步一次提交围栏→原marker查询→精确回执。失联后只query，不重复创建；日历成功才通知。EventKit/UN真实adapter已编译，权限仅显式用户动作请求 | 生产App动作producer/注册target/v2服务HTTP与审批组合、通知点击回同事项、后续修改删除和实际OS投递均未接验收 |

后端 **482/482 PASS**；其中17条新服务与6条新维护API组合是子集，不叠加计数。实际使用现有records事务端口与Deno缓存，显式deny-net，HTTP为维护Request/Response组合加注入Auth/模型/内存仓储，非生产PG或网络推理。GET不产生due、task或provider调用，旧grant原字节不变；重复create回同receipt，原操作可GET找回，源撤权后仍可读/停止但不能恢复执行。

原生宿主 **23/23 PASS**（4图片恢复＋9执行端＋8原合同＋2服务/传输），图片package全量 **24/24 PASS**。同候选Debug构建、non-DEBUG Simulator SDK/语法、126 App成员、双语资源及两构建配置的5项权限用途检查通过。OS端口全部注入，不曾弹系统权限或创建真实系统对象；URLSession适配的录制回执不冒充服务端实际执行。用户38与其数据/原会话期限保持。

R1/R2各有同一通知接续方法FAIL，日志和包保留。R1固定测试clock0而录制观察为20秒；R2误在dispatch前推进到20秒，正确触发原15秒lease拒绝。R3遵守原完整时序：0秒期限内提交，提交之后才推进到20秒观察；没有sleep、改fixture或削弱生产校验，整组23方法通过。R1→R3全部产品源码相同，仅这一个测试变化；SDK不重复计为新验证。

源码本地 `a6cbe7f80bc87c01ce5ee0cbd7dc9c0be0a86056`、选择性远端 `e3a26081b67ce89cc9822045ef6dbd0744f36dc0`、tree `390a33bb6ae3ee52e5b6030f3fad0bdabac2e88a`。20条明确路径分6后端＋14原生两次提交，不推旧本地历史。450输入逐项Git blob匹配，采用[基于38的20项差异](evidence/trigger-device-image39/source-delta.json)可重建完整输入行，避免复制450行静态清单；基线/行集合/full snapshot hash均固定。[结果](evidence/trigger-device-image39/result.json)记录方法及日志hash。构建使用既有 managed worktree（worktree-scan-fix），主目录现存源码/他人暂存区未覆盖，AF-A01最终整合门未关闭。33文件冻结包指纹 `a0fe18f8590ef327ab56f2eb1aafc0f3c7938f6db2175638d16a96c3b6f088ed`。生产仍API21/tick8，未部署本候选。

真实文本仍是首要阻塞。已只读核对旧r7服务端硬限32 token/20秒、固定CLI专用会话/turn/message；当前原生Base URL还拒绝多级review前缀，所以不能只换配置或拿旧r7重POST验App。旧429保持FAIL，授权已耗尽；公开Gemma端点存在不证明本账户配额恢复。下一步须先冻结新的具名App/API受理接线、身份范围和单次上限/停止条件，再依具体授权执行；不把CLI或本片合成PASS当App→真实模型→SSE→保存/重开的成功。

没有新增真实Auth/模型、生产SQL/部署/手机安装，未请求系统权限或写入真实日历/通知。AF-A12/13/14/15、CP-02/03、真实主链、同版18A/12U/3CP、FQ/CG/七天日用/具名竞品门均未关闭，FINAL-G3保持ACTIVE。
