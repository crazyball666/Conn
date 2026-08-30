#if DEBUG
    import ConnKit
    import ConnMultiplexer
    import ConnTerminal
    import Foundation
    import SwiftUI

    /// Deterministic UI fixture for the Session picker layout.
    /// This is compiled only for development and UI acceptance; production uses the live initializer.
    struct NewTerminalSheetSmokeView: View {
        let terminalSessions: TerminalSessionCoordinator

        private static let host = ConnKit.Host(
            id: "smoke-host",
            name: "Demo Host",
            address: "demo.example.com",
            username: "root"
        )

        private static let tmuxOption = PersistentBackendOption(
            providerID: "tmux",
            displayName: "tmux",
            configuration: PersistentTerminalConfiguration(
                providerID: "tmux",
                configurationKey: "smoke-tmux",
                payloadVersion: 1,
                providerPayload: Data()
            )
        )

        private static let zellijOption = PersistentBackendOption(
            providerID: "zellij",
            displayName: "Zellij",
            configuration: PersistentTerminalConfiguration(
                providerID: "zellij",
                configurationKey: "smoke-zellij",
                payloadVersion: 1,
                providerPayload: Data()
            )
        )

        var body: some View {
            NewTerminalSheet(
                fixedHost: Self.host,
                operations: operations,
                onCompleted: { _ in }
            )
        }

        private var operations: NewTerminalFlowModel.Operations {
            NewTerminalFlowModel.Operations(
                loadHosts: { [Self.host] },
                persistentBackendOptions: { [Self.tmuxOption, Self.zellijOption] },
                persistentWorkspaceOptions: { option, _ in
                    [Self.workspace(for: option)]
                },
                makeExistingBackend: { option, workspace, _ in
                    PersistentTerminalLaunch(
                        descriptor: Self.descriptor(option: option, workspace: workspace.workspace),
                        workspaceName: workspace.name
                    )
                },
                makeCreateBackend: { option, selection, _ in
                    let name = selection.name.flatMap { $0.isEmpty ? nil : $0 } ?? "new-session"
                    let workspace = RemoteWorkspaceRef(
                        workspaceID: "$\(name)",
                        instancePayloadVersion: 1,
                        providerInstancePayload: Data()
                    )
                    return PersistentTerminalLaunch(
                        descriptor: Self.descriptor(option: option, workspace: workspace),
                        workspaceName: name
                    )
                },
                beginLaunchAttempt: { terminalSessions.beginLaunchAttempt() },
                prepareLaunch: { _, _ in .success(()) },
                commitLaunch: { _ in .success("smoke-tab") },
                cancelLaunch: { _ in }
            )
        }

        private static func descriptor(
            option: PersistentBackendOption,
            workspace: RemoteWorkspaceRef
        ) -> PersistentAttachmentDescriptor {
            PersistentAttachmentDescriptor(
                providerID: option.providerID,
                configuration: option.configuration,
                workspace: workspace,
                payloadVersion: 1,
                providerPayload: Data()
            )
        }

        private static func workspace(
            for option: PersistentBackendOption
        ) -> RemoteWorkspaceSummary {
            RemoteWorkspaceSummary(
                workspace: RemoteWorkspaceRef(
                    workspaceID: "\(option.providerID)-demo-session",
                    instancePayloadVersion: 1,
                    providerInstancePayload: Data()
                ),
                name: "demo-session",
                occupancy: RemoteWorkspaceOccupancy(
                    affectedAttachmentCount: nil,
                    observedAt: .now,
                    freshness: .fresh
                )
            )
        }
    }
#endif
