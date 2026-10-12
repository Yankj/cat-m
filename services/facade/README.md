# Catpaw façade r2

固定 OpenMuse `1ac68f3909f2478ab6280883f1ab5ea65eb5719d` 的真实 TaskWorker，加一行捕获当前 attempt lease 的事件元数据；ActionService 加受控本地 `catpaw.preview` 解析/执行端口。唯一调度器仍是该 Worker。源码与测试保持 r2 原文，完整差异在 [local-preview.patch](patches/local-preview.patch)。上游原文为仓库 [vendor/openmuse](../../vendor/openmuse/README.md)。

`src/facade.mjs` 保存冻结 Delegation/Run、scope/grant/revision/epoch、operation 身份、不可变 Artifact version/hash 和审批投影。Task/ActionProposal 保持执行与审批权威。HTTP JSON 合同在 [native-contract-v1.json](contract/native-contract-v1.json)，无 SSE/replay。

已有 Node 22.17.1+：

```sh
node --experimental-transform-types src/server.mjs 8787
node --experimental-transform-types --test test/facade.test.mjs qa/tests/negative.test.mjs qa/tests/edges.test.mjs
```

第一条显式启动 `127.0.0.1:8787` 服务并写 `.runtime/synthetic-records.json`；只能运行单个写实例，Ctrl-C 停止。第二条在进程内执行固定 Worker 和模拟 handler，不监听端口、不访问模型。合成鉴权是 `Bearer synthetic-only`，合成 scope 见合同；它们不是用户身份或生产凭据。

可选的 HTTP/重启回归会监听随机 loopback 端口并创建隔离临时数据：

```sh
node --experimental-transform-types --test test/process-http.test.mjs
node --experimental-transform-types --test qa/tests/process-http.test.mjs qa/tests/loopback-negative.test.mjs qa/tests/http-edges.test.mjs
node --experimental-transform-types --test test/revision2.test.mjs
```

这些命令本轮未运行。`test/revision2.test.mjs` 混合内存边界与 HTTP 场景。QA 用例是 r2 独立用例的便携副本，只改 import 和临时目录根；断言保留，原文/副本 hash 在 [PROVENANCE.json](qa/PROVENANCE.json)。测试产物写入被忽略的 `evidence`/`qa/evidence`/`qa/data`。

r2 修复 F01 operation/run 冲突回滚、F02 lease 事件与正常失败诊断、F03 过期审批提交/409、F04 reconciliation 严格空对象。F01 的模型复现已过，真实 SQL 双连接仍待验证。unknown 不允许重发，核验 `resolved_local` 不代表远端副作用已验证。FileRepository 是单进程队列/原子文件提交；SqlRepository/SqlRuntime 已写但未做真实 DB/多实例验收。

本运行路径不安装 SDK、不导入 upstream config/model、不读取 `.env`，不访问 Intelligence/Google/模型或外部写端。Goal/Monitor/真实来源/记忆/持续云调度没有在此接通。MIT 许可不代表用户已接受托管服务协议。
