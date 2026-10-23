# 小咪家庭陪伴场景 · 方案资产索引

2026-10-22。首期从宝妈带孩子出发，后续扩展家庭事务与自我管理。本目录包含产品结构、视觉概念和工程改造方案，全部为虚构示例；不是已实施功能或产品验收结果。实时工程交付状态仍见[主计划](../../status/master-plan.md)。

## 先读什么

1. [技术方案 Markdown](../../architecture/family-companion-technical-plan.md) / [18 页 PDF](../../architecture/family-companion-technical-plan.pdf)：仓库改造路径、领域数据/API/事件、记忆统一、可靠调度、前置修复与分阶段验收。
2. [产品架构图 PNG](assets/cat-product-architecture-v0.1.png) / [PDF](assets/cat-product-architecture-v0.1.pdf) / [SVG](assets/cat-product-architecture-v0.1.svg)：目标用户、场景、长期闭环和对象关系。v0.1 待评审，图中“三个入口”表示内容分区，不要求底部 Tab。
3. [修订视觉 v0.2](assets/visual-v0.2-review.png)：当前待评审概念，延续现有小咪风格。图片不作为组件尺寸/色值权威，源码 token 优先。
4. [温馨 UI 局部细节](assets/warm-ui-details-v1-review.png)：圆润图标、猫状态、确认卡、记忆更正和空态，当前待评审。
5. [技术架构图](assets/technical-architecture.png)：现有原生宿主 + 模块化 Edge 后端 + 一个 Postgres；未新建云服务。
6. [决策记录](decisions.md)：已确认方向、工程建议和待确认项分开。
7. [家庭 API v1](api-v1.md)：冻结协议 `catpaw.family.v1`。iOS 与后端按该文件对齐；文件本身不是部署或验收。

## 延后执行计划

[执行 Goal / M0-M5 / 验收与分工](execution-goal.md)已准备为评审 v0.1；状态 PLAN_READY / NOT_STARTED。启动条件、目标主机授权及各执行环境的 gpt-6.1-sol + ultra 实际配置回读尚待确认。本次仅补计划，没有创建/恢复实施 Goal、启动实现或设置自动启动。

## 当前导航与视觉基准

保留 **conversation-first + 侧栏 + 原生返回**。今天 / 聊聊 / 我们家是内容分区，聊天仍默认入口，不强制底部三栏。成长计划是我们家一级内容，同时连接聊天和今天。

保留现有暖白背景、橙色猫品牌、深色正文、中性气泡、蓝色发送按钮；温暖通过理解、澄清、纠正和克制提醒体现，不另造主题。

- `apps/ios-conversation/Sources/DesignSystem/catBrandTokens.swift`：品牌橙 #FF702A、背景 #FFFCF8、正文 #292622。
- `Components.swift`：操作填充 #C64A0B，发送 #3567EE，本人气泡 #F2EFEB；含深色语义映射。
- `AdaptiveTextLayout.swift`：系统语义字体与 Dynamic Type；正文阅读节奏约 1.6 倍。
- [品牌规范](../../brand-theme.md)。旧 R5 的交互原则仍有价值，但旧蓝色气泡 JSON 不等于当前源码色值。

## 探索稿边界

[第一版柔绿四屏](explorations/visual-v0.1-not-implementation-baseline.png) **仅作历史探索，不作为实施基准**。用户后来明确要求沿用现有仓库色系。不能由图片推断家庭权限、真实模型、日历执行或通知已经实现。

温馨细节落地约束：图标采用 SF Symbols 同语义符号，24pt 图形、至少 44pt 热区；卡片 20pt、控件 14pt；可点击橙色文字使用 #C64A0B，不从图片采样亮橙。猫表情不代替文字和真实状态；只有实际收音显示“正在听”，成功回执后才显示“已加入日程”。

产品架构图采用中性文档配色，图末亦注明不代表 App 主题。v0.2 概念图仍需结合权限、回执和实际内容修订，不把图里的“爸爸”推断成首期多人协作已开放。

## 来源与可复现

- 产品图 Library：PNG `libfile_2569712d92a881918f0e9926efbef161`；PDF `libfile_1aef26494f7c8191adcc967f892917a8`；SVG `libfile_73bd5ae9ae248191bc12a3eca0c61024`；[绘图脚本](tools/draw-product-architecture.py) `libfile_e6104f1cd15c8191ac3aca0c2a9d6cf6`。
- 温馨局部稿：`libfile_2f6c828e3d308191a05a39f9501b9993`。
- 修订视觉 v0.2：`libfile_a5b10f7f00e4819192cf959a39dbc2d8`；历史探索：`libfile_a3d78a8d70cc819195df1fe6ac2d2877`。
- 技术方案 Library：Markdown `libfile_90e591a10418819189f637d42d9e598f`；PDF `libfile_707cfa966c908191b86fde2237cfcd16`。
- 既有原生离线截图参考：`libfile_6f01d275bb7481919b1c9c81d5492320`，存在连接失败状态，只作为当前样式证据；没有复制私人手机截图入库。
- [字节和 SHA-256 清单](asset-manifest.json)。下载链接的临时签名、凭证和真实家庭信息不入库。

产品图脚本原样保留，依赖 matplotlib 与 Linux Noto CJK 字体路径，本轮仅读取未执行。技术 PDF 使用 [macOS 原生排版脚本](tools/render-technical-plan.swift)，可在已装 Swift/AppKit/PDFKit 的 Mac 上运行：

```sh
swift docs/design/family-companion/tools/render-technical-plan.swift docs/architecture/family-companion-technical-plan.md /tmp/cat-family-technical-plan.pdf
```

PDF 将 Markdown 表格按带字段标签的记录排版，架构图单独一页；Markdown 是可编辑权威，PDF 是同版阅读副本。脚本在输出目录生成 preview 中间图，不应直接将临时图全量提交。

## 仓库与后续工作

当前源项目复用既有 `ai-work/catpaw-m`。用户指定目标为另一待确认执行环境中的 `ai-workspace/mimi`，当前 Mac 不存在该目标用户目录，尚未迁移且未删除源。远端已核验改名为同一仓库 `Yankj/mimi`（repository ID 1413057312），origin 已更新；旧名永久重定向。本次专用分支 `docs/family-product-plan` 基于 main `789ad4fe`，没有重复 clone、改名远端、合并 PR 或部署。

PR #110 已关闭、未合并；品牌通过 PR #112 合入 main。旧审计基于 423d25b1，原生/后端维护源码与 789ad4fe 无新增差异；历史测试结果不能改写成新 SHA 已测试。

后续代码开发另起经批准的切片，不在本 docs 分支夹带实现。图与方案变更时同步本索引、决策记录和 manifest；旧稿保留状态标签，避免设计基准漂移。
