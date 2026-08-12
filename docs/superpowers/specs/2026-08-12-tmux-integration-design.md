# Conn tmux 原生集成设计

**日期：** 2026-08-12  
**状态：** 已确认，评审补强完成，待实现计划\
**范围：** Linux/macOS 远端 tmux 发现、持久会话接入、原生管理、Control Mode 状态同步与普通 PTY 降级  
**依赖：** `2026-08-03-terminal-multi-session-design.md`、`2026-08-11-remote-capability-architecture-hardening-design.md`

## 1. 摘要

Conn 在现有进程内多终端之上增加远端持久终端能力。首个 provider 是 tmux，支持 Linux 和 macOS 主机；Windows 与 Unknown 平台保持普通 PTY，不执行 POSIX/tmux 探测。

核心架构采用双平面：

- **数据面：** 普通 PTY 直接执行 `tmux attach-session`，由 tmux 绘制完整布局、状态栏、copy-mode 和插件效果，SwiftTerm 继续负责终端模拟；
- **控制面：** 独立双向远程进程运行 `tmux -CC`，使用 Control Mode 命令、通知和初始快照维护 Session、Window、Pane 状态；
- **降级：** Control Mode 不满足要求或异常时保留普通 tmux PTY，并降级到按需快照；tmux 未安装时自动打开普通 PTY；
- **演进：** 控制面、领域状态和 UI 不依赖具体渲染器，后续可以增加逐 Pane 的 Control Mode 原生渲染，不推翻首期模型。

该方案选择“原生管理 + 原始 tmux 终端语义”，不是全量复制 iTerm2。它优先保护重度 tmux 用户已有的 `.tmux.conf`、插件、状态栏、快捷键和多客户端协作，同时为以后实现全原生 Pane、Zellij、GNU Screen、Windows 持久终端或远程 Agent 保留边界。

## 2. 背景与问题

现有 `TerminalSessionCoordinator` 管理 App 进程内的多个 SSH PTY。页面关闭后 PTY 可继续存活，但 App 被系统终止、SSH 断线或设备切换后，本地 PTY 无法恢复。tmux 的 server/client/session/window/pane 模型可以让远端程序脱离某一条 SSH 连接继续运行，并允许多个客户端共享。

仅在登录 Shell 中发送 `tmux attach` 可以解决“远端进程继续运行”，但不足以形成专业产品能力：

- App 不知道远端有哪些 Session、Window 和 Pane；
- 手机上依赖 prefix 组合键管理 Window/Pane 操作成本高；
- 外部桌面客户端修改 tmux 后，本地 UI 无法及时同步；
- 关闭本地 Tab、Detach、Kill Session 的语义容易混淆；
- 多客户端尺寸和 active pane 可能互相影响；
- 登录 Shell 的 rc 输出、alias、提示符和命令回显会污染机器协议。

因此 tmux 不能只作为一条初始命令，也不能直接塞进现有 `TerminalSessionStore`。它需要独立的 provider、控制协议、远端目录状态和本地 attachment 生命周期。

## 3. 产品定位与竞品基线

公开实现大致分为四类：

| 路线 | 代表产品 | 主要能力 | Conn 的取舍 |
| --- | --- | --- | --- |
| 透明 PTY | Prompt、Termius、Blink | 用户手工或启动命令进入 tmux | Conn 必须明显超过，仅作为降级 |
| tmux 增强终端 | Secure ShellFish、TermRover | Session Picker、缩略图或触摸快捷操作 | 首期对齐核心管理，并提供更完整 Window/Pane 状态 |
| Control Mode 原生客户端 | iTerm2 | 原生 Window/Tab/Split、逐 Pane 输出 | 保留为未来 Renderer；首期不牺牲 tmux 原始语义 |
| 自定义远端代理 | Pocketmux、WezTerm mux | 原生远端工作区、独立协议或 Agent | 不在首期引入安装、升级和安全维护负担 |

首期竞争目标：

- 超过只会运行 `tmux` 的通用 SSH 客户端；
- 对齐专业移动 tmux 客户端的 Session 发现、Attach 和高频管理能力；
- 通过 Control Mode 获得可靠的 Window/Pane 原生状态，而不是依赖固定周期轮询；
- 在共享桌面 tmux 时，默认不破坏现有布局和客户端；
- 保留用户原始 tmux UI、插件和肌肉记忆，形成区别于 iTerm2 全原生模式的价值。

Handoff、Universal Link、Mosh、缩略图、逐 Pane 原生渲染不是首期验收项，见第 23 节。

## 4. 目标与非目标

### 4.1 目标

- Linux/macOS 主机按需检测 tmux，Windows/Unknown 不运行 tmux 命令；
- 每次从普通终端入口启动时，在 tmux 可用的情况下显示启动选择器；
- tmux 不可用时不阻断用户，直接进入普通 PTY；
- 发现指定 tmux server profile 中的 Session，并支持新建和共享 Attach；
- 原生展示和管理 Session → Window → Pane；
- 使用 Control Mode 事件同步当前正在观察的 Session；
- 外部客户端的创建、关闭、重命名、布局变化能够反映到 Conn；
- 关闭 Conn 的 tmux Tab 只 Detach，远端 Session 继续运行；
- Kill Session、Close Window、Close Pane 是明确的破坏性操作；
- 保护已有桌面客户端的尺寸和 active pane，无法完全隔离时明确提示；
- 支持默认 tmux server、`-L socket-name` 和 `-S socket-path`；
- 不自动扫描所有 socket；
- Control Mode 失败时，交互终端和远端 tmux Session 不被连带关闭；
- 抽象持久终端 provider，为更多 multiplexer/平台保留扩展点；
- Control Mode 解析器、命令编码器和状态 reducer 可在 macOS host 上独立测试。

### 4.2 非目标

- 不自动安装 tmux、不修改 `.tmux.conf`、不管理 tmux 插件或主题；
- 不把远端 Session、Window、Pane 快照写入 SQLite；
- 不承诺 tmux server 跨远端主机重启存活；
- 不扫描未配置的 `-L`/`-S` socket；
- 不在首期实现 Mosh、Eternal Terminal、远程 Agent 或 WebRTC；
- 不在首期实现 Handoff、Universal Link、Live Activity 或跨设备自动恢复入口；
- 不在首期实现逐 Pane 原生渲染、原生 copy-mode 或本地重建 tmux 状态栏；
- 不在首期实现 move/link/swap/break/join Pane/Window、布局编辑器和批量操作；
- 不猜测 Windows 是否安装 WSL；Windows 持久终端由后续明确 provider 支持；
- 不把所有平台强行抽象为 Session/Window/Pane 三层模型。

## 5. 已确认的产品规则

### 5.1 启动流程

用户每次从普通终端入口启动时：

1. Conn 获取同一连接身份下的 `RemotePlatformProfile`；
2. Linux/macOS 对当前首选 tmux server profile 做按需 probe；
3. tmux 未安装、平台不支持或 provider 被禁用时，直接创建普通 PTY；
4. tmux 可用时，每次都显示选择器，不记住并自动跳过：
   - Attach 已有 tmux Session；
   - 新建 tmux Session；
   - 打开普通 PTY；
5. 用户可以在选择器中切换已配置的 tmux server profile；Conn 不主动扫描其它 socket。

tmux 不可用不是普通终端失败；UI 可以显示一次轻量说明，但不要求用户处理后才能进入终端。

Docker Console 和“脚本进入终端”保持现有独立 PTY 语义，不自动套入 tmux。将来若需要持久化 Docker/脚本会话，应由调用方显式选择 attachment backend，不能因主机支持 tmux 就偷偷改变命令生命周期。

### 5.2 Attach 与关闭

- 默认采用共享 Attach，不使用 `-d`，不踢掉其他客户端；
- 一个 tmux Session 可以同时被 Conn 和桌面终端 Attach；
- 关闭 Conn tmux Tab、关闭承载终端的 Modal，或因 App 后台/SSH 断线导致 channel 结束时，都只结束本地 tmux client，不 Kill 远端 Session；普通页面切换是否保持 Tab 由现有多会话生命周期决定；
- Detach 自己不需要破坏性确认；
- Kill Session、Close Window、Close Pane 必须走专用操作；
- Kill Session 前显示名称、Window/Pane 数量和其它受影响 client 数；Conn 自己的 Control Client 不计入风险，有外部或其它数据面客户端时加强提示；
- 不把“关闭 Tab”按钮复用为 Kill Session。

### 5.3 移动端 Pane 交互

- 默认显示 tmux 绘制的完整 Window 布局，不自动 zoom；
- 提供原生 Pane 列表和方向切换，方便手机触摸操作；
- 首期 Pane 操作包括 focus、水平/垂直 split、zoom/unzoom、close；
- Zoom 属于远端 Window 状态，可能影响其他客户端，首次操作或存在其他客户端时提示；
- iPad 横屏优先完整布局；iPhone 允许通过 Pane 列表定位，但不把每个 Pane 拆成本地 SwiftTerm；
- 支持 `active-pane` client flag 时，Conn 的交互 tmux client 使用独立 active pane；不支持时将“切换 Pane 可能影响其他客户端”作为 capability degradation 展示。

### 5.4 首期管理能力

| 层级 | 首期操作 |
| --- | --- |
| Session | list、attach、new、rename、detach self、kill |
| Window | list、select、new、rename、close |
| Pane | list、focus/select、split horizontal、split vertical、zoom/unzoom、close |

所有操作使用 `$session`、`@window`、`%pane` ID 作为 target；名称和 index 只用于展示。

## 6. 领域术语与身份

### 6.1 本地对象与远端对象

- `TerminalTab`：Conn 进程内打开的一张终端页；
- `TerminalAttachment`：本地终端页与某个远端 backend 的连接描述；
- `RemoteWorkspace`：某个持久终端 provider 的顶层可 Attach 对象；tmux 中对应 Session；
- `TmuxSession`、`TmuxWindow`、`TmuxPane`：tmux provider 的专有领域对象；
- `TmuxServerProfile`：一个 host 上的 tmux server 入口，包含 default、`-L` 或 `-S` 定位；
- `TmuxServerInstance`：当前运行中的某个 tmux server 实例。

### 6.2 ID 规则

tmux ID 只在一个 tmux server 实例生命周期中稳定。Conn 使用如下作用域身份：

```text
HostConnectionIdentity
+ TmuxServerProfileID
+ TmuxServerInstanceToken
+ tmux entity ID ($/@/%)
```

`TmuxServerInstanceToken` 不是任意字符串，使用 tmux 2.6 起可提供的 server 级格式组成结构化身份：

```swift
public struct TmuxServerInstanceToken: Sendable, Codable, Equatable, Hashable {
    public let resolvedSocketPath: String
    public let serverPID: Int32
    public let serverStartTime: Int64
}
```

`resolvedSocketPath` 用于防止 locator 接错 server，`serverPID + serverStartTime` 用于防止 PID 复用。profile ID 仍是外层作用域的一部分，不能只凭相同 socket path 跨 profile 复用 Hub。server 不存在时没有 instance token，availability 显式返回 `.serverAbsent`，禁止伪造 provisional token。

SSH 重连后：

- instance token 相同：可以继续用旧 `$`/`@`/`%` ID 校准；
- instance token 改变：旧 ID 全部失效，必须清空状态并重新发现；
- Session 名称只作为重新选择建议，不能在 server 重启后静默替代旧 ID Attach。

