# 当前页面终端新建流程设计

日期：2026-08-15

## 1. 目标

终端主页只展示 Conn 当前已经创建的本地 `TerminalTab`：普通 PTY、tmux attachment，以及断线但可以重连的本地 Tab。远端 tmux Session 不属于终端主页的数据源，不在主页加载、展示或缓存。

用户新建普通终端或 tmux 终端时，全部选择和远端探测都在发起操作的当前页面弹窗内完成。只有本地 Tab 创建成功后，应用才打开真实的终端页；禁止先打开空白 `TerminalScreen`，再从终端页弹出类型或 tmux Session 选择器。

本设计保持 provider-neutral：当前内置 provider 是 tmux；未来增加 Zellij 等 provider 时复用同一新建流程、Workspace 选择器和 descriptor/attachment 生命周期。

## 2. 产品原则

1. **终端主页是本地会话中心。** 它只读取 `TerminalSessionStore`，不承担远端 Workspace Catalog 职责。
2. **新建选择先于终端呈现。** 普通 PTY/tmux 选择、tmux 探测、远端 Session 选择和创建都发生在源页面弹窗。
3. **tmux 查询严格按需。** 只有用户在新建弹窗中明确选择 tmux 后，才探测 provider 并读取远端 Session。
4. **失败不产生 Tab。** 任一选择、探测或创建失败都留在弹窗内，不打开终端页，不创建失败占位 Tab，也不静默回退普通 PTY。
5. **关闭始终可见。** 新建弹窗每个阶段都有明确的“关闭”按钮；关闭会取消当前任务且不导航。

## 3. 非目标

- 不在终端主页维持实时 Catalog、Control Mode observation lease 或后台轮询。
- 不把远端 tmux Session 混入本地 Tab 列表。
- 不缓存远端 Workspace 列表。
- 本轮不在新建弹窗中提供 Window / Pane 管理入口。
- 不删除 `PersistentTerminalCatalogAttachment`、tmux Control Mode 或专有管理协议；底层能力保留给后续放置在已进入的持久终端工具栏等入口。
- 不修改数据库结构。Terminal Tab 和新建流程状态均为进程内数据。
- Docker Console、脚本终端等已经明确 backend 和初始命令的流程不重复询问普通 PTY/tmux。

## 4. 终端主页

### 4.1 数据源

主页按 Host 分组展示 `TerminalSessionStore` 中的本地 Tab：

- `.shell` / Docker / 脚本来源的普通 PTY；
- `.persistent(providerID: "tmux")` 等持久终端 attachment；
- `.connected`、`.reconnecting` 和 `.disconnected` 状态均保留显示；
- 断线 Tab 可进入终端页并按原 reconnect descriptor 重连。

主页不得展示 `RemoteWorkspaceSummary`，不得把远端 Session 数量计入本地会话数量。没有任何本地 Tab 的 Host 不出现在终端主页；用户通过“新建终端”选择该 Host。

### 4.2 网络副作用

以下操作只能读取本地 Store，不得触发 provider 或 SSH 请求：

- 打开终端主页；
- 展开或折叠主机卡片；
- 刷新页面布局；
- 在本地 Tab 之间切换。

因此从 `TerminalSessionCenterView` 移除：

- `remoteCatalogs`；
- `catalogLoadingKeys` / `catalogLoadingHostIDs`；
- `catalogTasks` / `catalogLoadGenerations`；
- `catalogHandles`；
- 展开时 `loadCatalogs`、折叠或离开时 `closeCatalogs`；
- `remoteWorkspaceSection`、实时 freshness 和远端 Session 行；
- 会话中心内的 Window / Pane 管理路由。

主页右上角“新建终端”只负责呈现当前页面的新建弹窗。

## 5. 当前页面新建弹窗

### 5.1 统一组件

新增 provider-neutral 的 `NewTerminalSheet`，由发起页面呈现。它可接收固定 Host，也可在没有固定 Host 时先显示主机选择阶段。

入口统一为：

