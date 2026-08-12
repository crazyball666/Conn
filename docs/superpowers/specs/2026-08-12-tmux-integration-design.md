# Conn tmux 原生集成设计

**日期：** 2026-08-12  
**状态：** 已确认，待实现计划  
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
- 关闭 Conn tmux Tab、关闭 Modal、App 进入后台或 SSH 断线只结束本地 tmux client；
- Detach 自己不需要破坏性确认；
- Kill Session、Close Window、Close Pane 必须走专用操作；
- Kill Session 前显示名称、Window/Pane 数量和 attached client 数；有其他客户端时加强提示；
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

`TmuxServerInstanceToken` 至少包含 socket profile 和本次探测到的 server PID/等价实例标识。SSH 重连后：

- instance token 相同：可以继续用旧 `$`/`@`/`%` ID 校准；
- instance token 改变：旧 ID 全部失效，必须清空状态并重新发现；
- Session 名称只作为重新选择建议，不能在 server 重启后静默替代旧 ID Attach。

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
│   └── TmuxPassthroughBackend
└── ControlModePaneRenderer            后续独立渲染面
          │
ConnMultiplexer                        新增纯 Swift target
├── PersistentTerminalProvider
├── PersistentTerminalProviderRegistry
├── TmuxProvider
├── TmuxControlHub
├── TmuxControlClient
├── TmuxProtocolParser
├── TmuxCommandEncoder
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
- `result()` 等待同一远程进程的 exit-status/exit-signal；server 未提供时字段为 nil，不为了结果累计无限 stdout/stderr；
- 远端 EOF、通道错误、本地关闭只完成一次；
- `close()` 只关闭当前 SSH channel，不关闭共享 `SSHSession`；
- 创建任务不响应 cancellation 时，采用现有 generation/claim 思路阻止迟到 channel 泄漏；
- Citadel 若没有公开足够 API，允许在 `ConnSSHCitadel` 内使用其 NIOSSH 底层能力或维护最小适配补丁，但不能把 Citadel 类型泄漏到 `ConnSSH`。

现有 `ShellChannel` 保留，避免无关调用点迁移。后续可让 `openShell()` 在引擎内部复用 `openProcess()`，但这不是 tmux 首期的前置条件。

## 9. 持久终端 Provider 抽象

### 9.1 不建立虚假的统一三层树

通用抽象只覆盖“探测、列出顶层工作区、创建、Attach、结束本地 attachment”。Window/Pane 等高级结构由 feature facet 表达：

```swift
public protocol PersistentTerminalProvider: Sendable {
    var descriptor: PersistentTerminalProviderDescriptor { get }

    func probe(
        on session: any SSHSession,
        profile: RemotePlatformProfile,
        configuration: PersistentTerminalConfiguration
    ) async throws -> PersistentTerminalAvailability

    func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary]
    func createWorkspace(_ request: CreateWorkspaceRequest, in context: PersistentTerminalContext) async throws -> RemoteWorkspaceRef
    func makeAttachment(to workspace: RemoteWorkspaceRef, in context: PersistentTerminalContext) throws -> TerminalAttachmentDescriptor
}
```

`RemoteWorkspaceSummary` 只包含 provider-independent 顶层信息：稳定引用、名称、创建/活动时间（provider 可提供时）、attached client 数、简要状态。tmux Window/Pane 使用 `TmuxWorkspaceSnapshot` 和 `TmuxWorkspaceManaging`，不塞入通用模型。

### 9.2 Feature set

Provider descriptor 声明能力，不支持的操作不出现在 UI：

```text
workspaceDiscovery
workspaceCreation
workspaceRename
workspaceDestruction
eventStreaming
clientInspection
clientManagement
hierarchicalWindows
hierarchicalPanes
readOnlyAttach
snapshotPreview
nativePaneOutput
```

首期 tmux provider 实现前五项以及 Window/Pane 层级；`clientInspection` 只用于 attached client 数和安全提示，不提供踢出其他客户端的 UI。其它能力留作后续。

### 9.3 Registry

`PersistentTerminalProviderRegistry` 在 App 组合层注入 provider：

