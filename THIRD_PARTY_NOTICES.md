# 第三方归属与许可

OpenMuse 来源 [CopilotKit/openmuse](https://github.com/CopilotKit/openmuse)，固定 commit `1ac68f3909f2478ab6280883f1ab5ea65eb5719d`。MIT 原文（Copyright (c) 2026 OpenMuse contributors）保存在 [vendor/openmuse/LICENSE](vendor/openmuse/LICENSE) 和 [services/facade/patched-openmuse/LICENSE](services/facade/patched-openmuse/LICENSE)，字节保持一致。

`vendor/openmuse` 是用于机制/patch 核验的原始源码子集。`services/facade/patched-openmuse` 是运行所需受控副本；Worker 事件补捕获 lease，ActionService 加本地 preview 扩展。精确统一 diff 在 [local-preview.patch](services/facade/patches/local-preview.patch)，所有修改仍受上游 MIT 归属约束。

原生客户端与本项目新写 façade/离线适配代码尚未指定对外开源许可；本轮不替用户作许可证授权，也不改变私有仓库可见性。完整上游的其他依赖未打包、未安装，不声明已审查其全部许可。托管服务账户/协议接受仍由用户决定，并未在此轮发生。
