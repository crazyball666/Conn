#if canImport(UIKit)
    import ConnUI
    import SwiftUI
    import UIKit

    public enum TerminalKeybarMetrics {
        public static let compactHeight: CGFloat = 92
        public static let expandedHeight: CGFloat = 220
    }

    /// 终端加速键条（原型 S4 / 技术方案 §4.2）。
    ///
    /// 与终端视口同层、排列在其下方，系统键盘再排列在快捷键栏下方。
    /// Ctrl 为粘滞键，点亮后下一击组合。设计规范 §6：键盘触发动作**不动画**（高频）。
    struct TerminalKeybar: View {
        let ctrlActive: Bool
        let isExpanded: Bool
        let onKey: (TerminalKey) -> Void
        let onPaste: (String) -> Void
        let onChooseCommand: () -> Void
        let onReconnect: () -> Void
        let onDismissKeyboard: () -> Void
        let onExpansionChange: (Bool) -> Void

        /// 触感的触发源。每次按键自增一次，`sensoryFeedback` 只认「值变了」。
        ///
        /// 用计数器而不是「最后按下的键」：连按同一个键时后者的值不变，触感就不会响。
        @State private var pressCount = 0

        /// 摇杆边长 = 两行键帽 + 行距，正好跨满整个键条高度。
        private static let padSide: CGFloat = 34 * 2 + 6

        var body: some View {
            Group {
                if isExpanded {
                    expandedPanel
                } else {
                    compactPanel
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.connBar)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 1)
            }
            // 键帽按下给一记轻敲，与系统键盘的击键反馈同量级。
            // 不用 UIImpactFeedbackGenerator：那是 UIKit-only，而本文件虽在
            // `#if canImport(UIKit)` 内，声明式写法与仓库其它处（GroupFilterBar）一致。
            .sensoryFeedback(.impact(weight: .light), trigger: pressCount)
        }

        /// 日常输入保持两行：右侧摇杆不变，把低频翻页键移进展开面板，
        /// 腾出「安全粘贴」与「展开」两个高频入口。
        private var compactPanel: some View {
            HStack(spacing: 6) {
                VStack(spacing: 6) {
                    keyRow(TerminalKeybarLayout.compactRows[0])
                    HStack(spacing: 6) {
                        actionCap(
                            systemName: "keyboard.chevron.compact.down",
                            accessibilityLabel: L("收起键盘"),
                            identifier: "terminal.keybar.dismissKeyboard",
                            action: onDismissKeyboard
                        )
                        actionCap(
                            systemName: "arrow.clockwise",
                            accessibilityLabel: L("重新打开终端"),
                            identifier: "terminal.keybar.reconnect",
                            action: onReconnect
                        )
                        actionCap(
                            systemName: "command",
                            accessibilityLabel: L("选择本地脚本"),
                            identifier: "terminal.keybar.commands",
                            action: onChooseCommand
                        )
                        pasteCap
                        actionCap(
                            systemName: "chevron.up",
                            accessibilityLabel: L("展开快捷键"),
                            identifier: "terminal.keybar.expand"
                        ) {
                            onExpansionChange(true)
                        }
                    }
                }
                TerminalDirectionPad(onKey: onKey)
                    .frame(width: Self.padSide, height: Self.padSide)
            }
        }

        /// 完整面板使用固定高度，按键区内部滚动，所以 F1-F12 等低频键再多也不会
        /// 无限挤压终端视口。
        private var expandedPanel: some View {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    actionCap(
                        systemName: "chevron.down",
                        accessibilityLabel: L("收起快捷键"),
                        identifier: "terminal.keybar.collapse"
                    ) {
                        onExpansionChange(false)
                    }
                    pasteCap
                    actionCap(
                        systemName: "command",
                        accessibilityLabel: L("选择本地脚本"),
                        identifier: "terminal.keybar.commands",
                        action: onChooseCommand
                    )
                    actionCap(
                        systemName: "arrow.clockwise",
                        accessibilityLabel: L("重新打开终端"),
                        identifier: "terminal.keybar.reconnect",
                        action: onReconnect
                    )
                    actionCap(
                        systemName: "keyboard.chevron.compact.down",
                        accessibilityLabel: L("收起键盘"),
                        identifier: "terminal.keybar.dismissKeyboard",
                        action: onDismissKeyboard
                    )
                }
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                        spacing: 6
                    ) {
                        ForEach(TerminalKeybarLayout.expandedKeys) { key in
                            keyCap(key)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }

        private func keyRow(_ keys: [TerminalKey]) -> some View {
            HStack(spacing: 6) {
                ForEach(keys) { key in
                    keyCap(key)
                }
            }
        }

        private func keyCap(_ key: TerminalKey) -> some View {
            let isLit = key.isSticky && ctrlActive
            return Button {
                pressCount &+= 1
                onKey(key)
            } label: {
                Text(key.label)
                    .font(.connData(.footnote))
                    .foregroundStyle(isLit ? Color.connAccent : .connInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        isLit ? Color.connAccentFill : Color.connKey,
                        in: .rect(cornerRadius: ConnRadius.key, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                            .strokeBorder(isLit ? Color.connAccent : Color.connKeyline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(key.label)
        }

        /// 粘贴使用完整的普通按钮命中区；`PasteButton` 的透明覆盖层在终端键盘中
        /// 会吞掉点击，导致回调不触发。读取发生在用户明确点击后，符合系统剪贴板语义。
        private var pasteCap: some View {
            Button {
                guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                pressCount &+= 1
                onPaste(text)
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.connInk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.connKey, in: .rect(cornerRadius: ConnRadius.key, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .strokeBorder(Color.connKeyline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("粘贴")))
            .accessibilityIdentifier("terminal.keybar.paste")
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }

        private func actionCap(
            systemName: String,
            accessibilityLabel: String,
            identifier: String,
            action: @escaping () -> Void
        ) -> some View {
            Button {
                pressCount &+= 1
                action()
            } label: {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.connInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Color.connKey, in: .rect(cornerRadius: ConnRadius.key, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                            .strokeBorder(Color.connKeyline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityIdentifier(identifier)
        }
    }
#endif
