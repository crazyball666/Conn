# SwiftTerm 1.19 与 tmux 滚动稳定性设计

## 目标

- 将仓库内固定的 SwiftTerm 基线从官方 `v1.15.0` 升级到最新稳定版 `v1.19.0`。
- 保留 Conn 已有的 Host 交互、安全限制与测试，不把应用重新耦合到 SwiftTerm 内部实现。
- 根治 tmux 终端偶发无法上下滚动的问题，同时保持普通终端、tmux 历史、tmux Copy Mode 和 Claude Code 等 TUI 的既有语义。

## 已确认的根因

普通终端的正常 Buffer 直接使用 SwiftTerm 原生 `UIScrollView` 滚动。tmux 终端则根据当前 Pane 状态，将手势路由到本地历史、远端历史、Copy Mode、方向键或鼠标协议。

当前 `TerminalRouteToken` 把 tmux `persistentRevision` 当作整次手势的有效性条件。Control Mode 的后台快照会因刷新时间或其他与当前 Pane 滚动无关的状态推进 revision。若更新发生在手势开始与 `.changed` 事件之间，已固定的滚动路由会失效，后续位移被当作边界操作丢弃。

远端历史读取还会把开始手势时的 revision 与真正执行读取时的最新快照严格比较。即使 Session、Window 和 Pane 都没有变化，无关快照更新也会让只读历史请求失败。这两处竞态只存在于持久终端路径，因此普通终端不受影响。

## SwiftTerm 升级边界

`Packages/Vendor/SwiftTerm` 继续作为固定、可审计的源码依赖。升级步骤以官方 tag `v1.19.0` 为全量基线，不使用零散 cherry-pick，也不切换为浮动的远程 Package。

Conn 当前相对 `v1.15.0` 的修改限定在以下边界，升级时逐项重放并复核：

- `TerminalHostInteraction.swift`：Host 协议状态、鼠标/滚轮/方向键发送、不可变快照与 OSC 52 上限。
- `Terminal.swift`：协议状态通知和有界 OSC 52 解析入口。
- `EscapeSequenceParser.swift`：有界控制序列处理。
- `iOSTerminalView.swift`：Host 手势接管、选择、命中测试及输入桥接。
- `TerminalHostInteractionTests.swift`：上述行为的 vendor 级回归测试。

官方 `v1.19.0` 已公开 `SelectionService` 和 `TerminalView.selection`。移植时优先使用新的公开接口，但不为了减少补丁而改变 Conn 已验收的交互语义。`CONN_UPSTREAM.md`、开源许可页面及版本断言统一更新为 `v1.19.0` 和 commit `464df5207fc2432e16c9a23abe538187196daf5f`。

## 滚动路由设计

### 手势令牌

一次手势只在真正影响路由的条件变化时失效：

- 终端实例代次变化；
- attachment 代次变化；
- 当前目标 Pane 变化；
- Host 协议模式变化；
- tmux Pane 的 alternate-buffer、mode capability 或历史可用性变化。

普通的 tmux snapshot revision 变化不再中断正在进行的手势。实现上以持久路由签名替代原始 `persistentRevision`；签名由目标和上述路由字段组成。

### 请求执行

手势只固定“滚动应该走哪条路径”，不固定后台命令使用的快照版本。真正执行 Copy Mode 滚动时继续从 Coordinator 当前的 `persistentState` 构造请求，因此操作仍受最新状态保护。

历史读取是只读操作：开始前校验目标 Pane 和 attachment，完成后再次解析当前交互目标并确认 Pane 未切换。它不再因无关 revision 更新失败。若读取期间 Pane 已改变，结果仍丢弃，不会覆盖新 Pane 的终端画面。

### DECSET 1007

SwiftTerm `v1.19.0` 新增 Alternate Scroll Mode。Conn 的 Host 协议快照增加该状态，使自定义 iOS 手势与 SwiftTerm 语义一致：

- Mouse Tracking 开启时，滚动发送鼠标滚轮事件；
- Alternate Buffer 且 1007 开启时，滚动转换为方向键；
- Alternate Buffer 且 1007 关闭时，不虚构方向键滚动；
- 正常 Buffer 仍优先使用本地历史或 tmux 远端历史。

tmux Pane 自身的 Copy Mode 和其他 provider mode 仍优先于 1007，不改变现有持久终端能力抽象。

## 错误与并发处理

- 同一手势内的路由保持稳定；方向反转继续由现有 accumulator 清理反向余量。
- tmux provider 命令继续进入已有串行队列，不新增并发通道。
- stale provider state 只触发一次解析，并在解析后重放已累计行数。
- attachment、目标 Pane 或终端代次变化时立即取消未完成历史读取和滚动任务。
- 不新增用户可见文案；现有错误提示与本地化目录不变。

## 测试与验收

### SwiftTerm vendor 测试

- 执行官方 SwiftTerm 测试集。
- 保留并更新 Conn Host 交互、OSC 52、快照和 iOS 输入相关测试。
- 增加 1007 Host 协议状态传播与 reset 行为测试。

### Conn 单元测试

- revision 单独变化时，正在进行的 tmux 滚动路由保持有效。
- Pane、attachment、模式或终端代次变化时，路由立即失效。
- 只读历史请求允许无关 snapshot revision 更新，但拒绝目标 Pane 或 attachment 变化。
- 1007 开启与关闭时的 Alternate Buffer 路由符合预期。
- 普通终端本地 scrollback 行为不回归。

### 模拟器 UI 测试

在用户当前已启动的唯一模拟器上验证：

- 普通终端连续上下滚动；
- tmux Shell 有历史内容时连续上下滚动；
- tmux 滚动期间注入后台状态刷新，手势不中断；
- tmux Copy Mode、Claude Code/TUI Alternate Buffer 和左右 Window 切换互不抢占；
- 长按选择、方向盘和快捷键栏不回归。

所有 `xcodebuild test` 固定当前模拟器 UDID，并传入 `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`。

## 非目标

- 不升级到预发布的 SwiftTerm `v1.20.0`。
- 不重写终端交互架构，也不移除 Conn 的 Host 适配层。
- 不改变 tmux Control Mode 生命周期、Session 持久化或快捷键队列。
- 不修改当前工作区中尚未提交的 SSH 10 秒 TCP 超时改动。