tmux client 没有 `$`/`@`/`%` 形式的 server entity ID。`TmuxClientID` 只在当前 Hub generation 内有效，由 `client_name/tty + client_pid + client_created` 中目标版本可提供的字段组成；实际命令使用经过 snapshot 验证的 `target-client` 名称。Conn 自有 wrapper 在 `exec tmux` 前输出 tty 和 `$$`，因为 `exec` 保持进程 PID，可与 `list-clients` 的 tty/PID 同时核对。仅凭 tty、名称相似或本地 attachment 顺序不得认领 client。

## 7. 总体架构

```text
App UI
├── Terminal Launch Chooser
├── Terminal Session Center
└── Tmux Management Views
          │
ConnTerminal
├── TerminalSessionCoordinator
├── TerminalSessionStore              本地打开的 Tab
├── RemoteWorkspaceCatalogStore       UI 展示状态
├── TerminalAttachmentBackend
│   ├── PlainPTYBackend
│   └── PersistentProviderBackend
└── ControlModePaneRenderer            后续独立渲染面
          │
ConnMultiplexer                        新增纯 Swift target
├── PersistentTerminalProvider
├── PersistentTerminalProviderRegistry
├── PersistentAttachmentDescriptor
├── PersistentTerminalAttachment
├── TmuxProvider
├── TmuxPassthroughAttachment
├── TmuxControlHub
├── TmuxControlClient
├── TmuxProtocolParser
├── TmuxOperation
├── TmuxControlCommandRenderer
├── TmuxShellInvocationRenderer
└── TmuxStateReducer
          │
ConnSSH
├── SSHSession
├── ShellChannel                       兼容现有调用
└── RemoteProcessChannel               新增双向进程抽象
          │
ConnSSHCitadel
└── CitadelRemoteProcessChannel
```

依赖约束：

- `ConnMultiplexer` 依赖 `ConnKit` 和 `ConnSSH`，不依赖 UIKit、SwiftUI、SwiftTerm 或 Citadel；
- `ConnTerminal` 依赖 `ConnMultiplexer`，负责终端渲染与本地 Tab 生命周期；
- 通用 profile、attachment descriptor 和 provider runtime 接口由 `ConnKit`/`ConnMultiplexer` 拥有，不能引用 `ConnTerminal` 类型，避免依赖环；
- `ConnSSHCitadel` 只实现 SSH 传输协议，不理解 tmux；
- App UI 只调用 provider/controller，不拼接 tmux 命令、不解析协议；
- `ConnectionManager` 继续只管理 SSH 连接和平台画像，不缓存 tmux Session 树。

## 8. SSH 双向远程进程抽象

### 8.1 动机

Control Mode 是一个长期运行、标准输入可写、标准输出持续产生协议消息的远程进程。现有 `execStream` 只能读，`openShell` 又会进入登录 Shell，均不满足要求。

`ConnSSH` 新增通用抽象，概念接口如下：

```swift
public struct RemoteProcessRequest: Sendable, Equatable {
    public let command: String
    public let terminal: RemoteTerminalRequest?
}

public struct RemoteTerminalRequest: Sendable, Equatable {
    public let type: String
    public let size: TermSize
    public let modes: [RemoteTerminalMode: UInt32]
}

public enum RemoteProcessOutput: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
}

public struct RemoteProcessExit: Sendable, Equatable {
    public let exitCode: Int32?
    public let signal: String?
}

public protocol RemoteProcessChannel: AnyObject, Sendable {
    var output: AsyncThrowingStream<RemoteProcessOutput, Error> { get }
    func write(_ data: Data) async throws
    func resize(_ size: TermSize) async throws
    func result() async throws -> RemoteProcessExit
    func close() async
}
```

`SSHSession` 新增：

```swift
func openProcess(_ request: RemoteProcessRequest) async throws -> any RemoteProcessChannel
```

### 8.2 语义要求

- 通过 SSH channel request 精确执行 `request.command`，不先进入交互式登录 Shell；
- SSH server 通常仍通过远端用户 Shell 的 `-c` 执行命令；`.zshenv`、`BASH_ENV` 等非交互启动文件可能运行或输出内容，因此机器协议调用方仍必须有起始帧，不能假设首字节就是协议；
- 是否申请 PTY 由 request 明确决定；tmux 数据面和 Control Mode 都可以申请 PTY，但不依赖提示符、alias 或交互式 rc；
- `openProcess` 只有在 channel、PTY request（如有）、exec request 和 writer 都就绪后返回；
- stdout/stderr 在无 PTY 时保持区分；PTY 合并输出时实现可以统一映射为 stdout；
- output bridge 必须有界且保序，使用底层 channel backpressure/受控读取避免 `AsyncThrowingStream` 无上限堆积；终端字节不能静默 drop，超过明确资源上限时关闭当前 process channel 并返回结构化错误；
- `result()` 等待同一远程进程的 exit-status/exit-signal；server 未提供时字段为 nil，不为了结果累计无限 stdout/stderr；
- 远端 EOF、通道错误、本地关闭只完成一次；
- `close()` 只关闭当前 SSH channel，不关闭共享 `SSHSession`；
- 创建任务不响应 cancellation 时，采用现有 generation/claim 思路阻止迟到 channel 泄漏；
- Citadel 若没有公开足够 API，允许在 `ConnSSHCitadel` 内使用其 NIOSSH 底层能力或维护最小适配补丁，但不能把 Citadel 类型泄漏到 `ConnSSH`。

现有 `ShellChannel` 保留，避免无关调用点迁移。后续可让 `openShell()` 在引擎内部复用 `openProcess()`，但这不是 tmux 首期的前置条件。

## 9. 持久终端 Provider 抽象

### 9.1 不建立虚假的统一三层树

通用抽象覆盖“探测、列出顶层工作区、创建、生成可重连描述、打开/重开 attachment、结束本地 attachment”的完整生命周期。Window/Pane 等高级结构由 feature facet 表达，不能让 `TerminalSessionCoordinator` 按 provider 写分支：

```swift
public struct RemoteWorkspaceRef: Sendable, Codable, Equatable {
    public let workspaceID: String
    public let instancePayloadVersion: Int
    public let providerInstancePayload: Data
}

public struct PersistentAttachmentDescriptor: Sendable, Codable, Equatable {
    public let providerID: String
    public let profileID: String
    public let workspace: RemoteWorkspaceRef
    public let payloadVersion: Int
    public let providerPayload: Data
}

public enum PersistentAttachmentOpenReason: Sendable, Equatable {
    case initial
    case reconnect
}

public enum PersistentAttachmentPresentation: Sendable {
    case byteTerminal(any ShellChannel)
    // 后续由 nativePaneOutput facet 增加原生 presentation，不改变 descriptor/profile。
}

public protocol PersistentTerminalAttachment: AnyObject, Sendable {
    var descriptor: PersistentAttachmentDescriptor { get }
    var presentation: PersistentAttachmentPresentation { get }
    func close() async
}

public struct PersistentTerminalContext: Sendable {
    public let connectionIdentity: SSHConnectionIdentity
    public let session: any SSHSession
    public let platformProfile: RemotePlatformProfile
    public let backendProfile: TerminalBackendProfile
}

public protocol PersistentTerminalProvider: Sendable {
    var descriptor: PersistentTerminalProviderDescriptor { get }

    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability

    func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary]
    func createWorkspace(_ request: CreateWorkspaceRequest, in context: PersistentTerminalContext) async throws -> RemoteWorkspaceRef
    func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws
    func destroyWorkspace(
        _ workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) async throws
    func makeAttachmentDescriptor(
        to workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) throws -> PersistentAttachmentDescriptor
    func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment
}
```

`PersistentTerminalContext` 必须由一次 `ConnectionManager.platformContext(for:)` 返回的同一 SSH session 和平台画像构造，并附上当时的 `SSHConnectionIdentity`；实现时扩展现有 `RemotePlatformContext`，让它在连接池认领 session 的同一 actor 调用内一并返回 identity，再与 backend profile 组成 provider context。不能分别取得 session/profile/identity 后拼接，也不能跨 connection identity 复用。所有 probe/list/create/open/operation 都消费该 context，并在写入本地状态前确认 host generation 仍有效。

`create/rename/destroy` 是否出现在 UI 由 feature set 决定；协议保留统一入口是因为它们都作用于 provider-independent 的顶层 Workspace。未声明能力的 provider 返回结构化 unsupported，不能静默 no-op。Window/Pane 等非通用层级仍留在 tmux 专有 facet，不上提到该协议。

`RemoteWorkspaceRef.workspaceID` 是 provider 在当前实例内的稳定顶层 ID；`providerInstancePayload` 保存 provider 解码后才能理解的实例作用域，tmux 用它承载 `TmuxServerInstanceToken`。因此 `createWorkspace` 可以把单次 bootstrap 返回的新 token 和 Session ID 一起原子返回，无需第二次 probe。未知 instance payload version 不能打开或执行操作。

`RemoteWorkspaceSummary` 只包含 provider-independent 顶层信息：上述稳定引用、名称、创建/活动时间（provider 可提供时）、attachment 占用信息和简要状态。占用信息不是裸 `Int`，至少包含 optional `affectedAttachmentCount`、`observedAt` 和 `freshness`；统一语义是“会受到 Workspace 破坏性操作影响的其它 client/attachment”，provider 自己的观察/管理通道必须排除。tmux 因而统计除当前 Conn Control Client 外的已附加 clients；无法证明属于 Conn 的第三方 Control Mode client 仍按外部受影响对象计数。Window/Pane 使用 `TmuxWorkspaceSnapshot` 和 `TmuxWorkspaceManaging`，不塞入通用模型。

`providerPayload` 由对应 provider 按 `payloadVersion` 解码。未知 provider、instance payload version 或 attachment payload version 可以保留 descriptor 用于显示诊断，但不得尝试打开。`openAttachment(... reason: .reconnect)` 必须消费同一份通用 descriptor，不允许从 `TerminalSessionSource`、alias、名称或初始命令反推 provider。首期 presentation 只有 `.byteTerminal`；未来全原生 Pane Renderer 增加 presentation/facet，但不修改 Registry、profile schema、descriptor envelope 或终端启动选择器。

`PersistentTerminalAttachment.close()` 必须幂等。打开成功后由本地 Tab runtime 强持有 attachment handle；仅抽出 `ShellChannel` 而丢弃 handle 是非法接线，因为 provider 还可能需要在 close 时释放 Hub lease 或其它 provider runtime。

### 9.2 Feature set

Feature 必须区分“provider 实现理论上会做什么”和“当前 host/profile/server instance 实际可用什么”。`PersistentTerminalProviderDescriptor.potentialFeatures` 是静态上限；`PersistentTerminalAvailability.effectiveFeatures` 是 probe/Attach 协商后的动态交集，并带 generation/instance token。UI 和 operation guard 只读取 effective features，不能因 registry 中存在 tmux provider 就乐观开放按钮：

```text
workspaceDiscovery
workspaceCreation
workspaceRename
workspaceDestruction
eventStreaming
dynamicMetadataSubscriptions
clientInspection
clientManagement
hierarchicalWindows
hierarchicalPanes
readOnlyAttach
snapshotPreview
nativePaneOutput
```