- 默认注册 `TmuxProvider`；
- provider 选择同时检查平台、provider ID 和 profile configuration；
- 没有匹配 provider 时返回 unsupported，不回退到 POSIX；
- 普通 PTY 不伪装为 persistent provider，继续作为终端 launch backend 的基础选项；
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

### 10.2 命令安全

- tmux 可执行文件来自只读 probe 的固定候选或 `command -v tmux` 结果；
- locator、Session 名称等参数使用统一 POSIX shell argument encoder；
- UI 文本不得直接插值为整条命令；
- tmux target 始终使用已解析的 `$`/`@`/`%` ID；
- 创建或重命名时先执行产品级名称校验，再由 encoder 负责 shell 转义；
- snapshot format 不能用简单 tab/pipe split 解析任意远端名称，必须使用统一的 `TmuxFormatCodec` 转义/解码；
- 未知或无法解码的字段保留原始诊断但不进入可操作 ID 集合。

## 11. Probe 与能力协商

### 11.1 平台路由

- Linux/macOS：允许 tmux provider probe；
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

不使用单一版本号作乐观判断。版本用于诊断和测试矩阵，实际功能由命令/flag 能力协商决定：

- 满足 Control Mode、`no-output`、`ignore-size`、稳定 ID 和 list format：完整首期模式；
- Control Mode 可启动但缺少可选 flag：标记 degraded，并关闭对应隔离能力；
- Control Mode 不满足必要能力、但普通 tmux 可用：pass-through attach + 按需 snapshot；
- tmux executable 缺失：自动普通 PTY；
- socket 暂无 server/Session：仍允许创建新 Session；
- socket 权限不足或配置错误：展示该 profile 的错误，同时允许普通 PTY。

能力状态不长期写数据库。一次启动选择器内复用同一次 probe；用户手动重试或连接身份改变后重新探测。

## 12. 数据面

### 12.1 启动

`TmuxPassthroughBackend` 使用 `RemoteProcessChannel` 直接执行精确 attach 命令，不打开登录 Shell。attachment descriptor 至少包含：

```swift
public struct TmuxAttachmentDescriptor: Sendable, Equatable {
    public let profileID: String
    public let serverInstanceToken: String
    public let sessionID: String
    public let lastKnownSessionName: String
    public let renderMode: TmuxRenderMode
}
```

首期 `renderMode == .passthroughPTY`。后续增加 `.nativeControlMode`。

交互 tmux client 必须有可被控制面精确定位的 `target-client`。数据面启动命令在非登录、非交互 POSIX shell 中输出带随机 nonce 的有界握手帧和当前 `tty`，随后 `exec tmux attach-session`；renderer 在把输出交给 SwiftTerm 前以相同的有界 preamble 规则查找、消费并验证该帧，忽略帧前可能存在的非交互 Shell 启动输出。验证后的 PTY 名称仅保存在当前 attachment runtime 中，用于：

- `switch-client -c <target-client> -t <target-pane>` 精确切换 Conn 这一个 client 的 Session/Window/Pane；
- `refresh-client -t <target-client>` 调整 client flag/尺寸策略；
- 区分 Conn 自己与外部 desktop client。

握手帧不得进入 transcript，nonce 不落盘。取得 PTY 后，backend 用同一 profile 的 `list-clients` 验证该 target-client 已 Attach 到 requested Session；验证成功才把 Tab 提交给 `TerminalSessionStore`。进程在 readiness deadline 前退出时使用 `RemoteProcessExit` 和有界 stderr 诊断返回启动失败，不能先创建一张 disconnected Tab。

握手超时、格式错误但远程进程仍在运行时，可以在 readiness deadline 后进入 pass-through degraded 模式；此时隐藏原生 Window/Pane 切换和动态尺寸隔离，不能猜测 target-client。握手成功但 client 明确 Attach 到错误 Session 时必须关闭该 data channel 并报错，不能降级继续。

### 12.2 与现有 TerminalSession 的接线

首期普通 PTY 和 tmux pass-through 最终都是一个字节终端，不重写现有 `TerminalSession`/`TerminalTranscript`：

