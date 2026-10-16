# Native conversation client

Swift/SwiftUI iOS17+, local SwiftData (CloudKit disabled), URLSession SSE and original-turn GET recovery. Frozen P0 source import; not product acceptance. Actual progress is maintained only in ../../docs/status/master-plan.md. Runtime public configuration and signing must be supplied locally; this import has blank config. No real model calls or phone installation during P0 fixture checks.

## Proactive travel demo (DeviceTrial / BE5C)

NoBug B slice (meeting leave_at): inject a 望京 meeting from **设置 › 调试 › 主动信号模拟**.

- **Location:** tap **请求定位权限（When-In-Use）** once, or set Simulator **Features › Location** near 望京 (`simctl location <udid> set 39.9961,116.4806`). Without auth/fix, Why shows 「未用到 ETA」 (no silent CBD origin).
- Optional **模拟起点** is labeled explicitly in Why as 「从模拟起点 X」.
- Lead minutes write a real memory row in **设置 › 记忆** (not UserDefaults).
- Out of demo script: phone/shop chains, prod DB migrations, Widget/CLMonitor/auto-SMS.

