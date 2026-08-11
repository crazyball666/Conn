import ConnCrypto
import ConnKit
import ConnMonitor
import ConnOps
import ConnRunner
import ConnSSH
import ConnTerminal
import Foundation
import Testing
@testable import Conn

/// App 层新增的四个 `@Observable` Docker 资源模型（`DockerContainersModel` /
/// `DockerImagesModel` / `DockerVolumesModel` / `DockerNetworksModel`）此前一行
/// 测试都没有——`95f5260` 那次纯重构就悄悄丢过三个行为，靠人肉复查才捞回来。
/// 这里补最要害的几条，照 `ServersViewModelTests` 的写法：手写 `SSHSession` /
/// `SSHTransport`，把命令映射到确定性输出，不连真实网络。
@MainActor
struct DockerModelsTests {
    /// 直接构造 `DockerContext`，不经 `DockerViewModel`——测容器 / 镜像 / 网络
    /// 三个子模型各自的行为时，不需要走完整的可用性探测流程。
    private func makeContext(
        session: @escaping () async throws -> any SSHSession,
        isUsable: Bool
    ) -> DockerContext {
        DockerContext(
            session: session, sudo: false, isUsable: isUsable,
            report: { _ in }, refresh: { _ in }, reprobe: {}
        )
    }

    // MARK: - 1. DockerNetworksModel：未使用集合 = 悬空集合减去预置网络

    /// 这是本期最要害的一步合成：`unusedNames = danglingNames.subtracting(predefined)`。
    /// 写反（`predefined.subtracting(danglingNames)`）或干脆删掉这一步，
    /// 现有的其它测试（如果只测「加载成功」）照样全绿——必须专门断言这个集合运算。
    @Test("网络未使用集合排除预置网络（bridge/host/none）")
    func networksUnusedNamesExcludesPredefined() async {
        let session = ScriptedSession()
        session.setResponse(
            DockerCommand.networks(sudo: false),
            stdout: [
                #"{"ID":"n1","Name":"bridge","Driver":"bridge","Scope":"local"}"#,
                #"{"ID":"n2","Name":"app-net","Driver":"bridge","Scope":"local"}"#
            ].joined(separator: "\n")
        )
        // bridge 与 app-net 都「无容器接入」，但 bridge 是预置网络，不该出现在
        // 最终的 unusedNames 里。
        session.setResponse(DockerCommand.danglingNetworks(sudo: false), stdout: "bridge\napp-net")

        let context = makeContext(session: { session }, isUsable: true)
        let operations = DockerOperationsModel(
            context: context, hostUUID: "h1", runHistory: StubRunHistoryRepository()
        )
        let model = DockerNetworksModel(context: context, operations: operations)
        await model.load()

        #expect(model.unusedNames == ["app-net"])
    }

    // MARK: - 2. DockerContainersModel：isUsable=false 时 refresh() 短路去 reprobe

    @Test("isUsable=false 时 refresh() 短路去 reprobe，不取会话")
    func containersRefreshShortCircuitsWhenUnusable() async {
        final class Flags: @unchecked Sendable {
            var reprobed = false
            var sessionRequested = false
        }
        let flags = Flags()
        let context = DockerContext(
            session: { flags.sessionRequested = true; throw SSHError.channelClosed },
            sudo: false, isUsable: false,
            report: { _ in }, refresh: { _ in }, reprobe: { flags.reprobed = true }
        )
        let operations = DockerOperationsModel(
            context: context, hostUUID: "h1", runHistory: StubRunHistoryRepository()
        )
        let model = DockerContainersModel(context: context, operations: operations)

        await model.refresh()

        #expect(flags.reprobed, "isUsable=false 时必须回退去 reprobe（翻到「不可用」引导页）")
        #expect(!flags.sessionRequested, "不该在 reprobe 之外还去取会话")
    }

    // MARK: - 3. DockerImagesModel：isUsable=false 时 load() 静默 no-op

    @Test("isUsable=false 时 load() 静默 no-op，不发命令、不设 loaded")
    func imagesLoadNoOpsWhenUnusable() async {
        final class Flags: @unchecked Sendable {
            var sessionRequested = false
        }
        let flags = Flags()
        let context = makeContext(
            session: { flags.sessionRequested = true; throw SSHError.channelClosed },
            isUsable: false
        )
        let operations = DockerOperationsModel(
            context: context, hostUUID: "h1", runHistory: StubRunHistoryRepository()
        )
        let model = DockerImagesModel(context: context, operations: operations)

        await model.load()

        #expect(!flags.sessionRequested)
        #expect(model.loaded == false)
        #expect(model.items.isEmpty)
    }

