# 图片输入独立组件小批验收

2026-10-12，`feat/ios-image-composer`，来源HEAD `a1fd7e83603be8e3552e0d8ded5568377180db9a`。仅新增 [CatpawImageComposer](../../packages/ios-image-composer/README.md)、测试/验收与索引，不修改ConversationFirstView、主Model、network client、生命周期或签名。文档归档commit a1fd7e8与本组件commit分开。

| 实际运行层 | 终态 | 证明范围 |
|---|---|---|
| macOS SwiftPM | 16/16 PASS | 9 codec＋7状态/发送门槛：最终hash/base64/ID、PNG结构、JPEG/PNG EXIF/GPS与方向6、尺寸/字节缩小、动画/坏文件/原图上限、默认关闭、独立许可/文字、取消/范围清理/迟到覆盖/失败保留与同ID本地重试 |
| iOS SDK完整library | PASS | 含PhotosPicker的全部源码编译/链接，iOS17 target，Xcode/SDK27.1；最终组件无编译警告 |
| 专用iOS27.0 Simulator spawn | PASS | 无App安装的合成JPEG/PNG codec：方向、去元数据、尺寸/字节；没有选择或读取相册 |
| 8ce77b4 v2纯validator | 2/2 PASS | Simulator生成真实合成PNG/JPEG字节、标准base64和SHA256，服务端容器/像素校验通过；不启动API/provider或PG |

精确源码SHA、忽略日志SHA及边界见 [RESULT.json](evidence/ios-image-composer/RESULT.json)。v2源模块SHA为 `932dda958e8d1936173e4b3df4eaff8b8c5bc0d7f2fde685875d8e62a9c0cd58`。初始联调用了owner当前文件，最终核对发现已有后续修改，故改为Git8ce固定快照并重跑；不能把可变owner文件标作8ce通过。初始PhotosPicker label actor警告也已修正后复编。

## 给原生owner的固定接口

`ImageAttachmentDraft` 持有loading/encoding/ready/failed和单图内存态；`ImageAttachmentPicker`负责系统选图、缩略图/移除和具体错误/重试。`PreparedImageAttachment`输出不可变id/mimeType/sha256/encodedData/width/height/thumbnailData；`wire(messageID:)`仅产生v2附件四字段。默认PNG，JPEG支持8-bit baseline；PNG仅IHDR/IDAT/IEND，JPEG剥离APP/COM，均由新像素重绘/编码后解码确认。

`sendBlock(caption:messageID:gate:)`默认unavailable。所读8ce路线available=false；文字许可不授权图片，宿主须核对真实能力/route/hash/revision及当前scope独立图片同意，不能硬编码gate=true。单图必须非空文字，必须保留现有v1文字请求。失败/取消可重试本地读取/编码，原safe预览保留但当前图片禁止发送；不得静默丢图转文字。unknown属于宿主原turn核验，组件不重发、不持久化图片blob。

原生工程/Scheme尚未链接此package；本组件未宿主接线。PhotosPicker真实交互/iCloud、VoiceOver/最大字号/预览截图、触觉/反馈延迟、实机HEIC/RAW及颜色、DTO/独立同意/发送/unknown恢复、真实图片模型和MM04均NOT RUN。没有私人相册访问、真实服务/模型、付费服务、装机或部署，不能抵扣R1产品FAIL。后端生产图像结构校验的限制仍按v2文档保留，codec联调不是安全审计。
