import Foundation

public enum DockerComposeDialect: String, Sendable, Equatable, Hashable {
    case v2
    case v1

    var command: String {
        switch self {
        case .v2: "docker compose"
        case .v1: "docker-compose"
        }
    }
}

public enum DockerComposeState: String, Sendable, Equatable, Hashable {
    case running
    case partial
    case stopped
    case unknown
}

public enum DockerComposeProjectSource: String, Sendable, Equatable, Hashable {
    case automatic
    case manual
}

public struct DockerComposeProject: Identifiable, Sendable, Equatable, Hashable {
    public let name: String
    public var state: DockerComposeState
    public var configFiles: [String]
    public var projectDirectory: String
    public var source: DockerComposeProjectSource
    public var serviceCount: Int
    public var containerCount: Int
    public var runningContainerCount: Int

    public var id: String { name }

    public init(
        name: String,
        state: DockerComposeState,
        configFiles: [String],
        projectDirectory: String,
        source: DockerComposeProjectSource,
        serviceCount: Int = 0,
        containerCount: Int = 0,
        runningContainerCount: Int = 0
    ) {
        self.name = name
        self.state = state
        self.configFiles = configFiles
        self.projectDirectory = projectDirectory
        self.source = source
        self.serviceCount = serviceCount
        self.containerCount = containerCount
        self.runningContainerCount = runningContainerCount
    }
}

public struct DockerComposeService: Identifiable, Sendable, Equatable, Hashable {
    public let name: String
    public let image: String?
    public let state: DockerComposeState
    public let containerCount: Int
    public let runningContainerCount: Int
    public let status: String
    public let ports: String

    public var id: String { name }

    public init(
        name: String,
        image: String?,
        state: DockerComposeState,
        containerCount: Int,
        runningContainerCount: Int,
        status: String,
        ports: String
    ) {
        self.name = name
        self.image = image
        self.state = state
        self.containerCount = containerCount
        self.runningContainerCount = runningContainerCount
        self.status = status
        self.ports = ports
    }
}

public enum DockerComposeValidationError: Sendable, Equatable {
    case configFileMustBeAbsolute
    case projectDirectoryMustBeAbsolute
    case invalidProjectName(String)
}

public enum DockerComposeError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            return String(
                format: L("Docker Compose 命令失败（退出码 %d）"),
                exitCode
            )
        }
    }
}

public struct DockerComposeManualDraft: Sendable, Equatable {
    public var configFile: String
    public var projectDirectory: String
    public var projectName: String

    public init(
        configFile: String = "",
        projectDirectory: String = "",
        projectName: String = ""
    ) {
        self.configFile = configFile
        self.projectDirectory = projectDirectory
        self.projectName = projectName
    }

    public func validate() -> [DockerComposeValidationError] {
        let file = configFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        var errors: [DockerComposeValidationError] = []
        if !file.hasPrefix("/") {
            errors.append(.configFileMustBeAbsolute)
        }
        if !directory.isEmpty, !directory.hasPrefix("/") {
            errors.append(.projectDirectoryMustBeAbsolute)
        }
        if !name.isEmpty, !Self.isValidProjectName(name) {
            errors.append(.invalidProjectName(name))
        }
        return errors
    }

    public var project: DockerComposeProject? {
        guard validate().isEmpty else { return nil }
        let file = configFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitDirectory = projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = explicitDirectory.isEmpty
            ? URL(fileURLWithPath: file).deletingLastPathComponent().path
            : explicitDirectory
        let explicitName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = explicitName.isEmpty
            ? Self.normalizedProjectName(URL(fileURLWithPath: directory).lastPathComponent)
            : explicitName
        return DockerComposeProject(
            name: name,
            state: .unknown,
            configFiles: [file],
            projectDirectory: directory,
            source: .manual
        )
    }

    public static func normalizedProjectName(_ value: String) -> String {
        var result = ""
        var lastWasReplacement = false
        for scalar in value.lowercased().unicodeScalars {
            let isLetter = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            let isAllowedSeparator = scalar == "-" || scalar == "_"
            if isLetter || isDigit || isAllowedSeparator {
                result.unicodeScalars.append(scalar)
                lastWasReplacement = false
            } else if !lastWasReplacement {
                result.append("-")
                lastWasReplacement = true
            }
        }
        while let first = result.first, !first.isASCIIAlphaNumeric {
            result.removeFirst()
        }
        while result.last == "-" {
            result.removeLast()
        }
        return result.isEmpty ? "compose" : result
    }

    private static func isValidProjectName(_ value: String) -> Bool {
        guard let first = value.first, first.isASCIIAlphaNumeric else { return false }
        return value.allSatisfy { character in
            character.isASCIIAlphaNumeric || character == "-" || character == "_"
        }
    }
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122)
        }
    }
}
