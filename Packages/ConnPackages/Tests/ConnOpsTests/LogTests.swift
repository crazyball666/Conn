import ConnKit
import Testing
@testable import ConnOps

struct LogHighlighterTests {
    @Test("error/fail/panic/fatal → error")
    func errorLevel() {
        #expect(LogHighlighter.level(for: "nginx: [error] connect() failed") == .error)
        #expect(LogHighlighter.level(for: "task FAILED with code 1") == .error)
        #expect(LogHighlighter.level(for: "kernel panic - not syncing") == .error)
        #expect(LogHighlighter.level(for: "FATAL: out of memory") == .error)
    }

    @Test("warn/deprecated → warn")
    func warnLevel() {
        #expect(LogHighlighter.level(for: "[warn] worker process exited") == .warn)
        #expect(LogHighlighter.level(for: "this option is Deprecated") == .warn)
    }

    @Test("普通行 → normal")
    func normalLevel() {
        #expect(LogHighlighter.level(for: "192.168.1.1 GET /index.html 200") == .normal)
    }

    @Test("error 优先于 warn")
    func errorBeatsWarn() {
        #expect(LogHighlighter.level(for: "warning: fatal error ahead") == .error)
    }

    @Test("LogLine 构造即定级")
    func logLineLevels() {
        #expect(LogLine(id: 1, text: "all good").level == .normal)
        #expect(LogLine(id: 2, text: "ERROR boom").level == .error)
    }
}

struct LogSourceTests {
    private let runtime = DockerRuntimeContext(executable: "docker", sudo: false)

