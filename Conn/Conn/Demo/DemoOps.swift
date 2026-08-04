// 仅 DEBUG 编译：演示/截图/冒烟数据源，不进入发行包。
#if DEBUG
import ConnSSH
import Foundation

/// 演示模式的 Docker / 日志假数据（配合 `MockSSHTransport.dynamicResponder`）。
///
/// 命令识别顺序有讲究：日志探测命令里也含 `journalctl`，故须先判 `__JOURNAL__`
/// 再判 journalctl 跟随；可用性探测 `docker ps -q` 要先于 `docker ps -a`；
/// 卷 / 网络的 `--filter dangling` 变体同样要先于各自泛化的 `ls` 判断
/// （两者都含 `"docker volume/network ls"` 子串，具体分支必须排在前面）。
enum DemoOps {
    static func response(command: String, endpoint: SSHEndpoint) -> MockSSHTransport.CommandResponse? {
        dockerResponse(command) ?? logResponse(command)
    }

    // 拆成容器 / 卷 / 网络 / 镜像四段而不是一个大 if 链：任务 8 补的卷、网络、
    // 磁盘占用、层历史、镜像详情把原本一条函数的圈复杂度顶到 19（阈值 10），
    // 按资源种类拆开是真去重（各段本就管各的命令），不是为了压数字硬拆。
    private static func dockerResponse(_ command: String) -> MockSSHTransport.CommandResponse? {
        composeResponse(command) ?? containerResponse(command) ?? volumeResponse(command)
            ?? networkResponse(command) ?? imageResponse(command)
    }

    private static func composeResponse(_ command: String) -> MockSSHTransport.CommandResponse? {
        if command.contains("docker compose version") {
            return .init(stdout: "Docker Compose version v2.29.2\n")
        }
        if command.contains("docker-compose version") {
            return .init(stdout: "docker-compose version 1.29.2\n")
        }
        if command.contains("compose ls --all --format json") {
            return .init(stdout: composeProjectsJSON)
        }
        if command.contains("label=com.docker.compose.project=") {
            return .init(stdout: composeWebContainersJSON)
        }
        if command.contains("label=com.docker.compose.project") {
            return .init(stdout: composeContainersJSON)
        }
        if command.contains("config --services") {
            return .init(stdout: "api\nworker\ndb\n")
        }
        if command.contains(" logs ") {
            return .init(stdout: composeLog)
        }
        if command.contains(" up -d") || command.contains(" down")
            || command.contains(" restart") {
            return .init(stdout: "Compose operation completed\n")
        }
        return nil
    }

    private static func containerResponse(_ command: String) -> MockSSHTransport.CommandResponse? {
        // 写命令先于列表读取分支；演示不会改写后续的 JSON 夹具，只回显可审计的终态。
        if command.contains("docker run") { return .init(stdout: "c7d8e9f0a1b2\n") }
        if command.contains("docker ps -q") {
            return .init(stdout: "a1b2c3d4e5f6\nb2c3d4e5f6a7\n__EXIT__0")
        }
        // 按卷过滤的引用查询（`docker ps -a --filter volume=<名> --format ...`）不含
        // "--format" 紧跟在 "-a" 后面这个精确子串，与下面的通用 ps -a 判断不冲突，
        // 但仍把它放前面——它更具体，卷详情页「引用容器」段靠它撑起可点演示。
        if command.contains("--filter volume=") { return .init(stdout: containersUsingVolumeJSON) }
        if command.contains("docker ps -a --format") { return .init(stdout: containersJSON) }
        if command.contains("docker stats") { return .init(stdout: statsJSON) }
        if command.contains("docker inspect") { return .init(stdout: inspectJSON) }
        if command.contains("docker logs") { return .init(stdout: containerLog) }
        if let verb = dockerWriteVerb(in: command) { return .init(stdout: "\(verb) ok") }
        return nil
    }

