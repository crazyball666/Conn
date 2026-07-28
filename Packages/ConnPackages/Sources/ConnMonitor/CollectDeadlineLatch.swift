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
    /// deadline 赢下竞速时要 `cancel()` 一次的采集任务。**只 cancel，绝不 await**。
    var work: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    /// 采集自己跑完了：正常交还控制权。
    func workDidFinish() {
        resumeOnce()
    }

    /// deadline 先到：立刻交还控制权，并对采集任务尽力取消一次。
    ///
    /// **返回值是「本次调用赢下了竞速吗」，调用方必须用它**：计时器分支在这之后还要
    /// 驱逐该主机的会话（见 `MonitorScheduler.collectOne`），而计时器被 `cancel()` 掐掉时
    /// `Task.sleep` 抛出的错误被 `try?` 吞掉，代码照样往下走——没有这个返回值，
    /// 正常跑完的采集也会被顺手关掉连接。
    func abandonWork() -> Bool {
        guard resumeOnce() else { return false }
        work?.cancel()
        // 断开对孤儿的强引用：孤儿的闭包持有本对象，本对象再持有孤儿就成了环，
        // 得等它真跑完才解开。这里主动断掉，环立刻消失。
        work = nil
        return true
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
