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
    /// - 用户输入（delegate.send）→ `session.send`
    /// - 尺寸变化（delegate.sizeChanged）→ `session.resize`（SIGWINCH）
    public struct TerminalHostingView: UIViewRepresentable {
        private let session: TerminalSession
        private let theme: TerminalTheme

        public init(session: TerminalSession, theme: TerminalTheme = .conn) {
            self.session = session
            self.theme = theme
        }

        public func makeUIView(context: Context) -> TerminalView {
            let terminalView = TerminalView(frame: .zero)
            terminalView.terminalDelegate = context.coordinator
            applyTheme(to: terminalView)

            // 启动会话泵送：session 输出（已合帧）投给终端。feed 必须在主线程。
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

        public func updateUIView(_ terminalView: TerminalView, context: Context) {
            applyTheme(to: terminalView)
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(session: session)
        }

        private func applyTheme(to terminalView: TerminalView) {
            let terminal = terminalView.getTerminal()
            // 把主题数据转成 SwiftTerm 的调色板类型——这是数据转换而非 UI 样式
            // 硬编码，配色本身已由 TerminalTheme 集中管理。
            func color(_ rgb: TerminalTheme.RGB) -> SwiftTerm.Color {
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

        /// 桥接 SwiftTerm delegate → TerminalSession。
        public final class Coordinator: NSObject, TerminalViewDelegate {
            private let session: TerminalSession
            weak var terminalView: TerminalView?

            init(session: TerminalSession) {
                self.session = session
            }

            /// 必实现：用户按键 → 会话
            public func send(source: TerminalView, data: ArraySlice<UInt8>) {
                let bytes = [UInt8](data)
                Task { await session.send(bytes) }
            }

            /// 必实现：终端尺寸变化 → PTY resize
            public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
                Task { await session.resize(cols: newCols, rows: newRows) }
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
#endif
