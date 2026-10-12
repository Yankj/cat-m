# Catpaw iOS 对话 P0 独立 QA 小批

2026-10-12。产品继续 **FAIL / 不放行**：用户当前手机 build13 的真实失败保留。本报告只复验冻结待集成状态补丁；没有更改生产源码、冻结包、canonical index 或其他 owner worktree，没有真实 Auth/模型、手机安装、部署、推送。

## 冻结输入与隔离边界

分支 `test/ios-dialogue-p0`，唯一隔离 worktree `qa-dialogue`，基于 `b7fa4ee5f8d144208d51f6d0dcdee9259c4315b7`。两个 zip 的 SHA、大小与条目数匹配交接清单：build13 `018395c1…68764d`，pending `8ca70538…0af40`。完整值在 [INPUT-VERIFICATION.json](INPUT-VERIFICATION.json)。包内 build13 的 132 个原安装清单文件、140 个完整快照文件，以及 pending 的 144 个文件均通过 SHA 校验。build13 资源历史来源限制沿用交接说明，不推断原签名二进制可重建。

冻结源包只读，解包快照放在忽略的 `build/build13`、`build/pending`。模拟器使用第三份 `build/native` 和独立 QA bundle：只有 App 入口替换为 [QAHost.swift](QAHost.swift)，直接注入离线 backend，不创建生产 Auth/ApplicationModel、HTTP composition 或 Keychain。生产 View/model/service/Repository/SwiftData 源码哈希保持冻结身份；最终再次核验快照与输入 zip 未变。

## 实际结果

| 运行 | PASS | FAIL | SKIP | 层级 |
|---|---:|---:|---:|---|
| build13 独立 consent 红阶段 | 0 | 1（预期） | 0 | macOS Swift / FilePersistence / 合成 backend |
| build13 原 QA 8 场景 | 7 | 1（原失败复现） | 0 | 同上 |
| pending 独立场景 | 7 | 0 | 0 | 同上 |
| pending 原 QA 8 场景 | 8 | 0 | 0 | 同上 |
| pending 最终原生 XCTest | 9 | 0 | 0 | iPhone 17 Simulator / iOS 27.0；Xcode 与 SDK 27.1 |
| pending 慢许可反馈 XCUITest | 1 | 0 | 0 | 冻结生产 View + 合成离线宿主 |

原生 9 个 XCTest 中，一个运行旧 8 行为场景，不能再把这 8 场景计为额外 XCTest。初次 8 个单测及新增竞争单测的中间运行保留在 `build/native-unit.xcresult`、`build/native-race.xcresult`；表内只计最终 9 项，证据为 `build/native-final.xcresult`。UI 为 `build/native-ui.xcresult`，附实际合成 Simulator 截图。摘要见 [PORTABLE-RESULTS.json](PORTABLE-RESULTS.json)、[NATIVE-RESULTS.json](NATIVE-RESULTS.json)、[原生结果摘录](native-test-results.txt)。

## consent 红绿与本批断言

同一“许可挂起时必须有稳定本地等待反馈”的行为要求，采用两版本各自公开状态 API 的适配，不读取 private 标志或反射。build13 用既有 busy/enqueueing/sending/consent/error；pending 用公开 checking 与不可变 outgoing intent。新增测试保持许可 continuation 挂起，20 次按 100ms 间隔取样，共 2 秒：同步捕获 savingLocal，之后保持同 ID/原文的 queued/awaitingPermission、checking，且没有 backend dispatch/turn。build13 FAIL，pending PASS。这里的取样间隔和 model 同步状态 **都不是呈现帧延迟测量**。

红阶段定位：build13 `Sources/App/ConversationFirstModel.swift:20,76–84` 的 checking 为私有标志，先 await modelConsent 后才进入发送/排队。pending 的同文件 `:110–145` 先发布 savingLocal，再持久化队列/剩余草稿，公开 checking；这是冻结补丁提供的绿阶段实现，QA 未写生产修复。

其余独立断言：12 次重复 Send 只消费一次草稿；重新输入的相同正文保留独立 ID 与 FIFO；迟输入的草稿不被清除；12 次重复 read 不产生并行观察；unknown/已终态同 operation 不重发；恢复原请求不等待 readiness；取消旧观察的迟到回调不能清除/完成前台新观察；用户暂停不被后台暂停或自动恢复覆盖；SwiftData 重开保留精确草稿与队列；注入 SwiftData save 失败回滚同一事务、无 provider 请求；model 标记 composing 时拒绝发送并保留中文/换行/emoji，composition 提交后保留原文。

