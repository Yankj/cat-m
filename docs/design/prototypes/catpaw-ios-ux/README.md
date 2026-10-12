# UX-1可点按布局提案

入口：[index.html](index.html)；对应[设计规格](../../ios-codex-experience-spec.md)与[前期对标记录](../../ios-codex-reference-review-2026-10-13.md)。无外部依赖，所有内容为人工样例，操作只改变页面内存状态；刷新重置。

可以审阅：主对话/新对话、进行中与队列、侧栏搜索、任务计划、关闭/重开审批、成果阅读/返回改稿、记忆更正和跟进暂停、附件预览、浅深色/宽度/大字号/键盘占位。

本地打开HTML即可使用；若需要浏览器HTTP预览，用已有Python从仓库根运行：

```sh
python3 -m http.server 8843 --bind 127.0.0.1 --directory docs/design/prototypes/catpaw-ios-ux
```

访问 `http://127.0.0.1:8843/`。预览不请求模型、云端或第三方网站，不读相册/日历，不证明原生IME、触控、VoiceOver、系统动作、实际流式或后台恢复。大字号开关只模拟布局放大，最大辅助字号仍须原生验证；宽度为CSS设计单位，须在真实iOS安全区复核。

历史手机原图和新预览分别记账；预览从不作为AF-U或父用例的产品PASS证据。
