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

@Suite("DockerService — Compose 第三期")
struct DockerComposeServiceTests {
    @Test("Compose 探测优先 v2 并在失败后回退 v1")
    func detectsComposeDialectWithFallback() async throws {
        let v1Session = RecordingSSHSession(execResults: [
            .init(exitCode: 1, stdout: Data(), stderr: Data("not a command".utf8)),
            .init(exitCode: 0, stdout: Data("docker-compose version 1.29.2".utf8), stderr: Data()),
        ])

        let dialect = try await DockerService.composeDialect(on: v1Session, sudo: true)

        #expect(dialect == .v1)
        #expect(v1Session.invocations == [
            .init(method: .exec, command: "sudo -n docker compose version", timeout: .seconds(30)),
            .init(method: .exec, command: "sudo -n docker-compose version", timeout: .seconds(30)),
        ])

        let unavailable = RecordingSSHSession(execResults: [
            .init(exitCode: 1, stdout: Data(), stderr: Data()),
            .init(exitCode: 127, stdout: Data(), stderr: Data()),
        ])
        #expect(try await DockerService.composeDialect(on: unavailable, sudo: false) == nil)
    }

    @Test("v2 项目列表与容器标签合并项目目录和运行摘要")
    func listsV2ProjectsAndMergesContainerMetadata() async throws {
        let listed = """
        [{"Name":"web","Status":"running(1)","ConfigFiles":"/listed/compose.yml"}]
        """
        let containers = """
        {"ID":"c1","Image":"api:1","Names":"web-api-1","State":"running","Status":"Up","Ports":"8080/tcp","Labels":"com.docker.compose.project=web,com.docker.compose.project.config_files=/srv/web/compose.yml,com.docker.compose.project.working_dir=/srv/custom,com.docker.compose.service=api"}
        """
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data(listed.utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data(containers.utf8), stderr: Data()),
        ])

        let projects = try await DockerService.listComposeProjects(
            dialect: .v2, on: session, sudo: true
        )

        #expect(projects.count == 1)
        #expect(projects[0].name == "web")
        #expect(projects[0].projectDirectory == "/srv/custom")
        #expect(projects[0].configFiles == ["/srv/web/compose.yml"])
        #expect(projects[0].containerCount == 1)
        #expect(projects[0].runningContainerCount == 1)
        #expect(session.invocations.map(\.command) == [
            "sudo -n docker compose ls --all --format json",
            "sudo -n docker ps -a --filter 'label=com.docker.compose.project' --format '{{json .}}'",
        ])
    }

    @Test("项目服务合并 config 声明与现有容器")
    func listsDeclaredAndExistingServices() async throws {
        let project = DockerComposeProject(
            name: "web", state: .running,
            configFiles: ["/srv/web/compose.yml"], projectDirectory: "/srv/web",
            source: .automatic
        )
        let containers = """
        {"ID":"c1","Image":"api:1","Names":"web-api-1","State":"running","Status":"Up","Ports":"8080/tcp","Labels":"com.docker.compose.project=web,com.docker.compose.service=api"}
        """
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data("api\nworker\n".utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data(containers.utf8), stderr: Data()),
        ])

        let services = try await DockerService.composeServices(
            project, dialect: .v2, on: session, sudo: false
        )

        #expect(services.map(\.name) == ["api", "worker"])
        #expect(services.first(where: { $0.name == "worker" })?.state == .stopped)
        #expect(session.invocations.map(\.command) == [
            "docker compose -f '/srv/web/compose.yml' --project-directory '/srv/web' -p 'web' config --services",
            "docker ps -a --filter 'label=com.docker.compose.project=web' --format '{{json .}}'",
        ])
    }

    @Test("项目容器查询非零退出不能伪装成全部服务已停止")
    func serviceContainerDiscoveryRejectsNonzeroResult() async {
        let project = DockerComposeProject(
            name: "web", state: .running,
            configFiles: ["/srv/web/compose.yml"], projectDirectory: "/srv/web",
            source: .automatic
        )
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data("api\nworker\n".utf8), stderr: Data()),
            .init(exitCode: 17, stdout: Data(), stderr: Data("daemon unavailable".utf8)),
        ])

        await #expect(throws: DockerComposeError.self) {
            _ = try await DockerService.composeServices(
                project, dialect: .v2, on: session, sudo: false
            )
        }
    }

    @Test("Compose 项目发现非零退出不能伪装成空列表")
    func projectDiscoveryRejectsNonzeroResult() async {
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 17, stdout: Data(), stderr: Data("daemon unavailable".utf8)),
        ])

        await #expect(throws: DockerComposeError.self) {
            _ = try await DockerService.listComposeProjects(
                dialect: .v2, on: session, sudo: false
            )
        }
    }

    @Test("Compose 写操作沿用两分钟超时且保留明确非零结果")
    func composeWritesUseSharedWriteTimeout() async throws {
        let project = DockerComposeProject(
            name: "web", state: .running,
            configFiles: ["/srv/web/compose.yml"], projectDirectory: "/srv/web",
            source: .automatic
        )
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data(), stderr: Data()),
            .init(exitCode: 7, stdout: Data(), stderr: Data("failed".utf8)),
            .init(exitCode: 0, stdout: Data(), stderr: Data()),
        ])

        _ = try await DockerService.composeUp(project, dialect: .v2, on: session, sudo: true)
        let down = try await DockerService.composeDown(project, dialect: .v2, on: session, sudo: true)
        _ = try await DockerService.composeRestart(
            project, service: "api", dialect: .v2, on: session, sudo: true
        )

        #expect(down.exitCode == 7)
        #expect(session.invocations == [
            .init(
                method: .exec,
                command: "sudo -n docker compose -f '/srv/web/compose.yml' --project-directory '/srv/web' -p 'web' up -d",
                timeout: .seconds(120)
            ),
            .init(
                method: .exec,
                command: "sudo -n docker compose -f '/srv/web/compose.yml' --project-directory '/srv/web' -p 'web' down",
                timeout: .seconds(120)
            ),
            .init(
                method: .exec,
                command: "sudo -n docker compose -f '/srv/web/compose.yml' --project-directory '/srv/web' -p 'web' restart 'api'",
                timeout: .seconds(120)
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
