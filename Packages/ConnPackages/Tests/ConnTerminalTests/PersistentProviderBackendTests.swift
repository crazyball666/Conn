import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation
import Testing
@testable import ConnTerminal

@Suite("PersistentProviderBackend")
struct PersistentProviderBackendTests {
    @Test("通用 backend 只按 descriptor/registry 打开 byte presentation")
    func opensProviderAttachmentWithoutProviderSwitch() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let provider = FakePersistentProvider()
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let backend = PersistentProviderBackend(registry: registry)
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )
        let descriptor = provider.descriptorForTest
        let opened = try await backend.open(
            descriptor,
            for: host,
            connectionManager: manager,
            reason: PersistentAttachmentOpenReason.reconnect,
            terminalSize: TermSize(cols: 120, rows: 40)
        )

        #expect(opened.attachment.descriptor == descriptor)
        #expect(await provider.lastReason == .reconnect)
        try await opened.channel.write(Data("hello".utf8))
        await opened.attachment.close()
    }

    @Test("协调器 prepare 将 persistent attachment 错误转换为产品诊断")
    @MainActor
    func coordinatorPrepareUsesPersistentRuntimeDiagnosis() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let provider = FakePersistentProvider(openError: .transportClosed)
        let coordinator = TerminalSessionCoordinator(
            hostRepository: PersistentTestHostRepository(host: host),
            connectionManager: ConnectionManager(
                transport: MockSSHTransport(),
                platformDetector: FixedPlatformDetector()
            ),
            providerRegistry: try PersistentTerminalProviderRegistry(providers: [provider])
        )
        let attemptID = coordinator.beginLaunchAttempt()

        let result = await coordinator.prepareLaunch(
            TerminalLaunchRequest(
                host: host,
                policy: .createNew,
                source: .persistent(providerID: "fake"),
                backend: .persistent(provider.descriptorForTest)
            ),
            attemptID: attemptID
        )

        guard case let .failure(failure) = result else {
            Issue.record("attachment open 应失败")
            return
        }
        #expect(failure.message == PersistentTerminalError.transportClosed.userFacingDiagnosis)
        #expect(coordinator.store.tabs.isEmpty)
    }

    @Test("启动选择指定远端 workspace 时不自动改用第一个")
    func selectedWorkspaceIsUsedForAttachmentDescriptor() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let provider = FakePersistentProvider(workspaceIDs: ["first", "selected"])
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let backend = PersistentProviderBackend(registry: registry)
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )

        let workspaces = try await backend.workspaceOptions(
            for: try #require(backend.options().first),
            host: host,
            connectionManager: manager
        )
        let selectedWorkspace = try #require(workspaces.first { $0.workspace.workspaceID == "selected" })
        let launch = try await backend.launch(
            for: selectedWorkspace,
            option: try #require(backend.options().first),
            host: host,
            connectionManager: manager
        )

        #expect(launch.descriptor.workspace.workspaceID == "selected")
        #expect(launch.workspaceName == "selected")
        #expect(await provider.createdWorkspaceCount == 0)
    }

    @Test("启动选择新建 workspace 时调用 provider 创建而不是复用已有 workspace")
    func createSelectionCreatesWorkspace() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let provider = FakePersistentProvider(workspaceIDs: ["existing"])
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let backend = PersistentProviderBackend(registry: registry)
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )

        let launch = try await backend.createLaunch(
            for: PersistentWorkspaceCreateSelection(name: "new-session"),
            option: try #require(backend.options().first),
            host: host,
            connectionManager: manager
        )

        #expect(launch.descriptor.workspace.workspaceID == "created-new-session")
        #expect(launch.workspaceName == "new-session")
        #expect(await provider.createdWorkspaceCount == 1)
    }

    @Test("持久终端重命名使用 descriptor 配置并路由到所属 provider")
    func renameRoutesThroughDescriptorConfiguration() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let provider = FakePersistentProvider(workspaceIDs: ["ops"])
        let backend = PersistentProviderBackend(
            registry: try PersistentTerminalProviderRegistry(providers: [provider])
        )
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )
        let option = try #require(backend.options().first)
        let summary = try #require(
            try await backend.workspaceOptions(
                for: option,
                host: host,
                connectionManager: manager
            ).first
        )
        let launch = try await backend.launch(
            for: summary,
            option: option,
            host: host,
            connectionManager: manager
        )

        try await backend.renameWorkspace(
            launch.descriptor,
            to: "production",
            host: host,
            connectionManager: manager
        )

        #expect(await provider.renamedWorkspaces == ["ops:production"])
    }

    @Test("provider 选项来自本地注册表且枚举时不探测远端")
    func optionsAreLocalAndDoNotProbeRemote() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let provider = FakePersistentProvider()
        let backend = PersistentProviderBackend(
            registry: try PersistentTerminalProviderRegistry(providers: [provider])
        )
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )

        let options = backend.options()

        #expect(options.map(\.providerID) == ["fake"])
        #expect(options.map(\.configuration) == [provider.defaultConfiguration])
        #expect(await provider.probeCount == 0)

        let selected = try #require(options.first)
        let catalog = try await backend.openCatalog(
            for: selected,
            host: host,
            connectionManager: manager
        )
        var iterator = catalog.snapshots.makeAsyncIterator()
        #expect(await iterator.next()?.configurationKey == "default")
        #expect(await provider.openedCatalogConfigurationKeys == ["default"])
        await catalog.close()
    }

    @Test("多 provider 的目录查询只路由到用户选择项且不做重复 probe")
    func multipleProvidersQueryOnlyTheSelectedOptionWithoutProbe() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let tmux = FakePersistentProvider(id: "tmux", displayName: "tmux")
        let zellij = FakePersistentProvider(id: "zellij", displayName: "Zellij")
        let backend = PersistentProviderBackend(
            registry: try PersistentTerminalProviderRegistry(providers: [zellij, tmux])
        )
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )

        let options = backend.options()

        #expect(options.map(\.providerID) == ["tmux", "zellij"])
        #expect(await tmux.probeCount == 0)
        #expect(await zellij.probeCount == 0)

        let selected = try #require(options.first { $0.providerID == "zellij" })
        _ = try await backend.workspaceOptions(
            for: selected,
            host: host,
            connectionManager: manager
        )

        #expect(await tmux.probeCount == 0)
        #expect(await zellij.probeCount == 0)
        #expect(await tmux.workspaceListCount == 0)
        #expect(await zellij.workspaceListCount == 1)
        #expect(selected.configuration.providerID == "zellij")
    }
}

