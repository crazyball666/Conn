import SwiftUI
import Foundation

/// 表单 sheet、强确认 sheet 与不可误关的 pull cover 的唯一 UI 路由。把它从主列表
/// 拆出，避免分段的只读浏览逻辑与写入口状态机互相膨胀。
extension DockerView {
    /// 冒烟脚本可用环境变量直接落在某一分段，不必依赖模拟器点击 segmented picker。
    static func initialTab() -> Tab {
        #if DEBUG
            switch ProcessInfo.processInfo.environment["CONN_SMOKE_DOCKER_TAB"] {
            case "images": .images
            case "volumes": .volumes
            case "networks": .networks
            case "compose": .compose
            default: .containers
            }
        #else
            .containers
        #endif
    }

    var messageBinding: Binding<Bool> {
        Binding(get: { viewModel.actionMessage != nil }, set: { if !$0 { viewModel.actionMessage = nil } })
    }

    enum OperationSheet: Identifiable {
        case runContainer
        case pullImage
        case createVolume
        case createNetwork
        case addComposeProject
        case destructive(DockerPendingAction)

        var id: String {
            switch self {
            case .runContainer: "run-container"
            case .pullImage: "pull-image"
            case .createVolume: "create-volume"
            case .createNetwork: "create-network"
            case .addComposeProject: "add-compose-project"
            case let .destructive(action): "destructive-\(action.confirmationWord)"
            }
        }
    }

    var operationSheetBinding: Binding<OperationSheet?> {
        Binding(
            get: {
                if let action = viewModel.operations.pendingDestructiveAction {
                    return .destructive(action)
                }
                return operationSheet
            },
            set: { target in
                guard target == nil else {
                    operationSheet = target
                    return
                }
                operationSheet = nil
                viewModel.operations.cancelPendingAction()
            }
        )
    }

    var pullPresentationBinding: Binding<DockerPullPresentation?> {
        Binding(
            get: { viewModel.operations.pullPresentation },
            set: { presentation in
                // SwiftUI 会在手势、层级重建时尝试写 nil；活动 pull 必须忽略它。
                if presentation == nil { viewModel.operations.dismissPullProgress() }
            }
        )
    }

    @ViewBuilder
    func operationSheetView(_ target: OperationSheet) -> some View {
        switch target {
        case .runContainer:
            DockerRunFormView(
                networks: viewModel.networks, volumes: viewModel.volumes, operations: viewModel.operations
            )
        case .pullImage:
            DockerPullFormView(operations: viewModel.operations)
        case .createVolume:
            DockerVolumeFormView(operations: viewModel.operations)
        case .createNetwork:
            DockerNetworkFormView(operations: viewModel.operations)
        case .addComposeProject:
            DockerComposeManualFormView(model: viewModel.compose)
        case .destructive:
            DockerDestructiveConfirmationView(operations: viewModel.operations)
        }
    }

}
