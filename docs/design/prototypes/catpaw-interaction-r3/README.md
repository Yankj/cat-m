# Catpaw UX-1 R3 完整交互提案

14 个入口、42 项设计审阅索引。基础样式/场景来自本仓自有 R2，`interaction.js` 和 `interaction.css` 补充拖动、呈现生命周期、过程、稳定卡、表图与 HIL。

```sh
python3 -m http.server 8848 --bind 127.0.0.1 --directory docs/design/prototypes/catpaw-interaction-r3
```

访问 http://127.0.0.1:8848/。默认流式过程。屏框外按钮是人工事件回放；屏框内操作可以实际改变演示状态。无需依赖或网络服务。

推荐：过程展开/暂停→流中卡就绪并填表、回放正文、提交并到安全点→Intelligence 权重/图点/完整表→HIL 版本变化/未知核对→编辑浮层关闭重开/放弃→抽屉拖动和草稿切换。普通菜单入口仍可到成果/跟进/记忆。

所有 ID、数据、回执、处理、审批、队列和跟进为人工内存状态，刷新重置；没有真实执行适配器。原生系统 detents、持久恢复、权限、分享、键盘/安全区、VoiceOver/触觉与性能按原验收实现；部分效果复合对象仅在附录说明。网页不能关闭任何原生或真实产品验收。

依据：[R3 交互附录](../../interaction-scenarios-r3.md)、[机器场景表](../../interaction-scenarios-r3.json)、[R2 视觉参数](../../taste-visual-motion-r2.json)。旧 R2 与日期证据保留。
