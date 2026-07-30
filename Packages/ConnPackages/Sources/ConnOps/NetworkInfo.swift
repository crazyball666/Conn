import Foundation

/// 网络列表项（`docker network ls`）。
public struct NetworkInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let scope: String

    public init(id: String, name: String, driver: String, scope: String) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
    }

    /// Docker 预置的三张网，永远删不掉。
    ///
    /// 「未使用」徽标必须排除它们：`network ls --filter dangling=true` 会把没有容器
    /// 接入的 `bridge` / `host` / `none` 一并列出，而对它们打徽标只是噪声——
    /// 用户既不能也不该删。
    public var isPredefined: Bool {
        name == "bridge" || name == "host" || name == "none"
    }
}

/// 网络详情（`docker network inspect`）。
public struct NetworkDetail: Equatable, Sendable {
    /// 接入该网的容器。`docker network inspect` 直接给，**无需额外命令**。
    public struct AttachedContainer: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let ipv4: String?

        public init(id: String, name: String, ipv4: String?) {
            self.id = id
            self.name = name
            self.ipv4 = ipv4
        }
    }

    public let id: String
    public let name: String
    public let driver: String
    public let scope: String
    public let subnet: String?
    public let gateway: String?
    public let isInternal: Bool
    /// 按容器名排序——JSON 字典无序，不排会让 UI 每次刷新跳动。
    public let attachedContainers: [AttachedContainer]

    public init(
        id: String, name: String, driver: String, scope: String,
        subnet: String?, gateway: String?, isInternal: Bool,
        attachedContainers: [AttachedContainer]
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
        self.subnet = subnet
        self.gateway = gateway
        self.isInternal = isInternal
        self.attachedContainers = attachedContainers
    }
}
