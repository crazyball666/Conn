import Foundation

/// 「采集跑完」与「deadline 到点」之间的一次性闸：谁先到谁把续体兑现，另一方成为 no-op。
///
/// **`MonitorScheduler.collectOne` 的实现细节，别在别处用**。单独成文件只为把
/// `MonitorScheduler.swift` 的行数压回 SwiftLint 的 `file_length` 之下（与
/// `MonitorSchedulerTestSupport.swift` 同一个理由），它本身是自洽的一小段。
///
/// **为什么不用 `withTaskGroup` 竞速**：任务组在闭包返回前必须等所有子任务真正结束，
/// 而采集那一段恰恰不响应取消——那正是这套机制要修的缺陷本身，用它来修等于原地打转。
/// 用一次性续体，「到点返回」不依赖任何一方是否可取消：计时器一到就 `resume`，
/// `collectOne` 立刻从 await 里醒来，没跑完的那个 Task 被留在原地当孤儿。
@MainActor
final class CollectDeadlineLatch {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    /// 采集自己跑完了：正常交还控制权。
    func workDidFinish() {
        resumeOnce()
    }

    /// deadline 先到：立刻交还控制权，把还没跑完的那一轮丢成孤儿。
    ///
    /// **本对象刻意不持有那个采集 Task，因为它一个字也不该对它做**——尤其不许
    /// `cancel()`。整套方案的前提就是「这个任务杀不掉」：它挂在 Citadel 的 exec 请求
    /// 上（NIO 的 `EventLoopFuture`，不响应 Swift 并发取消），`cancel()` 对它毫无作用；
    /// 真正了结它的是 `MonitorScheduler.evictHungSession` 关掉那条连接。
    ///
    /// 而 `cancel()` 唯一确定的效果是**污染孤儿后续的结构化并发，把垃圾写进 UI**——
    /// 代次此刻通常仍然有效（超时与 `stop()` 无关），孤儿的写回会真的落地：
    /// - `ExecTimeout.withTimeout` 里的 `Task.sleep` 子任务会立刻抛 `CancellationError`，
    ///   于是重试那次 attempt 极可能以 `CancellationError` 收场 → `record()` →
    ///   `errors[host.id] = error.friendlyDiagnosis`。`CancellationError` 不是 `SSHError`，
    ///   `friendlyDiagnosis` 只能退到 `localizedDescription`，卡片上会冒出裸英文
    ///   `The operation couldn't be completed. (Swift.CancellationError error 1.)`。
    /// - 更难看的变体：`CitadelSession.runExec` 的 `for try await chunk in stream` 在取消下
    ///   是「流终止、`next()` 返回 nil」而非抛错，若它先出结果，会返回
    ///   `ExecResult(exitCode: 0, stdout: 空)` → 解析成全 nil 的 `HostMetrics` →
    ///   `errors` 被清空、卡片显示「健康但全是横杠」。
    ///
    /// 收益是假的（杀不掉），代价是真的（写垃圾）。所以：不取消，只放手。孤儿最终会
    /// 因为连接被关而拿到真实的 `SSHError`，`record` 写进去的是有意义的中文诊断。
    ///
    /// **返回值是「本次调用赢下了竞速吗」，调用方必须用它**：计时器分支在这之后还要
    /// 驱逐该主机的会话（见 `MonitorScheduler.collectOne`），而计时器被 `cancel()` 掐掉时
    /// `Task.sleep` 抛出的错误被 `try?` 吞掉，代码照样往下走——没有这个返回值，
    /// 正常跑完的采集也会被顺手关掉连接。
    func abandonWork() -> Bool {
        resumeOnce()
    }

    /// 只兑现一次续体（重复兑现会崩）。返回 true 表示本次调用是竞速的赢家。
    @discardableResult
    private func resumeOnce() -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume()
        return true
    }
}
