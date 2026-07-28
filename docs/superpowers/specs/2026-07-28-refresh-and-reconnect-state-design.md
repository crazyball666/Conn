# 采集状态可见化：刷新指示 + 重连区分 + 采集时机收敛 设计文档

日期：2026-07-28

## 背景与问题

用户报告了三个现象，排查后是同一个根因。

### 现象

1. **切 Tab 回服务器页会重新采集，界面无任何提示。**
2. **卡片在采集进行中没有表征**——数字自己跳一下，不知道何时在采、这轮成没成。
3. **App 退后台一段时间回前台，卡片显示「连接失败」**，但服务器其实好好的。

### 根因

`MonitorScheduler` 只暴露 `metrics` 与 `errors` 两个字典，UI 只能推断出三种状态：

| 条件 | `HealthCard.LoadState` | 表现 |
|---|---|---|
| `metrics[id] != nil` | `.loaded` | 正常渲染 |
| `errors[id] != nil` | `.failed(msg)` | 红色错误 |
| 都没有 | `.loading` | 骨架微光 |

**缺少「正在刷新」与「正在重连」的表达。** 三个现象都是这个缺口的不同切面：

- **现象 1**：`ServersView.onAppear` → `viewModel.appear()` → `startDashboard`，而它开头是
  「立刻采一轮 → 睡 2s → 再采一轮 → 进入常规间隔」。切一次 Tab 就是 2 秒内双采，
  全程无提示。那个 2s 预热轮的唯一目的是首采点亮 CPU（使用率需两次采样差分）。
- **现象 2**：`.loading` 只在 `metrics[id] == nil` 时出现，即**仅首次采集**。
  之后每轮采集卡片完全静默。
- **现象 3**：App 在后台期间 socket 被服务器 idle timeout 或系统回收，但
  `ConnectionManager` 池里那条会话仍标记为 `.connected`。回前台后下一轮采集拿到
  这条死会话，exec 失败，走进 `collectOne` 的 catch：

  ```swift
  } catch {
      errors[host.id] = error.friendlyDiagnosis   // → 卡片立刻变红「连接失败」
      metrics[host.id] = nil                      // → 旧读数被清空
      await connectionManager.invalidate(host: host)  // → 下一轮才重新握手
  }
  ```

  **死会话第一次使用必然失败一次，而这次失败被原样呈现成用户可见的错误。**
  要等下一个采集间隔（默认 30s）才恢复。「正在重连」与「真的连不上」在 UI 上
  长得一模一样。

### 佐证：前后台完全无处理

全仓 `scenePhase` 只接到了 `AppLockController`（应用锁）。**监控调度与连接池对
前后台切换毫无感知**，既不在进入后台时停轮询，也不在回前台时重建连接。

## 目标

- 卡片在采集进行中有明确表征。
- 「重连中」与「连接失败」在 UI 上可区分，回前台不再误报故障。
- 收敛采集时机：切 Tab / 返回列表不再无条件双采。
- 接上前后台生命周期。

## 非目标

- **不接页面级巡检概览。** `ServersViewModel` 上的 `lastScanText`（「最后巡检 3 分钟前」）、
  `abnormalCount`、`totalCount` 三个属性算好了但全仓无人渲染。顶部已有分组筛选条，
  再叠一层概览胶囊会打架。记进待办。
- 不改采集间隔的默认值与设置项。
- 不做后台采集（PRD 明确不做告警推送，后台巡检是 v1.1+ 的付费项）。

