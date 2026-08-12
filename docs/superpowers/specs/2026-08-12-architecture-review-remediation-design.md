# 跨平台能力架构复审修复设计

**状态：** 已确认（用户基于 2026-08-12 整体复审结论要求直接修复）

**日期：** 2026-08-12

## 1. 目标

- 平台相关命令只能消费同一次连接池校验得到的 SSH 会话与平台画像。
- 取消日志跟随后必须关闭承载该命令的 SSH 会话，终止远端跟随进程。
- 片段准备与执行计划必须绑定准确的 SSH 连接身份，禁止跨主机或跨连接配置复用。
- Docker 当前明确限定为 Linux/macOS SSH 上的 POSIX 命令执行；不在本轮实现 Windows Docker，但不能把 POSIX 假设伪装成平台无关实现。
- 批量片段最多并发 6 台；危险批量执行必须输入 `RUN`。
- 删除可绕过平台画像的默认 Linux/POSIX 公共入口。

## 2. Docker 边界

Docker CLI 和 Engine 确实存在于 Windows，也支持原生 Windows containers；Docker Desktop for Windows 还可以在 Linux containers 与 Windows containers 模式间切换。但 Conn 当前通过 SSH 向远端 shell 发送字符串命令，现有转义、`sudo -n`、函数 bootstrap 和参数拼装全部属于 POSIX shell 语义。

本轮采用“显式 POSIX、拒绝伪通用”的范围：

- `DockerRuntimeContext` 明确携带 `.posix` 执行家族，并拒绝构造其他家族。
- `DockerEnvironmentProvider` 声明自己的执行家族；默认 registry 仅注册 Linux/macOS + POSIX provider。
- provider registry 使用 `(platform, family)` 选择，Windows/Unknown 不匹配时不执行探测。
- 删除 PATH Docker、默认 Linux profile 等兼容回退；生产调用必须持有平台探测产生的 runtime。
- 未来支持 Windows 时新增 PowerShell 脚本 provider、PowerShell Docker command renderer/runtime 和 Windows environment provider，不复用 POSIX bootstrap。

不在本轮把所有 Docker 子命令重写成跨 shell AST。当前没有 Windows 远端实现，提前设计完整 PowerShell 参数渲染器会扩大风险且没有可运行验收环境。

## 3. 会话一致性与生命周期

`ConnectionManager.platformContext(for:)` 是平台敏感操作的唯一入口。删除单独的 `platformProfile(for:)` 公共入口，迫使调用者同时取得并消费同一上下文。

日志跟随不再占用连接池会话。`ConnectionManager` 提供调用者拥有的 dedicated session；日志 ViewModel 在开始时创建、停止/取消/自然结束时关闭。即使取消发生在握手期间，握手晚到的会话也必须立即关闭。

## 4. 计划身份和批量安全

新增不含秘密的 SSH 连接身份值，字段与连接池 key 保持一致。`SnippetHostPreparation` 和 `SnippetExecutionPlan` 都携带该身份；request builder 与 runner 在产生路由、写审计和发送 SSH 命令前验证目标身份。

批量 runner 使用固定上限 6 的滑动任务窗口。危险批量执行采用带文本输入的确认界面，只有精确输入 `RUN` 才能继续；单主机仍沿用普通二次确认。

## 5. 测试

- ConnectionManager：dedicated session 不进入池、调用者关闭、跳板/认证路径复用。
- 平台消费者：移除分离画像 API后由编译器保证统一上下文接线；保留连接替换竞态测试。
- 日志 ViewModel：停止会关闭 dedicated session；握手后发现已取消也关闭。
- Planner/Runner：跨主机、同 ID 但连接配置变化均在审计与 SSH 前拒绝。
- Batch：记录峰值并发不超过 6，单主机失败不阻塞其他主机。
- Docker：registry 同时按平台和 POSIX family 选择，Windows/Unknown 零命令；不存在默认 runtime。
- App：批量危险确认策略只接受精确 `RUN`。

数据库模型与迁移保持不变。
