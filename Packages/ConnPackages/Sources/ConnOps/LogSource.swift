import Foundation

/// 一个日志源（方案 §4.4 日志中心）。
public struct LogSource: Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// journalctl，unit 为空表示整机日志。
        case journal(unit: String)
        /// 普通日志文件。
        case file(path: String)
        /// macOS Unified Logging；predicate 为空时跟随整机日志。
        case unified(predicate: String?)
        /// Docker 容器日志（复用 docker logs 通道）。
        case container(
            id: String,
            name: String,
            runtime: DockerRuntimeContext
        )
        /// Docker Compose 项目或单个服务日志。
        case compose(
            project: DockerComposeProject,
            dialect: DockerComposeDialect,
            service: String?,
            runtime: DockerRuntimeContext
        )
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: Kind

    public init(id: String, title: String, subtitle: String, kind: Kind) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }

    /// 跟随命令（execStream 用）。合并 stderr；`sudo` 前缀用于受限文件/journal。
    public func followCommand(tail: Int = 300, sudo: Bool = false) -> String {
        let prefix = sudo ? "sudo -n " : ""
        switch kind {
        case let .journal(unit):
            let scope = unit.isEmpty ? "" : "-u \(unit) "
            return prefix + "journalctl \(scope)-n \(tail) -f --no-pager -o short-iso 2>&1"
        case let .file(path):
            return prefix + "tail -n \(tail) -F \(Self.shellQuote(path)) 2>&1"
        case let .unified(predicate):
            let filter = predicate.map { " --predicate \(Self.shellQuote($0))" } ?? ""
            return prefix + "/usr/bin/log stream --style syslog\(filter) 2>&1"
        case let .container(id, _, runtime):
            return DockerCommand.logs(
                id: id,
                tail: tail,
                runtime: runtime.withSudo(runtime.sudo || sudo)
            )
        case let .compose(project, dialect, service, runtime):
            return DockerCommand.composeLogs(
                project,
                service: service,
                tail: tail,
                dialect: dialect,
                runtime: runtime.withSudo(runtime.sudo || sudo)
            ) + " 2>&1"
        }
    }

    /// POSIX shell 单引号包裹；支持文件管理器传入含空格或单引号的任意路径。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 内置日志源预设与探测（存在性探测后才展示，避免罗列不存在的源）。
public enum LogPresets {
    /// 候选文件源（覆盖 Debian/Ubuntu 与 CentOS 常见路径）。
    ///
    /// 计算属性而非 `static let`：标题经 `L()` 本地化，App 内切换语言后重新求值即刷新。
    public static var fileCandidates: [LogSource] {
        [
            .init(id: "nginx-error", title: L("Nginx 错误"), subtitle: "/var/log/nginx/error.log",
                  kind: .file(path: "/var/log/nginx/error.log")),
            .init(id: "nginx-access", title: L("Nginx 访问"), subtitle: "/var/log/nginx/access.log",
                  kind: .file(path: "/var/log/nginx/access.log")),
            .init(id: "mysql-error", title: L("MySQL 错误"), subtitle: "/var/log/mysql/error.log",
                  kind: .file(path: "/var/log/mysql/error.log")),
            .init(id: "redis", title: "Redis", subtitle: "/var/log/redis/redis-server.log",
                  kind: .file(path: "/var/log/redis/redis-server.log")),
            .init(id: "syslog", title: "Syslog", subtitle: "/var/log/syslog",
                  kind: .file(path: "/var/log/syslog")),
            .init(id: "messages", title: "Messages", subtitle: "/var/log/messages",
                  kind: .file(path: "/var/log/messages")),
            .init(id: "auth", title: L("认证日志"), subtitle: "/var/log/auth.log",
                  kind: .file(path: "/var/log/auth.log"))
        ]
    }

    /// 整机 journal 源（journalctl 存在时可用）。
    public static var systemJournal: LogSource {
        LogSource(
            id: "journal-system", title: L("系统日志"), subtitle: L("journalctl（全部单元）"),
            kind: .journal(unit: "")
        )
    }

    /// 一趟探测命令：journalctl 是否存在 + 每个候选文件是否存在。
    public static var discoveryCommand: String {
        var lines = ["command -v journalctl >/dev/null 2>&1 && echo __JOURNAL__"]
        for candidate in fileCandidates {
            if case let .file(path) = candidate.kind {
                lines.append("test -f \(path) && echo \"__FILE__ \(candidate.id)\"")
            }
        }
        // 探测的退出码不能取决于最后一个候选文件是否存在；调用方会用退出码区分
        // “没有这些日志源”与“整条发现命令执行失败”。
        lines.append("true")
        return lines.joined(separator: "; ")
    }

    /// 解析探测输出，返回该机上**实际存在**的日志源（journal 优先）。
    /// 无 journalctl（非 systemd 系统）时自动降级为只含文件源（方案 §4.4 验收）。
    public static func parseDiscovery(_ output: String) -> [LogSource] {
        let lines = Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var sources: [LogSource] = []
        if lines.contains("__JOURNAL__") {
            sources.append(systemJournal)
        }
        let presentIDs = Set(
            lines
                .filter { $0.hasPrefix("__FILE__ ") }
                .map { $0.replacingOccurrences(of: "__FILE__ ", with: "") }
        )
        sources.append(contentsOf: fileCandidates.filter { presentIDs.contains($0.id) })
        return sources
    }
}
