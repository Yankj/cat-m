# 诊断交接快照 · 2026-10-15

本分支：`diagnosis/2026-10-15-ios-wip`。原本地HEAD：`582e4e42eff7c967cb5229e257af0925eb6c069f`；原目录短名：`ios-integrated`。源目录原有跟踪文件 663 个，另采集未提交文件 12 个（已跟踪修改不重复计数）。

**主诊断入口是 iOS WIP，第二入口是主仓文档WIP。各分支独立保存，尚未相互整合，也未与远端最新 main 集成；不能作为“全量集成、可编译或验收通过”版本。**

| 分支 | 原目录 / 原HEAD | 用途 |
|---|---|---|
| [diagnosis/2026-10-15-ios-wip](https://github.com/Yankj/catpaw-m/tree/diagnosis/2026-10-15-ios-wip) | `ios-integrated` / `582e4e42eff7c967cb5229e257af0925eb6c069f` | iOS 主诊断入口；12文件原样WIP |
| [diagnosis/2026-10-15-main-wip](https://github.com/Yankj/catpaw-m/tree/diagnosis/2026-10-15-main-wip) | `catpaw-m` / `86ea2091dfccb5cb2678a26cd9e42b322cc404dd` | 第二入口；固定目录基线＋6份设计/产品文档WIP |
| [diagnosis/2026-10-15-backend-live](https://github.com/Yankj/catpaw-m/tree/diagnosis/2026-10-15-backend-live) | `vision-live` / `e8fb5b90f5685dccb4c36da23c7b6740408e876b` | 独立后端最新已提交视觉源码 |
| [diagnosis/2026-10-15-backend-wip](https://github.com/Yankj/catpaw-m/tree/diagnosis/2026-10-15-backend-wip) | `backend-p0` / `74c079df26ca507b2930d0cf3a432e09ffe87e86` | 独立后端旧owner的7文件WIP；不等同live分支 |
| [diagnosis/2026-10-15-delivery](https://github.com/Yankj/catpaw-m/tree/diagnosis/2026-10-15-delivery) | `delivery-management` / `1d3242aeeaf589737ed0a12f47b3617f112ca8be` | 独立管理与用户验收失败记录 |
| [diagnosis/2026-10-15-qa-ios](https://github.com/Yankj/catpaw-m/tree/diagnosis/2026-10-15-qa-ios) | `qa-ios-e5ad1ef` / `5485aa31e60d42d13a47dbb139d8d5480eb36a05` | 固定475的合成TCP/URLSession wire历史证据 |
| [diagnosis/2026-10-15-qa-api](https://github.com/Yankj/catpaw-m/tree/diagnosis/2026-10-15-qa-api) | `qa-release` / `3170f2f78a0d8bfa876629ad1caffb11b934b28e` | 历史v15–v18无模型冒烟证据 |

源码入口：`apps/ios-conversation/CatpawM.xcodeproj`（scheme `DeviceTrial`）；后端为 `services/edge/supabase/functions/`。主仓与iOS/后端worktree不同源，比较时用各快照分支，不把主仓后端当成已部署v19。

历史版本：收据记载最后已安装 `0.3.0(15)`，源码 `4750142e9999bcf39a2231bd321169fe73e5e014`；当前iOS WIP配置为build16，未构建/安装。iOS分支的 `docs/acceptance/ios-build15-install-20261012.md` 保留原收据边界。

历史首个编译阻塞：暂停交接记录 `ConversationFirstView.swift:353` getter缺少return；当前源码可在 `stateName` getter附近核对。最近4项原生用例止于编译失败；流式UI命令未执行。**今天未复测构建或测试，未修复。** 旧43项原生、4项UI、8/8 loopback均不涵盖本次WIP；真机图片/真实模型、弱网/前后台等产品门槛仍未验，既有产品FAIL保留。

原始性能probe JSON与进程采样（7份，ios与qa-ios快照各一组）按日志排除；结构化RESULT/SOURCE-SHA256和验收说明保留，历史manifest中的原始日志链接可能不再可用。后端WIP保留原样，`git diff --check`另报provider文件第51行尾随空白；未修复。

本次仅重跑仓库冻结来源/许可完整性与敏感信息检查，不启动服务、模型、Auth、设备、签名或部署。iOS扫描中两处既有synthetic fixture公开key字面量未变，仅按WIP测试文件的新SHA更新reviewed-findings；生产源码保持采集字节。

未同步：原两份 `handoff.md`（含个人绝对路径，原文件留在本机）；忽略的runtime config、凭据/证书/设备信息、私图/私人对话、构建缓存与原始日志。canonical未跟踪候选/资产/研究/工具不属于固定整合目录，未导入；其 `SOURCE-MANIFEST.json` 本地改动也未当作新发布身份。其他干净的组件/旧iOS/QA worktree已盘点，相关来源由上述快照或历史身份定位。

传输：终端HTTPS缺认证，SSH主机密钥不匹配；未改凭据或SSH配置。用已连接GitHub的Git Data API建立完整文件树快照，父提交采用核查时远端main `63447d1fb44b6b1c99fae20cb10c907e58d2a595`，仅创建全新diagnosis分支。此父提交不表示本地与main做过代码合并；原本地历史SHA只作来源标识。

可复现的静态诊断（在新clone对应分支执行）：

```sh
git clone --branch diagnosis/2026-10-15-ios-wip https://github.com/Yankj/catpaw-m.git catpaw-diagnosis
cd catpaw-diagnosis
git rev-parse HEAD
git status --short
python3 scripts/check-repository.py
python3 scripts/scan-repository.py
```

如需单独复现iOS编译（今天未执行；使用已有Xcode，输出仅留忽略目录）：

```sh
xcodebuild -project apps/ios-conversation/CatpawM.xcodeproj -scheme DeviceTrial -configuration DeviceTrial -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/diagnosis CODE_SIGNING_ALLOWED=NO build
```
