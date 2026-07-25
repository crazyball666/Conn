#if canImport(UIKit)
import Highlightr
import SwiftUI
import UIKit

/// 语法高亮 + 行号的代码编辑器（UITextView + Highlightr，TextKit 1）。
///
/// 主题 / 语言 / 是否可编辑由外部传入；文本双向绑定。行号 gutter 由
/// `GutterTextView` 自绘，随内容滚动；高亮由 `CodeAttributedString` 实时完成。
public struct CodeEditor: UIViewRepresentable {
    @Binding private var text: String
    private let language: String?
    private let theme: String
    private let isEditable: Bool
    private let fontSize: CGFloat

    public init(
        text: Binding<String>,
        language: String?,
        theme: String,
        isEditable: Bool = true,
        fontSize: CGFloat = 13
    ) {
        _text = text
        self.language = language
        self.theme = theme
        self.isEditable = isEditable
        self.fontSize = fontSize
    }

    public func makeUIView(context: Context) -> GutterTextView {
        let storage = CodeAttributedString()
        storage.language = language
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer()
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = GutterTextView(frame: .zero, textContainer: container)
        textView.codeStorage = storage
        textView.isEditable = isEditable
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.delegate = context.coordinator
        applyTheme(to: textView, storage: storage, force: true)
        textView.text = text
        textView.recomputeLineStarts()
        return textView
    }

    public func updateUIView(_ textView: GutterTextView, context: Context) {
        guard let storage = textView.codeStorage else { return }
        if storage.language != language {
            storage.language = language
        }
        applyTheme(to: textView, storage: storage, force: false)
        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = selection
            textView.recomputeLineStarts()
        }
        textView.isEditable = isEditable
        textView.setNeedsDisplay()
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    /// 应用主题（仅在主题变化时重着色，避免每次 update 重扫）。
    private func applyTheme(to textView: GutterTextView, storage: CodeAttributedString, force: Bool) {
        guard force || textView.appliedTheme != theme else { return }
        textView.appliedTheme = theme
        storage.highlightr.setTheme(to: theme)
        storage.highlightr.theme.codeFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if !force { storage.language = language } // 触发已有内容按新主题重着色

        let background = storage.highlightr.theme.themeBackgroundColor ?? .systemBackground
        let dark = background.connIsDark
        textView.backgroundColor = background
        textView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.tintColor = dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.2, alpha: 1)
        textView.gutterBackgroundColor = background.connBlended(withDark: dark, amount: 0.06)
        textView.gutterTextColor = dark ? UIColor(white: 1, alpha: 0.38) : UIColor(white: 0, alpha: 0.32)
        textView.gutterLineColor = dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08)
        textView.setNeedsDisplay()
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        public func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            if let gutter = textView as? GutterTextView {
                gutter.recomputeLineStarts()
                gutter.setNeedsDisplay()
            }
        }
    }
}

/// UITextView + 左侧行号 gutter（自绘，随内容滚动）。
public final class GutterTextView: UITextView {
    var codeStorage: CodeAttributedString?
    var appliedTheme: String?
    var gutterWidth: CGFloat = 44
    var gutterBackgroundColor: UIColor = .secondarySystemBackground
    var gutterTextColor: UIColor = .tertiaryLabel
    var gutterLineColor: UIColor = .separator
    /// 各逻辑行的起始字符下标（供二分求行号）。
    private var lineStarts: [Int] = [0]

    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        contentMode = .redraw
        textContainerInset = UIEdgeInsets(top: 8, left: gutterWidth + 6, bottom: 8, right: 10)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    /// 重建逻辑行起始下标表。内容变化后调用。
    func recomputeLineStarts() {
        let string = text as NSString
        var starts = [0]
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { _, _, enclosing, _ in
            let next = enclosing.location + enclosing.length
            if next < string.length { starts.append(next) }
        }
        lineStarts = starts
    }

    public override func draw(_ rect: CGRect) {
        gutterBackgroundColor.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: rect.minY, width: gutterWidth, height: rect.height)).fill()
        gutterLineColor.setFill()
        UIBezierPath(rect: CGRect(x: gutterWidth - 0.5, y: rect.minY, width: 0.5, height: rect.height)).fill()
        super.draw(rect)
        drawLineNumbers(rect)
    }

    private func drawLineNumbers(_ rect: CGRect) {
        let numberFont = UIFont.monospacedSystemFont(ofSize: max(9, (font?.pointSize ?? 13) - 2), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: gutterTextColor]
        let string = text as NSString

        if string.length == 0 {
            drawNumber(1, at: textContainerInset.top, font: numberFont, attributes: attributes)
            return
        }
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { [weak self] _, usedRect, _, glyphRange, _ in
            guard let self else { return }
            let charIndex = self.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
            let isLineStart = charIndex == 0
                || (charIndex <= string.length && string.substring(with: NSRange(location: charIndex - 1, length: 1)) == "\n")
            guard isLineStart else { return } // 跳过软换行的续行
            self.drawNumber(
                self.lineNumber(forCharIndex: charIndex),
                at: usedRect.minY + self.textContainerInset.top,
                font: numberFont, attributes: attributes
            )
        }
    }

    private func drawNumber(_ number: Int, at yOffset: CGFloat, font: UIFont, attributes: [NSAttributedString.Key: Any]) {
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: gutterWidth - size.width - 6, y: yOffset), withAttributes: attributes)
    }

    /// 二分：不大于 index 的最大行起始 → 行号。
    private func lineNumber(forCharIndex index: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= index { answer = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return answer + 1
    }
}

private extension UIColor {
    /// 依据感知亮度判断是否深色背景。
    var connIsDark: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (0.299 * red + 0.587 * green + 0.114 * blue) < 0.5
    }

    /// 在背景上叠一层浅/深，作 gutter 底色（与代码区略作区分）。
    func connBlended(withDark dark: Bool, amount: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let target: CGFloat = dark ? 1 : 0
        return UIColor(
            red: red + (target - red) * amount,
            green: green + (target - green) * amount,
            blue: blue + (target - blue) * amount,
            alpha: alpha
        )
    }
}
#endif
