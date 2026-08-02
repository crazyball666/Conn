import Foundation
import Testing

struct HostWorkspaceNavigationTests {
    @Test("主机详情使用工作台入口而不是嵌套分段")
    func hostDetailUsesWorkspaceDestinations() throws {
        let source = try hostDetailSource()

        #expect(!source.contains("segmentPicker"))
        #expect(!source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("toolButton(.processes"))
        #expect(source.contains("toolButton(.files"))
        #expect(source.contains("toolButton(.docker"))
        #expect(source.contains("toolButton(.logs"))
        #expect(source.contains("ActionTile(L(segment.rawValue)"))
        #expect(source.contains(".navigationDestination(item: $route"))
    }

    @Test("进入主机详情后保留应用底栏")
    func hostWorkspaceKeepsRootTabBar() throws {
        let source = try hostDetailSource()

        #expect(!source.contains(".toolbar(.hidden, for: .tabBar)"))
        #expect(source.contains(".toolbar(.visible, for: .tabBar)"))
        #expect(source.contains("modulePage(showsTerminal: false)"))
    }

    private func hostDetailSource() throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectURL.appending(path: "Conn/Hosts/HostDetailView.swift"),
            encoding: .utf8
        )
    }
}