    // 卷：`--filter dangling` 变体与泛化的 `docker volume ls` 都含 "docker volume ls"
    // 子串，带 filter 的必须先判——否则 dangling 查询会拿到整份列表，
    // `parseNameList` 把每一行 JSON 当成一个「名字」，结果没有一个卷名对得上，
    // 反而是没有任何卷显示「未使用」（已用模拟器实测两种顺序验证过，不是没试过的猜测）。
    private static func volumeResponse(_ command: String) -> MockSSHTransport.CommandResponse? {
        if command.contains("docker volume create") { return .init(stdout: "demo-volume\n") }
        if command.contains("docker volume rm") { return .init(stdout: "demo-volume\n") }
        if command.contains("docker volume ls"), command.contains("dangling") {
            return .init(stdout: "old_cache\n")
        }
        if command.contains("docker volume inspect") { return .init(stdout: volumeInspectJSON) }
        if command.contains("docker volume ls") { return .init(stdout: volumesJSON) }
        return nil
    }

    /// 网络同理：dangling 变体先判。
    private static func networkResponse(_ command: String) -> MockSSHTransport.CommandResponse? {
        if command.contains("docker network create") { return .init(stdout: "demo-network\n") }
        if command.contains("docker network rm") { return .init(stdout: "demo-network\n") }
        if command.contains("docker network ls"), command.contains("dangling") {
            if isNetworkNavigationSmoke {
                return .init(stdout: "none\n")
            }
            return .init(stdout: "none\nisolated\n")
        }
        if command.contains("docker network inspect") {
            return .init(stdout: isNetworkNavigationSmoke ? networkInspectWithAttachedContainerJSON : networkInspectJSON)
        }
        if command.contains("docker network ls") { return .init(stdout: networksJSON) }
        return nil
    }

    private static func imageResponse(_ command: String) -> MockSSHTransport.CommandResponse? {
        // 特定的失败 / 中断夹具必须放在常规 pull 前，才能稳定展示 known 与 unknown 终态。
        if command.contains("docker pull"), command.contains("conn-demo/interrupted") {
            return .init(
                streamChunks: [Data("Pulling fs layer\n".utf8)], streamFailure: .channelClosed
            )
        }
        if command.contains("docker pull"), command.contains("conn-demo/failing") {
            return .init(
                streamChunks: [
                    Data("latest: Pulling from conn-demo/failing\n".utf8),
                    Data("error: denied\n".utf8)
                ],
                stderr: "Error response from daemon: pull access denied", exitCode: 1
            )
        }
        if command.contains("docker pull") {
            return .init(streamChunks: [
                Data("1.27: Pulling from library/nginx\n".utf8),
                Data("Digest: sha256:demo\n".utf8),
                Data("Status: Downloaded newer image for nginx:1.27\n".utf8)
            ])
        }
        if command.contains("docker system prune") {
            return .init(stdout: "Deleted Containers:\n\nTotal reclaimed space: 96MB\n")
        }
        if command.contains("docker image prune") { return .init(stdout: "Total reclaimed space: 128MB") }
        if command.contains("docker system df") { return .init(stdout: diskUsageJSON) }
        if command.contains("docker history") { return .init(stdout: historyJSON) }
        // 镜像详情放在 `docker images` 判断之前——两者当前互不为子串（"image" 后有无
        // "s" 之别），无冲突，但先判更具体的分支，能避免以后有人加更宽泛的
        // `docker image` 开头分支时踩雷。
        if command.contains("docker image inspect") { return .init(stdout: imageInspectJSON) }
        if command.contains("docker images") { return .init(stdout: imagesJSON) }
        if command.contains("docker rmi") { return .init(stdout: "Untagged: old:latest\nDeleted: sha256:aaa") }
        return nil
    }