## 关键决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 状态表达 | `MonitorScheduler` 新增 `phases: [String: CollectPhase]` | `metrics`/`errors` 两个字典表达不了「进行中」 |
| 首次传输失败 | 不报错、不清空读数，同轮内立刻重握手再试一次；**第二次尝试**仍失败才认定故障 | 死会话的必然一次失败不该打扰用户；真故障只延迟一次握手的时间 |
| 回前台 | 后台 > 30s 则驱逐全部会话并强制重采 | 不等一轮失败才发现会话死了 |
| 失败重试时机 | **同轮内立刻重试**，不等下一个间隔 | 否则失败到重连之间有长达一个 interval 的空窗，比改造前更糟 |
| 常规采集的胶囊文案 | **只转圈，不改文字** | 每 30s 把「正常」换成「刷新中」会让状态区一直跳，反而更吵 |
| 预热轮 | 已有 `metrics` 基线时跳过 | 该轮唯一目的是首采点亮 CPU，有基线即纯浪费 |
| 防抖 | 距上次采集 < 5s 时连立即那轮也跳过（`force` 可绕过） | 频繁切 Tab 不该反复重采 |
| 进入后台 | **不 `stop()`** | iOS 本就挂起 App，无耗电；而 `onAppear` 回前台不保证重触发，停了起不来 |
| 转圈的无障碍 | `reduceMotion` 时改用静态 `◌` 符号 | 设计规范 §2：色彩不是唯一指示，形状编码必须保留 |

## ConnSSH：连接池查询与批量驱逐

`ConnectionManager`（actor）新增两个方法：

```swift
/// 池中是否已有该主机的活跃会话。用于区分「复用会话采集」与「重新握手」。
public func hasPooledSession(for host: ConnKit.Host) -> Bool

/// 驱逐全部池化会话。回前台时调用——后台期间 socket 多半已被
/// 服务器 idle timeout 或系统回收，主动重建比等一轮失败更快。
public func invalidateAll()
```

`invalidateAll` 复用 `invalidate(host:)` 的语义：移除条目，`.connected` 的会话在后台
fire-and-forget 关闭（不对死 socket 同步 `close()`，会卡住调用方）；
`.connecting` 的任务取消。

## ConnMonitor：状态机

### 新增类型与属性

```swift
/// 某主机当前的采集阶段。
public enum CollectPhase: Sendable, Equatable {
    /// 不在采集。
    case idle
    /// 本轮采集在飞行中，复用池中已有会话。
    case collecting
    /// 会话已被驱逐，本轮在重新握手。
    case reconnecting
}
```

`MonitorScheduler` 上：

```swift
/// 各主机当前采集阶段，键为 `Host.id`。
public private(set) var phases: [String: CollectPhase] = [:]
```

### `collectOne` 改造：同轮内立刻重试一次

拆成「一次尝试」与「决定是否重试」两层。**重试在同一轮内立刻发生**，不等下一个
采集间隔——否则失败到重连之间会有长达一个 interval 的空窗，卡片挂着旧读数且
毫无表征，比改造前更糟。

```swift
/// 采一台。
///
/// **首次传输失败会立刻重握手重试一次**：死会话（App 在后台期间被服务器
/// idle timeout 或系统回收）第一次使用必然失败，那不是故障，不该打扰用户。
/// 重试期间胶囊显示「重连中」；重试仍失败才如实转红。
private func collectOne(
    _ host: ConnKit.Host, includeExtended: Bool = false, includeProcesses: Bool = false
) async {
    // 只有「本来有读数」的主机才享受这次宽限。首采失败直接如实报错，
    // 已判定故障的主机（metrics 已被清空）也不再重试，避免每轮双倍连接尝试。
    let allowsRetry = metrics[host.id] != nil

    if let error = await attempt(host, includeExtended: includeExtended, includeProcesses: includeProcesses) {
        if allowsRetry {
            if let retryError = await attempt(
                host, includeExtended: includeExtended, includeProcesses: includeProcesses
            ) {
                record(retryError, for: host)
            }
        } else {
            record(error, for: host)
        }
    }
    phases[host.id] = .idle
}

/// 一次采集尝试。成功返回 nil；失败驱逐会话并返回错误，**不写 `errors`**——
/// 是否呈现为故障由 `collectOne` 决定。
private func attempt(
    _ host: ConnKit.Host, includeExtended: Bool, includeProcesses: Bool
) async -> Error? {
    // 池里没有会话 = 本次要握手。首采（无读数）仍走骨架态，不算重连。
    let needsHandshake = await !connectionManager.hasPooledSession(for: host)
    phases[host.id] = (needsHandshake && metrics[host.id] != nil) ? .reconnecting : .collecting
    do {
        let session = try await connectionManager.session(for: host)
        let result = try await collector.collect(
            host: host, session: session,
            includeExtended: includeExtended, includeProcesses: includeProcesses
        )
        metrics[host.id] = result.carryingOver(
            metrics[host.id], keepExtended: !includeExtended, keepProcesses: !includeProcesses
        )
        errors[host.id] = nil
        return nil
    } catch {
        await connectionManager.invalidate(host: host)
        return error
    }
}

private func record(_ error: Error, for host: ConnKit.Host) {
    errors[host.id] = error.friendlyDiagnosis
    // 清掉过期读数，主机立即显示离线/未知，而不是一直挂着旧的绿色读数。
    metrics[host.id] = nil
}
```

