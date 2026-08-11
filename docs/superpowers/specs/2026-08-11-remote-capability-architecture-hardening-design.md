# 远端能力架构补强设计

**状态：** 已确认

**日期：** 2026-08-11

## 1. 背景

`2026-08-10-cross-platform-remote-capabilities-design.md` 已完成 Linux/macOS 平台画像、指标、进程、日志和 Docker 的第一轮适配。实现 review 表明当前 Linux/macOS 主路径可用，但仍有四个需要在 1.0 前补强的边界：

1. 未声明平台限制的片段会被直接判为兼容，Windows 主机可能继续执行 POSIX `sh -c`。
2. `RemoteCapabilityReport` 只存在于模型和测试中，片段兼容检查仍在 UI 内硬编码 Docker。
3. Docker 环境发现和脚本执行尚未形成可替换的平台接口。
4. 真实 macOS SSH 集成测试没有覆盖 SFTP、PTY 和日志流基础连通。

本文是原跨平台设计的补强方案。与原设计冲突时，片段执行、能力编排、Docker 环境提供者和 macOS 集成验收以本文为准；指标、进程、日志和平台画像的既有设计保持不变。

## 2. 目标与非目标

### 2.1 目标

- Linux、macOS 的现有行为和统一输出模型不回归。
- Unknown/Windows 在没有脚本执行 provider 时明确返回不支持，绝不执行 POSIX fallback。
- `sh`、`bash`、`zsh` 保留为有意义的用户选择，并由同一个 POSIX provider 处理。
- UI 不再探测 Docker、拼接 Docker bootstrap 或理解具体能力实现。
- 片段所需能力通过可注入 adapter 解析，并产出 `RemoteCapabilityReport`。
- Docker CLI 发现、权限判断和运行时上下文由平台 provider 负责，且一次准备只探测一次。
- 静默执行和终端执行消费同一份最终远端命令。
- 补齐真实 macOS 主机上的 SFTP、PTY 和日志流验收。
- 为未来 PowerShell、Windows Docker 或更多平台保留新增 provider 的位置。

### 2.2 非目标

- 本轮不实现 Windows 指标、进程、Event Log、Docker 或 PowerShell 执行。
- 不设计一种同时表达 POSIX Shell 和 PowerShell 的跨平台脚本语言。
- 不建立包含指标、进程、日志、Docker、文件和终端的巨型平台 adapter。
- 不建立跨所有 feature target 的中央 provider registry。
- 不把动态 capability 状态长期持久化。
- 不修改 snippet 或 run history 的数据库结构，不新增数据库迁移。
- 不为数据驱动的内置命令 JSON 增加无实际行为的 `CommandCatalogProvider`。

## 3. 设计原则

### 3.1 平台限制与技术可执行性分离

`Snippet.platforms` 表示作者声明的平台限制。空集合继续表示“作者没有额外限制”，以保持现有数据和用户片段语义。

作者没有限制不等于目标主机一定可执行。每次准备执行时还必须满足：

- 当前平台存在脚本执行 provider；
- 所选 `ShellInterpreter` 受该 provider 支持；
- 远端存在对应解释器；
- 所有 `requiredCapabilities` 均为可用状态。

因此 Windows 上的空平台集合片段会通过作者限制检查，但会在脚本 provider 检查处得到结构化的 `unsupportedPlatform`，不会进入执行路径。这个规则不需要修改持久化数据。

### 3.2 功能内窄接口

指标、进程、日志继续由 `ConnMonitor`/`ConnOps` 内现有 provider 负责。新增接口也遵守同一边界：

- `ConnSSH` 拥有脚本执行命令的构造抽象，因为它定义 `SSHSession` 和远端命令执行语义。
- `ConnOps` 拥有 Docker 环境 provider 和 `DockerRuntimeContext`。
- `ConnRunner` 拥有片段准备模型、requirement adapter 协议和 planner。
- App 组合层注入具体 requirement adapter，不让 `ConnRunner` 依赖 `ConnOps`。