    private static func logResponse(_ command: String) -> MockSSHTransport.CommandResponse? {
        if command.contains("__JOURNAL__") {
            return .init(stdout: "__JOURNAL__\n__FILE__ nginx-error\n__FILE__ syslog\n__FILE__ auth")
        }
        if command.contains("journalctl") { return .init(stdout: journalLog) }
        if command.contains("tail -n"), command.contains("-F") { return .init(stdout: fileLog) }
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

    private static let composeProjectsJSON = """
    [
      {"Name":"conn-web","Status":"running(3)","ConfigFiles":"/srv/conn-web/compose.yml"},
      {"Name":"analytics","Status":"exited(2)","ConfigFiles":"/srv/analytics/docker-compose.yml"}
    ]
    """

    // JSONL fixtures intentionally keep one record per line for the Docker parser.
    // swiftlint:disable line_length
    private static let composeContainersJSON = """
    {"ID":"ca1","Image":"conn-api:latest","Names":"conn-web-api-1","State":"running","Status":"Up 3 days","Ports":"8080/tcp","Labels":"com.docker.compose.project=conn-web,com.docker.compose.project.config_files=/srv/conn-web/compose.yml,com.docker.compose.project.working_dir=/srv/conn-web,com.docker.compose.service=api"}
    {"ID":"cw1","Image":"conn-worker:latest","Names":"conn-web-worker-1","State":"running","Status":"Up 3 days","Ports":"","Labels":"com.docker.compose.project=conn-web,com.docker.compose.project.config_files=/srv/conn-web/compose.yml,com.docker.compose.project.working_dir=/srv/conn-web,com.docker.compose.service=worker"}
    {"ID":"cd1","Image":"postgres:16","Names":"conn-web-db-1","State":"running","Status":"Up 3 days","Ports":"5432/tcp","Labels":"com.docker.compose.project=conn-web,com.docker.compose.project.config_files=/srv/conn-web/compose.yml,com.docker.compose.project.working_dir=/srv/conn-web,com.docker.compose.service=db"}
    {"ID":"an1","Image":"clickhouse:latest","Names":"analytics-db-1","State":"exited","Status":"Exited (0) 2 hours ago","Ports":"","Labels":"com.docker.compose.project=analytics,com.docker.compose.project.config_files=/srv/analytics/docker-compose.yml,com.docker.compose.project.working_dir=/srv/analytics,com.docker.compose.service=db"}
    {"ID":"an2","Image":"analytics-api:latest","Names":"analytics-api-1","State":"exited","Status":"Exited (0) 2 hours ago","Ports":"","Labels":"com.docker.compose.project=analytics,com.docker.compose.project.config_files=/srv/analytics/docker-compose.yml,com.docker.compose.project.working_dir=/srv/analytics,com.docker.compose.service=api"}
    """

    private static let composeWebContainersJSON = """
    {"ID":"ca1","Image":"conn-api:latest","Names":"conn-web-api-1","State":"running","Status":"Up 3 days","Ports":"0.0.0.0:8080->8080/tcp","Labels":"com.docker.compose.project=conn-web,com.docker.compose.service=api"}
    {"ID":"cw1","Image":"conn-worker:latest","Names":"conn-web-worker-1","State":"running","Status":"Up 3 days","Ports":"","Labels":"com.docker.compose.project=conn-web,com.docker.compose.service=worker"}
    {"ID":"cd1","Image":"postgres:16","Names":"conn-web-db-1","State":"running","Status":"Up 3 days","Ports":"5432/tcp","Labels":"com.docker.compose.project=conn-web,com.docker.compose.service=db"}
    """
    // swiftlint:enable line_length

    private static let composeLog = """
    api-1     | 2026-07-31T10:00:00Z server listening on :8080
    worker-1  | 2026-07-31T10:00:01Z queue connected
    db-1      | 2026-07-31T10:00:02Z database system is ready
    """

    private static let containersJSON = """
    {"ID":"a1b2c3d4e5f6","Image":"nginx:1.25","Names":"web-nginx","State":"running","Status":"Up 3 days","Ports":"0.0.0.0:80->80/tcp"}
    {"ID":"b2c3d4e5f6a7","Image":"postgres:16","Names":"pg-main","State":"running","Status":"Up 5 days","Ports":"5432/tcp"}
    {"ID":"c3d4e5f6a7b8","Image":"redis:7-alpine","Names":"redis-cache","State":"running","Status":"Up 5 days","Ports":"6379/tcp"}
    {"ID":"d4e5f6a7b8c9","Image":"backup:latest","Names":"nightly-backup","State":"exited","Status":"Exited (0) 6 hours ago","Ports":""}
    """

    private static let statsJSON = """
    {"ID":"a1b2c3d4e5f6","CPUPerc":"2.30%","MemPerc":"4.10%","MemUsage":"78.5MiB / 2GiB","NetIO":"1.2GB / 340MB","BlockIO":"12MB / 4.1GB"}
    {"ID":"b2c3d4e5f6a7","CPUPerc":"1.05%","MemPerc":"12.40%","MemUsage":"248MiB / 2GiB","NetIO":"820MB / 1.5GB","BlockIO":"0B / 22GB"}
    {"ID":"c3d4e5f6a7b8","CPUPerc":"0.30%","MemPerc":"1.80%","MemUsage":"36MiB / 2GiB","NetIO":"44MB / 88MB","BlockIO":"0B / 512MB"}
    """

    private static let imagesJSON = """
    {"ID":"a1b2c3d4e5f6","Repository":"nginx","Tag":"1.25","Size":"142MB","CreatedSince":"2 weeks ago"}
    {"ID":"b2c3d4e5f6a7","Repository":"postgres","Tag":"16","Size":"438MB","CreatedSince":"3 weeks ago"}
    {"ID":"c3d4e5f6a7b8","Repository":"redis","Tag":"7-alpine","Size":"41MB","CreatedSince":"1 month ago"}
    {"ID":"e5f6a7b8c9d0","Repository":"backup","Tag":"latest","Size":"210MB","CreatedSince":"5 days ago"}
    {"ID":"f6a7b8c9d0e1","Repository":"<none>","Tag":"<none>","Size":"88MB","CreatedSince":"2 months ago"}
    """

    private static let inspectJSON = """
    [{
      "Id": "a1b2c3d4e5f6a1b2c3d4e5f6",
      "Name": "/web-nginx",
      "Created": "2026-07-20T06:13:00.123456789Z",
      "Path": "/docker-entrypoint.sh",
      "Args": ["nginx", "-g", "daemon off;"],
      "RestartCount": 0,
      "State": {"Status": "running", "StartedAt": "2026-07-20T06:13:05Z", "Health": {"Status": "healthy"}},
      "Image": "sha256:abc",
      "Config": {
        "Image": "nginx:1.25",
        "Env": ["PATH=/usr/local/sbin:/usr/local/bin", "NGINX_VERSION=1.25.3", "TZ=Asia/Shanghai"],
        "Cmd": ["nginx", "-g", "daemon off;"]
      },
      "HostConfig": {"RestartPolicy": {"Name": "unless-stopped"}},
      "NetworkSettings": {
        "Ports": {
          "80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "80"}],
          "443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "443"}]
        },
        "Networks": {"bridge": {"IPAddress": "172.18.0.2"}}
      },
      "Mounts": [
        {"Source": "/srv/nginx/conf.d", "Destination": "/etc/nginx/conf.d", "RW": false},
        {"Source": "/srv/www", "Destination": "/usr/share/nginx/html", "RW": true},
        {"Name": "web_assets", "Source": "/var/lib/docker/volumes/web_assets/_data",
         "Destination": "/usr/share/nginx/static", "RW": true}
      ]
    }]
    """

    // MARK: - 卷假数据

    // swiftlint:disable line_length
    /// 4 个卷（1 未使用）——卷列表分段与截图靠这份撑起来。
    private static let volumesJSON = """
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/redis_data/_data","Name":"redis_data","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/web_assets/_data","Name":"web_assets","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/old_cache/_data","Name":"old_cache","Scope":"local","Size":"N/A","Status":"N/A"}
    """
    // swiftlint:enable line_length

    private static let volumeInspectJSON = """
    [{"CreatedAt":"2026-07-01T00:00:00Z","Driver":"local","Labels":{"com.docker.compose.project":"web"},
      "Mountpoint":"/var/lib/docker/volumes/pgdata/_data","Name":"pgdata","Options":{},"Scope":"local"}]
    """

    /// 引用 `pgdata` 的容器——卷详情「引用容器」段与容器详情→卷的交叉跳转靠它演示。
    private static let containersUsingVolumeJSON = """
    {"ID":"b2c3d4e5f6a7","Image":"postgres:16","Names":"pg-main","State":"running","Status":"Up 5 days","Ports":"5432/tcp"}
    """

    // MARK: - 网络假数据

    // swiftlint:disable line_length
    /// 4 张网络：预置 bridge / host / none + 1 张自建（`isolated`，即 dangling 名单里
    /// 那一张，真实 Docker 语义下「没有容器接入」与「被判定未使用」本就是一回事）。
    private static let networksJSON = """
    {"CreatedAt":"2026-01-01 00:00:00","Driver":"bridge","ID":"b1a1b1a1b1a1","IPv6":"false","Internal":"false","Labels":"","Name":"bridge","Scope":"local"}
    {"CreatedAt":"2026-01-01 00:00:00","Driver":"host","ID":"h1a1h1a1h1a1","IPv6":"false","Internal":"false","Labels":"","Name":"host","Scope":"local"}
    {"CreatedAt":"2026-01-01 00:00:00","Driver":"null","ID":"n1a1n1a1n1a1","IPv6":"false","Internal":"false","Labels":"","Name":"none","Scope":"local"}
    {"CreatedAt":"2026-07-05 10:00:00","Driver":"bridge","ID":"f6e5d4c3b2a1","IPv6":"false","Internal":"false","Labels":"","Name":"isolated","Scope":"local"}
    """
    // swiftlint:enable line_length

    private static let networkInspectJSON = """
    [{"Name":"isolated","Id":"f6e5d4c3b2a1c0d9e8f7a6b5c4d3e2f1","Scope":"local","Driver":"bridge","Internal":false,
      "IPAM":{"Config":[{"Subnet":"172.25.0.0/16","Gateway":"172.25.0.1"}]},
      "Containers":{}}]
    """

    /// 仅供 iPhone 冒烟验证网络详情 → 容器详情：network inspect 给完整 ID，
    /// docker ps 给 12 位短 ID，正好覆盖两种 ID 格式间的跳转。
    private static let networkInspectWithAttachedContainerJSON = """
    [{"Name":"isolated","Id":"f6e5d4c3b2a1c0d9e8f7a6b5c4d3e2f1","Scope":"local","Driver":"bridge","Internal":false,
      "IPAM":{"Config":[{"Subnet":"172.25.0.0/16","Gateway":"172.25.0.1"}]},
      "Containers":{"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6":{"Name":"web-nginx","IPv4Address":"172.25.0.2/16"}}}]
    """

    private static var isNetworkNavigationSmoke: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CONN_SMOKE_NETWORK_DETAIL_ROUTE"] != nil
            || environment["CONN_SMOKE_NETWORK_CONTAINER_ROUTE"] != nil
    }

