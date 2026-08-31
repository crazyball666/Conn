import ConnKit
import Foundation

/// 一个 SSH 连接目标（主机 + 端口）。
public struct SSHEndpoint: Sendable, Equatable, Hashable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int = 22) {
        self.host = host
        self.port = port
    }

    /// 指纹库与连接池的键，形如 `example.com:22`。
    public var identifier: String { "\(host):\(port)" }
}

/// 一跳跳板机的连接上下文。放在 ConnSSH 层，避免连接池依赖具体 SSH 引擎。
public struct SSHJumpHop: Sendable {
    public let endpoint: SSHEndpoint
    public let username: String
    public let auth: SSHAuth

    public init(endpoint: SSHEndpoint, username: String, auth: SSHAuth) {
        self.endpoint = endpoint
        self.username = username
        self.auth = auth
    }
}

/// 私钥材料。
///
/// **只在建立连接的瞬间存在于内存**，由上层从 Keychain 取出后
/// 立即传入，用后即弃（技术方案 §4.7）。
public struct SSHPrivateKeyMaterial: Sendable {
    /// 私钥的存储表示。
    public enum Representation: Sendable {
        /// OpenSSH / PEM 文本（导入的既有密钥）。
        case pem(String)
        /// 原始私钥字节（Conn 生成的 ed25519 存 32 字节 rawRepresentation）。
        case raw(Data)
    }

    public let kind: SSHKey.Kind
    public let representation: Representation

    public init(kind: SSHKey.Kind, representation: Representation) {
        self.kind = kind
        self.representation = representation
    }

    /// 便利构造：从 PEM 文本（导入场景）。
    public init(kind: SSHKey.Kind, pem: String) {
        self.init(kind: kind, representation: .pem(pem))
    }

    /// 便利构造：从原始字节（生成场景）。
    public init(kind: SSHKey.Kind, raw: Data) {
        self.init(kind: kind, representation: .raw(raw))
    }
}

/// 认证方式。
public enum SSHAuth: Sendable {
    case password(String)
    case key(SSHPrivateKeyMaterial)
    /// keyboard-interactive（堡垒机 2FA / PAM 质询）。
    /// Citadel 引擎不支持（S1 结论 R3），会抛 `.unsupportedByEngine`。
    case keyboardInteractive

    /// 引擎能力标识，用于 `.unsupportedByEngine` 精确报告缺哪项。
    public enum Feature: Sendable, Equatable {
        case keyboardInteractive
        case agentForwarding
    }
}

/// 主机密钥校验策略（TOFU，技术方案 §4.1）。
public enum HostKeyPolicy: Sendable, Equatable {
    /// Trust On First Use：首次入库，之后严格比对。
    case tofu
    /// 严格：必须匹配给定指纹，否则拒绝。
    case strict(expectedFingerprint: String)
    /// 本次接受（用户在指纹变更告警里手动确认覆盖）。
    case acceptOnce
}

/// 一次命令执行的结果。
public struct ExecResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    // 用无损的 String(decoding:as:) 而非可失败初始化器：命令输出可能含
    // 非法/截断的 UTF-8（如二进制日志），此时应把坏字节替换为占位符而非
    // 整段丢弃返回 nil。
    // swiftlint:disable optional_data_string_conversion

    /// stdout 解码为 UTF-8 字符串（去尾部换行）。
    public var stdoutText: String {
        String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// stderr 解码为 UTF-8 字符串（去尾部换行）。
    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    // swiftlint:enable optional_data_string_conversion

    public var isSuccess: Bool { exitCode == 0 }
}

/// PTY 尺寸。
public struct TermSize: Sendable, Equatable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// SSH 层错误。每个 case 的 `diagnosis` 遵循「原因 + 下一步建议」
/// （技术方案 §10.5），可直接呈现给用户。
public enum SSHError: Error, Sendable, Equatable {
    /// 认证失败的细分原因。
    public enum AuthFailureReason: Sendable, Equatable {
        /// 密码或密钥不被接受。
        case badCredentials
        /// RSA 密钥但服务器只接受 rsa-sha2，而当前引擎只能发 ssh-rsa(SHA-1)。
        /// 这是 Citadel 连现代服务器的已知缺口（S1 结论）。
        case rsaSha2Unsupported
        /// 没有服务器接受的认证方法。
        case noAcceptedMethods
    }

