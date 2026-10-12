# 原生 OpenMuse 客户端实施边界

从 Library 完整 v1 的独立源码副本实施，不修改 CatpawApp 或后端 task-6。
固定上游依据：OpenMuse 1ac68f3909f2478ab6280883f1ab5ea65eb5719d；task-6 的29项离线样件不是运行中的上游。

本轮测试 seam 是 OpenMuseTaskService 的公开 prepare/session/admit/refresh/preview/decide/control/recover 接口与语义 OpenMuseTaskTransport。
先以具名 synthetic fixture 实现垂直行为测试；HTTP 路径、请求体、版本号与鉴权在父线程转交冻结 facade contract 后映射，不自行发明。

- 先保存冻结请求和派发标记，再进行任何创建或审批 transport 调用。保存失败回滚，没有成功事件或外发。
- 重启、断流和404仅读回原任务/审批；不再次创建、不重复审批。业务 operation、businessRun、Task、AG-UI run各有独立身份。
- 权威 Task 读回独立于 AG-UI 的 RUN_FINISHED；tool call只触发读回，不能授权执行。
- 成果按server版本/hash校验，保留历史。审批预览使用同一body与version/hash；点击提交还要校验scope、任务、授权revision、epoch、目的地与action摘要。
- receipt accepted/unknown只可读回，不可新发；server succeeded不是独立副作用核验。
- 暂停和撤权分开。恢复不重授权限；epoch在本地控制提交时改变，迟到结果不能发布。客户端栅栏不等于server撤权成功。
- 新原生页面只显示恢复、审批预览、来源三个状态，沿用设计系统、iOS17与Swift5，不引入WebView/React Native/A2UI。
- 验收分成pure fixture、本地facade、真实Intelligence云和真实模型。只验证实际运行过的层；不创建账号/key、接受协议、部署或签名。

接口冻结前的语义DTO是客户端内部契约，不声称是上游或facade HTTP schema。
