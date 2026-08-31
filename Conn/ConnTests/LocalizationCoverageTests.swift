import Foundation
import Testing

@Suite("App localization coverage")
struct LocalizationCoverageTests {
    private let supportedLocales = ["en", "ja", "ko", "zh-Hant"]

    @Test("every literal L key is translated in every supported language")
    func literalLocalizedKeysHaveCompleteCatalogEntries() throws {
        for surface in sourceSurfaces {
            let catalog = try loadCatalog(surface.catalogPath)
            let keys = try localizedKeys(inDirectory: surface.sourcePath)
            try validate(keys: keys, in: catalog, surface: surface.name)
        }
    }

    @Test("dynamic UI keys are translated in their rendering module")
    func dynamicLocalizedKeysHaveCompleteCatalogEntries() throws {
        let appCatalog = try loadCatalog("Conn/Localizable.xcstrings")
        try validate(
            keys: ["概览", "进程", "文件", "Docker", "日志", "容器", "镜像", "卷", "网络", "Compose"],
            in: appCatalog,
            surface: "App dynamic navigation"
        )

        let uiCatalog = try loadCatalog("../Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings")
        let tmuxKeys = try tmuxInteractionKeys()
            .union(zellijInteractionKeys())
            .union(["主机", "终端", "脚本", "设置"])
        try validate(keys: tmuxKeys, in: uiCatalog, surface: "ConnUI dynamic terminal UI")

        let runnerCatalog = try loadCatalog("../Packages/ConnPackages/Sources/ConnRunner/Resources/Localizable.xcstrings")
        try validate(keys: builtinSnippetKeys(), in: runnerCatalog, surface: "ConnRunner built-ins")

        let sshCatalog = try loadCatalog("../Packages/ConnPackages/Sources/ConnSSH/Resources/Localizable.xcstrings")
        try validate(keys: dangerReasonKeys(), in: sshCatalog, surface: "ConnSSH danger reasons")
    }

