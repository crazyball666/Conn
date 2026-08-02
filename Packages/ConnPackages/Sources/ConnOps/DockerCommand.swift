import Foundation

/// Docker CLI 命令构造（方案 §4.4：全部经 exec 走 docker CLI，不依赖 API socket）。
///
/// `sudo` 为真时前缀 `sudo -n `——用户不在 docker 组但有免密 sudo 时的回退。
public enum DockerCommand {
    // MARK: - 第三期 Compose

    public static func composeVersion(_ dialect: DockerComposeDialect, sudo: Bool) -> String {
        prefix(sudo) + dialect.command + " version"
    }

    public static func composeProjects(sudo: Bool) -> String {
        prefix(sudo) + "docker compose ls --all --format json"
    }

    public static func composeContainers(projectName: String? = nil, sudo: Bool) -> String {
        let label = projectName.map { "label=com.docker.compose.project=\($0)" }
            ?? "label=com.docker.compose.project"
        return prefix(sudo)
            + "docker ps -a --filter \(ShellArgument.quote(label)) --format '{{json .}}'"
    }

    public static func composeUp(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        sudo: Bool
    ) -> String {
        composeBase(project, dialect: dialect, sudo: sudo) + " up -d"
    }

    public static func composeDown(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        sudo: Bool
    ) -> String {
        composeBase(project, dialect: dialect, sudo: sudo) + " down"
    }

    public static func composeRestart(
        _ project: DockerComposeProject,
        service: String? = nil,
        dialect: DockerComposeDialect,
        sudo: Bool
    ) -> String {
        let target = service.map { " " + ShellArgument.quote($0) } ?? ""
        return composeBase(project, dialect: dialect, sudo: sudo) + " restart" + target
    }

    public static func composeLogs(
        _ project: DockerComposeProject,
        service: String?,
        tail: Int = 300,
        dialect: DockerComposeDialect,
        sudo: Bool
    ) -> String {
        let target = service.map { " " + ShellArgument.quote($0) } ?? ""
        return composeBase(project, dialect: dialect, sudo: sudo)
            + " logs --no-color --tail \(tail) -f" + target
    }

    public static func composeConfigServices(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        sudo: Bool
    ) -> String {
        composeBase(project, dialect: dialect, sudo: sudo) + " config --services"
    }

    // MARK: - 第二期写操作

    /// 拉取一个镜像引用。
    public static func pull(reference: String, sudo: Bool) -> String {
        prefix(sudo) + "docker pull \(ShellArgument.quote(reference))"
    }

    /// 根据本地已校验的草稿构造 `docker run`。动态参数均是独立 shell argv。
    public static func run(_ draft: DockerRunDraft, sudo: Bool) -> String {
        var arguments: [String] = []
        if let name = draft.name {
            arguments += ["--name", ShellArgument.quote(name)]
        }
        if draft.detached {
            arguments.append("--detach")
        }
        if let network = draft.network {
            arguments += ["--network", ShellArgument.quote(network)]
        }
        if let hostname = draft.hostname, !hostname.isEmpty {
            arguments += ["--hostname", ShellArgument.quote(hostname)]
        }
        if let user = draft.user, !user.isEmpty {
            arguments += ["--user", ShellArgument.quote(user)]
        }
        if let workdir = draft.workdir, !workdir.isEmpty {
            arguments += ["--workdir", ShellArgument.quote(workdir)]
        }
        for port in draft.ports {
            arguments += ["--publish", ShellArgument.quote(port.dockerValue)]
        }
        for entry in draft.environment {
            arguments += ["--env", ShellArgument.quote(entry.dockerValue)]
        }
        for mount in draft.mounts {
            arguments += ["--mount", ShellArgument.quote(mount.dockerValue)]
        }
        if draft.restartPolicy != .no {
            arguments += ["--restart", ShellArgument.quote(draft.restartPolicy.rawValue)]
        }
        if draft.readOnlyRoot {
            arguments.append("--read-only")
        }
        arguments += draft.otherOptionTokens.map(ShellArgument.quote)
        arguments.append(ShellArgument.quote(draft.image))
        arguments += draft.commandTokens.map(ShellArgument.quote)
        return prefix(sudo) + "docker run \(arguments.joined(separator: " "))"
    }

    /// 创建 Docker 卷。
    public static func createVolume(_ draft: DockerVolumeDraft, sudo: Bool) -> String {
        let arguments = ([draft.driver] + draft.otherOptionTokens + [draft.name])
            .map(ShellArgument.quote)
            .joined(separator: " ")
        return prefix(sudo) + "docker volume create --driver \(arguments)"
    }

    /// 删除 Docker 卷。
    public static func removeVolume(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker volume rm \(ShellArgument.quote(name))"
    }

    /// 创建 Docker 网络。
    public static func createNetwork(_ draft: DockerNetworkDraft, sudo: Bool) -> String {
        var arguments: [String] = []
        if draft.isInternal {
            arguments.append("--internal")
        }
        if draft.isAttachable {
            arguments.append("--attachable")
        }
        arguments += draft.otherOptionTokens.map(ShellArgument.quote)
        arguments.append(ShellArgument.quote(draft.name))
        return prefix(sudo) + "docker network create --driver \(ShellArgument.quote(draft.driver)) \(arguments.joined(separator: " "))"
    }

    /// 删除 Docker 网络。
    public static func removeNetwork(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker network rm \(ShellArgument.quote(name))"
    }

