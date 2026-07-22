import Foundation

/// 一键部署公钥到主机（技术方案 §4.7）。
///
/// 生成把公钥追加进 `~/.ssh/authorized_keys` 的**幂等**命令（先 grep 去重），
/// 由上层用已建立的会话 exec。放在 ConnCrypto 是因为它只产命令字符串、不碰传输层。
public enum PublicKeyDeployer {
    /// 生成幂等的部署命令。
    ///
    /// - Parameter publicKeyOpenSSH: `authorized_keys` 格式公钥行。
    /// - Returns: 可交给 `SSHSession.exec` 的 shell 命令。
    ///
    /// 幂等性：`grep -qF ... || echo ... >>`——已存在则不重复追加。同时确保
    /// `~/.ssh` 700、`authorized_keys` 600 权限（sshd 对权限敏感，过宽会拒绝）。
    public static func deployCommand(publicKeyOpenSSH: String) -> String {
        let escaped = shellSingleQuote(publicKeyOpenSSH)
        return """
        mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
        grep -qF \(escaped) ~/.ssh/authorized_keys || echo \(escaped) >> ~/.ssh/authorized_keys
        """
    }

    /// 生成移除公钥的命令（撤销部署）。
    public static func removeCommand(publicKeyOpenSSH: String) -> String {
        let escaped = shellSingleQuote(publicKeyOpenSSH)
        return "grep -vF \(escaped) ~/.ssh/authorized_keys > ~/.ssh/ak.tmp && mv ~/.ssh/ak.tmp ~/.ssh/authorized_keys"
    }

    /// 把字符串安全包进单引号（处理内部单引号）。
    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
