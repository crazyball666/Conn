import ConnKit
import ConnSSH
import Foundation
import Testing
@testable import ConnMultiplexer

@Suite("Zellij terminal interaction")
struct ZellijInteractionTests {
    @Test("快捷面板按 Zellij 原生 Session、Tab、Pane、布局与模式分组")
    func quickActionsAreZellijNative() {
        let group = ZellijInteractionCatalog.group

        #expect(group.id == ZellijProvider.providerID)
        #expect(group.title == "zellij")
        #expect(group.sections.map(\.id) == ["session", "tab", "pane", "layout-mode"])
        #expect(group.swipeActions.isEmpty)
        #expect(group.actions.map(\.id) == ZellijTerminalQuickAction.allCases.map(\.rawValue))
        #expect(!group.actions.contains { $0.id == "zellij.session.manager" })
        #expect(group.actions.first {
            $0.id == ZellijTerminalQuickAction.closeSession.rawValue
        }?.confirmation?.titleKey == "关闭当前 Session？")
        #expect(group.actions.first {
            $0.id == ZellijTerminalQuickAction.closeTab.rawValue
        }?.confirmation?.titleKey == "关闭当前 Tab？")
        #expect(group.actions.first {
            $0.id == ZellijTerminalQuickAction.closePane.rawValue
        }?.confirmation?.titleKey == "关闭当前 Pane？")
        #expect(group.actions.first {
            $0.id == ZellijTerminalQuickAction.renameTab.rawValue
        }?.textInput == .init(titleKey: "重命名 Tab", placeholderKey: "Tab 名称"))
        #expect(group.actions.first {
            $0.id == ZellijTerminalQuickAction.renamePane.rawValue
        }?.textInput == .init(titleKey: "重命名 Pane", placeholderKey: "Pane 名称"))
    }

    @Test("所有快捷操作使用 Zellij CLI，不注入模式键位")
    func quickActionsUseCLIWhereZellijProvidesActions() {
        let expected: [ZellijTerminalQuickAction: ZellijTerminalQuickAction.Execution] = [
            .closeSession: .deleteSession,
            .newTab: .command(["new-tab"]),
            .previousTab: .command(["go-to-previous-tab"]),
            .nextTab: .command(["go-to-next-tab"]),
            .renameTab: .command(["rename-tab"]),
            .closeTab: .command(["close-tab"]),
            .syncTab: .command(["toggle-active-sync-tab"]),
            .newPane: .command(["new-pane"]),
            .splitPaneDown: .command(["new-pane", "--direction", "down"]),
            .splitPaneRight: .command(["new-pane", "--direction", "right"]),
            .switchPane: .command(["focus-next-pane"]),
            .fullscreenPane: .command(["toggle-fullscreen"]),
            .floatingPanes: .command(["toggle-floating-panes"]),
            .renamePane: .command(["rename-pane"]),
            .closePane: .command(["close-pane"]),
            .previousLayout: .command(["previous-swap-layout"]),
            .nextLayout: .command(["next-swap-layout"]),
            .increasePaneSize: .command(["resize", "increase"]),
            .decreasePaneSize: .command(["resize", "decrease"]),
            .scrollMode: .command(["switch-mode", "scroll"]),
            .searchMode: .command(["switch-mode", "enter-search"]),
            .lockInput: .command(["switch-mode", "locked"])
        ]

        #expect(ZellijTerminalQuickAction.allCases.count == expected.count)
        for action in ZellijTerminalQuickAction.allCases {
            #expect(action.execution == expected[action])
        }
    }

    @Test("普通动作支持有界重复并由 CLI executor 串行执行")
    func repeatedActionUsesCLIExecutor() async throws {
        let fixture = try await ZellijInteractionFixture()
        let state = try await fixture.facet.resolveState()

        let outcome = try await fixture.facet.performQuickAction(.init(
            actionID: ZellijTerminalQuickAction.newTab.rawValue,
            target: state.target,
            attachmentGeneration: state.attachmentGeneration,
            expectedStateRevision: state.revision,
            repeatCount: 3,
            resolution: .currentAtExecution
        ))

        #expect(outcome == .performed)
        #expect(fixture.process.writes.isEmpty)
        #expect(await fixture.actionExecutor.invocations == [
            .init(arguments: ["new-tab"], repeatCount: 3)
        ])
        #expect(try await fixture.facet.resolveState().revision == state.revision + 1)
        await fixture.attachment.close()
    }

    @Test("resolveState 暴露当前终端 Pane 的工作目录")
    func resolveStateExposesWorkingDirectory() async throws {
        let fixture = try await ZellijInteractionFixture()
        let state = try await fixture.facet.resolveState()

        #expect(state.workingDirectory == "/home/demo/project")
        #expect(state.freshness == .live)
        await fixture.attachment.close()
    }

    @Test("只选择聚焦的非插件 Pane 工作目录")
    func parsesFocusedTerminalPaneWorkingDirectory() throws {
        let output = Data(#"[{"is_plugin":true,"is_focused":true,"pane_cwd":"/home/demo/plugin"},{"is_plugin":false,"is_focused":false,"pane_cwd":"/home/demo/other"},{"is_plugin":false,"is_focused":true,"pane_cwd":"/home/demo/project"}]"#.utf8)

        #expect(
            try ZellijPaneMetadataParser.workingDirectory(from: output)
                == "/home/demo/project"
        )
    }

    @Test("没有聚焦的终端 Pane 时不返回目录")
    func ignoresMissingFocusedTerminalPaneWorkingDirectory() throws {
        let output = Data(#"[{"is_plugin":true,"is_focused":true,"pane_cwd":"/home/demo/plugin"},{"is_plugin":false,"is_focused":false,"pane_cwd":"/home/demo/other"}]"#.utf8)

        #expect(try ZellijPaneMetadataParser.workingDirectory(from: output) == nil)
    }

    @Test("Tab 切换不向当前 Pane 写入模式前缀或 h/l")
    func tabNavigationDoesNotLeakModeKeysIntoPane() async throws {
        let fixture = try await ZellijInteractionFixture()
        var state = try await fixture.facet.resolveState()

        for action in [
            ZellijTerminalQuickAction.previousTab,
            ZellijTerminalQuickAction.nextTab
        ] {
            _ = try await fixture.facet.performQuickAction(.init(
                actionID: action.rawValue,
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                expectedStateRevision: state.revision,
                resolution: .currentAtExecution
            ))
            state = try await fixture.facet.resolveState()
        }

        #expect(fixture.process.writes.isEmpty)
        #expect(await fixture.actionExecutor.invocations == [
            .init(arguments: ["go-to-previous-tab"], repeatCount: 1),
            .init(arguments: ["go-to-next-tab"], repeatCount: 1)
        ])
        await fixture.attachment.close()
    }

    @Test("Pane 与其他模式快捷操作不向当前 Pane 注入尾部字符")
    func providerActionsDoNotLeakModeKeysIntoPane() async throws {
        let fixture = try await ZellijInteractionFixture()
        let cases: [(ZellijTerminalQuickAction, String?, [String])] = [
            (.newTab, nil, ["new-tab"]),
            (.renameTab, "editor", ["rename-tab", "editor"]),
            (.closeTab, nil, ["close-tab"]),
            (.syncTab, nil, ["toggle-active-sync-tab"]),
            (.newPane, nil, ["new-pane"]),
            (.splitPaneDown, nil, ["new-pane", "--direction", "down"]),
            (.splitPaneRight, nil, ["new-pane", "--direction", "right"]),
            (.switchPane, nil, ["focus-next-pane"]),
            (.fullscreenPane, nil, ["toggle-fullscreen"]),
            (.floatingPanes, nil, ["toggle-floating-panes"]),
            (.renamePane, "server", ["rename-pane", "server"]),
            (.closePane, nil, ["close-pane"]),
            (.previousLayout, nil, ["previous-swap-layout"]),
            (.nextLayout, nil, ["next-swap-layout"]),
            (.increasePaneSize, nil, ["resize", "increase"]),
            (.decreasePaneSize, nil, ["resize", "decrease"]),
            (.scrollMode, nil, ["switch-mode", "scroll"]),
            (.searchMode, nil, ["switch-mode", "enter-search"]),
            (.lockInput, nil, ["switch-mode", "locked"])
        ]
        var state = try await fixture.facet.resolveState()

        for (action, argument, _) in cases {
            _ = try await fixture.facet.performQuickAction(.init(
                actionID: action.rawValue,
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                expectedStateRevision: state.revision,
                argument: argument,
                confirmsDestructiveAction: action.isDestructive,
                resolution: .currentAtExecution
            ))
            state = try await fixture.facet.resolveState()
        }

        #expect(fixture.process.writes.isEmpty)
        #expect(await fixture.actionExecutor.invocations == cases.map {
            .init(arguments: $0.2, repeatCount: 1)
        })
        await fixture.attachment.close()
    }

    @Test("target、generation、revision 与重复次数必须匹配")
    func validatesQuickActionRequest() async throws {
        let fixture = try await ZellijInteractionFixture()
        let state = try await fixture.facet.resolveState()

        await #expect(throws: PersistentTerminalInteractionError.targetMismatch) {
            try await fixture.facet.performQuickAction(.init(
                actionID: ZellijTerminalQuickAction.newTab.rawValue,
                target: .init(providerID: "tmux", workspaceID: "alpha", targetID: "alpha"),
                attachmentGeneration: state.attachmentGeneration,
                expectedStateRevision: state.revision
            ))
        }
        await #expect(throws: PersistentTerminalInteractionError.staleAttachmentGeneration) {
            try await fixture.facet.performQuickAction(.init(
                actionID: ZellijTerminalQuickAction.newTab.rawValue,
                target: state.target,
                attachmentGeneration: state.attachmentGeneration + 1,
                expectedStateRevision: state.revision
            ))
        }
        await #expect(throws: PersistentTerminalInteractionError.staleStateRevision) {
            try await fixture.facet.performQuickAction(.init(
                actionID: ZellijTerminalQuickAction.newTab.rawValue,
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                expectedStateRevision: state.revision + 1
            ))
        }
        await #expect(throws: PersistentTerminalInteractionError.invalidQuickActionRepeatCount(33)) {
            try await fixture.facet.performQuickAction(.init(
                actionID: ZellijTerminalQuickAction.newTab.rawValue,
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                expectedStateRevision: state.revision,
                repeatCount: 33
            ))
        }
        #expect(fixture.process.writes.isEmpty)
        await fixture.attachment.close()
    }

    @Test("Zellij 不伪造 history 或 provider scroll 能力")
    func unsupportedInteractionFacetsFailExplicitly() async throws {
        let fixture = try await ZellijInteractionFixture()
        let state = try await fixture.facet.resolveState()
        #expect(!state.historyAvailable)
        #expect(state.modeCapability == .none)

        await #expect(throws: PersistentTerminalInteractionError.unavailable) {
            try await fixture.facet.captureHistory(PersistentTerminalHistoryRequest(
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                maxLines: 100,
                maxBytes: 4096
            ))
        }
        await #expect(throws: PersistentTerminalInteractionError.unsupportedMode) {
            try await fixture.facet.scrollProviderMode(PersistentTerminalModeScrollRequest(
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                direction: .up,
                rows: 3
            ))
        }
        await fixture.attachment.close()
    }

    @Test("关闭动作必须经过 Alert 确认")
    func destructiveActionsRequireConfirmation() async throws {
        let fixture = try await ZellijInteractionFixture()
        let state = try await fixture.facet.resolveState()

        for action in [
            ZellijTerminalQuickAction.closeSession,
            .closeTab,
            .closePane
        ] {
            await #expect(throws: PersistentTerminalInteractionError.unavailable) {
                try await fixture.facet.performQuickAction(.init(
                    actionID: action.rawValue,
                    target: state.target,
                    attachmentGeneration: state.attachmentGeneration,
                    expectedStateRevision: state.revision
                ))
            }
        }
        #expect(fixture.process.writes.isEmpty)
        await fixture.attachment.close()
    }

    @Test("关闭 Session 只在远端 attach 进程退出后关闭 workspace")
    func closeSessionWaitsForRemoteExit() async throws {
        let fixture = try await ZellijInteractionFixture(autoExitOnQuit: true)
        let state = try await fixture.facet.resolveState()

        let outcome = try await fixture.facet.performQuickAction(.init(
            actionID: ZellijTerminalQuickAction.closeSession.rawValue,
            target: state.target,
            attachmentGeneration: state.attachmentGeneration,
            expectedStateRevision: state.revision,
            confirmsDestructiveAction: true
        ))

        #expect(outcome == .workspaceClosed)
        #expect(fixture.process.writes.isEmpty)
        #expect(await fixture.actionExecutor.deleteSessionCount == 1)
        await fixture.attachment.close()
    }

    @Test("关闭最后一个 Tab 或 Pane 导致进程正常退出时发布 workspace 关闭事件")
    func cleanExitAfterDestructiveActionPublishesWorkspaceClosed() async throws {
        let fixture = try await ZellijInteractionFixture()
        var lifecycle = fixture.attachment.lifecycleEvents.makeAsyncIterator()
        let state = try await fixture.facet.resolveState()

        let outcome = try await fixture.facet.performQuickAction(.init(
            actionID: ZellijTerminalQuickAction.closePane.rawValue,
            target: state.target,
            attachmentGeneration: state.attachmentGeneration,
            expectedStateRevision: state.revision,
            confirmsDestructiveAction: true
        ))
        #expect(outcome == .performed)

        await fixture.process.finishRemotely()
        #expect(await lifecycle.next() == .workspaceClosed)
        await fixture.attachment.close()
    }

    @Test("模式不匹配导致进程未退出时保留本地 workspace")
    func closeSessionTimeoutDoesNotClaimSuccess() async throws {
        let fixture = try await ZellijInteractionFixture(
            autoExitOnQuit: false,
            processExitTimeout: .milliseconds(20)
        )
        let state = try await fixture.facet.resolveState()

        await #expect(throws: PersistentTerminalInteractionError.unavailable) {
            try await fixture.facet.performQuickAction(.init(
                actionID: ZellijTerminalQuickAction.closeSession.rawValue,
                target: state.target,
                attachmentGeneration: state.attachmentGeneration,
                expectedStateRevision: state.revision,
                confirmsDestructiveAction: true
            ))
        }
        #expect(fixture.process.writes.isEmpty)
        #expect(await fixture.actionExecutor.deleteSessionCount == 1)
        await fixture.attachment.close()
    }
}

