import Citadel
import ConnSSH
import Foundation
import NIOCore

/// Citadel `SSHClient` 的会话包装，实现 `ConnSSH.SSHSession`。
final class CitadelSession: SSHSession, @unchecked Sendable {
    private let client: SSHClient
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>

    init(client: SSHClient) {
        self.client = client
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        _ = timeout
        // 关键：Citadel 在命令退出码非零时**抛** `SSHClient.CommandFailed`，
        // 而运维场景里非零退出极常见（grep 无匹配、test 判假、服务未运行…）。
        // 必须捕获它转成正常的 ExecResult，否则这些命令会被误当作错误。
        var stdout = Data()
        var stderr = Data()
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case let .stdout(buffer):
                    stdout.append(contentsOf: buffer.readableBytesView)
                case let .stderr(buffer):
                    stderr.append(contentsOf: buffer.readableBytesView)
                }
            }
            return ExecResult(exitCode: 0, stdout: stdout, stderr: stderr)
        } catch let failure as SSHClient.CommandFailed {
            return ExecResult(exitCode: Int32(failure.exitCode), stdout: stdout, stderr: stderr)
        }
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        let citadelStream = try await client.executeCommandStream(command)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in citadelStream {
                        switch chunk {
                        case let .stdout(buffer):
                            continuation.yield(Data(buffer.readableBytesView))
                        case let .stderr(buffer):
                            continuation.yield(Data(buffer.readableBytesView))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        // Phase 4 深用；这里返回占位以满足协议。真实实现见 CitadelShellChannel。
        throw SSHError.channelClosed
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        // Phase 6/端口转发深用。
        throw SSHError.channelClosed
    }

    func close() async {
        try? await client.close()
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }
}
