import Foundation

/// 把粘贴的 `ssh` 命令解析为主机草稿（PRD §5.1）。
///
/// 支持 `ssh [-p port] [-i keyfile] [user@]host`（选项可乱序）与
/// `ssh://user@host:port` URL 形式。非 ssh 文本或缺主机时返回 nil。
public enum SSHCommandParser {
    public static func parse(_ text: String) -> HostDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ssh://") {
            return parseURL(trimmed)
        }
        return parseCommand(trimmed)
    }

    // MARK: - URL 形式

    private static func parseURL(_ text: String) -> HostDraft? {
        guard let url = URLComponents(string: text),
              let host = url.host, !host.isEmpty
        else { return nil }

        var draft = HostDraft(address: host)
        if let user = url.user {
            draft.username = user
        }
        if let port = url.port {
            draft.port = port
        }
        return draft.validate()[.port] == nil ? draft : nil
    }

    // MARK: - 命令形式

    private static func parseCommand(_ text: String) -> HostDraft? {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.first == "ssh" else { return nil }
        tokens.removeFirst()

        var draft = HostDraft()
        var target: String?
        var portParseFailed = false
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "-p":
                // 端口在下一个 token
                guard index + 1 < tokens.count, let port = Int(tokens[index + 1]) else {
                    portParseFailed = true
                    index += 1
                    continue
                }
                draft.port = port
                index += 2
            case "-i":
                // 指定了密钥文件 → 认证方式判为密钥
                draft.authKind = .key
                index += 2 // 跳过 -i 与其参数
            default:
                if token.hasPrefix("-") {
                    // 其他未识别选项：连带其可能的参数一起跳过（保守跳 1 个）
                    index += 1
                } else if target == nil {
                    target = token
                    index += 1
                } else {
                    index += 1
                }
            }
        }

        guard !portParseFailed, let target else { return nil }
        applyTarget(target, to: &draft)
        return draft.validate()[.port] == nil ? draft : nil
    }

    /// 解析 `[user@]host` 目标，含 IPv6 的 `[...]` 包裹。
    private static func applyTarget(_ target: String, to draft: inout HostDraft) {
        var remainder = target
        if let atIndex = remainder.lastIndex(of: "@") {
            draft.username = String(remainder[remainder.startIndex ..< atIndex])
            remainder = String(remainder[remainder.index(after: atIndex)...])
        }
        // IPv6：ssh root@[2001:db8::1] → 去掉方括号
        if remainder.hasPrefix("["), let close = remainder.firstIndex(of: "]") {
            draft.address = String(remainder[remainder.index(after: remainder.startIndex) ..< close])
        } else {
            draft.address = remainder
        }
    }
}
