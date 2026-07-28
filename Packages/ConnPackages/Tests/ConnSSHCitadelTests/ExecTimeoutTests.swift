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

/// `execRacingTimeout` 的单测——**钉住「调用方传入的 timeout 真的被用于竞速」这条接线**。
///
/// 为什么单独钉它：本分支修的 bug 就是 `CitadelSession.exec` 里的 `_ = timeout`
/// （入参被丢掉、竞速写死 30 秒）。评审做过变异实验，把那行改回去，**全部测试仍然全绿**——
/// 也就是说这个 bug 可以原样复发。`CitadelSession` 持有真实的 Citadel `SSHClient`，
/// 没有服务器就无法构造，所以接线被抽成了 `execRacingTimeout(command:timeout:endpoint:run:)`，
/// 执行体做成注入参数，让这组断言能在没有网络的环境里跑。
@Suite("execRacingTimeout — exec 的超时接线")
struct ExecRacingTimeoutTests {
    private let endpoint = SSHEndpoint(host: "10.0.0.1", port: 22)

    @Test("超时用的是调用方传入的值：1 秒就在 1 秒左右失败，错误里带的也是 1 秒")
    func racesWithCallerSuppliedTimeout() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await execRacingTimeout(
                command: "sleep 20",
                timeout: .seconds(1),
                endpoint: endpoint
            ) { _ in
                // 远超传入超时的执行体：只要接线正确，它永远等不到自己跑完
                try await Task.sleep(for: .seconds(20))
                return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            Issue.record("预期抛 commandTimeout，但正常返回了——说明传入的 timeout 没被用上")
        } catch let error as SSHError {
            // 秒数取自入参：接线一旦写死常量（如曾经的 30 秒），这条断言立刻变红
            #expect(error == .commandTimeout(endpoint: endpoint, seconds: 1))
        }
        // 时间上也钉一道：写死 30 秒的话，这里会等到执行体自己跑完的 20 秒
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test("命令在超时前完成 → 原样返回结果，命令文本也原样交给执行体")
    func returnsResultWhenCommandFinishesInTime() async throws {
        let result = try await execRacingTimeout(
            command: "echo hi",
            timeout: .seconds(30),
            endpoint: endpoint
        ) { command in
            #expect(command == "echo hi")
            return ExecResult(exitCode: 7, stdout: Data("hi".utf8), stderr: Data())
        }
        #expect(result.stdoutText == "hi")
        // 非零退出码不是错误（grep 无匹配等），必须原样透出
        #expect(result.exitCode == 7)
    }

    @Test("抛的是 commandTimeout 而非连接超时——诊断不能把用户引去查防火墙")
    func throwsCommandTimeoutNotConnectionTimeout() async throws {
        do {
            _ = try await execRacingTimeout(
                command: "sleep 20",
                timeout: .milliseconds(200),
                endpoint: endpoint
            ) { _ in
                try await Task.sleep(for: .seconds(20))
                return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            Issue.record("预期抛 commandTimeout，但正常返回了")
        } catch let error as SSHError {
            #expect(error != .timeout(endpoint: endpoint))
            // 亚秒超时向上取整成 1 秒：文案里写「执行超过 0 秒」没有意义
            #expect(error == .commandTimeout(endpoint: endpoint, seconds: 1))
        }
    }

    @Test("执行体自己抛错 → 原样传播，不被伪装成命令超时")
    func propagatesRunError() async throws {
        do {
            _ = try await execRacingTimeout(
                command: "whatever",
                timeout: .seconds(30),
                endpoint: endpoint
            ) { _ in
                throw SSHError.channelClosed
            }
            Issue.record("预期抛 channelClosed，但正常返回了")
        } catch let error as SSHError {
            #expect(error == .channelClosed)
        }
    }
}

/// 记录被竞速淘汰的那个工作任务是否真的收到了取消。
private actor CancellationObserver {
    private(set) var wasCancelled = false

    func markCancelled(_ cancelled: Bool) {
        wasCancelled = cancelled
    }
}
