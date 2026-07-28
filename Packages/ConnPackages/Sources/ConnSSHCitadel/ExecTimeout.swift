import ConnSSH
import Foundation

/// 让一段异步工作与计时器竞速：谁先出结果谁说了算，计时器赢就抛 `timeoutError`。
///
/// **为什么 exec 必须有超时**：对着一条已死的 socket（App 后台期间被服务器 idle
/// timeout 或系统回收），底层读取到底多久才抛错完全取决于 TCP 自身的重传超时，
/// 可能几十秒甚至更久。而采集调度「有读数的主机首次传输失败就在同轮内立刻重新握手
/// 再试一次」的前提，是**第一次尝试会及时失败**——否则用户看到的不是快速闪过
/// 「重连中」，而是卡片长时间转圈。更硬的一条：调度用 `inFlight` 集合挡同代并发，
/// 它依赖每次 `exec` 的 await 终会返回；一次永不返回的 exec 会让那台主机永久停摆。
///
/// **为什么用任务组竞速，而不是「到点就走、把工作任务扔在后台」**：任务组在退出前
/// 会等待（已被取消的）子任务真正结束，这正是这里想要的语义——超时不只是换回控制权，
/// 还要确保那条流式读取真的停了，不能让它在后台继续占着 SSH 通道往 buffer 里写。
/// Citadel 的 `executeCommandStream` 返回 `AsyncThrowingStream`，其迭代是协作式
/// 可取消的，`cancelAll()` 会让 `for try await` 循环立即结束。
///
/// - Important: **这是软超时——本函数只保证错误类型，不保证 deadline。**
///   上一条「任务组退出前等子任务结束」的代价就在这里：工作体若不响应 Swift 并发的
///   协作式取消，`withThrowingTaskGroup` 必须一直等它自己跑完才能返回。评审实测：
///   200ms 超时、工作体是一段不可取消的阻塞，实际耗时 4.26 秒——抛出的确实是
///   `timeoutError`，但控制权并没有在超时点交还。**因此调用方必须保证工作体的每一段
///   都能响应取消，否则这层超时只是「事后正名」。**
///
///   当前 `CitadelSession.runExec` 的三段各自的实际情况：
///   1. `createChannel`（建通道）走 NIO 的 `EventLoopFuture.get()`，**不响应取消**。
///      唯一兜底是 Citadel 自己在这里挂的 15 秒定时器
///      （`.build/checkouts/Citadel/Sources/Citadel/TTY/Client/TTY.swift:314`，
///      `eventLoop.scheduleTask(in: .seconds(15)) { createChannel.fail(...) }`）。
///      **推论：exec 的超时不得低于 15 秒**——低于它，我们的计时器先到点，却仍要
///      干等这 15 秒兜底把 future 失败掉，那层兜底就等于失效，超时值形同虚设。
///   2. `triggerUserOutboundEvent(ExecRequest, wantReply: true)`（发 exec 请求等回执）
///      **没有任何兜底**：既不响应取消，Citadel 也没给它挂定时器。半开 TCP
///      （iOS 切换 Wi-Fi/蜂窝、NAT 丢表）会让这一步一直等到 TCP RTO 才失败，
///      量级是分钟。**这是当前剩余的 hang 窗口**，本函数挡不住，只能靠上层的
///      「回前台 invalidateAll + 重新握手」把这条会话整体丢弃来规避。
///   3. `for try await chunk in stream`（读输出）是协作式可取消的，
///      `cancelAll()` 能让它立即结束——只有这一段真正做到了「按时返回」。
func withTimeout<T: Sendable>(
    _ duration: Duration,
    timeoutError: SSHError,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw timeoutError
        }
        // 胜负一分就取消另一方：工作赢 → 停掉计时器；计时器赢 → 停掉流式读取。
        defer { group.cancelAll() }
        for try await first in group {
            return first
        }
        // 不可达：组里恒有两个任务，迭代必先产出一个结果或抛错。
        throw timeoutError
    }
}

/// exec 的超时接线：把**调用方传入的** `timeout` 原样用于竞速，超时抛
/// `SSHError.commandTimeout`（而不是连接超时 `.timeout`——命令跑太久跟网络无关）。
///
/// **为什么要从 `CitadelSession.exec` 里抽出来**：`CitadelSession` 持有真实的
/// Citadel `SSHClient`，没有服务器就无法构造，于是「传入的 timeout 是否真的被用上」
/// 这条接线曾经零测试覆盖——评审做变异（把 `timeout` 丢掉、写死 30 秒）时全部测试
/// 仍然全绿，也就是说 `_ = timeout` 那个 bug 可以原样复发。把执行体做成注入参数
/// (`run`) 之后，这条接线可以脱离 Citadel 单测，见 `ExecTimeoutTests`。
///
/// - Parameters:
///   - command: 要执行的命令，原样交给 `run`。
///   - timeout: 本次执行的上限。**必须是调用方传进来的那个值**，写死任何常量都是 bug。
///   - endpoint: 只用于超时错误的诊断文案（说清是哪台主机）。
///   - run: 实际执行体（真实实现是 Citadel 的流式 exec；测试注入替身）。
func execRacingTimeout(
    command: String,
    timeout: Duration,
    endpoint: SSHEndpoint,
    run: @escaping @Sendable (String) async throws -> ExecResult
) async throws -> ExecResult {
    let error = SSHError.commandTimeout(endpoint: endpoint, seconds: timeout.roundedUpSeconds)
    return try await withTimeout(timeout, timeoutError: error) {
        try await run(command)
    }
}

extension Duration {
    /// 向上取整到秒，最小 1——只用于超时文案（「执行超过 N 秒」写 0 秒没有意义）。
    var roundedUpSeconds: Int {
        let components = self.components
        let seconds = Int(components.seconds)
        return components.attoseconds > 0 ? max(1, seconds + 1) : max(1, seconds)
    }
}
