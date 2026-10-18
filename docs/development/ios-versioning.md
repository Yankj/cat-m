# iOS 包版本维护

设置顶部的「关于」显示当前安装包的身份：第一行「版本 1.1.0 (build 712)」，第二行「发布于 2026-10-18 07:30」（设备时区）。轻点这一行会展开提交号和构建配置，长按可以「复制版本信息」，用于报 bug。没有构建戳的包（预览、浅克隆的 CI 模拟器构建）显示「开发构建 · 未记录发布时间」；用未提交的改动构建的包显示「构建于 … · 含未提交修改」，提交号带 `+dirty`。界面不写死任何版本。

## 三个来源

| 字段 | 来源 | 谁来改 |
|---|---|---|
| 正式版本 `CFBundleShortVersionString` | `apps/ios-conversation/Configuration/Version.xcconfig` 的 `MARKETING_VERSION`（SemVer 三段数字） | 发版前用 `Scripts/bump-version.sh` |
| 构建号 `CFBundleVersion` | `git rev-list --count HEAD`，由 `Stamp Build Info` 阶段写进打包后的 Info.plist | 自动，不手改 |
| `CatpawBuildDate` / `CatpawGitSHA` / `CatpawGitDirty` / `CatpawBuildConfiguration` | 同一个阶段写入：构建时间（UTC ISO 8601，设置 `SOURCE_DATE_EPOCH` 时用它）、8 位提交号、是否有未提交改动、配置名 | 自动 |

App 和小组件扩展都跑 `Stamp Build Info`，同一提交算出的构建号一定相同（App Store 要求扩展和主 App 的 `CFBundleVersion` 一致）。`Version.xcconfig` 里的 `CURRENT_PROJECT_VERSION` 只是没有完整 git 历史时的兜底值，此时构建日志会给出 warning。源 Info.plist 不再保存提交号，构建也不再改动源码树。

## 日常

```sh
python3 apps/ios-conversation/Scripts/app-version.py show                 # 1.1.0 (build 712) 1a2b3c4d
apps/ios-conversation/Scripts/bump-version.sh patch                       # 1.1.0 -> 1.1.1，并在 CHANGELOG 开新节
python3 apps/ios-conversation/Scripts/app-version.py check --app <CatpawM.app>   # 核对包内版本、构建号、提交号和构建戳
```

改动先记在根目录 `CHANGELOG.md` 的「Unreleased」下。修 bug 用 `patch`，新功能用 `minor`，不兼容的大改用 `major`。构建号不用操心：每个提交都会让它变大，不同工作树在同一提交上算出同一个数。

## 发版

1. `python3 apps/ios-conversation/Scripts/app-version.py release-check`：工作树干净、完整历史（不能是浅克隆）、版本比上一个 `vX.Y.Z` tag 新、上一个 tag 是 HEAD 的祖先（保证构建号单调递增）、CHANGELOG 有带日期的本版本小节、工程接线正确。通过时打印要打的 tag。总的发版检查 `release_check.py` 会调用它（`--json`）。
2. 构建 DeviceTrial/Release 包，再运行 `check --app` 核对包内实际值。
3. 在发版提交上打 annotated tag `vX.Y.Z`（例如 `git tag -a v1.1.0 -m "CatpawM 1.1.0 (build N)"`），推送与 GitHub Release 由负责发版的人确认后执行。

禁止用 xcodebuild 参数覆盖 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`；`Check App Version` 阶段会拦下。以后的 CI 发版流程（#88）必须 `fetch-depth: 0` 并复用这些脚本，不用 `run_number` 当构建号。安装到手机后，从设置读回的版本、构建号和提交号应与发版记录一致。
