# Conn 全局多终端会话设计

**日期：** 2026-08-03  
**状态：** 已确认，待实现  
**范围：** 进程内全局终端会话、多会话切换、终端会话中心、会话别名  
**后续：** tmux 跨 App 生命周期恢复（不在本期）

## 1. 背景

当前 `TerminalScreen` 在每次呈现时独立建立 PTY，页面关闭后视图和 `TerminalSession` 一起释放。工程已有 `TerminalSessionStore` 雏形，但它没有注入 App，也不负责创建、复用、别名、状态或 UI 重新绑定。因此当前行为存在三个问题：

1. 从主机详情、Docker 控制台或脚本进入终端时会重复创建会话；
2. 关闭终端界面会失去终端画面，无法再次进入原会话；
3. 根导航虽然已经定义了 `ConnDock.Tab.terminal`，`RootTabView` 却没有终端会话中心。

本期把终端 PTY 生命周期从页面中移到 App 全局协调器。SSH 连接仍由现有 `ConnectionManager` 全局共享；终端层只管理一条 SSH 连接上的多个 PTY Shell。

## 2. 目标与非目标

### 2.1 目标

- 同一主机允许同时建立多个独立 PTY 会话；
- 关闭终端 Modal 时不关闭 PTY，重新进入恢复终端输出和滚动状态；
- 普通终端入口默认复用该主机最近使用的会话；
- Docker 控制台和“脚本进入终端”创建独立、可管理的会话；
- 终端内可以切换当前主机的会话，并给会话设置别名；
- 根 Tab 增加终端会话中心，按主机分组管理全部活跃会话；
- 只有 SSH 连接和 PTY 都创建成功后，会话才加入会话中心；
- 关闭终端会话只关闭对应 PTY，不断开共享 SSH 连接。

### 2.2 非目标

- 不把活会话写入 SQLite；
- 不承诺 App 被杀死后恢复 PTY；
- 不在本期自动安装、配置或连接 tmux；
- 不改变 `ConnectionManager` 的每主机 SSH 连接池语义；
- 不把静默脚本执行加入终端会话中心；
- 不提供 iOS 后台常驻或 7×24 终端保持。

## 3. 核心决策

### 3.1 App 全局协调器

`AppDependencies` 增加唯一的 `TerminalSessionCoordinator`。它注入 `ConnectionManager` 和 `HostRepository`，与二者同生命周期，并持有增强后的 `TerminalSessionStore`。语言或主题切换导致根视图重建时，协调器实例不重建，会话继续存活。重连时按 host ID 从仓库读取最新主机配置；会话行只保存展示元数据，不复制密码或私钥。

职责边界：

| 组件 | 职责 |
| --- | --- |
| `ConnectionManager` | 每主机复用 SSH 传输连接；不感知终端标签和别名 |
| `TerminalSessionCoordinator` | 创建、复用、重连和关闭 PTY；处理入口策略和错误 |
| `TerminalSessionStore` | 保存活跃会话元数据、当前/最近选择、别名和状态 |
| `TerminalSession` | 当前一代 ShellChannel 的输入输出和尺寸变化 |
| `TerminalTranscript` | 跨 PTY generation 保存输出缓存、UI 订阅和视口状态 |
| `TerminalScreen` | 当前 Modal 的选中会话、工具栏、会话切换和命令选择器 |
| `TerminalSessionsView` | 根 Tab 会话中心、按主机分组、创建和管理入口 |

协调器必须在成功取得 `SSHSession`、成功 `openShell`、成功构造并启动 `TerminalSession` 后才调用 `store.add`。任一步失败都不创建会话记录。

### 3.2 会话与 SSH 连接的关系

同一主机的多个终端会话：

```text
ConnectionManager
└── Host A 的一条 SSHSession
    ├── PTY 1 → TerminalSession 1
    ├── PTY 2 → TerminalSession 2
    └── PTY 3 → TerminalSession 3
```

