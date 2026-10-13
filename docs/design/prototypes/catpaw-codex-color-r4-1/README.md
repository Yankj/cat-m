# Catpaw R4.1 配色细节预览

用户提供移动交互研究后的局部视觉修订。直接打开 `index.html`，或从仓库根运行：

```sh
python3 -m http.server 8849 --bind 127.0.0.1 --directory docs/design
```

访问 http://127.0.0.1:8849/prototypes/catpaw-codex-color-r4-1/ 。顶部六组场景与浅深色／放大文字开关保持原R4能力；[原 R4](../catpaw-motion-study-r4/index.html)保留对照。

本目录只有新构图与覆盖样式，读取原R4基础CSS、motion.js、app.js和SVG，避免把呈现引擎复制成另一维护版本。`refinement.css` 的中性灰阶和局部紫色是Catpaw提案，研究采样不是官方Codex tokens。完整取舍见[R4.1说明](../../codex-color-detail-r4-1.md)与[语义参数](../../codex-color-detail-r4-1.json)。

样机仍是人工RAM状态，没有模型／账户／日历／云端请求。网页blur不等于Liquid Glass；辅助文字放大不等于原生最大Dynamic Type。图标发送按钮采用浅紫＋白箭头，仅满足必要图标3:1起点，普通文字按钮采用更强对比。原生落实继续沿[R4交互合同](../../native-interaction-motion-r4.md)，不能用截图关闭产品验收。
