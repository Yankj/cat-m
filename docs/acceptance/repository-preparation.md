# 本轮仓库准备检查

本文件记录v1/r2/r3资产准备阶段的实际本地检查，保留历史口径。当前conversation-first产品进展只维护在 [主交付计划](../status/master-plan.md)；355文件、源码hash或这里的旧合成测试不代表产品完成。此次计划纠正没有重跑这些runtime测试。

2026-10-11，本地维护快照，不含远端提交。先完成v1/r2基础准备，随后收到冻结r3正式终态并单独整合。原生v1业务源码/资源/项目/测试和façade r2运行源码保持原文；基础迁移只调整两个iOS测试脚本的引用/输出目录、六份独立QA用例的import/临时根，以及两份历史Gateway输出中的个人路径。r3的4个测试工具与1份适配说明只迁移路径/输出，业务源/Swift断言保持原字节。所有转换有原文/副本SHA256。

| 基础准备实际执行 | 结果 | 精确边界 |
|---|---|---|
| 复制/来源完整性 | 188项导入bytes对应；最终v1 41项identity和10项spec对应 | v1/r2基线，r3另列 |
| 上游原文/许可/patch | 44项SHA256+Git blob SHA1，MIT原文一致；patch重建实际运行TS副本通过 | 使用已保存来源，未重新联网认证全套源码 |
| v1 source检查 | macOS条件typecheck、iOS syntax parse、36源工程/scheme/资源检查通过 | 无iOS SDK/API/宏/链接/XCTest/UI构建 |
| 双语检查 | 463条完整，429 locale-bound lookups，查缺负向自检通过 | 非英文视觉/VoiceOver验收 |
| v1 Foundation领域 | 186/186，0失败 | Codable磁盘driver，非SwiftData/设备运行 |
| façade进程内 | 42/42，0失败（原14+负向15+独立边界13） | 不监听端口；并发使用模型，不是真实SQL |
| 早期离线样件 | 29/29，0失败 | 无HTTP/Worker/真实模型执行 |
| v1 Gateway合同/归属/安全 | 通过；真实模型0 | 用已有完整Xcode进程工具链编译运行，无端口监听 |

Gateway检查首次使用默认Command Line Tools时，链接器触发 `ld::LayoutExecutable::assignAddresses` 断言，未运行合同断言，记录为失败。设置本次进程的 `DEVELOPER_DIR` 指向已有完整Xcode后，同一源码和检查通过；没有更改全局xcode-select、安装组件或修改源码。若本机也遇到该链接器问题，使用 `DEVELOPER_DIR=<已有Xcode的Contents/Developer> zsh apps/ios/Scripts/test-gateway-portable.sh contract`。本轮机器可移植结果摘要见 [results.json](evidence/repository-preparation/results.json)。

本轮不安装依赖、不启动常驻或loopback服务、不操作Simulator、不访问真实模型/Intelligence/数据库，不读取凭据或新登录。HTTP/重启和原生历史结果保留原口径；冻结r3最后源码已由客户端任务实际iOS编译/HTTP/原生UI验收，本轮另做无监听本地复核，详见 [r3终态验收](openmuse-r3.md)。初次只读盘点不再代表当前状态。

## 冻结r3整合后的实际本地检查

| 本轮新增检查 | 结果 | 精确边界 |
|---|---|---|
| 来源/最终ZIP/合同 | 101项最后源码与ZIP对应、194项ZIP文件hash、121项导入bytes、43份App源、10项spec、4张图及合成响应provenance一致 | App/ZIP不入库；保留原v1/r2身份与上游许可/patch |
| fixture / 磁盘 | 15/15，0失败 | Foundation/合成transport，无外部请求 |
| 合成HTTP响应重放 | 5/5，0失败 | torn读、预算耗尽、原任务恢复、hash/scope拒绝；无live网络/Worker |
| 源码/工程/资源 | macOS条件typecheck、iOS syntax parse、43源工程/scheme/spec/资源通过 | 不等于iOS SDK/宏/链接或XCTest/UI构建 |
| 双语资源 | 513条、488 locale-bound lookups、查缺负向自检通过 | 不是新增页面英文/浅色/VoiceOver视觉验收 |
| HTTP runner编译 | 默认已有CLT成功，生成本机Swift runner | 仅编译，没有启动HTTP测试或监听 |
| 迁移工具/链接 | Shell/MJS语法及维护Markdown文件引用通过 | 测试断言不修改 |
| 原目录保全 | v1 91项、r2 26项、冻结r3 251项无变化 | 包括r3原报告/工具等未入库文件，只读hash核对 |

本轮15+5测试输出与source检查保存为精选文本，机器可移植摘要见 [openmuse-r3-results.json](evidence/repository-preparation/openmuse-r3-results.json)。客户端实际iOS构建/HTTP/原生UI终态另见 [r3验收](openmuse-r3.md)，本轮没有重复运行服务或Simulator。v1/r2未变，因此基础准备的186/42/29项结果继续保留原时间点，不重复计数。

冻结spec的Markdown原有双空格换行/末尾空行，以及unified patch的单空格上下文行保持原字节；`.gitattributes`仅为这些路径声明精确空白规则，并禁用冻结资产换行转换。其他新文件执行普通diff空白检查。冻结README中技术版本标v1.2，正文实际标v1.3，该历史不一致已在产品索引说明，没有改写冻结文件。

## 敏感内容与体积

候选文件扫描覆盖凭据前缀/私钥/具体secret赋值、signed URL、内部域名、绝对个人路径、设备UUID上下文、敏感文件/目录、非预期二进制和5MiB大文件。扫描器只读Git候选文件，忽略缓存和凭据目录；绝不打印疑似值。

12项命中已逐项核读并按完整文件SHA256固定记录在 [reviewed-findings.json](../../scripts/reviewed-findings.json)：v1/r3共7张PNG只有通用Screenshot/方向/尺寸/XMP元数据，无设备或用户身份；上游1处是签名URL变量构造而非签名链接；1处为明确 `local-aimock-demo-only`；3处为reserved `.example`合成邮箱。任一文件byte变动使例外失效，需要重新审阅。最终候选扫描无未解决命中或5MiB以上文件，只有7张审阅过的PNG。

这是一轮已知模式扫描与人工审阅，不能保证识别所有未知敏感内容。发布前须再次扫描最新差异。仓库外本地审计保留扫描JSON、源目录保全和QA迁移检查、待提交差异统计；它包含机器路径，不能一起纳入仓库。

## 排除项

- 原交付大ZIP、拆包、`.app`/IPA、DerivedData/`.build*`、xcresult、用户Xcode状态和设备日志。
- 全量原生截图/树/附件缓存、原宿主用户参考截图、Library身份/传输资料、signed上传链接。
- 上游安装/打包/传输临时脚本与锁文件；本地合成运行不需要完整SDK或依赖安装。
- façade `.env.example` 及所有 `.env`/credentials/runtime数据；仓库仅说明必要运行配置，不保存真实身份。
- r3源码的打包/截图临时工具、完整构建/UI日志、结果包和App；仅纳入冻结的维护源码、纯测试输出、分层终态摘要及4张精选图。初次活动盘点保留为历史记录。
- 含个人绝对路径/设备身份的原验收报告：转为此处维护摘要，原文hash和本地位置只保留在仓库外审计。

已交付v1中约1.5GiB构建目录和约72MiB报告/截图缓存被排除；r3原ZIP的6,401,200字节也不入库。长期仓库候选资产约5.2MiB，以最终本地审计统计为准。没有密钥、真实用户资料或私有内部文件被复制进候选集。
