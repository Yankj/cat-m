# 同身份有界模型检查 r8 · 2026-10-15

本记录固定 `AF-W10-ROUTE-PROBE-20261015-R8` 的源码、离线验证和发布前边界，**没有执行新模型请求、Auth 请求或部署**。当前进度只维护 [master-plan](../status/master-plan.md)。[机器证据](../acceptance/evidence/model-route-review-r8/result.json)含12条源码与原始日志哈希；原失败不被最终通过覆盖。

旧 r7 的一次请求已失败并消耗，原32 token／20秒、固定ID和客户端均不能改参数继续。模型密钥只由现有服务端 `config.modelKey` 使用；本地操作库不获取或复制它。新 r8 是新的固定短文本操作，复用原匿名身份、scope和三项绑定，不复用旧请求或旧许可；仍须新会话明确许可。

| 冻结层 | 身份 |
|---|---|
| 基线 | 实际API21的53文件逐SHA256读回匹配批准的r7归档；tick8未改 |
| r8 API归档 | 55文件，`f210841e8a92151ef210d1f47e5d309022a8e4a9c17fdd54fb6cf26e7ef7e3e4` |
| r8文件集合hash | `ff3df55095a927d8aa2772377583c5b1b81e50040a4a1a1e37dc696acb8a0d49` |
| 原API21回退归档 | `eac493ce38634ef721c69be7cece91c6d0aa1b040f922a1a5247d14e4052c257` |
| 源码同步 | 本地backend `7534a9d`／client `371be02`；远端 `aafd6db`／`bb02476`；选择性tree `7e5a3976f89418c964a95669e7d5c5b69e9a756b` |

部署提案严格从原API21归档生成，不是把39维护后台整包部署。只有四条差异：`_shared/bootstrap.ts` 增加独立具名runtime缓存；新增 `_shared/model-route-review-probe-next.mjs`；纳入现有 `core/src/strict-json.mjs`；旧 `model-route-review-probe.mjs` 的scope-exclusive检查仅限POST，修复加入新会话后旧原记录GET被误拦。原subject/scope/固定GET路径仍核对，旧POST围栏不变。默认API/config/provider/图片/index文件字节不变，tick没有候选更新。

新入口仅已认证的既有subject/scope可达。固定新CID/TID/MID和 `Reply only: received.`，无上下文、附件、记忆、工具或后台kick。OpenRouter → `google/gemma-4-31b-it:free` → Google AI Studio，最多一次provider请求、512 token、30秒；四项max_price均0、单供应商、data_collection deny、require_parameters、禁止fallback和重试。原turn事务与持久操作账本防重复；unknown或429之后只GET原ID。任何错误帧不能被正确末帧洗白，成功必须有实际model/provider、cost=0、完整终态与逐帧验证，缺证据不算成功。

最终维护后台 **498/498 PASS**，新入口16项是子集；客户端 **16/16 PASS**（14故障/合同＋2冻结55文件实际组合），另外同身份刷新库5项注入Auth测试通过。这些均显式deny-net、现有缓存和TestRepository/有限SQL stand-in；没有真实PG多实例或模型。组合路径确实经过客户端→冻结wrapper→原chat/authority→注入provider→SSE/receipt→冷runtime原GET，覆盖成功与429。独立审查复现首版selector阻断旧前缀的P1，第二候选修复；归档、默认路径和三份runtime缓存矩阵通过，先前runner错误保留。

操作入口为 `ModelRouteReviewNextClient`，只通过既有受支持store的load/vault原位使用认证；新operation journal无凭据。默认plan不读store、不联网，不支持signup、scope bootstrap、刷新或部署。Root在忽略目录保存有明确阶段/执行开关的本地操作runner；不把私人机器路径写成公共产品配置。一次本地禁网检查已由原客户端返回 `probe_new_session_unavailable_no_auto_refresh`，没有输出/复制凭据，因此当前不能直接发起检查。

另行准备的 `refreshSameReviewIdentity` 仅在单独批准后使用Supabase标准刷新端点，原身份/原scope/原权限，原位保存到原vault。实际执行前必须由原store journal锁覆盖完整刷新，新独立journal在请求前持久claim；失败或结果未知不重试、不另建身份。库和离线测试不代表已经获得批准或完成刷新。

风险集中在更新同一远端函数、并发/真实PG、现有身份会话与供应商配额。批准后仍须重核API21/tick8及全部基线hash，部署只上传这55文件并保持现有自定义认证配置，逐文件读回一致后才执行具名阶段。出现基线漂移先停止重新审查；部署后不一致时按具体批准恢复原归档，不能从回退自动重发模型。既有会话不可用时先停，不能借更新函数创建身份或扩大权限。

首次提交部署请求被自动审批在执行前拒绝：可信授权被判定只覆盖旧r7，未覆盖精确r8生产风险。未创建新版本，已向用户请求精确包的直接批准，不改用CLI或其他路径绕过；身份刷新批准也独立待定。

本片没有原生包或Simulator安装，用户仍在38；它不会证明App真实SSE、保存/正常重开或Agent工具链完成。AF/FINAL所有未验门保留，旧r7失败记录不改，运行Goal不关闭。