关闭 `TerminalSession 2` 只调用它的 `ShellChannel.close()`。禁止调用 `connectionManager.disconnect(host:)`，因为监控、文件、Docker、日志和其它 PTY 仍可能复用同一 SSH 连接。

## 4. 会话数据模型

`TerminalTab` 扩充为活会话的轻量记录：

```swift
public struct TerminalTab: Identifiable, Sendable {
    public let id: String
    public let hostID: String
    public let hostName: String
    public let hostAddress: String
    public var alias: String
    public let source: TerminalSessionSource
    public let createdAt: Date
    public var lastUsedAt: Date
    public var status: TerminalSessionStatus
    public var generation: UInt64
    public let transcript: TerminalTranscript
    public let reconnect: TerminalReconnectDescriptor
    public var session: TerminalSession
}
```

来源类型：

```swift
public enum TerminalSessionSource: Sendable, Equatable {
    case shell
    case docker(containerName: String)
    case script(title: String)
}
```

状态只表示已经创建成功的会话：

```swift
public enum TerminalSessionStatus: Sendable, Equatable {
    case connected
    case disconnected(message: String?)
    case reconnecting
}
```

不存在 `.connecting` 或“首次连接失败”的会话卡片。首次连接中的进度属于发起页面的临时呈现状态，不进入 store。

默认别名：

- 普通 Shell：当前主机内第一个未占用的 `终端 N`；
- Docker 控制台：容器名；
- 脚本终端：脚本标题；
- 用户输入会去除首尾空白；空字符串恢复该会话的自动别名。

别名、状态和会话元数据全部只存在内存中。

重连信息不能只从展示用的 `source` 推导。每个 tab 保存独立、仅内存的重连描述：

```swift
public struct TerminalReconnectDescriptor: Sendable, Equatable {
    /// 仅 Docker 控制台保存精确的 `docker exec ...` 命令；普通 Shell 和脚本为 nil。
    public let commandToReplay: String?
}
```

脚本初始命令可能包含用户变量，只用于首次启动，创建成功后不写入 reconnect descriptor；Docker 控制台保存精确进入容器命令，重连时重放。以上内容不落 SQLite、不写日志。

## 5. 创建与复用策略

终端入口统一转换为 `TerminalLaunchRequest`：

```swift
enum TerminalLaunchPolicy {
    case reuseRecentOrCreate
    case createNew
    case existing(tabID: String)
}

struct TerminalLaunchRequest {
    let host: Host
    let policy: TerminalLaunchPolicy
    let source: TerminalSessionSource
    let initialCommand: String?
    let replayInitialCommandOnReconnect: Bool
}
```

各入口规则：

| 入口 | 策略 | 初始命令 | 重连重放 |
| --- | --- | --- | --- |
| 主机详情终端按钮 | `reuseRecentOrCreate` | 无 | 否 |
| 服务器列表快捷终端 | `reuseRecentOrCreate` | 无 | 否 |
| 终端会话中心选择已有会话 | `existing` | 无 | 不适用 |
| 终端会话中心“新建会话” | `createNew` | 无 | 否 |
| 当前主机会话弹窗“新建会话” | `createNew` | 无 | 否 |
| Docker 控制台 | `createNew` | `docker exec ...` | 是 |
| 脚本“进入终端” | `createNew` | Shell 解释器命令 | 否 |

普通入口复用 `store.recentTab(forHost:)`；显式新建始终打开新 PTY。同一普通入口被快速连续点击时，协调器用每主机的 in-flight 创建任务去重，避免产生重复会话。

首次创建流程：

1. Modal 显示临时连接进度；
2. 协调器从 `ConnectionManager` 取得共享 SSHSession；
3. 打开新 PTY；
4. 构造尚未启动输出泵的临时 `TerminalSession`；
5. 需要初始命令时，在 Shell writer 就绪后用 throwing write 发送一次；
6. 再次确认 launch request 仍被当前调用方持有且未取消；
7. 激活 transcript generation、加入 store，再启动输出泵并显示终端；
8. 任一步失败都关闭已创建的临时资源、关闭 Modal，再发布一次全局 Toast，不写入 store。Toast 要在 Modal dismiss 后显示，避免根级 Toast 被全屏呈现层遮住。