`RemoteCapabilityReport` 是模块之间共享的结果值，不是中央 service locator。

## 4. 脚本执行 Provider

### 4.1 接口

在 `ConnSSH` 定义：

```swift
public enum RemoteScriptFamily: String, Sendable, Hashable {
    case posix
}

public protocol RemoteScriptExecutionProvider: Sendable {
    var family: RemoteScriptFamily { get }
    var supportedPlatforms: Set<RemotePlatformKind> { get }
    var supportedInterpreters: Set<ShellInterpreter> { get }

    func interpreterProbeCommand(for interpreter: ShellInterpreter) -> String
    func invocation(for script: String, interpreter: ShellInterpreter) throws -> String
}
```

provider 只描述“如何检查和构造命令”，不持有 session、不负责连接重试、不更新 UI。

增加可注入的 `RemoteScriptExecutionProviderRegistry`。默认 registry 首期只注册 `POSIXScriptExecutionProvider`。选择条件同时包含 `RemotePlatformProfile.kind` 和 `ShellInterpreter`；没有匹配项时返回 nil，不回退到 Linux/POSIX。

### 4.2 POSIX 实现

`POSIXScriptExecutionProvider`：

- family 为 `.posix`；
- 支持 `.linux`、`.macOS`；
- 支持 `.sh`、`.bash`、`.zsh`；
- 使用 `command -v <固定枚举值>` 或等价只读命令检查解释器；
- 使用现有单引号 POSIX 转义将完整多行脚本包装为 `<interpreter> -c '<script>'`；
- 不读取用户输入作为可执行文件名；
- 不依赖交互式 rc、alias 或本地登录 Shell。

`sh`、`bash`、`zsh` 不需要三个 provider。它们共享 POSIX 调用与转义方式，但保留不同的脚本语法和远端可执行文件要求。

### 4.3 清除旁路

当前 `ShellInterpreter.invocation(for:)` 和 `SSHSession.execScript` 会在不知道平台的情况下直接生成 POSIX 命令，形成绕过 provider 的路径。实现时应迁移所有片段调用点，使以下两条路径都只消费 planner 生成的最终命令：

- 静默执行：`SnippetRunner` 调用 `SSHSession.exec(preparedCommand, timeout:)`；
- 终端执行：`TerminalScreen.initialCommand` 接收同一个 `preparedCommand`。

`ShellInterpreter` 继续作为可持久化值类型，不再负责平台相关的命令构造。旧 POSIX helper 若保留，名称和可见性必须明确其仅限已确认的 POSIX 上下文，不能继续作为通用片段入口。

## 5. Docker 环境 Provider

### 5.1 接口与实现

在 `ConnOps` 定义：

```swift
public protocol DockerEnvironmentProvider: Sendable {
    var platform: RemotePlatformKind { get }

    func probe(on session: any SSHSession) async throws -> DockerProbeResult
}
```

默认 registry 提供：

- `LinuxDockerEnvironmentProvider`；
- `DarwinDockerEnvironmentProvider`。

两者可以复用私有 POSIX 探测器、daemon/权限分类和 Compose 检查，但各自拥有可执行文件候选路径。Windows/Unknown 没有 provider 时直接返回 `unsupportedPlatform`，不执行任何 POSIX Docker 命令。

`DockerService.probe(on:profile:)` 可以作为兼容 facade 委托给 registry，但平台 `switch`、候选路径和后续扩展点应位于 provider/registry，而不是 UI。

### 5.2 单次探测和上下文复用

一次 Docker requirement 准备必须同时产生：

- Docker `CapabilityState`；
- 可用状态下的 `DockerRuntimeContext`；
- 可用状态下注入用户脚本前的 Docker bootstrap。

同一次准备不得先通过通用 capability probe 探测 Docker，再由 planner 第二次探测以获取 runtime。容器、镜像、卷、网络、Compose、日志和片段继续复用同一个 `DockerRuntimeContext`。

