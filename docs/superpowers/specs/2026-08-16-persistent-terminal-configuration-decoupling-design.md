# 持久终端配置去数据库化设计

**日期：** 2026-08-16
**状态：** 已确认，待实施
**适用范围：** Conn 的 tmux 持久终端能力，以及未来 Zellij、GNU Screen 等 provider

## 1. 决策摘要

Conn 不再为每台 SSH 主机创建或持久化 `TerminalBackendProfile`。支持 tmux、Zellij、Screen 等持久终端是代码能力，不是主机数据；默认 provider 配置由 provider 在运行时提供，远端 Session/Workspace 只在用户选择对应终端类型后实时探测。

本次改造将：

- 删除 `TerminalBackendProfile`、`TerminalBackendProfileRepository` 及其 GRDB 实现；
- 让默认 provider 配置成为不可变的运行时值；
- 让 `PersistentAttachmentDescriptor` 自带重连所需的配置快照；
- 移除 `HostStore.save` 和 App 启动阶段的 tmux 配置创建、补建与查询；
- 删除最终数据库中的 `terminal_backend_profile` 表；
- 保持现有 tmux Control Mode、远端 Session 管理、后台重连和 provider-neutral 扩展结构。

本设计取代 `docs/superpowers/specs/2026-08-12-tmux-integration-design.md` 中关于 durable backend profile、`profileID`、`SchemaV4` 运行时依赖和隐式 default profile 物化的决策。该文档的 provider registry、远端 workspace、attachment 生命周期和 Control Mode 设计继续有效。

## 2. 目标与非目标

### 2.1 目标

- 保存或编辑主机时只处理 SSH 主机、认证和分组数据。
- App 启动和终端主页展示不连接远端，也不创建或查询持久终端配置。
- 用户选择 tmux 后才探测 tmux 并读取远端 Session。
- 默认 tmux 配置不入库；未来内置的 Zellij、Screen 默认配置同样不入库。
- 已打开终端的重连不依赖可变数据库记录。
- 新增 provider 时不修改 `HostStore`、数据库 schema 或 `TerminalSessionCoordinator` 的 provider 分支。
- 保留用户关闭新建终端弹窗时的取消边界，不能留下半创建 Tab 或 provider attachment。

### 2.2 非目标

- 本次不提供自定义 `tmux -L`、`tmux -S`、二进制路径、环境变量或 provider 启动参数 UI。
- 本次不提供用户可保存、排序、启用或同步的启动预设。
- 本次不持久化远端 tmux/Zellij/Screen Session 列表或拓扑。
- 本次不恢复 App 被系统杀死前的本地终端 Tab；`TerminalSessionStore` 继续只存在进程内存。
- 本次不改变普通 PTY、Docker 或脚本终端的生命周期语义。

## 3. 领域模型

### 3.1 ProviderDefinition

Provider 是编译进 App 的能力实现，由 `PersistentTerminalProviderRegistry` 注册，不属于数据库实体。每个 provider 声明：

- 稳定 `providerID`；
- 展示名称；
- 支持的平台与配置版本；
- 可选能力集合；
- 一个内置默认配置；
- probe、list、create、attach 和管理操作。

tmux、Zellij、Screen 都遵循同一个协议。Provider registry 不读取主机数据库之外的配置仓库。

### 3.2 PersistentTerminalConfiguration

以 provider-neutral 的不可变值替代 `TerminalBackendProfile`：

```swift
public struct PersistentTerminalConfiguration: Sendable, Codable, Equatable, Hashable {
    public let providerID: String
    public let configurationKey: String
    public let payloadVersion: Int
    public let providerPayload: Data
}
```

约束：

- `providerID` 必须与消费它的 provider descriptor ID 一致；
- `configurationKey` 是 provider 生成的规范化稳定标识，不是数据库 UUID；
- `payloadVersion` 必须在 provider 声明的支持范围内；
- `providerPayload` 只由所属 provider 编解码；共享层不得解释 tmux 字段；
- 默认值可以重复生成，值相等即表示相同配置；
- 配置不包含凭据，未来如需敏感值只允许携带 Keychain 引用。

tmux 默认配置仍由 `TmuxProviderConfiguration(locator: .default)` 表达，`configurationKey` 为 `default`。

### 3.3 PersistentBackendOption

新建终端 UI 使用本地、静态的 provider 选项替代依赖数据库 profile 的 `PersistentBackendCandidate`：

```swift
public struct PersistentBackendOption: Identifiable, Sendable, Equatable {
    public let providerID: String
    public let displayName: String
    public let configuration: PersistentTerminalConfiguration

    public var id: String {
        providerID + ":" + configuration.configurationKey
    }
}
```

Option 的出现不代表远端已经安装该程序。打开新建终端弹窗只读取 registry；选择具体 Option 后才进行远端 probe。

### 3.4 PersistentAttachmentDescriptor

Descriptor 必须是重连所需信息的自包含快照：

