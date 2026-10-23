# mimi 小咪 产品官网

独立的静态产品网站，位于 `apps/website/`。不依赖原生 App、Edge 服务或模型凭据；Node 20+ 即可构建，无第三方运行依赖。

## 本地开发

```sh
cd apps/website
npm run dev
```

默认地址 `http://localhost:4173/`，可用 `PORT=4174 npm run dev` 指定端口。修改源文件后运行 `npm run build` 并刷新页面。开发服务器支持 MP4 Range 请求。

```sh
npm run build
npm run check
npm run preview
```

## 结构

- `src/`：首页、安全、技术、版本资料的原生 HTML，以及 CSS / JavaScript。
- `public/assets/`：用户提供的视频、PDF、品牌及截图裁切。
- `content.json`：品牌主张、版本基线、官网 URL、GitHub 和下载入口。
- `build.mjs`：生成四页、SEO 元数据、sitemap，以及根 README 的产品介绍块。
- `README-product-section.md`：生成的 README 联动块，以 `CATPAW-WEBSITE` 标记限定替换范围。
- `dist/`：忽略的部署产物，可由任何静态主机独立托管。
- `.openai/hosting.json`：当前 Sites 站点配置，不含凭据。

## 内容维护与 README 联动

1. 核对仓库 `docs/product/capabilities/catpaw-capabilities.json`、`CHANGELOG.md` 和新的演示素材。
2. 更新 `content.json` 的版本、核对日期及 SHA；改动相关 `src/*.html`，明确已交付、限制、计划。
3. 运行 `npm run build && npm run check`。
4. 把生成的 `README-product-section.md` 替换到根 README 的同名标记区间，保留其余工程文档。
5. 检查四页、手机布局、深浅主题、视频、案例按钮和 FAQ。构建不会上传或部署任何产品后端。

原视频与 PDF 保留 v1.1 演示；官网的当前能力说明核对到 v1.2.0。不能因为版本号升到 v1.2 就把旧路线图里所有 v1.2 项目标为已完成。

## 与公司站的关系

- **heydusk.com**（仓库 `Yankj/heydusk-site`）是独立的公司官网，只介绍理想三旬 / HeyDusk，产品列表外链到本站。
- **本目录**是小咪产品官网，域名 `mimi.heydusk.com`，独立构建、独立部署，不并入公司站仓库。

## 独立部署

发布目录是 `dist/`，不需要服务端环境变量、数据库或密钥。配置静态主机时构建命令为 `npm run build`，输出目录为 `dist`（项目根目录为 `apps/website`）。

当前使用 Sites 配置，站点默认仅所有者可访问；公开访问需单独调整站点访问权限。GitHub Actions 仅构建、检查并保存静态产物，不部署 iOS、Edge 或生产数据库。

`content.json.url` 必须与最终域名同步；构建会同时更新 canonical、Open Graph、sitemap 和 README 入口。

## 设计与验证

简约、暖白与橙色的现有品牌；系统字体；深浅主题；减少动态偏好；视频按需加载。素材来源与哈希见 `ASSETS.md`。页面是原生 HTML 内容，不是整页截图。

`npm run check` 检查页面、资源、锚点、语言与原始媒体尺寸；它不替代真实浏览器视觉和交互验证。网站中的交互案例只解释提醒时间推算，不访问账户或写入系统日历。

## Vercel（mimi.heydusk.com）

Vercel 项目 `mimi-site`，Git 连接 `Yankj/mimi`，Root Directory 为 `apps/website`，构建配置见 `vercel.json`（`npm run build` → `dist`）。分支推送生成 Preview；`main` 合并后才生成 Production。

域名：在 Vercel 项目里添加 `mimi.heydusk.com`，再在 Cloudflare 的 heydusk.com 区域添加 `CNAME mimi → cname.vercel-dns.com`（代理状态设为 DNS only / 灰云）。