`DockerRuntimeContext` 和 bootstrap 只在 `DockerAvailability.isUsable` 且 runtime 非 nil 时存在。CLI 缺失、平台不支持、daemon 未运行和权限不足时，adapter 只返回对应的不可用状态，prelude 为 nil。若 availability 声称可用但 runtime 缺失，则按 `.unavailable(.queryFailed)` 处理，不能生成一个不完整的执行计划。

片段 adapter 在一次 probe 内使用 `DockerRuntimeContext` 生成 bootstrap，通用 `SnippetHostPreparation` 只保留生成后的受信任 prelude，不跨模块持有 Docker 类型。Docker 页面继续按现有方式持有完整 runtime；二者都来自各自一次 provider probe，不要求共享跨页面缓存。

## 6. 片段 Requirement Adapter 与 Planner

### 6.1 Requirement Adapter

在 `ConnRunner` 定义与具体 feature 无关的窄接口：

```swift
public protocol SnippetRequirementAdapter: Sendable {
    var capability: RemoteCapability { get }
    var scriptFamily: RemoteScriptFamily { get }

    func prepare(
        on session: any SSHSession,
        profile: RemotePlatformProfile
    ) async throws -> SnippetRequirementResolution
}

public struct SnippetRequirementResolution: Sendable, Equatable {
    public let state: CapabilityState
    public let scriptPrelude: String?
}
```

App 组合层按 `(capability, scriptFamily)` 注册具体 adapter。首期只有 POSIX Docker adapter；它包装 `DockerEnvironmentProvider`，把完整探测结果压缩成统一状态和可选 POSIX prelude。未来新增 requirement 或脚本家族时注册匹配的 adapter，不修改 `SnippetRunView`。

required capability 没有注册与当前 execution provider family 匹配的 adapter 时，planner 为该能力生成 `.unsupported`，不能忽略、乐观通过或复用其他脚本家族的 prelude。adapter 按 capability raw value 的稳定顺序执行和拼接 prelude，避免 `Set` 遍历顺序影响最终命令。

`scriptPrelude` 由受信任的内置 adapter 生成，不接受用户文本。prelude 必须是当前 `RemoteScriptFamily` 的完整脚本片段：只声明函数/变量，或在自身初始化失败时显式终止并返回非零。当前 `.posix` planner 按稳定顺序用换行连接 prelude，随后连接用户脚本；不得全局注入 `set -e`，以免改变用户脚本语义。

### 6.2 准备结果

planner 分为网络准备与纯命令生成两步：

```swift
public struct SnippetHostPreparation: Sendable {
    public let platformProfile: RemotePlatformProfile
    public let capabilityReport: RemoteCapabilityReport
    public let scriptPreludes: [String]
    public let executionProvider: any RemoteScriptExecutionProvider
}

public struct SnippetExecutionPlan: Sendable, Equatable {
    public let auditScript: String
    public let preparedCommand: String
    public let interpreter: ShellInterpreter
    public let capabilityReport: RemoteCapabilityReport
}

public enum SnippetHostPreparationResult: Sendable {
    case ready(SnippetHostPreparation)
    case blocked(RemoteCapabilityReport)
}
```

具体字段名可在实现时按 Swift 类型约束微调，但必须保持以下语义：

- `SnippetHostPreparation` 是针对一台主机的一次只读准备结果，不持有 session；
- 变量值变化只需用最新 rendered script 重新生成命令，不重复远端探测；
- `auditScript` 是用户实际看到的变量渲染后脚本，不包含内部 Docker bootstrap；
- `preparedCommand` 包含稳定排序的 prelude 和脚本 provider 包装，只用于远端执行；
- 静默和终端模式必须消费同一个 `preparedCommand`。

`SnippetHostPreparation` 直接持有已选择的无状态、`Sendable` execution provider，不需要用字符串 ID 从可能变化的 registry 重新查找。它不要求 `Equatable`，也不持有 SSH session。blocked 结果始终携带 report，使 UI 只消费一种结构化错误模型。