    // MARK: - 磁盘占用 / 镜像详情假数据

    private static let diskUsageJSON = """
    {"Images":[{"ID":"sha256:a1b2c3d4e5f6a7b8","Repository":"nginx","Tag":"1.25","Size":"142MB"},
               {"ID":"sha256:bbb444555666","Repository":"postgres","Tag":"16","Size":"438MB"}],
     "Volumes":[{"Name":"pgdata","Size":"1.2GB","Links":1},{"Name":"redis_data","Size":"64MB","Links":1},
                {"Name":"web_assets","Size":"48MB","Links":1},{"Name":"old_cache","Size":"310MB","Links":0}],
     "Containers":[],"BuildCache":[]}
    """

    // swiftlint:disable line_length
    /// 4 层历史——镜像详情「层历史」段靠它撑起截图/预览。
    private static let historyJSON = """
    {"Comment":"","CreatedAt":"2026-07-20T06:00:00Z","CreatedBy":"/bin/sh -c #(nop) CMD [\\"nginx\\" \\"-g\\" \\"daemon off;\\"]","CreatedSince":"9 days ago","ID":"a1b2c3","Size":"0B"}
    {"Comment":"","CreatedAt":"2026-07-19T04:00:00Z","CreatedBy":"/bin/sh -c #(nop) EXPOSE 80 443","CreatedSince":"10 days ago","ID":"<missing>","Size":"0B"}
    {"Comment":"","CreatedAt":"2026-07-18T02:00:00Z","CreatedBy":"/bin/sh -c apt-get update \\u0026\\u0026 apt-get install -y curl","CreatedSince":"11 days ago","ID":"<missing>","Size":"58.2MB"}
    {"Comment":"","CreatedAt":"2026-07-01T00:00:00Z","CreatedBy":"/bin/sh -c #(nop) ADD file:abc in /","CreatedSince":"4 weeks ago","ID":"<missing>","Size":"83.7MB"}
    """
    // swiftlint:enable line_length

    private static let imageInspectJSON = """
    [{"Id":"sha256:a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
      "RepoTags":["nginx:1.25"],
      "RepoDigests":["nginx@sha256:deadbeefcafe"],
      "Created":"2026-07-20T06:00:00.000Z",
      "Size":142000000,
      "Architecture":"arm64","Os":"linux",
      "Config":{"Entrypoint":["/docker-entrypoint.sh"],"Cmd":["nginx","-g","daemon off;"],
                "Env":["PATH=/usr/bin","NGINX_VERSION=1.25.3"],"Labels":{"maintainer":"nginx"}}}]
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
#endif
