#if canImport(UIKit)
    import ConnSSH
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
        private let theme: TerminalTheme

        public init(session: TerminalSession, theme: TerminalTheme = .conn) {
            self.session = session
            self.theme = theme
        }

        public func makeUIView(context: Context) -> KeybarTerminalView {
            let terminalView = KeybarTerminalView(frame: .zero)
            terminalView.terminalDelegate = context.coordinator
            terminalView.installKeybar(coordinator: context.coordinator)
            applyTheme(to: terminalView)

            let coordinator = context.coordinator
            coordinator.terminalView = terminalView
            Task {
                await session.start { bytes in
                    Task { @MainActor in
                        coordinator.terminalView?.feed(byteArray: bytes[...])
                    }
                }
            }
            return terminalView
        }

        public func updateUIView(_ terminalView: KeybarTerminalView, context: Context) {
            applyTheme(to: terminalView)
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(session: session)
        }

        private func applyTheme(to terminalView: TerminalView) {
            let terminal = terminalView.getTerminal()
            func color(_ rgb: TerminalTheme.RGB) -> SwiftTerm.Color {
                // 主题数据转 SwiftTerm 调色板类型——数据转换，非 UI 样式硬编码。
                // swiftlint:disable:next no_hardcoded_hex
                SwiftTerm.Color(red: UInt16(rgb.r) * 257, green: UInt16(rgb.g) * 257, blue: UInt16(rgb.b) * 257)
            }
            terminal.installPalette(colors: theme.ansi.map(color))
            terminalView.nativeBackgroundColor = uiColor(theme.background)
            terminalView.nativeForegroundColor = uiColor(theme.foreground)
            terminalView.caretColor = uiColor(theme.cursor)
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

        /// 进入窗口后自动聚焦，弹出软键盘与加速键条（无需用户先点一下）。
        override public func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.becomeFirstResponder()
                }
            }
        }

        func installKeybar(coordinator: TerminalHostingView.Coordinator) {
            self.coordinator = coordinator
            rebuildKeybar()
        }

        func refreshKeybar() {
            rebuildKeybar()
        }

        private func rebuildKeybar() {
            guard let coordinator else { return }
            let keybar = TerminalKeybar(ctrlActive: coordinator.ctrlActive) { [weak coordinator] key in
                coordinator?.handleKey(key)
            }
            let host = UIHostingController(rootView: keybar)
            host.view.backgroundColor = .clear
            // 两行键 + 内边距，约 92pt 高
            host.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 92)
            host.view.autoresizingMask = [.flexibleWidth]
            inputAccessoryView = host.view
            reloadInputViews()
        }
    }
#endif
