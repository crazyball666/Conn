import ConnEditor
import ConnKit
import ConnUI
import MarkdownUI
import SwiftUI

/// Markdown 渲染文档视图
struct MarkdownDocumentView: View {
    let markdown: String

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
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("files.markdown.preview")
    }
}
