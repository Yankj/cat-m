# 演示素材索引（2026-10-18，UTC+8）

所有路径都相对仓库根目录（github.com/Yankj/catpaw-m）。每条都注明在哪个分支：

- **docs/launch-brief**：本分支，`docs/launch/` 下的所有文件（本索引、brief、复制进来的素材）。
- **main**：已发布基线（694d19e）。
- **chore/v11-integration**：v1.1 最新集成分支（语音、实时文字、账户菜单、开屏登录、吉祥物动画等）。

缩写：`ios/` = `apps/ios-conversation/`，`L/` = `docs/launch/assets/`（本分支）。

## 用户提供（docs/launch-brief）
- `L/user/brand-board.png`：logo、品牌主张、色板（#FF702A #C64A0B #FFFCF8 #292622 #929298）、字体
- `L/user/splash-dark.png`：深色启动页，logo 加「先你一步，把事办妥」
- `L/user/mascot-sheet.png`：毛绒小猫 6 个状态，以及在 App 里的用法

## 品牌与图标（main，集成分支相同）
- App 图标：`ios/Resources/Assets.xcassets/AppIcon.appiconset/`（light / dark / tinted）；重新生成脚本 `ios/design/brand/regenerate_appicon.py`
- 品牌资源：`ios/Resources/Assets.xcassets/CatpawBrand/`（BrandMark、BrandMarkFill、BrandMarkOnOrange）
- 启动页资源（chore/v11-integration）：`ios/Resources/Assets.xcassets/LaunchBrandHead.imageset`、`LaunchGlyph.imageset`、`LaunchMark.imageset`、`LaunchBackground.colorset`、`LaunchCanvas.colorset`
- 品牌规范：`docs/brand-theme.md`；参考图 `docs/refs/brand/`（01-icon-hero-3d、02-brand-sheet、03-flat-mark-black、extracted-flat-mark、extracted-white-mark）
- 3D 场景起始图标（docs/launch-brief）：`L/starters/icons-preview.png`、`L/starters/current-starters.png`、`L/starters/mockup-{light,dark}.png`，单个图标 `L/starters/icons/{breakdown,coffee,meeting,reminder,report,schedule}.png`

## 小猫
- 静态图（main）：`ios/Resources/Assets.xcassets/CatpawBrand/Mascot/Mascot{Idle,Thinking,Writing,Executing,Done,Error,Front}.imageset`；集成分支另有 `MascotFrontBlink.imageset`
- 动画 `.mov`：`ios/Resources/Mascot/Mascot{Idle,Thinking,Executing,Done,Error}.mov`（每段 11–65 KB）。
  - **注意**：这 5 段目前还没进 chore/v11-integration（正在集成，推上去后就在该分支同一路径）。在那之前，可以从 `feat/chat-send-snappy` 分支的同一路径读取（例如 `git show origin/feat/chat-send-snappy:apps/ios-conversation/Resources/Mascot/MascotIdle.mov > MascotIdle.mov`）。
  - 弹出动画 CatpawMascotPopHold 同样在集成后才进 chore/v11-integration。
- 渲染代码：`ios/Sources/DesignSystem/CatpawPlushMascot.swift`
- deck 用的小猫和图标（docs/launch-brief）：`L/deck-v3/brand/{plush-front,plush-back,state-1..6,icon,scales}.webp`

## 启动页设计（docs/launch-brief）
- `L/launch-v2/mockup-{light,dark}.png`、`mockup-{light,dark}-en.png`、`sizes-sheet.png`
- 过渡动画：`L/launch-v2/transition-{light,dark}.{mp4,gif}`
- slogan 放在哪、为什么少放：`L/launch-v2/SLOGAN-PLACEMENT.md`

## 真实界面截图（docs/launch-brief）
- `L/deck-v3/screens/*.jpg`：对话（chat-e9e2）、v1.1 图片授权（consent-v11）、首次启动（firstrun-sim）、启动页（launch-*）、起始图标（starters-sim）、卡住时序（stall-t09s/t17s/t20s）、未完成（unfinished）、未发送（unsent）、顶栏（header-e9e2）
- 消息内状态与授权弹窗：`L/inline-status/C-consent-sheet-v11-{light,dark}.png`、`E-status-variants-{light,dark}.png`、`D-unfinished-light.png`、`B-longpress-light.png`
- 早期验收截图（main，界面比 v1.1 旧，只作参考）：`docs/acceptance/evidence/`、`docs/assets/ios-v1/`

## Deck v3（docs/launch-brief）
- 可直接打开的单文件 deck：`L/deck-v3/demo-deck-v3.html`（图片已内嵌）
- 全部 30 页渲染图（JPEG）：`L/deck-v3/renders/slide-01..30.jpg`，含 `slide-07-step1..3.jpg`
- 讲解稿：`L/deck-v3/NARRATIVE-v3.md`
- 已知问题：一半以上篇幅是状态和部署记录，没讲实时文字，部分信息过时（还写着 v52、授权只按单个对话），不少截图是占位图。以 BRIEF-v2 为准。

## 产品视频 animatic v2（docs/launch-brief）
- 主版 80 秒：`L/video/animatic-v2.mp4`；竖版 20 秒：`L/video/animatic-v2-20s-9x16.mp4`
- 字幕：`L/video/subtitles-{main80,cut60,vertical20}.srt`
- 镜头总览：`L/video/contact-sheet-v2-{main80,vertical20}.jpg`
- 已知问题：开头是竖屏录屏放进横屏，左侧大片空白；「为什么需要它」讲得薄；缺实时文字和图片授权两个亮点；需要用最终版重新录界面。

## 不在仓库里（没有复制）
- 旧版 animatic v1（`animatic-v1`、`-60s`、`-20s-9x16`）和 v1 关键帧：被 v2 取代。
- animatic v2 单帧关键帧（约 8.7 MB）：用 contact sheet 代替。
- 背景音乐（约 7.8 MB，授权情况未核实）、模拟推送文件、Remotion 工程源码和时间线 `beats.json`。
- 录制手册 MAC-RECORDING.md 和视频计划 PLAN.md：内容依赖团队内部的机器路径。
- 片场的 Grok 生成测试图（还在做）。
- 其余 inline-status 截图（旧版授权弹窗、A-unsent、深色版 D/B 等）、deck v3 的其他配图目录（base、cap、fr、la、loader、media、mem、sl、v11）、旧版 deck v1/v2。
- 3D 起始图标的源文件、补丁和 @2x/@3x 切图（已合入代码的版本见 `ios/Resources/Assets.xcassets`）。
- 启动页 v2 的 SPEC.md 和资源工程（已合入代码的版本在集成分支）。
- 今早的真机问题截图（device-0728），与发布材料无关。
- 旧版启动动画 launch-anim.mov：已过时，不用。
