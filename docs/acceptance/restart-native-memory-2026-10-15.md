# 原生记忆阶段版 · 2026-10-15

交付候选 `AF-W40-NATIVE-20261015-25-R6`，版本 **0.3.0(25)**，源码提交 `0fc8c6958c4ffba6f88ca31d0cd565a9f439f59b`。本片通过有边界的原生与离线验证，AF-A11、AF-G5、FINAL-G3仍未签收。当前进展只维护在 [master-plan](../status/master-plan.md)。

用户可从对话左上菜单进入“记忆”，明确开启利用，核对并保存当前对话或工作区偏好，查看原来源、更正和忘记。未确认草稿可冷恢复；提交丢响应后仅读取原操作，不重复发送。记忆接现有 Foundation 的 source、claim、candidate、generation、guard与 scoped transaction，没有第二套权威。

在本交付工作树运行：

```sh
zsh apps/ios-conversation/Scripts/run-simulator-review25.sh resume
```

默认恢复同一客户端，固定复用已有 `Catpaw-r5-conversation-qa`（BE5C60E0-B415-4BF4-8F36-8975FB5314AA）；已安装完整包字节匹配时跳过安装。`work`仅在明确需要另一份本地QA草稿时创建新客户端，不创建模拟器，旧客户端保留。脚本固定8769的原normal-r3服务、账号/scope及原会话到期时间，不启动服务或续权，不自动填发、批准或POST。实际work→resume客户端一致，启动前后memory POST为7→7、provider为0→0，系统字号恢复large。build24的设备、包和8767/8768服务保留。

| 检查 | 实际结果与范围 |
|---|---|
| 维护后端 | 361/361离线PASS；实际维护HTTP/领域代码，合成身份、注入provider、序列化TestRepository |
| 原生构建 | non-DEBUG SDK检查PASS，113个App源成员、1071双语项；Build25-r2测试构建PASS |
| 新记忆宿主 | 7方法PASS，来自r2混合运行中的成功分项；该轮后续UI失败/诊断中断不算整轮PASS |
| 受影响服务宿主 | 6类35方法PASS，含计划草稿、审批、成果更正、控制恢复及生命周期围栏 |
| 默认UI r6 | 审阅关闭、冷草稿、真实维护来源、更正、忘记/回执PASS；恰3次命令POST、provider不增 |
| 最大系统字号UI r6 | 真实accessibilityExtraExtraExtraLarge、实际可见稳定软键盘、编辑区至少44pt可见、完整审阅与固定确认/关闭可达PASS；不宣称全部光标/全App/动效已验 |
| unknown UI r3 | 原命令受理后丢响应，冷启动仅GET原ID找回成功；1POST、1原操作GET，零二次POST |
| 固定输入与敏感检查 | 384源/辅助输入逐项hash一致；30文件包不变；1131候选0阻断/0待审 |

42项宿主与3项UI来自不同具名运行，产品App完整包指纹相同，不是一次调用全通过。r2之后只修改UI自动化helper及辅助启动脚本，未更改产品App字节。完整30文件bundle SHA256：`7bbf2741c12ddf7753f665d210513c3efd009af75bb6b6ba1422b4300a92138b`。机器判定、每项日志hash和9个本地附件见 [RESULT](evidence/native-memory-20261015/RESULT.json)、[源快照](evidence/native-memory-20261015/source-snapshot.json)、[包清单](evidence/native-memory-20261015/package-files.json)。8张PNG和1份几何文本保持ignored本机目录，未上传媒体。

共同机制修复包括：Swift/JS数字与Unicode规范化使用系统JavaScriptCore固定函数，JSON作为数据输入；同一原RED哈希最终两端451911…一致。未知4xx必须保留原UUID，只有严格具名且能证明未受理的拒绝可重核。服务以可信actor绑定不可变记忆subject并验证原source，封堵同scope他actor忘记/关闭漏洞。草稿epoch防迟到flush复活已提交/忘记内容；Root每次跨actor跳转重新核对生命周期准入，页面不能重新授予网络权。

包清单的生成图标名被扫描器误判为邮箱；核对后仅追加精确path/line/hash例外，模式未放宽。384源输入仍固定到源码提交，随后这一项治理元数据变更另列于RESULT。

历史失败均保留：SDK r1声明失败；SDK r3编译中输入被改而失效；r2旧夹具丢scoped transaction重载导致state500、两UI失败、最终诊断SIGTERM143；r3/r4测试误选键盘预测条ScrollView；r5图片没有软键盘及默认弹层过渡。最终改为绑定页面viewport、测量键盘候选栏、等待真实键盘与稳定确认区，不逐页降低字号。原失败日志/像素不覆盖。

限制：尚无自然语言抽取接线，检索沿现有词法机制；真实Auth、PG多实例、模型、手机、跨对话记忆使用未由此验收。时间有效性在provider前核对；纯时间到期且generation不变的调用中间边界仍待专项，不能扩大为完整记忆验收。忘记清除主记忆/派生利用并防旧来源学回，不抹除普通聊天历史或召回已发provider的数据，备份清除未核验。W40扩展数据范围会改变routeHash，旧模型许可无效；独立r7路由候选固定旧合同，不得混合部署。

下一步按用户点测反馈修订，并继续真实W10–12/CP-01、W40自然对话接线、独立调度CP-02、系统日程CP-03及同版AF/FINAL门。生产部署与新手机包沿明确授权分别准备。
