# Changelog

CatpawM iOS 版本记录。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

- 正式版本 `X.Y.Z` 只来自 `apps/ios-conversation/Configuration/Version.xcconfig`，用 `apps/ios-conversation/Scripts/bump-version.sh major|minor|patch` 修改。
- 构建号自动等于 git 提交数，不用手改；设置 › 关于里显示「版本 X.Y.Z (build N) · 发布于 日期 时间」。
- 发版打 tag `vX.Y.Z`，发版当天把本节标题里的「未发布」改成日期，`app-version.py release-check` 会核对。
- 平时的改动先记在「Unreleased」下面，发版时 `bump-version.sh` 会自动把它们归到新版本。

## [Unreleased]

## [1.1.1] - 未发布

在 1.1.0 基础上的修复版本，功能不变。

### 修复
- 标题过长时溢出、显示不全的问题。
- 时间显示格式不正确的问题。

## [1.1.0] - 2026-10-18

v1.1：从 0.3.0 (build 41, 2026-10-16) 之后的第一个版本，累计约 370 个提交。

### 新增
- 语音对话：声波按钮进入语音模式，本机识别、静音自动结束、可打断，语音回复默认开启。
- 实时流式回复（需 catpaw-api v53，`X-Catpaw-Live-Text: 1`），点「停止」只擦除已显示的文字。
- 侧边栏顶部账户下拉菜单：当前账户、切换/添加账户（Google / GitHub）、退出登录；设置页不再有账户面板。
- 起手提示与 3D 图标，状态行小猫和工具徽标，Live Activity 显示任务标题。
- 版本管理：构建号自动递增，设置 › 关于显示版本、构建号和发布时间，长按可复制提交号。

### 修复
- 开屏登录卡在开屏页（点按钮或谷歌登录后不进入对话）。
- 发送转圈要等整条回复结束才消失；没收到回复的消息显示「没有收到回复 · 点按重发」。
- 图片限流不再卡住；上下文过长（413）给出「新开对话」，历史冲突（409）可重发。
- SwiftData 删除行崩溃、冷启动卡住、切账户时数据隔离等稳定性问题。

## [0.3.0] - 2026-10-16

最后一次手动改构建号的版本（build 41，`21e6b8c`）。之前的构建号 1–41 由 `app-version.py bump` 手动递增，没有打 tag。