**连接开销**：双倍尝试只发生在「健康 → 故障」的那一轮。第一轮判定故障后
`metrics` 被清空，`allowsRetry` 转为 false，此后每轮仍是单次尝试，
长期宕机的主机没有额外成本。

**用户看到的**：正常 → （死会话失败，无闪烁）→ 重连中（转圈）→ 正常。
真故障则是：正常 → 重连中 → 连接失败（红）。

### `startDashboard` 收敛采集时机

```swift
public func startDashboard(
    hosts: [ConnKit.Host], interval: Duration = .seconds(30),
    concurrency: Int = 4, force: Bool = false
) {
    stop()
    dashboardConfig = (hosts, interval, concurrency)
    // 2s 预热轮的唯一目的是首采点亮 CPU（使用率需两次采样差分）。基线是**逐主机**的
    // （MetricCollector.previousCPU[host.id]），所以判据也必须逐主机——用全局
    // metrics.isEmpty 会让「已有 N 台在线时新增第 N+1 台」不预热（新卡片挂一整个
    // interval 才点亮 CPU 环），又会让「全部主机判定故障后 metrics 被清空」恒真
    //（每次进页面都在 2s 内双采，每轮都带连接超时）。
    let needsWarmUp = hosts.contains { metrics[$0.id] == nil }
    // 距上次采集不足 5s 视为「刚采过」（频繁切 Tab / 返回列表），本次不重采。
    // 但有主机缺基线时不防抖，否则新增主机后 5s 内切走再切回，连立即那轮都会跳过。
    // force 用于回前台——那是明确要立刻重采的场景。
    let isFresh = !force && !needsWarmUp
        && (lastScanAt.map { now().timeIntervalSince($0) < 5 } ?? false)
    let scanGeneration = generation

    task = Task { [weak self] in
        guard let self else { return }
        if !isFresh {
            await self.scanOnce(hosts: hosts, concurrency: concurrency, generation: scanGeneration)
            guard self.isCurrent(scanGeneration) else { return }
            self.lastScanAt = self.now()
            if needsWarmUp {
                try? await Task.sleep(for: .seconds(2))
                guard self.isCurrent(scanGeneration) else { return }
                await self.scanOnce(hosts: hosts, concurrency: concurrency, generation: scanGeneration)
                guard self.isCurrent(scanGeneration) else { return }
                self.lastScanAt = self.now()
            }
        }
        while self.isCurrent(scanGeneration) {
            try? await Task.sleep(for: interval)
            guard self.isCurrent(scanGeneration) else { return }
            await self.scanOnce(hosts: hosts, concurrency: concurrency, generation: scanGeneration)
            guard self.isCurrent(scanGeneration) else { return }
            self.lastScanAt = self.now()
        }
    }
}
```

> 循环体从「先采后睡」改为「先睡后采」，否则 `isFresh` 跳过立即采集后会立刻
> 又采一轮，防抖失效。

### 并发收敛：代次 + 飞行中集合

`stop()` 只能 `task.cancel()`，而协作式取消要求被取消方主动查询——一轮采集全程
挂在握手/exec 的 `await` 上，取消信号到达时早已越过检查点。回前台尤其危险：
轮询 Task 大概率刚从 `Task.sleep(interval)` 醒来进入 `scanOnce`，
`resumeAfterBackground` 的 `startDashboard(force: true)` 追不上它，于是旧轮与新轮并行
（双倍握手、旧轮结尾把新轮的转圈提前熄掉、旧轮 `record()` 盖掉新轮刚写好的成功读数
→ 卡片闪一下「连接失败」，正是本次要消灭的现象）。`scanNow`（下拉刷新）更是根本
不经过 `task`，`Task.isCancelled` 对它恒为 false。