`TerminalSession.send` 不再吞掉 `ShellChannel.write` 错误。初始命令使用 throwing API，发送失败视为首次创建失败。普通交互输入写入失败时，TerminalSession 发送生命周期失败事件，由协调器把已成功存在的会话切到 `.disconnected`。

### 5.1 首次失败只提示一次

`reuseRecentOrCreate` 的并发请求可能等待同一个 in-flight 创建任务。失败结果包含稳定的 `failureID`，协调器提供原子消费方法：

```swift
struct TerminalLaunchFailure: Error, Sendable {
    let id: UUID
    let message: String
}

func consumeFailure(_ failure: TerminalLaunchFailure) -> String?
```

等待同一创建任务的调用方会拿到同一个 failure ID；只有第一个 `consumeFailure` 返回文案，其余返回 nil。因此 UI 只能发布一次 Toast。成功或失败后必须移除 in-flight 条目；关闭发起页面不能把已经成功加入 store 的会话误删。

## 6. 输出保持与 UI 重新绑定

输出历史和视口属于稳定的 terminal tab，不属于某一代可能被重连替换的 PTY。新增 `TerminalTranscript` actor，由 `TerminalTab` 持有；首次创建和每次重连构造 `TerminalSession` 时都注入同一个 transcript。旧 PTY 断开、新 PTY 替换后，历史输出和视口状态因此继续存在。

当前 `TerminalSession.start(onFeed:)` 只允许启动一次，并把输出回调绑定到首次创建的 `TerminalInputController`。页面销毁后再次绑定会失败。本期改成：每一代 `TerminalSession` 只负责把通道输出 append 到共享 transcript；UI 可以对 transcript 多次附加/解除。回放和实时输出不能用两个无顺序保证的回调，必须走同一个有序事件流：

```swift
actor TerminalTranscript {
    func attach() -> TerminalAttachment
    func detach(_ attachmentID: AttachmentID)
    func activateGeneration(_ generation: UInt64)
    func append(_ bytes: [UInt8], generation: UInt64)
    func appendGenerationBoundary(_ generation: UInt64)
    func updateViewport(_ state: TerminalViewportState)
}

actor TerminalSession {
    init(
        channel: any ShellChannel,
        transcript: TerminalTranscript,
        generation: UInt64
    )
    func start()
}

struct TerminalAttachment: Sendable {
    let id: AttachmentID
    let events: AsyncStream<TerminalRenderEvent>
}

enum TerminalRenderEvent: Sendable {
    case replayStarted(requiresReset: Bool)
    case replayBytes([UInt8])
    case replayFinished(TerminalViewportState)
    case generationBoundary
    case liveBytes([UInt8])
}
```

- `TerminalSession` 的构造和 `start()` 分离：首次创建在写入 store 后启动，重连在新 generation 提交后启动；所有帧携带 generation append 到 tab 的共享 transcript；
- 没有 UI 时 transcript 仍把输出写入 `TerminalReplayBuffer`；
- transcript actor 在同一 continuation 中依次 yield `replayStarted`、缓存块、`replayFinished`，之后才允许 yield `liveBytes`；actor 隔离保证 attach 与 append 串行化；
- `TerminalInputController` 用一个 MainActor task 顺序消费该 stream，不能为每一帧再创建无序 Task；
- 只有收到 `replayFinished` 后才能恢复视口位置；
- detach 必须带 token，旧页面不能误删新页面的订阅；
- 同一 tab 正常情况下只有一个可见订阅者，新的 attach 会替换旧订阅者；
- transcript 只接受当前 active generation 的 append；旧 PTY 即使在取消后迟到产出，也会在 actor 边界被丢弃；
- 重连提交新 generation 时复用原 transcript，先追加一个 `generationBoundary`，再接受新 PTY 输出；不得清空或替换 transcript。

