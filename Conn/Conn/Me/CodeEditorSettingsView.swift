import ConnEditor
import SwiftUI

/// 代码编辑器的显示与缩进偏好。全部设置即时写入 UserDefaults。
struct CodeEditorSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private let tabWidthOptions = [2, 4, 8]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(L("显示")) {
                Picker(selection: $settings.codeTheme) {
                    ForEach(CodeEditorCatalog.themes) { theme in
                        Text(theme.displayName).tag(theme.id)
                    }
                } label: {
                    Label(L("主题"), systemImage: "paintpalette")
                }

                Stepper(
                    value: $settings.codeFontSize,
                    in: 10 ... 24,
                    step: 1
                ) {
                    LabeledContent {
                        Text("\(Int(settings.codeFontSize)) pt")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(L("字体大小"), systemImage: "ruler")
                    }
                }
                .accessibilityIdentifier("settings.editor.font-size")

                Toggle(isOn: $settings.codeShowsLineNumbers) {
                    Label(L("显示行号"), systemImage: "list.number")
                }

                Toggle(isOn: $settings.codeLineWrapping) {
                    Label(L("自动换行"), systemImage: "arrow.turn.down.left")
                }
            }

            Section(L("缩进")) {
                Picker(selection: $settings.codeTabWidth) {
                    ForEach(tabWidthOptions, id: \.self) { width in
                        Text("\(width)").tag(width)
                    }
                } label: {
                    Label(L("Tab 宽度"), systemImage: "arrow.left.and.right.text.vertical")
                }

                Picker(L("缩进方式"), selection: $settings.codeIndentStyle) {
                    ForEach(CodeIndentStyle.allCases) { style in
                        Text(indentStyleLabel(style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(L("编辑器设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func indentStyleLabel(_ style: CodeIndentStyle) -> String {
        switch style {
        case .spaces: L("空格")
        case .tabs: L("制表符")
        }
    }
}
