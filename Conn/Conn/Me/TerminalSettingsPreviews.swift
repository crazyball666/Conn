import ConnTerminal
import ConnUI
import SwiftUI

/// 系统 Picker 会把复杂 option 降级成文本；主题预览必须由自定义列表直接渲染。
struct TerminalThemeSelectionSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L("深色")) {
                    ForEach(themes(appearance: .dark)) { theme in
                        themeButton(theme)
                    }
                }

                Section(L("浅色")) {
                    ForEach(themes(appearance: .light)) { theme in
                        themeButton(theme)
                    }
                }
            }
            .navigationTitle(L("主题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L("关闭"))
                }
            }
        }
    }

    private func themeButton(_ theme: TerminalTheme) -> some View {
        Button {
            selection = theme.id
        } label: {
            TerminalThemePreviewCard(
                theme: theme,
                isSelected: selection == theme.id
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(
            EdgeInsets(
                top: ConnSpacing.xxs,
                leading: ConnSpacing.sm,
                bottom: ConnSpacing.xxs,
                trailing: ConnSpacing.sm
            )
        )
        .listRowBackground(Color.clear)
    }

    private func themes(appearance: TerminalTheme.Appearance) -> [TerminalTheme] {
        TerminalTheme.all.filter { $0.appearance == appearance }
    }
}

/// 主题列表中的完整终端卡片，确保画布、正文、光标和 ANSI 色都真实可见。
private struct TerminalThemePreviewCard: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack {
                Text(theme.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.connAccent)
                }
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                    .fill(terminalColor(theme.background))

                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    HStack(spacing: 0) {
                        Text("$ ")
                            .foregroundStyle(terminalColor(theme.ansi[2]))
                        Text("Aa")
                            .foregroundStyle(terminalColor(theme.foreground))
                        Rectangle()
                            .fill(terminalColor(theme.cursor))
                            .frame(width: 7, height: 18)
                            .padding(.leading, 2)
                    }
                    .font(.system(size: 15, weight: .medium, design: .monospaced))

                    HStack(spacing: 2) {
                        ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, rgb in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(terminalColor(rgb))
                        }
                    }
                    .frame(height: 7)
                }
                .padding(ConnSpacing.sm)
            }
            .frame(height: 68)
        }
        .padding(ConnSpacing.sm)
        .background(
            isSelected ? Color.connAccentFill : Color.connSurface,
            in: RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.card, style: .continuous)
                .stroke(
                    isSelected ? Color.connAccent : Color.connLine,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 主题选择行直接渲染领域调色板，不维护第二套预览颜色。
struct TerminalThemePickerLabel: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: ConnSpacing.sm) {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                        .fill(terminalColor(theme.background))

                    Text("Aa")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(terminalColor(theme.foreground))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                    Rectangle()
                        .fill(terminalColor(theme.cursor))
                        .frame(width: 5, height: 13)
                        .padding(4)
                }
                .frame(width: 56, height: 32)

                HStack(spacing: 1) {
                    ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, rgb in
                        Rectangle().fill(terminalColor(rgb))
                    }
                }
                .frame(width: 56, height: 4)
                .clipShape(.capsule)
            }

            Text(theme.name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
    }
}

/// 光标形状选择保持绑定现有设置枚举，预览颜色来自当前主题。
struct TerminalCursorShapePicker: View {
    @Binding var selection: TerminalCursorShape
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: ConnSpacing.xs) {
            ForEach(TerminalCursorShape.allCases) { shape in
                Button {
                    selection = shape
                } label: {
                    TerminalCursorShapeCard(
                        shape: shape,
                        theme: theme,
                        isSelected: selection == shape
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == shape ? .isSelected : [])
            }
        }
    }
}

private struct TerminalCursorShapeCard: View {
    let shape: TerminalCursorShape
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: ConnSpacing.xxs) {
            ZStack {
                RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                    .fill(terminalColor(theme.background))

                Text("A")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(terminalColor(theme.foreground))

                cursor
            }
            .frame(width: 42, height: 30)

            Text(shapeLabel)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, ConnSpacing.xxs)
        .padding(.vertical, ConnSpacing.xs)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .background(
            isSelected ? Color.connAccentFill : Color.clear,
            in: RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .stroke(
                    isSelected ? Color.connAccent : Color.connLine,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shapeLabel)
    }

    @ViewBuilder
    private var cursor: some View {
        switch shape {
        case .block:
            ZStack {
                Rectangle()
                    .fill(terminalColor(theme.cursor))
                    .frame(width: 12, height: 18)
                Text("A")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(terminalColor(theme.background))
            }
        case .bar:
            Rectangle()
                .fill(terminalColor(theme.cursor))
                .frame(width: 2, height: 18)
                .offset(x: -7)
        case .underline:
            Rectangle()
                .fill(terminalColor(theme.cursor))
                .frame(width: 12, height: 2)
                .offset(y: 8)
        }
    }

    private var shapeLabel: String {
        switch shape {
        case .block: L("块状")
        case .bar: L("竖线")
        case .underline: L("下划线")
        }
    }
}

private func terminalColor(_ rgb: TerminalTheme.RGB) -> Color {
    Color(
        red: Double(rgb.r) / 255,
        green: Double(rgb.g) / 255,
        blue: Double(rgb.b) / 255
    )
}
