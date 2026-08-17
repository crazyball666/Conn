import ConnSSH
import Foundation

package enum TmuxInteractionError: Error, Sendable, Equatable {
    case targetMismatch
    case clientUnavailable
    case clientOwnershipMismatch
    case sessionMismatch
    case activePaneUnavailable
    case staleState(expectedRevision: UInt64, actualRevision: UInt64)
    case unsupportedMode
    case closed
    case createdWindowIdentityUnavailable
    case createdPaneIdentityUnavailable
}

/// tmux modes are classified from provider state, never from the foreground process name.
/// The lists intentionally contain only mode families with documented interaction behavior;
/// a future or configured mode fails closed until its semantics are known.
package enum TmuxInteractionModeClassifier {
    private static let scrollableModes: Set<String> = [
        "copy-mode",
        "copy-mode-vi",
        "view-mode",
    ]
    private static let keyDrivenModes: Set<String> = [
        "choose-buffer",
        "choose-client",
        "choose-tree",
        "client-mode",
        "tree-mode",
    ]

    package static func classify(
        paneInMode: Bool?,
        mode: String?
    ) -> PersistentTerminalModeCapability {
        guard paneInMode == true else {
            return paneInMode == false ? .none : .unsupported
        }
        guard let mode, !mode.isEmpty else { return .unsupported }
        if scrollableModes.contains(mode) { return .scrollable }
        if keyDrivenModes.contains(mode) { return .keyDriven }
        return .unsupported
    }
}

