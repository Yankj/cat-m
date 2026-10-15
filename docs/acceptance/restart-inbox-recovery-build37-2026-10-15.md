# build37：跨会话查收原任务与精确成果

2026-10-15，候选 `AF-S03-INBOX-20261015-37-R9`。本片交付可构建源码和实际 Simulator 用户路径；属于维护 API＋注入 Auth／模型／测试仓库的离线证据，不关闭 AF-A08、CP-01 或 FINAL-G3。

在 B 对话保留未发草稿，通过原侧栏“任务／成果”查到 A 的工作，打开原成果版本并核对相同 hash；返回仍是 B，冷启动后重新查询仍能查收。明确点击“回到原对话”才保存 B 并切换 A；再回 B 原文、空白和换行保留。查询及切换不重新发送 turn、调用模型或启动 worker。

本机没有 A 的原会话 journal 时，仍可通过原服务端 GET 阅读获准的成果；返回入口直接说明“原对话尚未保存在本机”，不创建空 A 或伪造历史。完整远端会话恢复尚未实现。

| 身份 | 固定值 |
|---|---|
| 本地源码提交 | `95ac3fd20c44b83e274f2728feb66aee2802c56f` |
| GitHub 源码 | [acb1edd](https://github.com/Yankj/catpaw-m/commit/acb1edd568c28ac0cf1064d58b5d8485c390880c)，tree `a0810138b50679193bc7847f45703fa70c7af902` |
| 来源 | 接续 build36；20 个明确审阅路径选择性发布，429 个固定输入在本地提交和独立远端索引逐项对应；未发布旧本地历史，未合并 main |
| App | `0.3.0(37)`，Debug Simulator，原 bundle；32 文件指纹 `f346b1e31ddc2621b343ae3c1129568905415752f8968801377c5b4126766397` |
| 冻结输入 | [source-snapshot.json](evidence/native-inbox37/source-snapshot.json)；摘要及日志／截图 hash 见 [result.json](evidence/native-inbox37/result.json) |

实现沿用一个领域与权限来源：新增 `GET /catpaw/inbox/v1/scopes/{scope}/items`，按当前 subject／server scope 读取现有 run、原 turn binding、Task、Artifact 和 Action；不建第二任务或通知状态机。默认20、最多50项，以原 created_at／run ID 和首屏 watermark 分页，cursor 绑定账户与空间。计划摘要来自 applied revision，不能把 accepted 当作已应用。

所有列表项重验原 owner、subject、空间、会话、turn 与冻结请求；精确成果读取复用原 canonical decoder，核对 run／task／id／version／hash／正文。新 head 不会被旧列表版本覆盖；旧版本只进入已验证历史。原来源或工作授权变化时降为只读事实，移除成果与待决引用；删除／脱敏来源不返回标题及引用。游标不携带许可。组合 API 测试确认 GET 前后完整测试仓库一致，模型、worker、公开读取计数不增加。

原生 Features 只调用 typed service；服务不保存任务真值或执行授权，内存快照按账户／空间与生命周期隔离，迟到响应不能穿过失效代际。网络失败可以显示注明未更新的旧快照，不能恢复新许可；401／403 清除服务快照。实际账号退出再登录的完整 UI 路径本片未运行。

独立审查发现会话切换在异步读取完成前先切了队列及部分草稿。修复将目标普通／工作／成果草稿先读入局部变量，最后检查后无 await 一起更新呈现状态；取消时用精确 preference revision 做 CAS 回滚，不覆盖后来的选择。五项宿主测试覆盖查阅保 B、明确切换、冷恢复、缺本机历史、七个读阶段取消及新建会话兼容。

| 验证 | 最终结果与实际范围 |
|---|---|
| 后台 | 新组合 HTTP 15／15；原成果／审批 GET 回归16／16；实际9条 API 返回字节进入原生传输测试 |
| 原生单元／传输 | 同最终 App 38／38 PASS，3.356秒；包括错误账户／空间、版本 hash、分页、失权、迟到响应和原会话合并 |
| 默认原生 UI | 跨会话／冷启动／同版本 hash／原草稿52.112秒；既有双草稿与侧栏搜索29.247秒，均 PASS |
| 最大系统字号 UI | 实际 `UICTContentSizeCategoryAccessibilityXXXL`、无 QA 字号覆盖；服务端成果查阅、可点击且至少44pt返回按钮、具体缺本机历史提示及返回保稿，19.783秒 PASS |
| 构建／静态 | 最终 build-for-testing 与非 DEBUG SDK PASS；120宿主成员、1119双语条目、设计／排版负向检查通过 |
| 治理 | 布局、冻结来源、部署快照、AF／FINAL／GenUI合同等8项 PASS；提交前1195项扫描0 blocking／0 manual，沿用145个已复核例外，未新增例外 |

导航返回采用现有蓝色 action 文字、中性 panel 及共用按压反馈。没有修改字号来遮掩布局；默认／实际最大系统字号的原生截图均保留。最大字号允许内容滚动，不将所有正文塞进首屏。Root实际审阅成果、固定返回和完整失败说明；默认 B 草稿截图是在抽屉关闭转场中采集，不能用它证明静止对齐或转场帧率。

过程失败保留在忽略的 `build/native-inbox-20261015/` 及 `services/edge/build/inbox-20261015/`：

- 后台 RED 为无路由404；初轮普通旧任务 scope.owner 兼容失败、工具调用 ID 字符串合同及UTF-8标题边界均修复后形成最终15项，不把早期轮次计作通过。
- 首轮本地化状态 helper 未接 locale，SDK检查失败；新宿主测试后端遗漏 observe 导致构建失败，分别修正。
- 初轮原生36／37通过：迟到响应测试没有等实际 held read 开始；改为确定事件屏障，保留原断言。
- 前两轮 UI 在新建 B 前失败；实际 AX／截图确认 DEBUG 指标浮层覆盖右上按钮，改走真实侧栏新建路径。普通用户体验启动不显示该浮层。
- typed 返回错误重构遗留旧变量导致 build-r6 失败，已修正。
- r7 UI 已完成 B 查阅 A 和冷恢复草稿，但 XCTest 对超过128字符的直接 identifier 查询抛异常；改用精确 NSPredicate，保留完整成果 id／version／hash，未缩短产品身份。
- r7／r8截图的蓝底继承黑字被视觉审查拒绝；r9改回现有导航语义角色后重新固定 App 并完整复验。
- 最大字号 XCTest PASS 后，外层 shell 使用 zsh只读 status 变量而退出1；已单独恢复 QA 字号并核对，不把包装脚本失败改写成测试失败或重计通过。
- 本机后台接续检查最初使用不存在的元数据 key 而中断；原行和36配置保持，启动器曾再次打开36。改用实际 synthetic_viewer_window 并验证原仓库逐字节一致后继续更新37；没有新请求发送。

固定“Catpaw 最新体验”原 Simulator 已更新并启动37；同 store、同 subject／scope／route，原后台行复制后完全一致，原会话到期时间保留，未续期。安装完整包指纹读回相等；启动请求计数94→95，但 accepted_posts 0→0、memory_posts 0→0、provider_calls 4→4、turns 2→2。旧36包、source27、状态与回执备份保留；37前端与本机后台均对应95ac3fd。私人启动截图只存忽略的 local-audit，未发布截图像素或用户内容。专用 QA 服务已停止，用户体验服务保留。

仍未验：真实 Auth／模型／PG／手机、独立调度、A 在 B 或 App 离开期间新完成的完整路径、实际账号交替登录 UI、大历史 SQL 性能、浅深色／VO／Reduce Motion／全尺寸矩阵、远端完整会话 hydrate、持久未读／outbox／通知，以及全部 AF／FINAL 门。此 GET 需要同版维护 API；生产旧 API 未部署本片，不能把这个包直接当作已获批手机／生产候选。

后续按依赖继续 Trigger／due 物化与同工作变化跟进；图片许可统一呈现独立推进。新增真实 Auth／模型／SQL／生产部署／手机安装／依赖／费用均0，原r7模型授权不重试，FINAL-G3保持 ACTIVE。
