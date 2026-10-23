# 重启 build 16 签名候选

2026-10-13。源码绑定 GitHub main `a905b47eb4201e21758fba8a66b6ff01d682e844`，tree `74400a57aeb9cdef72c846726b6f90e0609ceff9`。从 Git archive 独立构建，维护源码未注入生产配置。

DeviceTrial/iPhoneOS，0.3.0 (16)，原 bundle。构建 PASS，非 DEBUG；严格签名校验 PASS。原 certificate/profile/entitlements 全部一致，没有新权限或 provisioning 更新。只从已核对 binary hash 的旧 build15 复用五个公开 Info 配置字段，没有读取令牌、账号状态或用户数据。

IPA `cat-0.3.0-build16-a905b47.ipa`，6,123,236 bytes，SHA256 `e4c79e35025042c03cc06872ff1cb9216820126deb195f082d2e5296537626dc`。ZIP CRC 与所有 App 文件逐字节核对通过；binary SHA256 `e1fc81a28fadb6cf061c447e4fa57c9fc0636e350a2bb927e8de2725cf32c86a`。签名原 profile 到期 2026-10-18T13:11:47Z。

本次准备没有安装手机、调用模型或部署云端。准备过程中的本机 Python 归档参数兼容和证书提取参数问题已修正；最终构建和核对成功。完整日志、原包和 source manifest 保留在忽略的 `apps/ios-conversation/.build/restart-signed16/`；精简结果见 [RESULT](evidence/restart-build16-2026-10-13/RESULT.json)。

后续正常 App 的许可→原 POST→provider→终止回执→存储→UI 才能验收真实模型；本候选不证明 AF-A03 已通过。安装状态和当前进展仅见主计划。
