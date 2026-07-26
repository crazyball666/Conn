import ConnTerminal
import ConnUI
import SwiftUI

/// 终端显示与交互偏好。全部设置即时写入 UserDefaults。
struct TerminalSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private let scrollbackOptions = [500, 2_000, 5_000, 10_000]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(L("显示")) {
                Picker(selection: $settings.terminalThemeID) {
                    ForEach(TerminalTheme.all) { theme in
                        themeLabel(theme).tag(theme.id)
                    }
                } label: {
                    Label(L("主题"), systemImage: "paintpalette")
                }

                Stepper(
                    value: $settings.terminalFontSize,
                    in: 10 ... 24,
                    step: 1
                ) {
                    LabeledContent {
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(L("字体大小"), systemImage: "textformat.size")
                    }
                }
            }

            Section(L("光标")) {
                Picker(L("光标形状"), selection: $settings.terminalCursorShape) {
                    ForEach(TerminalCursorShape.allCases) { shape in
                        Text(cursorLabel(shape)).tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $settings.terminalCursorBlinking) {
                    Label(L("光标闪烁"), systemImage: "cursorarrow.rays")
                }
            }

            Section(L("交互")) {
                Picker(selection: $settings.terminalScrollback) {
                    ForEach(scrollbackOptions, id: \.self) { lines in
                        Text(String(format: L("%d 行"), lines)).tag(lines)
                    }
                } label: {
                    Label(L("回滚历史"), systemImage: "clock.arrow.circlepath")
                }

                Toggle(isOn: $settings.terminalKeybarEnabled) {
                    Label(L("快捷键栏"), systemImage: "keyboard")
                }
            }
        }
        .navigationTitle(L("终端设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func themeLabel(_ theme: TerminalTheme) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            HStack(spacing: 3) {
                Circle().fill(color(theme.background))
                Circle().fill(color(theme.cursor))
                Circle().fill(color(theme.foreground))
            }
            .frame(width: 39, height: 11)
            .accessibilityHidden(true)
            Text(theme.name)
        }
    }

    private func cursorLabel(_ shape: TerminalCursorShape) -> String {
        switch shape {
        case .block: L("块状")
        case .bar: L("竖线")
        case .underline: L("下划线")
        }
    }

    private func color(_ rgb: TerminalTheme.RGB) -> Color {
        Color(
            red: Double(rgb.r) / 255,
            green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255
        )
    }
}
