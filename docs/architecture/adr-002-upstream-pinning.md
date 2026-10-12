# ADR-002：固定上游原文与受控运行副本

状态：r2 已采用，2026-10-11。

固定 OpenMuse commit `1ac68f3909f2478ab6280883f1ab5ea65eb5719d`。原文子集、逐文件 Git blob SHA1/SHA256、MIT LICENSE 与修改副本分开存储。统一 patch 可在原文上应用并得到实际运行的修改文件；未修改 log/errors 和 LICENSE 逐字核对。

Worker 增加本轮闭包捕获 `leaseId` 的事件字段，FencedWorkerStore 验 grant/lease；失效事件转 LostLeaseError，普通诊断异常保留。ActionService 仅通过明确 preview 端口避免在合成模式导入完整 zod/model/config；保留审批 claim、expiry 和 unknown 生命周期。不能称当前 Worker 未经修改，不能称新增 `/catpaw/v1` 路由为上游原生 API。

未来升级先换固定 commit 和原文清单，再重建/审阅 patch，重跑契约及授权边界。44 文件是来源子集，不代表完整 SDK 可运行；本轮未重新联网认证全套源文件，也未安装依赖或接受托管协议。
