import ConnUI
import SwiftUI

/// 第三方依赖许可声明。内容随 App 一起发布，避免用户必须联网才能查看许可文本。
struct OpenSourceLicensesView: View {
    var body: some View {
        List {
            ForEach(OpenSourceLicense.componentGroups) { group in
                Section(group.licenseName) {
                    ForEach(group.components) { component in
                        row(for: component)
                    }
                }
            }

            Section {
                ForEach(OpenSourceLicense.licenseTexts) { license in
                    DisclosureGroup {
                        Text(license.body)
                            .font(.connFootnote)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.vertical, ConnSpacing.xxs)
                    } label: {
                        Text(license.title)
                            .font(.connSubheadline)
                    }
                }
            } header: {
                Text(L("许可证全文"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("开源许可"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(for component: LicenseComponent) -> some View {
        if let url = URL(string: component.urlString) {
            Link(destination: url) {
                label(for: component)
            }
        } else {
            label(for: component)
        }
    }

    private func label(for component: LicenseComponent) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                    .font(.connSubheadline)
                    .foregroundStyle(.connInk)
                Text(component.version)
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.connMuted)
        }
        .contentShape(Rectangle())
    }
}
