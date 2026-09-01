#if canImport(UIKit)
    import ConnMultiplexer
    import ConnUI
    import SwiftUI
    import UIKit

    /// 终端加速键条（原型 S4 / 技术方案 §4.2）。
    ///
    /// 与终端视口同层、排列在其下方，系统键盘再排列在快捷键栏下方。
    /// Ctrl 为粘滞键，点亮后下一击组合。设计规范 §6：键盘触发动作**不动画**（高频）。
    struct TerminalKeybar: View {
        let ctrlActive: Bool
        let isExpanded: Bool
        let onKey: (TerminalKey) -> Void
        let onPaste: (String) -> Void
        let onInsertToolCommand: (String) -> Void
        let onShowSessionActions: () -> Void
        let onChooseCommand: () -> Void
        let onReconnect: () -> Void
        let pointerAvailable: Bool
        let pointerActive: Bool
        let onTogglePointer: () -> Void
        let providerQuickActionGroup: PersistentTerminalQuickActionGroup?
        let performingProviderQuickActionID: String?
        let onProviderQuickAction: (PersistentTerminalQuickActionDescriptor) -> Void
        let keyboardVisible: Bool
        let onToggleKeyboard: () -> Void
        let onExpansionChange: (Bool) -> Void
        let attachmentState: TerminalAttachmentPanelState
        let onAttachmentAction: (TerminalAttachmentAction) -> Void

        /// 触感的触发源。每次按键自增一次，`sensoryFeedback` 只认「值变了」。
        ///
        /// 用计数器而不是「最后按下的键」：连按同一个键时后者的值不变，触感就不会响。
        @State private var pressCount = 0
        @State private var expandedSection: ExpandedSection = .common

        private enum ExpandedSection: String {
            case common
            case claudeCode
            case codex
            case upload
            case provider
        }

        var body: some View {
            VStack(spacing: isExpanded ? TerminalKeybarMetrics.gridSpacing : 0) {
                compactPanel(expanded: isExpanded)
                if isExpanded {
                    expandedPanel
                        .frame(
                            height: TerminalKeybarMetrics.expandedHeight
                                - TerminalKeybarMetrics.compactHeight
                                - TerminalKeybarMetrics.gridSpacing,
                            alignment: .top
                        )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity)
            .background(Color.connBar.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 1)
            }
            .sensoryFeedback(ConnHapticFeedback.highImpact, trigger: pressCount)
            .onChange(of: providerQuickActionGroup?.id) { _, groupID in
                if groupID == nil, expandedSection == .provider {
                    expandedSection = .common
                }
            }
        }

        /// 日常输入使用一行高密度快捷栏；四个方向合并为固定方向盘，其他按键横向
        /// 滚动。这样方向始终可触达，同时比四个独立箭头多显示三个常用键位。
        private func compactPanel(expanded: Bool) -> some View {
            HStack(spacing: 4) {
                sessionActionsCap

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(TerminalKeybarLayout.compactKeys) { key in
                            keyCap(key, width: TerminalKeybarMetrics.compactCapWidth)
                        }
                        pasteCap(width: TerminalKeybarMetrics.compactCapWidth)
                    }
                }
                .scrollIndicators(.hidden)

                fixedCommandCap
                expansionCap(expanded: expanded)
                keyboardCap

                TerminalDirectionPad(onKey: onKey)
                    .frame(
                        width: TerminalKeybarMetrics.compactPadSide,
                        height: TerminalKeybarMetrics.compactPadSide
                    )
                    .padding(.trailing, TerminalKeybarMetrics.directionPadTrailingInset)
            }
        }

        /// 展开态保留完整紧凑栏，只在其下方追加分类和内容。内容区内部滚动，
        /// 所以 F1-F12 等低频键再多也不会无限挤压终端视口。
        private var expandedPanel: some View {
            VStack(spacing: TerminalKeybarMetrics.gridSpacing) {
                ScrollView(.horizontal) {
                    HStack(spacing: TerminalKeybarMetrics.gridSpacing) {
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
                        expandedTab(
                            title: L("Claude Code"),
                            section: .claudeCode,
                            identifier: "terminal.keybar.tab.claude-code"
                        )
                        expandedTab(
                            title: L("Codex"),
                            section: .codex,
                            identifier: "terminal.keybar.tab.codex"
                        )
                        expandedTab(
                            title: L("上传"),
                            section: .upload,
                            identifier: "terminal.keybar.tab.upload"
                        )
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: TerminalKeybarMetrics.hitTargetHeight)

                Group {
                    if expandedSection == .provider, let providerQuickActionGroup {
                        providerPanel(providerQuickActionGroup)
                    } else if expandedSection == .claudeCode {
                        TerminalToolCommandPanelView(catalog: .claudeCode) { command in
                            pressCount &+= 1
                            onInsertToolCommand(command)
                        }
                    } else if expandedSection == .codex {
                        TerminalToolCommandPanelView(catalog: .codex) { command in
                            pressCount &+= 1
                            onInsertToolCommand(command)
                        }
                    } else if expandedSection == .upload {
                        TerminalAttachmentPanelView(state: attachmentState) { action in
                            pressCount &+= 1
                            onAttachmentAction(action)
                        }
                    } else {
                        commonPanel
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }

        private var commonPanel: some View {
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: TerminalKeybarMetrics.gridSpacing),
                        count: TerminalKeybarMetrics.commonColumnCount
                    ),
                    spacing: TerminalKeybarMetrics.gridSpacing
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
                    keyCap(.clearLine)
                    keyCap(.enter)
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
                LazyVStack(alignment: .leading, spacing: TerminalKeybarMetrics.gridSpacing) {
                    ForEach(group.sections) { section in
                        Text(L(section.titleKey))
                            .font(.connData(.caption2))
                            .foregroundStyle(Color.connMuted)
                            .padding(.leading, 2)
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(
                                    .flexible(),
                                    spacing: TerminalKeybarMetrics.gridSpacing
                                ),
                                count: TerminalKeybarMetrics.providerColumnCount
                            ),
                            spacing: TerminalKeybarMetrics.gridSpacing
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
                    .padding(.horizontal, 8)
                    .frame(height: TerminalKeybarMetrics.capVisualHeight)
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
            .frame(height: TerminalKeybarMetrics.hitTargetHeight)
        }

        private func providerActionCap(
            _ action: PersistentTerminalQuickActionDescriptor,
            groupID: String
        ) -> some View {
            let isPerforming = performingProviderQuickActionID == action.id
            return Button {
                pressCount &+= 1
                onProviderQuickAction(action)
            } label: {
                VStack(spacing: TerminalKeybarMetrics.providerContentSpacing) {
                    if isPerforming {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(
                                width: TerminalKeybarMetrics.providerIconSize,
                                height: TerminalKeybarMetrics.providerIconSize
                            )
                    } else {
                        Image(systemName: action.systemImageName)
                            .font(
                                .system(
                                    size: TerminalKeybarMetrics.providerIconSize,
                                    weight: .medium
                                )
                            )
                            .frame(height: TerminalKeybarMetrics.providerIconSize)
                    }
                    Text(L(action.titleKey))
                        .font(
                            .system(
                                size: TerminalKeybarMetrics.providerLabelSize,
                                weight: .regular,
                                design: .monospaced
                            )
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .allowsTightening(true)
                }
                .foregroundStyle(Color.connInk)
                .padding(.horizontal, TerminalKeybarMetrics.providerContentHorizontalPadding)
                .padding(.vertical, TerminalKeybarMetrics.providerContentVerticalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: TerminalKeybarMetrics.capVisualHeight)
                .background(Color.connKey, in: .rect(cornerRadius: ConnRadius.key, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .strokeBorder(Color.connKeyline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L(action.titleKey)))
            .accessibilityIdentifier("terminal.keybar.\(groupID).\(action.id)")
            .frame(height: TerminalKeybarMetrics.hitTargetHeight)
        }

        private func keyCap(_ key: TerminalKey, width: CGFloat? = nil) -> some View {
            let isLit = key.isSticky && ctrlActive
            return Button {
                pressCount &+= 1
                onKey(key)
            } label: {
                keyVisual(key)
                    .foregroundStyle(isLit ? Color.connAccent : .connInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: TerminalKeybarMetrics.capVisualHeight)
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
            .accessibilityLabel(keyAccessibilityLabel(key))
            .frame(width: width, height: TerminalKeybarMetrics.hitTargetHeight)
        }

        @ViewBuilder
        private func keyVisual(_ key: TerminalKey) -> some View {
            if let systemImageName = key.systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(size: 15, weight: .medium))
            } else {
                Text(key.label)
                    .font(.connData(.footnote))
            }
        }

        private func keyAccessibilityLabel(_ key: TerminalKey) -> String {
            switch key {
            case .clearLine: L("清除")
            case .enter: L("回车")
            default: key.label
            }
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
                    .frame(height: TerminalKeybarMetrics.capVisualHeight)
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
            .frame(width: width, height: TerminalKeybarMetrics.hitTargetHeight)
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
                    .frame(height: TerminalKeybarMetrics.capVisualHeight)
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
            .accessibilityLabel(Text(pointerActive ? L("关闭远程指针模式") : L("开启远程指针模式")))
            .accessibilityIdentifier("terminal.keybar.pointer")
            .frame(maxWidth: .infinity)
            .frame(height: TerminalKeybarMetrics.hitTargetHeight)
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
                    .frame(height: TerminalKeybarMetrics.capVisualHeight)
                    .background(Color.connKey, in: .rect(cornerRadius: ConnRadius.key, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                            .strokeBorder(Color.connKeyline, lineWidth: 1)
                    )
                    .frame(width: width, height: TerminalKeybarMetrics.hitTargetHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityIdentifier(identifier)
            .frame(width: width, height: TerminalKeybarMetrics.hitTargetHeight)
        }

        private var fixedCommandCap: some View {
            actionCap(
                systemName: "command",
                accessibilityLabel: L("选择本地脚本"),
                identifier: "terminal.keybar.commands",
                width: TerminalKeybarMetrics.compactCapWidth,
                action: onChooseCommand
            )
        }

        private var sessionActionsCap: some View {
            actionCap(
                systemName: "rectangle.stack",
                accessibilityLabel: L("会话操作"),
                identifier: "terminal.keybar.session-actions",
                width: TerminalKeybarMetrics.sessionActionsCapWidth,
                action: onShowSessionActions
            )
        }

        private func expansionCap(expanded: Bool) -> some View {
            actionCap(
                systemName: expanded ? "chevron.down" : "chevron.up",
                accessibilityLabel: expanded ? L("收起快捷键") : L("展开快捷键"),
                identifier: expanded ? "terminal.keybar.collapse" : "terminal.keybar.expand",
                width: TerminalKeybarMetrics.compactCapWidth
            ) {
                onExpansionChange(!expanded)
            }
        }

        private var keyboardCap: some View {
            actionCap(
                systemName: "keyboard",
                accessibilityLabel: keyboardVisible ? L("收起键盘") : L("显示键盘"),
                identifier: "terminal.keybar.dismissKeyboard",
                width: TerminalKeybarMetrics.compactCapWidth,
                action: onToggleKeyboard
            )
        }
    }

    /// When the optional terminal shortcut bar is hidden, page-level session actions
    /// still need a persistent 44pt entry because the immersive terminal has no top bar.
    struct TerminalSessionActionsBar: View {
        let onShowSessionActions: () -> Void
        @State private var pressCount = 0

        var body: some View {
            HStack(spacing: 0) {
                Button {
                    pressCount &+= 1
                    onShowSessionActions()
                } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.connInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: TerminalKeybarMetrics.capVisualHeight)
                        .background(
                            Color.connKey,
                            in: .rect(cornerRadius: ConnRadius.key, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                                .strokeBorder(Color.connKeyline, lineWidth: 1)
                        }
                        .frame(
                            width: TerminalKeybarMetrics.sessionActionsCapWidth,
                            height: TerminalKeybarMetrics.hitTargetHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("会话操作")))
                .accessibilityIdentifier("terminal.keybar.session-actions")
                .frame(
                    width: TerminalKeybarMetrics.sessionActionsCapWidth,
                    height: TerminalKeybarMetrics.hitTargetHeight
                )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity)
            .background(Color.connBar.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 1)
            }
            .sensoryFeedback(ConnHapticFeedback.highImpact, trigger: pressCount)
        }
    }
#endif
