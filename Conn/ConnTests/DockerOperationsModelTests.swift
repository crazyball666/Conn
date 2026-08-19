import ConnKit
import ConnOps
import ConnSSH
import Foundation
import Testing
@testable import Conn

private let operationsTestDockerRuntime = DockerRuntimeContext(executable: "docker", sudo: false)

@MainActor
struct DockerOperationsModelTests {
    @Test("旧的容器与镜像入口共用同一写操作闸门")
    func legacyContainerAndImageActionsShareOneGate() async {
        let gate = OperationGate()
        let session = GatedOperationSession(gate: gate)
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let containers = DockerContainersModel(context: context, operations: operations)
        let images = DockerImagesModel(context: context, operations: operations)
        let container = ContainerInfo(
            id: "c1", name: "web", image: "nginx", state: .running, status: "Up", ports: ""
        )

        let first = Task { await containers.perform(.stop, on: container) }
        await gate.waitForFirstCommand()
        let second = Task { await images.prune() }
        await Task.yield()

        let blockedCommandCount = await gate.commandCount
        #expect(blockedCommandCount == 1)
        #expect(operations.activeOperation != nil)

        await gate.allow()
        _ = await first.value
        await second.value

        let finalCommandCount = await gate.commandCount
        #expect(finalCommandCount == 1)
        #expect(operations.activeOperation == nil)
    }

    @Test("已知非零退出码也审计并只刷新受影响的镜像")
    func knownNonzeroAuditsAndRefreshesTargetScope() async {
        let session = OperationSession(result: ExecResult(
            exitCode: 1, stdout: Data("private-token".utf8), stderr: Data("denied".utf8)
        ))
        let history = RecordingHistory()
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let image = ImageInfo(imageID: "i1", repository: "registry/app", tag: "1", size: "1MB", created: "now")

        operations.requestDestructiveAction(.removeImage(image))
        let confirmed = await operations.confirmPendingAlertAction()

        #expect(confirmed)
        #expect(refreshes == [.images])
        let entry = history.entries.first
        #expect(entry?.state == .known)
        #expect(entry?.exitCode == 1)
        #expect(entry?.outputHead == nil)
        #expect(entry?.script.contains("private-token") == false)
    }

