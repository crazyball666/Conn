import ConnKit
import ConnOps
import Foundation

/// 一次 Docker 写操作完成后需要静默重载的资源。它是集合而非单一枚举，因为创建
/// 容器会同时改变容器列表与镜像引用关系。
struct DockerRefreshScope: OptionSet, Sendable, Equatable {
    let rawValue: UInt

    static let containers = DockerRefreshScope(rawValue: 1 << 0)
    static let images = DockerRefreshScope(rawValue: 1 << 1)
    static let volumes = DockerRefreshScope(rawValue: 1 << 2)
    static let networks = DockerRefreshScope(rawValue: 1 << 3)
    static let compose = DockerRefreshScope(rawValue: 1 << 4)
    static let all: DockerRefreshScope = [.containers, .images, .volumes, .networks, .compose]
}

/// 远端最终退出结果的可知性。此类型刻意只留退出码，绝不携带 `ExecResult`、命令或输出。
enum DockerOperationResultState: Sendable, Equatable {
    case known(exitCode: Int32)
    case unknown

    var runHistoryState: RunHistoryState {
        switch self {
        case .known: .known
        case .unknown: .unknown
        }
    }

    var exitCode: Int32? {
        switch self {
        case let .known(exitCode): exitCode
        case .unknown: nil
        }
    }

    var isSuccess: Bool {
        if case .known(exitCode: 0) = self { return true }
        return false
    }
}

/// 可审计的写操作种类。审计只保存此语义标签，不保存实际 docker 命令、草稿或远端输出。
enum DockerAuditOperation: Sendable, Equatable {
    case startContainer
    case stopContainer
    case restartContainer
    case removeContainer
    case removeImage
    case pruneImages
    case pullImage
    case runContainer
    case createVolume
    case removeVolume
    case createNetwork
    case removeNetwork
    case systemPrune
    case composeUp
    case composeDown
    case composeRestartProject
    case composeRestartService

    var historyLabel: String {
        switch self {
        case .startContainer: L("Docker 启动容器")
        case .stopContainer: L("Docker 停止容器")
        case .restartContainer: L("Docker 重启容器")
        case .removeContainer: L("Docker 删除容器")
        case .removeImage: L("Docker 删除镜像")
        case .pruneImages: L("Docker 清理悬空镜像")
        case .pullImage: L("Docker 拉取镜像")
        case .runContainer: L("Docker 创建容器")
        case .createVolume: L("Docker 创建卷")
        case .removeVolume: L("Docker 删除卷")
        case .createNetwork: L("Docker 创建网络")
        case .removeNetwork: L("Docker 删除网络")
        case .systemPrune: L("Docker 系统清理")
        case .composeUp: L("Docker Compose 启动项目")
        case .composeDown: L("Docker Compose 停止并移除项目")
        case .composeRestartProject: L("Docker Compose 重启项目")
        case .composeRestartService: L("Docker Compose 重启服务")
        }
    }
}

/// 用于持久化的最小审计摘要。没有命令文本、用户名密码、环境变量、token 或 stdout/stderr。
struct DockerAuditSummary: Sendable, Equatable {
    let operation: DockerAuditOperation
    let state: DockerOperationResultState
    let ranAt: Int64

    init(
        operation: DockerAuditOperation,
        state: DockerOperationResultState,
        ranAt: Int64 = Timestamp.now()
    ) {
        self.operation = operation
        self.state = state
        self.ranAt = ranAt
    }

    var historyLabel: String { operation.historyLabel }

    func historyEntry(hostUUID: String, id: String = UUID().uuidString) -> RunHistoryEntry {
        RunHistoryEntry(
            id: id,
            hostUUID: hostUUID,
            script: historyLabel,
            exitCode: state.exitCode,
            outputHead: nil,
            state: state.runHistoryState,
            ranAt: ranAt
        )
    }
}

