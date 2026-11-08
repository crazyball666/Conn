import ConnEditor
import ConnKit
import ConnUI
import MarkdownUI
import SafariServices
import SwiftUI

/// 使用系统 `SFSafariViewController` 在应用内展示 Markdown 中的外部网页链接
private struct MarkdownSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = UIColor(ConnTheme.accent)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Markdown 渲染文档视图（采用业界成熟的 GitHub 官方标准主题排版）
struct MarkdownDocumentView: View {
    let markdown: String
    @State private var activeWebURL: URL?

    var body: some View {
        Group {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L("文件为空"))
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, ConnSpacing.xxl)
            } else {
                Markdown(markdown)
                    .markdownTheme(.gitHub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("files.markdown.preview")
        .environment(\.openURL, OpenURLAction { url in
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                activeWebURL = url
                return .handled
            }
            return .systemAction
        })
        .sheet(item: $activeWebURL) { url in
            MarkdownSafariView(url: url)
                .ignoresSafeArea()
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
