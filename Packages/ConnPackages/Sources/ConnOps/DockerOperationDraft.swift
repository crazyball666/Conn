import Foundation

/// `docker run --publish` 的一个端口映射。
public struct PortBinding: Equatable, Sendable {
    public enum `Protocol`: String, Equatable, Sendable, CaseIterable {
        case tcp
        case udp
        case sctp
    }

    public let hostPort: String
    public let containerPort: String
    public let `protocol`: `Protocol`

    public init(hostPort: String, containerPort: String, protocol: `Protocol` = .tcp) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.`protocol` = `protocol`
    }

    var dockerValue: String {
        "\(hostPort):\(containerPort)/\(`protocol`.rawValue)"
    }

    var hasValidPorts: Bool {
        Self.isPort(hostPort) && Self.isPort(containerPort)
    }

    private static func isPort(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let port = Int(value)
        else {
            return false
        }
        return (1...65_535).contains(port)
    }
}

/// `docker run --env` 的一个环境变量。
public struct EnvironmentEntry: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    var dockerValue: String { "\(key)=\(value)" }

    var hasValidKey: Bool {
        guard let first = key.unicodeScalars.first, Self.isEnvironmentFirst(first) else {
            return false
        }
        return key.unicodeScalars.dropFirst().allSatisfy(Self.isEnvironmentRest)
    }

    private static func isEnvironmentFirst(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isEnvironmentRest(_ scalar: UnicodeScalar) -> Bool {
        isEnvironmentFirst(scalar) || (48...57).contains(scalar.value)
    }
}

/// `docker run --mount` 的一个挂载。
public struct MountEntry: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case namedVolume(String)
        case bind(String)
    }

    public let source: Source
    public let target: String
    public let readOnly: Bool

    public init(source: Source, target: String, readOnly: Bool = false) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }

    public init(source: Source, target: String, isReadOnly: Bool) {
        self.init(source: source, target: target, readOnly: isReadOnly)
    }

    public var isReadOnly: Bool { readOnly }

    var dockerValue: String {
        let sourceValue: String
        let type: String
        switch source {
        case .namedVolume(let name):
            type = "volume"
            sourceValue = name
        case .bind(let path):
            type = "bind"
            sourceValue = path
        }

        var value = "type=\(type),src=\(sourceValue),dst=\(target)"
        if readOnly {
            value += ",readonly"
        }
        return value
    }
}

/// Docker 的容器重启策略。
public enum RestartPolicy: String, Equatable, Sendable, CaseIterable {
    case no
    case always
    case unlessStopped = "unless-stopped"
    case onFailure = "on-failure"
}

/// 本地可确定的草稿问题。Docker daemon 仍是最终参数裁决者。
public enum ValidationError: Equatable, Sendable {
    case imageRequired
    case invalidPort(PortBinding)
    case duplicateHostPort(hostPort: String, protocol: PortBinding.`Protocol`)
    case invalidEnvironmentKey(String)
    case mountTargetMustBeAbsolute(String)
    case emptyOtherOptionToken
    case conflictingOtherOptionToken(String)
    case resourceNameRequired
}

/// 创建容器的纯草稿。额外参数被明确分为镜像前的 Docker 选项和镜像后的启动命令。
public struct DockerRunDraft: Equatable, Sendable {
    public let image: String
    public let name: String?
    public let detached: Bool
    public let network: String?
    public let ports: [PortBinding]
    public let environment: [EnvironmentEntry]
    public let mounts: [MountEntry]
    public let restartPolicy: RestartPolicy
    public let otherOptionTokens: [String]
    public let commandTokens: [String]

    public init(
        image: String,
        name: String? = nil,
        detached: Bool = false,
        network: String? = nil,
        ports: [PortBinding] = [],
        environment: [EnvironmentEntry] = [],
        mounts: [MountEntry] = [],
        restartPolicy: RestartPolicy = .no,
        otherOptionTokens: [String] = [],
        commandTokens: [String] = []
    ) {
        self.image = image
        self.name = name
        self.detached = detached
        self.network = network
        self.ports = ports
        self.environment = environment
        self.mounts = mounts
        self.restartPolicy = restartPolicy
        self.otherOptionTokens = otherOptionTokens
        self.commandTokens = commandTokens
    }

