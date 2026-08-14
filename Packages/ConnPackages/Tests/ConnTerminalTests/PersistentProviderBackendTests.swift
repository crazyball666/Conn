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
        let profile = TerminalBackendProfile(
            id: "profile-1",
            hostID: host.id,
            providerID: "fake",
            providerConfigurationKey: "default",
            displayName: "Fake",
            configurationJSON: "{}"
        )
        let provider = FakePersistentProvider()
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let backend = PersistentProviderBackend(
            registry: registry,
            profileRepository: InMemoryTerminalBackendProfiles(profiles: [profile])
        )
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

    @Test("启动选择指定远端 workspace 时不自动改用第一个")
    func selectedWorkspaceIsUsedForAttachmentDescriptor() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let profile = TerminalBackendProfile(
            id: "profile-1",
            hostID: host.id,
            providerID: "fake",
            providerConfigurationKey: "default",
            displayName: "Fake",
            configurationJSON: "{}"
        )
        let provider = FakePersistentProvider(workspaceIDs: ["first", "selected"])
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let backend = PersistentProviderBackend(
            registry: registry,
            profileRepository: InMemoryTerminalBackendProfiles(profiles: [profile])
        )
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )

        let workspaces = try await backend.workspaceOptions(
            for: PersistentBackendCandidate(
                providerID: "fake",
                profileID: profile.id,
                displayName: profile.displayName,
                availability: .available
            ),
            host: host,
            connectionManager: manager
        )
        let selectedWorkspace = try #require(workspaces.first { $0.workspace.workspaceID == "selected" })
        let descriptor = try await backend.descriptor(
            for: selectedWorkspace.workspace,
            providerID: "fake",
            profileID: profile.id,
            host: host,
            connectionManager: manager
        )

        #expect(descriptor.workspace.workspaceID == "selected")
        #expect(await provider.createdWorkspaceCount == 0)
    }

    @Test("启动选择新建 workspace 时调用 provider 创建而不是复用已有 workspace")
    func createSelectionCreatesWorkspace() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let profile = TerminalBackendProfile(
            id: "profile-1",
            hostID: host.id,
            providerID: "fake",
            providerConfigurationKey: "default",
            displayName: "Fake",
            configurationJSON: "{}"
        )
        let provider = FakePersistentProvider(workspaceIDs: ["existing"])
        let registry = try PersistentTerminalProviderRegistry(providers: [provider])
        let backend = PersistentProviderBackend(
            registry: registry,
            profileRepository: InMemoryTerminalBackendProfiles(profiles: [profile])
        )
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )

        let descriptor = try await backend.createDescriptor(
            for: PersistentWorkspaceCreateSelection(name: "new-session"),
            candidate: PersistentBackendCandidate(
                providerID: "fake",
                profileID: profile.id,
                displayName: profile.displayName,
                availability: .available
            ),
            host: host,
            connectionManager: manager
        )

        #expect(descriptor.workspace.workspaceID == "created-new-session")
        #expect(await provider.createdWorkspaceCount == 1)
    }

    @Test("Catalog 枚举全部启用 profile 并按显式候选打开")
    func catalogsAreProfileScoped() async throws {
        let host = Host(id: "host-1", name: "Linux", address: "linux.local", username: "tester")
        let first = TerminalBackendProfile(
            id: "profile-1",
            hostID: host.id,
            providerID: "fake",
            providerConfigurationKey: "first",
            displayName: "First",
            isPrimary: true,
            configurationJSON: "{}",
            sortOrder: 0
        )
        let second = TerminalBackendProfile(
            id: "profile-2",
            hostID: host.id,
            providerID: "fake",
            providerConfigurationKey: "second",
            displayName: "Second",
            isPrimary: false,
            configurationJSON: "{}",
            sortOrder: 1
        )
        let provider = FakePersistentProvider()
        let backend = PersistentProviderBackend(
            registry: try PersistentTerminalProviderRegistry(providers: [provider]),
            profileRepository: InMemoryTerminalBackendProfiles(profiles: [second, first])
        )
        let manager = ConnectionManager(
            transport: MockSSHTransport(),
            platformDetector: FixedPlatformDetector()
        )

        let candidates = await backend.candidates(for: host, connectionManager: manager)
        #expect(candidates.map(\.profileID) == [first.id, second.id])
        let selected = try #require(candidates.first { $0.profileID == second.id })
        let catalog = try await backend.openCatalog(
            for: selected,
            host: host,
            connectionManager: manager
        )
        var iterator = catalog.snapshots.makeAsyncIterator()
        #expect(await iterator.next()?.profileID == second.id)
        #expect(await provider.openedCatalogProfileIDs == [second.id])
        await catalog.close()
    }
}

