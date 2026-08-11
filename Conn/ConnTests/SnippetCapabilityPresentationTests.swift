import ConnKit
import Foundation
import Testing
@testable import Conn

@Suite("Snippet capability presentation")
struct SnippetCapabilityPresentationTests {
    @Test("script execution blocker has priority over capability blockers")
    func prioritizesScriptExecutionBlocker() {
        let report = RemoteCapabilityReport(states: [
            .docker: unavailable(.permissionDenied),
            .scriptExecution: unavailable(.queryFailed),
        ])

        let presentation = SnippetCapabilityPresentation(report: report)

        #expect(presentation.blockerMessage == L("无法确认远程主机是否满足片段要求。"))
    }

    @Test("blocker reason codes have stable messages")
    func mapsBlockerReasons() {
        let cases: [(CapabilityReasonCode, String)] = [
            (.unsupportedPlatform, "当前主机平台不支持执行此片段。"),
            (.executableMissing, "远程主机缺少执行此片段所需的命令。"),
            (.permissionDenied, "当前用户没有执行此片段所需的权限。"),
            (.daemonNotRunning, "执行此片段所需的服务未运行。"),
            (.partialData, "远程主机未提供执行此片段所需的完整数据。"),
            (.queryFailed, "无法确认远程主机是否满足片段要求。"),
            (.unknown, "远程主机暂时无法满足片段要求。"),
        ]

        for (reason, message) in cases {
            let presentation = SnippetCapabilityPresentation(report: RemoteCapabilityReport(
                states: [.docker: unavailable(reason)]
            ))

            #expect(presentation.blockerMessage == L(message))
        }
    }

    @Test("capability ordering is deterministic regardless of dictionary construction")
    func deterministicCapabilityOrdering() {
        let expected = L("远程主机缺少执行此片段所需的命令。")
        let first = SnippetCapabilityPresentation(report: RemoteCapabilityReport(states: [
            .logs: unavailable(.permissionDenied),
            .docker: unavailable(.executableMissing),
        ]))
        let second = SnippetCapabilityPresentation(report: RemoteCapabilityReport(states: [
            .docker: unavailable(.executableMissing),
            .logs: unavailable(.permissionDenied),
        ]))

        #expect(first.blockerMessage == expected)
        #expect(second.blockerMessage == expected)
    }

    @Test("degraded capability warns but remains executable")
    func degradedCapabilityProducesWarning() {
        let presentation = SnippetCapabilityPresentation(report: RemoteCapabilityReport(states: [
            .scriptExecution: .supported,
            .docker: .degraded(issues: [CapabilityIssue(code: .partialData)]),
        ]))

        #expect(presentation.blockerMessage == nil)
        #expect(
            presentation.degradedMessage
                == L("部分远程能力数据不可用，片段仍可继续执行。")
        )
    }

    @Test("supported capabilities produce no blocker or warning")
    func supportedCapabilitiesProduceNoMessage() {
        let presentation = SnippetCapabilityPresentation(report: RemoteCapabilityReport(states: [
            .scriptExecution: .supported,
            .docker: .supported,
        ]))

        #expect(presentation.blockerMessage == nil)
        #expect(presentation.degradedMessage == nil)
    }

    @Test("presentation has no Docker implementation type coupling")
    func hasNoDockerTypeCoupling() throws {
        let source = try source(named: "Conn/Commands/SnippetCapabilityPresentation.swift")

        #expect(!source.contains("import ConnOps"))
        #expect(!source.contains("DockerAvailability"))
    }

    private func unavailable(_ code: CapabilityReasonCode) -> CapabilityState {
        .unavailable(issue: CapabilityIssue(code: code))
    }

    private func source(named relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
    }
}
