import Foundation
import Testing
@testable import Conn

struct MarkdownParserTests {
    @Test("解析空文档返回空列表")
    func testParseEmptyDocument() {
        let blocks = MarkdownParser.parse("")
        #expect(blocks.isEmpty)

        let whitespaceBlocks = MarkdownParser.parse("   \n\n  \n")
        #expect(whitespaceBlocks.isEmpty)
    }

    @Test("解析不同层级标题")
    func testParseHeaders() {
        let markdown = """
        # Title 1
        ## Subtitle 2
        ### Section 3
        ###### Smallest 6
        """
        let blocks = MarkdownParser.parse(markdown)
        #expect(blocks.count == 4)

        if case let .header(level, text) = blocks[0] {
            #expect(level == 1)
            #expect(text == "Title 1")
        } else {
            Issue.record("Expected header block for level 1")
        }

        if case let .header(level, text) = blocks[1] {
            #expect(level == 2)
            #expect(text == "Subtitle 2")
        } else {
            Issue.record("Expected header block for level 2")
        }

        if case let .header(level, text) = blocks[2] {
            #expect(level == 3)
            #expect(text == "Section 3")
        } else {
            Issue.record("Expected header block for level 3")
        }

        if case let .header(level, text) = blocks[3] {
            #expect(level == 6)
            #expect(text == "Smallest 6")
        } else {
            Issue.record("Expected header block for level 6")
        }
    }

    @Test("解析带语言和不带语言的代码块")
    func testParseCodeBlocks() {
        let markdown = """
        ```swift
        let x = 42
        print(x)
        ```

        ```
        plain text block
        ```
        """
        let blocks = MarkdownParser.parse(markdown)
        #expect(blocks.count == 2)

        if case let .codeBlock(code, lang) = blocks[0] {
            #expect(lang == "swift")
            #expect(code == "let x = 42\nprint(x)")
        } else {
            Issue.record("Expected swift codeBlock")
        }

        if case let .codeBlock(code, lang) = blocks[1] {
            #expect(lang == nil)
            #expect(code == "plain text block")
        } else {
            Issue.record("Expected plain codeBlock")
        }
    }

    @Test("解析引用块")
    func testParseQuote() {
        let markdown = """
        > This is a quote
        > second line of quote
        """
        let blocks = MarkdownParser.parse(markdown)
        #expect(blocks.count == 1)

        if case let .quote(text) = blocks[0] {
            #expect(text == "This is a quote\nsecond line of quote")
        } else {
            Issue.record("Expected quote block")
        }
    }

    @Test("解析有序和无序列表")
    func testParseLists() {
        let markdown = """
        - Item A
        * Item B
        + Item C
        1. First
        2. Second
        """
        let blocks = MarkdownParser.parse(markdown)
        #expect(blocks.count == 5)

        if case let .listItem(ordered, index, text) = blocks[0] {
            #expect(!ordered)
            #expect(index == nil)
            #expect(text == "Item A")
        } else {
            Issue.record("Expected unordered item")
        }

        if case let .listItem(ordered, index, text) = blocks[3] {
            #expect(ordered)
            #expect(index == 1)
            #expect(text == "First")
        } else {
            Issue.record("Expected ordered item 1")
        }

        if case let .listItem(ordered, index, text) = blocks[4] {
            #expect(ordered)
            #expect(index == 2)
            #expect(text == "Second")
        } else {
            Issue.record("Expected ordered item 2")
        }
    }

    @Test("解析分割线与普通段落")
    func testParseDividerAndParagraph() {
        let markdown = """
        Hello world paragraph.
        Still paragraph.

        ---

        Another paragraph after hr.
        """
        let blocks = MarkdownParser.parse(markdown)
        #expect(blocks.count == 3)

        if case let .paragraph(text) = blocks[0] {
            #expect(text == "Hello world paragraph.\nStill paragraph.")
        } else {
            Issue.record("Expected paragraph block")
        }

        if case .divider = blocks[1] {
            // divider matched
        } else {
            Issue.record("Expected divider block")
        }

        if case let .paragraph(text) = blocks[2] {
            #expect(text == "Another paragraph after hr.")
        } else {
            Issue.record("Expected paragraph block")
        }
    }
}
