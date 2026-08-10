# 跨平台远端能力抽象设计

**状态：** Proposed  
**日期：** 2026-08-10  
**范围：** Linux、macOS；Windows 仅预留扩展接口和未支持状态

## 1. 目标

当前 Conn 的 SSH 传输层可以连接 macOS，但主机观测、进程、日志和内置巡检直接依赖 Linux 命令及 `/proc` 文件系统。目标是把远端平台差异收敛到可替换的能力提供者中：

- Linux 继续支持当前 GNU/BusyBox 采集行为。
- macOS 完整支持主机指标、进程、系统日志、内置命令和 Docker（在远端 CLI/权限满足时）。
- Windows 本轮不实现具体采集，但类型、注册表和状态模型可以承载未来 PowerShell/CIM 适配器。
- UI 只消费统一模型和能力状态，不拼接平台命令。
- 缺失能力必须明确显示为未支持、命令不可用或权限不足，不能把缺失数据伪装成 0 或正常。

## 2. 非目标

- 不替换 Citadel 或重写 SSH 握手协议。
- 不把远端所有命令抽象成一个跨平台 Shell 语言。
- 不在本轮实现 Windows 的性能采集、Event Log 或服务管理。
- 不改变用户自定义片段的执行语义；用户脚本仍由用户自行负责目标主机兼容性。
- 不把 Docker 容器内部的 Linux 观测误认为宿主机观测；宿主机能力仍由宿主机平台适配器决定。

## 3. 现状与设计约束

### 3.1 当前调用链

现有调用点主要是：

- `MonitorScheduler` → `MetricCollector` → `CollectionScript` → `MetricParser`/`ProcParsers`。
- `ProcessMonitor` → `ProcessCollector` → `ProcessCollectionScript` → `ProcessParser`。
- `LogCenterViewModel` 直接执行 `LogPresets.discoveryCommand` 并调用 `parseDiscovery`。
- `DockerViewModel` 直接调用 `DockerService.probe`，其余 Docker 操作由 `DockerCommand` 构造。
- `BuiltinSnippets` 从 JSON 载入并写入本地 `Snippet` 数据库。

这些调用链的统一输出模型已经存在：`HostMetrics`、`RemoteProcess`、`LogSource`、Docker 领域模型和 `RunOutcome`。本次保留这些模型，替换命令构造、平台判断和解析入口。

### 3.2 平台信息的来源

平台画像只在已建立的 SSH session 上探测。首期使用一个短探测命令获得：

- 操作系统族：Linux / Darwin / Windows / Unknown。
- 版本和架构（能可靠取得时）。
- 默认 Shell 类型。
- 常用可执行文件是否存在及其路径。
- Docker、日志、进程和基础指标能力的初步状态。

探测失败不应把主机自动当成 Linux。Unknown 平台进入明确的降级状态，避免再次执行一整套 Linux 命令造成误导。

## 4. 核心抽象

### 4.1 平台画像

在 `ConnKit` 增加平台无关的值类型，供所有功能包共享：

```swift
public enum RemotePlatformKind: String, Codable, Sendable, Hashable {
    case linux
    case macOS
    case windows
    case unknown
}

public enum RemoteCapability: String, Codable, Sendable, Hashable {
    case hostMetrics
    case processes
    case logs
    case builtinCommands
    case docker
    case sftp
    case terminal
}

public enum CapabilityState: Codable, Sendable, Equatable {
    case supported
    case degraded(reason: String)
    case unavailable(reason: String)
    case unsupported(reason: String)
}

public struct RemotePlatformProfile: Codable, Sendable, Equatable {
    public let kind: RemotePlatformKind
    public let release: String?
    public let architecture: String?
    public let shell: ShellInterpreter?
    public let capabilities: [RemoteCapability: CapabilityState]
    public let executables: [String: String]
}
```

实际实现可以按现有代码风格调整为 `Set`/数组等 Codable 友好形式，但必须满足：值类型、可测试、`Sendable`、不持有 session。

### 4.2 平台探测和缓存

在 `ConnSSH` 增加 `RemotePlatformDetector`，并由 `ConnectionManager` 提供按主机缓存的画像访问入口：

```swift
public protocol RemotePlatformDetecting: Sendable {
    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile
}

extension ConnectionManager {
    public func platformProfile(for host: ConnKit.Host) async throws -> RemotePlatformProfile
}
```

`ConnectionManager` 负责：

- 与 session 池使用同一主机 key。
- 首次请求时探测一次，后续功能复用画像，不为每个页面重复探测。
- `invalidate(host:)`、`invalidateAll()` 和连接失败时清除画像缓存。
- 探测命令只读、短小，并使用固定 sentinel；不得把用户输入拼进命令。

