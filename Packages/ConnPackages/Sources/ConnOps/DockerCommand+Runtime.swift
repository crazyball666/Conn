import Foundation

/// 基于探测所得 `DockerRuntimeContext` 的命令入口。
///
/// 对外只暴露 `runtime:` 版本，确保 Docker Desktop App bundle 等非 PATH 路径
/// 不会在探测后丢失；`sudo:` 构造器仅作为模块内部的 POSIX 命令模板。
public extension DockerCommand {
    static func composeVersion(
        _ dialect: DockerComposeDialect,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(composeVersion(dialect, sudo: false), runtime: runtime)
    }

    static func composeProjects(runtime: DockerRuntimeContext) -> String {
        contextualize(composeProjects(sudo: false), runtime: runtime)
    }

    static func composeContainers(
        projectName: String? = nil,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(composeContainers(projectName: projectName, sudo: false), runtime: runtime)
    }

    static func composeUp(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(composeUp(project, dialect: dialect, sudo: false), runtime: runtime)
    }

    static func composeDown(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(composeDown(project, dialect: dialect, sudo: false), runtime: runtime)
    }

    static func composeRestart(
        _ project: DockerComposeProject,
        service: String? = nil,
        dialect: DockerComposeDialect,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(
            composeRestart(project, service: service, dialect: dialect, sudo: false),
            runtime: runtime
        )
    }

    static func composeLogs(
        _ project: DockerComposeProject,
        service: String?,
        tail: Int = 300,
        dialect: DockerComposeDialect,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(
            composeLogs(project, service: service, tail: tail, dialect: dialect, sudo: false),
            runtime: runtime
        )
    }

    static func composeConfigServices(
        _ project: DockerComposeProject,
        dialect: DockerComposeDialect,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(
            composeConfigServices(project, dialect: dialect, sudo: false),
            runtime: runtime
        )
    }

    static func pull(reference: String, runtime: DockerRuntimeContext) -> String {
        contextualize(pull(reference: reference, sudo: false), runtime: runtime)
    }

    static func run(_ draft: DockerRunDraft, runtime: DockerRuntimeContext) -> String {
        contextualize(run(draft, sudo: false), runtime: runtime)
    }

    static func createVolume(_ draft: DockerVolumeDraft, runtime: DockerRuntimeContext) -> String {
        contextualize(createVolume(draft, sudo: false), runtime: runtime)
    }

    static func removeVolume(name: String, runtime: DockerRuntimeContext) -> String {
        contextualize(removeVolume(name: name, sudo: false), runtime: runtime)
    }

    static func createNetwork(_ draft: DockerNetworkDraft, runtime: DockerRuntimeContext) -> String {
        contextualize(createNetwork(draft, sudo: false), runtime: runtime)
    }

    static func removeNetwork(name: String, runtime: DockerRuntimeContext) -> String {
        contextualize(removeNetwork(name: name, sudo: false), runtime: runtime)
    }

    static func systemPrune(
        _ options: DockerSystemPruneOptions,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(systemPrune(options, sudo: false), runtime: runtime)
    }

    static func list(runtime: DockerRuntimeContext) -> String {
        contextualize(list(sudo: false), runtime: runtime)
    }

    static func stats(runtime: DockerRuntimeContext) -> String {
        contextualize(stats(sudo: false), runtime: runtime)
    }

    static func action(
        _ action: ContainerAction,
        id: String,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(self.action(action, id: id, sudo: false), runtime: runtime)
    }

    static func inspect(id: String, runtime: DockerRuntimeContext) -> String {
        contextualize(inspect(id: id, sudo: false), runtime: runtime)
    }

    static func console(id: String, runtime: DockerRuntimeContext) -> String {
        contextualize(console(id: id, sudo: false), runtime: runtime)
    }

    static func images(runtime: DockerRuntimeContext) -> String {
        contextualize(images(sudo: false), runtime: runtime)
    }

    static func removeImage(reference: String, runtime: DockerRuntimeContext) -> String {
        contextualize(removeImage(reference: reference, sudo: false), runtime: runtime)
    }

    static func pruneImages(runtime: DockerRuntimeContext) -> String {
        contextualize(pruneImages(sudo: false), runtime: runtime)
    }

    static func imageInspect(reference: String, runtime: DockerRuntimeContext) -> String {
        contextualize(imageInspect(reference: reference, sudo: false), runtime: runtime)
    }

    static func imageHistory(reference: String, runtime: DockerRuntimeContext) -> String {
        contextualize(imageHistory(reference: reference, sudo: false), runtime: runtime)
    }

    static func diskUsage(runtime: DockerRuntimeContext) -> String {
        contextualize(diskUsage(sudo: false), runtime: runtime)
    }

    static func volumes(runtime: DockerRuntimeContext) -> String {
        contextualize(volumes(sudo: false), runtime: runtime)
    }

    static func danglingVolumes(runtime: DockerRuntimeContext) -> String {
        contextualize(danglingVolumes(sudo: false), runtime: runtime)
    }

    static func volumeInspect(name: String, runtime: DockerRuntimeContext) -> String {
        contextualize(volumeInspect(name: name, sudo: false), runtime: runtime)
    }

    static func containersUsingVolume(name: String, runtime: DockerRuntimeContext) -> String {
        contextualize(containersUsingVolume(name: name, sudo: false), runtime: runtime)
    }

    static func networks(runtime: DockerRuntimeContext) -> String {
        contextualize(networks(sudo: false), runtime: runtime)
    }

    static func danglingNetworks(runtime: DockerRuntimeContext) -> String {
        contextualize(danglingNetworks(sudo: false), runtime: runtime)
    }

    static func networkInspect(name: String, runtime: DockerRuntimeContext) -> String {
        contextualize(networkInspect(name: name, sudo: false), runtime: runtime)
    }

    static func logs(
        id: String,
        tail: Int = 200,
        runtime: DockerRuntimeContext
    ) -> String {
        contextualize(logs(id: id, tail: tail, sudo: false), runtime: runtime)
    }

    static func availabilityProbe(runtime: DockerRuntimeContext) -> String {
        contextualize(availabilityProbe(sudo: false), runtime: runtime)
    }

    private static func contextualize(
        _ command: String,
        runtime: DockerRuntimeContext
    ) -> String {
        if command == "docker-compose" || command.hasPrefix("docker-compose ") {
            return runtime.composeV1CommandPrefix + command.dropFirst("docker-compose".count)
        }
        guard command == "docker" || command.hasPrefix("docker ") else {
            return command
        }
        return runtime.commandPrefix + command.dropFirst("docker".count)
    }
}
