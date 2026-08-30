import ConnKit
import ConnMultiplexer
import ConnSSH
import Foundation
import Testing

@Suite("Persistent terminal provider registry")
struct PersistentTerminalProviderRegistryTests {
    @Test("registry 确定性枚举代码内置默认配置")
    func registeredDefaultsAreLocalAndDeterministic() {
        let defaults = PersistentTerminalProviderRegistry.default.registeredDefaults()

        #expect(defaults.map(\.descriptor.id) == [
            TmuxProvider.providerID,
            ZellijProvider.providerID
        ])
        #expect(defaults.first?.configuration.providerID == TmuxProvider.providerID)
        #expect(defaults.first?.configuration.configurationKey == "default")
        #expect(defaults.first?.configuration.payloadVersion == TmuxProvider.configurationVersion)
    }

    @Test("内置 registry 注册 tmux 与 Zellij，但仍按平台精确路由")
    func builtInRegistryRegistersPersistentProviders() throws {
        let configuration = TmuxProvider().defaultConfiguration

        #expect(
            try PersistentTerminalProviderRegistry.default
                .provider(for: configuration, platform: .macOS)
                .descriptor.id == TmuxProvider.providerID
        )
        #expect(throws: PersistentTerminalError.unsupportedPlatform) {
            try PersistentTerminalProviderRegistry.default
                .provider(for: configuration, platform: .windows)
        }

        let zellij = ZellijProvider().defaultConfiguration
        #expect(
            try PersistentTerminalProviderRegistry.default
                .provider(for: zellij, platform: .linux)
                .descriptor.id == ZellijProvider.providerID
        )
        #expect(throws: PersistentTerminalError.unsupportedPlatform) {
            try PersistentTerminalProviderRegistry.default
                .provider(for: zellij, platform: .windows)
        }
    }

    @Test("provider ID、配置版本和平台必须同时精确匹配且不回退")
    func exactProviderAndPlatformSelection() throws {
        let provider = FakePersistentTerminalProvider(
            id: "tmux",
            supportedPlatforms: [.linux, .macOS],
            supportedConfigurationVersions: [1]
        )
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let configuration = makeConfiguration(providerID: "tmux")

        #expect(try registry.provider(for: configuration, platform: .linux).descriptor.id == "tmux")
        #expect(try registry.provider(for: configuration, platform: .macOS).descriptor.id == "tmux")
        #expect(throws: PersistentTerminalError.unsupportedPlatform) {
            try registry.provider(for: configuration, platform: .windows)
        }
        #expect(throws: PersistentTerminalError.unsupportedPlatform) {
            try registry.provider(for: configuration, platform: .unknown)
        }

        let futureConfiguration = makeConfiguration(providerID: "tmux", payloadVersion: 2)
        #expect(throws: PersistentTerminalError.unsupportedConfigurationVersion(
            providerID: "tmux",
            version: 2
        )) {
            try registry.provider(for: futureConfiguration, platform: .linux)
        }
    }

    @Test("重复 provider ID 在构造 registry 时确定性失败")
    func duplicateProviderIDsAreRejected() {
        let first = FakePersistentTerminalProvider(id: "tmux")
        let second = FakePersistentTerminalProvider(id: "tmux")

        #expect(throws: PersistentTerminalProviderRegistryError.duplicateProviderID("tmux")) {
            try PersistentTerminalProviderRegistry(providers: [first, second])
        }
    }

    @Test("probe 拒绝 provider 未声明支持的 server-instance payload 版本")
    func probeRejectsUnsupportedInstancePayloadVersion() async throws {
        let provider = FakePersistentTerminalProvider(id: "tmux", probeInstancePayloadVersion: 2)
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let context = try await makeContext(configuration: makeConfiguration(providerID: "tmux"))

        await #expect(throws: PersistentTerminalError.unsupportedDescriptorVersion(
            providerID: "tmux",
            component: .workspaceInstance,
            version: 2
        )) {
            try await registry.probe(in: context)
        }
    }

    @Test("未知 provider 与未知 payload 版本可诊断且绝不调用 open")
    func invalidDescriptorsAreNeverOpened() async throws {
        let provider = FakePersistentTerminalProvider(id: "tmux")
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let context = try await makeContext(configuration: makeConfiguration(providerID: "tmux"))

        let unknownProvider = makeDescriptor(providerID: "future")
        await #expect(throws: PersistentTerminalError.providerNotRegistered("future")) {
            try await registry.openAttachment(
                unknownProvider,
                reason: .initial,
                terminalSize: .init(cols: 80, rows: 24),
                in: context
            )
        }

        let unknownInstanceVersion = makeDescriptor(instancePayloadVersion: 2)
        await #expect(throws: PersistentTerminalError.unsupportedDescriptorVersion(
            providerID: "tmux",
            component: .workspaceInstance,
            version: 2
        )) {
            try await registry.openAttachment(
                unknownInstanceVersion,
                reason: .reconnect,
                terminalSize: .init(cols: 80, rows: 24),
                in: context
            )
        }

        let unknownAttachmentVersion = makeDescriptor(payloadVersion: 2)
        await #expect(throws: PersistentTerminalError.unsupportedDescriptorVersion(
            providerID: "tmux",
            component: .attachment,
            version: 2
        )) {
            try await registry.openAttachment(
                unknownAttachmentVersion,
                reason: .reconnect,
                terminalSize: .init(cols: 80, rows: 24),
                in: context
            )
        }

        #expect(await provider.openReasons() == [])
    }

    @Test("initial 与 reconnect 使用同一个通用 descriptor 路由")
    func routesInitialAndReconnectWithoutProviderSwitches() async throws {
        let provider = FakePersistentTerminalProvider(id: "tmux")
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let context = try await makeContext(configuration: makeConfiguration(providerID: "tmux"))
        let descriptor = makeDescriptor()

        let initial = try await registry.openAttachment(
            descriptor,
            reason: .initial,
            terminalSize: .init(cols: 80, rows: 24),
            in: context
        )
        let reconnect = try await registry.openAttachment(
            descriptor,
            reason: .reconnect,
            terminalSize: .init(cols: 120, rows: 40),
            in: context
        )

        #expect(initial.descriptor == descriptor)
        #expect(reconnect.descriptor == descriptor)
        #expect(await provider.openReasons() == [.initial, .reconnect])
    }

    @Test("attachment 句柄拥有幂等 close 生命周期")
    func attachmentCloseIsIdempotent() async throws {
        let provider = FakePersistentTerminalProvider(id: "tmux")
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let context = try await makeContext(configuration: makeConfiguration(providerID: "tmux"))
        let attachment = try await registry.openAttachment(
            makeDescriptor(),
            reason: .initial,
            terminalSize: .init(cols: 80, rows: 24),
            in: context
        )

        await attachment.close()
        await attachment.close()

        let fake = try #require(attachment as? FakePersistentTerminalAttachment)
        #expect(await fake.closeCount() == 1)
    }
}

