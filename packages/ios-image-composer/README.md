# CatpawImageComposer：单图本地输入组件

独立SwiftPM package，最低iOS17 / macOS14。iOS提供PhotosPicker，macOS仅用于合成codec/状态测试。基于后端 `vision-chat-contract-v2.md` 的已提交来源 **8ce77b450f51c93faf5e1fee100d7c0968086b98**；本package不包含该后端提交、网络client或宿主接线。

## 固定接口

| API | 用途 |
|---|---|
| `ImageAttachmentDraft` | @MainActor内存态：empty → loading → encoding → ready / failed；beginSelection返回ticket，receiveSelectedData/selectionFailed按ticket回写 |
| `cancelProcessing()` / `clear()` | 取消并拒绝迟到发布；clear用于移除/身份、范围、会话切换。编码或读取失败保留旧安全预览；已读取原图在失败/取消后可重新处理 |
| `retryEncoding()` / `canRetry` | 只重试本地编码，保留同一selection/附件ID，不发网络请求。读取失败由picker保留已选item供显式重新读取 |
| `PreparedImageAttachment` | 不可变id、mimeType、sha256、encodedData、width/height和≤192px缩略图；编码器创建，默认debug/description隐藏像素字节 |
| `wire(messageID:)` | v2附件四字段：id、mime_type、sha256、标准带padding base64。ID必须独立于messageID；hash对最终编码字节计算 |
| `sendBlock(caption:messageID:gate:)` | nil仅表示本地状态/门槛允许；默认unavailable。处理/失败/缺文字/许可/错误身份都阻止图片发送，不能静默丢图转文字 |
| `ImageAttachmentPicker(draft:gate:)` | 单图选择、更换、缩略图、移除、处理/取消、inline错误与显式重试；44pt控件、系统动态字体、Reduce Motion静态处理提示 |

PNG默认；也支持JPEG。异步Task.detached进行ImageIO缩图、方向变换及sRGB 8-bit重绘；不转发原照片容器。PNG只保留IHDR/IDAT/IEND，非交错RGB/RGBA；JPEG重新编码为baseline并移除所有APP/COM元数据，随后独立解码确认尺寸。JPEG透明像素铺白，PNG保留alpha；不裁剪图片。输出最长边≤2048，像素≤4,194,304，编码≤5,242,880 bytes；超过字节上限会继续等比缩小，仍失败则保留状态。输入安全门槛为≤50MiB、每边≤16,384、≤100M像素，拒绝动画/多帧及不可解码输入。这些是本地实现约束，不代表图像安全审计或全部HEIC/RAW/实机保真验证完成。

## 原生owner接入位置

将本地package加入活跃工程；组件只负责图片状态，现有ConversationFirstView、主Model、文本/IME、生命周期和网络由原生owner维护。本批没有修改它们。

```swift
@StateObject private var imageDraft = ImageAttachmentDraft() // 默认PNG
// 在既有composer旁放置，不创建第二个文本输入/发送状态机：
ImageAttachmentPicker(draft: imageDraft, gate: authoritativeImageGate)
    .id(currentConversationScopeIdentity)
```

- 纯选图只读取用户选定的一张图片，不请求全照片权限，不调用PHPhotoLibrary授权API，不上传。读取/编码/失败均只在内存；不保存原照片、EXIF、Data/base64到SwiftData、UserDefaults、日志或业务history。
- 宿主的 `ImageSendGate` 必须来自当前权威能力/路线/同意：readyz `image_input.available` 与真实路线 `live_transmission_available` 均true，文字许可单独有效，图片许可精确匹配当前subject/scope/conversation/route_hash/revision。不能用字段存在、mock_only、flag或硬编码true开放外发。**所读8ce契约available=false，组件默认sendBlock=.unavailable；宿主依据后续正式上线的权威能力判断，不从此组件推定生产图片已可用。**
- 单图需非空问题文字。图片ready后，宿主按现有发送操作原子冻结caption/messageID/turnID/route及附件，再调用wire并组成根schema_version=2、message.attachments=[wire]；整个JSON≤7,100,000 bytes和完整文本/上下文规则仍由宿主及服务器检查。文本v1路径保持原样；存在未准备/不可用附件时明确阻止，不静默删除附件发送文字。
- 清理/切换范围调用clear并按scope/conversation重建picker身份，释放已选item引用。正在读取/编码时发送被阻止；失败/取消可显式本地重试或移除，旧安全预览标明“未替换”，不能作为新图片偷偷发送。取消只能协作停止编码并用ticket拒绝迟到结果，不承诺C codec即时中断或取证级内存擦除。
- 开始真实发送后，unknown/timeout按宿主原turn GET核验，不重新选图编码再POST。此组件没有网络重试、队列提交、图片许可申请或云历史；本地重试是准入前编码动作。服务器receipt是持久受理证明，不能等同模型收到或答复正确。

## 合成复验与未验项

```sh
swift test --package-path packages/ios-image-composer --scratch-path packages/ios-image-composer/.build-verification
packages/ios-image-composer/Scripts/verify-ios-sdk.sh
# 可选：已有专用arm64模拟器，无App安装、无相册访问：
CATPAW_IMAGE_TEST_DEVICE=<专用模拟器标识> packages/ios-image-composer/Scripts/verify-ios-sdk.sh
# 对已提交v2纯validator检查模拟器生成的合成wire，不启动服务：
CATPAW_IMAGE_NODE_BIN=<已有Node路径> packages/ios-image-composer/Scripts/verify-v2-interop.sh
```

iOS SDK完整library编译/链接含PhotosPicker；simctl spawn只运行合成JPEG/PNG codec。PhotosPicker实际选图/iCloud读取、预览/移除VoiceOver、动态大字、真实触觉/帧延迟、实机HEIC/RAW与颜色保真、宿主DTO/同意/发送/unknown恢复、生产视觉模型和设备MM04均未验。没有读取私人相册、真实模型、装机或部署。逐项结果见 [组件验收](../../docs/acceptance/ios-image-composer.md)。

官方API入口：[Photos picker](https://developer.apple.com/documentation/photokit/bringing-photos-picker-to-your-swiftui-app)、[ImageIO thumbnail transform](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))。SDK类型以本机已安装Xcode编译终态为准。