    @Test("已知失败向用户展示远端 stderr 而不是只有退出码")
    func knownFailureReportsRemoteStderr() async {
        let session = OperationSession(result: ExecResult(
            exitCode: 1,
            stdout: Data("private stdout".utf8),
            stderr: Data("volume name already in use".utf8)
        ))
        var reports: [String] = []
        let operations = DockerOperationsModel(
            context: makeContext(
                session: { session },
                report: { reports.append($0) }
            ),
            hostUUID: "host-1",
            runHistory: RecordingHistory()
        )

        await operations.createVolume(DockerVolumeDraft(name: "cache"))

        #expect(
            reports.last
                == String(
                    format: L("%@ 失败：%@"),
                    L("创建卷"),
                    "volume name already in use"
                )
        )
        #expect(reports.last?.contains("private stdout") == false)
    }

    @Test("普通 Docker 写操作先记录 pending，再用同一条记录写入终态")
    func writeOperationUsesPendingAuditLifecycle() async {
        let session = OperationSession(result: ExecResult(exitCode: 0, stdout: Data(), stderr: Data()))
        let history = RecordingHistory()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }),
            hostUUID: "host-1",
            runHistory: history
        )

        await operations.createNetwork(DockerNetworkDraft(name: "app-net"))

        #expect(history.entries.count == 1)
        #expect(history.recordedIDs.count == 1)
        #expect(history.updatedIDs == history.recordedIDs)
        #expect(history.entries.first?.state == .known)
    }

    @Test("没有最终结果的写操作记录未知且不自动刷新")
    func unknownWriteAuditsWithoutRefresh() async {
        let session = OperationSession(throwsUnknown: true)
        let history = RecordingHistory()
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let image = ImageInfo(imageID: "i1", repository: "app", tag: "1", size: "1MB", created: "now")

        operations.requestDestructiveAction(.removeImage(image))
        let confirmed = await operations.confirmPendingAlertAction()

        #expect(confirmed)
        #expect(refreshes.isEmpty)
        let entry = history.entries.first
        #expect(entry?.state == .unknown)
        #expect(entry?.exitCode == nil)
    }

    @Test("本地草稿校验失败不会写审计或启动远端命令")
    func invalidRunDoesNotAuditOrStartRemoteCommand() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: history
        )

        await operations.runContainer(DockerRunDraft(image: ""))

        #expect(history.entries.isEmpty)
        #expect(!session.didExecute)
    }

    @Test("审计摘要不保留命令、环境变量或远端输出")
    func auditSummaryRedactsSecretsAndRawOutput() async {
        let session = OperationSession(result: ExecResult(
            exitCode: 0, stdout: Data("remote stdout: token=from-server".utf8), stderr: Data()
        ))
        let history = RecordingHistory()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: history
        )
        let draft = DockerRunDraft(
            image: "nginx:latest", environment: [EnvironmentEntry(key: "API_TOKEN", value: "local-secret")]
        )

        await operations.runContainer(draft)

        let entry = history.entries.first
        #expect(entry?.script.contains("API_TOKEN") == false)
        #expect(entry?.script.contains("local-secret") == false)
        #expect(entry?.script.contains("from-server") == false)
        #expect(entry?.script.contains("docker run") == false)
        #expect(entry?.outputHead == nil)
    }

    @Test("删除与清理动作统一使用 Alert 且不再生成输入确认词")
    func deleteAndCleanupActionsUseAlertsWithoutTypedConfirmation() {
        let container = ContainerInfo(
            id: "c1", name: "web", image: "nginx", state: .running, status: "Up", ports: ""
        )
        let image = ImageInfo(
            imageID: "i1", repository: "nginx", tag: "latest", size: "1MB", created: "now"
        )
        let volume = VolumeInfo(name: "cache", driver: "local", scope: "local", mountpoint: "/cache")
        let network = NetworkInfo(id: "n1", name: "app-net", driver: "bridge", scope: "local")
        let project = DockerComposeProject(
            name: "web", state: .running,
            configFiles: ["/srv/web/compose.yml"], projectDirectory: "/srv/web",
            source: .automatic
        )
        let actions: [DockerPendingAction] = [
            .container(action: .remove, container: container),
            .removeContainer(container),
            .removeImage(image),
            .removeVolume(volume),
            .removeNetwork(network),
            .pruneImages,
            .systemPrune(DockerSystemPruneOptions(allUnusedImages: true, includeVolumes: true)),
            .composeDown(project: project, dialect: .v2)
        ]

        for action in actions {
            #expect(action.confirmationStyle == .alert)
            #expect(action.typedConfirmationWord == nil)
            #expect(!action.alertTitle.isEmpty)
            #expect(!action.alertMessage.isEmpty)
            #expect(!action.acceptsTypedConfirmation("PRUNE"))
        }
    }

    @Test("生产环境停止容器必须输入容器名后执行")
    func productionContainerStopRequiresExactName() async {
        let session = OperationSession()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }),
            hostUUID: "host-1",
            runHistory: RecordingHistory(),
            isProduction: true
        )
        let container = ContainerInfo(
            id: "c1",
            name: "api",
            image: "app:1",
            state: .running,
            status: "Up",
            ports: ""
        )

        await operations.perform(.stop, on: container)

        #expect(
            operations.pendingDestructiveAction
                == .container(action: .stop, container: container)
        )
        #expect(session.executionCount == 0)
        #expect(await operations.confirmPendingAction(confirmation: "api"))
        #expect(
            session.lastCommand == DockerCommand.action(
                .stop,
                id: "c1",
                runtime: operationsTestDockerRuntime
            )
        )
    }

    @Test("生产环境重启 Compose 服务必须输入项目和服务名")
    func productionComposeServiceRestartRequiresExactTarget() async {
        let session = OperationSession()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }),
            hostUUID: "host-1",
            runHistory: RecordingHistory(),
            isProduction: true
        )
        let project = DockerComposeProject(
            name: "web",
            state: .running,
            configFiles: ["/srv/web/compose.yml"],
            projectDirectory: "/srv/web",
            source: .manual
        )

        await operations.composeRestart(
            project,
            service: "api",
            dialect: .v2
        )

        #expect(
            operations.pendingDestructiveAction
                == .composeRestart(project: project, service: "api", dialect: .v2)
        )
        #expect(session.executionCount == 0)
        #expect(!operations.canConfirmPendingAction(input: "web"))
        #expect(await operations.confirmPendingAction(confirmation: "web/api"))
        #expect(
            session.lastCommand
                == DockerCommand.composeRestart(
                    project,
                    service: "api",
                    dialect: .v2,
                    runtime: operationsTestDockerRuntime
                )
        )
    }

    @Test("Compose down 通过 Alert 确认并经共享操作模型执行")
    func composeDownUsesAlertConfirmationAndSharedOperations() async {
        let session = OperationSession()
        let history = RecordingHistory()
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(
            context: context, hostUUID: "host-1", runHistory: history
        )
        let project = DockerComposeProject(
            name: "web", state: .running,
            configFiles: ["/srv/web/compose.yml"], projectDirectory: "/srv/web",
            source: .automatic
        )

        operations.requestDestructiveAction(.composeDown(project: project, dialect: .v2))
        #expect(operations.pendingDestructiveAction?.confirmationStyle == .alert)
        #expect(session.executionCount == 0)

        let confirmed = await operations.confirmPendingAlertAction()

        #expect(confirmed)
        #expect(
            session.lastCommand == DockerCommand.composeDown(
                project,
                dialect: .v2,
                runtime: operationsTestDockerRuntime
            )
        )
        #expect(refreshes == [.all])
        #expect(history.entries.first?.script == L("Docker Compose 停止并移除项目"))
        #expect(history.entries.first?.script.contains("/srv/web") == false)
    }

    @Test("Compose up 与既有镜像操作共用同一单槽写闸门")
    func composeAndLegacyWritesShareOneGate() async {
        let gate = OperationGate()
        let session = GatedOperationSession(gate: gate)
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }),
            hostUUID: "host-1",
            runHistory: RecordingHistory()
        )
        let images = DockerImagesModel(
            context: makeContext(session: { session }),
            operations: operations
        )
        let project = DockerComposeProject(
            name: "web", state: .stopped,
            configFiles: ["/srv/web/compose.yml"], projectDirectory: "/srv/web",
            source: .automatic
        )

        let first = Task {
            await operations.composeUp(project, dialect: .v2)
        }
        await gate.waitForFirstCommand()
        let second = Task { await images.prune() }
        await Task.yield()

        #expect(await gate.commandCount == 1)

        await gate.allow()
        _ = await first.value
        await second.value
        #expect(await gate.commandCount == 1)
    }

    @Test("拉取逐块交付输出，以相同 UUID 写入已知非零结果")
    func pullDeliversChunksAndUpdatesPendingAudit() async {
        let session = PullSession(
            chunks: ["layer-a\n", "layer-b\n"],
            result: .success(ExecResult(exitCode: 1, stdout: Data(), stderr: Data("denied".utf8)))
        )
        let history = RecordingHistory()
        var chunks: [String] = []
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)

        await operations.pullImage(reference: "registry.example/app:1") { chunks.append($0) }

        #expect(chunks == ["layer-a\n", "layer-b\n"])
        #expect(history.entries.count == 1)
        #expect(history.recordedIDs == history.updatedIDs)
        #expect(history.entries.first?.state == .known)
        #expect(history.entries.first?.exitCode == 1)
        #expect(refreshes == [.images])
    }

    @Test("拉取没有最终结果时把同一 pending 审计更新为未知")
    func pullWithoutFinalResultBecomesUnknownWithoutRefresh() async {
        let session = PullSession(chunks: ["layer-a\n"], result: .failure(.channelClosed))
        let history = RecordingHistory()
        var refreshes: [DockerRefreshScope] = []
        let context = makeContext(session: { session }, refresh: { refreshes.append($0) })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)

        await operations.pullImage(reference: "registry.example/app:1") { _ in }

        #expect(history.entries.count == 1)
        #expect(history.recordedIDs == history.updatedIDs)
        #expect(history.entries.first?.state == .unknown)
        #expect(history.entries.first?.exitCode == nil)
        #expect(refreshes.isEmpty)
    }

    @Test("pending 审计无法落盘时不启动远端拉取")
    func pullDoesNotStartWhenPendingAuditCannotPersist() async {
        let session = PullSession(chunks: [], result: .success(ExecResult(exitCode: 0, stdout: Data(), stderr: Data())))
        let history = RecordingHistory(failRecord: true)
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: history
        )

        await operations.pullImage(reference: "registry.example/app:1") { _ in }

        #expect(!session.didStart)
    }

    @Test("镜像删除拒绝输入式入口，并只在 Alert 确认后执行一次")
    func imageRemovalUsesAlertConfirmationOnly() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let images = DockerImagesModel(context: context, operations: operations)
        let image = ImageInfo(imageID: "i1", repository: "registry/app", tag: "1", size: "1MB", created: "now")

        images.requestRemoval(image)
        let typedAttempt = await operations.confirmPendingAction(confirmation: image.displayName)

        #expect(!typedAttempt)
        #expect(session.executionCount == 0)
        #expect(operations.pendingDestructiveAction == .removeImage(image))

        let confirmed = await operations.confirmPendingAlertAction()

        #expect(confirmed)
        #expect(session.executionCount == 1)
        #expect(operations.pendingDestructiveAction == nil)
    }

    @Test("容器删除只暂存，并在 Alert 确认后执行")
    func containerRemovalStagesUntilAlertConfirmation() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let containers = DockerContainersModel(context: context, operations: operations)
        let container = ContainerInfo(
            id: "c1", name: "api", image: "registry/app:1", state: .running, status: "Up", ports: ""
        )

        await containers.perform(.remove, on: container)

        #expect(operations.pendingDestructiveAction == .removeContainer(container))
        #expect(session.executionCount == 0)

        let confirmed = await operations.confirmPendingAlertAction()
        #expect(confirmed)
        #expect(session.executionCount == 1)
    }

    @Test("镜像清理只暂存，Alert 确认后才执行一次")
    func imagePruneStagesUntilAlertConfirmation() async {
        let session = OperationSession()
        let history = RecordingHistory()
        let context = makeContext(session: { session })
        let operations = DockerOperationsModel(context: context, hostUUID: "host-1", runHistory: history)
        let images = DockerImagesModel(context: context, operations: operations)

        await images.prune()

        #expect(operations.pendingDestructiveAction == .pruneImages)
        #expect(session.executionCount == 0)

        let confirmed = await operations.confirmPendingAlertAction()
        #expect(confirmed)
        #expect(session.executionCount == 1)
    }

    @Test("系统清理选项进入 Alert 文案且不生成确认词")
    func systemPruneOptionsFlowIntoAlertMessage() {
        let session = OperationSession()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: RecordingHistory()
        )
        let initial = DockerSystemPruneOptions()
        let changed = DockerSystemPruneOptions(allUnusedImages: true, includeVolumes: true)

        operations.requestDestructiveAction(.systemPrune(initial))
        let first = operations.pendingDestructiveAction
        operations.requestDestructiveAction(.systemPrune(changed))

        #expect(first == .systemPrune(initial))
        #expect(operations.pendingDestructiveAction == .systemPrune(changed))
        #expect(operations.pendingDestructiveAction?.confirmationStyle == .alert)
        #expect(operations.pendingDestructiveAction?.typedConfirmationWord == nil)
        #expect(operations.pendingDestructiveAction?.alertMessage.contains(L("移除所有未使用镜像")) == true)
        #expect(operations.pendingDestructiveAction?.alertMessage.contains(L("包含未使用卷")) == true)
    }

    @Test("创建容器表单保留重复字段与 token 的输入顺序")
    func runFormStatePreservesDraftOrder() async {
        var state = DockerRunFormState()
        state.image = "registry.example/api:1"
        state.name = "api"
        state.detached = true
        state.network = "app-net"
        state.ports = [
            DockerPortRow(hostPort: "8080", containerPort: "80", protocol: .tcp),
            DockerPortRow(hostPort: "8443", containerPort: "443", protocol: .tcp)
        ]
        state.environment = [
            DockerEnvironmentRow(key: "FIRST", value: "one"),
            DockerEnvironmentRow(key: "SECOND", value: "two")
        ]
        state.mounts = [
            DockerMountRow(sourceKind: .namedVolume, source: "data", target: "/var/lib/api"),
            DockerMountRow(sourceKind: .bind, source: "/srv/config", target: "/etc/api", readOnly: true)
        ]
        state.otherOptionsText = """
        # 资源限制与额外 hosts
        --cpus=1
        --add-host=db:10.0.0.2
        """
        state.command = [DockerTokenRow(value: "serve"), DockerTokenRow(value: "--foreground")]

        #expect(state.isValid)
        #expect(state.draft == DockerRunDraft(
            image: "registry.example/api:1", name: "api", detached: true, network: "app-net",
            ports: [
                PortBinding(hostPort: "8080", containerPort: "80"),
                PortBinding(hostPort: "8443", containerPort: "443")
            ],
            environment: [EnvironmentEntry(key: "FIRST", value: "one"), EnvironmentEntry(key: "SECOND", value: "two")],
            mounts: [
                MountEntry(source: .namedVolume("data"), target: "/var/lib/api"),
                MountEntry(source: .bind("/srv/config"), target: "/etc/api", readOnly: true)
            ],
            otherOptionTokens: ["--cpus=1", "--add-host=db:10.0.0.2"],
            commandTokens: ["serve", "--foreground"]
        ))

        let session = OperationSession()
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: RecordingHistory()
        )
        await operations.runContainer(state.draft)
        #expect(
            session.lastCommand == DockerCommand.run(
                state.draft,
                runtime: operationsTestDockerRuntime
            )
        )
    }

    @Test("创建容器表单忽略空的重复行，但保留有内容的行")
    func runFormStateIgnoresBlankRepeatableRows() {
        var state = DockerRunFormState()
        state.image = "nginx"
        state.ports = [
            DockerPortRow(),
            DockerPortRow(hostPort: "8080", containerPort: "80"),
        ]
        state.environment = [
            DockerEnvironmentRow(),
            DockerEnvironmentRow(key: "EMPTY_VALUE", value: ""),
        ]
        state.mounts = [
            DockerMountRow(),
            DockerMountRow(source: "data", target: "/var/lib/data"),
        ]
        state.command = [DockerTokenRow(), DockerTokenRow(value: "nginx")]

        #expect(state.draft.ports == [PortBinding(hostPort: "8080", containerPort: "80")])
        #expect(state.draft.environment == [EnvironmentEntry(key: "EMPTY_VALUE", value: "")])
        #expect(state.draft.mounts == [MountEntry(source: .namedVolume("data"), target: "/var/lib/data")])
        #expect(state.draft.commandTokens == ["nginx"])
        #expect(state.isValid)
    }

    @Test("低频容器参数仍可通过高级文本选项手动填写")
    func runFormStateKeepsManualAdvancedOptions() {
        var state = DockerRunFormState()
        state.image = "nginx"
        state.otherOptionsText = """
        --hostname=web-01
        --user=nginx
        --workdir=/app
        --read-only
        """

        #expect(state.isValid)
        #expect(state.draft.otherOptionTokens == [
            "--hostname=web-01", "--user=nginx", "--workdir=/app", "--read-only",
        ])
    }

    @Test("卷和网络表单高级文本参数保持顺序并进入命令预览")
    func resourceFormStatesUseTextOptions() {
        var volume = DockerVolumeFormState()
        volume.name = "cache"
        volume.otherOptionsText = """
        --opt=type=nfs
        --opt=o=addr=10.0.0.2
        """
        #expect(volume.draft.otherOptionTokens == ["--opt=type=nfs", "--opt=o=addr=10.0.0.2"])
        #expect(
            DockerCommand.createVolume(volume.draft, runtime: operationsTestDockerRuntime)
                .contains("--opt=type=nfs")
        )

        var network = DockerNetworkFormState()
        network.name = "isolated"
        network.isInternal = true
        network.otherOptionsText = "--opt=com.docker.network.bridge.name=br-isolated"
        #expect(network.draft.otherOptionTokens == ["--opt=com.docker.network.bridge.name=br-isolated"])
        #expect(
            DockerCommand.createNetwork(network.draft, runtime: operationsTestDockerRuntime)
                .contains("--internal")
        )
    }

    @Test("非法创建草稿禁用继续，高风险配置会被显式标记")
    func runFormValidationAndRiskDetection() {
        var invalid = DockerRunFormState()
        #expect(!invalid.isValid)

        invalid.image = "nginx"
        invalid.ports = [DockerPortRow(hostPort: "0", containerPort: "80")]
        #expect(!invalid.isValid)

        var networkAlias = DockerRunFormState()
        networkAlias.image = "nginx"
        networkAlias.otherOptionsText = "--net=host"
        #expect(!networkAlias.isValid)

        let risky = DockerRunDraft(
            image: "docker:dind", network: "host",
            mounts: [
                MountEntry(source: .bind("/var/run/docker.sock"), target: "/var/run/docker.sock"),
                MountEntry(source: .bind("/"), target: "/host")
            ],
            otherOptionTokens: ["--privileged"]
        )
        #expect(Set(DockerRunRiskDetector.detect(risky)) == [.privileged, .hostNetwork, .dockerSocket, .rootBind])
    }

    @Test("pull 仅受控关闭：活动拒绝、终态由完成动作关闭")
    func activePullCannotDismissUntilTerminalResult() async {
        let gate = OperationGate()
        let session = GatedPullSession(gate: gate)
        let operations = DockerOperationsModel(
            context: makeContext(session: { session }), hostUUID: "host-1", runHistory: RecordingHistory()
        )

        let pull = Task { await operations.pullImage(reference: "registry.example/app:1") { _ in } }
        await gate.waitForFirstCommand()

        #expect(operations.isPullActive)
        #expect(!operations.canDismissPull)
        operations.dismissPullProgress()
        #expect(operations.pullPresentation != nil)

        await gate.allow()
        await pull.value

        #expect(!operations.isPullActive)
        #expect(operations.canDismissPull)
        operations.dismissPullProgress()
        #expect(operations.pullPresentation == nil)
    }

    @Test("pull 终态在刷新继续前就可供完成")
    func pullTerminalPresentationPrecedesBlockedRefresh() async {
        let refreshGate = RefreshGate()
        let session = PullSession(
            chunks: [], result: .success(ExecResult(exitCode: 0, stdout: Data(), stderr: Data()))
        )
        let operations = DockerOperationsModel(
            context: makeContext(
                session: { session },
                refresh: { _ in await refreshGate.waitUntilAllowed() }
            ),
            hostUUID: "host-1",
            runHistory: RecordingHistory()
        )

        let pull = Task { await operations.pullImage(reference: "registry.example/app:1") { _ in } }
        await refreshGate.waitForRefresh()

        #expect(operations.isPullActive)
        #expect(operations.pullPresentation?.result == .known(exitCode: 0))
        #expect(operations.canDismissPull)

        await refreshGate.allow()
        await pull.value

        #expect(!operations.isPullActive)
    }

    @Test("pull 终态标题区分成功、已知失败与未知结果")
    func pullTerminalTitlesDistinguishKnownFailureFromUnknownOutcome() {
        #expect(DockerPullProgressView.resultTitle(for: .known(exitCode: 0)) == L("拉取完成"))
        #expect(
            DockerPullProgressView.resultTitle(for: .known(exitCode: 23))
                == String(format: L("%@ 失败（退出码 %d）"), L("拉取镜像"), 23)
        )
        #expect(DockerPullProgressView.resultTitle(for: .unknown) == L("拉取结果未知"))
    }

    private func makeContext(
        session: @escaping () async throws -> any SSHSession,
        refresh: @escaping (DockerRefreshScope) async -> Void = { _ in },
        report: @escaping (String) -> Void = { _ in }
    ) -> DockerContext {
        DockerContext(
            session: session,
            runtime: operationsTestDockerRuntime,
            isUsable: true,
            report: report, refresh: refresh, reprobe: {}
        )
    }
}

