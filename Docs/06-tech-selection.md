# 06 · 技术调研与选型

## 移动端约束

- 不能依赖持续后台进程。主动依赖「信号 + 云端决策 + 系统通知 / 本地调度」。
- 端侧适合：日历读写、提醒创建、本地记忆缓存、轻量规则、通知调度。
- 重推理与长期记忆存储走云端。
- 跨 App 执行优先走 App Intents / 官方深链。

## 选型

| 层 | 选型 | 理由 |
|----|------|------|
| UI | SwiftUI | 原生体验最佳，声明式适合卡片流 |
| 状态 | @Observable | 现代 Swift 并发与 UI 模型 |
| 本地存储 | SwiftData | 记忆与日志本地可查 |
| 通知 | UserNotifications + BGTaskScheduler | 系统合规 |
| 日历/提醒 | EventKit | 端侧可直接执行 |
| 网络 | 现有 CatPaw 云 API | 不重造执行引擎 |
| 架构 | MVVM + Feature 模块 | 便于扩展 |

## 不推荐

React Native / Flutter（体验优先，且已明确 Swift 为主）。
