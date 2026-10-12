# 原生侧栏与本地图片宿主阶段验收

2026-10-12，release_id `catpaw-ios-host-20261012-checkpoint1`。这是独立集成分支的阶段候选；R1 发布仍未放行，没有覆盖手机 build14。

## 已接入行为

主宿主通过本地 Swift Package 连接 SidebarHost 与 ImageAttachmentPicker。根页汉堡/左边缘打开、面板左滑/遮罩关闭；详情保留 NavigationStack 系统返回。历史列表与搜索只读取当前 scope 的实际记录。任务/成果页读取当前对话已有投影，空时说明没有记录；记忆保持禁用。导航期间保留原对话草稿，选择同一对话不清除图片。

系统 PhotosPicker 只读用户选中的一项。本轮仅选择新造蓝色圆形测试图；Simulator 的六张系统预置照片没有被选择。编码在本机完成，预览、取消和移除不发请求、不丢文字。图片能力只读接口有明确默认关闭值；v15 实际 `image_input=false`。客户端单独图片许可和 v2 transport/receipt 尚未接通，发送门禁保持关闭，不会静默发送纯文本。

保留输入法 marked text、CmdReturn/Return、稳定 outgoing ID、队列/unknown 只读恢复与撤销 epoch 边界。流式 TextKit 性能改动从原 owner 提交导入。修复真实手势未到达 background UIView 的问题：recognizer 附着当前 window，但按活跃 anchor 范围、根页、编辑/横向控件与 UIKit modal 限制；系统详情返回不受干扰。大字号文本继续缩放，侧栏图标宽度按字号分配；工具栏图标保持标准控制尺寸。

## 分层结果

实际结果与逐文件身份在 [RESULT.json](evidence/ios-host-integration-20261012/RESULT.json)。非 DEBUG DeviceTrial iOS Simulator 构建与 iOS SDK typecheck 通过；这是无签名模拟器产物，不是手机 build13 或新安装。31 项原生断言通过（历史 Keychain entitlement 用例仍未执行）；侧栏/图片独立包分别 12/16 项通过；对话/队列可移植回归分别 7/9 项通过。最终宿主 UI 8 项全部通过；另对最新 DEBUG 诊断隐藏改动重跑受影响的 4 项侧栏用例并通过，补验关闭按钮。中间失败保留。

源检查中的语法、66 个 App 文件成员、3 个 target/scheme、两个本地模块 typecheck 通过；现有产品本地化门槛仍 FAIL，97 条命中，没有扩大豁免。敏感扫描的两个原有 mock public 字符串只更新了文件 SHA 与行号。

## 保留的失败与复验

初次 Debug App 编译双架构、Swift Package 只编译活动架构，x86_64 链接失败。项目 Debug 改为标准 ONLY_ACTIVE_ARCH=YES；非 DEBUG 构建保留原配置并实际重验。

第一轮 UI 4 项中 3 项失败：PhotosPicker 使用了错误 cell 查询、边缘 recognizer 未接收真实触摸、最大字号 DEBUG 诊断覆盖汉堡。系统实际元素是图片，且专用 Simulator 含六张 Apple 预置图。查询明确只选本轮新造图；手势改为受限 window anchor；仅具名 fixture 的诊断字号固定，产品字体不封顶。第二轮选图/手势通过；最后最大字号测试曾因未限定实际侧栏容器与过早查询导航条失败，修正后实际设置页面出现并可返回。相关中间 xcresult 和日志仍在忽略目录保留。

## 当前未通过的发布门槛

- 真实视觉：独立图片许可、严格 v2 附件冻结与 route/revision、admission receipt 校验、未知结果只读核验、失败保留原图/字节；协调刚提供固定 Gemma/Google 视觉源码候选，当前尚未部署或真实验证；本检查点先冻结本地输入。当前图片仅本机，不能称视觉 Agent 已交付。
- 真实服务会话 terminal/cursor、真正冷启动、真实 PG 竞态、真实模型回归未在本批执行。另一个 QA 的 v15 四项无模型冒烟已读，部署身份沿用协调回执；本机源码仍是固定目录已有 backend P0 基线。
- 真机 touch→已呈现帧、真实中文 IME、VoiceOver/Reduce Motion、弱网、Home30s 和冷重启未验。本批 Home5s 是实际 Simulator 操作＋进程内合成 backend，不证明云 worker 后台推进。
- 流中主动向上阅读的锚点保护仍未完成；现有自动追底可能抢阅读位置。帧/geometry 回调不是 GPU 呈现证明，性能产品阈值仍不能判 PASS。
- 两个历史副本与冻结规格/A1 资源保持原字节；签名、账号、权限、凭据与旧任务均未修改。没有模型请求、新安装、推送或部署。

后续真实发布按协调的六组清单冻结同一最终源码/部署/二进制身份后执行。原始运行目录均被 Git 忽略，不上传 Simulator 诊断或凭据。
