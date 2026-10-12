# iOS v1 历史验收记录

来源：已交付 v1 的最终集成报告与测试产物，2026-10-11。此页是去掉设备身份、绝对个人路径与传输记录后的维护摘要，未复制全量日志/附件。原报告 hash 与本地来源由仓库外审计保留。本轮未重跑原生构建或 Simulator。

| 检查 | 历史实际结果 | 保存证据 |
|---|---|---|
| Foundation/Codable 领域 | 186/186 | [final-portable-05.txt](evidence/ios-v1/final-portable-05.txt) |
| Node 合成 Gateway | 23/23 | [node-tests-03.txt](evidence/ios-v1/node-tests-03.txt) |
| Gateway 合同/归属/安全 | 通过 | [gateway-contract-06.txt](evidence/ios-v1/gateway-contract-06.txt) |
| URLSession/真实 loopback SSE | 通过，真实模型0 | [gateway-http-02.txt](evidence/ios-v1/gateway-http-02.txt) |
| 完整合并 XCTest/XCUITest | 14+14通过 | [修正前 source identity](evidence/ios-v1/final-tests-14-source-snapshot.json)；原日志留在交付资产 |
| 视觉修正后普通字号场景 | 1/1，112.932秒 | 原 `final-contrast-normal-15` 终态；[最终 source identity](evidence/ios-v1/final-source-snapshot.json) |
| 修正后最大字号键盘/审批 | 1/1，227.112秒 | 原 `final-max-tests-16` 终态；同最终 identity |
| 修正后最大字号CSV/阅读器/分区 | 1/1，91.790秒 | 同上 |
| 最终干净 Simulator build | BUILD SUCCEEDED，arm64+x86_64，无测试PlugIns | 同最终 identity，产物排除 |

完整 28 项之后仅修改 UI 色彩、确认优先顺序及稳定验收标识；业务领域/Repository/provider/runtime/服务未改。后续指定场景使用最终生产源码，不能说最后颜色修正后完整 28 项重跑。最终41项源码/资源/项目/原生测试 hash 对应当前导入文件，检查脚本逐项重验。

环境历史为 Xcode27.1/SDK27.1、iOS27.0 runtime；工程部署目标 iOS17+ 不证明 iOS17 runtime 跑过。v1交付完整ZIP SHA256 `b3cd71dd296f3e180e42106c004bf49e4b147da1a2b23d44fc7d17f52ffa32dd` 仅作原交付身份，ZIP不进仓库。3张精选合成图在 [设计说明](../design/README.md)，未变像素；不能证明全功能验收。

未验：真实 provider/Agent研究、HTTPS/session与credentials、原操作核验、云worker/推送；真机麦克风/on-device中文ASR/TTS/中断/权限路线、实际选择器授权、iOS17/iPad/英文/小屏、VoiceOver/Reduce Motion与大存储。TTS仅允许已校验内置公开示例v1，导入/私有/编辑版本受阻。
