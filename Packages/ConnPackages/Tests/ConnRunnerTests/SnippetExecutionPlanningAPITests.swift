import ConnRunner
import Foundation
import Testing

@Suite("Snippet execution planning API boundary")
struct SnippetExecutionPlanningAPITests {
    @Test("planner artifacts expose no public initializer")
    func artifactsCannotBeConstructedByExternalClients() throws {
        let source = try String(
            contentsOf: packageRoot
                .appending(path: "Sources/ConnRunner/SnippetExecutionPlanner.swift"),
            encoding: .utf8
        )

        for typeName in ["SnippetHostPreparation", "SnippetExecutionPlan"] {
            let body = try #require(typeBody(named: typeName, in: source))
            #expect(!body.contains("public init("), "\(typeName) must be planner-constructed")
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func typeBody(named typeName: String, in source: String) -> String? {
        guard let declaration = source.range(of: "public struct \(typeName)"),
              let openingBrace = source[declaration.upperBound...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        for index in source.indices[openingBrace...] {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            default:
                break
            }
        }
        return nil
    }
}
