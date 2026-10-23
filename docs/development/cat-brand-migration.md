# cat 品牌与兼容标识

产品显示名统一为小写 **cat**。当前原生工程是 `apps/ios-conversation/cat.xcodeproj`，scheme / 主模块 / 产物为 `cat`，扩展为 `catWidgets`；组件模块为 `catNavigation` 与 `catImageComposer`。沿用现有橙色猫头、吉祥物、配色和布局。用户可见文案与源代码类型/文件名同步更新。

## 保留的兼容身份

| 类别 | 保留值示例 | 原因与未来迁移条件 |
|---|---|---|
| 安装与签名 | `com.example.CatpawM.ConversationFirst.Auth`、`com.example.CatpawM.OpenMuseDemo`、原扩展 Bundle ID | 更改会成为另一个 App，影响覆盖安装、签名、推送和本地容器；品牌显示名可独立改为 cat |
| App Group / 后台任务 | `group.com.yankj.catpawm`、`com.yankj.catpawm.proactive.refresh` | 已有共享容器、后台任务与 entitlement 身份，直接改名会失去数据或失配 |
| Keychain 与本地持久化 | `CatpawM-L2`、`CatpawM-ConversationFirst-r7`、`catpaw.*` 默认值/队列/缓存/快照键 | 保留账号凭据、加密密钥、会话、通知与组件数据；未来若改需双读、原子迁移及回滚验证 |
| OAuth / 深链 | `catpawm://`、`catpawm://auth-callback` | 已有 OAuth allowlist、链接、通知、Widget 持续可用；新 scheme 只能作为兼容别名引入，需单独协调外部配置 |
| 服务 / 数据协议 | `catpaw-api`、`catpaw-proactive`、`/catpaw/…`、`X-Catpaw-*`、`catpaw.*.v1`、SQL schema/role | 线上旧客户端、存量记录和服务互通依赖这些值；需版本化双兼容方案，不能随品牌机械替换 |
| ActivityKit | `CatpawWorkAttributes`、`CatpawLeaveAttributes` | APNs 与系统运行时按属性类型识别 Live Activity，保留真实结构名；周围的宿主、文件、组件代码已用 cat |
| 外部配置 | `CATPAW_*`、`CatpawBackendOrigin` 等 Info.plist 键、外部项目 ID | 保留既有本地与部署配置接线；没有复制配置、变更凭据或线上权限 |
| 构建诊断与测试开关 | `CatpawBuildDate`、`CatpawGitSHA`、`-CatpawDemoBackend` 等 | 兼容已有构建诊断/本地验收工具；它们不是品牌显示名 |
| 仓库与旧发行物 | `Yankj/cat-m` URL、历史 `Catpaw-1.2.0.*` 下载名 | 本次不改 GitHub 仓库名，也不伪造已存在的发行物名字 |

`python3 scripts/check-brand-migration.py` 对比迁移前源码，检查显示名、Bundle ID、entitlement、关键字符串、数据库与部署快照。当前检验 472 项兼容约束；这是源码检查，不代替真实旧安装升级验收。

## 历史与归属

冻结 App、部署快照、上游源/版权、受控补丁、原验收报告和截图保持其真实身份。历史 `catpaw-*` 规格/样机路径继续作为稳定引用；编辑后的样机文字不追溯修改原截图或原验收结论。内部 `catpaw*` 标识符的保留原因见 [docs/internal-identifiers.md](../internal-identifiers.md)。

`docs/refs/landing-capability-hub.png` 和 `launch-splash-keyframes.png` 是旧 paw 图标方案的历史设计输入，不是当前 UI、当前图标或新版验收证据。当前视觉以 `docs/brand-theme.md` 与猫头资源为准。`slide-04` 的旧规格文件名、`slide-11` 的线上函数名属于真实引用/兼容服务名。

品牌规范图 `docs/refs/brand/02-brand-sheet.png` 和演示封面 `docs/assets/slides/slide-01.png` 用内置 imagegen 编辑：仅将产品名改为小写 cat，保持原有结构、图标、配色与文案。其余当前 App/Widget 图标和吉祥物不含旧品牌文字，保持原像素。生成图属于设计材料，不能证明原生 App 功能通过。

## 需要另行决策的事项

GitHub 仓库是否从 `catpaw-m` 改为 `cat`，需另行授权并核对 clone remote、CI、Release、文档/深链及外部集成。若未来要求 Bundle ID、scheme、App Group、Keychain 或云函数也彻底去旧名，应作为独立兼容迁移：列出现有安装/数据、双读或别名方案、旧客户端共存周期、回滚与真实升级验证。本次均未变更。