首期 tmux provider 的 potential features 包含 workspace 管理、事件流以及 Window/Pane 层级；当前目标 tmux 实际协商成功 format subscription 时，effective features 才包含 `dynamicMetadataSubscriptions`。Attach 前仍为 deferred 的 client capability 不得提前标记 effective；首次协商后按 server instance token 缓存并通知 UI。`clientInspection` 只用于按 ownership/kind 的受影响 client 数、尺寸决策和安全提示，不提供踢出其他客户端的 UI。其它能力留作后续。

### 9.3 Registry

`PersistentTerminalProviderRegistry` 在 App 组合层注入 provider：

- 默认注册 `TmuxProvider`；
- provider 选择同时检查平台、provider ID 和 profile configuration；
- 没有匹配 provider 时返回 unsupported，不回退到 POSIX；
- 普通 PTY 不伪装为 persistent provider，继续作为终端 launch backend 的基础选项；
- `PersistentProviderBackend` 只按 `providerID` 从 registry 取得 provider 并调用 `openAttachment`，不得 `switch tmux/zellij/...`；
- 未来增加 Zellij、Screen 或 Windows provider 时注册新实现，不修改 tmux provider。

## 10. tmux Server Profile 与命令构造

### 10.1 Socket 定位

```swift
public enum TmuxServerLocator: Sendable, Codable, Equatable {
    case `default`
    case namedSocket(String)   // tmux -L
    case socketPath(String)    // tmux -S
}
```

`-L` 与 `-S` 互斥。所有 tmux 操作必须使用同一个 `TmuxServerProfile` 构造命令，禁止 probe 走默认 socket、后续操作却漏掉 locator。

Locator 在进入 profile 前完成 tmux provider 级规范化：`namedSocket` 必须非空且不含 `/`、NUL 或控制字符；`socketPath` 必须是绝对远端 POSIX 路径，不展开 `~`/环境变量，消除重复 `/` 和 `.` 段并拒绝 `..` 段，但不跟随远端 symlink。规范化后的值生成 `provider_configuration_key`，原始用户输入只用于编辑回显，不能让两个文本写法绕过唯一索引却命中同一明显路径。

### 10.2 Typed Operation 与双 Renderer

provider 内部以 typed `TmuxOperation` AST 表达意图，输出必须按承载方式拆成两个 renderer：

```text
TmuxOperation
├── TmuxControlCommandRenderer     只生成 tmux command language
└── TmuxShellInvocationRenderer    生成 executable + locator + POSIX script
```

Control Mode stdin 已经位于一个 tmux client 内，只发送 `rename-session ...`、`kill-pane ...` 等 tmux command，不得再次包含 tmux executable、`-L/-S` 或 POSIX shell quoting。one-shot/wrapper 路径才由 Shell renderer 加入 executable、locator 并对 argv 做 POSIX shell argument encoding，得到受信任的 POSIX script；最终 transport command 必须再交给现有 `RemoteScriptExecutionProviderRegistry` 在已确认 Linux/macOS 上选择 `POSIXScriptExecutionProvider`，固定以 probe 返回并验证过的 `.sh` 绝对 executable path 承载，不能执行时再按可能变化的 `PATH` 查找。为此给 execution provider 增加接收 resolved interpreter path 的 machine-protocol overload/prepared runtime，而不是让 tmux provider 复制一套脚本包装。用户登录 Shell 即使是 zsh、fish 或其它实现，也只负责 SSH server 外层 `-c` 对 `<absolute-sh> -c '<script>'` 的最小启动，tmux 脚本语义不依赖它。两种 renderer 共用 typed operation 和目标校验，但各自拥有转义器与测试 fixture，不能把同一条最终字符串同时发给 Shell 和 Control Mode。

tmux 内部固定使用 `sh` 只用于 Conn wrapper/probe/one-shot；它不改变 tmux 新 Pane 的 default shell，也与用户为片段选择的 sh/bash/zsh 无关。找不到可用 POSIX script provider 或 `sh` probe 失败时，tmux provider 返回 unsupported/degraded 并保留普通 PTY，禁止直接退回“猜测当前登录 Shell 兼容”。

### 10.3 命令与 Snapshot 安全

- tmux 可执行文件来自只读 probe 的固定候选或 `command -v tmux` 结果；只接受经同一次 probe 验证为绝对、可执行文件且 `tmux -V` 成功的路径，输出含换行/NUL、alias/function 文本或多候选时拒绝；
- locator、Session 名称等参数使用统一 POSIX shell argument encoder；
- Control Mode argument 使用 tmux command argument encoder，不使用 POSIX shell encoder；
- UI 文本不得直接插值为整条命令；
- tmux target 始终使用已解析的 `$`/`@`/`%` ID；
- 创建或重命名时先执行产品级名称校验，再由 encoder 负责 shell 转义；
- snapshot format 不能用简单 tab/pipe split 解析任意远端名称，必须由协商后的 `TmuxFormatCodec` 转义/解码；支持 `q:` 的 dialect 使用 tmux 官方 quoting 并由专用 lexer 解码；不支持安全 quoting 的 legacy dialect 先批量读取只含 ID/数字的安全字段，再以独立响应读取每个不可信字符串字段，不能拿未转义名称参与分隔；
- Conn 发起的 Session/Window 创建和重命名对长度、空值及 C0/C1 控制字符做 provider 级校验；Unicode、空格和普通标点不应被无谓限制。远端已有对象仍视为不可信输入，即使名称超出 Conn 的创建规则也要安全解码和只读展示；
- 未知或无法解码的字段保留原始诊断但不进入可操作 ID 集合。

## 11. Probe 与能力协商

### 11.1 平台路由

- Linux/macOS：只有 registry 同时提供 POSIX script execution provider 且 `sh` 可用时才允许 tmux provider probe；
- Windows/Unknown：返回 `.unsupported(.unsupportedPlatform)`，不执行任何 POSIX 命令；
- 平台探测本身失败：沿用 SSH/平台探测错误，不伪装为 tmux 未安装。

`RemoteCapability` 增加 `.persistentTerminal`，用于启动器展示整体状态；具体 provider/version/feature 信息保留在 `PersistentTerminalAvailability`。

### 11.2 动态能力

probe 至少取得：

- tmux executable 的可复用绝对路径；
- `tmux -V` 原始版本与可解析版本；
- 目标 server profile 是否存在、是否有 Session；
- Control Mode 和首期必要 client flags/commands 是否可用；
- `active-pane`、format subscription 等可选能力；
- 权限、socket 不可访问、配置错误和 server 不存在的区分。

Probe 分两阶段，且不得为了探测能力创建用户不可见的 Session：

1. **静态/无 Session 阶段：** 取得平台、executable、版本、无 start-server 副作用的 `list-commands` 语法、locator 状态和可取得的 server identity；server 不存在时返回 `.serverAbsent(canCreate: true)`，Control Mode/客户端 flag 状态记为 `.deferred`；
2. **Attach 阶段：** 只有用户选择已有 Session 或成功创建第一个 Session 后，才通过真实 attachment/control client 协商 `-CC`、client flags、format subscription 和 protocol dialect；失败只降级当前 provider，不创建额外工作区。

“Control Mode 可用”不能只由 `tmux -V` 推断，也不能在无 Session 时通过 `tmux -CC new-session` 偷偷建 Session。静态 probe 只能使用经目标版本验证不会设置 start-server 行为的只读命令；测试必须确认它不产生 tmux server 进程、socket 或 Session。可从 `list-commands` 安全确认的语法先确认，必须依赖 client 的能力延迟到第一次 Attach。一次启动选择器内缓存静态 probe；Attach 阶段的结果绑定 server instance token 和 SSH connection identity。

不使用单一版本号作乐观判断。版本用于选择初始 protocol dialect、诊断和测试矩阵，实际功能仍由命令/flag 能力协商决定：

- 满足 Control Mode、稳定 ID、可确认 protocol dialect 和安全 snapshot codec：完整拓扑模式；
- 同时满足 format subscription：动态 metadata 为 live；不满足时保持完整拓扑事件，但相关字段标记 snapshot/stale，不宣称实时；
- `no-output`、`wait-exit`、`ignore-size`、`active-pane` 等可选 client flag 分别影响带宽、关闭握手、尺寸和焦点隔离；缺少某一项只降级对应能力，不能把它们混成一个“Control Mode 不可用”；
- Control Mode 不满足必要能力、但普通 tmux 可用：pass-through attach + 按需 snapshot；
- tmux executable 缺失：自动普通 PTY；
- socket 暂无 server/Session：仍允许创建新 Session；
- socket 权限不足或配置错误：展示该 profile 的错误，同时允许普通 PTY。

能力状态不长期写数据库。一次启动选择器内复用同一次 probe；用户手动重试或连接身份改变后重新探测。

## 12. 数据面

### 12.1 启动

`TmuxProvider.openAttachment` 使用 `RemoteProcessChannel` 直接执行精确 attach 命令，不打开登录 Shell。通用 envelope 的 `providerPayload` 首期解码为：

```swift
public struct TmuxWorkspaceInstancePayload: Sendable, Codable, Equatable {
    public let serverInstanceToken: TmuxServerInstanceToken
}

public struct TmuxAttachmentPayload: Sendable, Codable, Equatable {
    public let lastKnownSessionName: String
    public let renderMode: TmuxRenderMode
}
```

`RemoteWorkspaceRef.workspaceID` 是 tmux `$sessionID`，其 `providerInstancePayload` 解码为 `TmuxWorkspaceInstancePayload`。attachment payload 不重复保存 envelope/ref 已有的 provider、profile、session ID 或 instance token。首期 `renderMode == .passthroughPTY`；后续增加 `.nativeControlMode` 时提升 attachment payload version，并保留旧版本 decoder。

首次打开 attachment 的顺序固定为：校验 descriptor/profile/token → 取得临时 observation lease，优先用不调用 `refresh-client -C` 的 Control Client 协商 client flags/dialect 并读取最新 client topology → 生成 data attach invocation。这样 `ignore-size/active-pane` 在交互 client 出现前已知，不会先用错误尺寸 Attach 再补救。Control Mode preflight 失败时释放临时 observation lease，使用安全 one-shot snapshot/静态语法能力给出对应 degraded 提示后仍可继续 pass-through；不能因为管理面失败而阻断用户已选择的 tmux 终端。若连 client topology 都无法安全读取，按外部 client 可能存在处理并采用最保守的可用 attach 配置。

交互 tmux client 必须有可被控制面精确定位的 `target-client`。数据面启动命令在非登录、非交互 POSIX shell 中输出带随机 nonce 的有界握手帧、当前 `tty` 和 `$$`，随后 `exec tmux attach-session`；renderer 在把输出交给 SwiftTerm 前以相同的有界 preamble 规则查找、消费并验证该帧，忽略帧前可能存在的非交互 Shell 启动输出。验证后的 PTY 名称和进程 PID 仅保存在当前 attachment runtime 中，用于：

- `switch-client -c <target-client> -t <target-pane>` 精确切换 Conn 这一个 client 的 Session/Window/Pane；
- `refresh-client -t <target-client>` 调整 client flag/尺寸策略；
- 区分 Conn 自己与外部 desktop client。

