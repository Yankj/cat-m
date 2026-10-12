# build 16 覆盖安装记录

2026-10-13。用户明确允许覆盖安装现有 iPhone，并从正常 App 入口用原路由进行最多两次短文本验收、确认模型处理许可。

安装前系统查询确认原应用为 0.3.0(15)。再次核对冻结包为 `a905b47` / tree `74400a57`、0.3.0(16)，binary SHA256 `e1fc81a28fadb6cf061c447e4fa57c9fc0636e350a2bb927e8de2725cf32c86a`；严格签名校验通过。使用 `devicectl device install app` 更新同一 bundle，安装 exit 0，系统读回 0.3.0(16)。未卸载或重置用户数据，未修改证书、profile 或权限。

安装后镜像先提示“iPhone已更改”，连接和一次重试后提示“无法连接iPhone”。已请求用户恢复到原手机的镜像连接；本记录时尚未发送模型请求。原有数据是否正常显示仍需 App 内观察；系统版本读回不能代替许可、完整回复、持久化和重开验收。

本次手机包不包含 PR #2 的流式阅读修复。该修复及部署来源快照已单独合入 GitHub main `58ecfc5` / tree `09004006`，用于后续候选。API v19/tick v7 没有部署变更。

精简结果：[RESULT](evidence/restart-install16-2026-10-13/RESULT.json)。带设备标识的原始安装日志和系统查询只保存在忽略的 `.build/restart-signed16/`；不发布设备标识、认证令牌或用户会话。当前状态见[主计划](../status/master-plan.md)。