private func makeConfiguration(
    providerID: String,
    payloadVersion: Int = 1
) -> PersistentTerminalConfiguration {
    PersistentTerminalConfiguration(
        providerID: providerID,
        configurationKey: "default",
        payloadVersion: payloadVersion,
        providerPayload: Data("{}".utf8)
    )
}

private func makeDescriptor(
    providerID: String = "tmux",
    instancePayloadVersion: Int = 1,
    payloadVersion: Int = 1
) -> PersistentAttachmentDescriptor {
    PersistentAttachmentDescriptor(
        providerID: providerID,
        configuration: makeConfiguration(providerID: providerID),
        workspace: RemoteWorkspaceRef(
            workspaceID: "$1",
            instancePayloadVersion: instancePayloadVersion,
            providerInstancePayload: Data("instance".utf8)
        ),
        payloadVersion: payloadVersion,
        providerPayload: Data("attachment".utf8)
    )
}

private func makeContext(
    configuration: PersistentTerminalConfiguration
) async throws -> PersistentTerminalContext {
    let host = Host(
        id: "host-1",
        name: "Test",
        address: "test.local",
        username: "tester"
    )
    let manager = ConnectionManager(
        transport: MockSSHTransport(),
        platformDetector: FixedPlatformDetector(kind: .linux)
    )
    let remoteContext = try await manager.platformContext(for: host)
    return PersistentTerminalContext(
        platformContext: remoteContext,
        backendConfiguration: configuration
    )
}

private struct FixedPlatformDetector: RemotePlatformDetecting {
    let kind: RemotePlatformKind

