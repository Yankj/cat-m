# chat-ux #4 follow-up suggestions eval

- Ran: 2026-10-16T14:50:50.643Z (UTC) · agnes `agnes-3.0-flash` · temperature 0 · 3 runs × 10 cases
- **Pass: 19/30 = 63.3%** · per run 6/10, 6/10, 7/10 · fence present 70% · errors 0
- Pass = iOS parser yields 2–3 items, each ≤ 18 chars, none repeating the question. Quality (are they good questions) is not scored.
- Path: real chat service with production gates and the iOS kinds header (incl. followups); one provider route.

## Failures

| run | case | items |
|---|---|---|
| 1 | f04 | [] |
| 1 | f05 | ["帮我列个 Kotlin 入门路线","Swift 和 Kotlin 语法有哪些坑","我这两个项目更适合哪个"] |
| 1 | f08 | [] |
| 1 | f10 | [] |
| 2 | f02 | [] |
| 2 | f03 | [] |
| 2 | f05 | ["Swift 两周入门路线怎么排","Kotlin 和 Swift 语法对照","用哪本教材学 Swift 好"] |
| 2 | f06 | [] |
| 3 | f03 | [] |
| 3 | f06 | [] |
| 3 | f10 | [] |
