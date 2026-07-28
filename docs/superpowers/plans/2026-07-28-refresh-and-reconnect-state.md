# 采集状态可见化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让服务器卡片如实表达采集状态——采集中转圈、重连中显示「重连中」而非误报「连接失败」、切 Tab 不再无条件重采。

**Architecture:** `MonitorScheduler` 新增 `phases: [String: CollectPhase]` 第三维状态，`collectOne` 拆成 `attempt`（一次尝试，不写错误）+ 重试决策（有读数的主机首次传输失败时同轮内立刻重握手再试一次）。`ConnectionManager` 补 `hasPooledSession` 让调度层能区分「复用会话」与「重新握手」。UI 侧 `StatusPill` 加 `isBusy` 转圈，`HealthCard` 按 phase 切换文字与语义色。App 层接 `scenePhase`，回前台驱逐死会话并强制重采。

**Tech Stack:** Swift 5.10 / iOS 17 / SwiftUI + Observation / Swift Testing（`@Test` `#expect`）/ SwiftLint。

设计依据：`docs/superpowers/specs/2026-07-28-refresh-and-reconnect-state-design.md`。

## Global Constraints

- **平台基线 iOS 17**，SPM 包 `platforms: [.iOS(.v17), .macOS("15.0")]`，不得提高。
- **面向用户的文案一律走 `L("…")`**，源语言 zh-Hans；app 层进 `Conn/Conn/Localizable.xcstrings`，ConnUI 组件进 `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`。5 种语言：zh-Hans / en / ja / ko / zh-Hant。
- **设计规范 §2：色彩不是唯一指示。** 转圈在 `reduceMotion` 下必须退化为静态形状符号 `◌`，不能只靠颜色区分状态。
- **不使用系统 `ProgressView`**：尺寸与配色不受令牌控制，在 18pt 高的胶囊里偏大且颜色跟随 tint。
- **SwiftLint 基线是 7 条既有警告**（`DemoMetricsEngine` 长行、`MetricCollector:118` 强解包、`FileBrowserView` 文件/类型过长、`MetricParserTests` 两条）。标准是**不新增**，不是归零。运行：`cd Tooling && swiftlint lint --quiet`。
- **包测试**：`cd Packages/ConnPackages && swift test --filter <Suite>`。改了跨模块签名后若报链接错误，`find Tests -name "*.swift" -exec touch {} +` 强制重编。
- **App 构建**：`xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug`。
- **App 测试**：`xcodebuild test -workspace Conn.xcworkspace -scheme Conn -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for k,v in d.items():
    if v: print(v[0]["udid"]); break')" -only-testing:ConnTests`
- **不要启动新模拟器**。先 `xcrun simctl list devices booted` 用已开的那台；若显示 Shutdown，用 `xcrun simctl bootstatus <udid> -b` 把**同一台**启回来。
- **DerivedData 有多个 Conn.app**，装包前务必按修改时间取最新的：`ls -dt $(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" -not -path "*Index.noindex*") | head -1`。

---

### Task 1: ConnectionManager 补池查询与批量驱逐

