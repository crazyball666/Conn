import ConnSSH
import Foundation

/// Zellij quick actions use its session-targeted CLI so the attached pane never receives
/// provider mode prefixes or trailing command characters. Keeping the catalog provider-owned
/// lets the terminal UI remain provider-neutral.
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

    package enum Execution: Sendable, Equatable {
        case command([String])
        case deleteSession
    }

    /// Provider actions use Zellij's deterministic CLI control surface, including actions that
    /// change the attached client's input mode.
    package var execution: Execution {
        switch self {
        case .closeSession: .deleteSession
        case .newTab: .command(["new-tab"])
        case .previousTab: .command(["go-to-previous-tab"])
        case .nextTab: .command(["go-to-next-tab"])
        case .renameTab: .command(["rename-tab"])
        case .closeTab: .command(["close-tab"])
        case .syncTab: .command(["toggle-active-sync-tab"])
        case .newPane: .command(["new-pane"])
        case .splitPaneDown: .command(["new-pane", "--direction", "down"])
        case .splitPaneRight: .command(["new-pane", "--direction", "right"])
        case .switchPane: .command(["focus-next-pane"])
        case .fullscreenPane: .command(["toggle-fullscreen"])
        case .floatingPanes: .command(["toggle-floating-panes"])
        case .renamePane: .command(["rename-pane"])
        case .closePane: .command(["close-pane"])
        case .previousLayout: .command(["previous-swap-layout"])
        case .nextLayout: .command(["next-swap-layout"])
        case .increasePaneSize: .command(["resize", "increase"])
        case .decreasePaneSize: .command(["resize", "decrease"])
        case .scrollMode: .command(["switch-mode", "scroll"])
        case .searchMode: .command(["switch-mode", "enter-search"])
        case .lockInput: .command(["switch-mode", "locked"])
        }
    }

    package func resolvedExecution(argument: String?) throws -> Execution {
        guard self == .renameTab || self == .renamePane else { return execution }
        guard let name = argument?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { throw PersistentTerminalInteractionError.unavailable }
        guard case let .command(arguments) = execution else {
            throw PersistentTerminalInteractionError.unavailable
        }
        return .command(arguments + [name])
    }

    package var isDestructive: Bool {
        self == .closeSession || self == .closeTab || self == .closePane
    }
}

package protocol ZellijActionCommandExecuting: Sendable {
    func execute(arguments: [String], repeatCount: Int) async throws
    func deleteSession() async throws
}

package actor ZellijCLIActionExecutor: ZellijActionCommandExecuting {
    private let executable: String
    private let sessionName: ZellijSessionName
    private let session: any SSHSession

    package init(
        executable: String,
        sessionName: ZellijSessionName,
        session: any SSHSession
    ) {
        self.executable = executable
        self.sessionName = sessionName
        self.session = session
    }

    package func execute(arguments: [String], repeatCount: Int) async throws {
        let command = ([executable, "--session", sessionName.rawValue, "action"] + arguments)
            .map(POSIXShellArgument.encode)
            .joined(separator: " ")
        for _ in 0 ..< repeatCount {
            try await execute(command, fallbackError: "Zellij action failed")
        }
    }

    package func deleteSession() async throws {
        let command = [executable, "delete-session", sessionName.rawValue, "--force"]
            .map(POSIXShellArgument.encode)
            .joined(separator: " ")
        try await execute(command, fallbackError: "Zellij session deletion failed")
    }

    private func execute(_ command: String, fallbackError: String) async throws {
        let result = try await session.exec(command, timeout: .seconds(15))
        guard result.isSuccess else {
            throw PersistentTerminalError.commandRejected(
                result.stderrText.isEmpty ? fallbackError : result.stderrText
            )
        }
    }
}

package enum ZellijInteractionCatalog {
    package static let group = PersistentTerminalQuickActionGroup(
        id: ZellijProvider.providerID,
        title: "zellij",
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
                descriptor(
                    .renameTab,
                    "重命名 Tab",
                    "pencil",
                    textInput: .init(titleKey: "重命名 Tab", placeholderKey: "Tab 名称")
                ),
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
                descriptor(
                    .renamePane,
                    "重命名 Pane",
                    "pencil",
                    textInput: .init(titleKey: "重命名 Pane", placeholderKey: "Pane 名称")
                ),
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
        textInput: PersistentTerminalQuickActionTextInput? = nil,
        confirmation: PersistentTerminalActionConfirmation? = nil
    ) -> PersistentTerminalQuickActionDescriptor {
        .init(
            id: action.rawValue,
            titleKey: titleKey,
            systemImageName: systemImageName,
            textInput: textInput,
            confirmation: confirmation
        )
    }
}

package actor ZellijInteractionFacet: PersistentTerminalInteractionFacet {
    package nonisolated let states: AsyncStream<PersistentTerminalInteractionState>
    private nonisolated let continuation:
        AsyncStream<PersistentTerminalInteractionState>.Continuation
    private let channel: ZellijProcessShellChannel
    private let actionExecutor: any ZellijActionCommandExecuting
    private let target: PersistentTerminalInteractionTarget
    private let workspaceName: String
    private let attachmentGeneration: UInt64
    private let processExitTimeout: Duration
    private var revision: UInt64 = 0
    private var closed = false

    package init(
        descriptor: PersistentAttachmentDescriptor,
        channel: ZellijProcessShellChannel,
        actionExecutor: any ZellijActionCommandExecuting,
        attachmentGeneration: UInt64,
        processExitTimeout: Duration
    ) {
        self.channel = channel
        self.actionExecutor = actionExecutor
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

        switch try action.resolvedExecution(argument: request.argument) {
        case let .command(arguments):
            try await actionExecutor.execute(
                arguments: arguments,
                repeatCount: request.repeatCount
            )
        case .deleteSession:
            guard request.repeatCount == 1 else {
                throw PersistentTerminalInteractionError.invalidQuickActionRepeatCount(
                    request.repeatCount
                )
            }
            try await actionExecutor.deleteSession()
        }

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
