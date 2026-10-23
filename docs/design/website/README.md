# 小咪产品官网设计与来源

2026-10-19 的网站实现记录，不替代产品实时状态或真机验收。

官网源码已迁至 **`Yankj/heydusk-site/apps/mimi/`**，部署域名为 **mimi.heydusk.com**（与公司站 heydusk.com 同仓分目录；公司站仅外链至此，不内嵌产品页）。本仓库 `Yankj/heydusk-site/apps/mimi/` 仅保留迁出说明。采用用户指定的目录职责，与原生 App、Edge 后端分开部署。设计判断：面向个人用户的简约产品介绍；现有暖白、炭黑、橙色品牌；系统字体；少量解释性动效；明暗主题；减少动态偏好。设计参数为 6 / 4 / 3（布局变化 / 动效 / 信息密度）。

## 信息覆盖

| 原始 deck 维度 | 官网位置 |
|---|---|
| 1-3 定位、痛点、理念 | 首页首屏、问题叙事、设计原则 |
| 4 完整案例 | 首页交互时间推算、五段过程、指定原视频 |
| 5 同类产品 | 技术页「聚焦手机里的日常小事」；原始 deck 保留 |
| 6 主动 | 首页主动案例、限制与 FAQ |
| 7 记忆 | 首页记忆段、安全页记忆管理 |
| 8 执行 | 首页确认到回执、公开链接阅读 |
| 9 可信 | 首页信任原则、安全页授权与完成依据 |
| 10-11 进度、六态小猫、确认卡、生成式 UI、语音 | 首页体验段、六态交互、技术页与版本边界 |
| 12 设计 why | 首页品牌与原生体验说明 |
| 13 安全和账号 | 独立安全、隐私与账号页 |
| 14 选型 | 技术页复用与自建表 |
| 15 系统全景 | 技术页原生 App / Edge / 权威记录架构 |
| 16 Agent 执行循环 | 技术页确认、设备执行、回执和断点续跑 |
| 17 实时预览、生成式 UI、人在回路 | 技术页即时体验与持久记录 |
| 18 主动与记忆机制 | 首页案例、技术页门控、记忆来源 |
| 19 模型可靠性 | 技术页故障转移、恢复及路由说明 |
| 20 路线 | 首页当前 / 计划，版本页细化限制 |
| 21 品牌收束 | 首页末尾行动入口 |
| 22 版本与生产缺口 | 版本页，保留未核实和计划边界 |
| 23 部署历史 | 版本页可展开的历史时间线（明确历史记录） |
| 24 通用 Agent 比较 | 技术页取舍说明、原始 deck 比较入口；不重发布未经核实的功能排名 |
| 25 证据索引 | 原始 PDF 证据索引链接、GitHub 能力清单、固定来源 SHA |

## 版本裁决

用户提供的 deck、视频记录 v1.1，当前主分支 `cb3bc90a6f35d93e9ad57a6c01c7dc83291d06ee` 的 CHANGELOG 和能力清单记录 v1.2.0；GitHub Releases latest 同样返回 v1.2.0（IPA 与模拟器包）。官网保留旧演示标签，当前入口使用「待办 / 记录 / 了解你」。Gmail、联网搜索仍为 v1.3 计划，不因为版本号变化而宣称旧路线图全部完成。

早期 brief 与新 deck 的模型顺序不同，官网不固定复述顺序。APNs、完整语音真机体验、语义检索和外部账号操作不扩大承诺。网站交互只是时间计算示例，不连接服务端或系统日历。

## 设计与研究参考

- 使用 `design-taste-frontend`：先判断页面目的，再组织视觉层级、真实素材、响应式与可访问性。
- [draw-ui](https://github.com/oil-oil/draw-ui)：已阅读并评估，作为备选；采用现有品牌素材，没有运行外部图像生成服务。
- [Lindy](https://www.lindy.ai/)：任务结果先于抽象能力；[安全页](https://www.lindy.ai/security)为控制、可见性与数据边界设置独立入口。
- [rabbit](https://www.rabbit.tech/)：以日常场景展开价值，再说明记忆、使用方式与 FAQ。
- [Manus](https://manus.im/)：功能、资料、下载与信任入口分层。
- [ChatGPT Pulse](https://openai.com/index/introducing-chatgpt-pulse/)、[Gemini Live](https://gemini.google/overview/gemini-live/)、[Apple Intelligence](https://www.apple.com/apple-intelligence/)、[Now Brief](https://www.samsung.com/sg/support/mobile-devices/how-to-set-up-and-use-now-brief-on-your-samsung-galaxy-device/)：官网结构与定位参考，不据此作功能优劣排名。

研究只提取结构，不复用第三方品牌图像、用户评价、客户标识、定价或未经依据的数字。素材来源及固定媒体哈希见 `Yankj/heydusk-site/apps/mimi/ASSETS.md`。
