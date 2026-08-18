#if canImport(UIKit)
    import ConnMultiplexer
    import ConnUI
    import SwiftUI
    import UIKit

    public enum TerminalKeybarMetrics {
        public static let compactHeight: CGFloat = 46
        public static let expandedHeight: CGFloat = 168
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
        let pointerAvailable: Bool
        let pointerActive: Bool
        let onTogglePointer: () -> Void
        let providerQuickActionGroup: PersistentTerminalQuickActionGroup?
        let performingProviderQuickActionID: String?
        let onProviderQuickAction: (String, String?, Bool) -> Void
        let keyboardVisible: Bool
        let onToggleKeyboard: () -> Void
        let onExpansionChange: (Bool) -> Void

        /// 触感的触发源。每次按键自增一次，`sensoryFeedback` 只认「值变了」。
        ///
        /// 用计数器而不是「最后按下的键」：连按同一个键时后者的值不变，触感就不会响。
        @State private var pressCount = 0
        @State private var expandedSection: ExpandedSection = .common
        @State private var pendingTextInputAction: PersistentTerminalQuickActionDescriptor?
        @State private var pendingConfirmationAction: PersistentTerminalQuickActionDescriptor?
        @State private var quickActionText = ""

        private enum ExpandedSection: String {
            case common
            case provider
        }

        private static let hitTargetHeight: CGFloat = 40
        private static let capVisualHeight: CGFloat = 32
        private static let compactCapWidth: CGFloat = 38
        private static let compactPadSide: CGFloat = 40

        var body: some View {
            Group {
                if isExpanded {
                    expandedPanel
                } else {
                    compactPanel
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(Color.connBar)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 1)
            }
            .sensoryFeedback(ConnHapticFeedback.highImpact, trigger: pressCount)
            .onChange(of: providerQuickActionGroup?.id) { _, groupID in
                if groupID == nil {
                    expandedSection = .common
                    pendingTextInputAction = nil
                    pendingConfirmationAction = nil
                }
            }
            .alert(
                pendingTextInputAction.map { L($0.textInput?.titleKey ?? $0.titleKey) } ?? "",
                isPresented: Binding(
                    get: { pendingTextInputAction != nil },
                    set: { if !$0 { pendingTextInputAction = nil } }
                )
            ) {
                if let input = pendingTextInputAction?.textInput {
                    TextField(L(input.placeholderKey), text: $quickActionText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button(L("取消"), role: .cancel) {
                    pendingTextInputAction = nil
                }
                Button(L("执行")) {
                    guard let action = pendingTextInputAction else { return }
                    let value = quickActionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingTextInputAction = nil
                    onProviderQuickAction(action.id, value, false)
                }
                .disabled(quickActionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog(
                pendingConfirmationAction?.confirmation.map { L($0.titleKey) } ?? "",
                isPresented: Binding(
                    get: { pendingConfirmationAction != nil },
                    set: { if !$0 { pendingConfirmationAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let action = pendingConfirmationAction {
                    Button(L(action.titleKey), role: .destructive) {
                        pendingConfirmationAction = nil
                        onProviderQuickAction(action.id, nil, true)
                    }
                }
                Button(L("取消"), role: .cancel) {
                    pendingConfirmationAction = nil
                }
            }
        }

        /// 日常输入使用一行高密度快捷栏；四个方向合并为固定方向盘，其他按键横向
        /// 滚动。这样方向始终可触达，同时比四个独立箭头多显示三个常用键位。
        private var compactPanel: some View {
            HStack(spacing: 4) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(TerminalKeybarLayout.compactKeys) { key in
                            keyCap(key, width: Self.compactCapWidth)
                        }
                        pasteCap(width: Self.compactCapWidth)
                    }
                }
                .scrollIndicators(.hidden)

                fixedCommandCap
                expansionCap(expanded: false)
                keyboardCap

                TerminalDirectionPad(onKey: onKey)
                    .frame(width: Self.compactPadSide, height: Self.compactPadSide)
            }
        }

        /// 完整面板使用固定高度，按键区内部滚动，所以 F1-F12 等低频键再多也不会
        /// 无限挤压终端视口。
        private var expandedPanel: some View {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    expansionCap(expanded: true)

                    expandedTab(
                        title: L("常用"),
                        section: .common,
                        identifier: "terminal.keybar.tab.common"
                    )
                    if let providerQuickActionGroup {
                        expandedTab(
                            title: providerQuickActionGroup.title,
                            section: .provider,
                            identifier: "terminal.keybar.tab.\(providerQuickActionGroup.id)"
                        )
                    }

                    Spacer(minLength: 0)
                    fixedCommandCap
                    keyboardCap
                }

                if expandedSection == .provider, let providerQuickActionGroup {
                    providerPanel(providerQuickActionGroup)
                } else {
                    commonPanel
                }
            }
        }

        private var commonPanel: some View {
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                    spacing: 6
                ) {
                    pasteCap()
                    actionCap(
                        systemName: "arrow.clockwise",
                        accessibilityLabel: L("重新打开终端"),
                        identifier: "terminal.keybar.reconnect",
                        action: onReconnect
                    )
                    if pointerAvailable {
                        pointerCap
                    }
                    ForEach(TerminalKeybarLayout.expandedKeys) { key in
                        keyCap(key)
                    }
                }
            }
            .scrollIndicators(.visible)
        }

        private func providerPanel(
            _ group: PersistentTerminalQuickActionGroup
        ) -> some View {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(group.sections) { section in
                        Text(L(section.titleKey))
                            .font(.connData(.caption2))
                            .foregroundStyle(Color.connMuted)
                            .padding(.leading, 2)
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 6),
                                count: 5
                            ),
                            spacing: 6
                        ) {
                            ForEach(section.actions) { action in
                                providerActionCap(action, groupID: group.id)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
        }

        private func expandedTab(
            title: String,
            section: ExpandedSection,
            identifier: String
        ) -> some View {
            let isSelected = expandedSection == section
            return Button {
                pressCount &+= 1
                expandedSection = section
            } label: {
                Text(title)
                    .font(.connData(.caption))
                    .foregroundStyle(isSelected ? Color.connAccent : Color.connMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        isSelected ? Color.connAccentFill : Color.clear,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? Color.connAccent : Color.connKeyline,
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        }

        private func providerActionCap(
            _ action: PersistentTerminalQuickActionDescriptor,
            groupID: String
        ) -> some View {
            let isPerforming = performingProviderQuickActionID == action.id
            return Button {
                pressCount &+= 1
                if action.confirmation != nil {
                    pendingConfirmationAction = action
                } else if action.textInput != nil {
                    quickActionText = ""
                    pendingTextInputAction = action
                } else {
                    onProviderQuickAction(action.id, nil, false)
                }
            } label: {
                VStack(spacing: 2) {
                    if isPerforming {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: action.systemImageName)
                            .font(.system(size: 14, weight: .medium))
                    }
                    Text(L(action.titleKey))
                        .font(.connData(.caption2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(Color.connInk)
                .frame(maxWidth: .infinity)
                .frame(height: Self.capVisualHeight)
                .background(Color.connKey, in: .rect(cornerRadius: ConnRadius.key, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .strokeBorder(Color.connKeyline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(performingProviderQuickActionID != nil)
            .accessibilityLabel(Text(L(action.titleKey)))
            .accessibilityIdentifier("terminal.keybar.\(groupID).\(action.id)")
            .frame(height: Self.hitTargetHeight)
        }

        private func keyCap(_ key: TerminalKey, width: CGFloat? = nil) -> some View {
            let isLit = key.isSticky && ctrlActive
            return Button {
                pressCount &+= 1
                onKey(key)
            } label: {
                Text(key.label)
                    .font(.connData(.footnote))
                    .foregroundStyle(isLit ? Color.connAccent : .connInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.capVisualHeight)
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
            .frame(width: width, height: Self.hitTargetHeight)
        }

        /// 粘贴使用完整的普通按钮命中区；`PasteButton` 的透明覆盖层在终端键盘中
        /// 会吞掉点击，导致回调不触发。读取发生在用户明确点击后，符合系统剪贴板语义。
        private func pasteCap(width: CGFloat? = nil) -> some View {
            Button {
                guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                pressCount &+= 1
                onPaste(text)
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.connInk)
                .frame(maxWidth: .infinity)
                .frame(height: Self.capVisualHeight)
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
            .frame(width: width, height: Self.hitTargetHeight)
        }

        private var pointerCap: some View {
            Button {
                pressCount &+= 1
                onTogglePointer()
            } label: {
                Image(systemName: pointerActive ? "cursorarrow.rays" : "cursorarrow")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(pointerActive ? Color.connAccent : Color.connInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.capVisualHeight)
                    .background(
                        pointerActive ? Color.connAccentFill : Color.connKey,
                        in: .rect(cornerRadius: ConnRadius.key, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                            .strokeBorder(pointerActive ? Color.connAccent : Color.connKeyline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pointerActive ? L("关闭远端指针模式") : L("开启远端指针模式")))
            .accessibilityIdentifier("terminal.keybar.pointer")
            .frame(maxWidth: .infinity)
            .frame(height: Self.hitTargetHeight)
        }

        private func actionCap(
            systemName: String,
            accessibilityLabel: String,
            identifier: String,
            width: CGFloat? = nil,
            action: @escaping () -> Void
        ) -> some View {
            Button {
                pressCount &+= 1
                action()
            } label: {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.connInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.capVisualHeight)
                    .background(Color.connKey, in: .rect(cornerRadius: ConnRadius.key, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                            .strokeBorder(Color.connKeyline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityIdentifier(identifier)
            .frame(width: width, height: Self.hitTargetHeight)
        }

        private var fixedCommandCap: some View {
            actionCap(
                systemName: "command",
                accessibilityLabel: L("选择本地脚本"),
                identifier: "terminal.keybar.commands",
                width: Self.compactCapWidth,
                action: onChooseCommand
            )
        }

        private func expansionCap(expanded: Bool) -> some View {
            actionCap(
                systemName: expanded ? "chevron.down" : "chevron.up",
                accessibilityLabel: expanded ? L("收起快捷键") : L("展开快捷键"),
                identifier: expanded ? "terminal.keybar.collapse" : "terminal.keybar.expand",
                width: Self.compactCapWidth
            ) {
                onExpansionChange(!expanded)
            }
        }

        private var keyboardCap: some View {
            actionCap(
                systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                accessibilityLabel: keyboardVisible ? L("收起键盘") : L("显示键盘"),
                identifier: "terminal.keybar.dismissKeyboard",
                width: Self.compactCapWidth,
                action: onToggleKeyboard
            )
        }
    }
#endif