### 6.3 数据流

主机被选择后：

1. `SnippetExecutionPlanner` 从 `ConnectionManager` 获取 session 和缓存的平台画像。
2. 初始化至少包含 `.scriptExecution` 的 capability states。
3. 检查 snippet 的作者平台限制；不满足时将 `.scriptExecution` 记为 `.unsupported(.unsupportedPlatform)` 并返回 blocked report。
4. 从 script registry 选择当前平台/解释器 provider；没有匹配项时写入同样的 unsupported 状态并返回 blocked report。
5. 执行解释器存在性探测；不可用时写入 `.unavailable` 并返回 blocked report。
6. 将 `.scriptExecution` 记为 `.supported`。
7. 仅对 `requiredCapabilities` 中除 `.scriptExecution` 外的能力，调用与 execution provider family 匹配的 requirement adapter。
8. 合并所有状态；任一 required capability 为 unavailable/unsupported 时返回 blocked report。
9. 只有全部要求可用时才返回带 execution provider 和 preludes 的 ready preparation。

如果作者平台限制、provider 或解释器检查提前阻断，尚未探测的 required capability 不写入 report；字典中缺少该 key 明确表示“本次未观察”，不能伪造为 unsupported/unavailable。UI 优先展示已经确定的 `.scriptExecution` 阻断原因。进入 requirement 阶段后，planner 应完成全部已声明 requirement 的探测并汇总状态，以便一次展示完整结果。

用户点击执行后：

1. 使用最新变量值生成 `auditScript`。
2. 以 preparation 中的 prelude 和 provider 生成 `preparedCommand`。
3. 危险命令判断继续针对用户脚本，不针对内部 bootstrap。
4. 静默执行将 `auditScript` 写入 run history，但执行 `preparedCommand`。
5. 终端执行把同一个 `preparedCommand` 作为 initial command。

## 7. 能力状态、错误与 UI

### 7.1 状态规则

- `.supported`：允许执行。
- `.degraded`：能力核心功能仍可用，允许执行并展示提示。
- `.unavailable`：当前环境不可用，阻止执行并允许重试。
- `.unsupported`：当前平台/实现不支持，阻止执行。

脚本执行本身加入 `RemoteCapability.scriptExecution`。planner 总是报告该能力：

- provider 匹配且解释器存在：`.supported`；
- provider 不存在：`.unsupported(.unsupportedPlatform)`；
- 解释器不存在：`.unavailable(.executableMissing)`；
- 探测命令成功但结果异常：`.unavailable(.queryFailed)`。

新增 enum case 不改变数据库结构；现有 snippet 不需要显式声明 `.scriptExecution`，因为每次片段准备都会隐式检查。

`.scriptExecution` 是 planner 内建的 intrinsic capability，不通过 requirement adapter registry 查找。若未来或手工数据把它写入 `requiredCapabilities`，planner 使用同一个内建状态满足或阻止要求，不把它误判为“未注册 adapter”。

### 7.2 错误边界

- SSH 建连、通道、超时等传输错误继续抛出并走现有连接错误/重试路径。
- 命令成功执行但能力不可用时返回 `CapabilityState`，不伪装成传输错误。
- Unknown/Windows 没有 provider 时不得执行探测 provider 的平台命令。
- provider 生成的可执行文件名来自受限枚举或固定候选路径。
- 用户变量仍只在 snippet 渲染阶段处理；本文不扩大其权限或改变危险命令确认策略。
- 内部 prelude 不写入用户审计脚本，避免审计记录被实现细节污染。

### 7.3 UI 集成

`SnippetRunView` 只负责：

- 触发/取消每台主机的异步准备；
- 使用现有 generation 防止迟到结果覆盖新选择；
- 保存 `SnippetHostPreparation` 或本地化后的阻止原因；
- 在所有选中主机均 ready 时允许静默/终端执行；
- 展示 degraded 提示和 unavailable/unsupported 原因。

