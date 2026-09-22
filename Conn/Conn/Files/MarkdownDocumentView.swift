import ConnKit
import ConnUI
import SwiftUI

/// Markdown 块级元素类型
enum MarkdownBlock: Identifiable, Equatable {
    case header(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(code: String, language: String?)
    case quote(text: String)
    case listItem(ordered: Bool, index: Int?, text: String)
    case divider

    var id: String {
        switch self {
        case let .header(level, text): "h-\(level)-\(text)"
        case let .paragraph(text): "p-\(text)"
        case let .codeBlock(code, lang): "code-\(lang ?? "")-\(code)"
        case let .quote(text): "q-\(text)"
        case let .listItem(ordered, idx, text): "li-\(ordered)-\(idx ?? 0)-\(text)"
        case .divider: "hr-\(UUID().uuidString)"
        }
    }
}

/// 快速简易 Markdown 解析器
enum MarkdownParser {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: .newlines)
        var lineIndex = 0
        let count = lines.count

        while lineIndex < count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行
            if trimmed.isEmpty {
                lineIndex += 1
                continue
            }

            // 多行代码块 ```
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                lineIndex += 1
                while lineIndex < count {
                    let subLine = lines[lineIndex]
                    if subLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        lineIndex += 1
                        break
                    }
                    codeLines.append(subLine)
                    lineIndex += 1
                }
                blocks.append(.codeBlock(code: codeLines.joined(separator: "\n"), language: lang.isEmpty ? nil : lang))
                continue
            }

            // 分割线
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                lineIndex += 1
                continue
            }

            // 标题 #
            if trimmed.hasPrefix("#") {
                var level = 0
                for char in trimmed {
                    if char == "#" { level += 1 } else { break }
                }
                if level > 0 && level <= 6 {
                    let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.header(level: level, text: text))
                    lineIndex += 1
                    continue
                }
            }

            // 引用块 >
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while lineIndex < count {
                    let subLine = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                    guard subLine.hasPrefix(">") else { break }
                    let content = String(subLine.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                    quoteLines.append(content)
                    lineIndex += 1
                }
                blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // 无序列表 -, *, +
            if (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")) && trimmed.count > 2 {
                let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.listItem(ordered: false, index: nil, text: text))
                lineIndex += 1
                continue
            }

            // 有序列表 1.
            let digitPrefix = trimmed.prefix { $0.isNumber }
            if !digitPrefix.isEmpty && trimmed.dropFirst(digitPrefix.count).hasPrefix(". ") {
                let dropLen = digitPrefix.count + 2
                let text = String(trimmed.dropFirst(dropLen)).trimmingCharacters(in: .whitespaces)
                let num = Int(digitPrefix)
                blocks.append(.listItem(ordered: true, index: num, text: text))
                lineIndex += 1
                continue
            }

            // 累积普通段落
            var paragraphLines: [String] = [line]
            lineIndex += 1
            while lineIndex < count {
                let nextLine = lines[lineIndex]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix("#")
                    || nextTrimmed.hasPrefix(">") || nextTrimmed.hasPrefix("- ") || nextTrimmed.hasPrefix("* ")
                    || nextTrimmed == "---" {
                    break
                }
                paragraphLines.append(nextLine)
                lineIndex += 1
            }
            blocks.append(.paragraph(text: paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }
}

/// Markdown 渲染文档视图
struct MarkdownDocumentView: View {
    let markdown: String
    private let blocks: [MarkdownBlock]

    init(markdown: String) {
        self.markdown = markdown
        self.blocks = MarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.md) {
            if blocks.isEmpty {
                Text(L("文件为空"))
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, ConnSpacing.xxl)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("files.markdown.preview")
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .header(level, text):
            headerView(level: level, text: text)
        case let .paragraph(text):
            inlineMarkdownText(text)
                .font(.connBody)
                .foregroundStyle(.connInk)
                .textSelection(.enabled)
        case let .codeBlock(code, language):
            codeBlockView(code: code, language: language)
        case let .quote(text):
            quoteView(text: text)
        case let .listItem(ordered, index, text):
            listItemView(ordered: ordered, index: index, text: text)
        case .divider:
            Rectangle()
                .fill(Color.connLine)
                .frame(height: 1)
                .padding(.vertical, ConnSpacing.xs)
        }
    }

    @ViewBuilder
    private func headerView(level: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(headerFont(level))
                .fontWeight(.bold)
                .foregroundStyle(.connInk)
                .textSelection(.enabled)
            if level == 1 {
                Rectangle()
                    .fill(Color.connLine)
                    .frame(height: 1)
            }
        }
        .padding(.top, level <= 2 ? ConnSpacing.xs : 2)
    }

    private func headerFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 24, weight: .bold)
        case 2: return .system(size: 20, weight: .bold)
        case 3: return .system(size: 17, weight: .semibold)
        default: return .system(size: 15, weight: .semibold)
        }
    }

    private func codeBlockView(code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.connDim)
                } else {
                    Spacer().frame(width: 1)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.connDim)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("复制"))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.connInk)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.card)
                .strokeBorder(Color.connLine, lineWidth: 0.5)
        )
    }

    private func quoteView(text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.connAccent)
                .frame(width: 3)
            inlineMarkdownText(text)
                .font(.connBody)
                .foregroundStyle(.connMuted)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func listItemView(ordered: Bool, index: Int?, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if ordered, let index {
                Text("\(index).")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.connDim)
                    .frame(minWidth: 18, alignment: .trailing)
            } else {
                Text("•")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.connAccent)
                    .frame(minWidth: 14, alignment: .center)
            }
            inlineMarkdownText(text)
                .font(.connBody)
                .foregroundStyle(.connInk)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr)
        } else {
            Text(text)
        }
    }
}