调度层要区分「复用池中会话」和「重新握手」，必须能问池里有没有这台主机。
回前台还要一次性驱逐全部会话——不能用既有的 `disconnectAll()`，它对每条会话
`await session.close()`，而后台回来时那些 socket 多半已死，同步 close 会卡住调用方。

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnSSH/ConnectionManager.swift`
- Test: `Packages/ConnPackages/Tests/ConnSSHTests/ConnectionManagerTests.swift`

**Interfaces:**
- Consumes: 无（第一个任务）。
- Produces:
  - `ConnectionManager.hasPooledSession(for host: ConnKit.Host) -> Bool`（actor 方法，调用方需 `await`）
  - `ConnectionManager.invalidateAll()`（actor 方法，非 async 内部实现，调用方需 `await`）

- [ ] **Step 1: 写失败测试**

在 `ConnectionManagerTests.swift` 的 `}` 之前追加：

```swift
    @Test("握手后池中有会话，invalidate 后没有")
    func tracksPooledSession() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let host = host()

        #expect(await !manager.hasPooledSession(for: host))
        _ = try await manager.session(for: host)
        #expect(await manager.hasPooledSession(for: host))

        await manager.invalidate(host: host)
        #expect(await !manager.hasPooledSession(for: host))
    }

    @Test("invalidateAll 清空全部池化会话")
    func invalidateAllClearsPool() async throws {
        let manager = ConnectionManager(transport: MockSSHTransport())
        let first = host(address: "10.0.0.1")
        let second = host(address: "10.0.0.2")
        _ = try await manager.session(for: first)
        _ = try await manager.session(for: second)
        #expect(await manager.activeCount == 2)

        await manager.invalidateAll()

        #expect(await manager.activeCount == 0)
        #expect(await !manager.hasPooledSession(for: first))
        #expect(await !manager.hasPooledSession(for: second))
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter ConnectionManagerTests 2>&1 | grep -E "error:|✘|Test run" | head -5
```

Expected: 编译失败 —— `ConnectionManager` 没有 `hasPooledSession` / `invalidateAll`。

- [ ] **Step 3: 实现两个方法**

在 `ConnectionManager.swift` 的 `invalidate(host:)` 之后插入：

```swift
    /// 池中是否已有该主机的条目（已连接或正在握手）。
    ///
    /// 采集调度用它区分两件事：**复用现成会话跑一条命令**，还是**要先握手**。
    /// 后者在主机本来有读数时意味着「重连中」，UI 据此显示转圈而非静默。
    public func hasPooledSession(for host: ConnKit.Host) -> Bool {
        entries[poolKey(for: host)] != nil
    }

    /// 驱逐全部池化会话（不等待关闭）。
    ///
    /// 与 `disconnectAll()` 的区别：那个会 `await session.close()` 逐条等待，
    /// 而本方法用于**回前台**——后台期间 socket 多半已被服务器 idle timeout
    /// 或系统回收，对死 socket 同步 close 会卡住调用方。语义同 `invalidate(host:)`，
    /// 只是作用于全部条目。
    public func invalidateAll() {
        let current = entries
        entries.removeAll()
        for entry in current.values {
            switch entry {
            case let .connected(session):
                Task { await session.close() }
            case let .connecting(task):
                task.cancel()
            }
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd Packages/ConnPackages && swift test --filter ConnectionManagerTests 2>&1 | grep -E "✘|Test run" | head -5
```

Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "feat(ssh): ConnectionManager 补 hasPooledSession 与 invalidateAll

hasPooledSession 让采集调度能区分「复用会话」与「重新握手」；
invalidateAll 是 disconnectAll 的 fire-and-forget 变体，供回前台驱逐死会话
（对死 socket 同步 close 会卡住调用方）。"
```

---

### Task 2: MonitorScheduler 新增采集阶段与同轮重试

这是本次的核心。`collectOne` 目前一失败就写 `errors` + 清 `metrics`，
导致死会话必然的那一次失败被原样呈现成「连接失败」。

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MonitorScheduler.swift`
- Create: `Packages/ConnPackages/Tests/ConnMonitorTests/MonitorSchedulerTests.swift`

**Interfaces:**
- Consumes: `ConnectionManager.hasPooledSession(for:)`（Task 1）。
- Produces:
  - `public enum CollectPhase: Sendable, Equatable { case idle, collecting, reconnecting }`
  - `MonitorScheduler.phases: [String: CollectPhase]`（`public private(set)`）

- [ ] **Step 1: 写失败测试**

新建 `Packages/ConnPackages/Tests/ConnMonitorTests/MonitorSchedulerTests.swift`：

```swift
import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMonitor

private typealias DomainHost = ConnKit.Host

/// 记录握手与命令次数，并按预设让前 N 次 exec 抛错（模拟后台期间死掉的会话）。
private actor CallLog {
    private(set) var connects = 0
    private(set) var execs = 0
    private var failuresRemaining: Int

    init(execFailures: Int = 0) { failuresRemaining = execFailures }

    func recordConnect() { connects += 1 }

    /// 追加 n 次待失败的 exec（测试中途注入死会话）。
    func failNext(_ count: Int) { failuresRemaining += count }

    /// 返回 true 表示本次 exec 应当抛错。
    func shouldFailExec() -> Bool {
        execs += 1
        guard failuresRemaining > 0 else { return false }
        failuresRemaining -= 1
        return true
    }
}

private final class FlakyTransport: SSHTransport {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func connect(
        _ endpoint: SSHEndpoint, username: String, auth: SSHAuth, hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        await log.recordConnect()
        return FlakySession(log: log)
    }
}

private final class FlakySession: SSHSession {
    private let log: CallLog
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(log: CallLog) {
        self.log = log
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        if await log.shouldFailExec() { throw SSHError.channelClosed }
        // 空输出即可：MetricParser 解析出全 nil 的 HostMetrics，但字典里是非 nil 值，
        // 足以让「这台主机已知可用」成立。
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

@MainActor
@Suite("MonitorScheduler — 采集阶段与重试")
struct MonitorSchedulerTests {
    private func makeScheduler(execFailures: Int = 0) -> (MonitorScheduler, CallLog) {
        let log = CallLog(execFailures: execFailures)
        let manager = ConnectionManager(transport: FlakyTransport(log: log))
        return (MonitorScheduler(connectionManager: manager), log)
    }

    private func host(_ id: String = "h1") -> DomainHost {
        DomainHost(id: id, name: "web", address: "10.0.0.1", username: "root")
    }

    @Test("首采成功后有读数，阶段回到 idle")
    func firstScanPopulatesMetrics() async {
        let (scheduler, log) = makeScheduler()
        let target = host()

        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.metrics[target.id] != nil)
        #expect(scheduler.errors[target.id] == nil)
        #expect(scheduler.phases[target.id] == .idle)
        #expect(await log.execs == 1)
    }

    @Test("有读数的主机首次 exec 失败会同轮立刻重试，不报错")
    func retriesOnceWithoutSurfacingError() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        // 先采一轮建立「已知可用」
        await scheduler.scanNow(hosts: [target])
        #expect(scheduler.metrics[target.id] != nil)

        // 让下一次 exec 失败一次（模拟死会话）
        await log.failNext(1)
        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.errors[target.id] == nil)
        #expect(scheduler.metrics[target.id] != nil)
        // 第 1 轮 1 次 + 第 2 轮（失败 1 次 + 重试 1 次）= 3
        #expect(await log.execs == 3)
        // 重试前驱逐了会话，所以重新握手了一次
        #expect(await log.connects == 2)
    }

    @Test("重试也失败才认定故障，清空读数")
    func secondFailureSurfacesError() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])

        await log.failNext(2)
        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.errors[target.id] != nil)
        #expect(scheduler.metrics[target.id] == nil)
        #expect(scheduler.phases[target.id] == .idle)
    }

    @Test("已判定故障的主机每轮只尝试一次，不再双倍连接")
    func failedHostDoesNotDoubleAttempt() async {
        let (scheduler, log) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])   // exec 1
        await log.failNext(2)
        await scheduler.scanNow(hosts: [target])   // exec 2、3 → 判定故障

        await log.failNext(1)
        await scheduler.scanNow(hosts: [target])   // 只该有 exec 4

        #expect(await log.execs == 4)
    }

    @Test("首采失败直接报错，不重试")
    func firstScanFailureSurfacesImmediately() async {
        let (scheduler, log) = makeScheduler(execFailures: 1)
        let target = host()

        await scheduler.scanNow(hosts: [target])

        #expect(scheduler.errors[target.id] != nil)
        #expect(scheduler.metrics[target.id] == nil)
        #expect(await log.execs == 1)
    }

    @Test("stop 清空全部阶段")
    func stopClearsPhases() async {
        let (scheduler, _) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])

        scheduler.stop()

        #expect(scheduler.phases.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter MonitorSchedulerTests 2>&1 | grep -E "error:|✘" | head -5