/// Provider-owned command palette for an attached tmux terminal. IDs are stable API values;
/// the terminal renderer only sees the provider-neutral descriptors below.
package enum TmuxTerminalQuickAction: String, CaseIterable, Sendable {
    case renameSession = "tmux.session.rename"
    case newWindow = "tmux.window.new"
    case previousWindow = "tmux.window.previous"
    case nextWindow = "tmux.window.next"
    case renameWindow = "tmux.window.rename"
    case splitHorizontal = "tmux.pane.split-horizontal"
    case splitVertical = "tmux.pane.split-vertical"
    case previousPane = "tmux.pane.previous"
    case nextPane = "tmux.pane.next"
    case toggleZoom = "tmux.pane.toggle-zoom"
    case swapPanePrevious = "tmux.pane.swap-previous"
    case swapPaneNext = "tmux.pane.swap-next"
    case resizeLeft = "tmux.pane.resize-left"
    case resizeRight = "tmux.pane.resize-right"
    case resizeUp = "tmux.pane.resize-up"
    case resizeDown = "tmux.pane.resize-down"
    case toggleSynchronizePanes = "tmux.pane.toggle-synchronize"
    case copyMode = "tmux.mode.copy"
    case cycleLayout = "tmux.layout.next"
    case tiledLayout = "tmux.layout.tiled"
    case evenHorizontalLayout = "tmux.layout.even-horizontal"
    case evenVerticalLayout = "tmux.layout.even-vertical"
    case mainHorizontalLayout = "tmux.layout.main-horizontal"
    case mainVerticalLayout = "tmux.layout.main-vertical"

    package static let group = PersistentTerminalQuickActionGroup(
        id: TmuxProvider.providerID,
        title: "tmux",
        sections: [
            .init(id: "session", titleKey: "Session", actions: [
                descriptor(
                    .renameSession,
                    "重命名 Session",
                    "pencil",
                    textInput: .init(titleKey: "重命名 Session", placeholderKey: "Session 名称")
                ),
            ]),
            .init(id: "window", titleKey: "Window", actions: [
                descriptor(.newWindow, "新建 Window", "plus.rectangle"),
                descriptor(.previousWindow, "上一个 Window", "arrow.left.to.line"),
                descriptor(.nextWindow, "下一个 Window", "arrow.right.to.line"),
                descriptor(
                    .renameWindow,
                    "重命名 Window",
                    "pencil",
                    textInput: .init(titleKey: "重命名 Window", placeholderKey: "Window 名称")
                ),
            ]),
            .init(id: "pane", titleKey: "Pane", actions: [
                descriptor(.splitHorizontal, "左右分屏", "rectangle.split.2x1"),
                descriptor(.splitVertical, "上下分屏", "rectangle.split.1x2"),
                descriptor(.previousPane, "上一个 Pane", "arrow.left"),
                descriptor(.nextPane, "下一个 Pane", "arrow.right"),
                descriptor(.toggleZoom, "Pane Zoom", "arrow.up.left.and.arrow.down.right"),
                descriptor(.swapPanePrevious, "向前交换 Pane", "arrow.up.square"),
                descriptor(.swapPaneNext, "向后交换 Pane", "arrow.down.square"),
                descriptor(.resizeLeft, "向左调整", "arrow.left"),
                descriptor(.resizeRight, "向右调整", "arrow.right"),
                descriptor(.resizeUp, "向上调整", "arrow.up"),
                descriptor(.resizeDown, "向下调整", "arrow.down"),
                descriptor(
                    .toggleSynchronizePanes,
                    "切换同步输入",
                    "arrow.triangle.2.circlepath"
                ),
            ]),
            .init(id: "mode", titleKey: "模式", actions: [
                descriptor(.copyMode, "复制模式", "doc.on.doc"),
            ]),
            .init(id: "layout", titleKey: "Pane 布局", actions: [
                descriptor(.cycleLayout, "切换布局", "rectangle.3.group"),
                descriptor(.tiledLayout, "平铺布局", "square.grid.2x2"),
                descriptor(.evenHorizontalLayout, "等宽布局", "rectangle.split.3x1"),
                descriptor(.evenVerticalLayout, "等高布局", "rectangle.split.1x2"),
                descriptor(.mainHorizontalLayout, "主区域居上", "rectangle.tophalf.inset.filled"),
                descriptor(.mainVerticalLayout, "主区域居左", "rectangle.lefthalf.inset.filled"),
            ]),
        ],
        swipeActions: [
            // The content follows the finger: swiping left advances, swiping right goes back.
            .init(
                direction: .left,
                actionID: nextWindow.rawValue,
                successNoticeKey: "已切换到下一个 Window"
            ),
            .init(
                direction: .right,
                actionID: previousWindow.rawValue,
                successNoticeKey: "已切换到上一个 Window"
            ),
        ]
    )

    package func operation(
        for state: TmuxResolvedInteractionState,
        client: TmuxClientTarget,
        argument: String? = nil,
        repeatCount: Int = 1
    ) throws -> TmuxOperation {
        guard repeatCount == 1 || self == .previousWindow || self == .nextWindow else {
            throw PersistentTerminalInteractionError.invalidQuickActionRepeatCount(repeatCount)
        }
        return switch self {
        case .renameSession:
            .renameSession(state.sessionID, to: try TmuxName(argument ?? ""))
        case .newWindow:
            .createWindow(in: state.sessionID, name: nil)
        case .previousWindow:
            .selectRelativeWindow(
                in: state.sessionID,
                direction: .previous,
                steps: try TmuxWindowNavigationStepCount(repeatCount),
                for: client
            )
        case .nextWindow:
            .selectRelativeWindow(
                in: state.sessionID,
                direction: .next,
                steps: try TmuxWindowNavigationStepCount(repeatCount),
                for: client
            )
        case .renameWindow:
            .renameWindow(state.windowID, to: try TmuxName(argument ?? ""))
        case .splitHorizontal:
            .splitPane(state.paneID, orientation: .horizontal)
        case .splitVertical:
            .splitPane(state.paneID, orientation: .vertical)
        case .previousPane:
            .selectPane(previous(state.paneID, in: state.paneIDs), for: client)
        case .nextPane:
            .selectPane(next(state.paneID, in: state.paneIDs), for: client)
        case .toggleZoom:
            .setPaneZoom(state.paneID, zoomed: !state.isWindowZoomed)
        case .swapPanePrevious:
            .swapPane(state.paneID, direction: .previous)
        case .swapPaneNext:
            .swapPane(state.paneID, direction: .next)
        case .resizeLeft:
            .resizePane(state.paneID, direction: .left, cells: try TmuxResizeCellCount(5))
        case .resizeRight:
            .resizePane(state.paneID, direction: .right, cells: try TmuxResizeCellCount(5))
        case .resizeUp:
            .resizePane(state.paneID, direction: .up, cells: try TmuxResizeCellCount(5))
        case .resizeDown:
            .resizePane(state.paneID, direction: .down, cells: try TmuxResizeCellCount(5))
        case .toggleSynchronizePanes:
            .toggleSynchronizePanes(state.windowID)
        case .copyMode:
            .enterCopyMode(state.paneID)
        case .cycleLayout:
            .cyclePaneLayout(state.windowID)
        case .tiledLayout:
            .applyPaneLayout(state.windowID, layout: .tiled)
        case .evenHorizontalLayout:
            .applyPaneLayout(state.windowID, layout: .evenHorizontal)
        case .evenVerticalLayout:
            .applyPaneLayout(state.windowID, layout: .evenVertical)
        case .mainHorizontalLayout:
            .applyPaneLayout(state.windowID, layout: .mainHorizontal)
        case .mainVerticalLayout:
            .applyPaneLayout(state.windowID, layout: .mainVertical)
        }
    }

    private static func descriptor(
        _ action: Self,
        _ titleKey: String,
        _ systemImageName: String,
        textInput: PersistentTerminalQuickActionTextInput? = nil
    ) -> PersistentTerminalQuickActionDescriptor {
        .init(
            id: action.rawValue,
            titleKey: titleKey,
            systemImageName: systemImageName,
            textInput: textInput
        )
    }

    private func previous<ID: Equatable>(_ current: ID, in values: [ID]) -> ID {
        guard let index = values.firstIndex(of: current), values.count > 1 else { return current }
        return values[(index - 1 + values.count) % values.count]
    }

    private func next<ID: Equatable>(_ current: ID, in values: [ID]) -> ID {
        guard let index = values.firstIndex(of: current), values.count > 1 else { return current }
        return values[(index + 1) % values.count]
    }
}

