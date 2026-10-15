# 对话记忆接线片 · 2026-10-15

候选 `AF-W40-CONVERSATION-20261015-26`，版本 **0.3.0(26)**。源码 `bd06a2f551d27c6cfe23d2ba63f1e7b9b532351e`，已按24条明确文本路径发布到 `feat/s04-conversation-memory`，远端源码 `83466ffa83f5b024cee27ded631decb5294bcb0b`。本片完成可构建源码和离线验证，未安装；用户当前验收仍是build25。实时进度只见 [master-plan](../status/master-plan.md)。

用户明确开启记忆后，新客户端的普通对话可由当前模型调用提出记忆候选，显示“待确认”，进入已有记忆页查看原文来源、范围，再决定是否确认。模型只能提出 `inferred/proposed`，不能直接写已确认事实。工作区范围确认后可在新会话利用；当前对话范围不外溢。更正、忘记和敏感确认沿原有端口。

复用现有source/job/candidate/guard/generation及事务：受理时只冻结当前可信用户消息的精确来源与job，不占普通回答的lease；模型完整终态后，同事务精确claim、提交候选、完成job、保存refs-only回执。现有提交围栏在最后await后复核原许可、scope、runtime与generation。没有第二个提取模型循环，没有额外provider回合。原GET可找回回执，禁止新operation或二次POST。

独立审查发现并修复两个P1：旧客户端闭集工具会拒绝未知事件，因此新增显式合同header，旧请求工具和admission hash保持原字节语义；重复提议会生成重复回执ID，因此在Foundation共有集合输出去重，状态、事件和回执一起保持唯一，未放宽客户端校验。未改字号或页面布局体系。

| 证据 | 结果与边界 |
|---|---|
| 完整维护后端 | 385/385离线PASS，含10条新实际维护HTTP用例与14条提取seam用例；序列化TestRepository和注入provider，不是真实PG/模型 |
| Swift便携对话 | 52断言PASS，含合法/空候选、假Goal、缺typed、篡改内容、失败和冷恢复 |
| Swift记忆合同 | PASS，严格原文/原turn/12字段、0–6唯一候选及22类负例，已有命令journal继续通过 |
| 原生HTTP/SSE | 94断言PASS；36次显式fixture发送=36POST；候选成功和篡改来源均1POST+1原GET，后者保持unknown且拒绝重发 |
| 产品包 | Release通用Simulator编译链接PASS，0.3.0(26)、20文件指纹 `21eb66692f329d1c361b01a59b2c309497bd7c9da626bc3e5bdbcc538a6e1f97`；未启动/安装 |
| SDK／资源 | non-DEBUG typecheck及语法parse在r1分项PASS；r1整脚本随后资源FAIL，不算整轮通过。修正资源到统一catalog后r2双语1077项/113宿主成员PASS |
| 一致性／治理 | 387输入与独立远端索引逐项Git blob一致；布局、冻结来源、部署快照、AF/FINAL/CG合同、字号静态guard、敏感与空白检查PASS |

[RESULT](evidence/conversation-memory-20261015/RESULT.json) 和 [源快照](evidence/conversation-memory-20261015/source-snapshot.json)固定日志hash与来源。包逐文件清单和原日志保留ignored `build/conversation-memory-20261015/`。本片没有新增PNG或上传旧媒体，没有覆盖其他工作树/手机/用户build25。

保留失败：原HTTP缺提取路径；重复候选state1但receipt2；全后台r3过时SQL顺序断言；wire r1未设置现有Node路径；Root先误将文案加到AppIntent专用.strings导致SDK后续资源失败。修复分别落在共用集合、隐私字段集合断言、明确运行环境和统一UIStrings，不把失败轮改写成PASS。

限制：自然语义选取仍需真实模型验证；真实PG多实例、AF-A11两会话/两scope、真实手机、原生完整UI/VO/运动和全部产品门未验。检索仍词法，忘记守卫沿既有主题键，不宣称能识别任意释义；确定性候选回执正文当前为中文。原r7一次真实请求429与本片离线PASS分别保留，不扩大该次授权。API21未部署本片；W40新数据合同不能混入原r7包。AF-A11、AF-G5、FINAL-G3均未签收。
