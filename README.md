# 猫伴 · Cat Companion

CatPaw Mobile 上的主动式个人助理模块。

> 有长期记忆、能在合适时机主动触达，并在用户授权范围内调用端侧能力与现有 Agent 完成任务。把「用户可控」做成产品核心。

## 文档

| 文档 | 内容 |
|------|------|
| [Docs/01-competitive-research.md](Docs/01-competitive-research.md) | 2026 竞品调研与关键观察 |
| [Docs/02-product-positioning.md](Docs/02-product-positioning.md) | 产品定位 |
| [Docs/03-product-spec.md](Docs/03-product-spec.md) | 产品说明书（MVP） |
| [Docs/04-interaction-design.md](Docs/04-interaction-design.md) | 交互设计原则与关键流程 |
| [Docs/05-visual-design.md](Docs/05-visual-design.md) | 视觉设计系统 |
| [Docs/06-tech-selection.md](Docs/06-tech-selection.md) | 技术调研与选型 |
| [Docs/07-solution-roadmap.md](Docs/07-solution-roadmap.md) | 方案与落地节奏 |

## 代码结构

```
CatCompanion/
├── App/                  # 入口与导航
├── DesignSystem/         # 颜色、字体、组件
├── Core/
│   ├── Models/           # 领域模型（记忆、主动卡片、动作日志）
│   ├── Services/         # 日历、通知、云端 Agent 调用抽象
│   └── Stores/           # 可观察状态
└── Features/
    ├── Home/             # 今日简报 + 主动卡片流
    ├── Memory/           # 记忆面板
    ├── Assistant/        # 对话入口
    ├── Proactive/        # 主动建议详情与确认流
    └── Settings/         # 权限、策略、日志
```

## 技术栈

- Swift 5.10+ / SwiftUI
- Observation（@Observable）
- EventKit（日历/提醒）
- UserNotifications + BGTaskScheduler
- 现有 CatPaw 云端 Agent API

## 本地运行

使用 Xcode 16+ 打开工程（或将源码导入现有 CatPaw iOS 工程）。最低部署目标 iOS 18。

## 设计原则

1. 信任与控制优先于主动强度。
2. 每次主动必须可解释。
3. 高风险动作默认确认。
4. 记忆对用户完全可见、可编辑、可遗忘。