private final class PersistentTestHostRepository: HostRepository, @unchecked Sendable {
    private let value: ConnKit.Host

    init(host: ConnKit.Host) { value = host }
    func allHosts() throws -> [ConnKit.Host] { [value] }
    func host(id: String) throws -> ConnKit.Host? { id == value.id ? value : nil }
    func save(_ host: ConnKit.Host) throws {}
    func delete(id: String) throws {}
}

private struct FixedPlatformDetector: RemotePlatformDetecting {
    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        RemotePlatformProfile(kind: .linux, shell: .sh)
    }
}

private actor ReasonRecorder {
    var value: PersistentAttachmentOpenReason?

    func set(_ value: PersistentAttachmentOpenReason) {
        self.value = value
    }
}

private actor WorkspaceCreateRecorder {
    private(set) var value = 0

    func increment() { value += 1 }
}

private actor ConfigurationRecorder {
    private(set) var values: [String] = []
    private(set) var probes = 0
    private(set) var workspaceLists = 0
    private(set) var renames: [String] = []

    func append(_ value: String) { values.append(value) }
    func recordProbe() { probes += 1 }
    func recordWorkspaceList() { workspaceLists += 1 }
    func recordRename(workspaceID: String, name: String) {
        renames.append("\(workspaceID):\(name)")
    }
}

private struct FakePersistentProvider: PersistentTerminalCatalogProvider, Sendable {
    let descriptor: PersistentTerminalProviderDescriptor
    let defaultConfiguration: PersistentTerminalConfiguration
    let descriptorForTest: PersistentAttachmentDescriptor
    let recorder: ReasonRecorder
    let workspaces: [RemoteWorkspaceSummary]
    let createdCount: WorkspaceCreateRecorder
    let configurationRecorder: ConfigurationRecorder
    let openError: PersistentTerminalError?

    init(
        id: String = "fake",
        displayName: String = "Fake",
        workspaceIDs: [String] = [],
        openError: PersistentTerminalError? = nil
    ) {
        descriptor = PersistentTerminalProviderDescriptor(
            id: id,
            displayName: displayName,
            supportedPlatforms: [.linux],
            supportedConfigurationVersions: [1],
            supportedWorkspaceInstancePayloadVersions: [1],
            supportedAttachmentPayloadVersions: [1],
            potentialFeatures: [.readOnlyAttach]
        )
        defaultConfiguration = PersistentTerminalConfiguration(
            providerID: id,
            configurationKey: "default",
            payloadVersion: 1,
            providerPayload: Data("{}".utf8)
        )
        workspaces = workspaceIDs.map { id in
            RemoteWorkspaceSummary(
                workspace: RemoteWorkspaceRef(
                    workspaceID: id,
                    instancePayloadVersion: 1,
                    providerInstancePayload: Data()
                ),
                name: id,
                occupancy: RemoteWorkspaceOccupancy(
                    affectedAttachmentCount: nil,
                    observedAt: Date(),
                    freshness: .unknown
                )
            )
        }
        createdCount = WorkspaceCreateRecorder()
        configurationRecorder = ConfigurationRecorder()
        descriptorForTest = PersistentAttachmentDescriptor(
            providerID: "fake",
            configuration: defaultConfiguration,
            workspace: RemoteWorkspaceRef(
                workspaceID: "workspace-1",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )
        recorder = ReasonRecorder()
        self.openError = openError
    }

    var lastReason: PersistentAttachmentOpenReason? {
        get async { await recorder.value }
    }

    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        await configurationRecorder.recordProbe()
        return .init(state: .available, effectiveFeatures: [.readOnlyAttach])
    }

