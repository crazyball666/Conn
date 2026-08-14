import Citadel
import ConnSSH
import Foundation
import NIOCore

/// Citadel `SSHClient` 的会话包装，实现 `ConnSSH.SSHSession`。
final class CitadelSession: SSHSession, @unchecked Sendable {
    private let client: SSHClient
    /// 只为 `SSHError.commandTimeout` 的诊断文案而持有——超时报错要说清是哪台主机。
    private let endpoint: SSHEndpoint
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>

    /// 底层 NIO 通道是否仍 active。Citadel 直接暴露了这个标志位，同步且无网络往返。
    var isConnected: Bool { client.isConnected }

    init(client: SSHClient, endpoint: SSHEndpoint) {
        self.client = client
        self.endpoint = endpoint
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

    /// 执行一条命令并等待完整结果，超过 `timeout` 抛 `SSHError.commandTimeout`。
    ///
    /// - Important: **超时不会终止远端命令。** Citadel 的 `_executeCommandStream`
    ///   没有给它返回的 `AsyncThrowingStream` 设 `onTermination`，所以取消只终止
    ///   本地这一侧的迭代——SSH channel 不发 signal、不关闭，远端进程照跑不误
    ///   （`apt upgrade`、`docker compose pull` 会一直跑到自己结束）。
    ///   调用方必须知道这条语义：用户看到「超时失败」时，服务器上那条命令很可能
    ///   仍在执行，重试同一条命令可能撞上还没跑完的上一次。`.commandTimeout`
    ///   的诊断文案已把这件事写给用户；这里再写给调用方一次。
    ///   要真正掐断远端进程，只能另开一条会话去 kill，本层不做。
    ///
    /// - Important: 超时下限受 Citadel 的 15 秒 `createChannel` 兜底约束，
    ///   **不得传低于 15 秒的值**，理由见 `execRacingTimeout` / `withTimeout` 的说明。
    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        // 约束：这里必须把**入参** timeout 原样交给 execRacingTimeout。
        // 曾经这行是 `_ = timeout` + 写死 30 秒，导致所有调用点的显式超时形同虚设；
        // 这类改动不会让任何测试变红，只会静默复发那个 bug。接线本身的测试见
        // ExecTimeoutTests（它测 execRacingTimeout，覆盖不到这一行的参数传递）。
        //
        // 捕获 self（本类是 @unchecked Sendable）而不是裸捕获 Citadel 的
        // SSHClient——后者未声明 Sendable，直接进 @Sendable 闭包会告警。
        try await execRacingTimeout(
            command: command,
            timeout: timeout,
            endpoint: endpoint
        ) { [self] command in
            try await runExec(command)
        }
    }

    /// exec 的实际执行体（不含超时）。
    private func runExec(_ command: String) async throws -> ExecResult {
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

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        let (output, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let cancellation = SSHCommandStreamCancellation()
        let resultTask = Task { [cancellation, self] in
            defer { cancellation.finish() }
            do {
                let result = try await execRacingTimeout(
                    command: command,
                    timeout: timeout,
                    endpoint: endpoint
                ) { [self] command in
                    try await runCommandStream(command, continuation: continuation)
                }
                continuation.finish()
                return result
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        cancellation.install(resultTask)
        continuation.onTermination = { [cancellation] _ in
            cancellation.cancel()
        }
        return SSHCommandStream(output: output) {
            try await resultTask.value
        }
    }

    /// 只消费一次 Citadel 命令流，同时把每块输出送给 UI 并累计为最终结果。
    private func runCommandStream(
        _ command: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws -> ExecResult {
        var stdout = Data()
        var stderr = Data()
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                let data: Data
                switch chunk {
                case let .stdout(buffer):
                    data = Data(buffer.readableBytesView)
                    stdout.append(data)
                case let .stderr(buffer):
                    data = Data(buffer.readableBytesView)
                    stderr.append(data)
                }
                continuation.yield(data)
            }
            return ExecResult(exitCode: 0, stdout: stdout, stderr: stderr)
        } catch let failure as SSHClient.CommandFailed {
            return ExecResult(exitCode: Int32(failure.exitCode), stdout: stdout, stderr: stderr)
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        try await CitadelShellChannel.open(client: client, term: term)
    }

    func openProcess(_ request: RemoteProcessRequest) async throws -> any RemoteProcessChannel {
        try await CitadelRemoteProcessChannel.open(client: client, request: request)
    }

    func sftp() async throws -> any RemoteFileSystem {
        let sftpClient = try await client.openSFTP()
        return CitadelFileSystem(client: sftpClient)
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