握手帧不得进入 transcript，nonce/tty/PID 不落盘。取得 PTY/PID 后，backend 用同一 profile 的 `list-clients` 同时验证 target-client identity 和 requested Session；验证成功才把 Tab 提交给 `TerminalSessionStore`。进程在 readiness deadline 前退出时使用 `RemoteProcessExit` 和有界 stderr 诊断返回启动失败，不能先创建一张 disconnected Tab。

握手超时、格式错误但远程进程仍在运行时，可以在 readiness deadline 后进入 pass-through degraded 模式；此时将未识别为合法握手帧的有界缓存按原顺序交还终端，隐藏原生 Window/Pane 切换和动态尺寸隔离，不能猜测 target-client。握手成功但 client 明确 Attach 到错误 Session 时必须关闭该 data channel 并报错，不能降级继续。

### 12.2 与现有 TerminalSession 的接线

首期普通 PTY 和 tmux pass-through 最终都是一个字节终端，不重写现有 `TerminalSession`/`TerminalTranscript`：

- `PlainPTYBackend` 继续把 `SSHSession.openShell()` 返回的 `ShellChannel` 交给 `TerminalSession`；
- `TmuxPassthroughAttachment` 位于 `ConnMultiplexer`，包装 `RemoteProcessChannel` 并实现 `PersistentTerminalAttachment`；其 `.byteTerminal` presentation 在握手帧消费后把 PTY 合并输出映射为 `ShellChannel`，并转发 write/resize/close；
- attachment 内只有一个 output pump 消费 `RemoteProcessChannel.output`：同一状态机先识别/消费握手，再把后续及降级时应保留的字节写入 sanitized `AsyncThrowingStream`。readiness 与 `TerminalSession` 共享这个 pump 的状态/结果，不能各自创建 iterator 竞争读取；Control Client 同样只有 parser actor 消费底层 output；
- readiness 成功后 attachment 在对应 instance Hub 登记 `attachmentID + tty + PID + requestedSessionID` 的 identity lease；该 lease 不要求 Control Client 存在，也不会单独触发控制通道。attachment close/重连替换时幂等注销旧 lease，避免以后把已退出或 tty 已复用的 client 认作 Conn；
- `ConnTerminal.PersistentProviderBackend` 不理解 tmux，只取得 `.byteTerminal` presentation 并交给现有 `TerminalSession`；
- `PersistentProviderBackend` 向 Coordinator 返回 channel、通用 descriptor 和 attachment handle；`TerminalSessionCoordinator` 复用现有 generation、transcript、lifecycle 和 Store 流程；
- `TerminalTab` 的 runtime 强持有 attachment handle，重连 descriptor 保存通用 `PersistentAttachmentDescriptor`；关闭/替换 Tab 时先停止本地 `TerminalSession`，再幂等关闭旧 handle，不能只关 byte channel 后遗留 provider lease；
- 首期不创建没有消费者的通用 Renderer 协议。未来全原生 Pane Renderer 复用 `ConnMultiplexer` 的 provider、状态和操作层，并增加新的 tab content/presentation 类型；它不要求修改启动选择器、远端 Catalog、profile 持久化或 tmux command API。

### 12.3 生命周期

- PTY EOF 表示本地 tmux client 退出，不代表远端 Session 被 Kill；
- 用户关闭 Tab 时关闭 PTY channel，即 Detach self；
- Session 在外部被 Kill 时，PTY 和 Control Mode 均会结束；协调器把 Tab 标记为远端对象不存在；
- SSH 断线后 Tab 进入 disconnected，但远端 Session 预期继续；
- 重连时先重新 probe server instance，再按原 Session ID Attach；
- server instance 改变或 Session ID 不存在时不自动创建同名 Session，返回“原会话已不存在”并让用户重新选择；
- 普通 PTY 保持现有 generation/transcript 行为；tmux 重连时 transcript 可以显示 generation boundary，但远端 scrollback 仍由 tmux 自己维护。

## 13. 控制面

### 13.1 TmuxControlHub

Hub 的共享 key：

```text
HostConnectionIdentity + TmuxServerProfileID + TmuxServerInstanceToken
```

一个 Hub 管理该 server instance 的：

- 全局 Session Catalog 快照；
- `sessionID → TmuxControlClient` 的观察租约；
- 活跃 data attachment 的 identity lease，用于把未来 `list-clients` 结果分类为 `.connInteractive`；
- 控制命令路由；
- client topology 与 capability 状态；
- 重连、退避和 snapshot reconciliation。

Hub 区分两种生命周期：data attachment 存活期间持有 identity lease，仅保存当前 generation 的 ownership 事实；UI/operation 持有 observation lease，后者才会创建或保持 Control Client。同一个远端 Session 被多个 Conn 视图观察时共享一个 Control Client；不同 Session 只有在终端/管理视图当前可见或有 pending operation 时才保持 Control Client。仅存在于 `TerminalSessionStore` 但处于后台的 Tab 保留 identity lease、不持有 observation lease；再次可见时重新取得 observation lease 并先校准 snapshot。Session Center 进入时执行一次全局 snapshot；无可见消费者且无 pending operation 时释放临时控制通道，不做全主机后台轮询。identity/observation lease 和 pending operation 都归零后，从 provider runtime registry 移除 Hub；不能让访问过的 server instance 永久驻留。

### 13.2 Control Client 启动参数

Control Client 使用 `RemoteProcessChannel` 直接启动 `tmux -CC attach-session`，不经过登录 Shell。建立后按实际协商能力配置：

- 支持 `no-output` 时启用，避免首期控制面接收 Pane 内容；不支持时解析器必须正确消费并丢弃 `%output/%extended-output`，超过带宽/缓冲预算则只降级控制面；
- 支持 `wait-exit` 时启用，以完成可确认的关闭握手；不支持时使用兼容关闭路径，不影响拓扑能力；
- 无论是否支持 `ignore-size`，首期 Control Client 都不调用 `refresh-client -C`，这是它不参与窗口尺寸的主约束；支持时可额外启用 `ignore-size` 作为防御性配置；

`active-pane` 设置在交互 tmux client，不依赖 Control Client 的当前 Pane。Control Client 通过已验证的交互 `target-client` 执行 `switch-client -c ... -t %pane`，否则原生选择会只改变控制通道自身而不会改变实际接收键盘输入的 Pane。

Control Client 与 data client 都必须通过 nonce + tty + PID 握手识别自己的 tmux `target-client`。Control Client 的 wrapper 先输出有界 nonce/tty/PID frame，再 `exec tmux -CC ...`；解析器先消费该 frame，再等待 DSC marker。Hub 将 frame 与当前 generation 的 `list-clients` identity 对照后登记为 `.connControl`，data attachment登记为 `.connInteractive(attachmentID)`，其余结果默认是 `.external`。Conn 不向远端 tmux option 写入 ownership tag。

`tmux -CC` 会发送官方 DSC 起始标记。Control Client 在看到该标记前处于 `awaitingProtocolMarker`，只收集有上限的 preamble 诊断，不解析 `%` 消息；看到标记后才进入协议解析。超过时间/字节上限仍未出现标记时关闭该 Control Client 并降级，避免 `.zshenv`、系统 banner 或错误文本被误解析为 tmux 事件。

关闭 Control Client 时遵循精确握手：当前 client 已成功启用 `wait-exit` 时先发送第一条空行请求 Detach，等待 `%exit`，再发送第二条空行 acknowledgement，最后等待 ST marker 和进程/通道 EOF；未启用 `wait-exit` 时只发送第一条空行并等待 `%exit`/ST/EOF，不发送第二条 acknowledgement。任一步超过关闭 deadline 才强制关闭当前 channel。该流程只结束控制 client，不 Kill Session，也不关闭交互 data client 或共享 SSHSession。

Control Client 必须可写，因为它需要执行管理命令；不能设置 `read-only`。只读 Attach 是后续独立产品能力，不与首期管理通道混用。

### 13.3 Session Catalog 与实时观察

- Catalog 是 tmux server 全局的一次性/事件触发快照；
- Control Client 只 Attach 一个 Session，提供该 Session Window/Pane 的实时事件；
- `%sessions-changed`、session rename 等全局相关事件使 Catalog 标记 dirty，并触发去抖后的重新抓取；
- 没有 Control Client 时，进入 Session Center、切换 profile、下拉刷新或操作完成后执行 snapshot；
- 完整 event + subscription 路径不固定运行 `list-*`；Control Mode、client inspection 或 metadata subscription 任一维度降级时，只对缺失维度在管理界面可见期间刷新：支持安全批量 codec 时默认 2 秒，legacy per-field codec 使用更低频率并标记 stale，用户离开界面立即停止，所有降级模式均保留手动下拉刷新。

### 13.4 通知、订阅与字段新鲜度

Control Mode 的原生通知足以驱动大部分拓扑变化，但不提供通用 `%client-attached`，也不会为 Pane 的 title/current command/current path 每次变化发送专用通知。完整实现按能力分层：

- 拓扑通知处理 `%sessions-changed`、`%window-*`、`%unlinked-window-*`、`%window-pane-changed`、`%layout-change` 和 `%client-*`；
- 支持 format subscription 时，为观察中的 Session 注册 `session_attached`，为 `%*` Pane 注册 `pane_title`、`pane_current_command`、`pane_current_path` 等 UI 实际展示字段；subscription value 仍通过 codec 解码；
- `session_attached` 变化只作为 client topology dirty 信号，随后执行 `list-clients`，不能凭计数猜 client ID/role/flags；
- `%layout-change` 必须解析 layout 中的 Pane ID/尺寸并验证与当前图一致，或立即抓取该 Window 的 Pane snapshot；不能只更新 layout 字符串而保留过期 Pane size；
- 不支持 subscription 时，动态 metadata 字段标为 stale/unknown 或由 feature set 隐藏；降级轮询只在对应管理 UI 可见时运行，昂贵的 legacy codec 可以降低频率并保留手动刷新；
- Session Catalog 中未被 Control Client 观察的 Session，其 affected attachment count 是带 `observedAt` 的快照值，不宣称全局实时；任何用于 Attach、Kill 确认或尺寸决策的 client topology 必须在操作前重新读取。

因此 `eventStreaming` 表示拓扑事件流能力，`dynamicMetadataSubscriptions` 单独表示 metadata 新鲜度，不能因为前者存在就把所有字段标记为实时。

### 13.5 命令路由与实例原子性

`TmuxCommandExecutor` 统一接收 typed operation，UI 不区分底层通道：

