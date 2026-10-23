# mimi.heydusk.com 部署说明

## Vercel 项目（需团队权限）

当前账号对 Vercel 团队无创建项目权限（此前 403）。请在 [Vercel New Project](https://vercel.com/new) 手动导入：

| 项 | 值 |
|---|---|
| Git repository | `Yankj/mimi` |
| Project name | `mimi-site`（建议） |
| Root Directory | `apps/website` |
| Framework Preset | Other |
| Build Command | `npm run build`（或沿用 `vercel.json`） |
| Output Directory | `dist` |
| Install Command | 默认 |
| Production Branch | `main`（合并 PR 后才上线） |

`vercel.json` 已包含：`framework: null`、`buildCommand`、`outputDirectory: dist`。

Preview：推送到非 main 分支自动生成。Production：合并到 `main` 后生成。

## Cloudflare DNS

在 heydusk.com 区域添加：

| Type | Name | Target | Proxy |
|---|---|---|---|
| CNAME | `mimi` | `cname.vercel-dns.com` | DNS only（灰云） |

然后在 Vercel 项目 Domains 中添加 `mimi.heydusk.com`。

## 公司站外链

heydusk-site 产品页与页脚已外链 `https://mimi.heydusk.com`；旧路径 `/products/cat` 等会 302 到该域名。
