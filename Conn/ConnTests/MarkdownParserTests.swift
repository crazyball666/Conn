import Foundation
import SwiftUI
import Testing
@testable import Conn

struct MarkdownParserTests {
    @Test("MarkdownDocumentView 空文本正常初始化")
    func testEmptyDocument() {
        let view = MarkdownDocumentView(markdown: "")
        #expect(view.markdown == "")

        let whitespaceView = MarkdownDocumentView(markdown: "   \n\n  \n")
        #expect(whitespaceView.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("MarkdownDocumentView 包含 GFM 表格内容能够正常构造")
    func testTableDocument() {
        let markdown = """
        | Header 1 | Header 2 |
        | :--- | :---: |
        | Cell 1 | Cell 2 |
        """
        let view = MarkdownDocumentView(markdown: markdown)
        #expect(!view.markdown.isEmpty)
        #expect(view.markdown.contains("Header 1"))
    }

    @Test("MarkdownDocumentView 包含代码块与列表正常构造")
    func testCodeAndListDocument() {
        let markdown = """
        # Title

        - Item A
        - Item B

        ```swift
        let x = 42
        ```
        """
        let view = MarkdownDocumentView(markdown: markdown)
        #expect(view.markdown.contains("# Title"))
    }
}