    func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary] {
        await configurationRecorder.recordWorkspaceList()
        return workspaces
    }

    func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceSummary {
        await createdCount.increment()
        return RemoteWorkspaceSummary(
            workspace: RemoteWorkspaceRef(
                workspaceID: "created-\(request.name ?? "default")",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            name: request.name ?? "generated",
            occupancy: RemoteWorkspaceOccupancy(
                affectedAttachmentCount: nil,
                observedAt: .now,
                freshness: .fresh
            )
        )
    }

    func renameWorkspace(_ workspace: RemoteWorkspaceRef, to newName: String, in context: PersistentTerminalContext) async throws {
        await configurationRecorder.recordRename(workspaceID: workspace.workspaceID, name: newName)
    }

    func destroyWorkspace(_ workspace: RemoteWorkspaceRef, in context: PersistentTerminalContext) async throws {
        throw PersistentTerminalError.unsupportedFeature(providerID: descriptor.id, feature: "destroy")
    }

    func makeAttachmentDescriptor(to workspace: RemoteWorkspaceRef, in context: PersistentTerminalContext) throws -> PersistentAttachmentDescriptor {
        PersistentAttachmentDescriptor(
            providerID: descriptor.id,
            configuration: context.backendConfiguration,
            workspace: workspace,
            payloadVersion: 1,
            providerPayload: Data()
        )
    }

    func workspace(id: String) -> RemoteWorkspaceRef? {
        workspaces.first { $0.workspace.workspaceID == id }?.workspace
    }

    var createdWorkspaceCount: Int {
        get async { await createdCount.value }
    }

    var workspaceListCount: Int {
        get async { await configurationRecorder.workspaceLists }
    }

    var openedCatalogConfigurationKeys: [String] {
        get async { await configurationRecorder.values }
    }

    var probeCount: Int {
        get async { await configurationRecorder.probes }
    }

    var renamedWorkspaces: [String] {
        get async { await configurationRecorder.renames }
    }

    func openCatalog(
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalCatalogAttachment {
        await configurationRecorder.append(context.backendConfiguration.configurationKey)
        return FakeCatalogAttachment(
            providerID: descriptor.id,
            configurationKey: context.backendConfiguration.configurationKey
        )
    }

    func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
        if let openError { throw openError }
        await recorderSet(reason)
        return FakePersistentAttachment(descriptor: descriptor)
    }

    private func recorderSet(_ reason: PersistentAttachmentOpenReason) async {
        await recorder.set(reason)
    }
}

private final class FakeCatalogAttachment: PersistentTerminalCatalogAttachment, @unchecked Sendable {
    let snapshots: AsyncStream<PersistentWorkspaceCatalogSnapshot>
    private let continuation: AsyncStream<PersistentWorkspaceCatalogSnapshot>.Continuation

    init(providerID: String, configurationKey: String) {
        (snapshots, continuation) = AsyncStream.makeStream()
        let observedAt = Date()
        continuation.yield(PersistentWorkspaceCatalogSnapshot(
            providerID: providerID,
            configurationKey: configurationKey,
            instance: nil,
            workspaces: [],
            freshness: .snapshot(observedAt: observedAt),
            observedAt: observedAt
        ))
    }

    func close() async { continuation.finish() }
}

private final class FakePersistentAttachment: PersistentTerminalAttachment, @unchecked Sendable {
    let descriptor: PersistentAttachmentDescriptor
    let presentation: PersistentAttachmentPresentation

    init(descriptor: PersistentAttachmentDescriptor) {
        self.descriptor = descriptor
        let channel = FakeShellChannel()
        presentation = .byteTerminal(channel)
    }

    func close() async {}
}

private final class FakeShellChannel: ShellChannel, @unchecked Sendable {
    let output = AsyncThrowingStream<Data, Error> { $0.finish() }
    func write(_ bytes: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func close() async {}
}
