import Testing
import UIKit
@testable import ConnEditor

@Suite("GutterTextView — 编辑器显示设置")
@MainActor
struct CodeEditorViewTests {
    @Test("编辑器默认字号为 10pt")
    func defaultFontSizeIsTenPoints() {
        #expect(CodeEditorConfiguration.defaultFontSize == 10)
        #expect(CodeEditorConfiguration().fontSize == 10)
    }

    @Test("关闭行号与自动换行会释放 gutter 并允许水平滚动")
    func displayConfiguration() {
        let view = GutterTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        view.configureDisplay(
            showsLineNumbers: false,
            wrapsLines: false,
            tabWidth: 4,
            indentStyle: .spaces
        )

        #expect(!view.showsLineNumbers)
        #expect(view.textContainerInset.left == 10)
        #expect(!view.textContainer.widthTracksTextView)
        #expect(view.alwaysBounceHorizontal)
        #expect(view.showsHorizontalScrollIndicator)
    }

    @Test("Tab 宽度变化会更新已有文本的制表间距")
    func tabWidthUpdatesExistingText() throws {
        let view = GutterTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.text = "a\tb"
        view.configureDisplay(
            showsLineNumbers: true,
            wrapsLines: true,
            tabWidth: 2,
            indentStyle: .tabs
        )
        let narrow = try #require(
            view.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )

        view.configureDisplay(
            showsLineNumbers: true,
            wrapsLines: true,
            tabWidth: 8,
            indentStyle: .tabs
        )
        let wide = try #require(
            view.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )

        #expect(wide.defaultTabInterval > narrow.defaultTabInterval)
    }

    @Test("空格缩进通过标准输入事务写入，并支持撤销")
    func spacesReplaceTabAndCanUndo() throws {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = controller
        window.makeKeyAndVisible()

        let view = GutterTextView(frame: window.bounds)
        controller.view.addSubview(view)
        view.configureDisplay(
            showsLineNumbers: true,
            wrapsLines: true,
            tabWidth: 2,
            indentStyle: .spaces
        )
        view.text = "a"
        view.selectedRange = NSRange(location: 1, length: 0)
        #expect(view.becomeFirstResponder())
        let undoManager = try #require(view.undoManager)
        undoManager.removeAllActions()

        view.insertText("\t")

        #expect(view.text == "a  ")
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(view.text == "a")
    }

    @Test("制表符缩进保留 Tab 字符")
    func tabsKeepTab() {
        let configuration = CodeEditorConfiguration(tabWidth: 4, indentStyle: .tabs)

        #expect(configuration.replacementText(for: "\t") == "\t")
    }
}
