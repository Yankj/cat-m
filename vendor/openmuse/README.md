# 固定 OpenMuse 原始源码子集

来源：CopilotKit/OpenMuse，commit `1ac68f3909f2478ab6280883f1ab5ea65eb5719d`。44 个已保存原始文件用于源码归属、机制审阅和 patch 对照；**不是完整上游 checkout，不可据此执行完整 SDK/App**。

[SOURCE-MANIFEST.json](SOURCE-MANIFEST.json) 保留逐文件 SHA256、Git blob SHA1 和固定 commit URL；本轮从已保存官方来源资料重验字节，没有联网重新认证全部源码。原始 [LICENSE](LICENSE) 保留。

本地运行副本在 [patched-openmuse](../../services/facade/patched-openmuse)，差异在 [local-preview.patch](../../services/facade/patches/local-preview.patch)。`scripts/check-repository.py` 在临时目录应用 patch 并比较实际运行文件，不修改此目录。
