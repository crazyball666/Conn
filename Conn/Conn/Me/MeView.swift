import ConnEditor
import ConnUI
import SwiftUI

/// 「我的」/设置页——原生 `Form` 分组（Apple 设置页风格）。
///
/// 外观（深浅色 / 主题色）、数据（刷新间隔）、安全（应用锁 / 密钥管家）、语言、关于。
struct MeView: View {
    let dependencies: AppDependencies
    @Environment(LocalizationManager.self) private var localization
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var localization = localization
        @Bindable var settings = settings
        Form {
            Section(L("外观")) {
                Picker(selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label(L("深浅色"), systemImage: "circle.lefthalf.filled")
                }
                accentRow(selection: $settings.accent)
            }

            Section(L("数据")) {
                Picker(selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label(L("主页刷新间隔"), systemImage: "arrow.clockwise")
                }
                Picker(selection: $settings.dockerRefreshInterval) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label(L("容器刷新间隔"), systemImage: "shippingbox")
                }
            }

            Section(L("编辑器")) {
                NavigationLink {
                    CodeEditorSettingsView()
                } label: {
                    Label(L("编辑器设置"), systemImage: "curlybraces")
                }
                NavigationLink {
                    TerminalSettingsView()
                } label: {
                    Label(L("终端设置"), systemImage: "terminal")
                }
            }

            Section(L("安全")) {
                Toggle(isOn: Binding(
                    get: { dependencies.appLock.isEnabled },
                    set: { dependencies.appLock.isEnabled = $0 }
                )) {
                    Label(
                        String(format: L("应用锁（%@）"), dependencies.appLock.biometryName),
                        systemImage: "lock.fill"
                    )
                }
                NavigationLink {
                    KeyManagerView(dependencies: dependencies)
                } label: {
                    Label(L("密钥管家"), systemImage: "key.fill")
                }
            }

            Section(L("语言")) {
                Picker(selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                } label: {
                    Label(L("语言"), systemImage: "globe")
                }
            }

            Section {
                LabeledContent {
                    Text(appVersion).foregroundStyle(.secondary)
                } label: {
                    Label(L("版本"), systemImage: "info.circle")
                }
            } footer: {
                Text(L("数据仅存本机与你自己的 iCloud · 无账号 · 零上传"))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .navigationTitle(L("设置"))
    }

    /// 主题色：一行标签 + 一排色卡（选中打勾）。
    private func accentRow(selection: Binding<AppAccent>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("主题色"), systemImage: "paintpalette.fill")
            HStack(spacing: 0) {
                ForEach(Array(AppAccent.allCases.enumerated()), id: \.element) { index, accent in
                    swatch(accent, selection: selection)
                    if index < AppAccent.allCases.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ accent: AppAccent, selection: Binding<AppAccent>) -> some View {
        Button {
            selection.wrappedValue = accent
        } label: {
            Circle()
                .fill(accent.color)
                .frame(width: 26, height: 26)
                .overlay {
                    if selection.wrappedValue == accent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.label)
        .accessibilityAddTraits(selection.wrappedValue == accent ? [.isButton, .isSelected] : .isButton)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }
}