    case connectionRefused(endpoint: SSHEndpoint)
    case dnsFailed(host: String)
    /// **连接**阶段超时（握手迟迟不完成）。诊断指向网络与防火墙。
    case timeout(endpoint: SSHEndpoint)
    /// **命令**执行超时：连接是通的，是这条命令跑得比 `seconds` 还久。
    ///
    /// 与 `.timeout` 分开是因为两者的「下一步」完全不同：连接超时该查网络，
    /// 命令超时查网络毫无意义（连接本来就通），而且必须告诉用户一件反直觉的事——
    /// **超时不会终止远端命令**，它只是停止本地等待（见 `CitadelSession.exec` 的说明）。
    case commandTimeout(endpoint: SSHEndpoint, seconds: Int)
    case authFailed(reason: AuthFailureReason)
    case missingPrivateKey
    case hostKeyMismatch(endpoint: SSHEndpoint, expected: String, actual: String)
    case hostKeyStoreUnavailable
    /// 配置了跳板链，但当前传输层没有提供跳板实现。
    case jumpChainUnsupported
    case unsupportedByEngine(SSHAuth.Feature)
    /// 跳板链在第 `hopIndex`（从 0 起）级失败，该级主机名为 `hopHost`。
    case jumpChainFailed(hopIndex: Int, hopHost: String)
    case channelClosed
    /// SFTP 子层错误：来自 Citadel 的 `SFTPMessage.Status`。
    ///
    /// `code` 是 SFTP 协议错误码（来自 `SFTPStatusCode.rawValue`），`message` 是**服务器
    /// 返回的原始消息**（英文，如 "No such file or directory"）——直接展示给用户，
    /// 不做翻译：i18n 的边界是 Conn 的产品文案，服务器消息是远端事实，由服务器自己负责语言。
    /// `CitadelFileSystem` 负责把 Citadel 类型包成这个 case（避免上层看到 Citadel）。
    case sftpError(code: UInt32, message: String)

    /// 面向用户的诊断：原因 + 下一步。按当前语言本地化（含 `%@`/`%d` 占位）。
    ///
    /// 对 `.sftpError` 而言，**直接返回 server message**——服务器返回的消息按它自己的
    /// 语言展示，不在客户端做无谓翻译。
    public var diagnosis: String {
        switch self {
        case let .connectionRefused(endpoint):
            String(format: L("无法连接 %@:%d：连接被拒绝。\n请确认 sshd 正在运行、端口配置正确且未被防火墙拦截。"),
                   endpoint.host, endpoint.port)
        case let .dnsFailed(host):
            String(format: L("无法解析主机 %@。\n请检查主机地址或 DNS 配置。"), host)
        case let .timeout(endpoint):
            String(format: L("连接 %@:%d 超时。\n请检查网络连通性和防火墙规则。"),
                   endpoint.host, endpoint.port)
        case let .commandTimeout(endpoint, seconds):
            String(format: L("命令在 %@:%d 上执行超过 %d 秒未返回，已停止等待。\n注意：命令可能仍在远程主机上运行；超时仅停止本地等待，不会终止远程进程。\n建议在终端中执行耗时较长的命令。"),
                   endpoint.host, endpoint.port, seconds)
        case let .authFailed(reason):
            switch reason {
            case .badCredentials:
                L("认证失败：密码或密钥未被接受。\n请核对用户名、密码和所选密钥。")
            case .rsaSha2Unsupported:
                L("认证失败：远程主机不接受当前 RSA 密钥签名算法。\nOpenSSH 8.8 及以上版本默认禁用 ssh-rsa (SHA-1)。建议改用 Ed25519 密钥。")
            case .noAcceptedMethods:
                L("认证失败：远程主机不接受所提供的认证方式。\n请确认远程主机允许密钥或密码登录。")
            }
        case .missingPrivateKey:
            L("密钥认证不可用：找不到对应的私钥材料。\n请在“密钥管理”中重新导入或生成密钥，然后重新选择。")
        case let .hostKeyMismatch(endpoint, expected, actual):
            String(format: L("主机指纹已变更，连接已阻止。\n校验端点：%@:%d\n远程主机密钥与首次记录不一致，可能源于系统重装或中间人攻击。\n已记录：%@\n当前：%@\n请确认变更来源后再手动信任。"),
                   endpoint.host, endpoint.port, expected, actual)
        case .hostKeyStoreUnavailable:
            L("无法读取主机指纹，连接已阻止。\n请检查本地数据库状态后重试。")
        case .jumpChainUnsupported:
            L("当前连接引擎不支持跳板机链路。\n请更新连接引擎或移除该主机的跳板机配置。")
        case let .unsupportedByEngine(feature):
            switch feature {
            case .keyboardInteractive:
                L("远程主机要求交互式认证（keyboard-interactive，常用于 2FA 或堡垒机）。\n当前版本暂不支持此方式，请改用密钥或密码登录。")
            case .agentForwarding:
                L("该连接需要 SSH Agent 转发，当前版本暂不支持。")
            }
        case let .jumpChainFailed(hopIndex, hopHost):
            String(format: L("跳板链第 %d 级（%@）连接失败。\n请单独检查该级跳板机的连通性和凭据。"),
                   hopIndex + 1, hopHost)
        case .channelClosed:
            L("连接通道已关闭。\n请重新连接或检查远程会话是否已终止。")
        case let .sftpError(_, message):
            // 服务器消息按它自己的语言展示，不在客户端做翻译（边界划分）。
            message
        }
    }
}

/// 把任意 `Error` 翻译成给用户看的一行诊断文案。
///
/// - 优先用 `SSHError.diagnosis`（已是业务层友好文案，含本地化）
/// - 其它错误降级到 `localizedDescription`（系统/三方库错误，依赖它们自己提供的描述）
///
/// **ViewModel 统一用这个**，不要直接 `error.localizedDescription`——否则会裸暴露
/// Citadel 内部类型名（如 `Citadel.SFTPMessage.Status错误1.`）。
public extension Error {
    var friendlyDiagnosis: String {
        if let sshError = self as? SSHError {
            return sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? sshError.diagnosis
        }
        return localizedDescription
    }
}
