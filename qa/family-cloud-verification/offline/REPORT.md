# 家庭改造离线故障回归 · lane A

**独立验收补充已完成，固定基线目标未通过。** 2026-10-22，固定行为探针 **18/18 PASS**；同一18项的目标断言 **6 PASS / 12 FAIL**，目标模式退出码1被保留。缺陷probe通过只证明现有失败行为被复现，不能签收M0/M1或家庭产品。用户已确认本机此前Goal已执行，其当前代码状态未知；云端不复制主Goal实现、不等待本机摘要或要求停工。正式验收分母和逐项边界见 [验收矩阵](ACCEPTANCE-MATRIX.md)，合成观测、源码Git blob/SHA256和原始输出hash见 [EVIDENCE.json](EVIDENCE.json)。

## 输入、执行与授权

- branch：`test/family-offline-regression`；worktree别名：`family-offline`。只写 `qa/family-cloud-verification/offline/`，无产品、协议、迁移、主计划或其他worktree改动，未提交/推送，由Root统一审阅整合。
- 产品base/candidate：`789ad4feceb0680b8e2e5913083c5b834dc63db1`。执行Goal及技术方案只读自 `2419db9b98e2e3bc0e8c850da62418d216fd3bb8`；报告不改其状态。
- Node `v24.19.0`；未安装依赖，未执行Deno/Swift。本次云任务仅普通离线预验证，没有创建/恢复/替换原生Goal；此云ledger未取得本机Goal ID，故`goal_id=null`，不表示本机不存在Goal。云模型requested=`gpt-6.1-sol`、effort=`ultra`；任务创建接受不等于实际执行证明，effective均为null/UNVERIFIED。此云能力缺口不裁定本机模型/Goal状态。
- [agent配置审计](AGENT-CONFIGURATION.json)保留了一孙级没有显式模型参数的偏差（CONFIG_NOT_EXPLICIT），其新增工作已停止，不纳入运行证据。不能声称全体agent配置门已满足。主lane独立读取源码并运行全部交付测试。
- 所有文本、用户ID、opID、设备参数与模型/SQL响应均合成。子进程环境清空，只注入测试mode、UTC和关闭Node警告。预加载guard拒绝fetch、socket/TLS、HTTP(S)、HTTP2、UDP和DNS；6次主动安全自检均在传输前拒绝，业务用例网络尝试0。没有真实模型/Auth/线上Supabase、部署、外发通知、签名、付费或家庭数据。

## 关键发现

1. `bootstrap.ts:22-30` 缓存 rejected Promise。第1次角色探针失败后，依赖恢复仍在同handler产生100个503，角色查询始终只有1次；健康路径100并发只初始化1次且reserved/released均1。连接错误与JSON探针错误类别未分别注入；stub返回固定JSON类型，不证明真实驱动JSON绑定。
2. `proactive/memory-store.mjs:16-25` claim没有lease恢复。新建worker共用同store后，2个合成60秒周期均不能重领；100条due先丢失前50条claim后，后50条也无法进展。SQL `20261015120000_proactive_tasks.sql:118-130` 存在对应的先LIMIT/后ON CONFLICT路径；这是静态对应，未执行PG。
3. `proactive/service.mjs:69-77` 的4个await/写入交错各运行25次；cancel响应先于event提交，仍得到100个新reminder_due和100次模拟APNs调用。100个task最终仍是cancelled/next=null，说明task状态正确不能代替事件/dispatch围栏正确。
4. `proactive/service.mjs:62` 在event/finish失败后尝试清空due。事件写失败丢失当前提醒；第一次finish失败丢失后续recurrence；两次finish都失败保留event但claim卡住。`service.mjs:23-24` 另复现task_created event失败后同op重试不补事件。claim写前失败、finish写后ack丢失两项持久状态安全目标通过；后者tick仍报fire_failed。
5. `agent-memory/service.mjs:55-60,181` / `memory-store.mjs:24` 没有内容CAS。旧HTTP编辑在await后覆盖较新的已成功更正，并返回200。409目标来自方案，现有v1不支持内容version参数，版本化扩展仍须M0冻结。
6. `agent-memory/service.mjs:113-117,184` 复现clear后在途journal重新写入且下轮召回；原memory_save op在删除后重放也重新创建内容。journal取走fragment后写失败，重试无fragment可用。单行在途update遇DELETE未复活且有sync墓碑，但HTTP返回500 internal_error；这个窄PASS不代表完整删除/错误语义正确。

## 交接运行命令

在任意仅新增QA提交、产品源仍匹配基线的checkout中运行：

```sh
node qa/family-cloud-verification/offline/run.mjs probes
node qa/family-cloud-verification/offline/run.mjs targets
node qa/family-cloud-verification/offline/run.mjs all
```

`probes` 断言固定base的当前行为，本次exit0；`targets` 断言未来应达到的结果，本次exit1；`all` 保留两份输出且因目标失败exit1。修复后的候选应先复核/提交产品源，再显式提供完整commit SHA，沿用同一18项分母：

```sh
node qa/family-cloud-verification/offline/run.mjs targets --candidate <reviewed-full-40-character-commit-sha>
```

runner默认固定base，允许QA提交导致HEAD改变；它校验整个维护functions/migrations相对显式candidate无diff且无未跟踪源，记录候选/HEAD及关键源码blob/SHA256。产品源不符则拒绝生成混合证据，不自动把HEAD当候选。`probes` 的缺陷基线断言在修复候选上可能变红，验收应使用`targets`。退避时长、lease周期与CAS wire冻结后，若调整测试须记录新版本，不能静默改变分母/清除失败。

原始TAP和每run元数据保存在本目录忽略的 `build/family-offline-*/`，精确路径及SHA256在EVIDENCE.json。可提交的EVIDENCE保留18项actual/target与源指纹，不包含凭据或真实身份。runner最多等待每次子进程60秒，不启动监听器或后台任务。

## 验证边界与后续

直接导入真实维护 `bootstrap.ts`、pool wrapper/runtime、proactive service/store、agent-memory service/store；仅替换npm postgres/jose边界和显式模型/APNs/embedding函数，故障在真实store方法前/后注入。业务实现没有拷贝到QA。worker重启是新service对象共用同内存store，没有强杀OS进程或恢复持久数据库。SQL/PG store只作为行号/静态合同证据；未证明事务回滚、多实例、RLS、锁、durable lease/fencing、真实缓存/索引/客户端删除传播、实际识别或通知成功。

仓库layout、冻结源码、部署快照完整性、敏感扫描及`git diff --check`均通过；敏感扫描无blocking/manual-review命中。它们不是产品内容日志0泄漏证据。本lane未运行30条产品trace、真实PG/模型/设备、原生全套或线上manifest，因此这些门保持NOT_RUN/BLOCKED。

交付后的动作归Root：复核测试/矩阵和12项目标失败，按明确路径提交推送验证分支；本机主Goal实现方可选定实际候选后使用显式candidate复验，云端不另开实现主线。当前没有等待权限的执行动作；云模型/编排证明缺口与此固定基线缺陷均已列明，不构成本机Goal停工要求。本lane不承担产品改造、不代签其他lane或本机接受安排。