`generationBoundary` 不是普通文字分隔符。消费者必须在同一有序事件流里先写入不会清空 scrollback 的终端归一化序列：退出 alternate screen、DEC soft reset、重置 SGR、恢复可见光标和自动换行，然后换行显示本地“已重新连接”分隔信息。禁止使用会清空 scrollback 的 RIS/full reset。这样上一代遗留的 alternate screen、隐藏光标、颜色和输入模式不会污染新 PTY，同时历史仍可回看。`appendGenerationBoundary` 同时把这组固定 ANSI 字节写进 replay buffer，并向当前订阅者 yield `.generationBoundary`；重新 attach 时直接回放缓存中的同一组字节，不能重复插入或遗漏归一化。

### 6.1 缓存限制

每个 transcript 同时限制：

- 最近约 10,000 行；
- 最大 4 MiB 原始终端字节。

超过任一限制时，从最旧的完整行开始丢弃；遇到长时间无换行输出时按字节上限截断。缓存发生截断后，重新构建 SwiftTerm 画面前先发送终端 reset，再回放剩余内容，避免继承不完整 ANSI 状态。缓存截断不关闭 PTY。

`TerminalReplayBuffer` 是独立纯 Swift 类型，负责 append、按行/字节裁剪和 snapshot，单独单测。

### 6.2 视口状态

每个 transcript 保存轻量 `TerminalViewportState`：是否跟随实时输出、最近滚动位置。UI detach 时写回，attach 并完成回放后恢复。若关闭页面前处于实时跟随，重新打开默认滚到底部；若用户正在回看历史，尽量恢复原相对位置。

## 7. 断开与重连

`TerminalSession` 提供独立的生命周期事件流，渲染事件和生命周期事件不混用：

```swift
enum TerminalSessionLifecycleEvent: Sendable {
    case closed
    case failed(message: String?)
}

var lifecycleEvents: AsyncStream<TerminalSessionLifecycleEvent> { get }
```

每个 `TerminalTab` 维护递增的 session generation。协调器监听生命周期事件时必须同时捕获 `tabID + generation`，更新 store 前确认 tab 仍存在且 generation 一致。这样重连替换 Session 后，旧 Session 延迟到达的 EOF/错误不会把新 Session 标成断开。

首次连接失败不进入会话中心。已经成功的会话后来发生 EOF 或 ShellChannel 错误时：

1. 保留 `TerminalTab`、别名、来源和输出缓存；
2. 状态切换为 `.disconnected`；
3. 可见终端显示已有画面和“已断开”，提供重新连接；
4. 会话中心用非绿色状态点显示断开；
5. 用户可以重连或关闭。

重连创建新的 PTY 并替换 `TerminalTab.session`，递增 generation，并把原 `TerminalTranscript` 注入新 Session；tab ID、别名和 transcript 都不改变。普通 Shell 无初始命令；Docker 控制台从 `TerminalReconnectDescriptor.commandToReplay` 读取并重新执行精确的进入容器命令；脚本终端的 descriptor 不保存命令，绝不自动重放脚本，避免重复副作用。

重连不能让两代 PTY 同时向同一 transcript 写入，严格按以下顺序执行：

1. 将 tab 标记为 `.reconnecting`，预留新 generation，并立即让 transcript 失效旧 generation；
2. 取消旧 Session 的生命周期监听，关闭旧 PTY，并等待它的输出泵结束或被取消；这里只关闭 PTY，不调用 `ConnectionManager.disconnect`；
3. 打开临时新 PTY；若需要重放 Docker 进入命令，在启动输出泵前用 throwing write 发送；
4. 回写前重新校验 tab、generation 和 reconnect task 所有权；校验失败则关闭临时 PTY；
5. 校验成功后，在 transcript 中提交 `generationBoundary`，替换 `TerminalTab.session`，再启动新 Session 输出泵和生命周期监听；
6. 任一步失败都关闭临时 PTY，保持原 tab 与历史，将状态恢复为 `.disconnected`。旧 generation 已失效，其迟到输出和 EOF 均被忽略。