    func detect(on session: any SSHSession) async throws -> RemotePlatformProfile {
        RemotePlatformProfile(kind: kind, shell: .sh)
    }
}

private final class FakePersistentTerminalProvider: PersistentTerminalProvider, @unchecked Sendable {
    let descriptor: PersistentTerminalProviderDescriptor
    let defaultConfiguration: PersistentTerminalConfiguration
    private let recorder = OpenReasonRecorder()
    private let probeInstancePayloadVersion: Int

    init(
        id: String,
        supportedPlatforms: Set<RemotePlatformKind> = [.linux, .macOS],
        supportedConfigurationVersions: Set<Int> = [1],
        probeInstancePayloadVersion: Int = 1
    ) {
        self.probeInstancePayloadVersion = probeInstancePayloadVersion
        defaultConfiguration = PersistentTerminalConfiguration(
            providerID: id,
            configurationKey: "default",
            payloadVersion: supportedConfigurationVersions.min() ?? 1,
            providerPayload: Data("{}".utf8)
        )
        descriptor = PersistentTerminalProviderDescriptor(
            id: id,
            displayName: id,
            supportedPlatforms: supportedPlatforms,
            supportedConfigurationVersions: supportedConfigurationVersions,
            supportedWorkspaceInstancePayloadVersions: [1],
            supportedAttachmentPayloadVersions: [1],
            potentialFeatures: [.workspaceDiscovery, .workspaceCreation]
        )
    }

    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        PersistentTerminalAvailability(
            state: .available,
            effectiveFeatures: descriptor.potentialFeatures,
            instance: .init(
                payloadVersion: probeInstancePayloadVersion,
                providerPayload: Data("instance".utf8)
            )
        )
    }

    func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary] {
        []
    }

    func createWorkspace(
        _ request: CreateWorkspaceRequest,
        in context: PersistentTerminalContext
    ) async throws -> RemoteWorkspaceSummary {
        RemoteWorkspaceSummary(
            workspace: makeDescriptor().workspace,
            name: request.name ?? "generated",
            occupancy: .init(
                affectedAttachmentCount: nil,
                observedAt: .now,
                freshness: .fresh
            )
        )
    }

    func renameWorkspace(
        _ workspace: RemoteWorkspaceRef,
        to newName: String,
        in context: PersistentTerminalContext
    ) async throws {}

    func destroyWorkspace(
        _ workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) async throws {}

    func makeAttachmentDescriptor(
        to workspace: RemoteWorkspaceRef,
        in context: PersistentTerminalContext
    ) throws -> PersistentAttachmentDescriptor {
        PersistentAttachmentDescriptor(
            providerID: descriptor.id,
            configuration: context.backendConfiguration,
            workspace: workspace,
            payloadVersion: 1,
            providerPayload: Data("attachment".utf8)
        )
    }

    func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
        await recorder.append(reason)
        return FakePersistentTerminalAttachment(descriptor: descriptor)
    }

    func openReasons() async -> [PersistentAttachmentOpenReason] {
        await recorder.values
    }
}

private actor OpenReasonRecorder {
    private(set) var values: [PersistentAttachmentOpenReason] = []

    func append(_ reason: PersistentAttachmentOpenReason) {
        values.append(reason)
    }
}

private final class FakePersistentTerminalAttachment: PersistentTerminalAttachment, @unchecked Sendable {
    let descriptor: PersistentAttachmentDescriptor
    let presentation: PersistentAttachmentPresentation
    private let state = AttachmentCloseState()

    init(descriptor: PersistentAttachmentDescriptor) {
        self.descriptor = descriptor
        presentation = .byteTerminal(FakeShellChannel())
    }

    func close() async {
        await state.closeOnce()
    }

    func closeCount() async -> Int {
        await state.count
    }
}

private actor AttachmentCloseState {
    private(set) var count = 0
    private var isClosed = false

    func closeOnce() {
        guard !isClosed else { return }
        isClosed = true
        count += 1
    }
}

private final class FakeShellChannel: ShellChannel, @unchecked Sendable {
    let output = AsyncThrowingStream<Data, Error> { continuation in
        continuation.finish()
    }

    func write(_ bytes: Data) async throws {}
    func resize(_ size: TermSize) async throws {}
    func close() async {}
}