因此收敛放在**数据侧**：

- `generation`：`stop()` 递增一次。采集发起时捕获代次，写回 `metrics`/`errors`/
  `phases`/`lastScanAt` 前一律 `guard isCurrent(scanGeneration)`。旧轮即便跑完，
  也一个字节都写不进去。
- `inFlight: Set<String>`：代次挡不住**同代**的两轮（下拉刷新 vs 轮询）。
  同一主机已有一轮在飞行中时，后到的那轮直接让位。

`stop()` 除清空 `phases`（轮询停了就没有任何一台在采集中）外，还把
`dashboardConfig` 置 nil。理由见下一节。

## App 层：前后台生命周期

**不在进入后台时 `stop()`。** iOS 本就会挂起 App，轮询 Task 自然停止推进，没有额外
耗电；而 `onAppear` 在回前台时**不保证重新触发**，停了就再也起不来，轮询会彻底死掉。
只处理回前台。

`MonitorScheduler` 记住上次的仪表盘参数，并暴露一个恢复入口：

```swift
private var dashboardConfig: (hosts: [ConnKit.Host], interval: Duration, concurrency: Int)?

/// 回前台恢复。
///
/// - Parameter idleFor: 处于后台的时长。
///
/// 后台超过 30s 时，池里的 socket 多半已被服务器 idle timeout 或系统回收——
/// 主动驱逐并立刻重采，比等下一个采集间隔（默认 30s）撞上死会话再自愈快得多。
public func resumeAfterBackground(idleFor: TimeInterval) async {
    guard idleFor > 30, let config = dashboardConfig else { return }
    await connectionManager.invalidateAll()
    startDashboard(
        hosts: config.hosts, interval: config.interval,
        concurrency: config.concurrency, force: true
    )
}
```

`startDashboard` 增加 `force: Bool = false`，为真时跳过下一节的 5 秒防抖——
回前台是明确要立刻重采的场景。

> **`dashboardConfig` 必须由 `stop()` 清空，否则这条 guard 恒真。**
> 服务器是默认 Tab，App 一启动 `dashboardConfig` 就被写上；若永不清空，**任何**
> 回前台都会执行 `invalidateAll()`。而 `ConnectionManager` 是全 App 唯一的连接池，
> `invalidateAll()` 对 `.connected` 条目做的是整条连接的 `close()`——挂在这条连接上的
> 终端交互式 shell（`TerminalScreen`）、日志 `tail -f`（`LogStreamViewModel`）、
> 跨编辑会话持有的 sftp handle（`FileEditorView`）会一起死。`TerminalScreen` 不监听
> 通道结束，`phase` 停在 `.ready`，表现为界面冻住、无报错、输入无响应。
> `ServersView.onDisappear → stop()` 正是「仪表盘不可见」的既有信号，把
> `invalidateAll` 的作用域收敛到「仪表盘此刻确实在跑」；顺带也修掉「用户已切走
> Tab 后回前台，却用陈旧配置把轮询重新拉起来」。

`RootTabView` 接 `scenePhase`（`AppLockGate` 挂在更外层，两者互不干扰）：

```swift
@Environment(\.scenePhase) private var scenePhase
@State private var backgroundedAt: Date?

.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .background:
        backgroundedAt = Date()
    case .active:
        guard let at = backgroundedAt else { break }
        let idle = Date().timeIntervalSince(at)
        backgroundedAt = nil
        Task { await dependencies.monitor.resumeAfterBackground(idleFor: idle) }
    default:
        break
    }
}
```

> **与 `collectOne` 重试的关系**：这条是加速，不是必需。就算后台不足 30s 但服务器
> 超时更短，`collectOne` 的同轮重试仍会把它表达为「重连中」而非故障——只是要等到
> 下一个采集间隔才发生。两条一起才既不误报、又恢复得快。

## ConnUI：StatusPill 转圈

`StatusPill` 新增参数：