/// 当前持有全局 Docker 写闸门的操作。目标仅用于显示忙碌态，绝不进入审计摘要。
enum DockerOperation: Sendable {
    case container(action: ContainerAction, targetID: String)
    case removeImage(targetID: String)
    case pruneImages
    case pullImage
    case runContainer
    case createVolume
    case removeVolume
    case createNetwork
    case removeNetwork
    case systemPrune
    case composeUp(projectName: String)
    case composeDown(projectName: String)
    case composeRestart(projectName: String, serviceName: String?)

    var auditOperation: DockerAuditOperation {
        switch self {
        case let .container(action, _):
            switch action {
            case .start: .startContainer
            case .stop: .stopContainer
            case .restart: .restartContainer
            case .remove: .removeContainer
            }
        case .removeImage: .removeImage
        case .pruneImages: .pruneImages
        case .pullImage: .pullImage
        case .runContainer: .runContainer
        case .createVolume: .createVolume
        case .removeVolume: .removeVolume
        case .createNetwork: .createNetwork
        case .removeNetwork: .removeNetwork
        case .systemPrune: .systemPrune
        case .composeUp: .composeUp
        case .composeDown: .composeDown
        case let .composeRestart(_, serviceName):
            serviceName == nil ? .composeRestartProject : .composeRestartService
        }
    }

    var refreshScope: DockerRefreshScope {
        switch self {
        case .container: [.containers, .images]
        case .removeImage, .pruneImages, .pullImage: .images
        case .runContainer: [.containers, .images]
        case .createVolume, .removeVolume: .volumes
        case .createNetwork, .removeNetwork: .networks
        case .systemPrune: .all
        case .composeUp, .composeDown: .all
        case .composeRestart: [.containers, .compose]
        }
    }

    var activeContainerID: String? {
        guard case let .container(_, targetID) = self else { return nil }
        return targetID
    }

    var activeImageID: String? {
        guard case let .removeImage(targetID) = self else { return nil }
        return targetID
    }
}

/// 拉取进度页唯一持有的展示状态。日志只留在内存中，不会进入审计记录；`result == nil`
/// 表示远端终态尚未知，因而不允许 SwiftUI 的手势或绑定提前关闭该页。
struct DockerPullPresentation: Identifiable, Equatable {
    let id: UUID
    var logs: String
    var result: DockerOperationResultState?

    init(id: UUID = UUID(), logs: String = "", result: DockerOperationResultState? = nil) {
        self.id = id
        self.logs = logs
        self.result = result
    }
}

/// Docker 写操作的确认展示方式。删除 / 清理统一使用系统 Alert；只有生产环境下
/// 非删除类的高风险操作继续要求输入目标名称，避免这次交互调整降低生产保护等级。
enum DockerPendingConfirmationStyle: Sendable, Equatable {
    case alert
    case typedEntry
}

/// 破坏性或生产环境敏感动作。确认 UI 只持有这个强类型值，不能把任何展示文本
/// 再解释成命令；最终执行仍由 `DockerOperationsModel` 的共享写闸门负责。
enum DockerPendingAction: Sendable, Equatable {
    case container(action: ContainerAction, container: ContainerInfo)
    case removeContainer(ContainerInfo)
    case removeImage(ImageInfo)
    case removeVolume(VolumeInfo)
    case removeNetwork(NetworkInfo)
    case pruneImages
    case systemPrune(DockerSystemPruneOptions)
    case composeUp(project: DockerComposeProject, dialect: DockerComposeDialect)
    case composeDown(project: DockerComposeProject, dialect: DockerComposeDialect)
    case composeRestart(
        project: DockerComposeProject,
        service: String?,
        dialect: DockerComposeDialect
    )

    var confirmationStyle: DockerPendingConfirmationStyle {
        switch self {
        case let .container(action, _):
            action.isDestructive ? .alert : .typedEntry
        case .removeContainer, .removeImage, .removeVolume, .removeNetwork,
             .pruneImages, .systemPrune, .composeDown:
            .alert
        case .composeUp, .composeRestart:
            .typedEntry
        }
    }