private final class InMemoryTerminalBackendProfiles: TerminalBackendProfileRepository, @unchecked Sendable {
    private let values: [String: TerminalBackendProfile]

    init(profiles: [TerminalBackendProfile]) {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func profiles(hostID: String, providerID: String?) throws -> [TerminalBackendProfile] {
        values.values.filter { $0.hostID == hostID && (providerID == nil || $0.providerID == providerID) }
    }

    func profile(id: String) throws -> TerminalBackendProfile? { values[id] }
    func save(_ profile: TerminalBackendProfile) throws {}
    func delete(id: String) throws {}
    func setPrimary(id: String?, hostID: String, providerID: String) throws {}
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

private actor CatalogProfileRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) { values.append(value) }
}

private struct FakePersistentProvider: PersistentTerminalCatalogProvider, Sendable {
    let descriptor: PersistentTerminalProviderDescriptor
    let descriptorForTest: PersistentAttachmentDescriptor
    let recorder: ReasonRecorder
    let workspaces: [RemoteWorkspaceSummary]
    let createdCount: WorkspaceCreateRecorder
    let catalogProfiles: CatalogProfileRecorder

    init(workspaceIDs: [String] = []) {
        descriptor = PersistentTerminalProviderDescriptor(
            id: "fake",
            displayName: "Fake",
            supportedPlatforms: [.linux],
            supportedConfigurationVersions: [1],
            supportedWorkspaceInstancePayloadVersions: [1],
            supportedAttachmentPayloadVersions: [1],
            potentialFeatures: [.readOnlyAttach]
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
        catalogProfiles = CatalogProfileRecorder()
        descriptorForTest = PersistentAttachmentDescriptor(
            providerID: "fake",
            profileID: "profile-1",
            workspace: RemoteWorkspaceRef(
                workspaceID: "workspace-1",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )
        recorder = ReasonRecorder()
    }

    var lastReason: PersistentAttachmentOpenReason? {
        get async { await recorder.value }
    }

    func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
        .init(state: .available, effectiveFeatures: [.readOnlyAttach])
    }

    func listWorkspaces(in context: PersistentTerminalContext) async throws -> [RemoteWorkspaceSummary] { workspaces }

    func createWorkspace(_ request: CreateWorkspaceRequest, in context: PersistentTerminalContext) async throws -> RemoteWorkspaceRef {
        await createdCount.increment()
        return RemoteWorkspaceRef(
            workspaceID: "created-\(request.name ?? "default")",
            instancePayloadVersion: 1,
            providerInstancePayload: Data()
        )
    }

    func renameWorkspace(_ workspace: RemoteWorkspaceRef, to newName: String, in context: PersistentTerminalContext) async throws {
        throw PersistentTerminalError.unsupportedFeature(providerID: descriptor.id, feature: "rename")
    }

    func destroyWorkspace(_ workspace: RemoteWorkspaceRef, in context: PersistentTerminalContext) async throws {
        throw PersistentTerminalError.unsupportedFeature(providerID: descriptor.id, feature: "destroy")
    }

    func makeAttachmentDescriptor(to workspace: RemoteWorkspaceRef, in context: PersistentTerminalContext) throws -> PersistentAttachmentDescriptor {
        PersistentAttachmentDescriptor(
            providerID: descriptor.id,
            profileID: context.backendProfile.id,
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

    var openedCatalogProfileIDs: [String] {
        get async { await catalogProfiles.values }
    }

    func openCatalog(
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalCatalogAttachment {
        await catalogProfiles.append(context.backendProfile.id)
        return FakeCatalogAttachment(profileID: context.backendProfile.id)
    }

    func openAttachment(
        _ descriptor: PersistentAttachmentDescriptor,
        reason: PersistentAttachmentOpenReason,
        terminalSize: TermSize,
        in context: PersistentTerminalContext
    ) async throws -> any PersistentTerminalAttachment {
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

    init(profileID: String) {
        (snapshots, continuation) = AsyncStream.makeStream()
        let observedAt = Date()
        continuation.yield(PersistentWorkspaceCatalogSnapshot(
            providerID: "fake",
            profileID: profileID,
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
