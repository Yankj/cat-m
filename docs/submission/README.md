# CatPaw Mobile · NoBug B 交付说明（会议出发助理）

> 仓库：`github.com/Yankj/catpaw-m` · 分支 `feat/ios-mvp-integration-v2`  
> **冻结 tip SHA：`f8e86d8`**（2026-10-16 18:30 北京时间）  
> 架构细节：[ARCHITECTURE.md](./ARCHITECTURE.md) · 录屏分镜：[demo-video-plan.md](./demo-video-plan.md)  
> 同内容镜像：仓库 `docs/submission/`

CatPaw Mobile 主动式个人助理的 **NoBug B 切片**：在会前算出 `leave_at`，用卡片 / 通知 / 出发 Live Activity 找你，确认后写提醒、起草短信。  
**演示脚本不含** 电话链、购物链。

---

## 状态标记

| 标记 | 含义 |
|---|---|
| **[已实现]** | 代码在 tip `f8e86d8`，可在 DeviceTrial / BE5C 演示 |
| **[部分]** | 有路径但依赖系统能力或后端 gate |
| **[设计]** | 文档有、本切片未做 |

---

## B 八步演示（NoBug 验收故事）

在 **DeviceTrial** · 模拟器 `BE5C60E0-B415-4BF4-8F36-8975FB5314AA`（或真机）上：

| 步 | 做什么 | 期望 | 状态 |
|---|---|---|---|
| **S1** | 设置 › 调试 › 主动信号模拟 → 看构建区 **git SHA** | 与冻结 tip 一致（Info `CatpawGitSHA`） | [已实现] |
| **S2** | 「写入记忆并生效」提前 N 分钟 → 打开 **设置 › 记忆** | 出现「开会提前 N 分钟准备」，可「忘记」删除 | [已实现] |
| **S3** | 「请求定位权限」或 `simctl location` 设望京；可选「模拟起点」；「注入望京 SOHO 的会」 | Why：**有定位** →「路途约 M 分钟（MapKit）」；**模拟起点** →「从模拟起点 望京」；**无定位** →「未用到 ETA」（无上海兜底） | [已实现] |
| **S4** | 看建议卡标题 / 「为什么」 | `leave_at` = 开会 − lead − travel；信号含日历 / 路途 / 规则；记忆来源可点进记忆页 | [已实现] |
| **S5** | 「创建提醒」 | EventKit 写入提醒事项；重复点不双写；可撤销 | [已实现] |
| **S6** | 「告诉参会人」 | **真机**：MessageUI 起草（用户自点发送才 `done`）。**模拟器**：`unavailable`，**不**标完成，taken 留证 | [部分] 模拟器无法发短信 |
| **S7** | 介入后看灵动岛 / Live Activity | 出发倒计时（`Text(date, .timer)`）；撤销 / dismiss 结束 LA | [已实现] |
| **S8** | 记忆页删除该条或关掉「使用记忆」→ 再注入 | lead 回默认；卡片文案 / `leave_at` 变化；无假 MemoryRef | [已实现] |

---

## 模拟器 vs 真机

| 能力 | 模拟器 BE5C | 真机 |
|---|---|---|
| 注入会议 / 去重账本 / Why | ✅ | ✅ |
| 记忆写入（agent-memory gate 开） | ✅ 需后端 | ✅ |
| 记忆写入（gate 未开通） | ✅ **本机 stub**，设置 › 记忆可见可删（界面诚实提示） | 同左 |
| MapKit ETA + 真实定位 | ✅ 需授权或 simctl location | ✅ When-In-Use |
| EventKit 提醒 | ✅（权限后） | ✅ |
| MessageUI 短信 | ❌ unavailable，不标 done | ✅ 用户点发送才 done |
| 出发 Live Activity | ✅ 有限 | ✅ |
| 电话 / 购物链 | 🚫 本切片脚本不演示 | 🚫 |

---

## 明确不在本切片

- 电话链、购物链（P1，脚本外）
- 桌面 Widget 品牌抛光、CLMonitor / 显著位置围栏
- 自动发送短信（只起草）
- **生产 DB migration / 扩展启用**（migration 在仓库，**未**要求评委或用户应用到 prod）
- reply-chrome 重写（已合入 `12160c8`，勿再改）

---

## 诚实说明（gate / migration）

- `catpaw.agent-memory.v1` 服务端 **feature gate** 可能仍为未开通：客户端会提示并写入 **本机记忆库**（同一 Settings › 记忆 页），**不会**用 UserDefaults 冒充 MemoryRef。
- `services/edge` 下 proactive / agent_memory migration **已在仓库**；应用到生产库需所有者确认，**本交付不依赖 prod 已迁移**。
- ETA：**禁止**静默上海 / CBD 原点；无定位 =「未用到 ETA」。

---

## 运行

```sh
git clone -b feat/ios-mvp-integration-v2 https://github.com/Yankj/catpaw-m.git
cd catpaw-m && git checkout f8e86d8
open apps/ios-conversation/CatpawM.xcodeproj
# Scheme: DeviceTrial → 目标 BE5C 或真机
```

定位（模拟器）：

```sh
xcrun simctl location BE5C60E0-B415-4BF4-8F36-8975FB5314AA set 39.9961,116.4806
```

或在调试页点「请求定位权限（When-In-Use）」。详见 `apps/ios-conversation/README.md`。

---

## 相关提交

| SHA | 说明 |
|---|---|
| `f8e86d8` | 本交付冻结 tip（定位入口 / 标签去重 / attendees 持久化） |
| `68c8c0c` | 真实记忆 lead + CLLocation ETA（NoBug P0 红线） |
| `e8f5502` | notify unavailable 留证不标 done |
| `12160c8` | reply-chrome（已合入，勿重写） |