    @Test("卷和网络删除入口只在可用、未使用且非预置时暂存 Operations 确认")
    func resourceDeletionAvailabilityRules() async throws {
        let session = ScriptedSession()
        session.setResponse(
            DockerCommand.volumes(sudo: false),
            stdout: #"{"Name":"cache","Driver":"local","Scope":"local","Mountpoint":"/var/lib/docker/volumes/cache/_data"}"#
        )
        session.setResponse(DockerCommand.danglingVolumes(sudo: false), stdout: "cache")
        session.setResponse(
            DockerCommand.networks(sudo: false),
            stdout: [
                #"{"ID":"bridge","Name":"bridge","Driver":"bridge","Scope":"local"}"#,
                #"{"ID":"app","Name":"app-net","Driver":"bridge","Scope":"local"}"#
            ].joined(separator: "\n")
        )
        session.setResponse(DockerCommand.danglingNetworks(sudo: false), stdout: "bridge\napp-net")
        let context = makeContext(session: { session }, isUsable: true)
        let operations = DockerOperationsModel(
            context: context, hostUUID: "h1", runHistory: StubRunHistoryRepository()
        )
        let volumes = DockerVolumesModel(context: context, operations: operations)
        let networks = DockerNetworksModel(context: context, operations: operations)
        await volumes.load()
        await networks.load()

        let volume = try #require(volumes.items.first)
        let predefined = try #require(networks.items.first(where: { $0.isPredefined }))
        let unusedNetwork = try #require(networks.items.first(where: { $0.name == "app-net" }))

        #expect(volumes.canRemove(volume))
        #expect(!volumes.canRemove(VolumeInfo(name: "used", driver: "local", scope: "local", mountpoint: "/used")))
        #expect(!networks.canRemove(predefined))
        #expect(networks.canRemove(unusedNetwork))
        #expect(!networks.canRemove(NetworkInfo(id: "used", name: "used-net", driver: "bridge", scope: "local")))
        volumes.requestRemoval(volume)
        #expect(operations.pendingDestructiveAction == .removeVolume(volume))

        let unavailableContext = makeContext(session: { session }, isUsable: false)
        let unavailableOperations = DockerOperationsModel(
            context: unavailableContext, hostUUID: "h1", runHistory: StubRunHistoryRepository()
        )
        let unavailableNetworks = DockerNetworksModel(context: unavailableContext, operations: unavailableOperations)
        #expect(!unavailableNetworks.canRemove(unusedNetwork))
        unavailableNetworks.requestRemoval(unusedNetwork)
        #expect(unavailableOperations.pendingDestructiveAction == nil)
    }

    // MARK: - 4. loadImagesWithUsage() 的容器兜底分支（必修 4b 的修复行为）

    /// 容器兜底取数（`containers.items.isEmpty` 时补拉一次）失败时，必须跳过
    /// `refreshUsage`，不能拿空列表去算——否则 `ImageUsage.unusedImageIDs` 会把
    /// **每一个**镜像都判成「未使用」（没有任何容器能匹配空列表），且没有任何
    /// 提示告诉用户这其实是取数失败、不是真实状态。
    @Test("容器兜底取数失败时跳过 refreshUsage，不把镜像误判为未使用")
    func loadImagesWithUsageSkipsRefreshOnContainerFetchFailure() async {
        let host = Host(name: "web-01", address: "10.20.0.11", username: "root")
        let session = ScriptedSession()
        session.setResponse(
            RemotePlatformDetector.posixCommand,
            stdout: """
            __CONN_UNAME__
            Linux
            __CONN_RELEASE__
            6.8
            __CONN_ARCH__
            arm64
            __CONN_SHELL__
            /bin/sh
            __CONN_END__
            """
        )
        session.setResponse(
            containing: "conn_docker_path=$(command -v docker 2>/dev/null || true)",
            stdout: "docker\n"
        )
        session.setResponse(DockerCommand.availabilityProbe(sudo: false), stdout: "__EXIT__0")
        session.setResponse(
            DockerCommand.images(sudo: false),
            stdout: #"{"ID":"aaa111222333","Repository":"myapp","Tag":"1.0","Size":"10MB","CreatedSince":"1 day ago"}"#
        )
        session.setResponse(DockerCommand.stats(sudo: false), stdout: "")
        // `docker ps -a` 一直失败——模拟容器取数持续失败（瞬时网络问题、会话半死等）。
        session.fail(DockerCommand.list(sudo: false))

        let viewModel = DockerViewModel(host: host, dependencies: makeDependencies(session: session))

        await viewModel.load()
        // 探测成功但 `containers.load(using:)` 失败：外壳的 `load()` 落到 .failed，
        // `containers.items` 从未被赋值，仍是空的——这正是 4b 描述的前提条件。
        guard case .failed = viewModel.loadState else {
            Issue.record("期望 loadState 落在 .failed，实际 \(viewModel.loadState)")
            return
        }
        #expect(viewModel.containers.items.isEmpty)

        await viewModel.loadImagesWithUsage()

        #expect(viewModel.images.items.count == 1, "镜像本身应该正常加载成功")
        #expect(viewModel.images.unusedIDs.isEmpty, "容器兜底取数失败时不能把镜像误判为未使用")
    }