`RemotePlatformDetector` 的默认实现负责 Linux、Darwin 和 Unknown；Windows 只返回 `windows` 或 `unknown` 的画像，不提供具体采集器。

### 4.3 能力提供者

每个功能模块定义自己的窄接口，接口只依赖统一的平台画像和该模块的输出模型：

```swift
public protocol MetricsProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func command(includeExtended: Bool) -> String
    func parse(_ output: String) -> ParsedMetrics
}

public protocol ProcessProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func command: String { get }
    func parse(_ output: String) -> [RemoteProcess]
}

public protocol LogProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func discoveryCommand: String { get }
    func parseDiscovery(_ output: String) -> [LogSource]
}

public protocol CommandCatalogProvider: Sendable {
    var platform: RemotePlatformKind { get }
    func builtinCommands() -> [PlatformSnippet]
}
```

这些接口只表示“如何采集/解析”，不负责调度、连接重试、UI 状态或持久化。各模块通过 `ProviderRegistry` 根据 `RemotePlatformProfile.kind` 选择实现：

- `ConnMonitor`: `LinuxMetricsProvider`、`DarwinMetricsProvider`、`LinuxProcessProvider`、`DarwinProcessProvider`。
- `ConnOps`: `LinuxLogProvider`、`DarwinLogProvider`、Docker 环境提供者。
- `ConnRunner`: Linux/macOS 内置命令目录；Windows 目录预留。

Linux 适配器先从现有 `CollectionScript`、`MetricParser`、`ProcParsers`、`ProcessCollectionScript` 和 `ProcessParser` 中提取，保持现有 sentinel 与 GNU/BusyBox fixture 不变。macOS 适配器使用独立命令和 fixture，不在 Linux parser 中添加大量平台分支。

### 4.4 统一结果和降级

`HostMetrics` 的既有可选字段继续保留，但采集结果增加平台/能力诊断信息，供 UI 区分“首次采样无差分”和“平台不支持”：

- 采样值缺失仍使用 `nil`。
- 采集结果携带 `RemotePlatformProfile` 或等价的 `CapabilityReport`。
- CPU、内存、磁盘等核心指标缺失时，健康状态不能仅依据仍存在的磁盘值显示为 `.ok`。
- 趋势图只有在存在真实样本时绘制；不支持或未采集不转换为 0。
- 进程、日志、Docker 页面使用 `CapabilityState` 显示明确的降级说明，并保留重试入口。

`CapabilityState` 是能力级状态，不替代命令的具体退出码。权限不足、命令不存在、守护进程未运行和平台不支持必须保持可区分。

## 5. Linux 适配器

Linux 是行为兼容优先的迁移目标：

- 保留 `/proc/stat`、`/proc/meminfo`、`/proc/loadavg`、`/proc/net/dev`、`/proc/diskstats`、`/proc/uptime` 和 `df` 的当前语义。
- 保留 GNU 与 BusyBox 两种进程输出解析。
- 保留 `journalctl` 和常见 Linux 日志文件探测。
- 保留当前 Docker CLI、免密 `sudo -n` 回退和 Compose 解析。
- Linux 不支持某段数据时仍返回字段级 nil 和能力诊断，不影响其他可用段。

迁移完成后应删除调用方对 `CollectionScript.command`、`ProcessCollectionScript.command` 和 `LogPresets.discoveryCommand` 的直接依赖；这些实现细节只允许出现在 Linux provider 内。

## 6. macOS 适配器

### 6.1 主机指标

使用 Darwin 原生命令，并把解析结果映射到现有 `ParsedMetrics`：

| 领域 | 首期命令方向 | 结果 |
|---|---|---|
| CPU/型号/核心数 | `sysctl` | CPU 快照、核心数、型号 |
| 内存 | `vm_stat`、`sysctl`、`vm.swapusage` | 总量、使用量、缓存/空闲、Swap |
| 负载 | `sysctl` 或 `uptime` | load 1/5/15 |
| 磁盘 | `df -P -k` | 保留现有磁盘模型 |
| 网络 | `netstat -ib`、`ifconfig` | 接口累计流量、IP |
| TCP | Darwin `netstat`/`sysctl` 可用统计 | 能取得时提供 TCPStats，否则明确 nil |
| 磁盘 IO | `iostat` | 读写累计或速率，按能力状态降级 |
| 开机时长 | `sysctl kern.boottime` | uptime |
| 系统名 | `sw_vers` | macOS 版本名 |

