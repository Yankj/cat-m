# UX-1 R2 视觉、交互与动效提案

[打开提案](index.html)；[视觉/动效实施附录](../../taste-visual-motion-r2.md)、[参数](../../taste-visual-motion-r2.json)、[UX-1](../../ios-codex-experience-spec.md)。独立保留前版R1与日期证据，不覆写旧截图来源。

八个场景：对话内决定、第一次交代、成果、精确审批、确定时间试算、跟进、错误恢复、离线。侧栏可搜索、清空、切回草稿；聊天/修改两份草稿独立；跟进字段跨静默/关闭保留；成果回同工作修改；审批关闭/拒绝/unknown语义独立。

点“播放流中决定”回放整段增量，正文继续时可回答，决定收成摘要，成果随后出现。CSS有限运动只使用transform/opacity，减弱动态可关闭；原生手势/键盘/材质采用系统实现。外观跟系统或手选浅/深色；375/390/430屏框和17/22/30布局样例仅为CSS设计单位。

使用已有Python，无新依赖：

```sh
python3 -m http.server 8847 --bind 127.0.0.1 --directory docs/design/prototypes/catpaw-taste
```

访问 `http://127.0.0.1:8847/`。所有业务内容、流和回执人工构造，只改变内存。没有真实模型、后台执行、账号、日历、通知、文件读取或系统分享。刷新重置。时间试算使用已有duration_budget_v1：总时长−预留−步骤数×每步时长；负数提示超额，参数无效阻止继续，显式继续只带入原工作草稿。

SF Symbols的原生映射仍见icon-semantics；网页只用系统文字符号定位。磨砂层为CSS示意，不能称官方Liquid Glass。屏框、键盘占位、DOM焦点/按键和减弱动态样例不代替VoiceOver、系统IME、原生最大字号或帧性能。不关闭任何AF-U/FQ/CG产品验收。
