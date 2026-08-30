import Foundation

/// Zellij quick actions are intentionally key-sequence macros. Unlike tmux, Zellij does not
/// expose a control protocol that can provide a verified topology graph to this attachment.
/// Keeping the catalog provider-owned lets the terminal UI remain provider-neutral.
package enum ZellijTerminalQuickAction: String, CaseIterable, Sendable {
    case closeSession = "zellij.session.close"
    case newTab = "zellij.tab.new"
    case previousTab = "zellij.tab.previous"
    case nextTab = "zellij.tab.next"
    case renameTab = "zellij.tab.rename"
    case closeTab = "zellij.tab.close"
    case syncTab = "zellij.tab.sync"
    case newPane = "zellij.pane.new"
    case splitPaneDown = "zellij.pane.split-down"
    case splitPaneRight = "zellij.pane.split-right"
    case switchPane = "zellij.pane.switch"
    case fullscreenPane = "zellij.pane.fullscreen"
    case floatingPanes = "zellij.pane.floating"
    case renamePane = "zellij.pane.rename"
    case closePane = "zellij.pane.close"
    case previousLayout = "zellij.layout.previous"
    case nextLayout = "zellij.layout.next"
    case increasePaneSize = "zellij.pane.increase-size"
    case decreasePaneSize = "zellij.pane.decrease-size"
    case scrollMode = "zellij.mode.scroll"
    case searchMode = "zellij.mode.search"
    case lockInput = "zellij.mode.lock"

    /// Default Zellij key bindings. A complete sequence is sent through the attachment's
    /// shared serialized writer as one Data value so keyboard input cannot split a macro.
    package var macroBytes: [UInt8] {
        switch self {
        case .closeSession: [0x11]
        case .newTab: [0x14, 0x6E]
        case .previousTab: [0x14, 0x68]
        case .nextTab: [0x14, 0x6C]
        case .renameTab: [0x14, 0x72]
        case .closeTab: [0x14, 0x78]
        case .syncTab: [0x14, 0x73]
        case .newPane: [0x10, 0x6E]
        case .splitPaneDown: [0x10, 0x64]
        case .splitPaneRight: [0x10, 0x72]
        case .switchPane: [0x10, 0x70]
        case .fullscreenPane: [0x10, 0x66]
        case .floatingPanes: [0x1B, 0x66]
        case .renamePane: [0x10, 0x63]
        case .closePane: [0x10, 0x78]
        case .previousLayout: [0x1B, 0x5B]
        case .nextLayout: [0x1B, 0x5D]
        case .increasePaneSize: [0x1B, 0x3D]
        case .decreasePaneSize: [0x1B, 0x2D]
        case .scrollMode: [0x13]
        case .searchMode: [0x13, 0x73]
        case .lockInput: [0x07]
        }
    }

    package var isDestructive: Bool {
        self == .closeSession || self == .closeTab || self == .closePane
    }
}

package enum ZellijInteractionCatalog {
    package static let group = PersistentTerminalQuickActionGroup(
        id: ZellijProvider.providerID,
        title: "Zellij",
        sections: [
            .init(id: "session", titleKey: "Session", actions: [
                descriptor(
                    .closeSession,
                    "关闭 Session",
                    "xmark.circle",
                    confirmation: .init(titleKey: "关闭当前 Session？")
                )
            ]),
            .init(id: "tab", titleKey: "Tab", actions: [
                descriptor(.newTab, "新建 Tab", "plus.rectangle"),
                descriptor(.previousTab, "上一个 Tab", "arrow.left.to.line"),
                descriptor(.nextTab, "下一个 Tab", "arrow.right.to.line"),
                descriptor(.renameTab, "重命名 Tab", "pencil"),
                descriptor(
                    .closeTab,
                    "关闭 Tab",
                    "xmark.rectangle",
                    confirmation: .init(titleKey: "关闭当前 Tab？")
                ),
                descriptor(.syncTab, "同步 Tab", "arrow.triangle.2.circlepath")
            ]),
            .init(id: "pane", titleKey: "Pane", actions: [
                descriptor(.newPane, "新建 Pane", "rectangle.badge.plus"),
                descriptor(.splitPaneDown, "向下分屏", "rectangle.split.1x2"),
                descriptor(.splitPaneRight, "向右分屏", "rectangle.split.2x1"),
                descriptor(.switchPane, "切换 Pane", "rectangle.2.swap"),
                descriptor(
                    .fullscreenPane,
                    "Pane 全屏",
                    "arrow.up.left.and.arrow.down.right"
                ),
                descriptor(.floatingPanes, "浮动 Pane", "rectangle.on.rectangle"),
                descriptor(.renamePane, "重命名 Pane", "pencil"),
                descriptor(
                    .closePane,
                    "关闭 Pane",
                    "xmark.square",
                    confirmation: .init(titleKey: "关闭当前 Pane？")
                )
            ]),
            .init(id: "layout-mode", titleKey: "布局与模式", actions: [
                descriptor(.previousLayout, "上一个布局", "arrow.left"),
                descriptor(.nextLayout, "下一个布局", "arrow.right"),
                descriptor(.increasePaneSize, "增大 Pane", "plus.magnifyingglass"),
                descriptor(.decreasePaneSize, "缩小 Pane", "minus.magnifyingglass"),
                descriptor(.scrollMode, "滚动模式", "scroll"),
                descriptor(.searchMode, "搜索模式", "magnifyingglass"),
                descriptor(.lockInput, "锁定输入", "lock")
            ])
        ]
    )

    private static func descriptor(
        _ action: ZellijTerminalQuickAction,
        _ titleKey: String,
        _ systemImageName: String,
        confirmation: PersistentTerminalActionConfirmation? = nil
    ) -> PersistentTerminalQuickActionDescriptor {
        .init(
            id: action.rawValue,
            titleKey: titleKey,
            systemImageName: systemImageName,
            confirmation: confirmation
        )
    }
}