CPU 和网络速率仍由现有 collector 使用远端 uptime/累计值做差分；如果 Darwin 命令只能提供瞬时速率，则 provider 必须明确声明该字段语义，不得伪装成累计值。

### 6.2 进程

使用 Darwin 支持的 `ps` 字段和稳定分隔格式，不依赖 GNU `--sort`、`nlwp` 或 BusyBox `top`。排序在 Swift 中完成。Darwin 无法可靠提供的线程数、父进程或运行时长保留为 nil，并在能力报告中说明。

进程采集命令必须：

- 使用固定列名/分隔符，避免命令行中的空格破坏解析。
- 不通过 `top -bn1` 作为 fallback。
- 对单条坏行跳过，不让一条异常进程导致整页失败。

### 6.3 系统日志

macOS provider 增加：

- Unified Logging：`log show` 的最近时间窗口查询。
- 跟随模式：`log stream`，必要时使用固定 predicate。
- `/var/log/system.log` 和可探测的服务日志作为文件源。

`LogSource.Kind` 增加独立的 unified log 类型，而不是复用 `journal`。这样 UI 可显示正确的来源名称，未来 Windows Event Log 也可新增独立类型。

### 6.4 Docker

Docker 的容器模型和 JSON 输出保持跨宿主机通用，但 macOS provider/环境探测负责：

- 发现非交互 SSH 下的 `docker` 路径。
- 不依赖交互 Shell 的 PATH。
- 区分 Docker Desktop 未运行、CLI 未安装和权限不足。
- 将 macOS 的启动引导改为 Docker Desktop 相关提示；Linux 才显示 `systemctl`。

## 7. 内置命令和持久化

内置 JSON 增加稳定的 `id` 和 `platforms` 字段，例如 `linux`、`macOS`、`all`。命令目录 provider 负责按远端平台提供可执行的内置命令：

- Linux 使用现有命令；macOS 使用 `sysctl`、Darwin `ps`、`netstat`、`log` 等等价命令。
- Docker 片段标记为 Docker capability，而不是简单按操作系统过滤。
- 用户自定义片段的 `platforms` 默认为 `all`，不改变已有脚本。

由于内置片段已经写入 SQLite，`Snippet` 和 `snippet` 表增加可选平台元数据，并提供 schema migration：

- 旧数据迁移为 `all`。
- 现有用户编辑/删除/排序行为不变。
- 导入逻辑以稳定 id 幂等，避免新增平台片段时重复导入。
- 片段列表可以显示“当前主机不可用”的状态，但不删除用户的其他平台片段。

`ShellInterpreter` 目前只有 `sh`、`bash`、`zsh`。macOS 首期继续支持现有三种；Windows 适配阶段再扩展 PowerShell/CMD，并在独立迁移中处理脚本执行和危险命令规则。

## 8. 调度和 UI 集成

### 8.1 监控调度

`MonitorScheduler` 在采集前通过 `ConnectionManager.platformProfile(for:)` 获取画像，将 profile 传给 `MetricCollector`。`MetricCollector` 只调用选中的 `MetricsProvider`，保留现有 CPU、网卡和 IO 跨样本基线。

`ProcessMonitor` 使用同一画像选择 `ProcessProvider`。平台探测失败时不执行 Linux fallback，而是把失败原因交给 `ProcessListViewModel` 展示。

### 8.2 日志和 Docker

`LogCenterViewModel` 不再直接调用静态 `LogPresets.discoveryCommand`，而是请求适配器生成 discovery command 和 sources。`LogSource.followCommand` 继续负责流式命令，但 unified log 由自身的 kind 生成。

`DockerViewModel` 继续复用 `DockerService`，但 probe 需要消费平台画像中的 executable path、privilege strategy 和 Docker capability 状态。UI 的不可用文案按平台选择，不再固定显示 `systemctl`。

### 8.3 能力状态展示

UI 至少需要在以下场景显示原因：

- 概览：指标部分可用时显示降级标识或详情说明，不把空字段画成 0。
- 进程：平台不支持、命令缺失、权限不足分别显示。
- 日志：macOS Unified Logging 可用时显示系统日志；无权限时显示可操作提示。
- Docker：CLI 未安装、daemon 未运行和权限不足分别显示平台相关引导。
- 内置片段：当前平台不可用的内置片段不应误导用户直接执行。

## 9. 错误处理和安全

- 所有 provider 命令仍然通过 `SSHSession.exec`/`execStream` 执行，继续遵守现有连接池和重试策略。
- 平台探测命令和 provider 命令使用固定字符串；路径和 unit 名称必须通过现有 shell quote 工具处理。
- 解析器对缺失段、权限错误、未知版本和异常行采取局部降级，不使用静默的全局成功。
- `sudo -n` 只用于已知的只读日志/ Docker 场景；不因 macOS 适配而引入交互式 sudo。
- Unknown/Windows 未实现 provider 必须返回可序列化的 `unsupported` 状态，不能 force-cast 为 Linux provider。

