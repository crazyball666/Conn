import ConnSSH
import Foundation
import Testing
@testable import ConnSSHCitadel

/// `withTimeout` 的单测。
///
/// 与本 target 里其它几组测试不同，**这组不需要真服务器**：超时竞速是纯并发逻辑，
/// 被刻意抽成了不碰 Citadel 的泛型 helper，正是为了能在没有 Docker/网络的环境下验证。
@Suite("withTimeout — exec 超时竞速")
struct ExecTimeoutTests {
    private let endpoint = SSHEndpoint(host: "10.0.0.1", port: 22)

    @Test("工作在超时前完成 → 原样返回结果")
    func returnsResultWhenFastEnough() async throws {
        let value = try await withTimeout(.seconds(5), timeoutError: .timeout(endpoint: endpoint)) {
            "done"
        }
        #expect(value == "done")
    }

    @Test("工作超时 → 抛 SSHError.timeout(endpoint:)，且带的是本会话的 endpoint")
    func throwsTimeoutWhenTooSlow() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await withTimeout(.milliseconds(50), timeoutError: .timeout(endpoint: endpoint)) {
                // 远超超时的工作，模拟对着死 socket 的读取
                try await Task.sleep(for: .seconds(30))
                return "never"
            }
            Issue.record("预期抛 SSHError.timeout，但正常返回了")
        } catch let error as SSHError {
            #expect(error == .timeout(endpoint: endpoint))
        }
        // 关键：控制权必须在超时点附近就交还，而不是等工作自己跑完 30s
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test("超时后那条还在跑的工作被取消，不会留在后台空转")
    func cancelsPendingWorkOnTimeout() async throws {
        let observer = CancellationObserver()
        await #expect(throws: SSHError.self) {
            _ = try await withTimeout(.milliseconds(50), timeoutError: .timeout(endpoint: endpoint)) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await observer.markCancelled(Task.isCancelled)
                    throw error
                }
                return "never"
            }
        }
        // withTimeout 用任务组竞速，返回前会等被取消的子任务真正结束，
        // 所以这里读到的标记已经是终态，不需要再 sleep 赌时序。
        #expect(await observer.wasCancelled)
    }

    @Test("工作自己抛错 → 原样传播，不被伪装成超时")
    func propagatesOperationError() async throws {
        do {
            _ = try await withTimeout(.seconds(5), timeoutError: .timeout(endpoint: endpoint)) {
                throw SSHError.channelClosed
            }
            Issue.record("预期抛 channelClosed，但正常返回了")
        } catch let error as SSHError {
            #expect(error == .channelClosed)
        }
    }

    @Test("工作先完成 → 不会被随后到点的计时器拖住（早于超时时长返回）")
    func doesNotWaitForTimerAfterSuccess() async throws {
        let started = ContinuousClock.now
        let value = try await withTimeout(.seconds(10), timeoutError: .timeout(endpoint: endpoint)) {
            42
        }
        #expect(value == 42)
        #expect(started.duration(to: .now) < .seconds(2))
    }
}

/// 记录被竞速淘汰的那个工作任务是否真的收到了取消。
private actor CancellationObserver {
    private(set) var wasCancelled = false

    func markCancelled(_ cancelled: Bool) {
        wasCancelled = cancelled
    }
}
