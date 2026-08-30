# Zellij 轻量持久终端 Provider 设计

**日期：** 2026-08-30
**状态：** 已确认

## 目标

在不复制 tmux Control Mode 的前提下，为 Conn 增加 Zellij 持久终端支持。Zellij 复用现有 Provider registry、Session 选择、新建、PTY attachment、断线重建和本地恢复能力；终端内快捷操作通过官方默认键位组合完成。

## 已确认的产品边界

- 不设置 Zellij 最低版本，也不根据版本号阻止创建或连接。
- 不在 App 内维护 Zellij 的 Session → Tab → Pane 拓扑。
- 不实现 JSON 查询、状态订阅、WASM Bridge 或 Zellij 版 Control Mode。
- Zellij 快捷键按自身高频工作流设计，不与 tmux 功能逐项对应。
- 不新增数据库表或 Provider profile；默认配置仍是代码能力，持久恢复继续使用现有 opaque descriptor。
- 首期支持远端 Linux 和 macOS；Windows 留给现有远端平台抽象后续扩展。

## 架构

`ZellijProvider` 实现现有 `PersistentTerminalProvider`：发现可执行文件、列出/创建/删除 Session，并通过带 PTY 的 `RemoteProcessChannel` 执行 `zellij attach`。Attachment 提供 byte terminal 与轻量 `PersistentTerminalInteractionFacet`；该 facet 只拥有快捷键描述、请求校验、串行写入和静态交互状态，不观察远端拓扑。

快捷操作使用 provider-owned key macro：每个 action 映射到一段终端字节，例如 `Ctrl-T` 后接 `n`。通用终端层继续只渲染 `PersistentTerminalQuickActionGroup` 并使用现有 `TerminalProviderActionQueue`，不出现 Zellij 分支。PTY 的普通键盘输入和快捷宏都必须经过 attachment 自己的同一个串行 writer；一次宏是不可拆分的写入，不能与用户输入交错。

## Session 生命周期

- `probe` 只确认 Zellij 可执行文件存在，不解析或限制版本。
- `listWorkspaces` 调用 `zellij list-sessions --short --no-formatting`，Session 名称作为 Zellij 的 workspace identity。
- attachment 预检仅在 Session 列表查询成功且目标名称缺失时报告 `remoteObjectMissing`；查询命令失败必须保留为服务不可用，不能触发替代 Session 流程。
- `createWorkspace` 使用 `zellij attach --create-background <name>` 创建后台 Session；未填写名称时由 Conn 生成安全、唯一的 `conn-...` 名称。
- `openAttachment` 通过启动脚本验证目标仍存在，输出 Conn 私有握手帧后 `exec zellij attach <name>`。
- 目标不存在时返回 `PersistentTerminalError.remoteObjectMissing`，沿用现有“创建替代 Session”恢复路径。
- `destroyWorkspace` 使用 Zellij 的 `delete-session --force`；`renameWorkspace` 首期不暴露功能并返回明确的 unsupported feature。

Session 名称必须非空，不能是 `.`、`..`，不能包含 `/`、换行或控制字符。这样才能安全地用于列表解析、descriptor identity 和 shell 参数。

## 快捷面板

面板标题为 `Zellij`，按 Zellij 自身语义分组：

- Session：关闭 Session。首期不暴露原生 Session 管理器，因为它可以切换或重命名 Session，而轻量 attachment 无法观察并同步以名称为 identity 的本地恢复记录。
- Tab：新建、上一个、下一个、重命名、关闭、同步输入。
- Pane：新建、上下/左右分屏、切换、全屏、浮动、重命名、关闭。
- 布局与模式：上一个/下一个布局、放大/缩小 Pane、滚动、搜索、锁定输入。

关闭 Session/Tab/Pane 使用通用系统 Alert 确认。关闭 Session 写入默认 `Ctrl-Q` 后必须等待当前 Zellij attach 进程真实退出；只有进程在限定时间内退出才返回 `.workspaceClosed`，否则报告操作不可用并保留本地终端。关闭最后一个 Tab/Pane 导致 attach 进程正常退出时，attachment 通过 provider-neutral 生命周期事件关闭本地终端并删除恢复记录，不为普通关闭操作增加固定等待。其他动作只表示宏已完整写入，不显示远端状态成功 Toast。Zellij 不声明横滑手势，避免在没有拓扑状态时显示错误的切换成功提示。

默认宏以 Zellij 官方默认键位为准；Zellij 的前缀键本身具有模式语义，因此用户停留在 Locked/同名前缀模式，或完全重写 keybindings 时，快捷按钮可能不匹配。首期不读取或修改用户远端配置，也不为了判断模式增加控制面；所有默认动作尽量选择执行后回到 Normal 的官方绑定，模式不匹配时不展示未经确认的成功结果。

## UI 与本地化

新建终端入口从硬编码 `tmux` 改为“持久终端”。存在 tmux 与 Zellij 两个 provider 时，用户先选择 provider，再获取该 provider 的远端 Session。所有新增文案使用 `L()` 并提供 zh-Hans、zh-Hant、en、ja、ko。

## 验证

- ConnMultiplexer 单元测试覆盖 registry、无版本门槛探测、Session 解析/创建、descriptor、PTY 握手、缺失 Session 和快捷键字节。
- ConnTerminal/App 单元测试覆盖多 provider 选择不串线。
- XCUITest 覆盖新建终端 provider 选择和 Zellij 快捷面板的分组、破坏性 Alert。
- 在用户当前已启动的唯一模拟器上运行相关单元测试及 XCUITest，不创建 clone。
