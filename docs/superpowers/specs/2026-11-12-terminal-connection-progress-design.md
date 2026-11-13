# 终端连接阶段与即时进入设计

日期：2026-11-12

## 1. 目标

用户点击终端入口后立即进入终端页，不再等待远端连接成功才创建页面。连接过程以终端画布上的阶段卡片展示：

- 网络
- 认证
- 终端通道
- 已连接

每个阶段显示状态、耗时和失败原因；失败后可以直接重试或关闭。重连复用同一套卡片。

## 2. 与 2026-08-15 方案的关系

本设计取代 `2026-08-15-current-page-terminal-launch-design.md` 中以下行为：

- 不再要求“连接成功后才打开 TerminalScreen”；
- 首次连接失败不再只停留在源页面弹窗，而是保留一个断开状态的本地 Tab，在终端页展示失败阶段并允许重试；
- 新建流程的选择阶段仍由 `NewTerminalSheet` 负责，选择完成后立即创建本地 Tab 并打开终端页。

取消、关闭和 Host 失效仍必须由协调器清理临时 session/attachment；被取消的 Tab 不得留在 Store。

## 3. 状态机

```text
点击终端
  -> startConnecting(request)
       -> 创建本地 Tab（status = .connecting）
       -> 立即打开 TerminalScreen
       -> 后台连接
            -> 成功：替换 session / attachment，status = .connected
            -> 失败：status = .disconnected，进度卡显示失败阶段
            -> 用户关闭：取消任务并删除 Tab
```

重连：

```text
TerminalScreen
  -> reconnect(tabID)
       -> status = .reconnecting
       -> 进度卡显示阶段
       -> 成功：替换 session，status = .connected
       -> 失败：status = .disconnected，卡片显示失败阶段和重试
```

## 4. 架构

- `TerminalSessionCoordinator.startConnecting` 先创建带占位 `PendingShellChannel` 的本地 Tab；真正的连接由 `TerminalScreen` 的 `beginConnectingIfNeeded` 在页面出现后启动，保证进度卡先于任何快速连接结果出现。
- 恢复会话使用同样的两段式流程：`startRestoring` 立即创建占位 Tab，`TerminalScreen` 出现后由 `beginRestoringIfNeeded` 执行 provider 恢复。
- `TerminalConnectionProgressCenter` 按 Tab/连接（activityID）保存连接活动；同一 Host 的多条终端互不覆盖，协调器负责写入，终端页只读。
- 阶段列表按 Host 的连接路径动态生成，不固定套用四条：
  - 直连：SSH → 认证 → 终端 → 已连接
  - Headscale / 私有网络：配置 → 凭据 → 节点 → 路由 → SOCKS → SSH → 认证 → 终端 → 已连接
  - 代理：代理 → SSH → 认证 → 终端 → 已连接
  - 跳板：跳板 → SSH → 认证 → 终端 → 已连接
- 私有网络的 profile/credential/state/route/socks 阶段来自底层 `ConnectionPhaseSample`；没有逐阶段样本时在连接完成后兜底补齐。
- `TerminalScreen` 根据 Tab 状态和活动状态显示 `TerminalConnectionOverlay`。
- 新建流程（普通 PTY、tmux、Docker、脚本）统一走即时 Tab 路径；tmux 仍先完成 Workspace/descriptor 选择，再创建 Tab。
- 原有 `prepareLaunch`/`commitLaunch` 事务保留给恢复和内部调用；生产新增路径使用 `startConnecting`。

## 5. 验收

- 点击新建终端后，终端页在远端连接完成前出现；
- 连接卡片按阶段更新，失败阶段与原始错误可见；
- 首次连接失败后 Tab 保留，重试成功复用同一 Tab；
- 关闭连接中的 Tab 会取消任务并清理临时通道；
- 重连期间显示同一卡片，失败可重试；
- 连接成功后的终端输入输出、tmux attachment、文件/Docker 入口行为不变。