private final class RecordingHistory: RunHistoryRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: RunHistoryEntry] = [:]
    private var orderedIDs: [String] = []
    private(set) var recordedIDs: [String] = []
    private(set) var updatedIDs: [String] = []
    private let failRecord: Bool

    init(failRecord: Bool = false) {
        self.failRecord = failRecord
    }

    var entries: [RunHistoryEntry] {
        lock.withLock { orderedIDs.compactMap { stored[$0] } }
    }

    func record(_ entry: RunHistoryEntry) throws {
        if failRecord { throw SSHError.channelClosed }
        lock.withLock {
            stored[entry.id] = entry
            orderedIDs.append(entry.id)
            recordedIDs.append(entry.id)
        }
    }

    func update(_ entry: RunHistoryEntry) throws {
        lock.withLock {
            stored[entry.id] = entry
            updatedIDs.append(entry.id)
        }
    }

    func recoverPending() throws {}

    func recent(hostUUID: String?, limit: Int) throws -> [RunHistoryEntry] {
        entries.prefix(limit).map { $0 }
    }
}

private actor OperationGate {
    private var commands: [String] = []
    private var open = false
    private var firstCommandWaiter: CheckedContinuation<Void, Never>?
    private var openWaiter: CheckedContinuation<Void, Never>?

    func begin(_ command: String) -> Bool {
        commands.append(command)
        if commands.count == 1 {
            firstCommandWaiter?.resume()
            firstCommandWaiter = nil
            return true
        }
        return false
    }

    func waitForFirstCommand() async {
        guard commands.isEmpty else { return }
        await withCheckedContinuation { firstCommandWaiter = $0 }
    }

    func waitUntilOpen() async {
        guard !open else { return }
        await withCheckedContinuation { openWaiter = $0 }
    }

    func allow() {
        open = true
        openWaiter?.resume()
        openWaiter = nil
    }

    var commandCount: Int { commands.count }
}