```

Expected: 编译失败 —— `MonitorScheduler` 没有 `phases`。

- [ ] **Step 3: 新增 CollectPhase 与 phases 属性**

在 `MonitorScheduler.swift` 的 `import` 之后、`MonitorScheduler` 类型之前插入：

```swift
/// 某主机当前的采集阶段。
///
/// 与 `metrics`/`errors` 正交：那两者说「有没有读数、是不是已判定故障」，
/// 本枚举说「此刻有没有在采、是不是在重新握手」。
public enum CollectPhase: Sendable, Equatable {
    /// 不在采集。
    case idle
    /// 本轮采集在飞行中，复用池中已有会话。
    case collecting
    /// 会话已被驱逐，本轮在重新握手。
    case reconnecting
}
```

在类内 `errors` 属性之后插入：

```swift
    /// 各主机当前采集阶段，键为 `Host.id`。驱动卡片右上角的转圈与「重连中」。
    public private(set) var phases: [String: CollectPhase] = [:]
```

- [ ] **Step 4: 把 collectOne 拆成 attempt + 重试决策**

用下面三个方法**整体替换**现有的 `collectOne`：

```swift
    /// 采一台。失败只记 `errors[host.id]`，不抛、不影响其他主机（方案 §4.3 验收）。
    /// 仪表盘轮询默认只取核心段；详情轮询按 `wantsExtended`/`wantsProcesses` 传入。
    ///
    /// **首次传输失败会立刻重握手重试一次**：死会话（App 在后台期间被服务器
    /// idle timeout 或系统回收）第一次使用必然失败，那不是故障，不该打扰用户。
    /// 重试期间 `phases` 为 `.reconnecting`，UI 显示「重连中」；重试仍失败才如实转红。
    private func collectOne(
        _ host: ConnKit.Host, includeExtended: Bool = false, includeProcesses: Bool = false
    ) async {
        // 只有「本来有读数」的主机才享受这次宽限。首采失败直接如实报错；
        // 已判定故障的主机（metrics 已被清空）也不再重试，避免每轮双倍连接尝试。
        let allowsRetry = metrics[host.id] != nil

        if let error = await attempt(
            host, includeExtended: includeExtended, includeProcesses: includeProcesses
        ) {
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

    /// 一次采集尝试。
    ///
    /// 成功返回 nil；失败驱逐会话并返回错误，**不写 `errors`**——
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
            // 本轮没采的段（切走的概览/进程段）沿用上次值，切回来不闪空/不重载。
            metrics[host.id] = result.carryingOver(
                metrics[host.id], keepExtended: !includeExtended, keepProcesses: !includeProcesses
            )
            errors[host.id] = nil
            return nil
        } catch {
            // #2：驱逐可能已死的会话，下次尝试重新握手 → 断网后自愈。
            await connectionManager.invalidate(host: host)
            return error
        }
    }

    /// 认定为故障：写错误文案并清掉过期读数。
    private func record(_ error: Error, for host: ConnKit.Host) {
        errors[host.id] = error.friendlyDiagnosis
        // #1：清掉过期实时指标，主机立即显示离线/未知，而不是一直挂着旧的绿色读数。
        metrics[host.id] = nil
    }
```

- [ ] **Step 5: stop 清空 phases**

```swift
    /// 停止轮询（页面不可见 / 切走时调用）。
    public func stop() {
        task?.cancel()
        task = nil
        // 轮询停了就没有任何一台在采集中，否则转圈会一直挂着。
        phases.removeAll()
    }
```

- [ ] **Step 6: 跑测试确认通过**

```bash
cd Packages/ConnPackages && swift test --filter MonitorSchedulerTests 2>&1 | grep -E "✘|Test run" | head -8
```

Expected: 6 条全部 PASS。若报链接错误，先
`find Tests -name "*.swift" -exec touch {} +` 再跑。

- [ ] **Step 7: 跑全量包测试与 lint**

```bash
cd Packages/ConnPackages && swift test 2>&1 | grep -E "✘|Test run" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
```

Expected: 全绿；lint 为 7。

- [ ] **Step 8: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "feat(monitor): 新增 CollectPhase 与同轮重试，死会话不再误报故障

collectOne 拆成 attempt（一次尝试，不写 errors）+ 重试决策：有读数的主机
首次传输失败立刻重握手再试一次，重试仍失败才认定故障。死会话第一次使用
必然失败，那不是故障。双倍尝试只发生在健康→故障的那一轮。"
```