- 终端主页右上角“新建”：弹窗先选择 Host；
- 主机详情终端入口：若已有最近使用的本地 Tab，直接打开该 Tab；否则在主机详情页弹出固定 Host 的新建流程；
- 服务器列表快捷终端：若已有最近使用的本地 Tab，直接打开；否则在服务器列表页弹出固定 Host 的新建流程；
- 已进入终端页后的“新建会话”：在当前终端页弹出固定 Host 的新建流程，成功后直接切换到新 Tab；
- 点击终端主页已有本地 Tab：直接打开，不经过新建弹窗。

Docker 和脚本入口继续按显式 request 创建，成功后进入终端，不展示本弹窗。

### 5.2 导航和关闭

弹窗使用独立 `NavigationStack`，导航栏在所有阶段提供“关闭”按钮：

- 关闭后取消当前探测、刷新或创建任务；
- 关闭后不创建 Tab、不改变当前 Tab、不打开 `TerminalScreen`；
- 子阶段提供返回按钮，但返回不能替代关闭按钮；
- 创建过程中关闭后，即使底层不可取消操作迟到成功，也必须由协调器级可取消 launch transaction 关闭临时 session/attachment，禁止写入 Store 或触发导航。仅在 Sheet 模型里取消 `Task` 或检查 generation 不足以满足该保证。

弹窗只通过一个成功结果回调返回 `(host, tabID)`。源页面收到成功结果后先关闭弹窗，再导航到 `TerminalScreen` 的 `.existing(tabID:)`；不得让 `TerminalScreen` 再执行 backend 选择或创建。

## 6. 新建流程状态机

### 6.1 阶段

```text
hostSelection（仅未固定 Host 的入口）
  -> terminalTypeSelection
       -> plainPTYCreating
       -> persistentProviderLoading
            -> persistentWorkspaceSelection
                 -> persistentAttaching
                 -> persistentCreating
  -> completed(host, tabID)
```

任一非完成状态都可以关闭。错误保留在当前阶段，可重试或返回类型选择。

### 6.2 普通 PTY

用户选择普通 PTY 后：

1. 立即以 `.createNew`、`.plainPTY` 发起 `TerminalLaunchRequest`；
2. 弹窗显示创建进度；
3. 成功后返回 `(host, tabID)`；
4. 源页面关闭弹窗，再打开已有 Tab；
5. 失败时停留在类型选择流程并显示错误。

普通 PTY 分支不执行 persistent provider probe。

### 6.3 tmux / persistent backend

只有用户明确选择 tmux 后才开始远端工作：

1. 调用 `persistentBackendCandidates(for:)` 探测已配置、启用的 provider；
2. 保留全部候选及其 `issue`，另行派生 `.available` / `.degraded` 的可用集合；
3. 没有可用候选时，从完整候选集合展示 tmux 未安装、平台不支持或 profile 不可用的诊断，不能因过滤候选而丢失原因；
4. 当前只有一个可用候选时，直接调用 `persistentWorkspaceOptions` 获取一次 Workspace 快照；
5. 多个可用 provider/profile 候选时，先让用户选择候选，再查询所选候选；
6. 不调用 `openPersistentCatalog`，不订阅 `snapshots`。

Workspace 页面支持：

- 进入已有 Session；
- 新建 Session；
- 手动刷新；
- 返回终端类型选择；
- 关闭整个弹窗。

选择已有 Workspace：

1. 通过 `makePersistentAttachmentDescriptor` 生成 descriptor；
2. 使用 `.persistent(descriptor)` backend 和 `.createNew` 创建本地 Tab；
3. 成功后返回 `(host, tabID)`；
4. 失败时保留弹窗和 Workspace 列表，不回退普通 PTY。

新建 Workspace：

1. 复用现有命名输入与校验；
2. 调用 `makePersistentBackend(from:create:for:)`；
3. 创建本地 persistent Tab；
4. 成功后返回结果，失败时留在弹窗。

手动刷新重新执行候选探测和一次 Workspace 查询，重新校准安装状态、server 状态和 Session 列表。刷新期间保留当前列表；成功后原子替换，失败时保留旧列表并显示错误。

## 7. 组件边界

### 7.1 `NewTerminalFlowModel`

新增主 actor 状态模型：

