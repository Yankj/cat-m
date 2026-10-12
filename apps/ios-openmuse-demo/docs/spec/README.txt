Catpaw-m iOS实施规格包

基线：2026年10月10日，产品v0.5，iOS实施规格v0.1，技术v1.2。
用途：在用户Mac上的新原生iOS项目中继续实现，不以HTML原型或可点击外壳作为最终交付。

下载与解压
从Library下载本ZIP，解压全部文件到新项目根目录的 docs/spec。ZIP内文件直接位于根层；例如将此ZIP解压目标设为 <新项目>/docs/spec，避免多套嵌套目录。不要覆盖用户原有项目内容，若目标有同名文件先比较。

阅读顺序
1. catpaw-product-spec.md v0.5：完整现有功能复刻、新增长期个人助理、语音读写。重点读第21章B0与第22章iOS实施、25页面和M0–M6。
2. catpaw-ios-implementation-plan.md v0.1：先做本机Xcode/SDK/模拟器只读核验和31图证据矩阵，再按里程碑实现独立SwiftUI工程。默认iOS17+须用实际环境校准。
3. catpaw-ios-contracts.swift 与 catpaw-ios-agent-contracts.swift：需一同使用的基础与助理领域契约参考；本包打包时未typecheck，不能称可编译。实现者须按目标Swift/Xcode检查、调整并运行测试；即使typecheck通过，也不等于iOS构建、运行或后端接入已验证。
4. catpaw-technical-spec.md v1.2：核心架构、独立基础复刻、语音技术与安全边界。
5. 核心和语音JSON Schema及examples：拟议结构契约与合成示例；hash为格式占位。Schema通过不能替代授权、状态机、持久化及实际效果验证。

当前交付方向
先plan/spec，再持续编码至可运行iOS App。B0本地会话、文档、项目、专家/技能配置、任务记录、定时规则和权限偏好等应是真实本地功能；FixtureProvider的模型回复、进度和外部结果必须标记模拟。D0是交互参考，不是终点；D1原宿主接入是可选路径，不阻塞独立新工程。后续R1真实Agent与持久后台另按能力验收。

边界
原音与私人TTS数据的处理路线必须明确；麦克风权限不等于云上传许可。设备TTS、真实ASR、自托管模型分别验收，不把免费模型许可当免费算力。部署、账号连接、额外安装与云传输不可由本规格自动推导许可。

31图与状态证据
本包不包含用户截图或新造证据矩阵；从本机已有授权材料建立矩阵，区分confirmed、inferred、unverified。不得把未见的功能当成原宿主事实。

校验
SHA256.json记录本包各源文件的摘要，便于确认下载未变及后续定位设计基线。

本次开工修订
新增 catpaw-ios-agent-contracts.swift 和 catpaw-ios-start-review.md，同时更新实施计划及基础 Swift 契约。M1 可以开工，不等待原宿主源码或真实远程provider。
- Provider 流只有明确成功终态才能标完成；EOF、取消或截断不能假报成功，fixture不因此变成真实结果。
- 专用存储context关闭autosave；保存失败rollback或重建，不发LocalCommit或递增成功changeSequence；未保存用户草稿独立保留。
- TTS播放事件与实际音频回调对齐；检查实施计划和首链审查中的事件修订，不用接口返回当用户已经听到。
- 两份Swift文件打包时仍未typecheck；在Mac用实际Swift/Xcode/SDK校准后再报告可编译和可运行。