package struct TmuxResolvedInteractionState: Sendable, Equatable {
    package let state: PersistentTerminalInteractionState
    package let clientID: TmuxClientID
    package let sessionID: TmuxSessionID
    package let windowID: TmuxWindowID
    package let windowIDs: [TmuxWindowID]
    package let paneID: TmuxPaneID
    package let paneIDs: [TmuxPaneID]
    package let isWindowZoomed: Bool
    package let paneRows: Int
    package let historySize: Int?
    package let historyLimit: Int?
}

package struct TmuxInteractionStateProjector: Sendable {
    package init() {}

    package func project(
        snapshot: TmuxServerSnapshot,
        identity: TmuxControlInteractiveIdentity,
        attachmentGeneration: UInt64
    ) throws -> PersistentTerminalInteractionState {
        try resolve(
            snapshot: snapshot,
            identity: identity,
            expectedTarget: nil,
            attachmentGeneration: attachmentGeneration
        ).state
    }

    package func resolve(
        snapshot: TmuxServerSnapshot,
        identity: TmuxControlInteractiveIdentity,
        expectedTarget: PersistentTerminalInteractionTarget?,
        attachmentGeneration: UInt64
    ) throws -> TmuxResolvedInteractionState {
        guard let client = snapshot.clients[identity.clientID] else {
            throw TmuxInteractionError.clientUnavailable
        }
        guard client.role == .connInteractive(attachmentID: identity.attachmentID) else {
            throw TmuxInteractionError.clientOwnershipMismatch
        }
        guard client.sessionID == identity.requestedSessionID else {
            throw TmuxInteractionError.sessionMismatch
        }
        guard let paneID = client.activePaneID,
              let pane = snapshot.panes[paneID],
              client.currentWindowID == pane.windowID
        else {
            throw TmuxInteractionError.activePaneUnavailable
        }
        let target = PersistentTerminalInteractionTarget(
            providerID: TmuxProvider.providerID,
            workspaceID: identity.requestedSessionID.rawValue,
            targetID: paneID.rawValue
        )
        if let expectedTarget, expectedTarget != target {
            throw TmuxInteractionError.targetMismatch
        }

        let interaction = pane.interaction
        let freshness = effectiveFreshness([
            interaction.alternateOn.freshness,
            interaction.paneInMode.freshness,
            interaction.mode.freshness,
            interaction.historySize.freshness,
            interaction.historyLimit.freshness,
        ])
        let state = PersistentTerminalInteractionState(
            target: target,
            attachmentGeneration: attachmentGeneration,
            revision: snapshot.revision,
            freshness: freshness,
            isAlternateBuffer: interaction.alternateOn.value,
            modeCapability: TmuxInteractionModeClassifier.classify(
                paneInMode: interaction.paneInMode.value,
                mode: interaction.mode.value
            ),
            providerModeID: interaction.mode.value,
            historyAvailable: (interaction.historySize.value ?? 0) > 0,
            observedAt: snapshot.observedAt
        )
        return .init(
            state: state,
            clientID: client.id,
            sessionID: client.sessionID,
            windowID: pane.windowID,
            windowIDs: snapshot.windows(in: client.sessionID),
            paneID: paneID,
            paneIDs: snapshot.panes(in: pane.windowID),
            isWindowZoomed: snapshot.windows[pane.windowID]?.isZoomed == true,
            paneRows: pane.size.rows,
            historySize: interaction.historySize.value,
            historyLimit: interaction.historyLimit.value
        )
    }

    private func effectiveFreshness(
        _ values: [TmuxMetadataFreshness]
    ) -> PersistentTerminalInteractionFreshness {
        if values.contains(where: {
            if case .stale = $0 { return true }
            return false
        }) {
            return .stale
        }
        if values.contains(.unavailable) { return .stale }
        if values.contains(where: {
            if case .snapshot = $0 { return true }
            return false
        }) {
            return .snapshot
        }
        return .live
    }
}

package struct TmuxParsedHistory: Sendable, Equatable {
    package let lines: [PersistentTerminalHistoryLine]
    package let isTruncated: Bool
    package let byteCount: Int
}