    /// 仅生产环境的非删除高风险操作需要输入目标名称。删除与清理动作必须返回 nil，
    /// 从领域层保证 UI 不会重新退回“手动输入 DELETE/PRUNE”的旧交互。
    var typedConfirmationWord: String? {
        switch self {
        case let .container(action, container): action.isDestructive ? nil : container.name
        case let .composeUp(project, _): project.name
        case let .composeRestart(project, service, _):
            service.map { "\(project.name)/\($0)" } ?? project.name
        case .removeContainer, .removeImage, .removeVolume, .removeNetwork,
             .pruneImages, .systemPrune, .composeDown:
            nil
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case let .container(action, _): action.label
        case .removeContainer, .removeImage, .removeVolume, .removeNetwork: L("删除")
        case .pruneImages, .systemPrune: L("清理")
        case .composeUp: L("启动")
        case .composeDown: L("停止并移除")
        case .composeRestart: L("重启")
        }
    }

    var impactMessage: String? {
        switch self {
        case .container, .composeUp, .composeRestart:
            L("这是生产环境主机。该操作会影响正在运行的服务，请核对目标后再继续。")
        case .composeDown:
            L("将移除该项目的容器和网络，但不会删除卷。项目配置会保留，之后可以再次启动。")
        default:
            nil
        }
    }

    var typedConfirmationMessage: String {
        guard let typedConfirmationWord else { return "" }
        return String(format: L("请输入 %@ 以继续。"), typedConfirmationWord)
    }

    func acceptsTypedConfirmation(_ confirmation: String) -> Bool {
        guard confirmationStyle == .typedEntry, let typedConfirmationWord else { return false }
        return confirmation == typedConfirmationWord
    }

    var alertTitle: String {
        switch self {
        case let .container(action, _):
            action.isDestructive ? L("删除容器") : L("确认 Docker 操作")
        case .removeContainer: L("删除容器")
        case .removeImage: L("删除镜像")
        case .removeVolume: L("删除卷")
        case .removeNetwork: L("删除网络")
        case .pruneImages: L("清理悬空镜像")
        case .systemPrune: L("清理 Docker 资源")
        case .composeDown: L("停止并移除 Compose 项目")
        case .composeUp, .composeRestart: L("确认 Docker 操作")
        }
    }

    var alertMessage: String {
        switch self {
        case let .container(action, container):
            action.isDestructive
                ? destructiveResourceMessage(container.name)
                : typedConfirmationMessage
        case let .removeContainer(container):
            destructiveResourceMessage(container.name)
        case let .removeImage(image):
            destructiveResourceMessage(image.displayName)
        case let .removeVolume(volume):
            destructiveResourceMessage(volume.name)
        case let .removeNetwork(network):
            destructiveResourceMessage(network.name)
        case .pruneImages:
            L("此操作不可撤销。")
        case let .systemPrune(options):
            systemPruneMessage(options)
        case let .composeDown(project, _):
            [project.name, impactMessage].compactMap { $0 }.joined(separator: "\n\n")
        case .composeUp, .composeRestart:
            typedConfirmationMessage
        }
    }

    private func destructiveResourceMessage(_ name: String) -> String {
        [name, L("此操作不可撤销。")].joined(separator: "\n\n")
    }

    private func systemPruneMessage(_ options: DockerSystemPruneOptions) -> String {
        var lines = [L("默认将移除已停止容器、未使用网络、悬空镜像和构建缓存。")]
        if options.allUnusedImages { lines.append(L("移除所有未使用镜像")) }
        if options.includeVolumes { lines.append(L("包含未使用卷")) }
        lines.append(L("此操作不可撤销。"))
        return lines.joined(separator: "\n")
    }
}
