import ConnUI
import SwiftUI

/// 「我的」页（原型 S10 框架）。密钥管家、安全、关于等入口。
///
/// Phase 5：接入密钥管家。同步/购买/设置等其余入口在后续 Phase 补。
struct MeView: View {
    let dependencies: AppDependencies
    @Environment(LocalizationManager.self) private var localization

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.stackGap) {
                section(L("语言")) {
                    languageRow
                }

                section(L("安全")) {
                    navRow(L("密钥管家"), systemName: "key.fill", tint: .accent) {
                        KeyManagerView(dependencies: dependencies)
                    }
                }

                section(L("关于")) {
                    infoRow(L("隐私承诺"), systemName: "hand.raised.fill", detail: L("无服务端 · 零遥测"))
                    infoRow(L("版本"), systemName: "info.circle", detail: appVersion)
                }

                footer
            }
            .padding(.top, ConnSpacing.sm)
            .padding(.bottom, ConnSpacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.connBg.ignoresSafeArea())
    }

    private var languageRow: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    localization.language = language
                } label: {
                    if localization.language == language {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            ConnListRow(
                title: localization.language.displayName,
                leading: { IconChip("globe", tint: .accent) },
                trailing: { ConnChevron() }
            )
        }
        .padding(.horizontal, ConnSpacing.page)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(title)
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .connEyebrowTracking()
                .padding(.horizontal, ConnSpacing.page)
                .padding(.top, ConnSpacing.sm)
            content()
        }
    }

    private func navRow(
        _ title: String,
        systemName: String,
        tint: IconChip.Tint,
        @ViewBuilder destination: () -> some View
    ) -> some View {
        NavigationLink(destination: destination()) {
            ConnListRow(
                title: title,
                leading: { IconChip(systemName, tint: tint) },
                trailing: { ConnChevron() }
            )
        }
        .buttonStyle(ConnPressStyle())
        .padding(.horizontal, ConnSpacing.page)
    }

    private func infoRow(_ title: String, systemName: String, detail: String) -> some View {
        ConnListRow(
            title: title,
            leading: { IconChip(systemName, tint: .neutral) },
            trailing: {
                Text(detail)
                    .font(.connData(.caption))
                    .foregroundStyle(.connMuted)
            }
        )
        .padding(.horizontal, ConnSpacing.page)
    }

    private var footer: some View {
        Text(L("数据仅存本机与你自己的 iCloud · 无账号 · 零上传"))
            .font(.connFootnote)
            .foregroundStyle(.connMuted)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, ConnSpacing.lg)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }
}
