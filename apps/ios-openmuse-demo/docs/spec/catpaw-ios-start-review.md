# cat iOS 首链开工门槛审查

日期：2026 年 10 月 10 日。范围：产品实施稿 v0.5、iOS 工程实施规格及 Swift 参考接口。仅审查是否足以开始 M1，不要求所有后端、完整截图细节或后续语音能力先完成。

## 结论

可以开始 M1。规格已经足够支持 SwiftUI 工程、会话与消息真实本地保存、明确标注的 fixture 回复、取消、重启恢复这条首链。未发现需要等待原宿主源码、真实模型 provider 或全套语音条件才能编码的阻断。

iOS 17+、SwiftData、纯 Swift 领域层与专用 repository actor 是一致的默认；UI 与 SwiftData 记录不跨 actor 混用，CloudKit 关闭，用户分区与演示分区分开，真实外部写入关闭。原生朗读不要求麦克风；ASR 先探测 on-device 能力，用户明确启动才请求权限，不可用时回文字或标注模拟。

Swift 文件当前是未 typecheck 的接口草案。本环境没有 Swift 编译器，不能报告代码已编译或 iOS 已运行。实现者应在创建工程时立即用实际 Xcode/SDK 校准接口与 actor 隔离，这属于 M1 的首个验证动作，不是延迟开工的理由。

## 首链需要同时落实的两项修订

1. Provider 流必须有明确成功终态。不能把 AsyncThrowingStream 自然结束、网络 EOF 或取消都映射为 completed。固定成功终止事件后才完成消息/任务；无成功终态的截断保留已有文本并显示未完成。fixture 与未来真实 provider 使用同一协议，终止事件也不能把 simulated 提升为 remoteVerified。
2. 保存失败必须清除本次未提交的 context 修改。repository 使用关闭 autosave 的专用 context；失败后 rollback 或重建 context，不发 LocalCommit，不递增成功 changeSequence。未保存的用户草稿在 FeatureModel 独立保留，防止失败插入被后续保存顺带写入。

这两项已由技术作者写入并重读确认，可随工程骨架、模型和页面实施。Apple 明确说明 context 变更在保存前只存在内存、rollback 可丢弃未提交变更；mainContext 默认开启 autosave，因此不能只靠“调用过显式 save”守住失败边界。[ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)、[autosaveEnabled](https://developer.apple.com/documentation/swiftdata/modelcontext/autosaveenabled)、[rollback](https://developer.apple.com/documentation/swiftdata/modelcontext/rollback%28%29)

## M1 最小通过证据

- 真实 Xcode 工程及共享 scheme 构建成功，实际模拟器启动；不以 HTML 或源码文件存在替代。
- 建立会话、保存用户消息与草稿，关闭后重开 disk-backed store，内容和顺序一致。
- fixture 回复全程显示模拟；明确完成、失败、取消、迟到事件和意外 EOF 可分别复现。
- 双击提交仍是一个 clientMessageID；失败保存后再进行另一项成功保存，失败记录不能意外落盘。
- 重置演示数据不删用户分区；切分区后旧订阅、路由及语音不串入新分区。
- 启动、打开语音页、朗读均不自动请求麦克风或识别权限；未配置真实 provider 时没有隐式网络调用。

完整迁移样本、所有模块截图、真实 on-device ASR、音色质量、真实模型与云调度按后续工作包验收，不应卡住上述首链。应并行建立真实 provider 接入清单，不能以 fixture 完成代替最终 Agent。

## 小项说明

原生 TTS 的 failed 事件应来自适配器的预检、明确本机错误或有界超时检测；AVSpeechSynthesizerDelegate 的开始、结束、暂停和取消回调不能虚构为一个通用 didFail 回调，也不能证明用户实际听到了声音。该纠偏不影响 M1，随 WP6 落实即可。

## 修订复核

2026 年 10 月 10 日 17:41 UTC 已重读确认：实施计划第 4.3 节加入 autosave 关闭、失败 rollback/reset、无伪 LocalCommit 及重启幂等核对；第 6.2 节与 Swift enum 加入 messageCompleted、taskCompleted、无终态 EOF 处理与单一终态规则；第 9.1 节纠正 TTS failed 来源；IOS03/IOS08 测试用例同步。

全部开工审查发现已在规格层收口。未执行 Swift typecheck、xcodebuild、模拟器或持久化运行测试。下一步是实际 M1 编码和首链验证，不需要继续等待文档打包或后续 M3 接口全部实现。
