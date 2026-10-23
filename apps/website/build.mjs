import {readFile,writeFile,mkdir,cp} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=path.dirname(fileURLToPath(import.meta.url));
const read=(p)=>readFile(path.join(root,p),'utf8');
const c=JSON.parse(await read('content.json'));
const escape=(s)=>String(s).replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;').replaceAll('>','&gt;');
await mkdir(path.join(root,'dist'),{recursive:true});
await cp(path.join(root,'public'),path.join(root,'dist'),{recursive:true});
const states=[['idle','等待','等你开口，随时准备帮忙。'],['thinking','思考','思考中，正在理解你的请求。'],['writing','写作','写作中，把想法整理成清楚的文字。'],['executing','执行','执行中，正在处理已确认的操作。'],['done','完成','收到成功回执，这件事办妥了。'],['error','出错','遇到问题，如实说明，等你决定下一步。']];
const faq=[
 ['在哪里下载？需要什么设备？',`小咪是中文优先的 iOS 原生 App，仓库标注 iOS 17+。请通过 <a href="${c.release}" class="inline-link" target="_blank" rel="noopener">GitHub Releases</a> 查看最新安装文件和步骤。本站不提供尚未确认的 App Store 或 TestFlight 链接。`],
 ['它会一直提醒我吗？','不会每件事都响铃。主动建议经过轻重分级、免打扰时段、每日提醒上限和去重。具体时段以 App 设置为准；当前按时提醒通过本地通知送达。'],
 ['和通用 AI 聊天产品有什么不同？','小咪把重点放在 iPhone 上的日程、提醒、记忆与可确认的行动。它能说明为什么来找你，写入前等你确认，办完后留下回执。它不追求替你登录网站、操作电脑或付款。'],
 ['可以关掉记忆，让它忘记吗？','可以。侧栏「了解你」管理记忆，支持开关、查看、更正和忘记。启用记忆不等于自动记住一切；自动保存还有单独开关。'],
 ['它能自己上网、读邮件或打电话吗？','现在只阅读你给的公开网页链接，不自主联网搜索，也不读取或发送邮件。Gmail 和联网搜索在计划中。系统跳转与实际代你完成通话、发送信息是不同能力，不混为一谈。'],
 ['视频里的界面，和现在一样吗？','视频和 25 页 deck 保留 v1.1 的演示。当前 v1.2.0 将侧栏改为「待办 / 记录 / 了解你」，并增加能力说明和跳转按钮。更多变化见版本与资料页。'],
 ['免费模型，意味着产品永久免费吗？','不能这样推断。模型线路有各自的额度与条款，免费额度也可能限流。本站没有虚构订阅价格，也不承诺永久免费；可用性和获取方式以版本说明为准。']
];
const nav=(active)=>`<a class="skip" href="#main">跳到正文</a><header class="site-header"><div class="header-inner wrap"><a href="index.html" class="logo" aria-label="mimi 小咪 首页"><img src="assets/mark.png" width="35" height="35" alt=""><span class="wordmark">mimi</span></a><nav id="main-nav" class="main-nav" aria-label="主导航"><a href="index.html#proactive">产品能力</a><a href="index.html#experience">体验与设计</a><a href="trust.html" ${active==='trust'?'aria-current="page"':''}>安全与隐私</a><a href="technology.html" ${active==='technology'?'aria-current="page"':''}>技术</a><a href="updates.html" ${active==='updates'?'aria-current="page"':''}>版本与资料</a></nav><div class="header-actions"><a href="${c.repository}" class="button" target="_blank" rel="noopener">GitHub ↗</a><button id="theme-toggle" class="theme-toggle" aria-label="切换颜色模式">深色</button><button id="menu-toggle" class="menu-toggle" aria-expanded="false" aria-controls="main-nav">菜单</button></div></div></header>`;
const footer=`<footer class="site-footer"><div class="wrap"><div class="footer-top"><div class="footer-brand"><a class="logo" href="index.html"><img src="assets/mark.png" alt="" width="35" height="35"><span class="wordmark">mimi</span></a><p>先你一步，把事办妥。<br>A step ahead. Things handled.</p></div><div class="footer-links"><strong>认识小咪</strong><a href="index.html#film">观看产品短片</a><a href="index.html#proactive">体验提醒逻辑</a><a href="trust.html">安全与隐私</a><a href="updates.html">版本与资料</a></div><div class="footer-links"><strong>继续了解</strong><a href="${c.repository}" target="_blank" rel="noopener">GitHub 项目 ↗</a><a href="${c.release}" target="_blank" rel="noopener">获取安装资料 ↗</a><a href="technology.html">技术与开源取舍</a><a href="assets/catpaw-product-deck.pdf" target="_blank" rel="noopener">产品 deck ↗</a></div></div><div class="footer-bottom"><span>© 2026 <a href="https://heydusk.com">理想三旬 / HeyDusk</a> · mimi 小咪</span><span>从容，清楚，可靠。</span></div></div></footer>`;
const tokens={REPO:c.repository,RELEASE:c.release,SOURCE_DATE:c.sourceDate,SOURCE_COMMIT_SHORT:c.sourceCommit.slice(0,7),PILLARS:c.pillars.map(p=>`<a href="#${p.anchor}"><b>${p.name}</b><span>${p.text}</span></a>`).join(''),CAT_STATES:states.map(([id,name,caption])=>`<button type="button" data-cat="${id}" data-caption="${caption}" aria-pressed="${id==='thinking'}"><img src="assets/cat-${id}.webp" alt="" width="256" height="256" loading="lazy">${name}</button>`).join(''),FAQ:faq.map(([q,a])=>`<details><summary>${q}</summary><p>${a}</p></details>`).join('')};
const pages=[['index','先你一步，把事办妥'],['trust','安全、隐私与账号'],['technology','技术与产品取舍'],['updates','版本与资料']];
for(const [name,title] of pages){
 let body=await read(`src/${name}.html`);
 for(const [key,value] of Object.entries(tokens))body=body.replaceAll(`{{${key}}}`,value);
 body=body.replace(/<table class="data-table">([\s\S]*?)<\/table>/g, (table,inner)=>{const headers=[...inner.matchAll(/<th scope="col">(.*?)<\/th>/g)].map(x=>x[1]);let column=0;return '<table class="data-table">'+inner.replace(/<td>/g,()=>'<td data-label="'+escape(headers[column++%headers.length])+'">')+'</table>';});
 const url=c.url+(name==='index'?'/':`/${name}.html`);
 const jsonld=JSON.stringify({'@context':'https://schema.org','@type':'SoftwareApplication',name:c.name,description:c.description,operatingSystem:'iOS 17+',applicationCategory:'ProductivityApplication',url:c.url,softwareVersion:c.appVersion});
 const html=`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>mimi 小咪 · ${title}</title><meta name="description" content="${escape(c.description)}"><meta property="og:title" content="mimi 小咪 · ${title}"><meta property="og:description" content="${escape(c.description)}"><meta property="og:type" content="website"><meta property="og:url" content="${url}"><meta property="og:image" content="${c.url}/assets/film-cover.webp"><meta name="twitter:card" content="summary_large_image"><link rel="canonical" href="${url}"><link rel="icon" href="assets/mark.png" type="image/png"><link rel="stylesheet" href="styles.css"><script>try{const t=localStorage.getItem('catpaw-theme');document.documentElement.dataset.theme=t||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light')}catch{}</script><script type="application/ld+json">${jsonld}</script><script src="app.js" defer></script></head><body>${nav(name)}<main id="main">${body}</main>${footer}</body></html>`;
 await writeFile(path.join(root,`dist/${name}.html`),html);
}
for(const file of ['styles.css','app.js'])await cp(path.join(root,'src',file),path.join(root,'dist',file));
await writeFile(path.join(root,'dist/robots.txt'),`User-agent: *\nAllow: /\nSitemap: ${c.url}/sitemap.xml\n`);
await writeFile(path.join(root,'dist/sitemap.xml'),`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${pages.map(([name])=>`<url><loc>${c.url}/${name==='index'?'':`${name}.html`}</loc></url>`).join('')}</urlset>`);
await writeFile(path.join(root,'README-product-section.md'),`<!-- CATPAW-WEBSITE:START -->\n## 产品官网\n\n**${c.tagline}** ${c.description}\n\n[浏览官网](${c.url}/) · [观看产品视频](${c.url}/#film) · [25 页产品介绍](${c.url}/assets/catpaw-product-deck.pdf) · [安全与隐私](${c.url}/trust.html) · [技术设计](${c.url}/technology.html)\n\n${c.pillars.map(p=>`- **${p.name}**：${p.text}。`).join('\n')}\n\n官网源码位于 [apps/website](apps/website)，独立构建与部署。演示素材保留 v1.1 版本；当前入口、状态与限制以 [能力清单](docs/product/capabilities/catpaw-capabilities.json) 和 [CHANGELOG](CHANGELOG.md) 为准。\n<!-- CATPAW-WEBSITE:END -->\n`);
console.log(`Built ${pages.length} pages; video and PDF preserved as provided.`);