- 每种 `TmuxOperation` 显式声明 `.readOnly`、`.idempotentMutation` 或 `.nonIdempotentMutation/.destructive` 语义，executor 的 timeout/retry policy 由该元数据决定，调用页面不能自行猜测；
- 目标 Session 已有 ready Control Client：通过该 client 串行发送命令并等待 `%end/%error`；
- 创建第一个 Session、只打开 Session Center、目标 Session 未被观察或 Control Mode 已降级：通过 `SSHSession.exec` 执行同一个 typed operation 经 `TmuxShellInvocationRenderer` 生成的短命令；
- one-shot 命令完成后立即抓取相关 Catalog/Session snapshot；
- 任意 mutation（尤其 bootstrap/new/split/kill）在已发送后超时或 transport 中断都按“结果未知”处理，禁止自动重发；先用同 profile/token 校准 snapshot。只有确认尚未发送或 read-only query 才能按 policy 自动重试；
- Control Mode 命令失败不能静默改走 one-shot 重试，因为第一次命令可能已经生效；先 reconciliation，再由用户决定是否重试；
- 一次普通 operation 绑定 host connection identity、profile ID、server instance token 和 generation，不能跨重连换通道继续执行；
- one-shot 写操作必须在同一个 tmux client invocation 中先校验 `resolvedSocketPath/pid/start_time`，再执行 typed operation；不能先用一次 exec 比较 token，再用第二次 exec 执行；
- 同一 invocation 已连接的 server 在校验后退出时，当前操作按 transport/provider failure 结束，不允许 renderer 自动连接随后启动的新 server；
- Control Mode operation 只在已用同一 token 同步完成的 channel generation 上执行；channel 断开后的命令结果为 unknown/failed，禁止换新 channel 自动重放；
- snapshot 在同一 tmux invocation/control generation 中读取 instance identity 和实体；多命令 legacy snapshot 至少在首尾核对 token，任一处不一致就丢弃整批结果；
- 唯一不带 expected token 的写操作是 `.bootstrapCreateWorkspace`，并且只允许消费短时 `TmuxServerAbsentClaim(connectionIdentity, profileID, normalizedLocator, probeGeneration, observedAt)`；claim 必须来自最近一次静态 probe、与当前 context 完全匹配且一次性使用。单个 invocation 必须先启动/连接目标 locator、在同一 server command queue 中确认 `server_sessions == 0`，再执行 `new-session -d -P -F ...` 并原子返回新 `session_id`、`pid`、`start_time` 和 `socket_path`；若 probe 后已有其它客户端创建了 Session，bootstrap 必须拒绝并刷新 Catalog，不能把“刚出现的非空 server”当作自己创建的 server。明确存在但为空的 server 已有 instance token，走携带 expected token 的普通 create。返回值校验成功后才建立 Hub/descriptor，不能先创建再另行猜测 token。

## 14. Control Mode 协议状态机

### 14.1 连接状态

```text
idle
  → connecting
  → awaitingProtocolMarker
  → synchronizing
  → ready
  → recovering
  → synchronizing
  → ready

任何状态 → terminalFailure
任何活动状态 → closing → closed
任何状态 → closed
```

- `connecting`：远程进程 channel 与 `-CC` 握手；
- `awaitingProtocolMarker`：丢弃/隔离有界的 Shell preamble，等待 tmux `-CC` DSC 起始标记；
- `synchronizing`：读取 server identity、Session/Window/Pane/Client 完整快照；
- `ready`：应用事件、接受操作；
- `recovering`：协议缺口、channel 断开或 snapshot dirty，按有界退避重连；
- `terminalFailure`：明确不可恢复的版本、权限、socket 或协议错误；
- `closing`：按当前 client 已启用配置完成兼容 Detach；启用 `wait-exit` 时额外等待 acknowledgement，超时后只强制关闭当前 channel；
- 每一代 channel 有 generation，旧代次迟到事件和命令结果全部丢弃。

### 14.2 Protocol Dialect 与协商能力

不能把当前 tmux 的输出语法硬编码成唯一协议。例如 tmux 2.6 的 `%begin/%end/%error` guard 是 `time + command-number` 两个参数，较新版本增加 flags；`q:` quoting、`no-output`、`wait-exit`、`active-pane` 和 format subscription 也在不同版本出现。协议 grammar、server/client 能力和当前 client 已启用配置必须分开建模，不能用一个 `if version >= ...` 或一个“大而全 dialect”代表全部状态：

```swift
public struct TmuxProtocolDialect: Sendable, Equatable {
    public let commandGuardShape: TmuxCommandGuardShape   // twoFields / threeFields
    public let snapshotCodec: TmuxSnapshotCodecKind      // legacyPerField / quoted
}

public struct TmuxNegotiatedCapabilities: Sendable, Equatable {
    public let supportedClientFlags: Set<TmuxClientFlag>
    public let supportsFormatSubscriptions: Bool
}

public struct TmuxControlClientConfiguration: Sendable, Equatable {
    public let enabledClientFlags: Set<TmuxClientFlag>
    public let activeSubscriptionNames: Set<String>
}
```

版本只选择保守的初始候选；第一次无副作用 Control Mode 命令用实际 `%begin/%end` 确认 guard shape，`list-commands` 和真实 client flag/subscription 结果确认 capability，随后记录本 client 确实启用成功的配置。关闭握手、输出处理和尺寸策略只读取 enabled configuration，不能因为“版本理论支持”就假定 flag 已生效。实际结果与候选矛盾时降级或报 `.protocolViolation`，不能继续按错误 grammar 解析。Snapshot codec 是 grammar 的一部分：`quoted` 使用 `q:` lexer，`legacyPerField` 只批量读取安全 ID/数字并逐字段读取不可信文本。

### 14.3 字节流解析

`TmuxProtocolParser` 是增量字节解析器：

- 接受任意 Data chunk，不假设一块是一行；
- 起始 DSC marker 和退出 ST marker 同样支持跨 chunk 识别；
- 保留半行并限制最大缓冲；
- 按已确认 dialect 区分两参数或三参数 `%begin/%end/%error`、命令输出和异步通知；
- 通知不会插入命令输出块，但解析器不能依赖一次 read 只含一种消息；
- pane output 解码按 tmux octal escaping 规则实现，为未来 Renderer 留用；
- 未知 `%...` 通知作为 `.unknown` 保留并记录受限诊断，不让解析器崩溃；
- 无效 block nesting、超长行、非法转义或无法关联的终止块触发 reconciliation；
- 原始协议和远端标题默认不写日志；诊断只记录消息种类、长度和去敏 ID。

### 14.4 命令关联与并发

`TmuxControlClient` 是 actor，首期串行发送管理命令：

- 同一时刻只允许一个需要响应的命令在途；
- 命令等待匹配的 `%end` 或 `%error`；
- 异步通知在同一个 actor 中按流顺序交给 reducer；
- UI 操作在 actor 队列中串行，避免 rename/kill/select 的目标竞态；
- 命令有本地 deadline；deadline 只停止 UI 等待，随后把 client 标记 dirty/recovering，暂停或拒绝后续 mutation，直到看到原 command 的终止 guard 并完成 reconciliation barrier，或关闭该 generation 后重连。迟到 `%end/%error` 只用于诊断和触发校准，不能把已经提示“结果未知”的操作静默改成成功；
- 不做未确认的乐观领域状态修改；成功响应和事件后更新，缺少预期事件时以 snapshot 校准。

### 14.5 Snapshot Reconciliation

以下情况抓取完整快照：

- Control Client 首次 ready；
- SSH/Control Mode 重连；
- server instance token 变化；
- 收到未知但可能影响拓扑的通知；
- parser 检测到缺块、非法序列或 buffer overflow；
- 命令超时、响应成功但预期对象未出现；
- 用户下拉刷新。

reducer 以新快照原子替换当前 generation 的状态，再继续应用后续事件。旧 generation 的快照不得覆盖新连接。

## 15. 领域模型与 Store

### 15.1 tmux 快照

```swift
public struct TmuxServerSnapshot: Sendable, Equatable {
    public let instance: TmuxServerInstance
    public let sessions: [TmuxSessionID: TmuxSessionSnapshot]
    public let sessionGroups: [String: Set<TmuxSessionID>]
    public let windows: [TmuxWindowID: TmuxWindowSnapshot]
    public let panes: [TmuxPaneID: TmuxPaneSnapshot]
    public let windowLinks: [TmuxWindowLink]
    public let clients: [TmuxClientID: TmuxClientSnapshot]
    public let observedAt: Date
    public let revision: UInt64
    public let impactRevision: UInt64
}

public struct TmuxSessionSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxSessionID
    public let name: String
    public let groupName: String?
    public let currentWindowID: TmuxWindowID?
}

public struct TmuxWindowSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxWindowID
    public let name: String
    public let layout: String?
    public let isZoomed: Bool
    public let activePaneID: TmuxPaneID?
}

public struct TmuxPaneSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxPaneID
    public let windowID: TmuxWindowID
    public let index: Int
    public let title: TmuxObservedValue<String>
    public let currentCommand: TmuxObservedValue<String>
    public let currentPath: TmuxObservedValue<String>
    public let size: TermSize
    public let isDead: Bool
}

public struct TmuxObservedValue<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value?
    public let freshness: TmuxMetadataFreshness
}

public struct TmuxWindowLink: Sendable, Equatable {
    public let sessionID: TmuxSessionID
    public let windowID: TmuxWindowID
    public let index: Int
}

public struct TmuxClientID: Sendable, Equatable, Hashable {
    public let targetName: String
    public let processID: Int32?
    public let createdAt: Int64?
}

public struct TmuxClientSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxClientID
    public let sessionID: TmuxSessionID
    public let currentWindowID: TmuxWindowID?
    public let activePaneID: TmuxPaneID?
    public let flags: Set<TmuxClientFlag>?
    public let role: TmuxClientRole
    public let kind: TmuxClientKind
    public let sizeParticipation: TmuxClientSizeParticipation
    public let observedAt: Date
}

public enum TmuxClientRole: Sendable, Equatable {
    case connInteractive(attachmentID: String)
    case connControl(sessionID: TmuxSessionID)
    case external
}

public enum TmuxClientKind: Sendable, Equatable {
    case interactiveTerminal
    case controlMode
    case unknown
}

public enum TmuxClientSizeParticipation: Sendable, Equatable {
    case participating
    case ignored
    case notParticipating
    case unknown
}

public enum TmuxMetadataFreshness: Sendable, Equatable {
    case liveSubscription(observedAt: Date)
    case snapshot(observedAt: Date)
    case stale(lastObservedAt: Date?)
    case unavailable
}
```

tmux Window 可以手工 link 到多个 Session，Session group 也会共享同一组 Window，因此领域状态必须是规范化图，不能把同一个 Window 复制进多个 Session 树。UI 通过 `windowLinks` 和 Pane 的 `windowID` 投影 Session → Window → Pane；`sessionGroups` 记录 group membership，用于预测 `new-window` 等会传播到整组的操作。Session 的受影响 client 数从 `clients` 按 role/kind 推导；同一个 Window 的 rename/layout 事件只更新一份实体。首期虽然不提供 link/unlink 或创建 group 的 UI，也必须正确读取和展示用户已有的 linked windows/grouped sessions。

Client 的 ownership role、kind 和 size participation 是三个正交维度：role 回答“是不是 Conn 自己的通道”，kind 回答“交互终端还是 Control Mode”，size participation 回答“是否实际/可能影响窗口尺寸”。不能只看一个 `client_flags` 字符串推断全部语义。至少提供：

- `externalAttachedClientCount`：仅 `.external`；
- `affectedAttachedClientCount`：排除本 Hub 明确认领的 `.connControl`，其余 client 均计入；第三方 Control Mode client 也会被 Kill Session 影响；
- `interactiveClientCount`：kind 为 `.interactiveTerminal` 或 `.unknown` 且 role 不是 `.connControl`；未知按交互端保守处理；
- `sizeParticipatingClientCount`：size participation 为 `.participating` 或 `.unknown` 的数量；无法确认时按“可能参与尺寸”保守计入；
- `otherAffectedClientCount(relativeTo:)`：破坏性确认使用，排除当前 data attachment 和本 Hub 的 Control Client；
- `otherInteractiveClientCount(relativeTo:)`：焦点/共享 Window 提示使用，只统计 interactive/unknown。