    /// 按 `docker run` 参数顺序展开，供复核 UI 展示。
    public var effectiveArguments: [String] {
        var arguments: [String] = []
        if let name {
            arguments += ["--name", name]
        }
        if detached {
            arguments.append("--detach")
        }
        if let network {
            arguments += ["--network", network]
        }
        for port in ports {
            arguments += ["--publish", port.dockerValue]
        }
        for entry in environment {
            arguments += ["--env", entry.dockerValue]
        }
        for mount in mounts {
            arguments += ["--mount", mount.dockerValue]
        }
        if restartPolicy != .no {
            arguments += ["--restart", restartPolicy.rawValue]
        }
        arguments += otherOptionTokens
        arguments.append(image)
        arguments += commandTokens
        return arguments
    }

    public func validate() -> [ValidationError] {
        var errors: [ValidationError] = []
        if image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.imageRequired)
        }

        var hostPorts = Set<String>()
        for port in ports {
            if !port.hasValidPorts {
                errors.append(.invalidPort(port))
            }

            let key = "\(port.hostPort)\u{0}\(port.protocol.rawValue)"
            if !hostPorts.insert(key).inserted {
                errors.append(.duplicateHostPort(hostPort: port.hostPort, protocol: port.protocol))
            }
        }

        for entry in environment where !entry.hasValidKey {
            errors.append(.invalidEnvironmentKey(entry.key))
        }
        for mount in mounts where !mount.target.hasPrefix("/") {
            errors.append(.mountTargetMustBeAbsolute(mount.target))
        }
        for token in otherOptionTokens {
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyOtherOptionToken)
            } else if Self.isConflictingOtherOption(token) {
                errors.append(.conflictingOtherOptionToken(token))
            }
        }
        return errors
    }

    private static func isConflictingOtherOption(_ token: String) -> Bool {
        if token == "--" {
            return true
        }

        let structuredOptions = [
            "--name", "--network", "--restart", "--detach", "-d",
            "--publish", "-p", "--env", "-e", "--volume", "-v", "--mount",
        ]
        return structuredOptions.contains { option in
            token == option || token.hasPrefix(option + "=")
        }
    }
}

/// 创建 Docker 卷的纯草稿。
public struct DockerVolumeDraft: Equatable, Sendable {
    public let name: String
    public let driver: String
    public let otherOptionTokens: [String]

    public init(name: String, driver: String = "local", otherOptionTokens: [String] = []) {
        self.name = name
        self.driver = driver
        self.otherOptionTokens = otherOptionTokens
    }

    public func validate() -> [ValidationError] {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [.resourceNameRequired] : []
    }
}

/// 创建 Docker 网络的纯草稿。
public struct DockerNetworkDraft: Equatable, Sendable {
    public let name: String
    public let driver: String
    public let isInternal: Bool
    public let isAttachable: Bool
    public let otherOptionTokens: [String]

    public init(
        name: String,
        driver: String = "bridge",
        isInternal: Bool = false,
        isAttachable: Bool = false,
        otherOptionTokens: [String] = []
    ) {
        self.name = name
        self.driver = driver
        self.isInternal = isInternal
        self.isAttachable = isAttachable
        self.otherOptionTokens = otherOptionTokens
    }

    public func validate() -> [ValidationError] {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [.resourceNameRequired] : []
    }
}

/// `docker system prune` 的范围开关。
public struct DockerSystemPruneOptions: Equatable, Sendable {
    public let allUnusedImages: Bool
    public let includeVolumes: Bool

    public init(allUnusedImages: Bool = false, includeVolumes: Bool = false) {
        self.allUnusedImages = allUnusedImages
        self.includeVolumes = includeVolumes
    }

    public init(removeAllUnusedImages: Bool, includeVolumes: Bool = false) {
        self.init(allUnusedImages: removeAllUnusedImages, includeVolumes: includeVolumes)
    }
}