---

### Task 3: 收敛采集时机 + 回前台恢复入口

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnMonitor/MonitorScheduler.swift`
- Test: `Packages/ConnPackages/Tests/ConnMonitorTests/MonitorSchedulerTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `invalidateAll()`；Task 2 的 `phases`。
- Produces:
  - `startDashboard(hosts:interval:concurrency:force:)`，`force: Bool = false`
  - `resumeAfterBackground(idleFor: TimeInterval) async`

- [ ] **Step 1: 写失败测试**

在 `MonitorSchedulerTests` 里追加（注意 `MonitorScheduler` 的 `now` 是可注入闭包）：

```swift
    /// 用可控时钟构造，便于测防抖。
    private func makeScheduler(
        execFailures: Int = 0, now: @escaping () -> Date
    ) -> (MonitorScheduler, CallLog) {
        let log = CallLog(execFailures: execFailures)
        let manager = ConnectionManager(transport: FlakyTransport(log: log))
        return (MonitorScheduler(connectionManager: manager, now: now), log)
    }

    @Test("已有读数时跳过 2s 预热轮")
    func skipsWarmUpWhenBaselineExists() async throws {
        let (scheduler, log) = makeScheduler()
        let target = host()
        await scheduler.scanNow(hosts: [target])       // exec 1，建立基线
        let before = await log.execs

        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        // 只应多出「立即那一轮」，不该有 2s 后的预热轮
        #expect(await log.execs == before + 1)
    }

    @Test("距上次采集不足 5 秒时不重采")
    func debouncesRapidRestarts() async throws {
        let clock = MutableClock()
        let (scheduler, log) = makeScheduler(now: { clock.now })
        let target = host()
        await scheduler.scanNow(hosts: [target])
        let before = await log.execs

        clock.advance(by: 2)                            // 只过了 2 秒
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs == before)
    }

    @Test("force 绕过防抖")
    func forceBypassesDebounce() async throws {
        let clock = MutableClock()
        let (scheduler, log) = makeScheduler(now: { clock.now })
        let target = host()
        await scheduler.scanNow(hosts: [target])
        let before = await log.execs

        clock.advance(by: 2)
        scheduler.startDashboard(hosts: [target], interval: .seconds(600), force: true)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs == before + 1)
    }

    @Test("后台不足 30 秒时回前台不动作")
    func shortBackgroundDoesNothing() async throws {
        let (scheduler, log) = makeScheduler()
        let target = host()
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        try await Task.sleep(for: .milliseconds(300))
        let before = await log.execs

        await scheduler.resumeAfterBackground(idleFor: 10)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs == before)
    }

    @Test("后台超过 30 秒时回前台驱逐会话并强制重采")
    func longBackgroundReconnects() async throws {
        let (scheduler, log) = makeScheduler()
        let target = host()
        scheduler.startDashboard(hosts: [target], interval: .seconds(600))
        try await Task.sleep(for: .milliseconds(300))
        let execsBefore = await log.execs
        let connectsBefore = await log.connects

        await scheduler.resumeAfterBackground(idleFor: 60)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.stop()

        #expect(await log.execs > execsBefore)
        // 会话被驱逐过，必须重新握手
        #expect(await log.connects == connectsBefore + 1)
    }
```

并在文件末尾（`MonitorSchedulerTests` 之外）加可变时钟：

```swift
/// 可手动推进的时钟，用于测防抖。
private final class MutableClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter MonitorSchedulerTests 2>&1 | grep -E "error:|✘" | head -5
```

Expected: 编译失败 —— `startDashboard` 没有 `force` 参数、没有 `resumeAfterBackground`。

- [ ] **Step 3: 加 dashboardConfig 存储**

在 `MonitorScheduler` 类内 `private var task: Task<Void, Never>?` 之后插入：

```swift
    /// 上次 `startDashboard` 的参数。回前台恢复时按原样重启。
    private var dashboardConfig: (hosts: [ConnKit.Host], interval: Duration, concurrency: Int)?
```

- [ ] **Step 4: 改写 startDashboard**

整体替换现有的 `startDashboard`：

```swift
    /// 仪表盘模式：轮询全部主机，每轮并发上限 `concurrency`，轮间隔 `interval`。
    ///
    /// 两处收敛，避免切 Tab / 返回列表时无条件重采：
    /// - **预热轮**（开头睡 2s 再采一次）只为首采点亮 CPU（使用率需两次采样差分）。
    ///   已有读数说明基线在，跳过。
    /// - **防抖**：距上次采集不足 5s 视为刚采过，本次连立即那轮也跳过。
    ///   `force` 用于回前台——那是明确要立刻重采的场景。
    public func startDashboard(
        hosts: [ConnKit.Host],
        interval: Duration = .seconds(30),
        concurrency: Int = 4,
        force: Bool = false
    ) {
        stop()
        dashboardConfig = (hosts, interval, concurrency)
        let isFresh = !force && (lastScanAt.map { now().timeIntervalSince($0) < 5 } ?? false)
        let needsWarmUp = metrics.isEmpty

        task = Task { [weak self] in
            guard let self else { return }
            if !isFresh {
                await self.scanOnce(hosts: hosts, concurrency: concurrency)
                self.lastScanAt = self.now()
                if needsWarmUp {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self.scanOnce(hosts: hosts, concurrency: concurrency)
                    self.lastScanAt = self.now()
                }
            }
            // 先睡后采：否则 isFresh 跳过立即采集后会马上又采一轮，防抖失效。
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self.scanOnce(hosts: hosts, concurrency: concurrency)
                self.lastScanAt = self.now()
            }
        }
    }
```