本 Hub 的 Control Client 因明确从未调用 `refresh-client -C`，其 size participation 为 `.notParticipating`。第三方 Control Mode client 即使 `client_control_mode == 1`，也可能曾调用 `-C`；无法从目标版本格式证明时标为 `.unknown`，不能乐观排除。交互 client 的 `ignore-size` 已知时映射为 `.ignored`，flags 缺失时为 `.unknown`。

ownership role 只由当前 Hub generation 内的 tty/PID handshake 与 `list-clients` 对照产生；kind 来自安全读取的 `client_control_mode` 等格式和 Conn 自有通道事实。若旧版本缺少 PID/created/kind 格式，必须把对应能力标为 degraded，并至少结合唯一 tty、requested Session 和 attach 时序重新校准。无法证明属于 Conn 时 role 一律按 `.external`、kind/size participation 一律按 `.unknown` 处理，避免低估风险。

字段无法由某版本安全提供时为 optional/`unavailable` 或由 feature set 隐藏，不伪造值。Pane 的 title/current command/current path 各自携带 freshness，不能用一个总状态掩盖某项 subscription 失败。Session 的 current window、Window 的 active pane 与 client-specific 视图必须分开；不能把 Conn 交互 client 的当前状态覆盖成 server 全局状态。

`revision` 随任何状态变化递增；`impactRevision` 只在对象名称、link/group/Panes、client topology/flags 等会改变操作确认或隔离决策的字段变化时递增。Pane command/path/title 的普通 subscription 更新不能让用户正在阅读的破坏性确认无限失效。

### 15.2 双 Store

`TerminalSessionStore` 继续只保存本地 Tab：

- 普通 PTY Tab；
- tmux attachment Tab；
- 当前 SwiftTerm、transcript、连接状态和本地别名。

新增 `RemoteWorkspaceCatalogStore` 作为 `@MainActor @Observable` 展示投影：

- 按 host/profile 展示远端 Session Catalog；
- 持有 loading/ready/degraded/error/refreshing 状态；
- 订阅 Hub 的 AsyncStream snapshot；
- 不持有 SSH channel，不解析协议，不作为领域真相；
- UI 关闭后解除订阅，Hub 根据 lease 决定释放控制通道。

`TerminalSessionSource` 增加通用 persistent attachment 来源，但不能把整个 snapshot 存入 Tab，也不能硬编码每个 provider：

```swift
case persistent(providerID: String)
```

重连信息继续与展示来源分离。现有只含 `commandToReplay` 的 `TerminalReconnectDescriptor` 改为显式枚举：

```swift
public enum TerminalReconnectDescriptor: Sendable, Equatable {
    case shell
    case replayCommand(String)              // 现有 Docker console
    case persistent(PersistentAttachmentDescriptor)
}
```

脚本终端创建成功后仍使用 `.shell`，不保存或重放用户脚本；persistent 重连只能按 descriptor 的 `providerID` 通过 registry 调用 `openAttachment(... reason: .reconnect)`，不能从 alias、source 文案或 initial command 反推。未知 provider/payload version 保留 Tab 的诊断信息并标记不可重连，不 fallback 到 tmux 或普通 POSIX 命令。

## 16. 操作语义

### 16.1 Target 与校验

- 普通 operation envelope 必须携带 host connection identity、profile ID、expected server instance token、generation 和 typed entity ID；
- 校验 server instance token 与执行命令必须发生在同一 tmux invocation/control generation，UI 层的“操作前刷新”不能代替执行层原子 guard；
- `.bootstrapCreateWorkspace` 使用独立的无 token operation 类型，并要求调用方携带有效、同 context、一次性的 `TmuxServerAbsentClaim`；不能让任意 rename/kill/select/普通 create operation 把 token 设为 nil；
- typed operation 和两个 renderer 只接收 typed ID，不接收任意 target 字符串；
- 名称冲突、最后一个 Pane、最后一个 Window 等规则以 tmux 返回为准；
- 远端对象已不存在时转成 typed `.staleTarget`，刷新快照后给用户明确反馈；
- destructive action 的确认内容来自操作前最新快照；快照过旧时先刷新。

### 16.2 选择与创建

- select Window/Pane 通过 `switch-client -c <verified-interactive-client> -t <typed target>` 作用于 Conn 的交互 client，并等待事件/快照确认；
- 若交互 client 身份未完成握手，隐藏原生 select/focus 操作，用户仍可在 pass-through 终端里用自己的 tmux 键位；
- 新建 Window/Split 默认继承 tmux 自身 default shell 和用户配置；
- 在 grouped Session 中新建 Window 会同步到 group 内所有 Session；操作前用最新 group membership 展示共享影响。目标版本无法安全读取 group topology 时隐藏原生 New Window，用户仍可在 pass-through 终端内操作；
- 首期不擅自传 `-c currentPath`，避免路径不可访问、格式差异和跨版本问题；
- 不模拟 prefix 快捷键，直接使用 tmux command API；用户仍可以在终端内使用自己的 prefix。

### 16.3 破坏性操作

- 所有远端 mutation 先由纯 `TmuxOperationImpactAnalyzer` 基于规范化 link graph、session group、Pane 数和 client topology 计算 `affectedSessionIDs`、`destroyedSessionIDs/windowIDs/paneIDs`、其它 affected/interactive clients 以及共享可见状态变化；UI 文案和 operation guard 共用同一结果，不能各页面分别猜副作用；
- Kill Session、Close Window、Close Pane 都显示对象名称/编号；
- Kill Session 显示 `otherAffectedClientCount`，不把本 Hub 的 Conn Control Client 计入用户风险；
- `Kill Session` 只销毁目标 Session 并移除它的 Window links；仍被其它 Session link 的 Window/Pane 会继续存在，只有失去最后 link 的 Window 才连同 Pane 被销毁，确认页必须区分“从当前 Session 移除”和“真正终止 Pane”；
- `Close Window` 首期明确映射为 `kill-window`，不是 `unlink-window`；Window 被多个 Session link 时，确认页列出受影响 Session，并说明该 Window 会从所有 Session 消失；
- Rename Window、Split Pane、Zoom/Unzoom 和关闭 Pane 同样检查 `windowLinks`；共享 Window 上的名称、布局、状态或 Pane 变化可能影响所有关联 Session，不能只显示当前 Session。非破坏性的 Rename/Split/Zoom 至少展示共享影响提示，破坏性操作必须确认；
- Close 最后一个 Pane 可能连带销毁 Window/Session，确认文案必须反映快照中可推导的影响；
- destructive confirmation 必须基于操作前重新校准的 link graph 和 client topology，并生成短时 `TmuxDestructiveConfirmationClaim(instanceToken, generation, impactRevision, impactDigest, expiresAt)`；真正入队时任一字段过期、当前 `impactRevision` 已变化或重新计算的 impact digest 不同，都返回 `.staleConfirmation` 并要求重新确认，不能拿旧弹窗授权新的影响范围；
- executor 仍在同一 control generation/one-shot invocation 内做 target 与 server token guard；目标版本能安全表达的 link count、Pane count 等结构 precondition 一并校验。tmux 是多客户端系统，无法原子表达的外部变化不能伪装成强事务保证，UI 应说明确认后若拓扑变化操作可能被拒绝并刷新；
- 无法确认 snapshot 新鲜度时禁止执行并要求刷新；
- 命令 `%error` 不从本地 Store 删除对象；先显示失败，再校准；
- 操作成功后依赖事件更新；没有事件时立即 snapshot。

## 17. 多客户端隔离与终端尺寸

### 17.1 默认原则

Conn 不 detach 其他客户端，不修改全局 tmux option，不永久写入用户 server/session/window 配置。隔离优先使用 client flag 和当前 client 命令。

### 17.2 尺寸策略

- Control Client 始终不调用 `refresh-client -C`，支持时可额外设置 `ignore-size`；首期它不参与尺寸，除非将来全原生 Renderer 明确接管窗口尺寸；
- 支持 `ignore-size` 的交互 tmux client 初始一律带该 flag Attach，完成 tty ownership 验证和最新 `list-clients` 后再决定是否移除，避免 readiness 期间短暂改变外部布局；
- 不支持 `ignore-size` 时标记尺寸隔离 degraded；Attach 前发现其它 interactive client 或 size participation 未知的 client 时明确提示可能影响布局，且不提供动态 flag 切换承诺；
- 存在其它 size participation 为 `.participating/.unknown` 的 client 时保持 `ignore-size`，支持时同时使用 `active-pane`；本 Hub 的 Conn Control Client 明确为 `.notParticipating`，不进入这个判断；
- 没有其它 `.participating/.unknown` client 时允许 Conn 移除自身 `ignore-size` 并参与当前 Session 的尺寸，使手机终端可用；
- client topology 变化后重新评估 Conn client 的 size participation；实现必须通过目标 tmux 版本集成测试验证 `refresh-client`/client flag 的动态行为；
- 无法安全切换时优先保护外部客户端：Conn 转为 `ignore-size`，允许本地出现裁切/空白并给出提示；
- 不修改用户的全局 `window-size`、`aggressive-resize` 或 `default-size`；
- resize 高频事件做去抖和去重，避免拖动界面时淹没 SSH channel。

### 17.3 Active Pane 与 Zoom

- 支持 `active-pane` 时，Conn 通过已验证的交互 target-client 使用独立 pane focus；
- 不支持时，原生 Pane 列表的 select 会改变 tmux Window active pane，并可能被其他客户端看到，UI 标记 degraded；
- `active-pane` 只隔离同一 Window 内的 Pane，不承诺隔离 Session 的 current window；选择另一个 Window 仍遵循远端 tmux 的共享语义，可能让同 Session 的其他 pass-through client 一起切换；
- UI 在存在其它 interactive client 时对 Window 切换显示共享状态提示，但不阻止操作；这是普通 tmux Attach 的固有语义，只有未来逐 Pane 原生 Renderer 才能完全摆脱共享可见 Window；
- Zoom 是 Window 级远端状态，即使有 `active-pane` 也可能影响其它 attached client 和 linked Session；存在任一影响对象时始终提示；
- Conn 退出时不自动 unzoom，避免撤销用户或其他客户端主动设置的状态。

## 18. 生命周期、后台与重连

### 18.1 App 前后台

- 页面消失只释放 UI subscription，不关闭可见 TerminalTab 的交互 PTY；
- App 长时间后台后，沿用现有 SSH 失效策略；本地 data/control channels 进入 disconnected；
- 不尝试依靠 iOS 后台保活维持 SSH；tmux 是持久性的权威；
- 回前台按需重新建立 SSH、probe server、校验 instance token、Attach Session；
- 不在回前台时扫描全部 host 或全部 socket。

### 18.2 重连协调

同一个 tmux Tab 的数据面和控制面分别重连：

