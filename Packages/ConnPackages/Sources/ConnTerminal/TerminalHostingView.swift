#if canImport(UIKit)
    import ConnSSH
    import ConnUI
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// SwiftUI 终端容器。
    ///
    /// 终端视口与快捷键栏是同一个 `VStack` 里的相邻区域；系统键盘位于两者下方。
    /// 快捷键栏展开时会真实压缩终端视口，不再通过 `inputAccessoryView` 悬浮覆盖内容。
    public struct TerminalHostingView: View {
        private let session: TerminalSession
        private let transcript: TerminalTranscript
        private let configuration: TerminalConfiguration
        private let onChooseCommand: () -> Void
        private let onReconnect: () -> Void

        public init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            configuration: TerminalConfiguration = .init(),
            onChooseCommand: @escaping () -> Void = {},
            onReconnect: @escaping () -> Void = {}
        ) {
            self.session = session
            self.transcript = transcript
            self.configuration = configuration
            self.onChooseCommand = onChooseCommand
            self.onReconnect = onReconnect
        }

        public var body: some View {
            TerminalHostContent(
                session: session,
                transcript: transcript,
                configuration: configuration,
                onChooseCommand: onChooseCommand,
                onReconnect: onReconnect
            )
            // 重连会换一个 TerminalSession；显式换身份，避免 @StateObject 继续持有旧会话。
            .id(ObjectIdentifier(session))
        }
    }

    private struct TerminalHostContent: View {
        @StateObject private var controller: TerminalInputController
        @State private var isKeybarExpanded: Bool

        private let configuration: TerminalConfiguration
        private let onChooseCommand: () -> Void
        private let onReconnect: () -> Void

        init(
            session: TerminalSession,
            transcript: TerminalTranscript,
            configuration: TerminalConfiguration,
            onChooseCommand: @escaping () -> Void,
            onReconnect: @escaping () -> Void
        ) {
            _controller = StateObject(wrappedValue: TerminalInputController(session: session, transcript: transcript))
            _isKeybarExpanded = State(
                initialValue: ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_EXPANDED"] != nil
            )
            self.configuration = configuration
            self.onChooseCommand = onChooseCommand
            self.onReconnect = onReconnect
        }

        var body: some View {
            VStack(spacing: 0) {
                TerminalViewportRepresentable(
                    configuration: configuration,
                    controller: controller
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if configuration.showsKeybar, controller.isTerminalFocused {
                    TerminalKeybar(
                        ctrlActive: controller.ctrlActive,
                        isExpanded: isKeybarExpanded,
                        onKey: controller.handleKey,
                        onPaste: controller.handlePaste,
                        onChooseCommand: onChooseCommand,
                        onReconnect: onReconnect,
                        onDismissKeyboard: controller.dismissKeyboard,
                        onExpansionChange: { isKeybarExpanded = $0 }
                    )
                    .frame(
                        height: isKeybarExpanded
                            ? TerminalKeybarMetrics.expandedHeight
                            : TerminalKeybarMetrics.compactHeight
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("terminal.keybar")
                }
            }
            .onChange(of: controller.isTerminalFocused) { _, isFocused in
                if !isFocused {
                    isKeybarExpanded = false
                }
            }
            .onDisappear { controller.detach() }
        }
    }

    /// 只包装 SwiftTerm 视口；快捷键栏由上层 SwiftUI 布局负责。
    private struct TerminalViewportRepresentable: UIViewRepresentable {
        let configuration: TerminalConfiguration
        let controller: TerminalInputController

        func makeUIView(context: Context) -> KeybarTerminalView {
            let terminalView = KeybarTerminalView(frame: .zero)
            terminalView.accessibilityIdentifier = "terminal.viewport"
            terminalView.terminalDelegate = controller
            terminalView.onFirstResponderChange = controller.setTerminalFocused
            applyConfiguration(to: terminalView)
            terminalView.configureContentPadding(horizontal: ConnSpacing.sm)
            controller.attach(terminalView)
            return terminalView
        }

        func updateUIView(_ terminalView: KeybarTerminalView, context: Context) {
            applyConfiguration(to: terminalView)
            terminalView.configureContentPadding(horizontal: ConnSpacing.sm)
        }

        static func dismantleUIView(_ terminalView: KeybarTerminalView, coordinator: Void) {
            terminalView.onFirstResponderChange = nil
        }

        private func applyConfiguration(to terminalView: KeybarTerminalView) {
            let fontSize = CGFloat(configuration.fontSize)
            if abs(terminalView.font.pointSize - fontSize) > 0.01 {
                terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }

            let terminal = terminalView.getTerminal()
            if terminal.options.scrollback != configuration.scrollback {
                terminalView.changeScrollback(configuration.scrollback)
            }

            let cursorStyle = swiftTermCursorStyle
            if terminalView.configuredCursorShape != configuration.cursorShape
                || terminalView.configuredCursorBlinking != configuration.cursorBlinking {
                terminal.options.cursorStyle = cursorStyle
                terminalView.cursorStyleChanged(source: terminal, newStyle: cursorStyle)
                terminalView.configuredCursorShape = configuration.cursorShape
                terminalView.configuredCursorBlinking = configuration.cursorBlinking
            }

            func color(_ rgb: TerminalTheme.RGB) -> SwiftTerm.Color {
                // 主题数据转 SwiftTerm 调色板类型——数据转换，非 UI 样式硬编码。
                // swiftlint:disable:next no_hardcoded_hex
                SwiftTerm.Color(red: UInt16(rgb.r) * 257, green: UInt16(rgb.g) * 257, blue: UInt16(rgb.b) * 257)
            }
            let theme = configuration.theme
            terminal.installPalette(colors: theme.ansi.map(color))
            terminalView.nativeBackgroundColor = uiColor(theme.background)
            terminalView.nativeForegroundColor = uiColor(theme.foreground)
            terminalView.caretColor = uiColor(theme.cursor)
        }

        private var swiftTermCursorStyle: SwiftTerm.CursorStyle {
            switch (configuration.cursorShape, configuration.cursorBlinking) {
            case (.block, true): .blinkBlock
            case (.block, false): .steadyBlock
            case (.bar, true): .blinkBar
            case (.bar, false): .steadyBar
            case (.underline, true): .blinkUnderline
            case (.underline, false): .steadyUnderline
            }
        }

        private func uiColor(_ rgb: TerminalTheme.RGB) -> UIColor {
            UIColor(
                red: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1
            )
        }

    }

    /// SwiftTerm delegate、会话输入和 SwiftUI 键条共享的单一状态源。
    private final class TerminalInputController: NSObject, TerminalViewDelegate, ObservableObject {
        private let session: TerminalSession
        private let transcript: TerminalTranscript
        private let replayOutboundGate = TerminalReplayOutboundGate()
        private var renderTask: Task<Void, Never>?
        private var attachmentID: UUID?
        weak var terminalView: KeybarTerminalView?

        @Published var ctrlActive = false
        @Published private(set) var isTerminalFocused = false

        init(session: TerminalSession, transcript: TerminalTranscript) {
            self.session = session
            self.transcript = transcript
        }

        func attach(_ terminalView: KeybarTerminalView) {
            detach()
            self.terminalView = terminalView
            replayOutboundGate.beginReplay()
            renderTask = Task { @MainActor [weak self] in
                await self?.renderTranscript()
            }
        }

        func detach() {
            renderTask?.cancel()
            renderTask = nil
            guard let attachmentID else { return }
            self.attachmentID = nil
            Task { [transcript] in
                await transcript.detach(attachmentID)
            }
        }

        @MainActor
        private func renderTranscript() async {
            var isReplayGateActive = true
            defer {
                if isReplayGateActive {
                    replayOutboundGate.finishReplay()
                }
            }

            let attachment = await transcript.attach()
            attachmentID = attachment.id
            // `onDisappear` 可能恰好发生在 await attach 期间；此时 detach 尚拿不到
            // attachmentID。建立订阅后立即补查取消态，避免留下无人消费的 output stream。
            guard !Task.isCancelled else {
                await transcript.detach(attachment.id)
                attachmentID = nil
                return
            }
            for await event in attachment.events {
                guard !Task.isCancelled else { break }
                guard let terminalView else { continue }
                switch event {
                case let .replayStarted(requiresReset):
                    if requiresReset {
                        terminalView.getTerminal().resetToInitialState()
                    }
                case let .replayBytes(bytes), let .liveBytes(bytes):
                    terminalView.feedFollowingLiveOutput(byteArray: bytes[...])
                case let .replayFinished(viewport):
                    replayOutboundGate.finishReplay()
                    isReplayGateActive = false
                    if viewport.followsLiveOutput {
                        terminalView.scroll(toPosition: 1)
                    } else {
                        terminalView.scroll(toPosition: viewport.scrollPosition)
                    }
                case .generationBoundary:
                    terminalView.feedFollowingLiveOutput(byteArray: TerminalTranscript.generationBoundaryBytes[...])
                }
            }
            await transcript.detach(attachment.id)
            if attachmentID == attachment.id {
                attachmentID = nil
            }
        }

        func setTerminalFocused(_ isFocused: Bool) {
            guard isTerminalFocused != isFocused else { return }
            isTerminalFocused = isFocused
        }

        /// 用户按键 → 经 Ctrl 粘滞编码 → 会话。
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm 会通过同一个 delegate 回传用户按键和终端查询响应。
            // 历史控制序列回放期间只允许渲染，禁止把旧查询的新响应写入当前 PTY。
            guard replayOutboundGate.allowsTerminalDelegateOutput else { return }
            let (encoded, stillActive) = TerminalKeyEncoder.encode([UInt8](data), ctrlActive: ctrlActive)
            ctrlActive = stillActive
            Task { try? await session.send(encoded) }
        }

        /// 终端尺寸变化 → PTY resize。
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { try? await session.resize(cols: newCols, rows: newRows) }
        }

        func handleKey(_ key: TerminalKey) {
            if key.isSticky {
                ctrlActive.toggle()
                return
            }
            let (encoded, stillActive) = TerminalKeyEncoder.encode(key.bytes, ctrlActive: ctrlActive)
            ctrlActive = stillActive
            Task { try? await session.send(encoded) }
        }

        func handlePaste(_ text: String) {
            Task { try? await session.send(Array(text.utf8)) }
        }

        func dismissKeyboard() {
            _ = terminalView?.resignFirstResponder()
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {
            let state = TerminalViewportState(
                followsLiveOutput: !source.canScroll || position >= 1,
                scrollPosition: position
            )
            Task { [transcript] in
                await transcript.updateViewport(state)
            }
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// 负责终端绘制、滚动与焦点通知的 `TerminalView` 子类。
    public final class KeybarTerminalView: TerminalView {
        var onFirstResponderChange: ((Bool) -> Void)?
        private var horizontalContentPadding: CGFloat = 0
        fileprivate var configuredCursorShape: TerminalCursorShape?
        fileprivate var configuredCursorBlinking: Bool?

        override public init(frame: CGRect) {
            super.init(frame: frame)
            configureViewportInsets()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureViewportInsets()
        }

        /// SwiftUI 通过键盘安全区直接改变终端的真实高度，SwiftTerm 再据此重算行数。
        /// 禁止 `UIScrollView` 同时按安全区自动追加 adjusted inset，否则在
        /// 收起—再次弹出键盘后会对底部高度重复补偿，留下可滚动空白。
        private func configureViewportInsets() {
            contentInsetAdjustmentBehavior = .never
            hostManagesTouchGestures = true
            // SwiftTerm 默认会创建一排 Esc/Ctrl/方向键等输入附件。Conn 已有与终端
            // 同层的自定义快捷键栏，必须显式关闭默认附件，否则键盘上方会出现重复栏。
            inputAccessoryView = nil
        }

        /// SwiftTerm 将选择浮标画在文字坐标边缘。终端自身全宽、文字内容内移后，
        /// 浮标仍处于控件可绘制范围内，不会被左右边界裁切。
        func configureContentPadding(horizontal padding: CGFloat) {
            let padding = max(0, padding)
            horizontalContentPadding = padding
            contentInset = UIEdgeInsets(
                top: contentInset.top,
                left: padding,
                bottom: contentInset.bottom,
                right: padding
            )
            verticalScrollIndicatorInsets = UIEdgeInsets(
                top: verticalScrollIndicatorInsets.top,
                left: padding,
                bottom: verticalScrollIndicatorInsets.bottom,
                right: padding
            )
            horizontalScrollIndicatorInsets = UIEdgeInsets(
                top: horizontalScrollIndicatorInsets.top,
                left: padding,
                bottom: horizontalScrollIndicatorInsets.bottom,
                right: padding
            )
            applyContentLayout()
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            applyContentLayout()
        }

        override public var contentOffset: CGPoint {
            didSet {
                guard horizontalContentPadding > 0 else { return }
                let targetX = -horizontalContentPadding
                guard abs(contentOffset.x - targetX) > 0.01 else { return }
                super.contentOffset = CGPoint(x: targetX, y: contentOffset.y)
            }
        }

        /// 进入窗口后自动聚焦，弹出软键盘与加速键条（无需用户先点一下）。
        override public func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.becomeFirstResponder()
                }
            } else {
                onFirstResponderChange?(false)
            }
        }

        override public func becomeFirstResponder() -> Bool {
            let didBecome = super.becomeFirstResponder()
            if didBecome {
                onFirstResponderChange?(true)
            }
            return didBecome
        }

        override public func resignFirstResponder() -> Bool {
            let didResign = super.resignFirstResponder()
            if didResign {
                onFirstResponderChange?(false)
            }
            return didResign
        }

        /// 输出流到达时保持“跟随实时输出”的语义。
        ///
        /// SwiftTerm 已经能区分实时跟随和用户手动回看，这里在 feed 前捕获状态，
        /// feed 后显式恢复底部位置，避免视口尺寸变化或批量输出时停在旧位置。
        /// 用户主动上翻后 `scrollPosition < 1`，不会被新输出抢回底部。
        func feedFollowingLiveOutput(byteArray: ArraySlice<UInt8>) {
            let wasFollowingLiveOutput = !canScroll || scrollPosition >= 1
            feed(byteArray: byteArray)
            if wasFollowingLiveOutput {
                scroll(toPosition: 1)
            }
        }

        private func applyContentLayout() {
            let usableWidth = bounds.width - horizontalContentPadding * 2
            let terminal = getTerminal()
            guard horizontalContentPadding > 0,
                  usableWidth > 0,
                  terminal.cols > 0 else {
                return
            }

            let cellWidth = getOptimalFrameSize().width / CGFloat(terminal.cols)
            guard cellWidth > 0 else { return }

            let targetColumns = max(1, Int(usableWidth / cellWidth))
            if targetColumns != terminal.cols {
                resize(cols: targetColumns, rows: terminal.rows)
            }

            let targetX = -horizontalContentPadding
            if abs(contentOffset.x - targetX) > 0.01 {
                contentOffset = CGPoint(x: targetX, y: contentOffset.y)
            }
        }

    }
#endif