/// Parses `capture-pane -p` output as inert text. Terminal control strings are removed before
/// UTF-8 decoding, and the result is never fed back into a terminal emulator.
package struct TmuxHistoryCaptureParser: Sendable {
    package init() {}

    package func parse(
        _ data: Data,
        maximumLines: Int,
        maximumBytes: Int
    ) -> TmuxParsedHistory {
        let lineLimit = max(maximumLines, 1)
        let byteLimit = max(maximumBytes, 1)
        let bounded = Data(data.prefix(byteLimit))
        var wasTruncated = data.count > bounded.count
        let sanitized = sanitize(bounded)
        var text = String(decoding: sanitized, as: UTF8.self)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var values = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), values.last?.isEmpty == true {
            values.removeLast()
        }
        if values.count > lineLimit {
            values = Array(values.suffix(lineLimit))
            wasTruncated = true
        }
        let lines = values.map { value in
            PersistentTerminalHistoryLine(
                text: value,
                cellColumnToUTF16Offset: Array(0 ... value.utf16.count),
                isWrapped: false
            )
        }
        return .init(
            lines: lines,
            isTruncated: wasTruncated,
            byteCount: bounded.count
        )
    }

    private enum EscapeState {
        case normal
        case escape
        case csi
        case controlString
        case controlStringEscape
    }

    private func sanitize(_ data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)
        var state = EscapeState.normal
        for byte in data {
            switch state {
            case .normal:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x09, 0x0A, 0x0D:
                    result.append(byte)
                case 0x00 ... 0x1F, 0x7F:
                    break
                default:
                    result.append(byte)
                }

            case .escape:
                switch byte {
                case UInt8(ascii: "["):
                    state = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"),
                     UInt8(ascii: "_"), UInt8(ascii: "^"):
                    state = .controlString
                default:
                    state = .normal
                }

            case .csi:
                if (0x40 ... 0x7E).contains(byte) {
                    state = .normal
                }

            case .controlString:
                if byte == 0x07 {
                    state = .normal
                } else if byte == 0x1B {
                    state = .controlStringEscape
                }

            case .controlStringEscape:
                if byte == UInt8(ascii: "\\") {
                    state = .normal
                } else if byte != 0x1B {
                    state = .controlString
                }
            }
        }
        return result
    }
}

package enum TmuxInteractionOneShotError: Error, Sendable, Equatable {
    case invalidTimeout
    case unsupportedRuntime(RemoteScriptFamily)
    case scopeMismatch(expected: TmuxOperationScope, actual: TmuxOperationScope)
    case staleInstance
    case malformedResponse
    case outputLimitExceeded(maximumBytes: Int)
    case commandRejected(Int32)
    case captureFailed
    case timedOut
}

