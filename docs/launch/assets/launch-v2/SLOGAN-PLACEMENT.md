# Where the slogan goes

- zh 「先你一步，把事办妥」 (9 characters including the comma)
- en "A step ahead. Things handled." (29 characters)

Pointers are into 仓库 @ 5ff3adde（旧集成分支 feat/status-line） (`apps/ios-conversation/…`) unless noted. Rule: **one slogan, few places**. It's a brand line, not UI copy, so it never sits next to a real task.

| # | Place | Pointer | Use? | Exact copy / note |
|---|---|---|---|---|
| 1 | **Launch screen** (every launch, ≈ 0.2 s visible after the snapshot) | `Resources/LaunchScreen.storyboard` → `Base.lproj/` + `en.lproj` / `zh-Hans.lproj` `LaunchScreen.strings`; first frame `CatpawLaunchStatic.swift` | **Use** | zh 「先你一步，把事办妥」 / en "A step ahead. Things handled." System 17 Regular, calmSecondary. Spec in `SPEC.md` |
| 2 | **Onboarding brand subtitle** (first run) | `Sources/Features/NativeLoginView.swift:164` `Text(ui("你的个人 AI 助手"))` (FirstRunAppearance text id at `Onboarding/FirstRunAppearance.swift:30`) | **Use: replace this line** | 「先你一步，把事办妥」 / "A step ahead. Things handled.", same caption font and calmSecondary. The serif headline at `:168` (「解放双手，让工作自己向前走」) and the subcopy at `:175` stay; they explain, the slogan brands. Also update the contrast id string at `FirstRunAppearance.swift:30` |
| 3 | Onboarding serif headline | `NativeLoginView.swift:168` | **Don't use** | Keep the headline. Two taglines stacked would compete |
| 4 | **Settings → 关于 (About)** | `Sources/Features/ConversationFirstView.swift:1359` `Section(ui("关于"))` | **Use, as the section footer** | `Section { … } header: { Text(ui("关于")) } footer: { Text(ui("先你一步，把事办妥")) }` → "A step ahead. Things handled." Default footer style, below 版本 / 构建号 |
| 5 | Empty chat (starter screen) | `Sources/Features/ConversationFirstView.swift:345` and `Sources/App/CatpawApp.swift:298` 「想一起完成什么？」 + the subtitle 「问一个问题，或说一件想做的事。」 | **Don't use** | Too much. The user has just seen it on the launch screen 0.2 s earlier, and here the screen's job is to prompt an action. A brand line above the starters reads as an ad |
| 6 | **App Store subtitle** (30-character limit) | App Store Connect metadata (not in the repo) | **Use** | zh-Hans 「先你一步，把事办妥」 = 9 / 30 ✓; en "A step ahead. Things handled." = **29 / 30** ✓ (counted with Python `len`). Don't add an emoji or extra spaces, because en has 1 character to spare |
| 7 | App Store promotional text / first screenshot caption | ASC (not in the repo) | **Use** | Screenshot 1 headline = the slogan; the description opens with it on its own line |
| 8 | **Demo deck cover** | 旧版 deck（demo-deck.html:148，不在仓库） (currently 「把交代的事，变成可用成果。」) | **Use: replace line 148** | 「先你一步，把事办妥」. Keep `:147` 「主动式个人 Agent · v1.0」 as the descriptor. Optionally end the closing slide with it too |
| 9 | Home-screen widget placeholder / gallery | `Widgets/CatpawWidgets/CatpawHomeWidgets.swift:35` `placeholder(at:)`; `:136` `placeholder(in:)` | **Don't use in the placeholder** (it's redacted to shapes anyway). **Use as the widget-gallery `.description(...)`** only if the description isn't already more useful; recommended no, keep the functional description | — |
| 10 | Live Activity / Dynamic Island | `Widgets/CatpawWidgets/CatpawWorkLiveActivity.swift` | **Don't use** | That surface shows live task status only. A slogan there would be noise on the lock screen |
| 11 | Share sheet (`ShareLink` of answers/artifacts) | `Sources/Features/ConversationAnswerView.swift:86`, `ConversationArtifactReaderView.swift:74` | **Don't use** | Don't append marketing to the user's shared content. If a share *preview* title is ever added (`SharePreview`), use "Catpaw", not the slogan |
| 12 | App display name / Info.plist | `Resources/Info.plist:11` `CFBundleDisplayName`; `*/InfoPlist.strings` | **Don't use** | The name stays "Catpaw". Permission strings stay functional |
| 13 | Notifications (proactive) | — | **Don't use** | Every notification must say what it's about |
| 14 | Website / press kit / email signature | outside the repo | **Use** | Same copy; en sentence case, with the two full stops |

Copy rules:
- zh uses a full-width comma 「，」 and no final full stop.
- en is two short sentences, each ending with "." ("A step ahead. Things handled."); don't Title-Case it.
- Never translate it ad hoc. Always pull it from `UIStrings.json` key 「先你一步，把事办妥」 (or the launch `.strings`).
- Never in orange; ink or calmSecondary only.
