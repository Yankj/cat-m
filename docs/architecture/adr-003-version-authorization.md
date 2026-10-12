# ADR-003：不可变成果与事务授权栅栏

状态：v1/r2 合成实现采用，2026-10-11。

Run admission 冻结 scope、输入、模型配置和 policy。operation/run 身份先在同事务预留，再创建 Task，唯一插入失败必须回滚。grant revision/epoch 与 Worker lease 在实际写入/审批事务内重新验证，暂停、撤权或接管后迟到 attempt 不能发布。

Artifact 使用固定 version、canonical body 和 SHA256；回到相同旧内容仍形成新版本和新审批。审批绑定 request、grant、epoch、artifact/hash、目的地/action 摘要及过期时间。修改成果使旧待批准无效；unknown 永久阻止重复决定，只允许核验原效果，`resolved_local` 不提升为远端 verified。

FileRepository 支持单进程事务队列与原子 rename，不能多进程共享写入。SQL 已写行锁/CAS/事务端口，但并发模型通过不能证明真实 PostgreSQL 隔离、唯一键等待、死锁/序列化失败恢复或多实例可靠性。真实 DB 门槛保留在验收待办。