private struct ZellijInteractionFixture {
    let process: ZellijInteractionProcessChannel
    let actionExecutor: ZellijActionCommandRecorder
    let attachment: ZellijPassthroughAttachment
    let facet: ZellijInteractionFacet

    init(
        autoExitOnQuit: Bool = false,
        processExitTimeout: Duration = .seconds(2)
    ) async throws {
        let process = ZellijInteractionProcessChannel(autoExitOnQuit: autoExitOnQuit)
        self.process = process
        let onDeleteSession: (@Sendable () async -> Void)?
        if autoExitOnQuit {
            onDeleteSession = { await process.finishRemotely() }
        } else {
            onDeleteSession = nil
        }
        actionExecutor = ZellijActionCommandRecorder(
            onDeleteSession: onDeleteSession,
            workingDirectory: "/home/demo/project"
        )
        let channel = try await ZellijProcessShellChannel.open(
            process: process,
            nonce: "INTERACTION"
        )
        let configuration = ZellijProvider().defaultConfiguration
        let workspace = try RemoteWorkspaceRef(
            workspaceID: "alpha",
            instancePayloadVersion: ZellijProvider.workspaceInstancePayloadVersion,
            providerInstancePayload: JSONEncoder().encode(ZellijWorkspaceInstancePayload())
        )
        let descriptor = try PersistentAttachmentDescriptor(
            providerID: ZellijProvider.providerID,
            configuration: configuration,
            workspace: workspace,
            payloadVersion: ZellijProvider.attachmentPayloadVersion,
            providerPayload: JSONEncoder().encode(
                ZellijAttachmentPayload(sessionName: "alpha")
            )
        )
        attachment = ZellijPassthroughAttachment(
            descriptor: descriptor,
            channel: channel,
            actionExecutor: actionExecutor,
            attachmentGeneration: 7,
            processExitTimeout: processExitTimeout
        )
        facet = attachment.interaction as! ZellijInteractionFacet
    }
}

