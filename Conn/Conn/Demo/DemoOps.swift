import ConnSSH
import Foundation

/// 演示模式的 Docker / 日志假数据（配合 `MockSSHTransport.dynamicResponder`）。
///
/// 命令识别顺序有讲究：日志探测命令里也含 `journalctl`，故须先判 `__JOURNAL__`
/// 再判 journalctl 跟随；可用性探测 `docker ps -q` 要先于 `docker ps -a`。
enum DemoOps {
    static func response(command: String, endpoint: SSHEndpoint) -> MockSSHTransport.CommandResponse? {
        if command.contains("docker ps -q") {
            return .init(stdout: "a1b2c3d4e5f6\nb2c3d4e5f6a7\n__EXIT__0")
        }
        if command.contains("docker ps -a --format") {
            return .init(stdout: containersJSON)
        }
        if command.contains("docker stats") {
            return .init(stdout: statsJSON)
        }
        if command.contains("docker logs") {
            return .init(stdout: containerLog)
        }
        if let verb = dockerWriteVerb(in: command) {
            return .init(stdout: "\(verb) ok")
        }
        if command.contains("__JOURNAL__") {
            return .init(stdout: "__JOURNAL__\n__FILE__ nginx-error\n__FILE__ syslog\n__FILE__ auth")
        }
        if command.contains("journalctl") {
            return .init(stdout: journalLog)
        }
        if command.contains("tail -n"), command.contains("-F") {
            return .init(stdout: fileLog)
        }
        return nil
    }

    private static func dockerWriteVerb(in command: String) -> String? {
        for verb in ["docker start", "docker stop", "docker restart", "docker rm"]
            where command.contains(verb) {
            return verb
        }
        return nil
    }

    // MARK: - Docker 假数据

    private static let containersJSON = """
    {"ID":"a1b2c3d4e5f6","Image":"nginx:1.25","Names":"web-nginx","State":"running","Status":"Up 3 days","Ports":"0.0.0.0:80->80/tcp"}
    {"ID":"b2c3d4e5f6a7","Image":"postgres:16","Names":"pg-main","State":"running","Status":"Up 5 days","Ports":"5432/tcp"}
    {"ID":"c3d4e5f6a7b8","Image":"redis:7-alpine","Names":"redis-cache","State":"running","Status":"Up 5 days","Ports":"6379/tcp"}
    {"ID":"d4e5f6a7b8c9","Image":"backup:latest","Names":"nightly-backup","State":"exited","Status":"Exited (0) 6 hours ago","Ports":""}
    """

    private static let statsJSON = """
    {"ID":"a1b2c3d4e5f6","CPUPerc":"2.30%","MemPerc":"4.10%","MemUsage":"78.5MiB / 2GiB","Name":"web-nginx"}
    {"ID":"b2c3d4e5f6a7","CPUPerc":"1.05%","MemPerc":"12.40%","MemUsage":"248MiB / 2GiB","Name":"pg-main"}
    {"ID":"c3d4e5f6a7b8","CPUPerc":"0.30%","MemPerc":"1.80%","MemUsage":"36MiB / 2GiB","Name":"redis-cache"}
    """

    // MARK: - 日志假数据

    private static let containerLog = lines(count: 40, prefix: "") { index in
        switch index % 12 {
        case 3: "[error] upstream timed out (110: Connection timed out) while reading response"
        case 8: "[warn] worker_connections are not enough, reusing connections"
        default: "172.18.0.1 - - [23/Jul/2026] \"GET /api/v1/health HTTP/1.1\" 200 15 \"-\" \"curl/8.4\""
        }
    }

    private static let journalLog = lines(count: 40, prefix: "2026-07-23T09:1") { index in
        switch index % 10 {
        case 5: "sshd[421]: Failed password for invalid user admin from 203.0.113.9 port 51824"
        case 9: "systemd[1]: WARNING: Started daily apt upgrade check."
        default: "systemd[1]: Started Session c\(index) of user deploy."
        }
    }

    private static let fileLog = lines(count: 40, prefix: "") { index in
        switch index % 9 {
        case 4: "2026/07/23 09:14:02 [error] 812#812: *1024 open() \"/var/www/x\" failed (2: No such file)"
        case 7: "2026/07/23 09:14:05 [warn] 812#812: conflicting server name \"_\" on 0.0.0.0:80"
        default: "2026/07/23 09:14:0\(index % 10) [info] 812#812: signal process started"
        }
    }

    /// 生成 `count` 行，`body(index)` 决定每行内容，`prefix` 拼在行首。
    private static func lines(count: Int, prefix: String, body: (Int) -> String) -> String {
        (1 ... count).map { "\(prefix)\(body($0))" }.joined(separator: "\n")
    }
}
