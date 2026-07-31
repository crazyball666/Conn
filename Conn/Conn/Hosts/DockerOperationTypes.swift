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
        case .composeDown: L("Docker Compose 停止项目")
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
            command: historyLabel,
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

/// 需要用户输入确认词的破坏性动作。Task 5 的表单只需持有这个强类型值，不能把
/// 任意字符串再解释成命令。
enum DockerPendingAction: Sendable, Equatable {
    case removeContainer(ContainerInfo)
    case removeImage(ImageInfo)
    case removeVolume(VolumeInfo)
    case removeNetwork(NetworkInfo)
    case pruneImages
    case systemPrune(DockerSystemPruneOptions)
    case composeDown(project: DockerComposeProject, dialect: DockerComposeDialect)

    /// 删除必须逐字输入资源名；清理类操作固定输入 PRUNE。资源名而非通用 DELETE
    /// 让用户在确认时再看一眼目标，且不同 prune 选项替换 pending action 时 UI 会重置输入。
    var confirmationWord: String {
        switch self {
        case let .removeContainer(container): container.name
        case let .removeImage(image): image.displayName
        case let .removeVolume(volume): volume.name
        case let .removeNetwork(network): network.name
        case .pruneImages, .systemPrune: "PRUNE"
        case let .composeDown(project, _): project.name
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .removeContainer, .removeImage, .removeVolume, .removeNetwork: L("删除")
        case .pruneImages, .systemPrune: L("清理")
        case .composeDown: L("停止")
        }
    }

    var confirmationMessage: String {
        String(format: L("请输入 %@ 以继续。"), confirmationWord)
    }

    func accepts(confirmation: String) -> Bool {
        confirmation == confirmationWord
    }
}