/// Executes an already typed read-only tmux request through the prepared POSIX runtime. The
/// request remains guarded by the exact server token and ordinary output is bounded before it
/// reaches snapshot or history decoders.
package struct TmuxOneShotReadOnlyCommandExecutor: TmuxReadOnlyCommandExecuting, Sendable {
    package typealias NonceFactory = @Sendable () throws -> TmuxInvocationNonce

    private let session: any SSHSession
    private let runtime: PreparedRemoteScriptRuntime
    private let executable: TmuxExecutablePath
    private let locator: TmuxServerLocator
    private let boundScope: TmuxOperationScope
    private let maximumOutputBytes: Int
    private let nonceFactory: NonceFactory

    package init(
        session: any SSHSession,
        runtime: PreparedRemoteScriptRuntime,
        executable: TmuxExecutablePath,
        locator: TmuxServerLocator,
        scope: TmuxOperationScope,
        maximumOutputBytes: Int = PersistentTerminalHistoryRequest.maximumBytes,
        nonceFactory: @escaping NonceFactory
    ) {
        self.session = session
        self.runtime = runtime
        self.executable = executable
        self.locator = locator
        boundScope = scope
        self.maximumOutputBytes = max(maximumOutputBytes, 1)
        self.nonceFactory = nonceFactory
    }

    package func execute(
        _ request: TmuxControlRequest,
        scope: TmuxOperationScope,
        timeout: Duration
    ) async throws -> TmuxReadOnlyCommandExecution {
        guard scope == boundScope else {
            throw TmuxInteractionOneShotError.scopeMismatch(
                expected: boundScope,
                actual: scope
            )
        }
        guard timeout > .zero else { throw TmuxInteractionOneShotError.invalidTimeout }
        guard runtime.family == .posix else {
            throw TmuxInteractionOneShotError.unsupportedRuntime(runtime.family)
        }
        guard request.semantics == .readOnly,
              var command = String(data: request.wireData, encoding: .utf8)
        else {
            throw TmuxInteractionOneShotError.malformedResponse
        }
        if command.hasSuffix("\n") { command.removeLast() }
        let nonce = try nonceFactory()
        let acceptedMarker = "__CONN_TMUX_READ_ACCEPTED_\(nonce.value)__"
        let changedMarker = "__CONN_TMUX_READ_CHANGED_\(nonce.value)__"
        let condition = "#{&&:#{==:#{pid},\(scope.instanceToken.serverPID)},"
            + "#{==:#{start_time},\(scope.instanceToken.serverStartTime)}}"
        let acceptedCommand = "display-message -p \(encodeTmux(acceptedMarker)) ; \(command)"
        let changedCommand = "display-message -p \(encodeTmux(changedMarker))"
        let arguments = locator.arguments + [
            "if-shell", "-F", condition, acceptedCommand, changedCommand,
        ]
        let script = (["exec", executable.value] + arguments)
            .map { POSIXShellArgument.encode($0) }
            .joined(separator: " ")
        let remoteCommand = try runtime.invocation(for: script)
        let execution = try await session.exec(remoteCommand, timeout: timeout)
        guard execution.stdout.count <= maximumOutputBytes else {
            throw TmuxInteractionOneShotError.outputLimitExceeded(
                maximumBytes: maximumOutputBytes
            )
        }
        let accepted = Data(acceptedMarker.utf8)
        let changed = Data(changedMarker.utf8)
        if let remainder = consumeLeadingLine(accepted, from: execution.stdout) {
            guard remainder.range(of: accepted) == nil,
                  remainder.range(of: changed) == nil
            else { throw TmuxInteractionOneShotError.malformedResponse }
            guard execution.isSuccess else {
                throw TmuxInteractionOneShotError.commandRejected(execution.exitCode)
            }
            return .init(scope: scope, output: splitLines(remainder))
        }
        if let remainder = consumeLeadingLine(changed, from: execution.stdout), remainder.isEmpty {
            throw TmuxInteractionOneShotError.staleInstance
        }
        throw TmuxInteractionOneShotError.malformedResponse
    }

    private func splitLines(_ data: Data) -> [Data] {
        var lines = Array(data).split(
            separator: UInt8(ascii: "\n"),
            omittingEmptySubsequences: false
        ).map { Data($0) }
        if data.last == UInt8(ascii: "\n"), lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.map { line in
            guard line.last == UInt8(ascii: "\r") else { return line }
            return Data(line.dropLast())
        }
    }

    private func consumeLeadingLine(_ marker: Data, from output: Data) -> Data? {
        guard output.starts(with: marker) else { return nil }
        if output.count == marker.count { return Data() }
        let boundary = output.index(output.startIndex, offsetBy: marker.count)
        if output[boundary] == UInt8(ascii: "\n") {
            return Data(output[output.index(after: boundary)...])
        }
        if output[boundary] == UInt8(ascii: "\r") {
            let next = output.index(after: boundary)
            guard next < output.endIndex, output[next] == UInt8(ascii: "\n") else {
                return nil
            }
            return Data(output[output.index(after: next)...])
        }
        return nil
    }

    private func encodeTmux(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

package struct TmuxPaneCaptureResult: Sendable, Equatable {
    package let data: Data
    package let isTruncated: Bool
}

package protocol TmuxPaneHistoryCaptureExecuting: Sendable {
    func capture(
        paneID: TmuxPaneID,
        startLine: Int,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> TmuxPaneCaptureResult
}

package struct TmuxStreamingPaneHistoryCaptureExecutor:
    TmuxPaneHistoryCaptureExecuting, Sendable
{
    private struct Collection: Sendable {
        let stdout: Data
        let isTruncated: Bool
    }
    private let session: any SSHSession
    private let runtime: PreparedRemoteScriptRuntime
    private let executable: TmuxExecutablePath
    private let locator: TmuxServerLocator
    private let scope: TmuxOperationScope
    private let nonceFactory: TmuxOneShotReadOnlyCommandExecutor.NonceFactory

    package init(
        session: any SSHSession,
        runtime: PreparedRemoteScriptRuntime,
        executable: TmuxExecutablePath,
        locator: TmuxServerLocator,
        scope: TmuxOperationScope,
        nonceFactory: @escaping TmuxOneShotReadOnlyCommandExecutor.NonceFactory
    ) {
        self.session = session
        self.runtime = runtime
        self.executable = executable
        self.locator = locator
        self.scope = scope
        self.nonceFactory = nonceFactory
    }

    package func capture(
        paneID: TmuxPaneID,
        startLine: Int,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> TmuxPaneCaptureResult {
        guard timeout > .zero else { throw TmuxInteractionOneShotError.invalidTimeout }
        guard runtime.family == .posix else {
            throw TmuxInteractionOneShotError.unsupportedRuntime(runtime.family)
        }
        guard (1 ... PersistentTerminalHistoryRequest.maximumBytes).contains(maximumBytes),
              (-PersistentTerminalHistoryRequest.maximumLines ...
                  PersistentTerminalHistoryRequest.maximumLines).contains(startLine)
        else {
            throw TmuxInteractionOneShotError.captureFailed
        }
        let nonce = try nonceFactory()
        let acceptedMarker = "__CONN_TMUX_CAPTURE_ACCEPTED_\(nonce.value)__"
        let changedMarker = "__CONN_TMUX_CAPTURE_CHANGED_\(nonce.value)__"
        let condition = "#{&&:#{==:#{pid},\(scope.instanceToken.serverPID)},"
            + "#{==:#{start_time},\(scope.instanceToken.serverStartTime)}}"
        let capture = [
            "capture-pane", "-p", "-N", "-t", encodeTmux(paneID.rawValue),
            "-S", encodeTmux(String(startLine)), "-E", encodeTmux("-"),
        ].joined(separator: " ")
        let acceptedCommand = "display-message -p \(encodeTmux(acceptedMarker)) ; \(capture)"
        let changedCommand = "display-message -p \(encodeTmux(changedMarker))"
        let arguments = locator.arguments + [
            "if-shell", "-F", condition, acceptedCommand, changedCommand,
        ]
        let script = (["exec", executable.value] + arguments)
            .map { POSIXShellArgument.encode($0) }
            .joined(separator: " ")
        let command = try runtime.invocation(for: script)
        let process = try await session.openProcess(
            RemoteProcessRequest(command: command)
        )
        let markerAllowance = max(
            acceptedMarker.utf8.count,
            changedMarker.utf8.count
        ) + 2
        let wireLimit = maximumBytes.addingReportingOverflow(markerAllowance)
        guard !wireLimit.overflow else {
            await process.close()
            throw TmuxInteractionOneShotError.captureFailed
        }

        let collection: Collection
        do {
            collection = try await withThrowingTaskGroup(of: Collection.self) { group in
                group.addTask {
                    try await collect(process: process, wireLimit: wireLimit.partialValue)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await process.close()
                    throw TmuxInteractionOneShotError.timedOut
                }
                guard let first = try await group.next() else {
                    throw TmuxInteractionOneShotError.captureFailed
                }
                group.cancelAll()
                return first
            }
        } catch {
            await process.close()
            throw error
        }
        await process.close()

        let accepted = Data(acceptedMarker.utf8)
        let changed = Data(changedMarker.utf8)
        guard let payload = consumeLeadingLine(accepted, from: collection.stdout) else {
            if consumeLeadingLine(changed, from: collection.stdout)?.isEmpty == true {
                throw TmuxInteractionOneShotError.staleInstance
            }
            throw TmuxInteractionOneShotError.malformedResponse
        }
        guard payload.range(of: accepted) == nil,
              payload.range(of: changed) == nil
        else { throw TmuxInteractionOneShotError.malformedResponse }
        return TmuxPaneCaptureResult(
            data: Data(payload.prefix(maximumBytes)),
            isTruncated: collection.isTruncated || payload.count > maximumBytes
        )
    }

    private func collect(
        process: any RemoteProcessChannel,
        wireLimit: Int
    ) async throws -> Collection {
        var stdout = Data()
        var stderrBytes = 0
        for try await output in process.output {
            try Task.checkCancellation()
            switch output {
            case let .stdout(chunk):
                let remaining = max(wireLimit - stdout.count, 0)
                stdout.append(chunk.prefix(remaining))
                if chunk.count > remaining {
                    return Collection(stdout: stdout, isTruncated: true)
                }
            case let .stderr(chunk):
                let total = stderrBytes.addingReportingOverflow(chunk.count)
                guard !total.overflow, total.partialValue <= 64 * 1_024 else {
                    throw TmuxInteractionOneShotError.captureFailed
                }
                stderrBytes = total.partialValue
            }
        }
        let result = try await process.result()
        guard result.exitCode == 0, result.signal == nil else {
            throw TmuxInteractionOneShotError.commandRejected(result.exitCode ?? -1)
        }
        return Collection(stdout: stdout, isTruncated: false)
    }

    private func consumeLeadingLine(_ marker: Data, from output: Data) -> Data? {
        guard output.starts(with: marker) else { return nil }
        if output.count == marker.count { return Data() }
        let boundary = output.index(output.startIndex, offsetBy: marker.count)
        if output[boundary] == UInt8(ascii: "\n") {
            return Data(output[output.index(after: boundary)...])
        }
        if output[boundary] == UInt8(ascii: "\r") {
            let next = output.index(after: boundary)
            guard next < output.endIndex, output[next] == UInt8(ascii: "\n") else {
                return nil
            }
            return Data(output[output.index(after: next)...])
        }
        return nil
    }

    private func encodeTmux(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

package actor TmuxOneShotInteractionBackend {
    private let loader: TmuxSnapshotLoader
    private let captureExecutor: any TmuxPaneHistoryCaptureExecuting
    private let scope: TmuxOperationScope
    private let dialect: TmuxProtocolDialect
    private let attachmentID: String
    private let attachmentGeneration: UInt64
    private let requestedSessionID: TmuxSessionID
    private let tty: String
    private let processID: Int32
    private let clock: @Sendable () -> Date
    package init(
        executor: any TmuxReadOnlyCommandExecuting,
        captureExecutor: any TmuxPaneHistoryCaptureExecuting,
        scope: TmuxOperationScope,
        dialect: TmuxProtocolDialect,
        attachmentID: String,
        attachmentGeneration: UInt64,
        requestedSessionID: TmuxSessionID,
        tty: String,
        processID: Int32,
        nonceFactory: @escaping TmuxSnapshotLoader.NonceFactory,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        loader = TmuxSnapshotLoader(
            executor: executor,
            nonceFactory: nonceFactory,
            clock: clock
        )
        self.captureExecutor = captureExecutor
        self.scope = scope
        self.dialect = dialect
        self.attachmentID = attachmentID
        self.attachmentGeneration = attachmentGeneration
        self.requestedSessionID = requestedSessionID
        self.tty = tty
        self.processID = processID
        self.clock = clock
    }

    package func resolve() async throws -> TmuxResolvedInteractionState {
        let unowned = try await loader.load(
            scope: scope,
            dialect: dialect,
            identities: [],
            controlClientID: nil,
            timeout: .seconds(5)
        )
        let matches = unowned.clients.values.filter {
            $0.tty == tty
                && $0.id.processID == processID
                && $0.sessionID == requestedSessionID
                && $0.kind == .interactiveTerminal
        }
        guard matches.count == 1, let client = matches.first else {
            throw TmuxInteractionError.clientUnavailable
        }
        let identity = TmuxControlInteractiveIdentity(
            attachmentID: attachmentID,
            clientID: client.id,
            requestedSessionID: requestedSessionID
        )
        let owned = try await loader.load(
            scope: scope,
            dialect: dialect,
            identities: [identity],
            controlClientID: nil,
            timeout: .seconds(5)
        )
        let resolved = try TmuxInteractionStateProjector().resolve(
            snapshot: owned,
            identity: identity,
            expectedTarget: nil,
            attachmentGeneration: attachmentGeneration
        )
        return resolved
    }

    package func captureHistory(
        _ request: PersistentTerminalHistoryRequest,
        pinned: TmuxResolvedInteractionState
    ) async throws -> PersistentTerminalHistorySnapshot {
        try validate(request, against: pinned.state)
        let historySize = max(pinned.historySize ?? 0, 0)
        let historyLimit = max(pinned.historyLimit ?? historySize, 0)
        let availableHistory = min(historySize, historyLimit)
        let totalAvailable = availableHistory + pinned.paneRows
        let wantedLines = min(request.maxLines, max(totalAvailable, 1))
        let startLine = pinned.paneRows - wantedLines
        let capture = try await captureExecutor.capture(
            paneID: pinned.paneID,
            startLine: startLine,
            maximumBytes: request.maxBytes,
            timeout: .seconds(10)
        )
        let parsed = TmuxHistoryCaptureParser().parse(
            capture.data,
            maximumLines: wantedLines,
            maximumBytes: request.maxBytes
        )

        // A capture is immutable, but it is not published if the verified data client moved
        // while the separate read-only channel was collecting it.
        let current = try await resolve()
        guard current.paneID == pinned.paneID,
              current.state.target == request.target
        else {
            throw TmuxInteractionError.activePaneUnavailable
        }
        let visibleCount = min(pinned.paneRows, parsed.lines.count)
        let visibleStart = parsed.lines.count - visibleCount
        return PersistentTerminalHistorySnapshot(
            target: request.target,
            attachmentGeneration: request.attachmentGeneration,
            stateRevision: request.expectedStateRevision,
            capturedAt: clock(),
            lines: parsed.lines,
            visibleLineRange: visibleStart ..< parsed.lines.count,
            isTruncated: capture.isTruncated
                || parsed.isTruncated
                || wantedLines < totalAvailable,
            byteCount: parsed.byteCount
        )
    }

    private func validate(
        _ request: PersistentTerminalHistoryRequest,
        against state: PersistentTerminalInteractionState
    ) throws {
        guard request.target == state.target else {
            throw PersistentTerminalInteractionError.targetMismatch
        }
        guard request.attachmentGeneration == state.attachmentGeneration else {
            throw PersistentTerminalInteractionError.staleAttachmentGeneration
        }
        guard request.expectedStateRevision == state.revision else {
            throw PersistentTerminalInteractionError.staleStateRevision
        }
    }

}

package actor TmuxInteractionFacet: PersistentTerminalInteractionFacet {
    package nonisolated let states: AsyncStream<PersistentTerminalInteractionState>
    private nonisolated let continuation:
        AsyncStream<PersistentTerminalInteractionState>.Continuation
    private let historyBackend: TmuxOneShotInteractionBackend
    private let attachmentGeneration: UInt64
    private var controlLease: TmuxProviderControlInteractionLease?
    private var observationTask: Task<Void, Never>?
    private var latestState: PersistentTerminalInteractionState?
    private var closed = false

    package init(
        attachmentGeneration: UInt64,
        historyBackend: TmuxOneShotInteractionBackend
    ) {
        self.attachmentGeneration = attachmentGeneration
        self.historyBackend = historyBackend
        let stream = PersistentTerminalInteractionStreams.makeStateStream()
        states = stream.stream
        continuation = stream.continuation
    }

    public var quickActionGroup: PersistentTerminalQuickActionGroup? {
        get async {
            guard !closed else { return nil }
            return TmuxTerminalQuickAction.group
        }
    }

    package func install(_ lease: TmuxProviderControlInteractionLease) async {
        guard !closed, lease.attachmentGeneration == attachmentGeneration else {
            await lease.registry.release(lease)
            return
        }
        if let previous = controlLease {
            await previous.registry.release(previous)
        }
        observationTask?.cancel()
        controlLease = lease
        observationTask = Task { [weak self] in
            for await snapshot in lease.snapshots {
                guard !Task.isCancelled else { return }
                await self?.accept(snapshot, from: lease)
            }
        }
    }

    public func resolveState() async throws -> PersistentTerminalInteractionState {
        guard !closed else { throw TmuxInteractionError.closed }
        guard let controlLease,
              await controlLease.registry.hasReadyControlRuntime(controlLease)
        else {
            throw PersistentTerminalError.controlModeUnavailable
        }
        let state = try await controlLease.registry.resolveInteraction(controlLease)
        publish(state)
        return state
    }

    public func captureHistory(
        _ request: PersistentTerminalHistoryRequest
    ) async throws -> PersistentTerminalHistorySnapshot {
        guard !closed else { throw TmuxInteractionError.closed }
        guard let lease = controlLease,
              await lease.registry.hasReadyControlRuntime(lease)
        else {
            throw PersistentTerminalError.controlModeUnavailable
        }
        let pinned = try await lease.registry.resolveInteractionContext(
            lease,
            refreshIfNeeded: false
        )
        return try await historyBackend.captureHistory(request, pinned: pinned)
    }

    public func scrollProviderMode(
        _ request: PersistentTerminalModeScrollRequest
    ) async throws {
        guard !closed else { throw TmuxInteractionError.closed }
        guard request.attachmentGeneration == attachmentGeneration else {
            throw PersistentTerminalInteractionError.staleAttachmentGeneration
        }
        guard let controlLease,
              await controlLease.registry.hasReadyControlRuntime(controlLease)
        else {
            throw PersistentTerminalError.controlModeUnavailable
        }
        try await controlLease.registry.scrollInteraction(controlLease, request: request)
    }

    public func performQuickAction(
        _ request: PersistentTerminalQuickActionRequest
    ) async throws {
        guard !closed else { throw TmuxInteractionError.closed }
        guard request.attachmentGeneration == attachmentGeneration else {
            throw PersistentTerminalInteractionError.staleAttachmentGeneration
        }
        guard let controlLease,
              await controlLease.registry.hasReadyControlRuntime(controlLease)
        else {
            throw PersistentTerminalError.controlModeUnavailable
        }
        try await controlLease.registry.performQuickAction(
            controlLease,
            request: request
        )
    }

    package func close() async {
        guard !closed else { return }
        closed = true
        observationTask?.cancel()
        observationTask = nil
        continuation.finish()
        if let controlLease {
            self.controlLease = nil
            await controlLease.registry.release(controlLease)
        }
    }

    private func accept(
        _ snapshot: TmuxServerSnapshot,
        from lease: TmuxProviderControlInteractionLease
    ) {
        guard !closed,
              controlLease?.registrationID == lease.registrationID,
              lease.attachmentGeneration == attachmentGeneration,
              let state = try? TmuxInteractionStateProjector().project(
                  snapshot: snapshot,
                  identity: lease.identity,
                  attachmentGeneration: attachmentGeneration
              )
        else { return }
        publish(state)
    }

    private func publish(_ state: PersistentTerminalInteractionState) {
        latestState = state
        continuation.yield(state)
    }
}