```swift
public struct PersistentAttachmentDescriptor: Sendable, Codable, Equatable {
    public let providerID: String
    public let configuration: PersistentTerminalConfiguration
    public let workspace: RemoteWorkspaceRef
    public let payloadVersion: Int
    public let providerPayload: Data
}
```

删除 `profileID`。Descriptor 与 `TerminalTab.reconnectDescriptor` 一同保存在进程内存；后台重连直接用 descriptor 构造 provider context，不访问数据库。

### 3.5 Runtime Scope

Control Mode 和变更操作仍需隔离不同远端运行实例，但作用域不再使用 profile UUID。tmux runtime scope 由以下字段组成：

- `SSHConnectionIdentity`；
- `configurationKey`；
- `TmuxServerInstanceToken`；
- control generation。

这足以区分不同主机、默认或未来自定义 socket、tmux server 重启和 Control Mode 代次。相关字段与错误从 `profileID` / `invalidProfileID` 重命名为 `configurationKey` / `invalidConfigurationKey`。

## 4. 模块职责

### 4.1 ConnKit

- 删除 `TerminalBackendProfile`。
- 删除 `TerminalBackendProfileRepository`。
- `HostRepository` 和 Host 模型不增加任何终端字段。

### 4.2 ConnStore

- `HostStore.save` 恢复为纯主机事务，只保存 host 与 group membership。
- 删除 `TerminalBackendProfileStore` 和 `TerminalBackendProfileRecord`。
- 数据库最终 schema 删除 `terminal_backend_profile`。
- ConnStore 不依赖 ConnMultiplexer，也不理解 provider 配置 payload。

### 4.3 ConnMultiplexer

- 定义 `PersistentTerminalConfiguration`。
- Provider protocol 暴露内置默认配置。
- Registry 枚举静态 provider options，校验 configuration/provider/version 一致性。
- `PersistentTerminalContext.backendProfile` 改为 `backendConfiguration`。
- Descriptor、Control Mode scope、操作请求和诊断全部移除 `profileID`。
- tmux provider 继续独占 tmux JSON、socket locator、server token 和 Control Mode 协议知识。

### 4.4 ConnTerminal

- `PersistentProviderBackend` 只依赖 registry 和 `ConnectionManager`，不再依赖 profile repository。
- `TerminalSessionCoordinator` 始终可以构造 persistent backend，不再通过可选 repository 决定能力是否存在。
- `NewTerminalFlowModel` 从 registry 获取本地 Option；选择 Option 时才 probe 并读取 workspace。
- `TerminalSessionStore` 继续在内存中保存 descriptor 和 provider attachment 生命周期句柄。

### 4.5 App Composition Root

- `ConnApp` 不构造 `TerminalBackendProfileStore`。
- `ConnApp` 不创建默认 profile，不在启动时补建配置。
- live/demo 只把 provider registry、HostStore 和 ConnectionManager 注入终端协调器。

## 5. 新建终端数据流

1. 终端主页仅展示 `TerminalSessionStore` 中已经连接的普通终端和持久终端，不访问远端。
2. 用户点击新建终端，选择主机。
3. UI 展示普通 PTY 和 registry 中的内置 provider 类型；此时不连接远端。
4. 用户选择普通 PTY：直接沿现有 PTY 创建事务启动，不调用任何 provider。
5. 用户选择 tmux：
   - 通过 `ConnectionManager.platformContext(for:)` 获取同一代 SSH session 与平台信息；
   - registry 校验平台、provider ID 和配置版本；
   - tmux provider probe 可执行文件与 server；
   - provider 实时读取远端 Session 列表；
   - UI 显示 Session 或“创建会话”。
6. 用户选择或创建 Session 后，provider 生成包含配置快照的 descriptor。
7. Coordinator 以 descriptor 打开 attachment，完成后再原子提交本地 Tab。
8. 关闭弹窗、代次失效或打开失败时，临时资源必须关闭，不能提交 Tab。

将来同时注册多个 provider 时，选择 tmux 只探测 tmux，不并行探测 Zellij 或 Screen。

## 6. 重连与远端状态

- tmux/Zellij/Screen server 是远端 Workspace 的唯一事实来源。
- 本地不缓存可作为事实使用的远端 Session 目录；刷新始终重新读取远端。
- 健康 attachment 从后台回前台时保持原连接和 generation。
- 已确认断开的 attachment 使用 Tab 内 descriptor 重连。
- descriptor 配置与 provider 不匹配、版本不支持或 payload 损坏时，返回结构化错误，不回查数据库。
- tmux server instance token 改变表示原 descriptor 已过期；必须重新探测并让用户重新选择，不能静默连接同名 Session。
- Session 在列表展示后被其他客户端删除时，刷新并提示，不自动选择其他 Session。

## 7. 失败与降级语义