- 输入：可选固定 `Host`、Host repository、`TerminalSessionCoordinator`；
- 状态：当前 Host、阶段、候选、所选候选、Workspace、加载/刷新/创建状态、错误；
- 操作：选择 Host、选择普通 PTY、选择 persistent 类型、选择候选、刷新、进入 Workspace、新建 Workspace、返回、关闭；
- 输出：唯一一次 `completed(host, tabID)`；
- 用 UI generation 隔离迟到的 probe/list 结果；创建 Tab 使用协调器级 launch transaction，关闭或切换 Host/provider 后旧结果不能覆盖状态或写入 Store。

模型只依赖 provider-neutral 类型，不持有 `PersistentTerminalCatalogAttachment`，不接触 tmux 命令或专有 payload。

### 7.2 `NewTerminalSheet`

只负责按模型阶段渲染：

- 主机列表；
- 普通 PTY / persistent 类型选择；
- provider / Workspace 选择；
- 新建命名；
- loading、empty、unavailable、failed；
- 所有阶段固定关闭按钮。

现有 `PersistentWorkspacePicker` 的 Workspace 行、命名和空状态提取复用，避免 `TerminalScreen` 与新弹窗各自维护一套实现。

### 7.3 `TerminalScreen`

所有生产入口都向 `TerminalScreen` 传入 `.existing(tabID:)`，页面只呈现已经存在的 Tab。彻底移除由空页面触发的普通 PTY/tmux backend picker、Workspace picker和新建状态机，不保留生产调用的迁移后门。

Docker、脚本等显式入口也必须在各自当前页面通过协调器创建成功，再呈现 `.existing(tabID:)`。它们不展示普通 PTY/tmux 选择弹窗，但在创建完成前显示当前页面的进度；页面消失时取消对应 launch transaction。任何生产调用点都不得以“进入 `TerminalScreen` 后再创建”实现兼容。

终端页内“新建会话”调用同一个 `NewTerminalSheet`，成功后切换 `tabID`，无需重建外层终端页面。

### 7.4 可取消 launch transaction

`TerminalSessionCoordinator` 新增两阶段、按 attempt ID 管理的创建边界，解决底层 SSH/PTY 打开可能不响应 Swift Task cancellation 的问题：

1. 源页面创建唯一 `TerminalLaunchAttemptID`；
2. `prepareLaunch(request, attemptID:)` 打开 backend、构造临时 session/attachment 和 Tab 元数据，但不调用 `store.add`，不启动 Store 所属生命周期观察；
3. Sheet 或显式入口确认当前 UI generation 仍有效后，在 MainActor 上调用 `commitLaunch(attemptID:)`；
4. `commitLaunch` 与 `cancelLaunch` 对同一 attempt 原子竞争，只有 active/prepared attempt 可以提交；提交才把 Tab 加入 Store、启动 session/lifecycle，并返回 `tabID`；
5. `cancelLaunch(attemptID:)` 立即把 pending/prepared attempt 标为取消；已准备资源立即关闭，仍在不可取消 open 中的任务返回后只关闭临时资源，绝不写入 Store；
6. commit 成功后 attempt 转为 consumed，Sheet 的成功 dismiss 不再取消已归属 Store 的 Tab；
7. 任一失败路径清理 attempt 和临时资源，失败 Tab 不进入 Store。

`launch(_:)` 可保留为内部便利入口并以 prepare + commit 实现，但所有会受页面取消影响的生产入口必须显式持有 attempt ID。关闭 Sheet、切换 Host/provider、源页面消失和 Host identity 失效都调用 `cancelLaunch`。

该事务边界保证“关闭弹窗后无 Tab”由会话协调器负责，而不是依赖 UI Task cancellation 的时序。

### 7.5 Provider 与协调器

继续复用：

- `persistentBackendCandidates(for:)`；
- `persistentWorkspaceOptions(for:host:)`；
- `makePersistentAttachmentDescriptor(...)`；
- `makePersistentBackend(from:create:for:)`；
- `launch(_:)`。

终端主页和新建弹窗不得调用 `openPersistentCatalog`。底层 Catalog API 和管理能力保留。

## 8. 数据流