以下状态从 View 删除：

- `dockerRuntimeByHostID`；
- Docker capability 的条件分支；
- Docker bootstrap 拼接；
- `ShellInterpreter.invocation(for:)` 调用。

无 platform/capability 元数据的片段也必须执行脚本 provider 准备，不能再直接标记兼容。

## 8. 缓存与失效

- `RemotePlatformProfile` 继续由 `ConnectionManager` 随 session 池缓存和失效。
- 解释器和 Docker 是动态状态，不写数据库、不放入 `ConnectionManager` 长期缓存。
- 一次 host preparation 内只探测一次，并直接复用于随后执行。
- 主机取消选择、片段变化或 compatibility generation 变化时丢弃 preparation。
- 执行时若 daemon、权限或远端环境已变化，以实际命令结果为准；UI 提供重新检查入口。
- 首期不引入 TTL、后台定时刷新或全局 capability cache，避免在没有测量依据时增加缓存一致性复杂度。

preparation 持有无状态 execution provider 和已生成 prelude，不持有 `DockerRuntimeContext`、session 或可关闭资源。

## 9. 内置命令与持久化

内置命令继续由 JSON 提供：

- `platforms` 表达作者限制；
- `requiredCapabilities` 表达动态前置条件；
- `interpreter` 表达脚本语法选择；
- 新平台命令通过新增 JSON 条目提供。

JSON 是数据目录，不包含平台行为，因此本轮不增加 `CommandCatalogProvider`。平台行为由 script provider 和 requirement adapter 承担。

未来 PowerShell 支持应新增 `ShellInterpreter` raw value、`RemoteScriptFamily.powerShell`、Windows execution provider，以及每个需要 prelude 的 `(capability, .powerShell)` requirement adapter，并继续复用现有 `interpreter` 文本列。没有 PowerShell adapter 的 requirement 必须保持 unsupported，绝不能复用 POSIX prelude。本轮不预先增加 PowerShell interpreter/family case。若未来需要表达 execution policy 而不只是解释器，再由该阶段单独设计迁移，不能在本轮猜测需求。

数据库保持现状：

- `snippet.interpreter` 不变；
- `snippet.platforms_json` 不变；
- `snippet.required_capabilities_json` 不变；
- `run_history.interpreter` 不变；
- 不注册 SchemaV4。

## 10. 测试策略

### 10.1 ConnKit

- `RemoteCapability.scriptExecution` raw value 和 Codable 往返。
- 空 `platforms` 仍表示无作者限制。
- report 保存所有已实际观察的 script execution/required capability 状态；提前阻断时未探测项保持缺失。

### 10.2 ConnSSH

- POSIX registry 对 Linux/macOS + sh/bash/zsh 返回 provider。
- Windows/Unknown 不返回 POSIX provider。
- `sh`、`bash`、`zsh` probe 命令只使用受限枚举值。
- 多行、单引号、变量和特殊字符的 invocation 安全转义。
- 不存在 provider 时不执行任何 POSIX 命令。

### 10.3 ConnOps

- Linux/Darwin Docker registry 选择正确 provider。
- Windows/Unknown 不执行 discovery。
- Darwin Docker Desktop、Homebrew 和 Intel 路径保持覆盖。
- Docker CLI 缺失、daemon 未运行、权限不足分类不回归。
- 一次 provider probe 返回完整 runtime，后续操作继续复用。

### 10.4 ConnRunner

- 无 metadata 的片段仍检查 script provider。
- provider 不存在、解释器缺失和未注册 requirement 分别得到明确状态。
- blocked 结果不携带 execution provider，并保留已观察的 capability report；提前阻断的 requirement 状态保持缺失。
- `requiredCapabilities` 中显式出现 `.scriptExecution` 时使用 intrinsic 状态，不查 adapter。
- `.supported`/`.degraded` 可执行，`.unavailable`/`.unsupported` 阻止。
- 多个 requirement 的 prelude 按稳定顺序拼接。
- 变量变化使用同一 preparation 生成新命令，不重复 probe。
- Docker 等内部 prelude 不进入 `auditScript`。
- prelude 用换行稳定拼接，adapter 自己保证初始化失败时退出；planner 不注入 `set -e`。
- 静默执行执行 prepared command，但 run history 和 `RunOutcome` 保留用户脚本。