1. `TerminalSessionCoordinator` 负责本地 data plane generation；
2. `TmuxControlHub` 负责 control plane generation；
3. 数据面成功、控制面失败：终端继续可用，管理 UI degraded 并允许重试；
4. 控制面成功、数据面失败：Catalog 可见，但 Tab 标记 disconnected，用户可以重新 Attach；
5. 两者不因一方 close 而调用 `ConnectionManager.disconnect(host:)`；
6. 共享 SSH 实际已死时，沿用 `ConnectionManager.session(for:)` 的存活检查和一次驱逐重试策略；
7. 重连任务按 host/profile/session 去重，取消不能作为唯一正确性保证，必须检查 generation。
8. backend profile 被禁用、删除或 identity 发生变化时，立即使旧 profile 的 Catalog/Hub/operation generation 失效并禁止新 Attach/重连，但不主动 Kill Session，也不强关仍可使用的 pass-through data channel；现有 Tab 标记“配置已失效、不可重连”，直到用户关闭或重新选择 profile。

### 18.3 Hub 退避

Control Mode 恢复使用有上限的指数退避并加入抖动；仅在存在 observation lease 或 pending operation 时重试，只有 identity lease 的后台 Tab 不维持控制面。网络不可用、App 后台或最后一个 observation lease 释放时停止。用户主动重试立即开始新 generation。

## 19. 错误模型与降级

新增结构化错误：

```swift
public enum PersistentPayloadComponent: String, Sendable, Equatable {
    case workspaceInstance
    case attachment
}

public enum PersistentTerminalError: Error, Sendable, Equatable {
    case unsupportedPlatform
    case providerNotRegistered(String)
    case providerDisabled
    case profileUnavailable(String)
    case executableMissing
    case incompatibleVersion(String?)
    case serverUnavailable
    case socketPermissionDenied
    case invalidConfiguration
    case unsupportedDescriptorVersion(
        providerID: String,
        component: PersistentPayloadComponent,
        version: Int
    )
    case unsupportedFeature(providerID: String, feature: String)
    case controlModeUnavailable
    case protocolViolation
    case serverInstanceChanged
    case bootstrapPreconditionChanged
    case staleConfirmation
    case staleTarget
    case remoteObjectMissing
    case commandRejected(String)
    case operationOutcomeUnknown
    case transportClosed
}
```

错误处理规则：

- SSH 建连、认证、host key、channel 等错误保留 `SSHError`；
- tmux 命令成功执行但环境不可用时映射 provider error，不伪装为网络错误；
- tmux 未安装：启动普通 PTY，不展示阻断页；
- Control Mode 不可用：允许 pass-through attach；管理界面显示“有限状态同步”并提供手动刷新；
- protocol violation：停止应用增量事件，保留最后一次 snapshot 为 stale，只读显示，随后重连校准；
- expected token 与同一 invocation 中读到的 instance 不一致：返回 `.serverInstanceChanged`，不发送后续操作命令；
- mutation command 在已发送后超时/断线：明确提示“结果未知”，禁止自动重试，先 snapshot；bootstrap 也必须先发现是否已创建，不能重复 new；
- 普通查询可以在校准后由用户重试；
- 远端原始 stderr 不直接作为本地化正文，但可作为受限详情展示。

## 20. 持久化设计

### 20.1 需要持久化的内容

持久化的是用户配置，不是远端运行状态。通过 `SchemaV4` 新增与项目现有命名、外键和时间类型一致的 `terminal_backend_profile`：

```text
uuid                       TEXT PRIMARY KEY
host_uuid                  TEXT NOT NULL REFERENCES host(uuid) ON DELETE CASCADE
provider_id                TEXT NOT NULL
provider_configuration_key TEXT NOT NULL
display_name               TEXT NOT NULL
is_enabled                 INTEGER NOT NULL DEFAULT 1
is_primary                 INTEGER NOT NULL DEFAULT 0
configuration_version      INTEGER NOT NULL
configuration_json         TEXT NOT NULL
sort_order                 INTEGER NOT NULL DEFAULT 0
created_at                 INTEGER NOT NULL
updated_at                 INTEGER NOT NULL
sync_dirty                 INTEGER NOT NULL DEFAULT 0
```

规则：

- `provider_id` 首期为稳定值 `tmux`；
- `configuration_json` 由对应 provider 按版本解码；未知 provider/config version 保留记录但不执行；
- `provider_configuration_key` 是 provider 为配置生成的稳定身份键；tmux 使用带类型标签的 `default`、`named:<normalized-name>`、`path:<normalized-path>`，规范化规则见 10.1，`-S` 路径不远程解析 symlink；
- `TerminalBackendProfile.id` 是 descriptor 使用的稳定 `profileID`。隐式 default profile 使用由 `host UUID + provider ID + provider_configuration_key` 按固定 namespace 生成的确定性 UUID；首次物化或禁用 default 时沿用同一 UUID，不能让一张已打开 Tab 因“隐式变显式”而失去 profile；
- `provider_configuration_key` 对一个 profile 记录不可变；修改 locator 或其它 provider identity 字段要创建新 profile ID，并让旧 profile 的 Hub/operation generation 失效，不能在原 ID 下把已打开 attachment 悄悄改指向另一 server。display name、排序和 enabled 等非 identity 字段可原地修改；
- `(host_uuid, provider_id, provider_configuration_key)` 建唯一索引，避免同一 locator 被重复配置并创建多个 Hub；
- 一个 host/provider 最多一个 `is_primary`，由 `(host_uuid, provider_id) WHERE is_primary = 1` 的唯一部分索引保证；它只决定启动器首先查询哪个 socket，不自动跳过启动选择器；
- primary 必须同时 enabled；repository 在一个数据库事务内完成旧 primary 清除、新 primary 设置以及 `updated_at/sync_dirty` 更新。禁用或删除 primary 时按 `sort_order, created_at, uuid` 选择下一个 enabled profile，若没有则保持无 primary；不能留下指向 disabled profile 的启动默认值；
- 未配置 profile 时提供隐式的 tmux default socket profile；用户编辑后可物化为记录；
- 用户禁用隐式 default profile 时物化一条 `is_enabled = 0` 的 default locator 记录，避免“没有记录”再次被解释为启用；
- `-L`/`-S` profile 可以有多个，但 Conn 只查询用户当前选择或已配置的 profile；
- host connection identity 改变时 profile 仍属于 host 配置，但所有运行时 snapshot/channel 失效并重新 probe；
- `created_at/updated_at` 使用项目统一的 `Int64` 毫秒时间戳；profile 是用户配置，遵循现有实体的 `sync_dirty` 约定；
- profile 删除使用当前项目一致的真删除语义；`host` 删除由外键 cascade 清理；
- App 尚未发布也使用正式 `SchemaV4` migration，不在启动代码中临时 ALTER 或修改旧 migration。

模块边界：

- `ConnKit` 定义 provider-neutral 的 `TerminalBackendProfile` 值类型和 `TerminalBackendProfileRepository`；其中 configuration 保持 opaque，不依赖 tmux 类型；
- `ConnStore` 定义 `TerminalBackendProfileRecord`、GRDB repository 和 `SchemaV4`；
- `ConnMultiplexer` 的 provider 按 `providerID/configurationVersion` 解码 configuration，并生成/校验 `providerConfigurationKey`；
- App 组合根把 repository 与 provider registry 注入终端/Catalog，不允许 `ConnTerminal` 直接访问 GRDB。

### 20.2 不持久化的内容

- Session/Window/Pane/Client snapshot；
- tmux `$`/`@`/`%` ID；
- server instance token；
- Control Mode channel 与 command queue；
- Pane output、`capture-pane` 内容和缩略图；
- 动态 availability、版本和 socket 权限结果；
- 本地活 TerminalTab（沿用现有内存语义）。

## 21. 安全与隐私

- 不自动安装 tmux，不运行包管理器，不修改 rc/tmux 配置；
- 只在用户保存的 host 和 server profile 范围内执行命令；
- `-S` path 视为不可信配置，必须转义，不允许拼接额外参数；
- Session/Window 名称、Pane title/path/current command 视为远端不可信展示数据；
- UI 使用单独的 display sanitizer 限长并把 C0/C1、ESC 和双向文本控制符可视化/隔离；领域层保留有界 raw value 供刷新比较，但绝不把 sanitized 文本反用于 target 或命令构造；
- 命令构造使用 typed operation + argument encoder，UI 不提交 raw tmux command；
- 首期不开放“执行任意 tmux command”的高级入口；
- Control Mode 原始流、Pane 内容和 snapshot 默认不写日志或 analytics；
- 错误遥测只包含 provider、feature、状态码和去标识版本，不包含主机、socket path、标题、路径或命令内容；
- future snapshot thumbnail/capture-pane 必须另行评审隐私、缓存和清理策略；
- Kill/Close 等操作进入现有审计/确认体系时记录结构化操作，不记录 Pane 输出。

## 22. 测试与验收矩阵

### 22.1 纯单元测试

`ConnMultiplexerTests` 必须覆盖：

- Control Mode 字节逐 byte、随机 chunk、半行、多行和 CR/LF 分块；
- tmux 2.6 两参数与新版本三参数 `%begin/%end/%error`、空输出、异步通知和未知通知；
- octal escape、无效 escape、非 UTF-8 Pane 数据；
- 最大行/缓冲限制和恢复；
- `quoted` 与 `legacyPerField` snapshot codec 中的空格、引号、分隔符、换行和 Unicode 名称；
- display sanitizer 对 ESC/C0/C1、双向文本控制符、超长名称和路径做有界安全展示，typed target 仍只使用 ID；
- 同一 typed operation 分别经 Control renderer 和 Shell renderer 生成正确命令，Shell script 再由 POSIX execution provider 包装为明确 `sh -c`；executable/locator/POSIX quoting 不进入 Control Mode；
- reducer 的 add/rename/close/select/layout/zoom、format subscription、metadata freshness 和 client topology 事件；
- `%layout-change` 后解析 Pane 尺寸或触发 Window snapshot，不能保留过期尺寸；
- generation 丢弃迟到事件、快照和命令结果；
- command timeout 后 dirty/reconciliation；
- read-only 与 mutation 的 retry policy 分离；create/split/kill/bootstrap 在已发送后 timeout 均不得自动重放；
- 当前 client 确实启用 `wait-exit` 时两次空行、未启用时一次空行，以及关闭超时强制收尾；
- provider registry 的 Linux/macOS 命中与 Windows/Unknown 拒绝；
- 通用 persistent descriptor 的 initial/reconnect、未知 provider/version 拒绝和 provider-owned close；
- attachment identity lease 与 observation lease 相互独立，后台 Tab 不保持 Control Client，close/重连替换会注销旧 tty/PID ownership；
- profile 的 default/`-L`/`-S` 互斥与配置版本；
- server token 的 socket/PID/start time、PID 复用与 token 变化；
- 普通 operation 必须携带 token，只有持有有效一次性 `TmuxServerAbsentClaim` 的 `.bootstrapCreateWorkspace` 可无 token；claim 跨 connection/profile/generation/期限不可复用，probe 后 server 已变为非空时 bootstrap 原子拒绝；
- `.connInteractive/.connControl/.external` ownership、interactive/control/unknown kind 和 size participation 分类；本 Hub Control Client 不进入 affected/interactive/size 风险计数，第三方 Control Mode 无法证明尺寸时保持 unknown；
- linked Window 的 rename/zoom/kill/最后 Pane 影响计算；
- `TmuxOperationImpactAnalyzer` 对 Kill Session 保留仍有其它 link 的 Window，对 Split/Rename/Zoom 输出跨 Session 共享影响，并识别 grouped Session 的 New Window 传播；
- destructive confirmation claim 绑定 instance/generation/impactRevision/impact digest，过期或影响状态事件先到时拒绝旧确认；普通 Pane metadata 更新不应误伤确认；
- data/control plane 独立失败；
- Hub lease 复用与最后一个 lease 释放；
- server instance 改变后旧 ID 失效。

