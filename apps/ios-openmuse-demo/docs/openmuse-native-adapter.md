# 原生 OpenMuse 合成 Demo 适配器

本目录是完整 v1 的独立副本。原工程、原 v1 Library 身份和原交付 ZIP 保留。当前 App 的 bundle 为 `com.example.CatpawM.OpenMuseDemo`，本机数据根为 `Application Support/CatpawM-OpenMuseDemo`。没有更改 signing team、全局 xcode-select、系统权限或外部仓库。

## 组合入口

设置 → 开发联调 → OpenMuse 合成 Demo，仅允许明确选择的 `Profiles.demo` 本机分区。默认具名 Fixture 使用独立磁盘权威文件；用户主动切换到 127.0.0.1:8796 并检查合同能力后才允许 HTTP 提交。启动、切换来源、恢复导航均不自动联网。Demo 明确保存已选数据分区以便 App 重启后恢复原记录。

新增三个状态页面沿用现有 SwiftUI 设计系统：恢复与进度、冻结审批预览、成果与来源。审批按钮绑定同一正文、version、content hash、destination、arguments hash、grant epoch 和 action digest。accepted/unknown 只提供原回执 GET 与显式本机效果检查，不提供重新发送。

## 契约与身份

冻结文件为 `docs/openmuse-facade-v1/native-contract-v1.json`，SHA256 `08b79075636a8c70b90df82a6d02e6ffee2a0f36e138e88a56eb50576bd1f7a9`。`/catpaw/v1` 是新增 facade API，不是 OpenMuse 原生端点。固定上游 commit 为 `1ac68f3909f2478ab6280883f1ab5ea65eb5719d`；r2 Worker 有捕获 lease 的受控补丁，不能称作未修改的上游。

| 身份 | 用途 |
|---|---|
| operation ID | 本机先保存，再用于一次接纳；断连读原 operation |
| business Run ID | 本机冻结的业务 Run，独立于 operation/delegation/Task |
| server Task ID | 服务返回并校验，原任务权威读回 |
| worker attempt / upstream run | 服务 lease 尝试历史，允许已校验的后继尝试 |
| AG-UI run | 临时流观察；RUN_FINISHED 不完成业务 Task |
| local / server request hash | 分别冻结本机输入与服务完整输入，互不冒用 |

HTTP 原生 Demo 的本地 `Profiles.demo` 显式映射到合同公布的服务合成 principal。`Bearer synthetic-only` 是公开合成身份，不能用于真实账号或部署。HTTP 配置只接受无账号、无 query/fragment、显式端口的 `http://127.0.0.1`。没有 Intelligence、模型或云端可用性升级路径。

## 持久化与恢复

`OpenMuseTaskService` 通过已有 Repository 的原子提交与 revision CAS 保存完整 session。接纳/审批的 dispatch 标记先于任何写请求；保存失败丢弃 candidate，不发成功事件。unknown、404 或 EOF 均不能触发再次创建或审批。独立原始记录、审批 journal、已检查的成果历史均保留。

`recover` 只处理本机 observation epoch 和中断 dispatch，不调用 HTTP。后续用户点击读原任务：GET delegation → GET original operation/Run → GET 指定成果版本与审批 → 再 GET Run，校验最终引用未变。服务合同没有 snapshot revision，因此客户端不捏造版本号，也不声称这些 GET 是一个服务端事务快照。

如果 Worker 在读回中发布了新引用，抛出单独的 `OpenMuseSnapshotReadChanged`，本轮结果不发布。`refreshUntilStable` 最多重新读三次；耗尽后抛出明确可恢复错误、结束 UI busy、保留 last checked projection 和 needsRead。hash、scope、grant/epoch、不可变版本或已完成历史不匹配不进入该重试分支。每个 HTTP request 有 30 秒超时；后台不承诺手机常驻执行。

暂停/撤权先保存本机栅栏，再调用服务 control。迟到结果不能越过 epoch。服务控制未确认时保留本机栅栏和原记录，不冒称服务撤权成功；当前 UI 要求人工诊断该状态。撤权不可静默恢复。resume 确认后旧 Run 保持暂停，只能准备独立 operation/business Run 的新草稿，再显式提交；不会重发旧 Run。

## 临时流与旧 Provider 桥接

`OpenMuseAgentProvider` 只桥接接纳、状态和停止观察。接纳流 EOF 不是 task/message 完成，停止观察返回 outcomeUnknown，不声称业务已取消。不可用的 AG-UI chat wire 明确报错，没有猜测 chat HTTP 端点或伪造 result DocumentReference。新 rich projection 使用独立 service，没有替换原 ChatRuntime、Gateway、OperationReducer 或语音实现。

## 可复现路径

```sh
zsh Scripts/test-openmuse-portable.sh
zsh Scripts/test-openmuse-snapshot.sh
zsh Scripts/build-openmuse-http-runner.sh
```

HTTP 四进程脚本需要另外交付的 r2 facade 目录和既有 Node22；不会安装依赖、读取 .env 或启动完整 OpenMuse：

```sh
node Scripts/test-openmuse-http.mjs . ../../services/facade
```

原生 UI 测试应选择已确认空闲的设备，独立 bundle，不并行占用用户/设计设备。最终原生/HTTP结果与未验边界见仓库 `docs/acceptance/openmuse-r3.md`；设备身份和个人路径只保留在仓库外本地审计。完整上游、真实协议同意/账号/key/Intelligence/模型、SQL多实例和真机/iOS17运行均不由本 Demo 验证。
