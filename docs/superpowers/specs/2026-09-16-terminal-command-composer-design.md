# 终端待发送输入区设计

**日期：** 2026-09-16
**状态：** 已确认，进入实现

## 背景与目标

Conn 当前终端支持 SwiftTerm 原生实时输入、快捷键栏、命令选择器和附件路径插入。移动端输入长命令时，用户需要先在独立输入区编辑，确认后再放入终端输入行。本功能增加一个当前终端页面范围内的“待发送内容”输入区，降低手机输入成本，同时不改变原有终端实时输入能力。

竞品参考：Blink 保留终端直接输入与 Return 发送模型；Prompt 通过 Clips 和自定义键盘快速把文本插入终端。Conn 采用竞品截图中的待发送区形态，并保留原生终端作为另一条输入路径。

## 用户交互

- 输入区位于终端视口和现有快捷键栏之间，始终参与垂直布局，终端视口按实际高度压缩，不覆盖输出。
- 默认显示约一行高度；内容变长时自动扩展，最多约四行，超出部分在输入区内部滚动。
- 占位文案为“待发送内容”，右侧提供至少 44pt 触控热区的纸飞机发送按钮。
- 回车只插入换行，不触发发送；发送按钮才是唯一提交入口。
- 发送按钮把内容按原样作为一次程序化粘贴插入当前终端输入行，不追加 `CR` 或 `LF`，不自动执行命令。
- 发送动作在当前页面主线程同步完成目标绑定和出站队列登记；`TerminalSession.enqueue` 返回 `true` 代表数据已被当前出站队列接受，Composer 以此作为本次提交成功点，随后清空草稿并保持输入区焦点，方便连续发送；空白内容不可发送。
- 未 attach、正在回放、已断开或没有当前终端视图时不登记发送，返回失败并保留草稿；登记后的后续 transport 写入失败仍由现有 Session 生命周期处理，不伪造 Composer 级重试。
- 草稿只存在当前 `TerminalScreen` 生命周期内，并按 tab 隔离；切换 tab 时保留各自草稿，重连时保留未提交草稿但重新校验目标，关闭 tab 或离开终端页面时清理，不写入数据库或 Keychain。
- 现有终端直接输入、快捷键、命令选择器和附件插入保持原行为，不把它们统一改为待发送区。

## 架构与数据流

### 组件职责

- `TerminalCommandComposerState`：位于 `ConnTerminal` 的纯状态模型，提供文本、空白校验、发送状态和一次提交生命周期，便于 host 单测覆盖。
- `TerminalCommandComposer`：位于 `ConnTerminal` 的 SwiftUI 视图，负责多行输入、动态高度、发送按钮和可访问性；不直接操作 SSH 或 `TerminalSession`。
- `TerminalHostContent`：持有页面级草稿和 Composer 视图，在发送回调中先取得当前 `TerminalComposerTarget`，再调用已有 `TerminalInputController`。
- `TerminalInputController`：新增“提交 Composer 文本”入口，并记录固定的 `tabID` 与 PTY generation。提交时同步捕获并校验 `tabID`、generation 和当前持久终端 target；校验通过后在当前 attach 的 SwiftTerm 视图上清除终端选区并调用 `paste(text:)`，让普通 PTY、tmux 和 zellij 都走现有终端输入与发送队列；不创建异步完成回调，因此不会把旧草稿结果应用到后续 tab 或 pane。
- `TerminalSession` 出站队列：将 `enqueue` 改为返回是否接受本次数据。`true` 只表示在出站队列锁内完成登记，不代表 transport 已写成功；`false` 表示队列已因关闭/失败先在线性化锁内终止。close/fail 与 enqueue 的先后由同一把锁决定，先取得锁的一方生效。队列拒绝时 Composer 不清空草稿，已接受后由原有 Session 负责后续 transport 错误和生命周期状态。

### 发送流程