    // MARK: - 依赖装配

    private func makeDependencies(session: ScriptedSession) -> AppDependencies {
        let transport = ScriptedTransport(session: session)
        let connectionManager = ConnectionManager(transport: transport)
        return AppDependencies(
            hostRepository: StubHostRepository(),
            hostGroupRepository: StubHostGroupRepository(),
            keyRepository: StubSSHKeyRepository(),
            credentialStore: InMemoryCredentialStore(),
            connectionManager: connectionManager,
            snippetExecutionPlanner: SnippetExecutionPlanner(
                connectionManager: connectionManager,
                executionProviderRegistry: .default,
                requirementAdapterRegistry: SnippetRequirementAdapterRegistry(adapters: [])
            ),
            diagnosticsTransport: transport,
            monitor: MonitorScheduler(connectionManager: connectionManager),
            runHistory: StubRunHistoryRepository(),
            snippetRepository: StubSnippetRepository(),
            snippetGroupRepository: StubSnippetGroupRepository(),
            terminalSessions: TerminalSessionCoordinator(
                hostRepository: StubHostRepository(),
                connectionManager: connectionManager
            ),
            appLock: AppLockController(authenticator: StubAuthenticator(), isEnabled: false)
        )
    }
}

// MARK: - 脚本化的假会话 / 传输层

/// 把命令映射到确定性输出的假会话；未登记的命令一律返回空成功输出。
/// 与 `ServersViewModelTests.swift` 里的 `GatedSession` 同一路数，这里额外加了
/// 「命令 → 输出」的映射表与「指定命令失败」的开关。
private final class ScriptedSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true

    private let lock = NSLock()
    private var responses: [String: String] = [:]
    private var partialResponses: [(fragment: String, stdout: String)] = []
    private var failingCommands: Set<String> = []

    init() {
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func setResponse(_ command: String, stdout: String) {
        lock.withLock { responses[command] = stdout }
    }

    func setResponse(containing fragment: String, stdout: String) {
        lock.withLock { partialResponses.append((fragment, stdout)) }
    }

    /// 登记后，这条命令每次被 exec 都会抛错（模拟持续失败，而非只失败一次）。
    func fail(_ command: String) {
        lock.withLock { failingCommands.insert(command) }
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        let shouldFail = lock.withLock { failingCommands.contains(command) }
        if shouldFail { throw SSHError.channelClosed }
        let stdout = lock.withLock {
            responses[command]
                ?? partialResponses.first(where: { command.contains($0.fragment) })?.stdout
        } ?? ""
        return ExecResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }
    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

private final class ScriptedTransport: SSHTransport {
    let session: ScriptedSession
    init(session: ScriptedSession) { self.session = session }

    func connect(
        _ endpoint: SSHEndpoint, username: String, auth: SSHAuth, hostKeyPolicy: HostKeyPolicy
    ) async throws -> any SSHSession {
        session
    }
}

// MARK: - AppDependencies 的最小 Stub（DockerViewModel 只用得到 connectionManager / runHistory，
// 其余字段是 AppDependencies 构造要求的陪衬，给空实现即可）

private final class StubHostRepository: HostRepository, @unchecked Sendable {
    func allHosts() throws -> [Host] { [] }
    func host(id: String) throws -> Host? { nil }
    func save(_ host: Host) throws {}
    func delete(id: String) throws {}
}

private final class StubHostGroupRepository: HostGroupRepository, @unchecked Sendable {
    func allGroups() throws -> [HostGroup] { [] }
    func save(_ group: HostGroup) throws {}
    func delete(id: String) throws {}
}

private final class StubSSHKeyRepository: SSHKeyRepository, @unchecked Sendable {
    func allKeys() throws -> [SSHKey] { [] }
    func key(id: String) throws -> SSHKey? { nil }
    func save(_ key: SSHKey) throws {}
    func delete(id: String) throws {}
}

private final class StubRunHistoryRepository: RunHistoryRepository, @unchecked Sendable {
    func record(_ entry: RunHistoryEntry) throws {}
    func update(_ entry: RunHistoryEntry) throws {}
    func recoverPending() throws {}
    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry] { [] }
}

private final class StubSnippetRepository: SnippetRepository, @unchecked Sendable {
    func allSnippets() throws -> [Snippet] { [] }
    func snippet(id: String) throws -> Snippet? { nil }
    func save(_ snippet: Snippet) throws {}
    func delete(id: String) throws {}
    func count() throws -> Int { 0 }
}

private final class StubSnippetGroupRepository: SnippetGroupRepository, @unchecked Sendable {
    func allGroups() throws -> [SnippetGroup] { [] }
    func save(_ group: SnippetGroup) throws {}
    func delete(id: String) throws {}
}

private struct StubAuthenticator: BiometricAuthenticator {
    let isAvailable = true
    let displayName = "Face ID"
    func authenticate(reason: String) async -> BiometricResult { .success }
}
