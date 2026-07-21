import Foundation

/// 命令危险性裁决（技术方案 §4.2）。
public struct DangerVerdict: Sendable, Equatable {
    /// 命中高危规则（本身可能造成不可逆破坏）。
    public let isDangerous: Bool
    /// 是否需要执行前二次确认（危险命令，或生产主机上的敏感命令）。
    public let needsConfirmation: Bool
    /// 命中原因（供确认弹层展示）。
    public let reason: String?
}

/// 危险命令规则表。
///
/// 规则内置为正则（JSON 化可更新是后续优化）。分两级：
/// - **高危**：`rm -rf /`、`mkfs`、`dd of=/dev/`、fork bomb 等不可逆破坏 → 任何环境都确认。
/// - **生产敏感**：`systemctl stop/restart`、`reboot`、`kill` 等 → 仅生产标签主机确认。
public enum DangerCommandRules {
    /// 高危模式：命中即为危险，任何环境都需二次确认。
    private static let dangerousPatterns: [(pattern: String, reason: String)] = [
        // rm -rf 作用于根或家目录（/、/*、~、$HOME），但不含更深的子路径
        (#"\brm\s+(-[a-zA-Z]*\s+)*-?[a-zA-Z]*[rf][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(/|/\*|~|\$HOME)\s*$"#, "删除根目录或家目录"),
        (#"\bmkfs(\.\w+)?\b"#, "格式化文件系统"),
        (#"\bdd\b.*\bof=/dev/"#, "写入块设备（可能覆盖磁盘）"),
        (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "fork 炸弹"),
        (#">\s*/dev/(sd|nvme|hd|vd)\w*"#, "覆写块设备"),
        (#"\bchmod\s+-R\s+777\s+/\s*$"#, "递归放开根目录权限")
    ]

    /// 生产敏感模式：仅在生产标签主机上需确认。
    private static let productionSensitivePatterns: [(pattern: String, reason: String)] = [
        (#"\bsystemctl\s+(stop|restart|disable)\b"#, "在生产环境停止/重启服务"),
        (#"\b(reboot|shutdown|poweroff|halt)\b"#, "在生产环境重启/关机"),
        (#"\bkill(all)?\s+-9\b"#, "在生产环境强制终止进程"),
        (#"\bdocker\s+(stop|rm|kill)\b"#, "在生产环境停止/删除容器"),
        (#"\bdrop\s+(table|database)\b"#, "在生产环境删除数据库对象")
    ]

    public static func evaluate(_ command: String, isProduction: Bool) -> DangerVerdict {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)

        for rule in dangerousPatterns where matches(normalized, rule.pattern) {
            return DangerVerdict(isDangerous: true, needsConfirmation: true, reason: rule.reason)
        }

        if isProduction {
            for rule in productionSensitivePatterns where matches(normalized, rule.pattern) {
                return DangerVerdict(isDangerous: false, needsConfirmation: true, reason: rule.reason)
            }
        }

        return DangerVerdict(isDangerous: false, needsConfirmation: false, reason: nil)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