private actor RefreshGate {
    private var refreshStarted = false
    private var allowed = false
    private var refreshWaiter: CheckedContinuation<Void, Never>?
    private var allowedWaiter: CheckedContinuation<Void, Never>?

    func waitUntilAllowed() async {
        refreshStarted = true
        refreshWaiter?.resume()
        refreshWaiter = nil
        guard !allowed else { return }
        await withCheckedContinuation { allowedWaiter = $0 }
    }

    func waitForRefresh() async {
        guard !refreshStarted else { return }
        await withCheckedContinuation { refreshWaiter = $0 }
    }

    func allow() {
        allowed = true
        allowedWaiter?.resume()
        allowedWaiter = nil
    }
}

private final class GatedOperationSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let gate: OperationGate

    init(gate: OperationGate) {
        self.gate = gate
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        if await gate.begin(command) { await gate.waitUntilOpen() }
        return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) {
            ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

private final class OperationSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let result: ExecResult
    private let throwsUnknown: Bool
    private let lock = NSLock()
    private var executeCount = 0
    private var commands: [String] = []

    init(
        result: ExecResult = ExecResult(exitCode: 0, stdout: Data(), stderr: Data()),
        throwsUnknown: Bool = false
    ) {
        self.result = result
        self.throwsUnknown = throwsUnknown
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        lock.withLock {
            executeCount += 1
            commands.append(command)
        }
        if throwsUnknown { throw SSHError.channelClosed }
        return result
    }

    var didExecute: Bool { lock.withLock { executeCount > 0 } }
    var executionCount: Int { lock.withLock { executeCount } }
    var lastCommand: String? { lock.withLock { commands.last } }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) { self.result }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

