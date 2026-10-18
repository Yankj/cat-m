# 架构总览

[← 返回 README](../README.md) · [文档索引](README.md) · 详细审查：[2026-10-15 代码与分支复核](architecture/repository-review-2026-10-15.md)

本文是 Diátaxis 的 Explanation 文档，描述 `main` 分支上的系统结构。进度和验收状态不在此维护，见 [主计划](status/master-plan.md)。

## 系统边界

```mermaid
flowchart TB
  subgraph Client["iOS App（apps/ios-conversation）"]
    V["Views<br/>ConversationFirstView · TaskPlan · TaskAction · Artifact · Memory · Inbox"]
    S["Application Services<br/>ConversationSessionService · TaskActionService · DeviceEffectService · MemoryService"]
    D["Domain<br/>AgentContracts · OperationReducer · DeviceEffects · StrictJSON"]
    P["Providers<br/>NativeChatHTTPBackend · NativeAuthSessionManager · NativeCalendarEffectExecutor"]
    DB[("SwiftData + BlobStore")]
    V --> S --> D
    S --> P
    S --> DB
  end
  subgraph Pkg["本地 Swift packages"]
    NAV["ios-navigation"]
    IMG["ios-image-composer"]
  end
  subgraph Backend["Supabase Edge（services/edge）"]
    API["catpaw-api/index.ts"]
    AUTH["authority.mjs · consent.mjs · sensitivity.mjs"]
    CORE["_shared/core"]
    API --> AUTH --> CORE
  end
  V --> NAV
  V --> IMG
  P -->|HTTPS / SSE| API
  CORE --> PG[("PostgreSQL")]
  CORE --> M["OpenRouter 免费路由"]
```

## 分层职责

| 层 | 目录 | 职责 | 不允许 |
|---|---|---|---|
| Views | `Sources/Features/*View.swift` | 展示、收集用户决定 | 持有账号、发 HTTP、执行副作用 |
| Services | `Sources/Features/*Service.swift` | 编排用例、状态机、重试与恢复 | 绕过 Domain 合同 |
| Domain | `Sources/Domain` | typed contract、严格 JSON、reducer | 依赖 UI 或系统框架 |
| Providers | `Sources/Providers` | 网络、SSE、认证与安全存储、EventKit | 自行决定授权 |
| Persistence | `Sources/Persistence` | SwiftData（CloudKit 关闭）、Blob | — |
| Edge | `services/edge/supabase/functions` | 准入、授权、同意、模型调用、持久化 | — |

## 关键原则

1. **授权在后端**：展示层和流结束都不能授予权限或宣告完成。
2. **人在回路**：外部副作用（如 `calendar.create.v2`）先审批，再在注册设备执行；`unknown_recovery: original_only`，结果未知时只按原决定核对。
3. **模型路由固定**：`config.mjs` 中的免费路由禁止 fallback 与数据收集，日历、照片、联系人、认证令牌等字段不发送给模型；敏感内容需单独确认。
4. **证据分层**：fixture、本地合成 façade、真实模型、云服务四层结果严格区分。

## 设备动作时序

```mermaid
sequenceDiagram
  actor U as 用户
  participant V as TaskActionsView
  participant S as DeviceEffectService
  participant API as catpaw-api
  participant X as NativeCalendarEffectExecutor
  V->>U: 审批卡片
  U->>V: 确认
  V->>S: 提交决定
  S->>API: decision + 版本
  API-->>S: 授权（或 stale / busy）
  S->>X: 执行 calendar + notification 子效果
  X-->>S: 外部引用或 ambiguous
  S->>API: 回报结果
```

## 相关文档

- [ADR-005 运行时复用与托管](architecture/adr-005-runtime-reuse-and-hosting.md)
- [后端原生契约交接](../services/edge/docs/NATIVE-HANDOFF.md)
- [目录角色](development/repository-layout.json)