    @Test("production UI does not bypass the localization entry point")
    func visibleChineseLiteralsUseLocalization() throws {
        let visibleAPIs = [
            "Text", "Button", "Label", "Section", "TextField", "SecureField", "ConnButton",
            "navigationTitle", "accessibilityLabel", "accessibilityHint", "alert", "confirmationDialog"
        ].joined(separator: "|")
        let expression = try NSRegularExpression(
            pattern: #"\b(?:\#(visibleAPIs))\(\s*(?:verbatim:\s*)?\"((?:\\.|[^\"\\])*)\""#
        )
        let han = try NSRegularExpression(pattern: #"\p{Han}"#)
        var violations: [String] = []

        for directory in productionSourceDirectories {
            for file in try swiftFiles(inDirectory: directory) {
                let source = try String(contentsOf: file, encoding: .utf8)
                    .components(separatedBy: "#Preview").first ?? ""
                let sourceRange = NSRange(source.startIndex..., in: source)
                for match in expression.matches(in: source, range: sourceRange) {
                    guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
                    let literal = String(source[literalRange])
                    let literalRangeNS = NSRange(literal.startIndex..., in: literal)
                    if han.firstMatch(in: literal, range: literalRangeNS) != nil {
                        let line = source[..<literalRange.lowerBound].reduce(1) { $1.isNewline ? $0 + 1 : $0 }
                        violations.append("\(file.lastPathComponent):\(line): \(literal)")
                    }
                }
            }
        }

        #expect(violations.isEmpty, "User-visible Chinese literals must use L(): \(violations)")
    }

    @Test("localized product copy avoids retired colloquial terminology")
    func localizedCopyUsesProfessionalTerminology() throws {
        let retiredFragments = [
            "还没有", "没有匹配的", "先去", "进终端", "会让你", "生成一把",
            "密钥管家", "片段", "服务器"
        ]
        var keys = Set<String>()
        for surface in sourceSurfaces {
            try keys.formUnion(localizedKeys(inDirectory: surface.sourcePath))
        }
        try keys.formUnion(tmuxInteractionKeys())
        try keys.formUnion(zellijInteractionKeys())
        try keys.formUnion(dangerReasonKeys())

        let violations = keys.filter { key in
            retiredFragments.contains { key.contains($0) }
        }.sorted()
        #expect(violations.isEmpty, "Retired or colloquial UI copy remains: \(violations)")
    }

    private struct SourceSurface {
        let name: String
        let sourcePath: String
        let catalogPath: String
    }

    private var sourceSurfaces: [SourceSurface] {
        [
            .init(name: "App", sourcePath: "Conn", catalogPath: "Conn/Localizable.xcstrings"),
            .init(
                name: "ConnCrypto",
                sourcePath: "../Packages/ConnPackages/Sources/ConnCrypto",
                catalogPath: "../Packages/ConnPackages/Sources/ConnCrypto/Resources/Localizable.xcstrings"
            ),
            .init(
                name: "ConnKit",
                sourcePath: "../Packages/ConnPackages/Sources/ConnKit",
                catalogPath: "../Packages/ConnPackages/Sources/ConnKit/Resources/Localizable.xcstrings"
            ),
            .init(
                name: "ConnOps",
                sourcePath: "../Packages/ConnPackages/Sources/ConnOps",
                catalogPath: "../Packages/ConnPackages/Sources/ConnOps/Resources/Localizable.xcstrings"
            ),
            .init(
                name: "ConnRunner",
                sourcePath: "../Packages/ConnPackages/Sources/ConnRunner",
                catalogPath: "../Packages/ConnPackages/Sources/ConnRunner/Resources/Localizable.xcstrings"
            ),
            .init(
                name: "ConnSSH",
                sourcePath: "../Packages/ConnPackages/Sources/ConnSSH",
                catalogPath: "../Packages/ConnPackages/Sources/ConnSSH/Resources/Localizable.xcstrings"
            ),
            .init(
                name: "ConnUI",
                sourcePath: "../Packages/ConnPackages/Sources/ConnUI",
                catalogPath: "../Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings"
            ),
            .init(
                name: "ConnTerminal",
                sourcePath: "../Packages/ConnPackages/Sources/ConnTerminal",
                catalogPath: "../Packages/ConnPackages/Sources/ConnUI/Resources/Localizable.xcstrings"
            )
        ]
    }

    private var productionSourceDirectories: [String] {
        sourceSurfaces.map(\.sourcePath)
    }

    private var projectDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func url(_ relativePath: String) -> URL {
        projectDirectory.appendingPathComponent(relativePath).standardizedFileURL
    }

    private func loadCatalog(_ relativePath: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url(relativePath)))
        let root = try #require(object as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "zh-Hans")
        return try #require(root["strings"] as? [String: Any])
    }

    private func localizedKeys(inDirectory relativePath: String) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: #"\bL\(\s*\"((?:\\.|[^\"\\])*)\""#)
        var keys = Set<String>()
        for file in try swiftFiles(inDirectory: relativePath) {
            let source = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "#Preview").first ?? ""
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let captured = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(unescapeSwiftLiteral(String(source[captured])))
            }
        }
        return keys
    }

    private func validate(keys: Set<String>, in catalog: [String: Any], surface: String) throws {
        for key in keys.sorted() {
            guard let entry = catalog[key] as? [String: Any] else {
                Issue.record("\(surface) catalog is missing key: \(key)")
                continue
            }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for locale in supportedLocales {
                guard
                    let localization = localizations[locale] as? [String: Any],
                    let unit = localization["stringUnit"] as? [String: Any],
                    unit["state"] as? String == "translated",
                    let value = unit["value"] as? String,
                    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    Issue.record("\(surface) key \(key) is missing a translated \(locale) value")
                    continue
                }
                #expect(
                    printfPlaceholders(in: value) == printfPlaceholders(in: key),
                    "\(surface) key \(key) has mismatched printf placeholders in \(locale): \(value)"
                )
            }
        }
    }

    private func swiftFiles(inDirectory relativePath: String) throws -> [URL] {
        let root = url(relativePath)
        let enumerator = try #require(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func printfPlaceholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|@|d|f|s)"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange]).replacingOccurrences(
                of: #"%\d+\$"#,
                with: "%",
                options: .regularExpression
            )
        }.sorted()
    }

    private func tmuxInteractionKeys() throws -> Set<String> {
        try descriptorKeys(in: "../Packages/ConnPackages/Sources/ConnMultiplexer/TmuxInteraction.swift")
    }

    private func zellijInteractionKeys() throws -> Set<String> {
        try descriptorKeys(
            in: "../Packages/ConnPackages/Sources/ConnMultiplexer/ZellijInteraction.swift"
        )
    }

    private func descriptorKeys(in relativePath: String) throws -> Set<String> {
        let source = try String(contentsOf: url(relativePath), encoding: .utf8)
        var keys = Set<String>()
        let named = try NSRegularExpression(
            pattern: #"(?:titleKey|placeholderKey|successNoticeKey|unavailableNoticeKey):\s*\"([^\"]+)\""#
        )
        let descriptor = try NSRegularExpression(
            pattern: #"descriptor\(\s*\.[^,]+,\s*\"([^\"]+)\""#,
            options: [.dotMatchesLineSeparators]
        )
        for expression in [named, descriptor] {
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let captured = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[captured]))
            }
        }
        return keys
    }

    private func builtinSnippetKeys() throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url(
            "../Packages/ConnPackages/Sources/ConnRunner/Resources/builtin-snippets.json"
        )))
        let root = try #require(object as? [String: Any])
        let groups = try #require(root["groups"] as? [[String: Any]])
        var keys = Set<String>()
        for group in groups {
            if let title = group["title"] as? String {
                keys.insert(title)
            }
            for snippet in group["snippets"] as? [[String: Any]] ?? [] {
                if let title = snippet["title"] as? String {
                    keys.insert(title)
                }
            }
        }
        return keys
    }

    private func dangerReasonKeys() throws -> Set<String> {
        let source = try String(contentsOf: url(
            "../Packages/ConnPackages/Sources/ConnSSH/DangerCommandRules.swift"
        ), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"\(#.*?,\s*"([^"]+)"\)"#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[captured])
        })
    }

    private func unescapeSwiftLiteral(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\"#, with: #"\"#)
    }
}