- `PlainPTYBackend` 继续把 `SSHSession.openShell()` 返回的 `ShellChannel` 交给 `TerminalSession`；
- `TmuxPassthroughBackend` 用私有 `RemoteProcessShellChannelAdapter` 包装 `RemoteProcessChannel`，消费握手帧后将 PTY 合并输出映射为 `AsyncThrowingStream<Data, Error>`，并转发 write/resize/close；
- adapter 实现现有 `ShellChannel`，但只位于 `ConnTerminal`，不能让 `ConnSSH` 反向依赖终端模块；
- `TerminalSessionCoordinator` 根据 launch choice 选择 backend，成功得到 `ShellChannel` 后复用现有 generation、transcript、lifecycle 和 Store 流程；
- `TerminalTab` 额外保存 attachment descriptor，不能再仅凭 `TerminalSessionSource` 或 initial command 推导重连方式；
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
- 控制命令路由；
- client topology 与 capability 状态；
- 重连、退避和 snapshot reconciliation。

同一个远端 Session 被多个 Conn 视图观察时共享一个 Control Client；不同 Session 只有在终端/管理视图当前可见或有 pending operation 时才保持 Control Client。仅存在于 `TerminalSessionStore` 但处于后台的 Tab 不持有观察 lease；再次可见时重新取得 lease 并先校准 snapshot。Session Center 进入时执行一次全局 snapshot；无可见消费者且无 pending operation 时释放临时控制通道，不做全主机后台轮询。

### 13.2 Control Client 启动参数

Control Client 使用 `RemoteProcessChannel` 直接启动 `tmux -CC attach-session`，不经过登录 Shell。完整模式至少启用：

- `no-output`：首期控制面不接收 Pane 内容；
- `ignore-size`：控制面默认不参与窗口尺寸；
- `wait-exit`：允许干净结束协议；

`active-pane` 设置在交互 tmux client，不依赖 Control Client 的当前 Pane。Control Client 通过已验证的交互 `target-client` 执行 `switch-client -c ... -t %pane`，否则原生选择会只改变控制通道自身而不会改变实际接收键盘输入的 Pane。

`tmux -CC` 会发送官方 DSC 起始标记。Control Client 在看到该标记前处于 `awaitingProtocolMarker`，只收集有上限的 preamble 诊断，不解析 `%` 消息；看到标记后才进入协议解析。超过时间/字节上限仍未出现标记时关闭该 Control Client 并降级，避免 `.zshenv`、系统 banner 或错误文本被误解析为 tmux 事件。

关闭 Control Client 时遵循 `wait-exit` 握手：请求 Detach 后等待 `%exit`，收到后发送空行确认并等待进程/通道 EOF；任一步超过关闭 deadline 才强制关闭当前 channel。该流程只结束控制 client，不 Kill Session，也不关闭交互 data client 或共享 SSHSession。

Control Client 必须可写，因为它需要执行管理命令；不能设置 `read-only`。只读 Attach 是后续独立产品能力，不与首期管理通道混用。

### 13.3 Session Catalog 与实时观察

- Catalog 是 tmux server 全局的一次性/事件触发快照；
- Control Client 只 Attach 一个 Session，提供该 Session Window/Pane 的实时事件；
- `%sessions-changed`、session rename 等全局相关事件使 Catalog 标记 dirty，并触发去抖后的重新抓取；
- 没有 Control Client 时，进入 Session Center、切换 profile、下拉刷新或操作完成后执行 snapshot；
- 不在正常路径每 2 秒运行 `list-*`；Control Mode 降级模式只在管理界面可见时每 2 秒刷新，用户离开界面立即停止，并保留手动下拉刷新。

### 13.4 命令路由

`TmuxCommandExecutor` 统一接收 typed operation，UI 不区分底层通道：

- 目标 Session 已有 ready Control Client：通过该 client 串行发送命令并等待 `%end/%error`；
- 创建第一个 Session、只打开 Session Center、目标 Session 未被观察或 Control Mode 已降级：通过 `SSHSession.exec` 执行同一个 `TmuxCommandEncoder` 生成的短命令；
- one-shot 命令完成后立即抓取相关 Catalog/Session snapshot；
- destructive one-shot 超时按“结果未知”处理，禁止自动重发；
- Control Mode 命令失败不能静默改走 one-shot 重试，因为第一次命令可能已经生效；先 reconciliation，再由用户决定是否重试；
- 一次 operation 绑定 host connection identity、profile ID、server instance token 和 generation，不能跨重连换通道继续执行。

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
- `closing`：完成 `wait-exit` Detach/acknowledgement，超时后只强制关闭当前 channel；
- 每一代 channel 有 generation，旧代次迟到事件和命令结果全部丢弃。

