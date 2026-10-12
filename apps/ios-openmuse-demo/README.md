# OpenMuse 原生合成 Demo r3

这是正式冻结的 r3 客户端快照，43 份 App Swift 源码，来自已交付 v1 的独立副本。已交付基线继续保留在 [apps/ios](../ios/README.md)。本客户端 bundle 为 `com.example.CatpawM.OpenMuseDemo`，本机数据根 `CatpawM-OpenMuseDemo`，禁用云同步；不是已接通真实 Agent 的产品版本。

打开 `CatpawM.xcodeproj`，选择共享 `CatpawM` scheme。设置中主动开启演示数据分区、选择本机，进入“OpenMuse · 合成 Demo”。默认具名 Fixture；切换到本机 façade 后，主动检查能力/提交。恢复不自动联网，unknown 只读原回执，不再次发送。

## 合同与本机 façade

客户端只接受 `http://127.0.0.1:8796`，公开合成鉴权 `Bearer synthetic-only`。r2 façade 位于本仓库 [services/facade](../../services/facade/README.md)，固定合同 [native-contract-v1.json](docs/openmuse-facade-v1/native-contract-v1.json) 的 SHA256 为 `08b79075636a8c70b90df82a6d02e6ffee2a0f36e138e88a56eb50576bd1f7a9`，与服务合同字节一致。

需要联调时，使用已有 Node22.17.1+，从仓库根显式启动单个合成服务：

```sh
cd services/facade
node --experimental-transform-types src/server.mjs 8796
```

仅监听loopback，Ctrl-C停止；只允许单个写实例。此命令不是完整OpenMuse/Intelligence启动，不读取key或`.env`。本轮仓库整合没有启动服务或Simulator。

## 可复现检查

在本客户端目录，使用已有Mac工具：

```sh
zsh Scripts/check-source.sh
zsh Scripts/test-openmuse-portable.sh
zsh Scripts/test-openmuse-snapshot.sh
zsh Scripts/build-openmuse-http-runner.sh
```

`test-openmuse-portable.sh`与`test-openmuse-snapshot.sh`分别执行15项fixture和5项合成HTTP响应重放，无真实网络或Worker。`check-source.sh`的macOS条件typecheck/iOS parse不代表iOS SDK编译。若遇默认Command Line Tools链接器断言，用本次进程 `DEVELOPER_DIR=<已有Xcode的Contents/Developer>` 执行；不更改全局xcode-select。

可选四客户端/四服务HTTP恢复回归需允许loopback监听，显式执行：

```sh
node Scripts/test-openmuse-http.mjs . ../../services/facade
```

脚本使用已有Node22、8796端口及自身 `.build/openmuse-http/run-*` 隔离数据；该端口应为空闲，结束停止自身服务，结果写其run目录的 `summary.json`。不接管既有服务。该HTTP命令本轮整合没有重跑，终态结果来自已核对的客户端任务。

结构与语义见 [适配器说明](docs/openmuse-native-adapter.md)。最终来源 [provenance](../../docs/status/openmuse-r3-provenance.json)、[分层验收](../../docs/acceptance/openmuse-r3.md) 与 [精选图](../../docs/design/openmuse-r3.md) 保留。最终源码原任务已重新iOS编译、实际HTTP链路及2条原生UI通过；本轮只重验复制、fixture/重放与静态工程资源，不把继承v1的全部原生/语音/视觉测试算作r3通过。

真实服务协议、账号/key、模型、Intelligence、SQL双连接/多实例、云worker/推送、iOS17运行时/真机及中文深色以外的完整视觉/无障碍仍未验。Library上传未成功，无新Library文件身份；本轮不补传或绕过该失败。