协调器按 tab ID 保存 in-flight reconnect task：

- 同一 tab 同时只允许一个重连；
- 关闭 tab 时先移除记录、递增/失效 generation，并取消对应重连任务；
- 重连完成准备回写前再次确认 tab 存在、generation 未变化且任务仍被认领；
- 若 tab 已关闭或又发起了新一代重连，立即关闭本次新建的临时 PTY，不得写回 store；
- 手动关闭产生的旧 Session `.closed` 事件因 generation 失效而被忽略，不能把已删除会话重新标记为断开。

若共享 SSH 连接实际已死，协调器先让 `ConnectionManager.session(for:)` 自检；打开 PTY 仍失败时驱逐该主机的无效池条目，再允许一次重新握手。失败后仅在 generation 仍匹配时回到 `.disconnected` 并显示一次 Toast。

### 7.1 `CitadelShellChannel` 生命周期修正

当前实现把 `withPTY` 闭包在 `pump(inbound)` 返回后继续挂起等待本地 `close()`；因此远端正常 EOF 不会结束 `output`，上层永远收不到 `.closed`。同时建立失败和建立后异常共用同一个 checked continuation，存在重复 resume 风险。本期必须一并修正：

- 用线程安全的一次性 readiness gate 包装 open continuation；writer 就绪只成功一次，writer 就绪前失败只抛给 `open` 一次；
- inbound 正常 EOF 或错误都要解除 `withPTY` 的挂起、结束 `ShellChannel.output`，使 `TerminalSession` 发出 `.closed` 或 `.failed`；
- writer 已就绪后的错误只结束 output/lifecycle，不能再次 resume open continuation；
- 本地 `close()` 幂等：解除挂起、结束 output、取消 PTY task，并且只关闭当前 PTY channel；
- `write`/`resize` 在 writer 不存在或通道已结束时必须抛错，不能静默成功；
- 任一路径都不得关闭共享 `SSHSession` 或调用 `ConnectionManager.disconnect`，同一主机其它终端与监控继续复用连接。

App 进入后台时不主动关闭会话，也不承诺持续执行。系统挂起 App 后，网络和输出接收会暂停；回到前台后仍存活的连接继续使用，已死亡的连接按上述流程处理。

## 8. 终端 Modal

所有会话入口统一使用 Modal 呈现具体终端。会话中心不主动控制 TabBar 隐藏；Modal 覆盖时系统自然遮住底栏，关闭后恢复。

### 8.1 导航栏

- 左上角：显式 `ToolbarItem(placement: .topBarLeading)` 返回按钮，使用系统 `chevron.left` 样式。`fullScreenCover` 内自己的 `NavigationStack` 不会自动提供返回键，所以该按钮必须由 `TerminalScreen` 创建；点击只 dismiss Modal，不关闭 PTY；
- 右上角“退出会话”：确认后关闭当前 PTY、移出 store、dismiss Modal；
- 右上角“会话列表”：打开当前主机的会话半屏弹窗。

右侧使用系统 `ToolbarItemGroup`。退出按钮使用明确的退出图标和无障碍标签，不复用含义模糊的普通 `xmark`。

### 8.2 当前主机会话弹窗

- `.presentationDetents([.medium, .large])`；
- 只展示当前主机的成功会话；
- 行内容：别名、来源、创建/最近使用信息、状态、当前选中标记；
- 点击另一行立即切换，随后关闭半屏弹窗；
- 导航栏提供“新建会话”；
- 长按会话行提供“修改别名”和“关闭会话”；
- 修改别名和关闭确认由该弹窗自身承载；
- 同时提供 VoiceOver 自定义操作，不能让长按成为无障碍用户的唯一入口；
- 关闭非当前会话不影响当前终端；关闭当前会话时切换到同主机最近会话，没有其它会话则关闭 Terminal Modal。

