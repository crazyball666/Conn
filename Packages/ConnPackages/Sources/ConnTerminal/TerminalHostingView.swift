#if canImport(UIKit)
    import ConnSSH
    import ConnUI
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// SwiftUI 包装 SwiftTerm 的 `TerminalView`。
    ///
    /// SwiftTerm 无可用的官方 SwiftUI wrapper（库内的是 DEBUG-only internal），故自写。
    /// 数据面：`TerminalSession(actor)` 桥接 PTY；UI 面此视图。
    /// - session 输出 → `terminalView.feed`（session 已做 16ms 合帧）
    /// - 用户输入（delegate.send）→ 经 Ctrl 粘滞编码 → `session.send`
    /// - 尺寸变化（delegate.sizeChanged）→ `session.resize`（SIGWINCH）
    /// - 加速键条挂在 `inputAccessoryView`
    public struct TerminalHostingView: UIViewRepresentable {
        private let session: TerminalSession
        private let configuration: TerminalConfiguration

        public init(session: TerminalSession, configuration: TerminalConfiguration = .init()) {
            self.session = session
            self.configuration = configuration
        }

        public func makeUIView(context: Context) -> KeybarTerminalView {
            let terminalView = KeybarTerminalView(frame: .zero)
            terminalView.terminalDelegate = context.coordinator
            terminalView.configureKeybar(
                enabled: configuration.showsKeybar,
                coordinator: context.coordinator
            )
            applyConfiguration(to: terminalView)
            terminalView.configureContentPadding(horizontal: ConnSpacing.sm)

            let coordinator = context.coordinator
            coordinator.terminalView = terminalView
            Task {
                await session.start { bytes in
                    Task { @MainActor in
                        coordinator.terminalView?.feedFollowingLiveOutput(byteArray: bytes[...])
                    }
                }
            }
            return terminalView
        }

        public func updateUIView(_ terminalView: KeybarTerminalView, context: Context) {
            terminalView.configureKeybar(
                enabled: configuration.showsKeybar,
                coordinator: context.coordinator
            )
            applyConfiguration(to: terminalView)
            terminalView.configureContentPadding(horizontal: ConnSpacing.sm)
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(session: session)
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

        /// 桥接 SwiftTerm delegate → TerminalSession，并维护 Ctrl 粘滞态。
        public final class Coordinator: NSObject, TerminalViewDelegate, ObservableObject {
            private let session: TerminalSession
            weak var terminalView: KeybarTerminalView?
            /// Ctrl 粘滞态。改变时刷新键条高亮。
            @Published var ctrlActive = false

            init(session: TerminalSession) {
                self.session = session
            }

            /// 必实现：用户按键 → 经 Ctrl 粘滞编码 → 会话
            public func send(source: TerminalView, data: ArraySlice<UInt8>) {
                let (encoded, stillActive) = TerminalKeyEncoder.encode([UInt8](data), ctrlActive: ctrlActive)
                if ctrlActive != stillActive {
                    ctrlActive = stillActive
                    terminalView?.refreshKeybar()
                }
                Task { await session.send(encoded) }
            }

            /// 必实现：终端尺寸变化 → PTY resize
            public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
                Task { await session.resize(cols: newCols, rows: newRows) }
            }

            /// 键条按键处理。
            func handleKey(_ key: TerminalKey) {
                if key.isSticky {
                    ctrlActive.toggle()
                    terminalView?.refreshKeybar()
                    return
                }
                let (encoded, stillActive) = TerminalKeyEncoder.encode(key.bytes, ctrlActive: ctrlActive)
                if ctrlActive != stillActive {
                    ctrlActive = stillActive
                    terminalView?.refreshKeybar()
                }
                Task { await session.send(encoded) }
            }

            public func setTerminalTitle(source: TerminalView, title: String) {}
            public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            public func scrolled(source: TerminalView, position: Double) {}
            public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
            public func bell(source: TerminalView) {}
            public func clipboardCopy(source: TerminalView, content: Data) {}
            public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        }
    }

    /// 带加速键条的 `TerminalView` 子类。
    ///
    /// SwiftTerm 的 `TerminalView` 暴露了**可写**的 `inputAccessoryView`，直接赋值
    /// 挂上键条即可（无需覆盖）。
    public final class KeybarTerminalView: TerminalView {
        private weak var coordinator: TerminalHostingView.Coordinator?
        private var isKeybarEnabled = false
        /// 键条的宿主控制器。**必须强持有**——`inputAccessoryView` 只留住它的 `view`。
        private var keybarHost: UIHostingController<TerminalKeybar>?
        private var horizontalContentPadding: CGFloat = 0
        fileprivate var configuredCursorShape: TerminalCursorShape?
        fileprivate var configuredCursorBlinking: Bool?

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
            }
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

        func configureKeybar(enabled: Bool, coordinator: TerminalHostingView.Coordinator) {
            let needsRebuild = self.coordinator !== coordinator
                || isKeybarEnabled != enabled
                || (enabled && inputAccessoryView == nil)
            self.coordinator = coordinator
            isKeybarEnabled = enabled
            if needsRebuild {
                rebuildKeybar()
            }
        }

        func refreshKeybar() {
            guard isKeybarEnabled else { return }
            rebuildKeybar()
        }

        private func rebuildKeybar() {
            guard isKeybarEnabled, let coordinator else {
                keybarHost = nil
                inputAccessoryView = nil
                reloadInputViews()
                return
            }
            let keybar = TerminalKeybar(ctrlActive: coordinator.ctrlActive) { [weak coordinator] key in
                coordinator?.handleKey(key)
            }
            // **复用同一个 host，只换 rootView**，不要每次新建。
            //
            // 两个理由。其一，摇杆的长按连发与拖动手势活在这棵 SwiftUI 树的 @State 上：
            // Ctrl 亮着时拖方向键会消耗掉 Ctrl → ctrlActive 变化 → 走到这里，若整棵树
            // 被换掉，正在进行的连发会当场断掉。其二，原来的写法只把 `host.view` 挂给
            // `inputAccessoryView`，`UIHostingController` 本身没有任何强引用，创建完即
            // 失去持有者——SwiftUI 的生命周期就此悬空。
            if let host = keybarHost {
                host.rootView = keybar
                return
            }
            let host = UIHostingController(rootView: keybar)
            host.view.backgroundColor = .clear
            // 两行键 + 内边距，约 92pt 高
            host.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 92)
            host.view.autoresizingMask = [.flexibleWidth]
            keybarHost = host
            inputAccessoryView = host.view
            reloadInputViews()
        }
    }
#endif
