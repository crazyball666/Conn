import ConnTerminal
import ConnUI
import SwiftUI

/// 终端显示与交互偏好。全部设置即时写入 UserDefaults。
struct TerminalSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var isThemePickerPresented = false

    private let scrollbackOptions = [500, 2_000, 5_000, 10_000]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(L("显示")) {
                Button {
                    isThemePickerPresented = true
                } label: {
                    HStack(spacing: ConnSpacing.sm) {
                        Label(L("主题"), systemImage: "paintpalette")
                        Spacer(minLength: ConnSpacing.xs)
                        TerminalThemePickerLabel(theme: selectedTheme)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                Stepper(
                    value: $settings.terminalFontSize,
                    in: 10 ... 24,
                    step: 1
                ) {
                    LabeledContent {
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(L("字体大小"), systemImage: "ruler")
                    }
                }
                .accessibilityIdentifier("settings.terminal.font-size")
            }

            Section(L("光标")) {
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    Label(L("光标形状"), systemImage: "cursorarrow")
                    TerminalCursorShapePicker(
                        selection: $settings.terminalCursorShape,
                        theme: selectedTheme
                    )
                }

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

            }
        }
        .navigationTitle(L("终端设置"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isThemePickerPresented) {
            TerminalThemeSelectionSheet(selection: $settings.terminalThemeID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var selectedTheme: TerminalTheme {
        TerminalTheme.theme(id: settings.terminalThemeID)
    }
}
