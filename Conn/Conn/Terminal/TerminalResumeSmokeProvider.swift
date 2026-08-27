#if DEBUG
    import ConnKit
    import ConnMultiplexer
    import ConnSSH
    import Foundation

    /// Deterministic persistent provider used only by the terminal restoration XCUITest.
    struct TerminalResumeSmokeProvider: PersistentTerminalProvider, Sendable {
        private let state = TerminalResumeSmokeState()
        let descriptor = PersistentTerminalProviderDescriptor(
            id: "tmux",
            displayName: "tmux",
            supportedPlatforms: [.linux],
            supportedConfigurationVersions: [1],
            supportedWorkspaceInstancePayloadVersions: [1],
            supportedAttachmentPayloadVersions: [1],
            potentialFeatures: []
        )
        let defaultConfiguration = PersistentTerminalConfiguration(
            providerID: "tmux",
            configurationKey: "smoke",
            payloadVersion: 1,
            providerPayload: Data()
        )

        var attachmentDescriptor: PersistentAttachmentDescriptor {
            PersistentAttachmentDescriptor(
                providerID: descriptor.id,
                configuration: defaultConfiguration,
                workspace: RemoteWorkspaceRef(
                    workspaceID: "$smoke-resume",
                    instancePayloadVersion: 1,
                    providerInstancePayload: Data()
                ),
                payloadVersion: 1,
                providerPayload: Data()
            )
        }

        func probe(in context: PersistentTerminalContext) async throws -> PersistentTerminalAvailability {
            .init(state: .available)
        }

        func listWorkspaces(
            in context: PersistentTerminalContext
        ) async throws -> [RemoteWorkspaceSummary] {
            if let workspace = state.createdWorkspace {
                return [workspace]
            }
            return []
        }

        func createWorkspace(
            _ request: CreateWorkspaceRequest,
            in context: PersistentTerminalContext
        ) async throws -> RemoteWorkspaceSummary {
            let workspace = RemoteWorkspaceSummary(
                workspace: .init(
                    workspaceID: "$smoke-replacement",
                    instancePayloadVersion: 1,
                    providerInstancePayload: Data()
                ),
                name: request.name ?? "saved-session",
                occupancy: .init(
                    affectedAttachmentCount: nil,
                    observedAt: .now,
                    freshness: .fresh
                )
            )
            state.createdWorkspace = workspace
            return workspace
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
                configuration: defaultConfiguration,
                workspace: workspace,
                payloadVersion: 1,
                providerPayload: Data()
            )
        }

        func openAttachment(
            _ descriptor: PersistentAttachmentDescriptor,
            reason: PersistentAttachmentOpenReason,
            terminalSize: TermSize,
            in context: PersistentTerminalContext
        ) async throws -> any PersistentTerminalAttachment {
            if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_RESUME_MISSING"] != nil,
               state.createdWorkspace == nil {
                throw PersistentTerminalError.remoteObjectMissing
            }
            return TerminalResumeSmokeAttachment(descriptor: descriptor)
        }
    }

    private final class TerminalResumeSmokeState: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: RemoteWorkspaceSummary?

        var createdWorkspace: RemoteWorkspaceSummary? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private final class TerminalResumeSmokeAttachment:
        PersistentTerminalAttachment,
        @unchecked Sendable {
        let descriptor: PersistentAttachmentDescriptor
        let presentation: PersistentAttachmentPresentation
        private let channel = TerminalResumeSmokeChannel()

        init(descriptor: PersistentAttachmentDescriptor) {
            self.descriptor = descriptor
            presentation = .byteTerminal(channel)
        }

        func close() async {
            await channel.close()
        }
    }

    private final class TerminalResumeSmokeChannel: ShellChannel, @unchecked Sendable {
        let output: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            (output, continuation) = AsyncThrowingStream.makeStream()
            continuation.yield(Data("restored tmux session\n".utf8))
        }

        func write(_ bytes: Data) async throws {}
        func resize(_ size: TermSize) async throws {}
        func close() async {
            continuation.finish()
        }
    }
#endif
