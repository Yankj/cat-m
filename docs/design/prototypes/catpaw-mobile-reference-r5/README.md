# mimi R5 移动端对话样机

参考用户提供的10张手机截图，呈现蓝色动作、中性阅读、字体与间距、处理过程和对象菜单。入口为 `index.html`。从仓库根复用本地预览服务：

```sh
python3 -m http.server 8849 --bind 127.0.0.1 --directory docs/design
```

访问 http://127.0.0.1:8849/prototypes/catpaw-mobile-reference-r5/ 。十组场景、六种处理状态、浅深色／放大字／降低透明度／键盘占位可操作。语音对话不纳入。

本轮只增加 `index.html`、`mobile.css`、`mobile.js`，读取原R4基础CSS／motion.js／app.js／SVG与R4.1覆盖层；原日期候选保留。[完整设计与能力边界](../../mobile-conversation-reference-r5.md)、[参数](../../mobile-conversation-reference-r5.json)为实施入口。

所有内容、计数、文件、过程、菜单与回执都是本地人工样例。连续回放使用本机计时，没有模型或搜索请求；消息／来源／附件操作不读取外部内容。相机、重新回答和空间管理未接通；归档与删除只预览，不能执行。键盘是几何占位；系统玻璃、IME、VoiceOver、真实任务控制与持久恢复仍需原生实现和验收。