```text
打开 / 展开终端主页
  -> TerminalSessionStore
  -> 本地普通 PTY + 本地 persistent Tab + 断线 Tab
  -> 零远端请求

当前页面点击新建终端
  -> present NewTerminalSheet
  -> 选择普通 PTY
       -> create local Tab
       -> dismiss sheet
       -> open TerminalScreen(existing tab)
  -> 选择 tmux
       -> probe candidates
       -> one-shot listWorkspaces
       -> attach existing / create Workspace
       -> create local persistent Tab
       -> dismiss sheet
       -> open TerminalScreen(existing tab)

关闭弹窗
  -> cancel probe/list + invalidate UI generation
  -> cancelLaunch(attemptID)
  -> coordinator closes any late temporary session/attachment
  -> no Tab / no navigation
```

## 9. 错误和降级

- tmux 未安装、平台不支持或 profile 不可用：tmux 分支显示诊断、返回和重试；不自动创建普通 PTY。
- server 尚不存在但 provider 支持创建：显示空列表与新建操作。
- Workspace 查询失败：显示错误；手动刷新失败时保留上一份成功快照。
- descriptor、attachment 或普通 PTY 创建失败：不导航、不生成失败 Tab。
- Host 在流程中被删除或连接身份改变：当前 generation 失效，关闭临时资源并显示错误。
- 关闭弹窗或切换 Host/provider：取消 probe/list Task，并调用 `cancelLaunch(attemptID:)`；协调器负责关闭迟到的临时 session/attachment，Store 不得出现 Tab。
- 断线本地 Tab：主页继续显示；进入后使用现有 reconnect descriptor 重连。

## 10. 扩展性

- 新建弹窗只认识 `PersistentBackendCandidate`、`RemoteWorkspaceSummary` 和通用 descriptor，不通过 `providerID == "tmux"` 分支执行协议逻辑。
- “tmux”是当前产品类型文案；provider 扩展只承诺现有通用候选、Workspace、descriptor 和 attachment API 边界，本轮不设计 Zellij 专有 UI。
- Zellij 等 provider 后续可通过现有 registry/profile/workspace/descriptor 能力接入，不要求修改主页或终端页的数据边界。
- 实时 Catalog 和 Window / Pane 管理仍是可选的高级能力，与轻量新建流程解耦。

## 11. 测试和验收

### 11.1 自动化测试

- 打开、展开和折叠终端主页不会调用 provider probe、Workspace 查询或 `openPersistentCatalog`；
- 主页只渲染本地 Store 中普通、persistent 和断线 Tab，零本地 Tab 的 Host 不显示；
- 新建弹窗所有阶段都有关闭操作；
- 关闭会取消 probe/list 和 launch transaction；不可取消 open 的迟到结果只能被关闭，不能创建 Tab 或导航；
- 普通 PTY 分支不会 probe persistent provider；
- 只有选择 tmux 后才 probe 和执行一次 Workspace 查询；
- 单可用候选直接显示 Workspace，多可用候选可切换；零可用候选仍保留完整诊断；
- 手动刷新重新探测并原子替换列表，失败保留旧列表；
- unavailable、empty、failed 状态正确；
- 选择已有 Workspace 使用精确 descriptor 创建 persistent Tab；
- 新建 Workspace 使用显式 create 路由；
- 成功前不出现 `TerminalScreen`，成功后只打开 `.existing(tabID:)`；
- 主机详情、服务器快捷入口、终端主页和终端内新建复用同一流程；
- Docker 和脚本显式入口在源页面创建成功后才打开 `.existing(tabID:)`，不再由 `TerminalScreen` 创建。

### 11.2 UI 验收

只复用用户已经启动的模拟器：

- 终端主页只显示本地普通、tmux 和断线 Tab，无远端 Session、实时 freshness 或展开加载动画；
- 在终端主页、主机详情或服务器列表点击新建时，弹窗出现在当前页面；
- 弹窗每个阶段都可关闭，关闭后当前页面不变；
- 选择普通 PTY 时不出现 tmux 加载；
- 选择 tmux 后才显示探测和远端 Session 列表；
- 进入或新建成功后弹窗先关闭，再打开正确终端；
- 返回终端主页后不持续刷新或保持远端观察连接。
