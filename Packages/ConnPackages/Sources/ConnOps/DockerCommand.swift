import Foundation

/// Docker CLI 命令构造（方案 §4.4：全部经 exec 走 docker CLI，不依赖 API socket）。
///
/// `sudo` 为真时前缀 `sudo -n `——用户不在 docker 组但有免密 sudo 时的回退。
public enum DockerCommand {
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
}
