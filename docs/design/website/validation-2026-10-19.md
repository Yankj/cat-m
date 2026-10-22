# 官网验证记录 · 2026-10-19

本记录只覆盖静态官网，不替代 iOS、模型、数据库或真机产品验收。

## 输入与部署身份

- 产品资料核对基线：`cb3bc90a6f35d93e9ad57a6c01c7dc83291d06ee`，v1.2.0。
- 原始视频、25 页 PDF 及图片的来源与 SHA256：`apps/website/ASSETS.md`。
- Sites 源码提交：`bdb9744c4e05e2ca7d55b2c264634b2511d46693`。
- 部署 ID：`appgdep_6ad587972e588191a833aa83fbce5aa9`，原生部署回执为 `succeeded`。
- 地址：https://catpaw-product.kunjie-yan.chatgpt.site 。本次保持站点默认的所有者私有访问；未切换公开访问。

## 验证结果

- `npm run build` 与 `npm run check` 通过：四页、内部链接/锚点、语言、媒体文件完整性。
- Chromium 实际浏览器检查：首页、安全、技术、版本四页在 1440、390、320 像素宽度均无水平溢出或损坏图片。
- 浅色/深色主题、移动导航与 Escape 收起、减少动态偏好、六态小猫切换通过。
- 提醒示例：会议 10:23，提前 20 / 30 分钟分别显示 10:03 / 09:53。纯前端示例，不访问设备或账号。
- 用户原视频实际播放通过：80 秒、1920 × 1080，无播放错误；本地预览服务器支持 Range 请求。
- 最终浏览器控制台：0 错误、0 警告。
- Lighthouse 本地移动端模拟：Performance **99**、Accessibility **100**、Best Practices **100**、SEO **100**；FCP 0.9 秒、LCP 2.0 秒、TBT 0 毫秒、CLS 0。这是实验室测量，不代表公网实际用户性能。
- 仓库布局、冻结来源、部署来源检查通过；敏感扫描零阻断/零待审。新媒体按精确路径和 SHA256 复核，未放宽扫描规则。

原始 Lighthouse JSON、浏览器截图和扫描 JSON 保留在本次任务工作区 `out/website/qa/` 与 `out/website/output/playwright/`，不纳入产品源码目录。

## 范围

没有修改或部署原生 App、Edge 服务、数据库、模型路由或用户账户。GitHub Actions 只独立构建网站并保存静态产物，没有自动发布或生产凭据。网站公开访问和主干合并不包含在此部署回执中。