private final class PullSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let chunks: [String]
    private let finalResult: Result<ExecResult, SSHError>
    private let lock = NSLock()
    private var started = false

    init(chunks: [String], result: Result<ExecResult, SSHError>) {
        self.chunks = chunks
        finalResult = result
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    var didStart: Bool { lock.withLock { started } }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        lock.withLock { started = true }
        let output = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
            continuation.finish()
        }
        return SSHCommandStream(output: output) {
            try self.finalResult.get()
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}

private final class GatedPullSession: SSHSession, @unchecked Sendable {
    let state: AsyncStream<SSHSessionState>
    private let continuation: AsyncStream<SSHSessionState>.Continuation
    let isConnected = true
    private let gate: OperationGate

    init(gate: OperationGate) {
        self.gate = gate
        (state, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected)
    }

    func exec(_ command: String, timeout: Duration) async throws -> ExecResult {
        ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func execStream(_ command: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func execCommandStream(_ command: String, timeout: Duration) async throws -> SSHCommandStream {
        _ = await gate.begin(command)
        return SSHCommandStream(output: AsyncThrowingStream { $0.finish() }) { [gate] in
            await gate.waitUntilOpen()
            return ExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }

    func openShell(term: TermSize) async throws -> any ShellChannel { throw SSHError.channelClosed }
    func sftp() async throws -> any RemoteFileSystem { throw SSHError.channelClosed }
    func openTunnel(to target: SSHEndpoint) async throws -> any SSHTunnel { throw SSHError.channelClosed }
    func close() async { continuation.finish() }
}