```swift
/// 是否显示忙碌指示。true 时符号位换成转圈（reduceMotion 下为静态 `◌`）。
public init(_ text: String, semantic: Semantic, showsSymbol: Bool = true, isBusy: Bool = false)
```

符号位的渲染分支：

- `isBusy == false` → 原有的 `Text(semantic.symbol)`
- `isBusy == true` 且 `reduceMotion == false` → 自绘旋转圆弧，直径与符号等高（9pt），
  线宽 1.5pt，用 `semantic.foreground`，1 秒匀速一圈
- `isBusy == true` 且 `reduceMotion == true` → `Text("◌")`

**不使用系统 `ProgressView`**：它的尺寸与配色不受令牌控制，在 18pt 高的胶囊里
偏大且颜色跟随 tint，与既有的符号编码不协调。

## HealthCard：phase → 胶囊映射

`HealthCard.Model` 新增：

```swift
/// 采集进行中（转圈）。
public let isBusy: Bool
/// 正在重连——胶囊改显「重连中」且转蓝，与「连接失败」区分开。
public let isReconnecting: Bool
```

卡头渲染：

```swift
StatusPill(
    isReconnecting ? L("重连中") : model.status.label,
    semantic: isReconnecting ? .info : model.status.pillSemantic,
    isBusy: model.isBusy
)
```

对照表：

| `CollectPhase` | 有读数 | 胶囊文字 | 语义色 | 转圈 |
|---|---|---|---|---|
| `.reconnecting` | 是 | 重连中 | `.info` | ✓ |
| `.collecting` | 是 | 原状态（正常/警告/故障） | 原色 | ✓ |
| `.collecting` | 否（首采） | 原状态 | 原色 | ✓（卡身仍是骨架微光） |
| `.idle` | — | 原状态 | 原色 | — |

> **本表的前提：同一主机同一时刻只有一轮采集。** 表里「有读数」这一列写的是
> *发起这次 attempt 时* 的事实——`phase` 与 `metrics`/`errors` 是两次独立的写入，
> 若同一主机上有两轮采集并发，它们会被不同轮次分别写，组合就可能错配：
> 例如 A 轮把 `phase` 置为 `.reconnecting`，B 轮同时 `record()` 清掉 `metrics`
> 并写 `errors`，卡片就会读到 `isReconnecting && loadState == .failed`
> ——这个组合**单轮次下不可达，并发下可达**，不是结构性不可达。
> 该前提由 `MonitorScheduler` 的**代次（generation）+ 飞行中集合（inFlight）**
> 保证：代次挡住被 `stop()`/重启作废的旧轮的一切写回，飞行中集合挡住同代的
> 下拉刷新与轮询在同一主机上叠跑。任何绕开这两道闸的新调用路径都会让本表失效。

`accessibilityDescription` 补上「重连中」「采集中」，让 VoiceOver 与视觉一致。

## ServersViewModel 映射

`card(for:)` 里读 `monitor.phases[host.id]` 填充两个新字段：

```swift
let phase = monitor.phases[host.id] ?? .idle
// …
isBusy: phase != .idle,
isReconnecting: phase == .reconnecting
```

`HostOverviewViewModel` 持有自己的 `MonitorScheduler`（详情页 3s 高频轮询），
本次不改其 UI——详情页有独立的加载表现，且高频轮询下常驻转圈会很吵。

## 测试

**ConnMonitorTests**（`MonitorScheduler` 的 `now` 已是可注入闭包，配 `MockSSHTransport`）
- 有读数的主机首次传输失败后会立刻重试一次（`MockSSHTransport` 断言两次 exec）。
- 重试成功：不写 `errors`，读数被新结果覆盖。
- 重试仍失败：写 `errors` 并清空 `metrics`。
- 已判定故障的主机（`metrics` 为 nil）下一轮只尝试一次，不再双倍连接。
- 首采失败（本就无读数）直接写 `errors`，不重试。
- 池空且已有读数时 phase 为 `.reconnecting`；池非空时为 `.collecting`。
- 首采（无读数）且池空时 phase 为 `.collecting` 而非 `.reconnecting`。
- `metrics` 非空时 `startDashboard` 不跑 2s 预热轮（采集次数断言）。
- 距上次采集 < 5s 时 `startDashboard` 不立即采集；`force: true` 时照采。
- `stop()` 清空 `phases`。
- `resumeAfterBackground(idleFor:)`：≤30s 不动作；>30s 驱逐会话并强制重采。