## 9. 根终端会话中心

`RootTabView` 在服务器和命令之间接入 `.terminal`：

```swift
tab(.terminal) {
    NavigationStack {
        TerminalSessionsView(dependencies: dependencies)
    }
}
```

页面行为：

- 按主机分组；分组头显示主机名、地址和活跃会话数；
- 每个主机分组可展开/收缩，收缩状态只在当前视图生命周期内保存；
- 会话行显示别名、来源、状态和最近使用时间；
- 点击行以 Modal 打开已有会话；
- 长按行修改别名或关闭，并提供同等 VoiceOver 操作；
- 没有会话时显示居中空状态和“新建终端”按钮；
- 右上角系统 `+` 打开主机选择半屏弹窗。

### 9.1 新建/选择流程

主机选择弹窗使用 `NavigationStack` 和中/大 detent：

1. 第一层显示当前仓库中的主机；
2. 选择主机后显示该主机已有会话和“新建终端会话”；
3. 点击已有会话关闭选择弹窗，并以 Modal 打开它；
4. 点击新建先关闭选择弹窗，再呈现连接进度和终端 Modal；
5. 连接失败显示全局 Toast，Modal 自动关闭，不留下会话行。

不把主机选择和会话选择塞进一个巨型菜单，避免主机多时不可搜索和不可扩展。

## 10. 其它入口改造

所有现有 `TerminalScreen` 调用点改为请求协调器：

- `HostDetailView`；
- `ServersView`；
- `SnippetRunView`；
- `DockerView`；
- `ContainerDetailView`；
- DEBUG 终端冒烟入口。

调用方只负责构造 `TerminalLaunchRequest` 和呈现 Modal，不直接持有 `ConnectionManager`、创建 `ShellChannel` 或决定复用逻辑。

删除主机时，先调用 `terminalSessions.closeAll(forHost:)` 关闭该主机全部 PTY，再删除主机记录。

主机配置修改遵守共享 SSH 连接的真实边界：

- 备注、名称等展示字段可立即从仓库刷新到会话中心；
- 已建立的 SSH 连接和 PTY 不受修改影响；
- 地址或端口改变会命中新的连接池 key，下一次新建/重连会建立新连接；
- 仅修改用户名、密码或密钥时，如果旧地址端口的 SSH 连接仍在池中，新 PTY 仍复用旧连接，无法在不打断其它 PTY 的情况下切换认证；新认证配置在下一次 SSH 握手时生效；
- 不为“立即应用凭据修改”主动断开共享连接。若未来需要该能力，应另做带影响范围确认的“断开主机全部连接”操作。

## 11. 错误提示与可访问性

- 创建失败、重连失败、改名失败统一使用全局 Toast；
- 连接错误沿用 `SSHError.diagnosis` / `friendlyDiagnosis`，不吞掉主机指纹或认证诊断；
- 退出当前会话、关闭列表中的会话使用明确确认；
- 连接中按钮禁用，防止重复点击；
- 状态不能只靠颜色，必须同时有文字或图标；
- 所有工具栏按钮、状态点、会话来源和长按操作有本地化无障碍标签；
- 动态字体下别名可换行，地址和来源可以截断，但不能挤掉选中和状态语义。

## 12. tmux 后续扩展点

本期不持久化会话，但保留来源和稳定 tab ID。后续 tmux 方案在协调器层增加恢复描述，不改变会话中心和 Terminal Modal：

```swift
enum TerminalContinuation {
    case processLocal
    case tmux(sessionName: String)
}
```

未来可把 tmux session name 和主机 ID 持久化。App 重启后先探测远端 tmux，再恢复或提示失效；普通本地 PTY 仍按本期规则在进程结束时消失。

## 13. 测试设计

### 13.1 `ConnTerminalTests`