    /// 清理未使用 Docker 资源；`-f` 始终存在，避免远端交互确认。
    public static func systemPrune(_ options: DockerSystemPruneOptions, sudo: Bool) -> String {
        var command = prefix(sudo) + "docker system prune -f"
        if options.allUnusedImages {
            command += " -a"
        }
        if options.includeVolumes {
            command += " --volumes"
        }
        return command
    }

    /// 全部容器（含已停），JSON 每行一个。
    public static func list(sudo: Bool) -> String {
        prefix(sudo) + "docker ps -a --format '{{json .}}'"
    }

    /// 运行中容器的资源占用快照，JSON 每行一个。
    public static func stats(sudo: Bool) -> String {
        prefix(sudo) + "docker stats --no-stream --format '{{json .}}'"
    }

    /// 对容器执行写操作。
    public static func action(_ action: ContainerAction, id: String, sudo: Bool) -> String {
        prefix(sudo) + "docker \(action.verb) \(id)"
    }

    /// 容器详情（`docker inspect`，返回 JSON 数组）。
    public static func inspect(id: String, sudo: Bool) -> String {
        prefix(sudo) + "docker inspect \(id)"
    }

    /// 进入容器控制台：在 PTY 里 exec，优先 bash 回退 sh（Alpine 等仅 sh）。
    public static func console(id: String, sudo: Bool) -> String {
        prefix(sudo) + "docker exec -it \(id) sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"
    }

    /// 全部镜像，JSON 每行一个。
    public static func images(sudo: Bool) -> String {
        prefix(sudo) + "docker images --format '{{json .}}'"
    }

    /// 删除镜像（`reference` 为 `repo:tag` 或镜像 ID）。
    public static func removeImage(reference: String, sudo: Bool) -> String {
        prefix(sudo) + "docker rmi \(reference)"
    }

    /// 清理悬空镜像（无 tag）。
    public static func pruneImages(sudo: Bool) -> String {
        prefix(sudo) + "docker image prune -f"
    }

    /// 镜像详情（JSON 数组）。
    public static func imageInspect(reference: String, sudo: Bool) -> String {
        prefix(sudo) + "docker image inspect \(reference)"
    }

    /// 镜像层历史，JSON 每行一个。`--no-trunc` 不加：指令过长在手机上没法读，
    /// docker 默认的截断正合适。
    public static func imageHistory(reference: String, sudo: Bool) -> String {
        prefix(sudo) + "docker history \(reference) --format '{{json .}}'"
    }

    /// 磁盘占用明细。**这条在镜像/卷多的主机上要数秒**，调用方须单独异步取，
    /// 不可与列表串在一起。`--format json` 在较老 docker 上不支持，
    /// 那时输出是表格文本，解析器会返回 nil，上层显示「—」。
    public static func diskUsage(sudo: Bool) -> String {
        prefix(sudo) + "docker system df -v --format '{{json .}}'"
    }

    // MARK: - 卷

    /// 全部卷，JSON 每行一个。
    public static func volumes(sudo: Bool) -> String {
        prefix(sudo) + "docker volume ls --format '{{json .}}'"
    }

    /// 无任何容器引用的卷名。对卷而言 `dangling` 的定义就是「没被引用」，
    /// 与我们要表达的「未使用」一致，故直接用它而不在客户端比对容器列表。
    public static func danglingVolumes(sudo: Bool) -> String {
        prefix(sudo) + "docker volume ls --filter dangling=true -q"
    }

    /// 卷详情（JSON 数组）。
    public static func volumeInspect(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker volume inspect \(name)"
    }

    /// 引用某个卷的容器（含已停止的——它引用着就删不掉该卷）。
    public static func containersUsingVolume(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker ps -a --filter volume=\(name) --format '{{json .}}'"
    }

    // MARK: - 网络

    /// 全部网络，JSON 每行一个。
    public static func networks(sudo: Bool) -> String {
        prefix(sudo) + "docker network ls --format '{{json .}}'"
    }

    /// 无容器接入的网络名。**注意它会包含预置的 bridge / host / none**，
    /// 打徽标前须用 `NetworkInfo.isPredefined` 滤掉。
    ///
    /// 用 `--format '{{.Name}}'` 而非 `-q`：`-q` 给的是网络 ID，而列表项与
    /// inspect 都以名字为键，取 ID 还要再映射一次。
    public static func danglingNetworks(sudo: Bool) -> String {
        prefix(sudo) + "docker network ls --filter dangling=true --format '{{.Name}}'"
    }

    /// 网络详情（JSON 数组）。
    public static func networkInspect(name: String, sudo: Bool) -> String {
        prefix(sudo) + "docker network inspect \(name)"
    }

    /// 跟随容器日志（execStream 用）。合并 stderr。
    public static func logs(id: String, tail: Int = 200, sudo: Bool) -> String {
        prefix(sudo) + "docker logs -f --tail \(tail) \(id) 2>&1"
    }

    /// 可用性探测：跑一次 `docker ps -q`，把退出码回显成 `__EXIT__<n>` 便于解析。
    /// stderr 合并进 stdout 以便读到「permission denied / not found」。
    public static func availabilityProbe(sudo: Bool) -> String {
        prefix(sudo) + "docker ps -q 2>&1; echo __EXIT__$?"
    }

    private static func prefix(_ sudo: Bool) -> String {
        sudo ? "sudo -n " : ""
    }

    private static func composeBase(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        sudo: Bool
    ) -> String {
        var arguments = project.configFiles.flatMap { ["-f", ShellArgument.quote($0)] }
        arguments += ["--project-directory", ShellArgument.quote(project.projectDirectory)]
        arguments += ["-p", ShellArgument.quote(project.name)]
        return prefix(sudo) + dialect.command + " " + arguments.joined(separator: " ")
    }
}
