# 主机指纹变更确认与重连实现计划

## 1. 为指纹库建立安全的条件覆盖契约

- 修改 `Packages/ConnPackages/Sources/ConnSSH/HostKeyStore.swift`，增加“仅当当前记录等于 expected 才覆盖”的 API，并保留现有 `remember` 的首次信任语义。
- 更新 `InMemoryHostKeyStore` 与 GRDB 实现，确保条件失败不会改变记录。
- 先在 `ConnSSH`/`ConnStore` 测试中写 RED，再实现；覆盖成功、条件失败、覆盖后 `evaluate` 匹配。

## 2. 保留监控层的类型化主机指纹错误并支持一次重连

- 修改 `Packages/ConnPackages/Sources/ConnMonitor/MonitorScheduler.swift`，新增按主机保存的 `SSHError.hostKeyMismatch` 结构化状态；普通 `errors` 文案继续保留给卡片显示。
- 增加单主机重连入口，驱逐池化会话后只执行一轮采集，避免复用列表全量扫描的重试策略。
- 更新监控测试，验证 mismatch 不丢失 old/new 指纹、成功后状态清理，且不会影响普通错误。

## 3. 接入 App 依赖和服务器列表确认交互

- 在 `AppDependencies` 注入生产环境创建的同一份 `GRDBHostKeyStore`；更新两个测试依赖工厂。
- 在 `ServersViewModel` 增加“条件更新指纹并重连”动作：确认旧指纹仍一致后更新，调用监控单主机重连；条件失败不覆盖并返回可解释状态；同 endpoint 的重复告警同步清理。
- 在 `ServersView` 观察结构化 mismatch，弹出包含现有诊断内容的确认弹窗；取消保持阻断，确认后的新 mismatch 不在同一次操作中自动重复弹出，重新进入页面或主动刷新后再确认；重连完成由现有卡片状态反映。
- 新增的标题/按钮/失败提示统一使用 `L()`，补齐五种语言的 `Conn/Conn/Localizable.xcstrings`。

## 4. 自动化验收

- 增加/更新 `ServersViewModelTests` 以及必要的监控测试，覆盖确认覆盖、过期确认保护、并发采集中确认仍会等待、共享 endpoint 去重和重连成功/失败。
- 增加 `ConnUITests` 的服务器列表指纹变更交互验收；测试不得引入生产环境变量或隐藏绕过校验的代码。
- 先执行针对性 Swift Package 测试和 Conn 单测，之后使用当前已启动模拟器 `DDACC334-4130-4FA3-AC0A-A28B62F71FC1`，固定单并发执行相关 `xcodebuild test`；若现有模拟器 Keychain/数据库故障阻断 UI 启动，保留证据并在交付说明中明确。

## 5. 交付检查

- 运行格式化/本地化覆盖测试和完整相关测试。
- 检查 `git diff`，确认没有修改不相关的终端、订阅或模拟器数据。
- 用户未要求 push，本次只提交工作区实现和测试结果，不执行远程推送。