### 10.5 App 层

- `SnippetRunView` 不再包含 Docker 分支和 runtime 状态。
- 多主机准备相互独立，单主机失败不阻塞其他探测任务完成。
- generation 失效后迟到结果不写回。
- 静默和终端模式使用同一 prepared command。
- Windows/Unknown 的空平台集合片段显示不支持且按钮不可执行。
- 每个 `DockerAvailability` 到 capability state/prelude 的 App 组合层映射均有测试；不可用状态不得产生 prelude。
- Docker adapter 测试断言每次 preparation 只调用一次 environment provider probe。

### 10.6 真实 macOS SSH 集成

扩展现有环境变量门控的 `MacHostIntegrationTests`，只执行只读操作：

- SFTP：打开子系统并列出配置的 home 路径或 `.`；
- PTY：打开 80×24 shell，发送带唯一 sentinel 的只读 `uname`/`printf` 命令，读到 sentinel 后关闭；
- 日志流：使用专用 SSH session 为 Unified Logging 或 system.log 建立短时 stream，确认通道可建立；测试结束或超时时关闭整条专用 session，以此作为远端命令通道的确定性清理；
- 继续覆盖平台、两轮指标、进程、日志 discovery 和 Docker probe。

测试必须设置明确的超时并在成功、失败、取消路径关闭 SFTP、PTY 和专用 SSH session。当前 `execStream` 没有显式 stream handle，本轮不扩展传输 API；仅取消本地 consumer 不算完成清理，必须关闭该测试独占的 session。缺少真实主机环境变量时 suite 保持明确 skipped，不能作为真实兼容通过。

项目模拟器约束保持不变：不创建、切换、启动、重启或关闭其他模拟器。

## 11. 验收标准

- 完整 Swift Package 测试通过，现有 Linux/macOS fixture 无回归。
- 无 metadata 用户片段不会在 Windows/Unknown 上执行 POSIX 命令。
- Linux/macOS 的 sh/bash/zsh 片段按选择的解释器执行；解释器不存在时显示明确原因。
- `SnippetRunView` 不包含 Docker 探测、Docker runtime 或脚本 bootstrap 逻辑。
- `RemoteCapabilityReport` 在生产片段准备链路中实际使用。
- Docker requirement 一次准备最多调用一次 Docker environment probe。
- Docker 不可用时不产生 runtime/prelude；可用但 runtime 缺失时按 queryFailed 阻止。
- run history 不记录内部 bootstrap，只记录变量渲染后的用户脚本。
- 静默与终端执行使用同一 provider 生成的 prepared command。
- 真实 macOS 环境变量可用时，平台、指标、进程、日志、Docker、SFTP 和 PTY 验收全部通过。
- Windows/Unknown 未实现功能均返回结构化 unsupported，不执行 Linux fallback。

## 12. 实施边界与顺序

1. 为 script execution、Docker environment provider 和 planner 写失败测试。
2. 增加 `scriptExecution` capability 和 POSIX script provider/registry，迁移两条执行路径。
3. 提取 Linux/Darwin Docker environment provider，保持现有 runtime 行为。
4. 在 `ConnRunner` 增加 requirement adapter、host preparation 和 execution plan。
5. 在 App 组合层接入 Docker adapter，简化 `SnippetRunView`。
6. 补齐 package、App 和真实 macOS 集成测试。
7. 运行完整 package tests；仅在用户已启动且可用的模拟器上做 App/UI 验收。

本设计不授权顺带重构其他 SSH、终端、Docker 操作或数据库模块。实现应保留现有工作树中的无关改动，并以最小必要范围完成上述边界。
