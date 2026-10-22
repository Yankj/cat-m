# release-ipa · GitHub Secrets（由用户本人在 GitHub › Settings › Secrets and variables › Actions 里设置）

工作流：`.github/workflows/release-ipa.yml`。触发：push 到 `release/**` 或手动 workflow_dispatch；PR 不会触发。
构建号 = `run_number`；版本号读 `apps/ios-conversation/Configuration/Version.xcconfig` 的 MARKETING_VERSION；`CatpawGitSHA` = 当前 git SHA。

| Secret | 内容 | 怎么拿 |
|---|---|---|
| `IOS_SIGNING_P12_BASE64` | 签名证书 + 私钥（.p12）的 base64 | ad-hoc 用 **Apple Distribution**，development 用 **Apple Development**。Mac「钥匙串访问」› 我的证书 › 右键证书 › 导出为 .p12（设密码）。没有证书时：developer.apple.com › Certificates › + 新建（用钥匙串「证书助理 › 从证书颁发机构请求证书」生成 CSR）。然后 `base64 -i cert.p12 \| pbcopy`，粘到 Secret |
| `IOS_SIGNING_P12_PASSWORD` | 导出 .p12 时设的密码 | 自己设定 |
| `IOS_PROFILE_APP_BASE64` | App 的描述文件 base64 | 1) developer.apple.com › Devices › + 注册 iPhone 13 的 UDID（Mac 连手机后 Finder 点设备型号行可看到 UDID；或 Xcode › Window › Devices）。2) Identifiers 注册 App ID（真实可用的 bundle id，比如 `com.yankj.catpaw`，勾选 Push Notifications）。3) Profiles › + › **Ad Hoc**（或 iOS App Development）› 选该 App ID、上面的证书、勾选 iPhone 13 › 下载 .mobileprovision。4) `base64 -i Catpaw_AdHoc.mobileprovision \| pbcopy` |
| `IOS_PROFILE_WIDGET_BASE64` | Widget 扩展（`<app id>.CatpawWidgets`）的描述文件 base64 | 同上，为 `…CatpawWidgets` 再注册一个 App ID 并生成同类型描述文件 |
| `CATPAW_LOCAL_XCCONFIG_BASE64`（可选） | 公开配置 Local.xcconfig（Supabase URL / publishable key / backend origin，非机密） | `base64 -i apps/ios-conversation/Configuration/Local.xcconfig \| pbcopy`；不设则 app 为未配置状态 |

注意：
- 仓库里的 bundle id 现在是 `com.example.CatpawM.OpenMuseDemo`，Apple 不允许注册 `com.example.*`。需要先把 DeviceTrial 配置的 bundle id 改成你注册的 id（App 与 `.CatpawWidgets`），否则导出会因 profile 不匹配失败。
- ad-hoc 选 `release-testing`（默认），development 选 `debugging`；描述文件类型要和它一致。
- 工作流用临时钥匙串（随机密码），结束时删除；不会读取或写入任何 Secret 的值。
- 产物：GitHub Release（prerelease）`v<版本>-build<run_number>`，附 ipa；只能装在描述文件里登记过 UDID 的设备上。