- 远端平台不支持所选 provider：显示原因并回退普通 PTY。
- tmux 未安装：按照已确认产品规则自动创建普通 PTY，并给出一次非阻塞说明。
- tmux 已安装但 server 不存在：进入空 Workspace 状态，允许创建 Session；不视为失败。
- SSH、认证、超时或网络错误：留在新建终端弹窗并允许重试；不能伪装成“未安装 tmux”，也不能自动启动 PTY 掩盖连接问题。
- 配置 provider ID 不匹配、配置版本不支持、payload 无法解码：返回 `invalidConfiguration` 或 `unsupportedConfigurationVersion` 一类结构化错误；Debug 可断言，Release 不崩溃。
- 新建或 attach 操作可能已经发往远端但结果不确定时，沿用现有 mutation 语义，不自动重试非幂等操作。
- 用户关闭弹窗时，现有 `TerminalLaunchAttemptID` 取消墓碑机制继续生效。

删除只与数据库 profile 有关的错误：`profileUnavailable`、`providerDisabled`、`identityMutation`、`disabledPrimary` 和 profile scope mismatch。

## 8. 数据库迁移

为了保留当前开发数据库中的主机、密钥、分组和其他数据，不能依赖删 App 或重建整个数据库：

- 保留历史 `SchemaV4` migration，使已应用迁移和新数据库都能走完整有序历史；
- 新增 `SchemaV5`，只执行 `DROP TABLE IF EXISTS terminal_backend_profile`；
- `AppDatabase.migrator` 在 V4 后注册 V5；
- 删除 profile record/repository 运行时代码，但历史 migration 文件可独立保留；
- 新数据库跑完全部 migration 后最终不存在该表；
- 首次正式发布前如决定压平预发布 migration，必须单独执行并重新验证，不属于本次改造。

被删除表中的数据仅是当前未发布实现生成的 provider profile，不包含远端 Session、主机凭据或本地活跃 Tab。迁移不得删除 host 或其他表。

## 9. 扩展路径

### 9.1 新增 Zellij 或 Screen

新增 provider 只需：

- 实现 provider protocol；
- 提供默认 `PersistentTerminalConfiguration`；
- 注册到 registry；
- 实现 probe/list/create/attach 和自身支持的可选 facet。

不修改数据库、HostStore 或 Coordinator 的 provider 分支。

### 9.2 将来增加用户启动预设

只有产品明确提供自定义 socket、二进制路径或启动参数 UI 时，才新增独立 `SavedLaunchPreset`。Preset 是用户主动保存的产品对象，不是 provider 能力存在的前提：

```text
SavedLaunchPreset -> PersistentTerminalConfiguration -> AttachmentDescriptor
```

默认配置仍不入库；已打开 Tab 持有配置快照，因此删除或编辑 Preset 不会破坏现有终端重连。本次不得预先增加 Preset 表或 repository。

## 10. 测试策略

### 10.1 ConnStore

- HostStore 保存、覆盖、失败回滚测试确认不创建或查询 provider 数据。
- SchemaV5 从含 profile 的 V4 数据库升级后：profile 表不存在，host/key/group 数据保持。
- 新数据库完成全部迁移后不存在 profile 表。

### 10.2 ConnMultiplexer

- 配置 envelope 的 Codable、值相等与 provider/version 校验。
- Registry 能从 fake provider 生成默认 Option，且不访问数据库。
- tmux 默认 locator 解码和规范化 key 保持正确。
- Descriptor 配置快照经过编码/解码后仍能打开相同 workspace。
- Control runtime scope 使用 configuration key 隔离不同配置与 server instance。
- 增加 fake Zellij provider，证明新增 provider 不需要数据库或 tmux 分支。

### 10.3 ConnTerminal

- 打开终端主页和加载主机不触发 provider probe。
- 选择普通 PTY 不触发 provider probe。
- 选择 tmux 才 probe 和 list workspaces。
- 多 provider 下只探测用户选择的一项。
- tmux 缺失时按规则降级 PTY；网络错误不降级。
- 创建、attach、取消和代次竞态不留下半创建 Tab。
- 后台重连仅凭 descriptor 完成，不访问 repository。

### 10.4 App

- Composition root 中不存在 profile store、默认 profile 补建或 HostStore 终端配置闭包。
- 新建终端弹窗的关闭、退回、刷新与错误展示保持可用。
- 全量 Swift Package 测试通过。
- iOS workspace `build-for-testing` 通过。
- UI 验收只使用用户已经启动的模拟器，不创建、启动、重启、关闭或切换其他模拟器。

## 11. 验收标准

- 添加、编辑主机不再执行任何 `terminal_backend_profile` SQL，也不会因 tmux 配置崩溃。
- App 启动和终端主页不探测远端 tmux。
- 只有用户选择 tmux 时才读取远端 Session。
- 普通 PTY、tmux attach/create、Control Mode 管理和后台重连保持端到端可用。
- 代码中不再存在 `TerminalBackendProfile`、`TerminalBackendProfileRepository`、`TerminalBackendProfileStore` 或运行时 `profileID` 依赖。
- 最终数据库 schema 不存在 `terminal_backend_profile`，其他用户数据不丢失。
- 新增 fake provider 的测试不修改数据库和 Coordinator provider 分支。
