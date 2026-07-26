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

/// 私钥材料。
///
/// **只在建立连接的瞬间存在于内存**，由上层从 Keychain / Secure Enclave 取出后
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
    public let passphrase: String?

    public init(kind: SSHKey.Kind, representation: Representation, passphrase: String? = nil) {
        self.kind = kind
        self.representation = representation
        self.passphrase = passphrase
    }

    /// 便利构造：从 PEM 文本（导入场景）。
    public init(kind: SSHKey.Kind, pem: String, passphrase: String? = nil) {
        self.init(kind: kind, representation: .pem(pem), passphrase: passphrase)
    }

    /// 便利构造：从原始字节（生成场景）。
    public init(kind: SSHKey.Kind, raw: Data, passphrase: String? = nil) {
        self.init(kind: kind, representation: .raw(raw), passphrase: passphrase)
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
    case timeout(endpoint: SSHEndpoint)
    case authFailed(reason: AuthFailureReason)
    case hostKeyMismatch(expected: String, actual: String)
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
            String(format: L("无法连接 %@:%d：连接被拒绝。\n下一步：确认 sshd 正在运行、端口正确、未被防火墙拦截。"),
                   endpoint.host, endpoint.port)
        case let .dnsFailed(host):
            String(format: L("无法解析主机 %@。\n下一步：检查地址拼写，或确认 DNS 可用。"), host)
        case let .timeout(endpoint):
            String(format: L("连接 %@:%d 超时。\n下一步：检查网络连通性与防火墙规则。"),
                   endpoint.host, endpoint.port)
        case let .authFailed(reason):
            switch reason {
            case .badCredentials:
                L("认证失败：密码或密钥不被接受。\n下一步：核对用户名、密码或所选密钥。")
            case .rsaSha2Unsupported:
                L("认证失败：该服务器不接受当前 RSA 密钥的签名算法。\n原因：现代 OpenSSH（8.8+）已禁用 ssh-rsa(SHA-1)。\n下一步：建议改用 ed25519 密钥——它在所有现代与旧版服务器上都可用。")
            case .noAcceptedMethods:
                L("认证失败：服务器不接受所提供的任何认证方式。\n下一步：确认服务器允许密钥或密码登录。")
            }
        case let .hostKeyMismatch(expected, actual):
            String(format: L("主机指纹已变更，连接已阻断。\n原因：服务器密钥与首次记录不符（可能是重装系统，也可能是中间人攻击）。\n记录：%@\n当前：%@\n下一步：确认变更来源后再手动信任。"),
                   expected, actual)
        case let .unsupportedByEngine(feature):
            switch feature {
            case .keyboardInteractive:
                L("该服务器需要交互式认证（keyboard-interactive，常见于 2FA / 堡垒机）。\n下一步：当前版本暂不支持此方式，请使用密钥或密码登录。")
            case .agentForwarding:
                L("该连接需要 SSH Agent 转发，当前版本暂不支持。")
            }
        case let .jumpChainFailed(hopIndex, hopHost):
            String(format: L("跳板链在第 %d 级（%@）连接失败。\n下一步：单独测试该级跳板机的连通性与凭据。"),
                   hopIndex + 1, hopHost)
        case .channelClosed:
            L("连接通道已关闭。\n下一步：下拉重连，或检查服务器端会话是否被终止。")
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