UI 小批实际检查 `chat.preparing` 和原 queued 文本在 Send 后出现，2 秒后仍存在，没有助理正文。它不使用旧 UI 测试中的未接通 probe，不把 XCTest.tap 返回耗时或 screenshot 当首帧指标。

## 仍未关闭的接线与设备门槛

| 范围 | 结论 / 定位 |
|---|---|
| 原生实际 IME / CmdReturn | **NOT_RUN；接线待完成**。冻结 View `Sources/Features/ConversationFirstView.swift:124–127` 是 SwiftUI TextField，未调用 updateInputComposition，也没有实际 markedTextRange 桥接。model guard PASS 不证明原生组合输入安全 |
| scene 接线 | **接线待完成**。View `:75` 仍把所有非 active（包括 inactive）送到 suspend，没有使用同步 sceneChanged 桥；本批直接调用 model 场景通过不覆盖该生产桥 |
| savingLocal 首帧 / 本地回显 | **NOT_RUN**。View 使用 followups.pending 和 checking 文本，未消费 outgoingMessages 的 savingLocal。真实 touch→已呈现帧 ≤100ms、主线程/滚动锚点均无测量，不能由模型发布时间抵扣 |
| preparing 时接受后续发送 | View `:96` 因 checking 禁用 Send；model 能继续接受新 draft 的通过不能直接推广到 UI。待 UX owner 按已确认接口适配 |
| 真机 home 5s/30s、杀 App、真实弱网/网络切换 | **NOT_RUN**。旧 5/30 场景仅逻辑 detach；本批没有真实 scene 时长/手机/网络操作 |
| 原 QA 全套 P0 UI probe | **NOT_RUN**。未接具名 fixture、qa.p0Probe、实际呈现帧。此次新增单个离线宿主 UI 检查不替代旧整套 P0 E2E |

下一步由集成/UX owner 适配 local echo、sceneChanged 与实际 IME 桥，保留这批测试，再安排具名安全 fixture 的 UI/帧测量。达到手机与真实网络门槛前不声称产品可用，不装新版手机，不扩展天气/图片/部署范围。

## 复现与证据

使用现有 Xcode；不安装依赖，不改全局 xcode-select。`FROZEN_HANDOFF` 与 `LEGACY_QA` 指向用户交接的两个只读目录；`DEVELOPER_DIR` 指向现有 Xcode。首次执行输出目录须为空；prepare 拒绝覆盖已存在快照。

```sh
python3 qa/ios-dialogue-p0/prepare.py --artifacts "$FROZEN_HANDOFF" --legacy-qa "$LEGACY_QA"
python3 qa/ios-dialogue-p0/run-portable.py
xcodebuild -project qa/ios-dialogue-p0/build/native/CatpawM.xcodeproj -scheme CatpawM -sdk iphonesimulator -destination "$QA_SIMULATOR_DESTINATION" -derivedDataPath qa/ios-dialogue-p0/build/DerivedData -resultBundlePath qa/ios-dialogue-p0/build/native-final.xcresult -parallel-testing-enabled NO -only-testing:CatpawMTests/QAIndependentTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= test
xcodebuild -project qa/ios-dialogue-p0/build/native/CatpawM.xcodeproj -scheme CatpawM -sdk iphonesimulator -destination "$QA_SIMULATOR_DESTINATION" -derivedDataPath qa/ios-dialogue-p0/build/DerivedData -resultBundlePath qa/ios-dialogue-p0/build/native-ui.xcresult -parallel-testing-enabled NO -only-testing:CatpawMUITests/QAFeedbackUITests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= test
python3 qa/ios-dialogue-p0/collect-results.py --artifacts "$FROZEN_HANDOFF"
```

原始构建日志和 xcresult 只留在忽略的 build；提交的摘要不含机器绝对路径、Simulator ID、真实对话或身份。测试/摘要哈希在 [QA-SHA256.json](QA-SHA256.json)。仓库冻结资产 integrity、敏感性扫描、diff 检查在提交前重新执行。