- 添加会话后成为当前会话；
- 同主机允许多个会话；
- 最近使用会话复用；
- 显式新建不会复用；
- 改名去空白、空名恢复默认；
- 按主机查询和分组；
- 关闭当前、其它、某主机全部和全局全部；
- 输出在无 UI 订阅时继续缓存；
- detach 后重新 attach 的单一事件流严格按 replayStarted → replayBytes → replayFinished → liveBytes 排序；
- replayFinished 前不恢复视口状态；
- 旧 attachment token 不会移除新订阅；
- 10,000 行和 4 MiB 上限；
- 通道 EOF/错误通知断开状态；
- 重连替换 Session 后仍使用同一个 transcript，旧输出和视口状态保留；
- transcript 丢弃旧 generation 迟到的输出；
- generation boundary 严格出现在新 generation 首个 live bytes 前；
- alternate screen、隐藏光标和 SGR 状态经过 boundary 后被归一化，同时 scrollback 保留；

### 13.2 `ConnSSHCitadelTests`

- writer 就绪和建立失败竞争时 readiness continuation 只完成一次；
- 远端正常 EOF 会结束 `ShellChannel.output`；
- 远端错误会以 throwing finish 结束 output；
- 本地 `close()` 可重复调用且不会挂起；
- writer 未就绪或通道结束后的 write/resize 会抛错；
- 关闭单个 PTY 不会关闭承载它的共享 SSHSession，另一 PTY 仍可输入输出。

### 13.3 App 单元测试

- 普通入口复用主机最近会话；
- 并发普通入口只创建一个 PTY；
- 显式新建同主机创建独立 PTY；
- 首次连接或 openShell 失败不写 store；
- 初始命令 write 失败关闭临时 PTY且不写 store；
- 多个等待者收到同一 failure ID，首次失败只消费并发送一次用户错误；
- 关闭 PTY 不调用 `ConnectionManager.disconnect`；
- Docker 重连重放进入容器命令；
- 脚本重连不重放脚本；
- Docker tab 保存精确的内存重连命令，脚本 tab 不保存脚本内容；
- 删除主机关闭对应 PTY；
- 不同来源生成正确默认别名。
- 旧 generation 的 EOF 不覆盖重连成功的新 Session；
- 重连必须等旧 PTY 的输出泵停止后才启动新 generation；
- 关闭 tab 会取消 in-flight reconnect，迟到结果会关闭临时 PTY且不回写；
- 用户名/凭据修改不驱逐仍被其它 PTY 复用的共享 SSH 连接；

### 13.4 UI 测试

- 根 Tab 出现“终端”，按主机展开/收缩；
- 空状态、新建按钮和主机选择流程；
- 终端以 Modal 打开，返回后底栏恢复；
- 返回不关闭会话，再次进入恢复原画面；
- 终端右上角退出和会话列表按钮；
- 半屏弹窗切换、改名、新建和关闭；
- 键盘、快捷键栏、长输出和切换会话后的布局不回归。

模拟器验收固定使用用户已启动的 iPhone 17 Pro，并给 `xcodebuild test` 指定其 UDID、关闭并行测试；不创建、关闭或克隆其它模拟器。

## 14. 验收标准

- [ ] 同一主机至少可同时打开三个独立 Shell，并即时切换；
- [ ] 关闭 Terminal Modal 后会话继续接收输出，重新打开能恢复画面；
- [ ] 主机详情普通入口复用最近会话，不会每次新增；
- [ ] Docker 与脚本终端进入会话中心并有合理默认别名；
- [ ] 首次连接失败只提示错误，会话中心无失败卡片；
- [ ] 退出终端只关闭 PTY，不中断该主机监控、文件、Docker 或其它终端；
- [ ] 根终端 Tab 能按主机管理全部活跃会话；
- [ ] 所有入口统一 Modal，底栏不做手动隐藏；
- [ ] App 被杀掉后会话清空，行为与本期范围一致；
- [ ] 单元测试、App 测试、UI 冒烟和 Release 构建通过。
