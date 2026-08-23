#if DEBUG
    import ConnMultiplexer
    import ConnSSH
    import ConnTerminal
    import Foundation

    /// Deterministic tmux interaction used only by terminal UI tests. The terminal keeps its
    /// real smoke PTY while this attachment supplies provider metadata and validates the
    /// provider-neutral quick-action request produced by the UI.
    @MainActor
    enum TerminalTmuxQuickActionSmokeSupport {
        static func install(in store: TerminalSessionStore, tabID: String) {
            guard let tab = store.tab(id: tabID), tab.persistentAttachment == nil else { return }
            let attachment = TerminalTmuxQuickActionSmokeAttachment(generation: tab.generation)
            store.replaceSession(
                tabID,
                session: tab.session,
                generation: tab.generation,
                status: tab.status,
                persistentAttachment: attachment
            )
        }
    }

    private final class TerminalTmuxQuickActionSmokeAttachment:
        PersistentTerminalInteractiveAttachment,
        @unchecked Sendable {
        let descriptor = PersistentAttachmentDescriptor(
            providerID: "tmux",
            configuration: PersistentTerminalConfiguration(
                providerID: "tmux",
                configurationKey: "smoke",
                payloadVersion: 1,
                providerPayload: Data()
            ),
            workspace: RemoteWorkspaceRef(
                workspaceID: "$smoke",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )
        let presentation: PersistentAttachmentPresentation
        let interaction: any PersistentTerminalInteractionFacet

        private let channel = TerminalTmuxQuickActionSmokeChannel()
        private let smokeInteraction: TerminalTmuxQuickActionSmokeInteraction

        init(generation: UInt64) {
            smokeInteraction = TerminalTmuxQuickActionSmokeInteraction(generation: generation)
            interaction = smokeInteraction
            presentation = .byteTerminal(channel)
        }

        func close() async {
            await smokeInteraction.close()
            await channel.close()
        }
    }

    private final class TerminalTmuxQuickActionSmokeChannel: ShellChannel, @unchecked Sendable {
        let output = AsyncThrowingStream<Data, Error> { continuation in
            continuation.finish()
        }

        func write(_ bytes: Data) async throws {}
        func resize(_ size: TermSize) async throws {}
        func close() async {}
    }

    private actor TerminalTmuxQuickActionSmokeInteraction: PersistentTerminalInteractionFacet {
        nonisolated let states: AsyncStream<PersistentTerminalInteractionState>

        private let continuation: AsyncStream<PersistentTerminalInteractionState>.Continuation
        private var state: PersistentTerminalInteractionState

        init(generation: UInt64) {
            let target = PersistentTerminalInteractionTarget(
                providerID: "tmux",
                workspaceID: "$smoke",
                targetID: "%smoke"
            )
            state = PersistentTerminalInteractionState(
                target: target,
                attachmentGeneration: generation,
                revision: 0,
                freshness: .live,
                isAlternateBuffer: false,
                modeCapability: .none,
                historyAvailable: false,
                observedAt: .now
            )
            let stream = PersistentTerminalInteractionStreams.makeStateStream()
            states = stream.stream
            continuation = stream.continuation
            continuation.yield(state)
        }

        var quickActionGroup: PersistentTerminalQuickActionGroup? {
            PersistentTerminalQuickActionGroup(
                id: "tmux",
                title: "tmux",
                sections: [
                    PersistentTerminalQuickActionSection(
                        id: "session",
                        titleKey: "Session",
                        actions: [
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.session.rename",
                                titleKey: "重命名 Session",
                                systemImageName: "pencil",
                                textInput: PersistentTerminalQuickActionTextInput(
                                    titleKey: "重命名 Session",
                                    placeholderKey: "Session 名称"
                                ),
                                completionEffect: .workspaceRenamed
                            )
                        ]
                    ),
                    PersistentTerminalQuickActionSection(
                        id: "window",
                        titleKey: "Window",
                        actions: [
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.window.new",
                                titleKey: "新建 Window",
                                systemImageName: "plus.rectangle"
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.window.previous",
                                titleKey: "上一个 Window",
                                systemImageName: "arrow.left.to.line"
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.window.next",
                                titleKey: "下一个 Window",
                                systemImageName: "arrow.right.to.line"
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.window.rename",
                                titleKey: "重命名 Window",
                                systemImageName: "pencil"
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.window.close",
                                titleKey: "关闭 Window",
                                systemImageName: "xmark.rectangle",
                                confirmation: PersistentTerminalActionConfirmation(
                                    titleKey: "关闭当前 Window？"
                                )
                            )
                        ]
                    )
                ],
                swipeActions: [
                    PersistentTerminalSwipeActionDescriptor(
                        direction: .left,
                        actionID: "tmux.window.next",
                        successNoticeKey: "已切换到下一个 Window",
                        unavailableNoticeKey: "没有可切换的 Window"
                    ),
                    PersistentTerminalSwipeActionDescriptor(
                        direction: .right,
                        actionID: "tmux.window.previous",
                        successNoticeKey: "已切换到上一个 Window",
                        unavailableNoticeKey: "没有可切换的 Window"
                    )
                ]
            )
        }

        func resolveState() async throws -> PersistentTerminalInteractionState {
            state
        }

        func captureHistory(
            _ request: PersistentTerminalHistoryRequest
        ) async throws -> PersistentTerminalHistorySnapshot {
            throw PersistentTerminalInteractionError.unavailable
        }

        func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) async throws {
            throw PersistentTerminalInteractionError.unsupportedMode
        }

        func performQuickAction(
            _ request: PersistentTerminalQuickActionRequest
        ) async throws -> PersistentTerminalQuickActionOutcome {
            guard request.target == state.target else {
                throw PersistentTerminalInteractionError.targetMismatch
            }
            guard request.attachmentGeneration == state.attachmentGeneration else {
                throw PersistentTerminalInteractionError.staleAttachmentGeneration
            }
            guard request.expectedStateRevision == state.revision else {
                throw PersistentTerminalInteractionError.staleStateRevision
            }
            if request.actionID == "tmux.window.next"
                || request.actionID == "tmux.window.previous" {
                return .unavailable
            }
            guard request.actionID == "tmux.session.rename" else {
                throw PersistentTerminalInteractionError.unsupportedQuickAction(request.actionID)
            }
            guard request.argument?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw PersistentTerminalInteractionError.unavailable
            }

            state = PersistentTerminalInteractionState(
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                revision: state.revision + 1,
                freshness: .live,
                isAlternateBuffer: state.isAlternateBuffer,
                modeCapability: state.modeCapability,
                providerModeID: state.providerModeID,
                historyAvailable: state.historyAvailable,
                observedAt: .now
            )
            continuation.yield(state)
            return .performed
        }

        func close() {
            continuation.finish()
        }
    }
#endif
