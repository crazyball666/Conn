import ConnSSH
import Foundation
import Testing
@testable import ConnOps

@Suite("DockerService — 第二期写操作")
struct DockerOperationServiceTests {
    @Test("拉取镜像走命令流并保留非零结果")
    func pullImageStreamsWithFiveMinuteTimeout() async throws {
        let expected = ExecResult(
            exitCode: 17,
            stdout: Data("layer 1\\nlayer 2\\n".utf8),
            stderr: Data("pull failed".utf8)
        )
        let session = RecordingSSHSession(stream: .init(
            chunks: [Data("layer 1\\n".utf8), Data("layer 2\\n".utf8)], result: expected
        ))

        let stream = try await DockerService.pullImage(reference: "nginx:1.27", on: session, sudo: true)
        var output = Data()
        for try await chunk in stream.output {
            output.append(chunk)
        }

        #expect(String(decoding: output, as: UTF8.self) == "layer 1\\nlayer 2\\n")
        #expect(try await stream.result() == expected)
        #expect(session.invocations == [
            .init(
                method: .execCommandStream,
                command: "sudo -n docker pull 'nginx:1.27'",
                timeout: .seconds(300)
            ),
        ])
    }

    @Test("运行容器走 exec 的两分钟写操作超时并保留非零结果")
    func runContainerUsesWriteTimeout() async throws {
        let expected = ExecResult(exitCode: 125, stdout: Data(), stderr: Data("bad run".utf8))
        let session = RecordingSSHSession(execResults: [expected])
        let draft = DockerRunDraft(image: "nginx:1.27", name: "web app", detached: true)

        let result = try await DockerService.runContainer(draft, on: session, sudo: true)

        #expect(result == expected)
        #expect(session.invocations == [
            .init(
                method: .exec,
                command: "sudo -n docker run --name 'web app' --detach 'nginx:1.27'",
                timeout: .seconds(120)
            ),
        ])
    }

    @Test("创建和删除卷走 exec 的两分钟写操作超时")
    func volumeWritesUseWriteTimeout() async throws {
        let created = ExecResult(exitCode: 18, stdout: Data("app data\\n".utf8), stderr: Data())
        let removed = ExecResult(exitCode: 19, stdout: Data(), stderr: Data("in use".utf8))
        let session = RecordingSSHSession(execResults: [created, removed])

        let createResult = try await DockerService.createVolume(
            DockerVolumeDraft(name: "app data"), on: session, sudo: false
        )
        let removeResult = try await DockerService.removeVolume(name: "app data", on: session, sudo: true)

        #expect(createResult == created)
        #expect(removeResult == removed)
        #expect(session.invocations == [
            .init(method: .exec, command: "docker volume create --driver 'local' 'app data'", timeout: .seconds(120)),
            .init(method: .exec, command: "sudo -n docker volume rm 'app data'", timeout: .seconds(120)),
        ])
    }

    @Test("创建和删除网络走 exec 的两分钟写操作超时")
    func networkWritesUseWriteTimeout() async throws {
        let created = ExecResult(exitCode: 20, stdout: Data("app net\\n".utf8), stderr: Data())
        let removed = ExecResult(exitCode: 21, stdout: Data(), stderr: Data("in use".utf8))
        let session = RecordingSSHSession(execResults: [created, removed])

        let createResult = try await DockerService.createNetwork(
            DockerNetworkDraft(name: "app net", isInternal: true), on: session, sudo: true
        )
        let removeResult = try await DockerService.removeNetwork(name: "app net", on: session, sudo: false)

        #expect(createResult == created)
        #expect(removeResult == removed)
        #expect(session.invocations == [
            .init(
                method: .exec,
                command: "sudo -n docker network create --driver 'bridge' --internal 'app net'",
                timeout: .seconds(120)
            ),
            .init(method: .exec, command: "docker network rm 'app net'", timeout: .seconds(120)),
        ])
    }

    @Test("系统清理走 exec 的五分钟超时并保留非零结果")
    func systemPruneUsesPruneTimeout() async throws {
        let expected = ExecResult(exitCode: 22, stdout: Data(), stderr: Data("daemon unavailable".utf8))
        let session = RecordingSSHSession(execResults: [expected])

        let result = try await DockerService.systemPrune(
            .init(allUnusedImages: true, includeVolumes: true), on: session, sudo: true
        )

        #expect(result == expected)
        #expect(session.invocations == [
            .init(
                method: .exec,
                command: "sudo -n docker system prune -f -a --volumes",
                timeout: .seconds(300)
            ),
        ])
    }
}

private struct SSHInvocation: Equatable {
    enum Method: Equatable {
        case exec
        case execCommandStream
    }

    let method: Method
    let command: String
    let timeout: Duration
}

/// 只记录本服务会用到的两种执行入口；其余 SSH 能力对这些单元测试无关。
private final class RecordingSSHSession: SSHSession, @unchecked Sendable {
    struct StreamResponse: Sendable {
        let chunks: [Data]
        let result: ExecResult
    }

    private let lock = NSLock()
    private var remainingExecResults: [ExecResult]
    private let stream: StreamResponse
    private var recordedInvocations: [SSHInvocation] = []
    private let stateContinuation: AsyncStream<SSHSessionState>.Continuation
    let state: AsyncStream<SSHSessionState>
    let isConnected = true

    init(
        execResults: [ExecResult] = [],
        stream: StreamResponse = .init(chunks: [], result: .init(exitCode: 0, stdout: Data(), stderr: Data()))
    ) {
        remainingExecResults = execResults
        self.stream = stream
        (state, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected)
    }

    var invocations: [SSHInvocation] {
        lock.withLock { recordedInvocations }
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        lock.withLock {
            recordedInvocations.append(.init(method: .exec, command: command, timeout: timeout))
            return remainingExecResults.isEmpty
                ? ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
                : remainingExecResults.removeFirst()
        }
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw SSHError.channelClosed
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        let response = lock.withLock { () -> StreamResponse in
            recordedInvocations.append(.init(method: .execCommandStream, command: command, timeout: timeout))
            return stream
        }
        return SSHCommandStream(output: AsyncThrowingStream { continuation in
            for chunk in response.chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }) {
            response.result
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel {
        throw SSHError.channelClosed
    }

    func sftp() async throws -> any RemoteFileSystem {
        throw SSHError.channelClosed
    }

    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel {
        throw SSHError.channelClosed
    }

    func close() async {
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }
}