    @Test("各类源的跟随命令")
    func followCommands() {
        let journal = LogSource(id: "j", title: "", subtitle: "", kind: .journal(unit: "nginx"))
        #expect(journal.followCommand() == "journalctl -u nginx -n 300 -f --no-pager -o short-iso 2>&1")

        let allJournal = LogSource(id: "j2", title: "", subtitle: "", kind: .journal(unit: ""))
        #expect(allJournal.followCommand() == "journalctl -n 300 -f --no-pager -o short-iso 2>&1")

        let file = LogSource(id: "f", title: "", subtitle: "", kind: .file(path: "/var/log/syslog"))
        #expect(file.followCommand() == "tail -n 300 -F '/var/log/syslog' 2>&1")

        let container = LogSource(
            id: "c",
            title: "",
            subtitle: "",
            kind: .container(id: "abc123", name: "web", runtime: runtime)
        )
        #expect(container.followCommand() == "docker logs -f --tail 300 abc123 2>&1")

        let unified = LogSource(
            id: "unified", title: "", subtitle: "", kind: .unified(predicate: nil)
        )
        #expect(unified.followCommand() == "/usr/bin/log stream --style syslog 2>&1")

        let filteredUnified = LogSource(
            id: "unified-filtered", title: "", subtitle: "",
            kind: .unified(predicate: "process == 'backup agent'")
        )
        #expect(
            filteredUnified.followCommand()
                == #"/usr/bin/log stream --style syslog --predicate 'process == '\''backup agent'\''' 2>&1"#
        )
    }

    @Test("容器日志沿用探测到的 Docker 路径")
    func containerLogsUseRuntimeContext() {
        let source = LogSource(
            id: "c",
            title: "",
            subtitle: "",
            kind: .container(
                id: "abc123",
                name: "web",
                runtime: DockerRuntimeContext(
                    executable: "/Applications/Docker.app/Contents/Resources/bin/docker",
                    sudo: false
                )
            )
        )

        #expect(
            source.followCommand()
                == "'/Applications/Docker.app/Contents/Resources/bin/docker' logs -f --tail 300 abc123 2>&1"
        )
    }

    @Test("任意文件路径会安全转义")
    func arbitraryFilePathIsQuoted() {
        let file = LogSource(
            id: "f",
            title: "",
            subtitle: "",
            kind: .file(path: "/var/log/app logs/o'hare.log")
        )
        #expect(file.followCommand() == "tail -n 300 -F '/var/log/app logs/o'\\''hare.log' 2>&1")
    }

    @Test("sudo 前缀")
    func sudoPrefix() {
        let file = LogSource(id: "f", title: "", subtitle: "", kind: .file(path: "/var/log/auth.log"))
        #expect(file.followCommand(sudo: true) == "sudo -n tail -n 300 -F '/var/log/auth.log' 2>&1")
    }

    @Test("Compose 项目和服务日志使用项目配置并安全转义")
    func composeFollowCommands() {
        let project = DockerComposeProject(
            name: "web app", state: .running,
            configFiles: ["/srv/web app/compose.yml"], projectDirectory: "/srv/web app",
            source: .manual
        )
        let projectLog = LogSource(
            id: "compose-web", title: "", subtitle: "",
            kind: .compose(project: project, dialect: .v2, service: nil, runtime: runtime)
        )
        let serviceLog = LogSource(
            id: "compose-web-api", title: "", subtitle: "",
            kind: .compose(
                project: project,
                dialect: .v1,
                service: "api service",
                runtime: runtime
            )
        )

        #expect(
            projectLog.followCommand(sudo: true)
                == "sudo -n docker compose -f '/srv/web app/compose.yml' --project-directory '/srv/web app' -p 'web app' logs --no-color --tail 300 -f 2>&1"
        )
        #expect(
            serviceLog.followCommand(tail: 50)
                == "docker-compose -f '/srv/web app/compose.yml' --project-directory '/srv/web app' -p 'web app' logs --no-color --tail 50 -f 'api service' 2>&1"
        )
    }

    @Test("探测解析：有 journalctl → 含系统源 + 存在的文件源")
    func discoveryWithJournal() {
        let output = "__JOURNAL__\n__FILE__ nginx-error\n__FILE__ syslog"
        let sources = LogPresets.parseDiscovery(output)
        #expect(sources.first?.id == "journal-system")
        #expect(sources.contains { $0.id == "nginx-error" })
        #expect(sources.contains { $0.id == "syslog" })
        #expect(!sources.contains { $0.id == "mysql-error" }) // 未探测到
    }

    @Test("无 journalctl（非 systemd）→ 降级只留文件源")
    func discoveryDegradesWithoutJournal() {
        let output = "__FILE__ messages"
        let sources = LogPresets.parseDiscovery(output)
        #expect(!sources.contains { $0.id == "journal-system" })
        #expect(sources.map(\.id) == ["messages"])
    }

    @Test("Linux provider 保留 journal 与文件探测")
    func linuxProviderKeepsExistingBehavior() {
        let provider = LogProviderRegistry.provider(for: .linux)

        #expect(provider?.platform == .linux)
        #expect(provider?.discoveryCommand.contains("journalctl") == true)
        #expect(provider?.discoveryCommand.hasSuffix("; true") == true)
        #expect(provider?.parseDiscovery("__FILE__ messages").map(\.id) == ["messages"])
    }

    @Test("Darwin provider 探测 Unified Logging 与 system.log")
    func darwinDiscovery() throws {
        let provider = try #require(LogProviderRegistry.provider(for: .macOS))

        #expect(provider.discoveryCommand.contains("/usr/bin/log"))
        #expect(provider.discoveryCommand.contains("/var/log/system.log"))
        #expect(!provider.discoveryCommand.contains("journalctl"))
        #expect(provider.discoveryCommand.hasSuffix("; true"))

        let sources = provider.parseDiscovery("__UNIFIED_LOG__\n__FILE__ system-log")
        #expect(sources.map(\.id) == ["darwin-unified", "system-log"])
        guard case .unified(predicate: nil) = sources[0].kind else {
            Issue.record("expected unified log source")
            return
        }
        #expect(sources[1].kind == .file(path: "/var/log/system.log"))
        #expect(provider.capabilityState(for: "__FILE__ system-log") != .supported)
    }

    @Test("未支持平台没有日志 provider")
    func unsupportedPlatforms() {
        #expect(LogProviderRegistry.provider(for: .windows) == nil)
        #expect(LogProviderRegistry.provider(for: .unknown) == nil)
    }
}
