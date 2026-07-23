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
