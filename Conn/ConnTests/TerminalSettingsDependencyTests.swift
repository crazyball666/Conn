import Foundation
import Testing

@Suite("Terminal settings dependency")
struct TerminalSettingsDependencyTests {
    private var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conn")
    }

    @Test("TerminalScreen 显式接收设置而不依赖模态环境继承")
    func terminalScreenUsesExplicitSettingsDependency() throws {
        let terminalScreen = try source("Terminal/TerminalScreen.swift")
        #expect(terminalScreen.contains("private let settings: SettingsStore"))
        #expect(terminalScreen.contains("settings: SettingsStore"))
        #expect(!terminalScreen.contains("@Environment(SettingsStore.self) private var settings"))

        let callers = [
            "Servers/ServersView.swift",
            "Hosts/HostDetailView.swift",
            "Hosts/ContainerDetailView.swift",
            "Hosts/DockerView.swift",
            "Commands/SnippetRunView.swift",
            "Terminal/TerminalSessionCenterView.swift",
            "Terminal/TerminalSmokeLaunchView.swift"
        ]
        for caller in callers {
            let contents = try source(caller)
            #expect(contents.contains("TerminalScreen("), "\(caller) should present TerminalScreen")
            #expect(contents.contains("settings: settings"), "\(caller) should pass SettingsStore explicitly")
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: appDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
