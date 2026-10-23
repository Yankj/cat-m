# PR #122 品牌身份有限修复 · 2026-10-23

范围：用户单独授权的 mimi / 小咪一致性修复；家庭 Goal 保持暂停。GitHub repository ID `1413057312` 已核实为 `Yankj/mimi`；PR 为 <https://github.com/Yankj/mimi/pull/122>，分支 `feat/mimi-rebrand`，修复基线 `f38140df21e32ab49827f67551d080c098087108`。使用干净 checkout，不根据旧目录名判断身份。

## 修改与保留

- `docs/product/capabilities/cat-capabilities.json`：product / identity 改为 mimi / 小咪，两处主动标签与 iOS 的「小咪发现」一致；能力状态和限制不变。
- `services/edge/supabase/functions/_shared/capabilities.mjs`：用 `python3 scripts/check-capabilities.py --write` 同步数据块；仅另改身份注释。
- `_shared/core/src/tools.mjs`：默认和公开来源聊天基础提示改为 mimi / 小咪。图片回合不注入能力块，仍需正确基础身份；修订/解释专用合同不变。
- `_shared/proactive/model.mjs`、`_shared/proactive/decision-model.mjs`：主动提醒与决策提示仅改品牌，门控、同意、路由和额度不变。
- `packages/ios-navigation/Sources/catNavigation/SidebarPanel.swift`：无 account 时备用显示名改为 mimi；当前宿主总传 account，未声称正式主路径曾显示旧名。
- `scripts/check-capabilities.py`：校验 mimi / 小咪 与用户可见字段的旧品牌；排除内部字段。`services/edge/test/capabilities.test.mjs`：补跨原生/清单、公开来源与日历开关、图片基础提示、实际聊天 provider 入参、主动适配器请求身份断言。
- 根与 iOS `AGENTS.md`：修正显示品牌指令，保留工程/模块身份；本记录与 master-plan 只补本轮接续信息。

保持 `docs/internal-identifiers.md` 原字节。Bundle ID、entitlement、Keychain/容器/存储键、`catpawm://`、`catCapabilities`、`cat.xcodeproj`/scheme/模块、`catpaw-api`/`catpaw-proactive`、`CATPAW_*`、协议/数据库对象和 `X-Catpaw-*` 均未改；历史、冻结源和网站资产名不机械改名。

实际普通聊天链：`catpaw-api/index.ts → bootstrap.ts → api.mjs → foundation-http.mjs → core/src/http.mjs → chat-service.mjs:284/303 → provider system_prompt → openrouter-provider.mjs:76 / free-route-chain.mjs:150`。主动提醒由 `catpaw-proactive/index.ts` 注入两适配器，生成文本进入事件正文。

## 本轮实际命令与结果

Linux / Python 3.12.14 / Node 24.19.0；未安装依赖，未运行 Auth、真实模型、SQL、APNs 或部署。

| 命令（从仓库根运行，另注明者除外） | 结果 |
|---|---|
| `python3 scripts/check-capabilities.py`，原检查/原数据 | PASS，13项；暴露缺乏品牌约束 |
| `cd services/edge && node --no-warnings --import ./test/support/node-strip-loader.mjs --test test/capabilities.test.mjs`，原测试 | 8 PASS，原断言接受旧 cat |
| 同一命令，先更新回归断言、未修产品 | 6 PASS / 6 FAIL，失败准确指出清单、基础聊天、主动两提示和实际 provider 旧身份 |
| 新品牌检查、未修清单 | FAIL，5项身份错误 |
| `python3 scripts/check-capabilities.py --write` 后再不带参数运行 | PASS，13项，同步镜像 |
| 上述能力测试，修复后 | 12 PASS / 0 FAIL；普通聊天实际离线 HTTP fixture 捕获 provider 入参，公开来源/图片路径为组件组合断言，主动两条使用 mock fetch |
| 下面列出的相关 Node 测试命令 | 134 PASS；另1个测试文件因离线 jose stub 缺 `SignJWT` 无法加载；在原基线独立快照复现相同失败 |
| `python3 scripts/check-brand-migration.py` | PASS，472项安装/数据/协议兼容约束；未修改其旧基线逻辑 |
| `python3 scripts/check-deployed-source.py` | PASS，50/43文件快照及14项差异保持 |
| `python3 scripts/check-repository-layout.py` | 基线与本轮均 FAIL：清单把外迁网站位置当成本地路径 |
| `python3 scripts/check-repository.py` | 基线与本轮均 FAIL：冻结 `apps/ios/Sources/Domain/ReadoutPolicy.swift` 哈希不符 |
| `python3 scripts/scan-repository.py` | 基线与本轮命中相同：`docs/brand/png/source-logo.jpg` unexpected_binary；`NativeOAuthTests.swift:106` 人工复核项；本轮修改无新增命中 |
| `python3 apps/ios-conversation/Scripts/validate-project.py` | 环境阻塞：缺 `plutil` |
| `python3 apps/ios-conversation/Scripts/check-localization.py` | 1426 lookup、1772双语条目/插值先通过；随后缺 `plutil`，整体未通过 |
| `python3 -m py_compile scripts/check-capabilities.py`、`node --check services/edge/test/capabilities.test.mjs`、`git diff --check` | PASS |

相关命令（`services/edge` 下）：

```sh
node --no-warnings --import ./test/support/node-strip-loader.mjs --test test/capabilities.test.mjs test/chat-context.test.mjs test/chat-runtime-lease.test.mjs test/chat-stream-budget.test.mjs test/device-call.test.mjs test/task-public-sources.test.mjs test/task-source-http.test.mjs test/task-revision.test.mjs test/vision-route-fallback.test.mjs test/proactive-tasks.test.mjs test/proactive-decision.test.mjs test/proactive-provider-consent.test.mjs test/proactive-route-consent-b1.test.mjs test/proactive-gate-default.test.mjs
```

## 网站、CI 与接续边界

只读核实 `Yankj/heydusk-site`（ID `1341441768`）PR #1，`feat/company-site@04fe6bc317e081ff8df5dac67d0ee241c4ea8ec9`：title/OG 为 `mimi 小咪`、正文为 mimi / 小咪；30个品牌素材 Git blob 与本仓基线一致。未改该仓库分支或部署。网站既有品牌文档链接指向尚未包含 `docs/brand` 的 mimi/main，读取返回404；合并顺序需另行协调，不在此修复。

基线 CI：`ci` [39939031451](https://github.com/Yankj/mimi/actions/runs/39939031451) 成功（iOS成功，Edge跳过）；`Website` [39939031616](https://github.com/Yankj/mimi/actions/runs/39939031616) 已失败，因迁出后 `apps/website/package.json` 不存在。此既存阻塞未扩修。推送后的实际头 SHA 与 CI 结果以 GitHub 读回及本次交付为准，不能套用基线绿色状态。

已检查 workflow：普通 push 本分支不匹配 `release/**` 发布入口；没有已知直接生产发布触发。原 `.githooks` 未启用，未关闭或绕过 hook；旧目的地 allowlist 是独立既存问题，本轮不改。只普通 push 现有 PR 头分支，不 force、merge、auto-merge 或发版。

三路只读审计显式请求支持的 `gpt-6.1-sol` / `ultra`；工具未返回可独立核验的实际底层设置。源码和离线测试不证明线上后端身份、模型回答或真实用户体验；本云环境无 Xcode/Swift/Deno/plutil，Xcode构建、真机与旧安装升级均未在此验证。后续接手先核对 PR 远端头和该 SHA 的 CI，不恢复暂停的家庭开发。
