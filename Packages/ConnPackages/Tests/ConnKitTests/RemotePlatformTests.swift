import Foundation
import Testing
@testable import ConnKit

@Suite("Remote platform domain")
struct RemotePlatformTests {
    @Test("平台种类 raw value 稳定")
    func platformRawValues() {
        #expect(RemotePlatformKind.linux.rawValue == "linux")
        #expect(RemotePlatformKind.macOS.rawValue == "macOS")
        #expect(RemotePlatformKind.windows.rawValue == "windows")
        #expect(RemotePlatformKind.unknown.rawValue == "unknown")
    }

    @Test("平台画像 Codable 往返无损")
    func profileRoundTrip() throws {
        let profile = RemotePlatformProfile(
            kind: .macOS,
            release: "15.0",
            architecture: "arm64",
            shell: .zsh
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(RemotePlatformProfile.self, from: data)

        #expect(decoded == profile)
    }

    @Test("脚本执行能力 Codable 往返无损")
    func scriptExecutionCapabilityRoundTrip() throws {
        let data = try JSONEncoder().encode(RemoteCapability.scriptExecution)
        let decoded = try JSONDecoder().decode(RemoteCapability.self, from: data)

        #expect(decoded == .scriptExecution)
    }

    @Test("降级原因保留稳定原因码与缺失字段")
    func degradedFields() {
        let issue = CapabilityIssue(
            code: .partialData,
            detail: "部分 Darwin 统计不可用",
            fields: ["tcp", "io"]
        )
        let state = CapabilityState.degraded(issues: [issue])
        let report = RemoteCapabilityReport(states: [.hostMetrics: state])

        #expect(report[.hostMetrics] == state)
        #expect(report[.processes] == nil)
    }

    @Test("能力报告 Codable 往返保留枚举关联值")
    func reportRoundTrip() throws {
        let issue = CapabilityIssue(code: .unsupportedPlatform, fields: ["processes"])
        let report = RemoteCapabilityReport(states: [.processes: .unsupported(issue: issue)])

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(RemoteCapabilityReport.self, from: data)

        #expect(decoded.states == report.states)
    }
}