- [ ] **Step 5: 加 resumeAfterBackground**

在 `stop()` 之后插入：

```swift
    /// 回前台恢复。
    ///
    /// - Parameter idleFor: 处于后台的时长（秒）。
    ///
    /// 后台超过 30s 时，池里的 socket 多半已被服务器 idle timeout 或系统回收——
    /// 主动驱逐并强制重采，比等下一个采集间隔（默认 30s）撞上死会话再自愈快得多。
    /// 不足 30s 则什么都不做：轮询 Task 随 App 恢复自然继续，就算会话真死了，
    /// `collectOne` 的同轮重试也会兜住。
    public func resumeAfterBackground(idleFor: TimeInterval) async {
        guard idleFor > 30, let config = dashboardConfig else { return }
        await connectionManager.invalidateAll()
        startDashboard(
            hosts: config.hosts, interval: config.interval,
            concurrency: config.concurrency, force: true
        )
    }
```

- [ ] **Step 6: 跑测试确认通过**

```bash
cd Packages/ConnPackages && swift test --filter MonitorSchedulerTests 2>&1 | grep -E "✘|Test run" | head -8
```

Expected: 11 条全部 PASS。

- [ ] **Step 7: 全量包测试 + lint**

```bash
cd Packages/ConnPackages && swift test 2>&1 | grep -E "✘|Test run" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
```

Expected: 全绿；lint 为 7。

- [ ] **Step 8: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "feat(monitor): 收敛采集时机，新增回前台恢复入口

有读数时跳过 2s 预热轮（该轮只为首采点亮 CPU）；距上次采集不足 5s 不重采。
循环体改为先睡后采，否则防抖会被紧随其后的一轮抵消。
resumeAfterBackground 在后台超 30s 时驱逐全部会话并强制重采。"
```

---

### Task 4: StatusPill 忙碌转圈

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnUI/Components/StatusPill.swift`
- Create: `Packages/ConnPackages/Tests/ConnUITests/StatusPillTests.swift`
- Modify: `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `StatusPill.init(_:semantic:showsSymbol:isBusy:)`，`isBusy: Bool = false`
  - `StatusPill.busySymbol(reduceMotion:) -> String?`（纯函数，`nil` 表示应画转圈）

- [ ] **Step 1: 写失败测试**

新建 `Packages/ConnPackages/Tests/ConnUITests/StatusPillTests.swift`：

```swift
import Foundation
import Testing
@testable import ConnUI

@Suite("StatusPill — 忙碌指示")
struct StatusPillTests {
    @Test("常规动效下画转圈，不用静态符号")
    func spinsWhenMotionAllowed() {
        #expect(StatusPill.busySymbol(reduceMotion: false) == nil)
    }

