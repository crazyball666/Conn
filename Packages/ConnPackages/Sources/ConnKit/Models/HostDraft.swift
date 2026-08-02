import Foundation

/// 主机表单的可变草稿。
///
/// 与不可变的领域模型 `Host` 分离：表单在编辑期需要部分填充、逐字段校验，
/// 而 `Host` 是已定稿的实体。`SSHCommandParser` 产出此类型，UI 双向绑定它，
/// 保存时 `toHost()` 定稿。
public struct HostDraft: Sendable, Equatable {
    /// 可校验的字段标识（校验错误按字段归位到 UI）。
    public enum Field: Sendable, Hashable {
        case name, address, port, username, key
    }

    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var authKind: Host.AuthKind
    public var keyUUID: String?
    public var jumpChain: [String]
    public var groupIDs: [String]
    public var tags: [String]
    public var icon: String?
    public var color: String?
    public var note: String?

    public init(
        name: String = "",
        address: String = "",
        port: Int = 22,
        username: String = "",
        authKind: Host.AuthKind = .password,
        keyUUID: String? = nil,
        jumpChain: [String] = [],
        groupIDs: [String] = [],
        tags: [String] = [],
        icon: String? = nil,
        color: String? = nil,
        note: String? = nil
    ) {
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.authKind = authKind
        self.keyUUID = keyUUID
        self.jumpChain = jumpChain
        self.groupIDs = groupIDs
        self.tags = tags
        self.icon = icon
        self.color = color
        self.note = note
    }

    /// 从已有主机构造草稿（编辑场景）。
    public init(from host: Host) {
        name = host.name
        address = host.address
        port = host.port
        username = host.username
        authKind = host.authKind
        keyUUID = host.keyUUID
        jumpChain = host.jumpChain
        groupIDs = host.groupIDs
        tags = host.tags
        icon = host.icon
        color = host.color
        note = host.note
    }

    /// 逐字段校验。返回 字段→错误信息；空字典表示可保存。
    ///
    /// PRD §5.1：只必填「地址 + 用户名 + 认证」。名称留空时用地址兜底
    /// （见 `toHost`），故不强制。
    public func validate() -> [Field: String] {
        var errors: [Field: String] = [:]
        if address.trimmingCharacters(in: .whitespaces).isEmpty {
            errors[.address] = L("请填写主机地址")
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            errors[.username] = L("请填写用户名")
        }
        if !(1 ... 65535).contains(port) {
            errors[.port] = L("端口需在 1–65535 之间")
        }
        if authKind == .key, keyUUID == nil {
            errors[.key] = L("请选择一把 SSH 密钥")
        }
        return errors
    }

    public var isValid: Bool { validate().isEmpty }

    /// 定稿为领域模型。名称留空时用地址兜底。
    ///
    /// - Parameter existingID: 编辑场景传入原 id 以保留主键；新增传 nil。
    public func toHost(existingID: String? = nil) -> Host {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return Host(
            id: existingID ?? UUID().uuidString,
            name: trimmedName.isEmpty ? address : trimmedName,
            address: address.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            port: port,
            authKind: authKind,
            keyUUID: keyUUID,
            jumpChain: jumpChain,
            groupIDs: groupIDs,
            tags: tags,
            icon: icon,
            color: color,
            note: note
        )
    }
}