package actor ZellijInteractionFacet: PersistentTerminalInteractionFacet {
    package nonisolated let states: AsyncStream<PersistentTerminalInteractionState>
    private nonisolated let continuation:
        AsyncStream<PersistentTerminalInteractionState>.Continuation
    private let channel: ZellijProcessShellChannel
    private let target: PersistentTerminalInteractionTarget
    private let workspaceName: String
    private let attachmentGeneration: UInt64
    private let processExitTimeout: Duration
    private var revision: UInt64 = 0
    private var closed = false

    package init(
        descriptor: PersistentAttachmentDescriptor,
        channel: ZellijProcessShellChannel,
        attachmentGeneration: UInt64,
        processExitTimeout: Duration
    ) {
        self.channel = channel
        self.attachmentGeneration = attachmentGeneration
        self.processExitTimeout = processExitTimeout
        workspaceName = descriptor.workspace.workspaceID
        target = PersistentTerminalInteractionTarget(
            providerID: descriptor.providerID,
            workspaceID: descriptor.workspace.workspaceID,
            targetID: descriptor.workspace.workspaceID
        )
        let stream = PersistentTerminalInteractionStreams.makeStateStream()
        states = stream.stream
        continuation = stream.continuation
    }

    public var quickActionGroup: PersistentTerminalQuickActionGroup? {
        get async { closed ? nil : ZellijInteractionCatalog.group }
    }

    public func resolveState() throws -> PersistentTerminalInteractionState {
        guard !closed else { throw PersistentTerminalInteractionError.unavailable }
        let state = currentState()
        continuation.yield(state)
        return state
    }

    public func captureHistory(
        _ request: PersistentTerminalHistoryRequest
    ) throws -> PersistentTerminalHistorySnapshot {
        try validateRoute(request.target, generation: request.attachmentGeneration)
        throw PersistentTerminalInteractionError.unavailable
    }

    public func scrollProviderMode(_ request: PersistentTerminalModeScrollRequest) throws {
        try validateRoute(request.target, generation: request.attachmentGeneration)
        throw PersistentTerminalInteractionError.unsupportedMode
    }

    public func performQuickAction(
        _ request: PersistentTerminalQuickActionRequest
    ) async throws -> PersistentTerminalQuickActionOutcome {
        guard !closed else { throw PersistentTerminalInteractionError.unavailable }
        try validateRoute(request.target, generation: request.attachmentGeneration)
        if request.resolution == .exactObservedState,
           request.expectedStateRevision != revision {
            throw PersistentTerminalInteractionError.staleStateRevision
        }
        guard (1 ... PersistentTerminalQuickActionRequest.maximumRepeatCount)
            .contains(request.repeatCount)
        else {
            throw PersistentTerminalInteractionError.invalidQuickActionRepeatCount(
                request.repeatCount
            )
        }
        guard let action = ZellijTerminalQuickAction(rawValue: request.actionID) else {
            throw PersistentTerminalInteractionError.unsupportedQuickAction(request.actionID)
        }
        guard !action.isDestructive || request.confirmsDestructiveAction else {
            throw PersistentTerminalInteractionError.unavailable
        }

        let bytes = Data(Array(repeating: action.macroBytes, count: request.repeatCount).joined())
        try await channel.write(bytes)

        if action == .closeSession {
            guard await processDidExitBeforeTimeout() else {
                throw PersistentTerminalInteractionError.unavailable
            }
            closed = true
            continuation.finish()
            return .workspaceClosed
        }

        revision &+= 1
        continuation.yield(currentState())
        return .performed
    }

    package func close() {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }

    private func currentState() -> PersistentTerminalInteractionState {
        PersistentTerminalInteractionState(
            target: target,
            workspaceName: workspaceName,
            attachmentGeneration: attachmentGeneration,
            revision: revision,
            freshness: .snapshot,
            isAlternateBuffer: nil,
            modeCapability: .none,
            historyAvailable: false,
            observedAt: Date()
        )
    }

    private func validateRoute(
        _ requestedTarget: PersistentTerminalInteractionTarget,
        generation requestedGeneration: UInt64
    ) throws {
        guard requestedTarget == target else {
            throw PersistentTerminalInteractionError.targetMismatch
        }
        guard requestedGeneration == attachmentGeneration else {
            throw PersistentTerminalInteractionError.staleAttachmentGeneration
        }
    }

    private func processDidExitBeforeTimeout() async -> Bool {
        let race = ZellijProcessExitRace()
        let processTask = Task { [channel] in
            do {
                _ = try await channel.waitForProcessExit()
                await race.resolve(true)
            } catch {
                await race.resolve(false)
            }
        }
        let timeoutTask = Task { [processExitTimeout] in
            do {
                try await Task.sleep(for: processExitTimeout)
                await race.resolve(false)
            } catch {
                // The winning branch cancels this task.
            }
        }
        let didExit = await race.value()
        processTask.cancel()
        timeoutTask.cancel()
        return didExit
    }
}

private actor ZellijProcessExitRace {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func resolve(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func value() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