**ConnSSHTests**
- `hasPooledSession` 在握手前后与 `invalidate` 后的返回值。
- `invalidateAll` 清空全部条目。

**ConnUITests**
- `StatusPill` 的忙碌符号选择：`reduceMotion` 为真时走静态 `◌` 分支
  （把分支抽成可测的纯函数 `StatusPill.busySymbol(reduceMotion:)`）。

**ConnTests**
- `ServersViewModel.cards` 的 `isBusy` / `isReconnecting` 随 `monitor.phases` 变化。

## i18n

新增文案：`重连中`（app 层 `Localizable.xcstrings`）、`采集中…`（已存在）。
`StatusPill` 的 `◌` 是符号不是文案，不入 catalog。补齐 en / ja / ko / zh-Hant。

## 待办（不在本次范围）

- 接出 `lastScanText` / `abnormalCount` / `totalCount` 三个已算好但从未渲染的属性。
- 详情页（`HostOverviewViewModel`）的采集状态表现。

## 实现与本文的偏离

Task 7（i18n 补全与验收）核对实现与本文时发现以下三处出入，均已批准/确认，
不影响行为，仅记录以便日后读码对得上。

1. **`dashboardConfig` 用具名 struct，不是本文 §「App 层：前后台生命周期」
   写的三元组。**

   本文写的是：
   ```swift
   private var dashboardConfig: (hosts: [ConnKit.Host], interval: Duration, concurrency: Int)?
   ```
   实现（`MonitorScheduler.swift:47-52`）改成了私有 `DashboardConfig` struct：
   ```swift
   private struct DashboardConfig {
       let hosts: [ConnKit.Host]
       let interval: Duration
       let concurrency: Int
   }
   private var dashboardConfig: DashboardConfig?
   ```
   原因：三元组有 3 个成员，触发 SwiftLint `large_tuple`（仓库配置上限 2 个
   成员），会把警告计数从基线 7 顶到 8。字段名与语义与本文一致，只是载体从
   匿名元组换成具名类型。

2. **`accessibilityDescription` 抽成可单测的 `static func`，并把「采集中…」
   的两处判断合并成一次。**

   本文只写了「`accessibilityDescription` 补上『重连中』『采集中』」，没有规定
   具体实现形态。实际实现（`HealthCard.swift:362-394`）：
   - 抽成 `static func accessibilityDescription(for model: Model) -> String`
     纯函数（与 `StatusPill.busySymbol(reduceMotion:)` 同一模式），脱离
     SwiftUI 视图即可单测，由 `HealthCardAccessibilityTests` 覆盖。
   - 原实现按「`isReconnecting`/`isBusy`」与「`loadState`」两套独立维度各自
     判断要不要念「采集中…」，但 `isBusy == true && loadState == .loading`
     是每台主机首次采集必经的状态（`MonitorScheduler.attempt` 对无读数主机
     恒置 `.collecting`，而 `.loading` 的条件正是 `metrics == nil`），两个
     分支会同时命中，念成「采集中…，采集中…」。改为合并成单一判断
     （`if isReconnecting … else if isBusy || loadState == .loading …`），
     `switch` 的 `.loading` 分支不再重复 append，避免首采时口播重复。

3. **i18n 小节写的落点是「app 层 `Localizable.xcstrings`」，实际落在
   ConnUI 包自己的 `Localizable.xcstrings`。**

   本文「## i18n」一节写：「新增文案：`重连中`（app 层 `Localizable.xcstrings`）」。
   但 `L("重连中")` 调用点在 `HealthCard.swift`，属于 `ConnUI` 这个 SPM 包，
   包内代码取不到 App target 的资源 bundle，只能落在包自己的
   `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`
   （Task 5 已补 en/ja/ko/zh-Hant 四语，Task 7 核对确认无缺）。本文这处
   表述与实现所在包不一致，按实际落点订正为准。
