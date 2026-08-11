import ConnKit
import Foundation
import Testing
@testable import Conn

@Suite("Snippet capability presentation")
struct SnippetCapabilityPresentationTests {
    private static let messageKeys = [
        "当前主机平台不支持执行此片段。",
        "远程主机缺少执行此片段所需的命令。",
        "当前用户没有执行此片段所需的权限。",
        "执行此片段所需的服务未运行。",
        "远程主机未提供执行此片段所需的完整数据。",
        "无法确认远程主机是否满足片段要求。",
        "远程主机暂时无法满足片段要求。",
        "当前主机平台仅支持此片段的部分能力，仍可继续执行。",
        "远程主机缺少部分可选命令，片段仍可继续执行。",
        "部分片段能力受权限限制，仍可继续执行。",
        "部分片段能力依赖的服务未运行，仍可继续执行。",
        "部分远程能力数据不可用，片段仍可继续执行。",
        "部分片段要求无法确认，仍可继续执行。",
        "部分片段能力状态未知，仍可继续执行。",
    ]

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

    @Test("all presentation messages are translated in every supported locale")
    func catalogCoversPresentationMessages() throws {
        let catalog = try JSONDecoder().decode(
            StringCatalog.self,
            from: Data(contentsOf: projectURL.appending(path: "Conn/Localizable.xcstrings"))
        )

        #expect(catalog.sourceLanguage == "zh-Hans")
        for key in Self.messageKeys {
            for locale in ["en", "ja", "ko", "zh-Hant"] {
                let stringUnit = try #require(
                    catalog.strings[key]?.localizations?[locale]?.stringUnit,
                    "Missing \(locale) translation for \(key)"
                )
                #expect(stringUnit.state == "translated")
                #expect(!stringUnit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @Test("presentation imports only ConnKit and has no Docker-specific identifiers")
    func hasOnlyReportLayerCoupling() throws {
        let source = try source(named: "Conn/Commands/SnippetCapabilityPresentation.swift")
        let imports = source.split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { $0.hasPrefix("import ") }

        #expect(imports == ["import ConnKit"])
        #expect(source.range(of: "docker", options: .caseInsensitive) == nil)
    }

    private func unavailable(_ code: CapabilityReasonCode) -> CapabilityState {
        .unavailable(issue: CapabilityIssue(code: code))
    }

    private var projectURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(named relativePath: String) throws -> String {
        return try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
    }
}

@Suite("Snippet compatibility result acceptance")
struct SnippetCompatibilityAcceptanceTests {
    @Test("accepts only a selected host with the current generation")
    func acceptsCurrentSelectedHost() {
        #expect(SnippetCompatibilityAcceptance.shouldAccept(
            hostID: "host",
            selectedHostIDs: ["host"],
            capturedGeneration: 7,
            currentGeneration: 7
        ))
    }

    @Test("rejects a result after host deselection")
    func rejectsDeselectedHost() {
        #expect(!SnippetCompatibilityAcceptance.shouldAccept(
            hostID: "host",
            selectedHostIDs: [],
            capturedGeneration: 7,
            currentGeneration: 7
        ))
    }

    @Test("rejects a stale generation for a still-selected host")
    func rejectsStaleGeneration() {
        #expect(!SnippetCompatibilityAcceptance.shouldAccept(
            hostID: "host",
            selectedHostIDs: ["host"],
            capturedGeneration: 6,
            currentGeneration: 7
        ))
    }
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: StringCatalogEntry]
}

private struct StringCatalogEntry: Decodable {
    let localizations: [String: StringCatalogLocalization]?
}

private struct StringCatalogLocalization: Decodable {
    let stringUnit: StringCatalogUnit?
}

private struct StringCatalogUnit: Decodable {
    let state: String
    let value: String
}