### 14.2 字节流解析

`TmuxProtocolParser` 是增量字节解析器：

- 接受任意 Data chunk，不假设一块是一行；
- 起始 DSC marker 和退出 ST marker 同样支持跨 chunk 识别；
- 保留半行并限制最大缓冲；
- 区分 `%begin`、命令输出、`%end`、`%error` 和异步通知；
- 通知不会插入命令输出块，但解析器不能依赖一次 read 只含一种消息；
- pane output 解码按 tmux octal escaping 规则实现，为未来 Renderer 留用；
- 未知 `%...` 通知作为 `.unknown` 保留并记录受限诊断，不让解析器崩溃；
- 无效 block nesting、超长行、非法转义或无法关联的终止块触发 reconciliation；
- 原始协议和远端标题默认不写日志；诊断只记录消息种类、长度和去敏 ID。

### 14.3 命令关联与并发

`TmuxControlClient` 是 actor，首期串行发送管理命令：

- 同一时刻只允许一个需要响应的命令在途；
- 命令等待匹配的 `%end` 或 `%error`；
- 异步通知在同一个 actor 中按流顺序交给 reducer；
- UI 操作在 actor 队列中串行，避免 rename/kill/select 的目标竞态；
- 命令有本地 deadline；deadline 只停止等待，随后必须将 client 标记 dirty 并做 snapshot，不能假设远端命令没有执行；
- 不做未确认的乐观领域状态修改；成功响应和事件后更新，缺少预期事件时以 snapshot 校准。

### 14.4 Snapshot Reconciliation

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
    public let windows: [TmuxWindowID: TmuxWindowSnapshot]
    public let panes: [TmuxPaneID: TmuxPaneSnapshot]
    public let windowLinks: [TmuxWindowLink]
    public let clients: [TmuxClientID: TmuxClientSnapshot]
    public let observedAt: Date
    public let revision: UInt64
}

public struct TmuxSessionSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxSessionID
    public let name: String
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
    public let title: String?
    public let currentCommand: String?
    public let currentPath: String?
    public let size: TermSize
    public let isDead: Bool
}

public struct TmuxWindowLink: Sendable, Equatable, Identifiable {
    public let sessionID: TmuxSessionID
    public let windowID: TmuxWindowID
    public let index: Int
}

