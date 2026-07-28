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
