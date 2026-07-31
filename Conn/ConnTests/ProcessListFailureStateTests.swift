import Foundation
import Testing
@testable import Conn

@Suite("进程列表失败状态")
struct ProcessListFailureStateTests {
    @Test("连接失败时显示错误横幅与重试按钮")
    func connectionFailureShowsBannerAndRetry() throws {
        let source = try source(named: "Conn/Hosts/ProcessListView.swift")

        #expect(source.contains("case let .failed(message):"))
        #expect(source.contains("ConnBanner(message, systemImage: \"exclamationmark.triangle\")"))
        #expect(source.contains("Button(L(\"重试\"))"))
        #expect(source.contains("await viewModel.retryProcesses()"))
    }

    private func source(named relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
    }
}