public struct TmuxClientSnapshot: Sendable, Equatable, Identifiable {
    public let id: TmuxClientID
    public let sessionID: TmuxSessionID
    public let currentWindowID: TmuxWindowID?
    public let activePaneID: TmuxPaneID?
    public let flags: Set<TmuxClientFlag>
}
```

tmux Window 可以 link 到多个 Session，因此领域状态必须是规范化图，不能把同一个 Window 复制进多个 Session 树。UI 通过 `windowLinks` 和 Pane 的 `windowID` 投影 Session → Window → Pane。Session 的 attached client 数从 `clients` 推导；同一个 Window 的 rename/layout 事件只更新一份实体。首期虽然不提供 link/unlink UI，也必须正确读取和展示用户已有的 linked windows。

字段无法由某版本安全提供时为 optional 或由 feature set 隐藏，不伪造值。Session 的 current window、Window 的 active pane 与 client-specific 视图必须分开；不能把 Conn 交互 client 的当前状态覆盖成 server 全局状态。

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

`TerminalSessionSource` 增加 tmux attachment 来源，但不能把整个 snapshot 存入 Tab：

```swift
case tmux
```

重连信息继续与展示来源分离。现有只含 `commandToReplay` 的 `TerminalReconnectDescriptor` 改为显式枚举：

```swift
public enum TerminalReconnectDescriptor: Sendable, Equatable {
    case shell
    case replayCommand(String)              // 现有 Docker console
    case tmux(TmuxAttachmentDescriptor)
}
```

脚本终端创建成功后仍使用 `.shell`，不保存或重放用户脚本；tmux 重连只能消费 `.tmux` descriptor，不能从 alias、source 文案或 initial command 反推。

## 16. 操作语义

### 16.1 Target 与校验

- 操作前确认 server instance token、generation 和 entity ID 仍匹配；
- command encoder 只接收 typed ID，不接收任意 target 字符串；
- 名称冲突、最后一个 Pane、最后一个 Window 等规则以 tmux 返回为准；
- 远端对象已不存在时转成 typed `.staleTarget`，刷新快照后给用户明确反馈；
- destructive action 的确认内容来自操作前最新快照；快照过旧时先刷新。

### 16.2 选择与创建

- select Window/Pane 通过 `switch-client -c <verified-interactive-client> -t <typed target>` 作用于 Conn 的交互 client，并等待事件/快照确认；
- 若交互 client 身份未完成握手，隐藏原生 select/focus 操作，用户仍可在 pass-through 终端里用自己的 tmux 键位；
- 新建 Window/Split 默认继承 tmux 自身 default shell 和用户配置；
- 首期不擅自传 `-c currentPath`，避免路径不可访问、格式差异和跨版本问题；
- 不模拟 prefix 快捷键，直接使用 tmux command API；用户仍可以在终端内使用自己的 prefix。

### 16.3 破坏性操作

- Kill Session、Close Window、Close Pane 都显示对象名称/编号；
- Kill Session 显示 attached client 数；
- Close 最后一个 Pane 可能连带销毁 Window/Session，确认文案必须反映快照中可推导的影响；
- 命令 `%error` 不从本地 Store 删除对象；先显示失败，再校准；
- 操作成功后依赖事件更新；没有事件时立即 snapshot。

## 17. 多客户端隔离与终端尺寸

### 17.1 默认原则

Conn 不 detach 其他客户端，不修改全局 tmux option，不永久写入用户 server/session/window 配置。隔离优先使用 client flag 和当前 client 命令。

### 17.2 尺寸策略

- Control Client 始终 `ignore-size`，除非将来全原生 Renderer 明确接管窗口尺寸；
- 交互 tmux client 在 attach 前查询其他客户端；存在其他客户端时使用 `ignore-size`，支持时同时使用 `active-pane`；
- 没有其他客户端时允许 Conn 参与当前 Session 的尺寸，使手机终端可用；
- client topology 变化后重新评估 Conn client 的 size participation；实现必须通过目标 tmux 版本集成测试验证 `refresh-client`/client flag 的动态行为；
- 无法安全切换时优先保护外部客户端：Conn 转为 `ignore-size`，允许本地出现裁切/空白并给出提示；
- 不修改用户的全局 `window-size`、`aggressive-resize` 或 `default-size`；
- resize 高频事件做去抖和去重，避免拖动界面时淹没 SSH channel。

### 17.3 Active Pane 与 Zoom

- 支持 `active-pane` 时，Conn 通过已验证的交互 target-client 使用独立 pane focus；
- 不支持时，原生 Pane 列表的 select 会改变 tmux Window active pane，并可能被其他客户端看到，UI 标记 degraded；
- `active-pane` 只隔离同一 Window 内的 Pane，不承诺隔离 Session 的 current window；选择另一个 Window 仍遵循远端 tmux 的共享语义，可能让同 Session 的其他 pass-through client 一起切换；
- UI 在存在其他客户端时对 Window 切换显示共享状态提示，但不阻止操作；这是普通 tmux Attach 的固有语义，只有未来逐 Pane 原生 Renderer 才能完全摆脱共享可见 Window；
- Zoom 是 Window 级远端状态，即使有 `active-pane` 也可能影响其他客户端；存在其他客户端时始终提示；
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

### 18.3 Hub 退避

Control Mode 恢复使用有上限的指数退避并加入抖动；仅在存在可见消费者或活跃 tmux Tab 时重试。网络不可用、App 后台或用户关闭最后一个 lease 时停止。用户主动重试立即开始新 generation。

## 19. 错误模型与降级

新增结构化错误：

```swift
public enum PersistentTerminalError: Error, Sendable, Equatable {
    case unsupportedPlatform
    case providerDisabled
    case executableMissing
    case incompatibleVersion(String?)
    case serverUnavailable
    case socketPermissionDenied
    case invalidConfiguration
    case controlModeUnavailable
    case protocolViolation
    case staleTarget
    case remoteObjectMissing
    case commandRejected(String)
    case transportClosed
}
```

错误处理规则：

- SSH 建连、认证、host key、channel 等错误保留 `SSHError`；
- tmux 命令成功执行但环境不可用时映射 provider error，不伪装为网络错误；
- tmux 未安装：启动普通 PTY，不展示阻断页；
- Control Mode 不可用：允许 pass-through attach；管理界面显示“有限状态同步”并提供手动刷新；
- protocol violation：停止应用增量事件，保留最后一次 snapshot 为 stale，只读显示，随后重连校准；
- destructive command 超时：明确提示“结果未知”，禁止自动重试，先 snapshot；
- 普通查询可以在校准后由用户重试；
- 远端原始 stderr 不直接作为本地化正文，但可作为受限详情展示。

## 20. 持久化设计

### 20.1 需要持久化的内容

持久化的是用户配置，不是远端运行状态。新增 `terminal_backend_profiles`：

```text
id                    TEXT PRIMARY KEY
host_id               TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE
provider_id           TEXT NOT NULL
display_name          TEXT NOT NULL
is_enabled            INTEGER NOT NULL DEFAULT 1
is_primary            INTEGER NOT NULL DEFAULT 0
configuration_version INTEGER NOT NULL
configuration_json    TEXT NOT NULL
sort_order            INTEGER NOT NULL DEFAULT 0
created_at             TEXT NOT NULL
updated_at             TEXT NOT NULL
```

规则：

- `provider_id` 首期为稳定值 `tmux`；
- `configuration_json` 由对应 provider 按版本解码；未知 provider/config version 保留记录但不执行；
- 一个 host/provider 最多一个 `is_primary`，由 `(host_id, provider_id) WHERE is_primary = 1` 的唯一部分索引保证；它只决定启动器首先查询哪个 socket，不自动跳过启动选择器；
- 未配置 profile 时提供隐式的 tmux default socket profile；用户编辑后可物化为记录；
- 用户禁用隐式 default profile 时物化一条 `is_enabled = 0` 的 default locator 记录，避免“没有记录”再次被解释为启用；
- `-L`/`-S` profile 可以有多个，但 Conn 只查询用户当前选择或已配置的 profile；
- host connection identity 改变时 profile 仍属于 host 配置，但所有运行时 snapshot/channel 失效并重新 probe；
- App 尚未发布也使用正式 schema migration，不在启动代码中临时 ALTER。

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
- `%begin/%end/%error`、空输出、异步通知和未知通知；
- octal escape、无效 escape、非 UTF-8 Pane 数据；
- 最大行/缓冲限制和恢复；
- snapshot format 中空格、引号、分隔符和 Unicode 名称；
- typed command encoder 的 target、名称和 socket escaping；
- reducer 的 add/rename/close/select/layout/zoom/client count 事件；
- generation 丢弃迟到事件、快照和命令结果；
- command timeout 后 dirty/reconciliation；
- `wait-exit` 正常 Detach/acknowledgement 与关闭超时强制收尾；
- provider registry 的 Linux/macOS 命中与 Windows/Unknown 拒绝；
- profile 的 default/`-L`/`-S` 互斥与配置版本；
- data/control plane 独立失败；
- Hub lease 复用与最后一个 lease 释放；
- server instance 改变后旧 ID 失效。

Parser 使用 fuzz/property tests 生成随机分块；相同完整协议输入在所有分块方式下必须产生相同事件序列。

### 22.2 SSH 引擎测试

`ConnSSHCitadelTests` 覆盖 `RemoteProcessChannel`：

- direct exec 不读取登录 rc；
- Control Mode 在随机 Shell preamble 后仍只从 `-CC` DSC marker 开始解析；marker 缺失/超限时安全降级；
- 可写 stdin、持续读取 stdout/stderr；
- PTY 可选申请和 resize；
- tmux 数据面握手帧能取得并验证远端 PTY 名称，且不会进入终端 transcript；
- 握手 marker 不可用但进程持续运行时只降级原生切换，不阻断 pass-through 终端；
- 已验证 client Attach 到错误 Session 时关闭 channel 并判定启动失败；
- 远程进程在 readiness 前非零退出不会产生 TerminalTab，exit-status/exit-signal 可被诊断；
- writer 未就绪前不返回；
- 正常 EOF、远端失败、本地 close 和并发 close 只结束一次；
- 关闭一个 process channel 不影响同一 SSHSession 的其它 PTY/exec；
- cancellation/迟到 channel 不泄漏；
- 经 jump host 的共享 session 同样可开 control/data channel。

### 22.3 tmux 集成测试

自动集成环境至少覆盖 tmux 2.6、3.0 系列和当前稳定版本；真实 macOS SSH 验收覆盖当前 Homebrew tmux。若某版本缺少 optional feature，测试必须验证 degraded 路径，而不是跳过。

场景包括：

- 无 server、空 server、一个/多个 Session；
- default、`-L`、`-S`；
- 新建、重命名、Kill Session；
- Window/Pane 全部首期操作；
- 桌面/第二客户端在 Conn 外部修改状态；
- 同一 Session 多 Conn consumer 共享 Control Client；
- SSH 断线后远端 Session 继续并成功重新 Attach；
- tmux server 重启导致 instance token 改变；
- 外部 Kill 当前 Session；
- Control Mode channel 断开而 data plane 继续；
- data plane 断开而 Catalog 继续；
- socket 权限不足、tmux 配置错误、版本能力缺失；
- 其他客户端存在时尺寸和 active pane 保护；
- `switch-client -c` 只改变 Conn 交互 client 的目标 Pane，不改变外部 client；
- Session/Window/Pane 名称包含 Unicode、空格、引号和格式分隔符。

### 22.4 UI 验收

仅复用用户已启动的模拟器并指定其 UDID，遵守项目 `AGENTS.md`。UI 验收至少覆盖：

- tmux 缺失自动普通 PTY；
- tmux 可用时每次显示选择器；
- Session Center 按 host/profile 按需加载；
- loading、empty、degraded、stale、disconnected 和 error；
- Session → Window → Pane 管理；
- destructive confirmation 与 attached client 提示；
- iPhone Pane 列表切换；
- iPad 横屏完整布局；
- Dynamic Type、本地化、VoiceOver label 和按钮可达性；
- 普通终端、Docker Console、脚本终端无回归。

### 22.5 完成判据

- Linux/macOS 上 tmux 可用时启动器、Attach 和全部首期管理操作可用；
- Windows/Unknown 没有任何 tmux/POSIX probe；
- App/SSH 断开不 Kill 远端 tmux Session；
- 关闭 Tab 只 Detach；
- Control Mode 正常时无固定周期 `list-*` 轮询；
- 外部拓扑变化可以事件驱动同步，异常后能通过 snapshot 自愈；
- 已有外部客户端不会被 Conn detach；
- 控制面故障不会关闭仍可用的终端数据面；
- 不写入远端 snapshot 或 Pane 内容到数据库；
- parser/reducer/command encoder 能在 host 单元测试运行；
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
- **Windows：** 将来注册 PowerShell/Windows Terminal/其它 persistent provider；不复用 POSIX command encoder；
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
- Control Mode 不得通过 `openShell()` 后发送 `tmux -CC`；必须使用 direct `openProcess`；
- tmux snapshot 不得放入 `ConnectionManager` 或 SQLite；
- `TerminalSessionStore` 不得成为远端 Session Catalog；
- 不能因为 Control Mode error 就 Kill/Detach 交互 tmux client；
- 不能因为关闭一个 data/control channel 就 disconnect 共享 SSHSession；
- Windows/Unknown 不得 fallback 到 POSIX tmux provider；
- 不得用 Session/Window 名称或 index 代替稳定 ID 执行操作；
- 不得修改用户全局 tmux option 来解决 Conn 客户端尺寸或焦点问题；
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