private actor ZellijActionCommandRecorder: ZellijActionCommandExecuting {
    struct Invocation: Sendable, Equatable {
        let arguments: [String]
        let repeatCount: Int
    }

    private(set) var invocations: [Invocation] = []
    private(set) var deleteSessionCount = 0
    private let onDeleteSession: (@Sendable () async -> Void)?
    private let workingDirectory: String?

    init(
        onDeleteSession: (@Sendable () async -> Void)? = nil,
        workingDirectory: String? = nil
    ) {
        self.onDeleteSession = onDeleteSession
        self.workingDirectory = workingDirectory
    }

    func execute(arguments: [String], repeatCount: Int) {
        invocations.append(.init(arguments: arguments, repeatCount: repeatCount))
    }

    func deleteSession() async {
        deleteSessionCount += 1
        await onDeleteSession?()
    }

    func currentWorkingDirectory() async throws -> String? {
        workingDirectory
    }
}

private final class ZellijInteractionProcessChannel: RemoteProcessChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<RemoteProcessOutput, Error>

    private let continuation: AsyncThrowingStream<RemoteProcessOutput, Error>.Continuation
    private let state = ZellijInteractionProcessState()
    private let autoExitOnQuit: Bool
    private let lock = NSLock()
    private var storedWrites: [Data] = []

    var writes: [Data] { lock.withLock { storedWrites } }

    init(autoExitOnQuit: Bool) {
        self.autoExitOnQuit = autoExitOnQuit
        (output, continuation) = AsyncThrowingStream.makeStream()
        continuation.yield(.stdout(Data(
            "__CONN_ZELLIJ_ATTACH_v1__ nonce=INTERACTION\n".utf8
        )))
    }

    func write(_ data: Data) async throws {
        lock.withLock { storedWrites.append(data) }
        if autoExitOnQuit, data.contains(0x11) {
            await state.complete(.init(exitCode: 0, signal: nil))
            continuation.finish()
        }
    }

    func resize(_ size: TermSize) async throws {}

    func result() async throws -> RemoteProcessExit {
        await state.result()
    }

    func close() async {
        await state.complete(.init(exitCode: nil, signal: "CLOSED"))
        continuation.finish()
    }

    func finishRemotely(exitCode: Int32 = 0) async {
        await state.complete(.init(exitCode: exitCode, signal: nil))
        continuation.finish()
    }
}

private actor ZellijInteractionProcessState {
    private var exit: RemoteProcessExit?
    private var waiters: [CheckedContinuation<RemoteProcessExit, Never>] = []

    func result() async -> RemoteProcessExit {
        if let exit {
            return exit
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func complete(_ exit: RemoteProcessExit) {
        guard self.exit == nil else { return }
        self.exit = exit
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: exit)
        }
    }
}