Parser 使用 fuzz/property tests 生成随机分块；相同完整协议输入在所有分块方式下必须产生相同事件序列。

`ConnStoreTests` 必须覆盖 `SchemaV4`：表/列名、`host(uuid)` cascade、毫秒时间戳、`sync_dirty`、profile identity 唯一索引、primary 部分唯一索引，以及未知 provider/config version 的无损往返。`ConnTerminalTests` 使用 fake provider 验证 Coordinator 只按通用 descriptor/registry 打开和重连，测试代码不需要出现 tmux 分支。

### 22.2 SSH 引擎测试

`ConnSSHCitadelTests` 覆盖 `RemoteProcessChannel`：

- direct exec 不启动交互式/登录 Shell；即使 SSH server 的非交互 Shell 仍产生启动 preamble，机器协议也能靠有界握手帧隔离；
- Control Mode 在随机 Shell preamble 后依次验证 nonce/tty/PID frame 和 `-CC` DSC marker；marker 缺失/超限时安全降级；
- 可写 stdin、持续读取 stdout/stderr；
- 高吞吐输出下保持顺序并施加有界 backpressure，不能静默丢 terminal/control 字节或无限增长内存；
- PTY 可选申请和 resize；
- tmux 数据面握手帧能取得并验证远端 PTY/PID，且不会进入终端 transcript；
- readiness 与 TerminalSession 共用单一 output pump，不发生双 iterator 丢字节；降级时未匹配缓存按原顺序只转发一次；
- 握手 marker 不可用但进程持续运行时只降级原生切换，不阻断 pass-through 终端；
- 已验证 client Attach 到错误 Session 时关闭 channel 并判定启动失败；
- 远程进程在 readiness 前非零退出不会产生 TerminalTab，exit-status/exit-signal 可被诊断；
- writer 未就绪前不返回；
- 正常 EOF、远端失败、本地 close 和并发 close 只结束一次；
- 关闭一个 process channel 不影响同一 SSHSession 的其它 PTY/exec；
- cancellation/迟到 channel 不泄漏；
- 经 jump host 的共享 session 同样可开 control/data channel。

### 22.3 tmux 集成测试

自动集成环境至少覆盖 tmux 2.6、3.0、3.2 系列和当前稳定版本；真实 macOS SSH 验收覆盖当前 Homebrew tmux。若某版本缺少 optional feature，测试必须验证对应 dialect/degraded 路径，而不是跳过。

场景包括：

- 无 server、空 server、一个/多个 Session；静态 probe 不得创建 Session，首次创建必须由单个 bootstrap invocation 返回 token 和 Session ID；
- default、`-L`、`-S`；
- 新建、重命名、Kill Session；
- Window/Pane 全部首期操作；
- 桌面/第二客户端在 Conn 外部修改状态；
- 同一 Session 多 Conn consumer 共享 Control Client；
- SSH 断线后远端 Session 继续并成功重新 Attach；
- tmux server 重启导致 instance token 改变；
- 在 token 校验与写操作竞态窗口重启 server，旧 operation 必须失败且不能命中新 server 的同号 ID；
- 外部 Kill 当前 Session；
- Control Mode channel 断开而 data plane 继续；
- data plane 断开而 Catalog 继续；
- socket 权限不足、tmux 配置错误、版本能力缺失；
- 外部 client attach/detach 后 `session_attached` 触发 `list-clients`，client ownership/kind、affected attachment count 和尺寸策略正确更新；
- 其他客户端存在时尺寸和 active pane 保护；Control Client 不得被误判为外部 size participant；
- 首次数据 Attach 前已完成 Control/one-shot preflight；目标版本支持 `ignore-size` 且已有桌面 client 时，不能出现“先按手机尺寸 resize、随后再 ignore-size”的瞬时布局扰动；
- `switch-client -c` 只改变 Conn 交互 client 的目标 Pane，不改变外部 client；
- 同一 Window link 到多个 Session 时只保留一份 Window 实体，Kill/Rename/Split/Zoom/最后 Pane 的影响范围正确；grouped Session 新建 Window 会刷新整组 links，Kill 一个 Session 不误删其它成员仍引用的 Window；
- Session/Window 名称覆盖 Unicode、空格、引号和目标版本实际允许的格式分隔符；Pane title/path/current command 与 codec 单测覆盖换行和控制字符。Conn 主动创建/重命名时不允许的控制字符必须在发送命令前被拒绝；

### 22.4 UI 验收

仅复用用户已启动的模拟器并指定其 UDID，遵守项目 `AGENTS.md`。UI 验收至少覆盖：

- tmux 缺失自动普通 PTY；
- tmux 可用时每次显示选择器；
- Session Center 按 host/profile 按需加载；
- loading、empty、degraded、stale、disconnected 和 error；
- Session → Window → Pane 管理；
- destructive confirmation 与其它 affected/interactive client 提示；
- linked Window 的跨 Session 影响确认，且提示计数不包含 Conn Control Client；
- iPhone Pane 列表切换；
- iPad 横屏完整布局；
- Dynamic Type、本地化、VoiceOver label 和按钮可达性；
- 普通终端、Docker Console、脚本终端无回归。

### 22.5 完成判据

- Linux/macOS 上 tmux 可用时启动器、Attach 和全部首期管理操作可用；
- Windows/Unknown 没有任何 tmux/POSIX probe；
- `TerminalSessionCoordinator` 只消费通用 provider/descriptor，增加新 persistent provider 不需要新增核心枚举分支；
- App/SSH 断开不 Kill 远端 tmux Session；
- 关闭 Tab 只 Detach；
- 完整 event + subscription 模式无固定周期 `list-*` 轮询；缺少 optional capability 时只对缺失维度做可见性约束的降级刷新；
- 外部拓扑变化可以事件驱动同步；动态 metadata 由 subscription 更新，不支持时明确 stale/hidden，异常后能通过 snapshot 自愈；
- 所有带远端 ID 的写操作在同一 tmux invocation/control generation 内校验 socket/PID/start time，server 重启后不能误操作新对象；
- 已有外部客户端不会被 Conn detach；
- 本 Hub 的 Control Client 不参与用户 affected 风险计数或窗口尺寸；第三方/未知 Control Mode client 保守处理；linked Window 的跨 Session 影响在破坏性操作前明确展示；
- 控制面故障不会关闭仍可用的终端数据面；
- 不写入远端 snapshot 或 Pane 内容到数据库；
- `SchemaV4` 遵循现有 `host(uuid)`、毫秒时间戳、`sync_dirty` 和 repository 分层；
- parser/reducer/typed operation/双 renderer 能在 host 单元测试运行；
- 现有普通 PTY、多会话、Docker、脚本终端测试全部通过。

## 23. 演进路线与扩展性

### 23.1 全原生 Pane Renderer

后续 `ControlModePaneRenderer` 可以：

- 关闭 `no-output`，消费 `%output/%extended-output`；
- 为每个 `%pane` 维护独立 SwiftTerm 实例；
- 使用 `pause-after` 做流控，暂停后 `capture-pane` 校准；
- 将 tmux Window layout 映射为本地 Split View；
- 使用 `refresh-client -C` 报告每个 Window/Pane 尺寸；
- 自行处理 tmux 不会发送的 copy/choose mode 画面。

由于 provider、Control Client、ID、snapshot 和 operation 已独立，升级主要新增 Renderer、pane-output 状态和新的 tab content/presentation，不改变启动器、Catalog、profile 持久化和 tmux 操作接口。

### 23.2 其它 Multiplexer

- **Zellij：** 新 provider 和专有 topology/controller；复用 `RemoteProcessChannel`、profile、Catalog 顶层模型和 attachment 生命周期；
- **GNU Screen：** 只声明自身支持的 workspace/window 能力，不伪造 Pane；
- **Windows：** 将来注册 PowerShell/Windows Terminal/其它 persistent provider；不复用 POSIX Shell renderer；
- **WSL：** 作为用户明确配置的 provider/profile，而不是按 Windows 主机自动猜测；
- **远程 Agent：** 可以成为新的 transport/provider，不修改 tmux provider。

### 23.3 产品增强

按价值排序的候选：

1. Session `capture-pane` 缩略图与隐私策略；
2. attached client 列表、只读 Attach、显式 Detach other client；
3. Handoff/Universal Link 深链到 host/profile/session name；
4. Mosh transport；
5. 收藏、排序和最近使用的远端 Session；
6. 全原生 Pane Renderer；
7. Agent 驱动的后台任务和远端工作区。

这些能力不能被首期类型阻塞，但不提前实现无当前消费者的协议或 UI。

## 24. 实现边界与禁止旁路

- UI 不得调用 `SSHSession.exec("tmux ...")` 拼命令；全部经过 `TmuxProvider`/controller；
- `TerminalSessionCoordinator`/`PersistentProviderBackend` 不得按 tmux、Zellij、Screen 或 Windows provider 写 `switch`；只按通用 descriptor 和 registry 调用生命周期接口；
- Control Mode 不得通过 `openShell()` 后发送 `tmux -CC`；必须使用 direct `openProcess`；
- Control Mode command 不得复用包含 executable/locator/POSIX quoting 的 Shell invocation；
- tmux snapshot 不得放入 `ConnectionManager` 或 SQLite；
- `TerminalSessionStore` 不得成为远端 Session Catalog；
- 不能因为 Control Mode error 就 Kill/Detach 交互 tmux client；
- 不能因为关闭一个 data/control channel 就 disconnect 共享 SSHSession；
- Windows/Unknown 不得 fallback 到 POSIX tmux provider；
- 不得用 Session/Window 名称或 index 代替稳定 ID 执行操作；
- 不得先用一次 SSH exec 校验 server token、再用第二次 exec 执行写操作；
- 不得把本 Hub 的 Conn Control Client 计入 affected/interactive client 风险和尺寸参与者，也不得把无法认领的第三方 Control Mode 乐观排除；
- 不得把 linked/grouped Window 的 Kill/Rename/Split/Zoom/Pane/New Window 影响描述成仅作用于当前 Session；
- 不得修改用户全局 tmux option 来解决 Conn 客户端尺寸或焦点问题；
- 不得为了 probe Control Mode 或 flag 支持自动创建临时 Session；
- 不得在启动代码临时改表，或使用与现有 `host(uuid)`/毫秒时间戳约定冲突的 profile schema；
- 不得把定时轮询作为完整模式的权威状态源。

## 25. 参考资料

- tmux manual: <https://man.openbsd.org/tmux.1>
- tmux Control Mode: <https://github.com/tmux/tmux/wiki/Control-Mode>
- tmux Formats: <https://github.com/tmux/tmux/wiki/Formats>
- iTerm2 tmux integration: <https://iterm2.com/documentation-tmux-integration.html>
- Secure ShellFish Terminal Multiplexing: <https://secureshellfish.app/help/tmux>
- TermRover Guide: <https://termrover.sh/guide>
- Pocketmux documentation: <https://docs.pmux.io/>
- WezTerm Multiplexing: <https://wezterm.org/multiplexing.html>
- Warp SSH Control Mode use: <https://docs.warp.dev/terminal/warpify/ssh>