## 10. 测试策略

### 10.1 单元测试

- `ConnKitTests`：平台枚举、能力状态、画像 Codable/Equatable 和默认值。
- `ConnSSHTests`：探测输出解析、Linux/Darwin/Windows/Unknown 识别、缓存失效。
- `ConnMonitorTests`：
  - Linux 既有 GNU/BusyBox fixture 全部保持通过。
  - 新增 macOS `sysctl`、`vm_stat`、`ps`、`netstat`、`iostat` fixture。
  - provider registry 选择正确平台。
  - 缺段产生 nil + capability reason，而不是 0 或 `.ok`。
  - Darwin 进程排序、坏行跳过和缺少线程字段。
- `ConnOpsTests`：macOS log discovery、`log show/stream` 命令、system.log fallback、Docker PATH/daemon/权限分类。
- `ConnRunnerTests`：平台标签解析、旧 JSON 兼容、用户片段默认 `all`、幂等导入。
- `ConnStoreTests`：schema migration 后旧 snippet 全部可读，平台元数据默认 `all`。

### 10.2 集成测试

保留现有 Docker SSH matrix 作为 Linux 集成测试，并新增 macOS 集成测试开关：

- 使用环境变量指定已启用 SSH 的 macOS 主机，不在测试中创建或切换本地模拟器。
- 验证平台探测、指标采集、进程、日志 discovery、Docker probe 和 SFTP/终端基础连通。
- 没有环境变量时测试应明确 skipped，而不是把 skipped 当作兼容通过。
- Windows 集成测试本轮只验证平台画像的可识别性时才加入；具体采集留到后续计划。

### 10.3 验收标准

- Linux 现有 package tests 无回归。
- 在真实 macOS SSH 主机上，概览至少能取得 CPU、内存、磁盘、负载、网络、uptime、系统名中的已实现字段；缺失字段有原因。
- Mac 进程页不再因 GNU 参数失败而静默空白。
- Mac 日志页能发现 Unified Logging 或 system.log，并能流式查看。
- Docker Desktop 可用时 Docker 页面能正常探测；不可用时文案不再要求 `systemctl`。
- Unknown/未来 Windows 主机不会执行 Linux 采集脚本。

## 11. 实施顺序

1. 建立 `ConnKit` 平台画像、能力状态和统一错误模型；为探测与 registry 写失败测试。
2. 在 `ConnSSH` 实现探测、缓存和失效；接入 scheduler/monitor 的 profile 传递。
3. 抽取 Linux metrics/process provider，保持现有测试 fixture 绿色。
4. 实现 Darwin metrics/process provider 及 fixture。
5. 抽取并实现 Linux/Darwin log provider，增加 unified log source。
6. 重构 Docker probe/命令路径和平台相关 UI 文案。
7. 增加内置片段平台元数据、数据库 migration 和按主机平台展示。
8. 补充真实 macOS SSH 集成测试说明与可选执行入口。
9. 运行 package tests、macOS host build 和用户已启动模拟器上的 UI 验收（只复用该模拟器，不管理其他模拟器生命周期）。

## 12. 文件边界

预计新增或修改的主要文件：

- `Packages/ConnPackages/Sources/ConnKit/Models/RemotePlatform.swift`
- `Packages/ConnPackages/Sources/ConnSSH/RemotePlatformDetector.swift`
- `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- `Packages/ConnPackages/Sources/ConnMonitor/*Provider.swift`、`MetricCollector.swift`、`ProcessCollector.swift`
- `Packages/ConnPackages/Sources/ConnOps/*LogProvider.swift`、`LogSource.swift`、`DockerService.swift`、`DockerCommand.swift`
- `Packages/ConnPackages/Sources/ConnRunner/BuiltinSnippets.swift`、`Resources/builtin-snippets.json`
- `Packages/ConnPackages/Sources/ConnKit/Models/Snippet.swift`
- `Packages/ConnPackages/Sources/ConnStore/Migrations/*`、`SnippetRecord.swift`、`SnippetStore.swift`
- `Conn/Conn/Hosts/LogCenterView.swift`、`DockerView.swift`、相关 ViewModel
- 对应 `Tests` 目录中的平台 fixture、registry、migration 和集成测试。

具体实现时应优先保持文件职责清晰；如果某个现有文件超过当前模块的职责边界，应在对应任务中拆分，而不是继续追加平台 `switch`。
