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

    @MainActor
    enum TerminalZellijQuickActionSmokeSupport {
        static func install(in store: TerminalSessionStore, tabID: String) {
            guard let tab = store.tab(id: tabID), tab.persistentAttachment == nil else { return }
            let attachment = TerminalZellijQuickActionSmokeAttachment(generation: tab.generation)
            store.replaceSession(
                tabID,
                session: tab.session,
                generation: tab.generation,
                status: tab.status,
                persistentAttachment: attachment
            )
        }
    }

    private final class TerminalZellijQuickActionSmokeAttachment:
        PersistentTerminalInteractiveAttachment,
        @unchecked Sendable {
        let descriptor = PersistentAttachmentDescriptor(
            providerID: "zellij",
            configuration: PersistentTerminalConfiguration(
                providerID: "zellij",
                configurationKey: "smoke",
                payloadVersion: 1,
                providerPayload: Data()
            ),
            workspace: RemoteWorkspaceRef(
                workspaceID: "smoke",
                instancePayloadVersion: 1,
                providerInstancePayload: Data()
            ),
            payloadVersion: 1,
            providerPayload: Data()
        )
        let presentation: PersistentAttachmentPresentation
        let interaction: any PersistentTerminalInteractionFacet

        private let channel = TerminalTmuxQuickActionSmokeChannel()
        private let smokeInteraction: TerminalZellijQuickActionSmokeInteraction

        init(generation: UInt64) {
            smokeInteraction = TerminalZellijQuickActionSmokeInteraction(generation: generation)
            interaction = smokeInteraction
            presentation = .byteTerminal(channel)
        }

        func close() async {
            await smokeInteraction.close()
            await channel.close()
        }
    }

    private actor TerminalZellijQuickActionSmokeInteraction:
        PersistentTerminalInteractionFacet {
        nonisolated let states: AsyncStream<PersistentTerminalInteractionState>
        private let continuation: AsyncStream<PersistentTerminalInteractionState>.Continuation
        private var state: PersistentTerminalInteractionState

        init(generation: UInt64) {
            state = PersistentTerminalInteractionState(
                target: PersistentTerminalInteractionTarget(
                    providerID: "zellij",
                    workspaceID: "smoke",
                    targetID: "smoke"
                ),
                workspaceName: "smoke",
                attachmentGeneration: generation,
                revision: 0,
                freshness: .snapshot,
                isAlternateBuffer: nil,
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
                id: "zellij",
                title: "Zellij",
                sections: [
                    .init(id: "session", titleKey: "Session", actions: [
                        action(
                            "zellij.session.close",
                            "关闭 Session",
                            "xmark.circle",
                            confirmationTitleKey: "关闭当前 Session？"
                        )
                    ]),
                    .init(id: "tab", titleKey: "Tab", actions: [
                        action("zellij.tab.new", "新建 Tab", "plus.rectangle"),
                        action("zellij.tab.next", "下一个 Tab", "arrow.right.to.line")
                    ]),
                    .init(id: "pane", titleKey: "Pane", actions: [
                        action(
                            "zellij.pane.split-right",
                            "向右分屏",
                            "rectangle.split.2x1"
                        ),
                        action(
                            "zellij.pane.close",
                            "关闭 Pane",
                            "xmark.square",
                            confirmationTitleKey: "关闭当前 Pane？"
                        )
                    ]),
                    .init(id: "layout-mode", titleKey: "布局与模式", actions: [
                        action("zellij.layout.next", "下一个布局", "arrow.right"),
                        action("zellij.mode.lock", "锁定输入", "lock")
                    ])
                ]
            )
        }

        func resolveState() -> PersistentTerminalInteractionState {
            state
        }

        func captureHistory(
            _ request: PersistentTerminalHistoryRequest
        ) throws -> PersistentTerminalHistorySnapshot {
            throw PersistentTerminalInteractionError.unavailable
        }

        func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) throws {
            throw PersistentTerminalInteractionError.unsupportedMode
        }

        func performQuickAction(
            _ request: PersistentTerminalQuickActionRequest
        ) throws -> PersistentTerminalQuickActionOutcome {
            guard request.target == state.target else {
                throw PersistentTerminalInteractionError.targetMismatch
            }
            return .performed
        }

        func close() {
            continuation.finish()
        }

        private func action(
            _ id: String,
            _ titleKey: String,
            _ systemImageName: String,
            confirmationTitleKey: String? = nil
        ) -> PersistentTerminalQuickActionDescriptor {
            .init(
                id: id,
                titleKey: titleKey,
                systemImageName: systemImageName,
                confirmation: confirmationTitleKey.map(
                    PersistentTerminalActionConfirmation.init(titleKey:)
                )
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
        private let exposesHistory: Bool
        private var controlScrollCount = 0

        init(generation: UInt64) {
            let historyEnabled = ProcessInfo.processInfo.environment["CONN_SMOKE_TMUX_HISTORY"] != nil
            exposesHistory = historyEnabled
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
                historyAvailable: historyEnabled,
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
                                id: "tmux.session.list",
                                titleKey: "Session 列表",
                                systemImageName: "rectangle.stack"
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.session.rename",
                                titleKey: "重命名 Session",
                                systemImageName: "pencil",
                                textInput: PersistentTerminalQuickActionTextInput(
                                    titleKey: "重命名 Session",
                                    placeholderKey: "Session 名称"
                                ),
                                completionEffect: .workspaceRenamed
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.session.close",
                                titleKey: "关闭 Session",
                                systemImageName: "xmark.circle",
                                confirmation: PersistentTerminalActionConfirmation(
                                    titleKey: "关闭当前 Session？"
                                )
                            )
                        ]
                    ),
                    PersistentTerminalQuickActionSection(
                        id: "window",
                        titleKey: "Window",
                        actions: [
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.window.list",
                                titleKey: "Window 列表",
                                systemImageName: "rectangle.on.rectangle"
                            ),
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
                    ),
                    PersistentTerminalQuickActionSection(
                        id: "pane",
                        titleKey: "Pane",
                        actions: [
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.pane.split-horizontal",
                                titleKey: "左右分屏",
                                systemImageName: "rectangle.split.2x1"
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.pane.split-vertical",
                                titleKey: "上下分屏",
                                systemImageName: "rectangle.split.1x2"
                            ),
                            PersistentTerminalQuickActionDescriptor(
                                id: "tmux.pane.close",
                                titleKey: "关闭 Pane",
                                systemImageName: "xmark.rectangle",
                                confirmation: PersistentTerminalActionConfirmation(
                                    titleKey: "关闭当前 Pane？"
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
            guard exposesHistory else {
                throw PersistentTerminalInteractionError.unavailable
            }
            guard request.target == state.target else {
                throw PersistentTerminalInteractionError.targetMismatch
            }
            guard request.attachmentGeneration == state.attachmentGeneration else {
                throw PersistentTerminalInteractionError.staleAttachmentGeneration
            }

            // Reproduce the real Control Mode race: unrelated observations can advance
            // while capture-pane is in flight without changing the active route.
            advanceStateRevision()
            try await Task.sleep(for: .milliseconds(180))
            let text = "tmux history smoke"
            let line = PersistentTerminalHistoryLine(
                text: text,
                cellColumnToUTF16Offset: Array(0 ... text.utf16.count),
                isWrapped: false
            )
            return PersistentTerminalHistorySnapshot(
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                stateRevision: state.revision,
                capturedAt: .now,
                lines: [line],
                visibleLineRange: 0 ..< 1,
                isTruncated: false,
                byteCount: text.utf8.count
            )
        }

        func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) async throws {
            guard request.target == state.target else {
                throw PersistentTerminalInteractionError.targetMismatch
            }
            guard request.attachmentGeneration == state.attachmentGeneration else {
                throw PersistentTerminalInteractionError.staleAttachmentGeneration
            }
            controlScrollCount += 1
            guard controlScrollCount == 1 else {
                throw PersistentTerminalError.controlModeUnavailable
            }
            state = PersistentTerminalInteractionState(
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                revision: state.revision + 1,
                freshness: .live,
                isAlternateBuffer: false,
                modeCapability: .scrollable,
                providerModeID: "copy-mode",
                historyAvailable: state.historyAvailable,
                observedAt: .now
            )
            continuation.yield(state)
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
            guard request.resolution == .currentAtExecution
                || request.expectedStateRevision == state.revision
            else {
                throw PersistentTerminalInteractionError.staleStateRevision
            }
            if request.actionID == "tmux.window.next"
                || request.actionID == "tmux.window.previous" {
                return .unavailable
            }
            if request.actionID == "tmux.session.list"
                || request.actionID == "tmux.window.list" {
                return .performed
            }
            if request.actionID == "tmux.pane.close" {
                return ProcessInfo.processInfo.environment[
                    "CONN_SMOKE_TMUX_LAST_WORKSPACE"
                ] == nil ? .performed : .workspaceClosed
            }
            if request.actionID == "tmux.session.close" {
                guard request.confirmsDestructiveAction else {
                    throw PersistentTerminalInteractionError.unavailable
                }
                return .workspaceClosed
            }
            if request.actionID == "tmux.window.new"
                || request.actionID == "tmux.pane.split-horizontal"
                || request.actionID == "tmux.pane.split-vertical" {
                try await Task.sleep(for: .milliseconds(120))
                advanceStateRevision()
                return .performed
            }
            guard request.actionID == "tmux.session.rename" else {
                throw PersistentTerminalInteractionError.unsupportedQuickAction(request.actionID)
            }
            guard request.argument?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw PersistentTerminalInteractionError.unavailable
            }

            advanceStateRevision()
            return .performed
        }

        private func advanceStateRevision() {
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
        }

        func close() {
            continuation.finish()
        }
    }
#endif
