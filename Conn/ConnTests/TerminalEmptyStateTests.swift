import Foundation
import XCTest

final class TerminalEmptyStateTests: XCTestCase {
    private var projectDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEmptyStateOmitsDuplicateCreationPrompt() throws {
        let sourceURL = projectDirectory
            .appendingPathComponent("Conn/Terminal/TerminalSessionCenterView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Label(L(\"暂无终端\"), systemImage: \"terminal\")"))
        XCTAssertFalse(source.contains("Text(L(\"新建普通终端或 tmux 终端后，会显示在这里。\"))"))
        XCTAssertFalse(source.contains("Button(L(\"新建终端\"))"))
        XCTAssertTrue(source.contains(".accessibilityLabel(L(\"新建终端\"))"))
    }

    func testTerminalAndSnippetListsUseCompactSurfaceCards() throws {
        let terminal = try source("Conn/Terminal/TerminalSessionCenterView.swift")
        let snippets = try source("Conn/Commands/SnippetsView.swift")
        let metrics = try source("../Packages/ConnPackages/Sources/ConnUI/Tokens/ConnMetrics.swift")

        XCTAssertTrue(metrics.contains("public static let listCard: CGFloat = 20"))
        XCTAssertTrue(terminal.contains("top: ConnSpacing.xs"))
        XCTAssertTrue(terminal.contains("bottom: ConnSpacing.xs"))
        XCTAssertTrue(terminal.contains(".listStyle(.insetGrouped)"))
        XCTAssertTrue(terminal.contains(".listRowBackground(Color.connSurface)"))
        XCTAssertTrue(snippets.contains(".connSurface(cornerRadius: ConnRadius.listCard)"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: projectDirectory.appendingPathComponent(relativePath).standardizedFileURL,
            encoding: .utf8
        )
    }
}
