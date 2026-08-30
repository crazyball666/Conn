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
        #expect(group.title == "Zellij")
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
    }

    @Test("快捷操作严格使用 Zellij 官方默认键位字节")
    func macrosUseDefaultZellijBindings() {
        let expected: [ZellijTerminalQuickAction: [UInt8]] = [
            .closeSession: [0x11],
            .newTab: [0x14, 0x6E],
            .previousTab: [0x14, 0x68],
            .nextTab: [0x14, 0x6C],
            .renameTab: [0x14, 0x72],
            .closeTab: [0x14, 0x78],
            .syncTab: [0x14, 0x73],
            .newPane: [0x10, 0x6E],
            .splitPaneDown: [0x10, 0x64],
            .splitPaneRight: [0x10, 0x72],
            .switchPane: [0x10, 0x70],
            .fullscreenPane: [0x10, 0x66],
            .floatingPanes: [0x1B, 0x66],
            .renamePane: [0x10, 0x63],
            .closePane: [0x10, 0x78],
            .previousLayout: [0x1B, 0x5B],
            .nextLayout: [0x1B, 0x5D],
            .increasePaneSize: [0x1B, 0x3D],
            .decreasePaneSize: [0x1B, 0x2D],
            .scrollMode: [0x13],
            .searchMode: [0x13, 0x73],
            .lockInput: [0x07]
        ]

        #expect(ZellijTerminalQuickAction.allCases.count == expected.count)
        for action in ZellijTerminalQuickAction.allCases {
            #expect(action.macroBytes == expected[action])
        }
    }

    @Test("普通动作支持有界重复并作为单个不可拆分写入")
    func repeatedActionWritesOneAtomicMacro() async throws {
        let fixture = try await ZellijInteractionFixture()
        let state = try await fixture.facet.resolveState()

        let outcome = try await fixture.facet.performQuickAction(.init(
            actionID: ZellijTerminalQuickAction.nextTab.rawValue,
            target: state.target,
            attachmentGeneration: state.attachmentGeneration,
            expectedStateRevision: state.revision,
            repeatCount: 3,
            resolution: .currentAtExecution
        ))

        #expect(outcome == .performed)
        #expect(fixture.process.writes == [Data([
            0x14, 0x6C,
            0x14, 0x6C,
            0x14, 0x6C
        ])])
        #expect(try await fixture.facet.resolveState().revision == state.revision + 1)
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
        #expect(fixture.process.writes == [Data([0x11])])
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
        #expect(fixture.process.writes == [Data([0x11])])
        await fixture.attachment.close()
    }
}

private struct ZellijInteractionFixture {
    let process: ZellijInteractionProcessChannel
    let attachment: ZellijPassthroughAttachment
    let facet: ZellijInteractionFacet

    init(
        autoExitOnQuit: Bool = false,
        processExitTimeout: Duration = .seconds(2)
    ) async throws {
        process = ZellijInteractionProcessChannel(autoExitOnQuit: autoExitOnQuit)
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
            attachmentGeneration: 7,
            processExitTimeout: processExitTimeout
        )
        facet = attachment.interaction as! ZellijInteractionFacet
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
