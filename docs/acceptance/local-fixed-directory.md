# 固定本地目录整合验收

2026-10-12。目标目录原先不存在，本批新建独立 clone；保留 Git 历史，使用 `--no-local --no-hardlinks`，无 alternates，对象文件 link count 为1。原仓库/worktree 未移动、删除或写入。实际本地路径保留在交付与 Git 的 canonical-source remote，不把个人绝对路径写入仓库文档。

分支 `integration/local-fixed-directory`，基于 `b7fa4ee`；七个指定来源提交和本地对应提交见 [来源映射](../status/local-integration-source.json)。GitHub origin 仅指定 URL，无认证、fetch/push。两处冲突均为主计划末尾追加记录，审查后保留双方全文；生产代码无冲突。

## 本轮实际结果

| 检查 | 结果 | 实测边界 |
|---|---|---|
| Git 完整性/独立对象库 | PASS | fsck exit0；无共享链接/alternates；保留冲突产生的2个无引用tree，未清理对象 |
| 指定源码身份 | PASS | iOS主源码/测试/资源/工程/config与d9a897c相同，后端生产/测试与14495be相同，侧栏与d92bfec相同，QA与5e7cf41相同 |
| 主iOS无签名构建 | PASS | DeviceTrial/generic iOS Simulator，Xcode27.1/SDK27.1，CODE_SIGNING_ALLOWED=NO；未启动/安装 |
| 原生检查脚本 | **FAIL（本地化门槛）** | 修正旧macOS target后，iOS SDK typecheck/语法/63源码/3target/scheme PASS；本地化检查99条未登记中文字面量，3文件，overall exit1 |
| 对话/队列 Foundation | 7/7＋9/9 PASS | 当前固定目录的已有脚本，独立合成存储，无网络 |
| 侧栏 | 12/12 PASS＋iOS library编译链接PASS | 独立package；本批无Simulator UI、未宿主接线 |
| 后端 | 62/62 PASS | 已有Deno2.9.6＋只读公开固定依赖，禁网络/忽略环境变量；合成Repository/transport/serializer，非真实PG |
| 冻结资产/敏感信息/空白 | PASS | 来源完整性通过，扫描无阻断或待审命中 |

结构化记录、来源tree和原始忽略日志SHA见 [RESULT.json](evidence/local-fixed-directory/RESULT.json)。命令见 [根README](../../README.md)。原始日志在忽略的 `build/local-integration/`，构建缓存不提交。

## 工具修正与剩余门槛

来源 `check-source.sh` 使用macOS SDK，iOS-only `ConversationFirstView` 的 UIKit import 导致在检查初始阶段失败；此外引用了缺失的 `validate-project.py`。本批只将开发检查目标改为实际iOS SDK，补静态项目成员校验器，不改生产源码。现有本地化门槛保留：NativeLoginView 14、ConversationFirstView 76、CatpawApp 9 条。99是检查器命中数，需逐项复核，不扩大为99个独立产品缺陷，也未新增豁免掩盖失败。

canonical 的未跟踪 candidates/assets/research/tooling未导入；之后的owner修改或视觉链分支未自动跟随。后端原 `.mjs` / `.ts` / lock 与固定配置不改；测试import map只在忽略build生成，并只读现有公开jose/postgres缓存，不复制依赖、候选资产或安装包。

本目录没有导入原生owner本地运行配置、凭据、证书或Keychain；不做安装、UI测试、生产Auth/模型/云端请求。侧栏仍未宿主接线；图片/真实流式/网络切换/30s恢复/实时能力、真实PG多实例、worker恢复和长期授权均不在本批。旧QA报告仍绑定其冻结输入，未冒充重跑；R1产品FAIL和性能未验状态保留。下一步在本固定目录继续开发的范围由协调分配。
