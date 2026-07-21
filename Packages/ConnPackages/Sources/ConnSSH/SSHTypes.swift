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
/// 立即传入，用后即弃（技术方案 §4.7：内存中 passphrase 用后置零）。
public struct SSHPrivateKeyMaterial: Sendable {
    public let kind: SSHKey.Kind
    /// OpenSSH / PEM 编码的私钥。SE 密钥此字段为空，签名走 `LAContext`。
    public let pem: String
    public let passphrase: String?

    public init(kind: SSHKey.Kind, pem: String, passphrase: String? = nil) {
        self.kind = kind
        self.pem = pem
        self.passphrase = passphrase
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

    /// stdout 解码为 UTF-8 字符串（去尾部换行）。
    ///
    /// 用无损的 `String(decoding:as:)` 而非可失败初始化器：命令输出可能含
    /// 非法/截断的 UTF-8（如二进制日志），此时应把坏字节替换为占位符而非
    /// 整段丢弃返回 nil。
    // swiftlint:disable:next optional_data_string_conversion
    public var stdoutText: String {
        String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    // swiftlint:disable:next optional_data_string_conversion
    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

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

    /// 面向用户的诊断：原因 + 下一步。
    public var diagnosis: String {
        switch self {
        case let .connectionRefused(endpoint):
            "无法连接 \(endpoint.host):\(endpoint.port)：连接被拒绝。\n下一步：确认 sshd 正在运行、端口正确、未被防火墙拦截。"
        case let .dnsFailed(host):
            "无法解析主机 \(host)。\n下一步：检查地址拼写，或确认 DNS 可用。"
        case let .timeout(endpoint):
            "连接 \(endpoint.host):\(endpoint.port) 超时。\n下一步：检查网络连通性与防火墙规则。"
        case let .authFailed(reason):
            switch reason {
            case .badCredentials:
                "认证失败：密码或密钥不被接受。\n下一步：核对用户名、密码或所选密钥。"
            case .rsaSha2Unsupported:
                "认证失败：该服务器不接受当前 RSA 密钥的签名算法。\n原因：现代 OpenSSH（8.8+）已禁用 ssh-rsa(SHA-1)。\n下一步：建议改用 ed25519 密钥——它在所有现代与旧版服务器上都可用。"
            case .noAcceptedMethods:
                "认证失败：服务器不接受所提供的任何认证方式。\n下一步：确认服务器允许密钥或密码登录。"
            }
        case let .hostKeyMismatch(expected, actual):
            "主机指纹已变更，连接已阻断。\n原因：服务器密钥与首次记录不符（可能是重装系统，也可能是中间人攻击）。\n记录：\(expected)\n当前：\(actual)\n下一步：确认变更来源后再手动信任。"
        case let .unsupportedByEngine(feature):
            switch feature {
            case .keyboardInteractive:
                "该服务器需要交互式认证（keyboard-interactive，常见于 2FA / 堡垒机）。\n下一步：当前版本暂不支持此方式，请使用密钥或密码登录。"
            case .agentForwarding:
                "该连接需要 SSH Agent 转发，当前版本暂不支持。"
            }
        case let .jumpChainFailed(hopIndex, hopHost):
            "跳板链在第 \(hopIndex + 1) 级（\(hopHost)）连接失败。\n下一步：单独测试该级跳板机的连通性与凭据。"
        case .channelClosed:
            "连接通道已关闭。\n下一步：下拉重连，或检查服务器端会话是否被终止。"
        }
    }
}