    /// 设计规范 §2：色彩不是唯一指示。关掉动效后必须仍有形状编码。
    @Test("reduceMotion 下退化为静态符号")
    func staticSymbolWhenMotionReduced() {
        #expect(StatusPill.busySymbol(reduceMotion: true) == "◌")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd Packages/ConnPackages && swift test --filter StatusPillTests 2>&1 | grep -E "error:|✘" | head -5
```

Expected: 编译失败 —— `StatusPill` 没有 `busySymbol`。

- [ ] **Step 3: 加 isBusy 与转圈**

`StatusPill.swift` 中，把 `showsSymbol` 属性与 init 改为：

```swift
    private let text: String
    private let semantic: Semantic
    private let showsSymbol: Bool
    private let isBusy: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinAngle: Double = 0

    /// - Parameters:
    ///   - text: 胶囊文字，如「正常」「running」「exit 5」。
    ///   - semantic: 状态语义，决定符号与配色。
    ///   - showsSymbol: 是否显示前导形状符号。纯计数类徽标（如「12 台主机」）
    ///     不表达状态，可关闭。
    ///   - isBusy: 是否正在进行中。为真时把符号位换成转圈；`reduceMotion`
    ///     开启时退化为静态 `◌`——设计规范 §2 要求形状编码不能只靠颜色代替。
    public init(
        _ text: String,
        semantic: Semantic,
        showsSymbol: Bool = true,
        isBusy: Bool = false
    ) {
        self.text = text
        self.semantic = semantic
        self.showsSymbol = showsSymbol
        self.isBusy = isBusy
    }

    /// 忙碌时符号位该画什么。返回 nil 表示画转圈，否则用返回的静态符号。
    ///
    /// 抽成纯函数以便脱离 SwiftUI 单测。
    public static func busySymbol(reduceMotion: Bool) -> String? {
        reduceMotion ? "◌" : nil
    }
```

把 `body` 里的符号分支改为：

```swift
    public var body: some View {
        HStack(spacing: 5) {
            if showsSymbol {
                symbolView
            }
            Text(text)
        }
        .font(.connData(.caption))
        .fontWeight(.semibold)
        .connTabularNumbers()
        .foregroundStyle(semantic.foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .background(semantic.background, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var symbolView: some View {
        if isBusy {
            if let fallback = Self.busySymbol(reduceMotion: reduceMotion) {
                Text(fallback)
            } else {
                spinner
            }
        } else {
            Text(semantic.symbol)
        }
    }

    /// 自绘转圈：一段 270° 圆弧匀速旋转。
    ///
    /// 不用系统 `ProgressView`——它的尺寸与配色不受令牌控制，在 18pt 高的胶囊里
    /// 偏大且颜色跟随 tint，与既有的符号编码不协调。
    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(semantic.foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(spinAngle))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            }
            .onDisappear { spinAngle = 0 }
    }
```

文件顶部确保有 `import SwiftUI`（已有）。

- [ ] **Step 4: 跑测试确认通过**

```bash
cd Packages/ConnPackages && swift test --filter StatusPillTests 2>&1 | grep -E "✘|Test run" | head -5
```

Expected: 2 条 PASS。

- [ ] **Step 5: 补 ConnUI 预览**

在 `StatusPill.swift` 两个 `#Preview` 的 `VStack` 里各加一行，便于目视验收：

```swift
        StatusPill("重连中", semantic: .info, isBusy: true)
```

- [ ] **Step 6: 构建 + lint**

```bash
cd Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
```

Expected: 无 error；lint 为 7。

- [ ] **Step 7: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "feat(ui): StatusPill 支持忙碌转圈

isBusy 时符号位换成自绘 270° 弧匀速旋转；reduceMotion 下退化为静态 ◌，
满足设计规范 §2「色彩不是唯一指示」。不用系统 ProgressView——尺寸与配色
不受令牌控制，在 18pt 胶囊里偏大。"
```

---

### Task 5: HealthCard 按采集阶段切换胶囊

**Files:**
- Modify: `Packages/ConnPackages/Sources/ConnUI/Components/HealthCard.swift`
- Modify: `Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 4 的 `StatusPill(_:semantic:showsSymbol:isBusy:)`。
- Produces:
  - `HealthCard.Model.isBusy: Bool`（init 参数 `isBusy: Bool = false`）
  - `HealthCard.Model.isReconnecting: Bool`（init 参数 `isReconnecting: Bool = false`）

- [ ] **Step 1: Model 加两个字段**

在 `Model` 的 `note` 属性之后加：

```swift
        /// 采集进行中——右上角胶囊转圈。
        public let isBusy: Bool
        /// 正在重连：胶囊改显「重连中」并转蓝，与已认定的「连接失败」区分开。
        public let isReconnecting: Bool
```

init 签名在 `note: String? = nil` 之后追加两个参数，并在体内赋值：

```swift
            note: String? = nil,
            isBusy: Bool = false,
            isReconnecting: Bool = false
        ) {
            // …既有赋值…
            self.note = note
            self.isBusy = isBusy
            self.isReconnecting = isReconnecting
        }
```

- [ ] **Step 2: 卡头按状态渲染**

把 `header` 里这一行：

```swift
                StatusPill(model.status.label, semantic: model.status.pillSemantic)
```

替换为：

```swift
                StatusPill(pillText, semantic: pillSemantic, isBusy: model.isBusy)
```

并在 `headerMeta` 之前加两个派生属性：

```swift
    /// 重连中时盖掉状态文案——「重连中」比「正常/故障」更贴近此刻发生的事。
    /// 常规采集**不改文案**，只转圈：每 30s 把「正常」换成「刷新中」会让状态区
    /// 一直跳，反而更吵。
    private var pillText: String {
        model.isReconnecting ? L("重连中") : model.status.label
    }

    private var pillSemantic: StatusPill.Semantic {
        model.isReconnecting ? .info : model.status.pillSemantic
    }
```

- [ ] **Step 3: 无障碍描述跟上**

把 `accessibilityDescription` 的开头改为：

```swift
    private var accessibilityDescription: String {
        var parts = ["\(model.title)，\(model.status.label)"]
        if model.isReconnecting {
            parts.append(L("重连中"))
        } else if model.isBusy {
            parts.append(L("采集中…"))
        }
        switch model.loadState {
```

（`switch` 及其后续内容不变。）

- [ ] **Step 4: 补 ConnUI 文案**

`Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings` 新增 `重连中`
（`采集中…` 已存在）。用脚本追加，保持既有格式：

```bash
cd /Users/crazyball/Code/Swift/Conn && python3 - <<'PY'
import json, pathlib
p = pathlib.Path("Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings")
cat = json.loads(p.read_text())
langs = {"en": "Reconnecting", "ja": "再接続中", "ko": "재연결 중", "zh-Hant": "重新連線中"}
entry = cat["strings"].setdefault("重连中", {})
loc = entry.setdefault("localizations", {})
for lang, value in langs.items():
    loc[lang] = {"stringUnit": {"state": "translated", "value": value}}
cat["strings"] = dict(sorted(cat["strings"].items()))
p.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
print("ok")
PY
```

- [ ] **Step 5: 补预览**

在 `HealthCard.swift` 既有 `#Preview` 的样例数组里追加一张重连中的卡：

```swift
        HealthCard.Model(
            id: "4", name: "reconnecting-host", address: "root@10.0.0.4",
            status: .ok, cpu: 12, memory: 40, disk: 55,
            isBusy: true, isReconnecting: true
        )
```

- [ ] **Step 6: 构建 + 测试 + lint**

```bash
cd Packages/ConnPackages && swift build 2>&1 | grep -E "error:" | head -5
swift test 2>&1 | grep -E "✘|Test run" | head -5
cd /Users/crazyball/Code/Swift/Conn/Tooling && swiftlint lint --quiet | wc -l
```

Expected: 无 error；测试全绿；lint 为 7。

- [ ] **Step 7: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "feat(ui): HealthCard 按采集阶段切换右上角胶囊

isReconnecting 时显示「重连中」并转蓝，与已认定的「连接失败」区分；
常规采集只转圈不改文案，避免状态区每 30s 跳一次。"
```

---

### Task 6: 接线 —— ServersViewModel 映射 + RootTabView 前后台

**Files:**
- Modify: `Conn/Conn/Servers/ServersViewModel.swift`
- Modify: `Conn/Conn/RootTabView.swift`
- Test: `Conn/ConnTests/ServersViewModelTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `MonitorScheduler.phases` / `CollectPhase`；Task 3 的
  `resumeAfterBackground(idleFor:)`；Task 5 的 `HealthCard.Model.isBusy` / `isReconnecting`。
- Produces: 无对外接口。

- [ ] **Step 1: 写失败测试**

映射本身只有两行，但要让它真能被测到，得在采集**进行中**观察卡片。
用一个由测试控制开合的闸门卡住 `exec`，就能确定性地停在 `.collecting`。

在 `Conn/ConnTests/ServersViewModelTests.swift` 顶部 import 区补 `import ConnMonitor`
（`ConnSSH` 已在），并在文件末尾（`ServersViewModelTests` 之外）追加：

```swift
/// 由测试控制开合的闸门：`exec` 在此挂起，直到测试放行。
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class GatedTransport: SSHTransport {
    let gate: Gate
    init(gate: Gate) { self.gate = gate }

    func connect(
        _ endpoint: SSHEndpoint, username: String, auth: SSHAuth, hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        GatedSession(gate: gate)
    }
}

private final class GatedSession: SSHSession {
    private let gate: Gate
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation

    init(gate: Gate) {
        self.gate = gate
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        await gate.wait()
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}
```

在 `ServersViewModelTests` 的 `}` 之前追加：

```swift
    @Test("采集进行中卡片标记为忙碌，结束后复位")
    func mapsCollectPhaseToCard() async throws {
        let target = Host(name: "web", address: "10.0.0.1", username: "root")
        let gate = Gate()
        let monitor = MonitorScheduler(
            connectionManager: ConnectionManager(transport: GatedTransport(gate: gate))
        )
        let viewModel = ServersViewModel(
            hostStore: StubHostRepository(hosts: [target]),
            groupStore: StubHostGroupRepository(),
            monitor: monitor
        )
        viewModel.load()
        #expect(viewModel.cards.first?.isBusy == false)

        let scan = Task { await monitor.scanNow(hosts: [target]) }

        // 等采集真正进入飞行中（exec 被闸门卡住）。上限 200 次让步，避免死等。
        var busySeen = false
        for _ in 0 ..< 200 where !busySeen {
            await Task.yield()
            busySeen = viewModel.cards.first?.isBusy == true
        }
        #expect(busySeen)
        // 首采无读数，池空时仍应是 collecting 而非 reconnecting
        #expect(viewModel.cards.first?.isReconnecting == false)

        await gate.open()
        await scan.value

        #expect(viewModel.cards.first?.isBusy == false)
    }
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/crazyball/Code/Swift/Conn
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for k,v in d.items():
    if v: print(v[0]["udid"]); break')" \
  -only-testing:ConnTests/ServersViewModelTests 2>&1 | grep -E "error:|\*\* TEST|busySeen" | head -5
```

Expected: FAIL —— `busySeen` 为 false。`ServersViewModel` 还没把 `monitor.phases`
映射到 `HealthCard.Model.isBusy`，该字段恒为默认的 false。

- [ ] **Step 3: ServersViewModel 填充两个字段**

在 `card(for:)` 方法体开头加：

```swift
    private func card(for host: Host) -> HealthCard.Model {
        let metrics = monitor.metrics[host.id]
        let error = monitor.errors[host.id]
        let phase = monitor.phases[host.id] ?? .idle
```

并在 `HealthCard.Model(...)` 的 `note: host.note` 之后追加两个实参：

```swift
            note: host.note,
            isBusy: phase != .idle,
            isReconnecting: phase == .reconnecting
        )
```

- [ ] **Step 4: RootTabView 接前后台**

`Conn/Conn/RootTabView.swift` 的 `RootTabView` 中，在 `selection` 之后加状态：

```swift
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundedAt: Date?
```

并在 `TabView { … }` 之后挂修饰器：

```swift
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // 不 stop()：iOS 本就挂起 App，轮询 Task 自然停止推进，没有额外耗电；
                // 而 onAppear 回前台不保证重新触发，停了就再也起不来。
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

- [ ] **Step 5: 构建并跑 App 测试**

```bash
cd /Users/crazyball/Code/Swift/Conn
xcodebuild build -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug 2>&1 | grep -E "error:|BUILD" | head -5
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for k,v in d.items():
    if v: print(v[0]["udid"]); break')" \
  -only-testing:ConnTests 2>&1 | grep -E "error:|\*\* TEST" | head -5
```

Expected: `BUILD SUCCEEDED`；`TEST SUCCEEDED`。

- [ ] **Step 6: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "feat: 服务器卡片接上采集阶段，RootTabView 接前后台

ServersViewModel 把 monitor.phases 映射为卡片的 isBusy/isReconnecting；
RootTabView 在回前台时调 resumeAfterBackground。进入后台不 stop——
iOS 本就挂起 App，而 onAppear 回前台不保证重触发。"
```

---

### Task 7: i18n 补全与真机验收

**Files:**
- Modify: `Conn/Conn/Localizable.xcstrings`
- Modify: `docs/superpowers/specs/2026-07-28-refresh-and-reconnect-state-design.md`（若实现有偏离）

**Interfaces:**
- Consumes: 前 6 个任务引入的全部 `L("…")` 新键。
- Produces: 无。

- [ ] **Step 1: 扫出缺失的 key**

```bash
cd /Users/crazyball/Code/Swift/Conn && python3 - <<'PY'
import json, pathlib, re
keys = set()
for f in pathlib.Path("Conn/Conn").rglob("*.swift"):
    for m in re.finditer(r'L\("((?:[^"\\]|\\.)*)"\)', f.read_text()):
        keys.add(m.group(1))
cat = json.loads(pathlib.Path("Conn/Conn/Localizable.xcstrings").read_text())
missing = sorted(k for k in keys if k not in cat["strings"])
print("MISSING:", missing or "（无）")
PY
```

Expected: 本次 app 层没有新增 `L()` 文案（「重连中」在 ConnUI 层，Task 5 已补）。
若列出内容，按下一步补齐。

- [ ] **Step 2: 补齐 4 种语言（仅当 Step 1 列出了 key）**

对每个 key 追加 `en` / `ja` / `ko` / `zh-Hant`，格式照 Task 5 Step 4 的脚本。
Step 1 无输出则跳过本步。

- [ ] **Step 3: clean build**

xcstrings 改动必须 clean build，增量构建会继续用旧的字符串目录。

```bash
cd /Users/crazyball/Code/Swift/Conn
xcodebuild -workspace Conn.xcworkspace -scheme Conn -destination 'generic/platform=iOS Simulator' -configuration Debug clean build 2>&1 | grep -E "error:|BUILD" | head -5
```

Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: 全量测试 + lint**

```bash
cd /Users/crazyball/Code/Swift/Conn/Packages/ConnPackages && swift test 2>&1 | grep -E "✘|Test run" | head -5
cd /Users/crazyball/Code/Swift/Conn
xcodebuild test -workspace Conn.xcworkspace -scheme Conn \
  -destination "id=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for k,v in d.items():
    if v: print(v[0]["udid"]); break')" 2>&1 | grep -E "\*\* TEST" | head -3
cd Tooling && swiftlint lint --quiet | wc -l
```

Expected: 包测试全绿；`TEST SUCCEEDED`；lint 为 7。

- [ ] **Step 5: 截图验收转圈**

用**已启动**的模拟器（不要 boot 新的），演示模式下截图。注意取最新的 DerivedData：

```bash
cd /Users/crazyball/Code/Swift/Conn
DEV=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for k,v in d.items():
    if v: print(v[0]["udid"]); break')
APP=$(ls -dt $(find ~/Library/Developer/Xcode/DerivedData -name "Conn.app" -path "*Debug-iphonesimulator*" -not -path "*Index.noindex*") | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1
xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_CONN_DEMO=1 xcrun simctl launch "$DEV" "$BUNDLE"
sleep 1 && xcrun simctl io "$DEV" screenshot /tmp/cards-busy.png
sleep 6 && xcrun simctl io "$DEV" screenshot /tmp/cards-idle.png
```

Expected: `/tmp/cards-busy.png` 里首采期间卡片右上角胶囊有转圈弧；
`/tmp/cards-idle.png` 里采集结束后恢复为 `●` 符号。

> 演示模式走 `MockSSHTransport`，采集瞬间完成，转圈可能一闪而过。
> 若两张截图都没拍到转圈，把 `MockSSHTransport.Behavior.streamChunkDelay`
> 临时调大不管用（那只影响流式输出）——改用 `xcrun simctl io ... recordVideo`
> 录 10 秒再逐帧看，或直接信任 Task 4 的单测覆盖。

- [ ] **Step 6: 核对文档与实现一致**

若实现过程中有任何偏离设计文档之处，在
`docs/superpowers/specs/2026-07-28-refresh-and-reconnect-state-design.md`
末尾追加「实现与本文的偏离」一节说明原因。

- [ ] **Step 7: 提交**

```bash
cd /Users/crazyball/Code/Swift/Conn
git add -A
git commit -m "chore: 采集状态可见化的 i18n 补全与验收"
```

---

## 附：任务顺序与验证门

| 任务 | 结束时的验证门 |
|---|---|
| 1 | `swift test --filter ConnectionManagerTests` |
| 2 | `swift test --filter MonitorSchedulerTests`（6 条）+ 全量包测试 |
| 3 | `swift test --filter MonitorSchedulerTests`（11 条）+ 全量包测试 |
| 4 | `swift test --filter StatusPillTests` + `swift build` |
| 5 | `swift build` + 全量包测试 |
| 6 | `xcodebuild build` + `-only-testing:ConnTests` |
| 7 | clean build + 全量测试 + 截图 |

Task 2 与 Task 3 都改 `MonitorScheduler`，**必须按顺序做** —— Task 3 的
`startDashboard` 依赖 Task 2 已把 `phases` 引入。