1. Composer 接收系统键盘输入，换行保留在草稿中，不进入 PTY。
2. 用户点击发送，Composer 校验文本非空白并锁定发送按钮；Host 在同一主线程事件中创建不可变的 `TerminalComposerTarget(tabID, generation, persistentTarget?)`。`tabID` 和 generation 来自当前 `TerminalHostContent`，普通 PTY 的 persistent target 固定为 `nil`，持久终端的 target 来自 Controller 最近一次确认的 provider-owned state。
3. Controller 在同一同步调用链内校验 target 与自身固定 session/generation、当前 attach 和当前 provider target 完全相等；不匹配时返回失败，SwiftUI 保留草稿。
4. 校验通过后调用 SwiftTerm 的程序化粘贴入口；SwiftTerm 根据当前 bracketed paste 状态编码整段内容，Controller 将每个生成片段立即登记到现有 `TerminalSession` 出站队列，维持与终端按键、快捷键和系统粘贴的顺序。
5. 所有片段均被出站队列接受后清空 Composer；登记后 transport 失败仍由现有 Session 生命周期/断开提示负责，不创建第二条错误通道。离开页面或显式关闭 tab 只清理 Composer UI；尚未完成的队列数据按 Session 关闭语义终止，已写出的数据不撤销。

## 边界与错误处理

- 不追加回车，避免多行 shell 内容、交互式程序和危险命令因一次点击自动执行。
- 多行提交要求目标终端已声明 bracketed paste；否则裸换行无法同时保留且不触发 shell 执行，Composer 保留草稿并提示用户重试。
- 不对用户内容做 trim 或 shell 转义；只用 trim 后结果判断是否为空，原始前后空格和换行保持不变。
- 未 attach、正在回放、已断开或没有当前终端视图时不提交，并保留草稿。
- 点击处理是同步的，按钮在处理期间防重入；草稿按 tab 隔离，关闭 tab 或离开页面时清理，重连时保留但下一次点击会基于最新 target 重新校验。提交没有异步 UI 回调，因此不存在旧提交清理新 tab 草稿的问题；已登记数据是否完成由 Session 关闭语义决定。未提交草稿不会因为 provider pane target 变化而自动发送。
- Composer 不影响终端焦点协议、PTY resize、持久终端 viewport 和 provider action queue。

### 生命周期矩阵

| 事件 | Composer 草稿 | 已登记但未写出的队列数据 | 已写出的数据 |
|---|---|---|---|
| 页面 dismiss | 清理 | 当前 Session 继续处理 | 不撤销 |
| tab 切换（旧 tab 保留） | 各 tab 草稿分别保留 | 旧 Session 继续处理 | 不撤销 |
| 重连/替换 generation | 未提交草稿保留，下一次发送重新校验 | 旧 Session close/fail 终止 | 不撤销 |
| 显式关闭 tab | 清理 | Coordinator 关闭 Session，未写出部分终止 | 不撤销 |
| transport 写入失败 | 已接受的草稿已清理 | Session 失败并清理未完成队列 | 已写出的部分不撤销 |
| provider pane target 变化 | 保留但必须重新点击校验 | 不影响已提交队列 | 不撤销 |

## 测试与验收

- `ConnTerminal` 单测：空白不可提交、文本/换行/前后空白原样保留、提交状态防重复、目标匹配时提交成功并清理、未 attach/目标过期时保留，以及未开启 bracketed paste 时拒绝不安全多行内容；`TerminalSession` recording channel 验证整段输入和 bracketed paste 两种 payload，使用写入记录和显式完成闸门断言队列顺序，不用 sleep 猜测。
- `ConnTerminal` 回归单测：程序化粘贴仍走同一 planner，实时按键和已有插入 mailbox 不受影响。
- App/XCUITest：在现有 demo/fixture 终端中验证输入区显示、多行编辑、回车不发送、发送按钮可用性、发送后清空，以及键盘、快捷键栏展开、深色模式、Dynamic Type 和 tab 切换不破坏布局；字节内容、bracketed paste、过期 target、关闭/重连队列竞态由包级 recording channel 和 Controller 单测验证，不从 UI 测试强行注入远端 transport。
- 设备验收优先复用当前用户已授权设备；若设备不可用，报告真实限制，不切换或创建设备。

## 明确不做

- 不持久化输入历史或草稿。
- 不增加“发送并执行”开关。
- 不替换 SwiftTerm 原生输入，不改 SSH/PTY 协议，不新增系统 VPN 或后台服务。
