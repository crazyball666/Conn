import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnOps

@Suite("DockerService — 跨平台运行时探测")
struct DockerRuntimeProbeTests {
    private let linux = RemotePlatformProfile(kind: .linux)
    private let macOS = RemotePlatformProfile(kind: .macOS)

    @Test("Docker 探测公开入口必须要求平台上下文")
    func publicProbeAPIRequiresPlatformContext() throws {
        let source = try String(
            contentsOf: packageRoot.appending(path: "Sources/ConnOps/DockerService.swift"),
            encoding: .utf8
        )
        let platformBlindProbe = #"public\s+static\s+func\s+probe\s*\(\s*on\s+session:\s*any\s+SSHSession\s*\)"#

        #expect(
            source.range(of: platformBlindProbe, options: .regularExpression) == nil,
            "Docker probing must go through a platform profile/provider"
        )
    }

    @Test("默认注册表为 Linux 与 Darwin 选择不同 provider")
    func defaultRegistrySelectsPlatformProviders() throws {
        let registry = DockerEnvironmentProviderRegistry.default

        #expect(registry.provider(for: .linux, scriptFamily: .posix) is LinuxDockerEnvironmentProvider)
        #expect(registry.provider(for: .macOS, scriptFamily: .posix) is DarwinDockerEnvironmentProvider)
        #expect(registry.provider(for: .windows, scriptFamily: .posix) == nil)
        #expect(registry.provider(for: .unknown, scriptFamily: .posix) == nil)
        #expect(registry.provider(for: .linux, scriptFamily: .powershell) == nil)
    }

    @Test("Linux 通过登录 Shell 环境发现 Docker 且不猜测安装目录")
    func linuxDiscoveryUsesLoginShellEnvironment() async throws {
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data(), stderr: Data()),
        ])

        let result = try await LinuxDockerEnvironmentProvider().probe(on: session)

        #expect(result == DockerProbeResult(availability: .notInstalled, runtime: nil))
        let command = try #require(session.invocations.first?.command)
        #expect(session.invocations.count == 1)
        #expect(command.contains("conn_login_shell=${SHELL:-}"))
        #expect(command.contains("-i -l -c"))
        #expect(!command.contains("/usr/bin/docker"))
        #expect(!command.contains("/usr/local/bin/docker"))
        #expect(!command.contains("/Applications/Docker.app"))
    }

    @Test("Darwin 通过登录 Shell 环境发现 Docker 且不猜测包管理器路径")
    func darwinDiscoveryUsesLoginShellEnvironment() async throws {
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data(), stderr: Data()),
        ])

        let result = try await DarwinDockerEnvironmentProvider().probe(on: session)

        #expect(result == DockerProbeResult(availability: .notInstalled, runtime: nil))
        let command = try #require(session.invocations.first?.command)
        #expect(session.invocations.count == 1)
        #expect(command.contains("conn_login_shell=${SHELL:-}"))
        #expect(command.contains("-i -l -c"))
        #expect(!command.contains("/usr/local/bin/docker"))
        #expect(!command.contains("/opt/homebrew/bin/docker"))
        #expect(!command.contains("/Applications/Docker.app/Contents/Resources/bin/docker"))
    }

    @Test("直接探测成功保留路径与 Compose，并只执行发现和一次可用性探测")
    func directSuccessPreservesRuntimeAndUsesTwoCommands() async throws {
        let executable = "/Applications/Docker.app/Contents/Resources/bin/docker"
        let compose = "/usr/local/bin/docker-compose"
        let session = RecordingSSHSession(execResults: [
            .init(
                exitCode: 0,
                stdout: Data("\(executable)\n__CONN_COMPOSE_V1__\(compose)\n".utf8),
                stderr: Data()
            ),
            .init(exitCode: 0, stdout: Data("__EXIT__0\n".utf8), stderr: Data()),
        ])

        let result = try await DockerService.probe(on: session, profile: macOS)

        #expect(result == DockerProbeResult(
            availability: .available(sudo: false),
            runtime: DockerRuntimeContext(
                executable: executable,
                sudo: false,
                composeV1Executable: compose
            )
        ))
        #expect(session.invocations.count == 2)
        #expect(session.invocations[0].command.contains("__CONN_EXECUTABLES_v1_BEGIN_"))
        #expect(!session.invocations[0].command.contains("/Applications/Docker.app"))
        #expect(session.invocations[1].command == "'\(executable)' ps -q 2>&1; echo __EXIT__$?")
    }

    @Test("直连失败后 sudo 成功只增加一次可用性探测")
    func sudoSuccessPreservesRuntimeAndUsesThreeCommands() async throws {
        let executable = "/usr/bin/docker"
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data("\(executable)\n".utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data("permission denied\n__EXIT__1\n".utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data("__EXIT__0\n".utf8), stderr: Data()),
        ])

        let result = try await DockerService.probe(on: session, profile: linux)

        #expect(result == DockerProbeResult(
            availability: .available(sudo: true),
            runtime: DockerRuntimeContext(executable: executable, sudo: true)
        ))
        #expect(session.invocations.count == 3)
        #expect(session.invocations[1].command == "'\(executable)' ps -q 2>&1; echo __EXIT__$?")
        #expect(session.invocations[2].command == "sudo -n '\(executable)' ps -q 2>&1; echo __EXIT__$?")
    }

    @Test("Docker Desktop 未启动与权限不足分别分类")
    func classifiesDaemonAndPermissionFailures() async throws {
        let executable = "/usr/local/bin/docker"
        let daemonSession = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data("\(executable)\n".utf8), stderr: Data()),
            .init(
                exitCode: 0,
                stdout: Data("Cannot connect to the Docker daemon. Is Docker Desktop running?\n__EXIT__1\n".utf8),
                stderr: Data()
            ),
            .init(
                exitCode: 0,
                stdout: Data("Cannot connect to the Docker daemon. Is Docker Desktop running?\n__EXIT__1\n".utf8),
                stderr: Data()
            ),
        ])
        let permissionSession = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data("\(executable)\n".utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data("permission denied\n__EXIT__1\n".utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data("sudo: a password is required\n__EXIT__1\n".utf8), stderr: Data()),
        ])

        let daemon = try await DockerService.probe(on: daemonSession, profile: macOS)
        let permission = try await DockerService.probe(on: permissionSession, profile: macOS)

        #expect(daemon == DockerProbeResult(availability: .daemonNotRunning, runtime: nil))
        #expect(permission == DockerProbeResult(availability: .permissionDenied, runtime: nil))
        #expect(daemonSession.invocations.count == 3)
        #expect(permissionSession.invocations.count == 3)
    }

    @Test("找不到 Docker CLI 时不执行可用性命令")
    func reportsMissingCLI() async throws {
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data(), stderr: Data()),
        ])

        let result = try await DockerService.probe(on: session, profile: macOS)

        #expect(result == DockerProbeResult(availability: .notInstalled, runtime: nil))
        #expect(session.invocations.count == 1)
        #expect(session.invocations[0].command.contains("__CONN_EXECUTABLES_v1_BEGIN_"))
    }

    @Test("Unknown 与 Windows 不执行 POSIX Docker 探测")
    func unsupportedPlatformsDoNotRunPOSIXDiscovery() async throws {
        for platform in [RemotePlatformKind.unknown, .windows] {
            let session = RecordingSSHSession()

            let result = try await DockerService.probe(
                on: session,
                profile: RemotePlatformProfile(kind: platform)
            )

            #expect(result == DockerProbeResult(availability: .unsupportedPlatform, runtime: nil))
            #expect(session.invocations.isEmpty)
        }
    }

    @Test("DockerService 通过注入注册表委派 provider")
    func serviceDelegatesToInjectedRegistry() async throws {
        let expected = DockerProbeResult(
            availability: .available(sudo: false),
            runtime: DockerRuntimeContext(executable: "injected-docker", sudo: false)
        )
        let registry = DockerEnvironmentProviderRegistry(providers: [
            StubDockerEnvironmentProvider(
                platform: .windows,
                scriptFamily: .posix,
                result: expected
            ),
        ])
        let session = RecordingSSHSession()

        let result = try await DockerService.probe(
            on: session,
            profile: RemotePlatformProfile(kind: .windows),
            registry: registry
        )

        #expect(result == expected)
        #expect(session.invocations.isEmpty)
    }

    @Test("Docker runtime 与默认 providers 明确声明 POSIX 家族")
    func runtimeAndProvidersDeclarePOSIXFamily() {
        let runtime = DockerRuntimeContext(executable: "/usr/bin/docker", sudo: false)

        #expect(runtime.scriptFamily == .posix)
        #expect(LinuxDockerEnvironmentProvider().scriptFamily == .posix)
        #expect(DarwinDockerEnvironmentProvider().scriptFamily == .posix)
    }

    @Test("公开 Docker 操作不存在绕过 runtime 的 sudo 重载或默认 runtime")
    func publicDockerAPIsRequireDiscoveredRuntime() throws {
        let serviceSource = try String(
            contentsOf: packageRoot.appending(path: "Sources/ConnOps/DockerService.swift"),
            encoding: .utf8
        )
        let detailSource = try String(
            contentsOf: packageRoot.appending(path: "Sources/ConnOps/DockerService+ResourceDetails.swift"),
            encoding: .utf8
        )
        let runtimeSource = try String(
            contentsOf: packageRoot.appending(path: "Sources/ConnOps/DockerRuntimeContext.swift"),
            encoding: .utf8
        )
        let commandSource = try String(
            contentsOf: packageRoot.appending(path: "Sources/ConnOps/DockerCommand.swift"),
            encoding: .utf8
        )

        let runtimeBypass = #"(?s)public\s+static\s+func\s+\w+\s*\([^)]*sudo:\s*Bool"#
        #expect(serviceSource.range(of: runtimeBypass, options: .regularExpression) == nil)
        #expect(detailSource.range(of: runtimeBypass, options: .regularExpression) == nil)
        #expect(commandSource.range(of: runtimeBypass, options: .regularExpression) == nil)
        #expect(!runtimeSource.contains("static let `default`"))
    }

    @Test("Docker 脚本引导函数保留探测路径与 sudo 上下文")
    func shellBootstrapUsesRuntimeContext() {
        let direct = DockerRuntimeContext(
            executable: "/Applications/Docker.app/Contents/Resources/bin/docker",
            sudo: false
        )
        let elevated = DockerRuntimeContext(executable: "/usr/local/bin/docker", sudo: true)

        #expect(
            direct.shellBootstrapCommand
                == "docker() { '/Applications/Docker.app/Contents/Resources/bin/docker' \"$@\"; }"
        )
        #expect(
            elevated.shellBootstrapCommand
                == "docker() { sudo -n '/usr/local/bin/docker' \"$@\"; }"
        )
    }

    @Test("Compose v1 使用独立探测路径而不是假定与 docker 同目录")
    func composeV1UsesIndependentExecutable() {
        let runtime = DockerRuntimeContext(
            executable: "/usr/bin/docker",
            sudo: false,
            composeV1Executable: "/usr/local/bin/docker-compose"
        )

        #expect(
            DockerCommand.composeVersion(.v1, runtime: runtime)
                == "'/usr/local/bin/docker-compose' version"
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct StubDockerEnvironmentProvider: DockerEnvironmentProvider {
    let platform: RemotePlatformKind
    let scriptFamily: RemoteScriptFamily
    let result: DockerProbeResult

    func probe(on session: any SSHSession) async throws -> DockerProbeResult {
        result
    }
}

@Suite("DockerService — 第二期写操作")
struct DockerOperationServiceTests {
    private let directRuntime = DockerRuntimeContext(executable: "docker", sudo: false)
    private let elevatedRuntime = DockerRuntimeContext(executable: "docker", sudo: true)

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

        let stream = try await DockerService.pullImage(
            reference: "nginx:1.27",
            on: session,
            runtime: elevatedRuntime
        )
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

        let result = try await DockerService.runContainer(
            draft,
            on: session,
            runtime: elevatedRuntime
        )

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
            DockerVolumeDraft(name: "app data"), on: session, runtime: directRuntime
        )
        let removeResult = try await DockerService.removeVolume(
            name: "app data",
            on: session,
            runtime: elevatedRuntime
        )

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
            DockerNetworkDraft(name: "app net", isInternal: true),
            on: session,
            runtime: elevatedRuntime
        )
        let removeResult = try await DockerService.removeNetwork(
            name: "app net",
            on: session,
            runtime: directRuntime
        )

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
            .init(allUnusedImages: true, includeVolumes: true),
            on: session,
            runtime: elevatedRuntime
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
    private let directRuntime = DockerRuntimeContext(executable: "docker", sudo: false)
    private let elevatedRuntime = DockerRuntimeContext(executable: "docker", sudo: true)

    @Test("Compose 探测优先 v2 并在失败后回退 v1")
    func detectsComposeDialectWithFallback() async throws {
        let v1Session = RecordingSSHSession(execResults: [
            .init(exitCode: 1, stdout: Data(), stderr: Data("not a command".utf8)),
            .init(exitCode: 0, stdout: Data("docker-compose version 1.29.2".utf8), stderr: Data()),
        ])

        let dialect = try await DockerService.composeDialect(
            on: v1Session,
            runtime: elevatedRuntime
        )

        #expect(dialect == .v1)
        #expect(v1Session.invocations == [
            .init(method: .exec, command: "sudo -n docker compose version", timeout: .seconds(30)),
            .init(method: .exec, command: "sudo -n docker-compose version", timeout: .seconds(30)),
        ])

        let unavailable = RecordingSSHSession(execResults: [
            .init(exitCode: 1, stdout: Data(), stderr: Data()),
            .init(exitCode: 127, stdout: Data(), stderr: Data()),
        ])
        #expect(
            try await DockerService.composeDialect(
                on: unavailable,
                runtime: directRuntime
            ) == nil
        )
    }

    @Test("v2 项目列表与容器标签合并项目目录和运行摘要")
    func listsV2ProjectsAndMergesContainerMetadata() async throws {
        let listed = """
        [{"Name":"web","Status":"running(1)","ConfigFiles":"/listed/compose.yml"}]
        """
        // swiftlint:disable line_length
        let containers = """
        {"ID":"c1","Image":"api:1","Names":"web-api-1","State":"running","Status":"Up","Ports":"8080/tcp","Labels":"com.docker.compose.project=web,com.docker.compose.project.config_files=/srv/web/compose.yml,com.docker.compose.project.working_dir=/srv/custom,com.docker.compose.service=api"}
        """
        // swiftlint:enable line_length
        let session = RecordingSSHSession(execResults: [
            .init(exitCode: 0, stdout: Data(listed.utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data(containers.utf8), stderr: Data()),
        ])

        let projects = try await DockerService.listComposeProjects(
            dialect: .v2, on: session, runtime: elevatedRuntime
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
            project, dialect: .v2, on: session, runtime: directRuntime
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
                project, dialect: .v2, on: session, runtime: directRuntime
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
                dialect: .v2, on: session, runtime: directRuntime
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

        _ = try await DockerService.composeUp(
            project, dialect: .v2, on: session, runtime: elevatedRuntime
        )
        let down = try await DockerService.composeDown(
            project, dialect: .v2, on: session, runtime: elevatedRuntime
        )
        _ = try await DockerService.composeRestart(
            project, service: "api", dialect: .v2, on: session, runtime: elevatedRuntime
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
            let result = remainingExecResults.isEmpty
                ? ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
                : remainingExecResults.removeFirst()
            return adaptLegacyDockerDiscovery(result, for: command)
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

private func adaptLegacyDockerDiscovery(
    _ result: ExecResult,
    for command: String
) -> ExecResult {
    guard let nonce = dockerResolverNonce(in: command), result.isSuccess else { return result }
    let lines = String(decoding: result.stdout, as: UTF8.self)
        .split(whereSeparator: \Character.isNewline)
        .map(String.init)
    let composeMarker = "__CONN_COMPOSE_V1__"
    let docker = lines.first { !$0.hasPrefix(composeMarker) && !$0.isEmpty }
    let compose = lines.first { $0.hasPrefix(composeMarker) }
        .map { String($0.dropFirst(composeMarker.count)) }
    let directories = [docker, compose].compactMap { executable -> String? in
        guard let executable, executable.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: executable).deletingLastPathComponent().path
    }
    let path = (directories + ["/usr/bin", "/bin"])
        .reduce(into: [String]()) { values, value in
            if !values.contains(value) { values.append(value) }
        }
        .joined(separator: ":")
    let output = [
        "__CONN_EXECUTABLES_v1_BEGIN_\(nonce)__",
        path,
        "__CONN_EXECUTABLES_v1_ITEM_0_\(nonce)__",
        docker ?? "",
        "__CONN_EXECUTABLES_v1_ITEM_1_\(nonce)__",
        compose ?? "",
        "__CONN_EXECUTABLES_v1_END_\(nonce)__",
    ].joined(separator: "\n")
    return ExecResult(exitCode: 0, stdout: Data(output.utf8), stderr: result.stderr)
}

private func dockerResolverNonce(in command: String) -> String? {
    let marker = "__CONN_EXECUTABLES_v1_BEGIN_"
    guard let range = command.range(of: marker) else { return nil }
    let suffix = command[range.upperBound...]
    guard let end = suffix.range(of: "__") else { return nil }
    let nonce = String(suffix[..<end.lowerBound])
    return nonce.isEmpty ? nil : nonce
}
