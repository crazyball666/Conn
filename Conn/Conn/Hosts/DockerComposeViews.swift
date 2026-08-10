import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

struct DockerComposeListView: View {
    let model: DockerComposeModel
    @Binding var search: String
    let open: (DockerComposeProject) -> Void

    var body: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(
                count: String(format: L("共 %d 个项目"), filteredProjects.count)
            )
            if let error = model.errorMessage {
                ConnRetryState(error, retryTitle: L("重试")) {
                    Task { await model.load() }
                }
            }
            if !model.isLoaded {
                ProgressView(L("读取 Compose 项目…"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ConnSpacing.xl)
            } else if filteredProjects.isEmpty {
                Text(search.isEmpty ? L("没有 Compose 项目") : L("没有匹配的 Compose 项目"))
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
                    .padding(.vertical, ConnSpacing.xl)
            } else {
                ForEach(filteredProjects) { project in
                    projectRow(project)
                }
            }
        }
        .padding(.bottom, ConnSpacing.lg)
        .task { await model.loadIfNeeded() }
    }

    private var filteredProjects: [DockerComposeProject] {
        guard !search.isEmpty else { return model.items }
        return model.items.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.projectDirectory.localizedCaseInsensitiveContains(search)
                || $0.configFiles.contains {
                    $0.localizedCaseInsensitiveContains(search)
                }
        }
    }

    private func projectRow(_ project: DockerComposeProject) -> some View {
        Button { open(project) } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.connAccent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.connData(.footnote))
                        .foregroundStyle(.connInk)
                        .lineLimit(1)
                    Text(projectSummary(project))
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: ConnSpacing.xs)
                StatusPill(stateTitle(project.state), semantic: stateSemantic(project.state))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.connMuted)
            }
            .padding(ConnSpacing.cardPadding)
            .connSurface(cornerRadius: ConnRadius.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(project.name)，\(stateTitle(project.state))")
    }

    private func projectSummary(_ project: DockerComposeProject) -> String {
        let source = project.source == .manual ? L("手动") : L("自动发现")
        return String(
            format: L("%@ · %d 个服务 · %d/%d 个容器运行"),
            source,
            project.serviceCount,
            project.runningContainerCount,
            project.containerCount
        )
    }
}

struct DockerComposeProjectDetailView: View {
    let initialProject: DockerComposeProject
    let viewModel: DockerViewModel
    let host: Host
    let dependencies: AppDependencies

    @Environment(\.dismiss) private var dismiss
    @State private var services: [DockerComposeService] = []
    @State private var loading = true
    @State private var hasLoadedServices = false
    @State private var errorMessage: String?
    @State private var logSource: LogSource?
    @State private var openedContainer: ContainerInfo?
    @State private var expandedServiceIDs: Set<String> = []
    @State private var showRemoveManualConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                DockerDetail.operationActivity(
                    viewModel.operations.activeOperationDescription
                )
                actions
                summary
                servicesSection
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadServicesIfNeeded() }
        .onChange(of: viewModel.operations.activeOperationDescription) { previous, current in
            if previous != nil, current == nil {
                Task { await loadServices() }
            }
        }
        .navigationDestination(item: $logSource) { source in
            LogStreamView(
                host: host,
                dependencies: dependencies,
                source: source,
                sudo: viewModel.usesSudo
            )
        }
        .navigationDestination(item: $openedContainer) { container in
            ContainerDetailView(
                host: host,
                dependencies: dependencies,
                container: container,
                viewModel: viewModel
            )
        }
        .alert(L("移除手动项目？"), isPresented: $showRemoveManualConfirmation) {
            Button(L("取消"), role: .cancel) {}
            Button(L("移除"), role: .destructive) {
                viewModel.compose.removeManualProject(project)
                dismiss()
            }
        } message: {
            Text(L("只会从当前会话的项目列表移除，不会停止或删除服务器上的 Docker 资源。"))
        }
    }

    private var project: DockerComposeProject {
        viewModel.compose.items.first(where: { $0.name == initialProject.name })
            ?? initialProject
    }

    private var summary: some View {
        DockerDetail.section(L("概要")) {
            HStack {
                StatusPill(stateTitle(project.state), semantic: stateSemantic(project.state))
                if project.source == .manual {
                    StatusPill(L("手动"), semantic: .info)
                }
            }
            DockerDetail.infoRows([
                (L("项目名称"), project.name),
                (L("服务"), "\(project.serviceCount)"),
                (L("容器"), "\(project.runningContainerCount)/\(project.containerCount)"),
                (L("项目目录"), project.projectDirectory),
                (L("配置文件"), project.configFiles.joined(separator: ", "))
            ])
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("操作"))
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .connEyebrowTracking()
            HStack(spacing: ConnSpacing.xs) {
                DockerDetail.actionButton(
                    L("启动"),
                    systemImage: "play.circle"
                ) {
                    perform { dialect in
                        await viewModel.operations.composeUp(project, dialect: dialect)
                    }
                }
                DockerDetail.actionButton(
                    L("重启"),
                    systemImage: "arrow.clockwise.circle"
                ) {
                    perform { dialect in
                        await viewModel.operations.composeRestart(project, dialect: dialect)
                    }
                }
                DockerDetail.actionButton(
                    L("日志"),
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    openProjectLogs()
                }
                DockerDetail.actionButton(
                    L("停止并移除"),
                    systemImage: "trash",
                    tint: .connCrit
                ) {
                    guard let dialect = viewModel.compose.dialect else { return }
                    viewModel.operations.requestDestructiveAction(
                        .composeDown(project: project, dialect: dialect)
                    )
                }
            }
            .disabled(!viewModel.canWrite || viewModel.compose.dialect == nil)
            if project.source == .manual {
                Button(role: .destructive) {
                    showRemoveManualConfirmation = true
                } label: {
                    Label(L("从列表移除此手动项目"), systemImage: "minus.circle")
                        .font(.connSubheadline)
                        .padding(.horizontal, ConnSpacing.cardPadding)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .connSurface(cornerRadius: ConnRadius.card)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var servicesSection: some View {
        DockerDetail.section(L("服务")) {
            if let errorMessage {
                ConnRetryState(errorMessage, retryTitle: L("重试")) {
                    Task { await loadServices() }
                }
            } else if loading {
                ProgressView(L("读取服务…"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ConnSpacing.lg)
            } else if services.isEmpty {
                Text(L("该项目没有服务"))
                    .font(.connSubheadline)
                    .foregroundStyle(.connMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                        if index > 0 {
                            Rectangle().fill(Color.connLine).frame(height: 0.5)
                        }
                        serviceRow(service)
                    }
                }
            }
        }
    }

    private func serviceRow(_ service: DockerComposeService) -> some View {
        VStack(spacing: 0) {
            if service.containers.isEmpty {
                serviceNavigationLabel(service)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ConnSpacing.xs)
            } else {
                Button { open(service) } label: {
                    serviceNavigationLabel(service)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ConnSpacing.xs)
            }

            if service.containers.count > 1, expandedServiceIDs.contains(service.id) {
                expandedContainers(for: service)
            }
        }
    }

    private func serviceNavigationLabel(_ service: DockerComposeService) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: "shippingbox")
                .font(.system(size: 12))
                .foregroundStyle(.connMuted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.connData(.footnote))
                    .foregroundStyle(.connInk)
                Text(serviceSubtitle(service))
                    .font(.connData(.caption2))
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: ConnSpacing.xs)
            StatusPill(stateTitle(service.state), semantic: stateSemantic(service.state))
            if service.containers.count > 1 {
                Image(systemName: expandedServiceIDs.contains(service.id) ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.connMuted)
            } else if service.containers.count == 1 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.connMuted)
            }
        }
    }

    private func open(_ service: DockerComposeService) {
        if service.containers.count == 1 {
            openedContainer = service.containers[0]
        } else if service.containers.count > 1 {
            toggleServiceExpansion(service)
        }
    }

    private func toggleServiceExpansion(_ service: DockerComposeService) {
        if expandedServiceIDs.contains(service.id) {
            expandedServiceIDs.remove(service.id)
        } else {
            expandedServiceIDs.insert(service.id)
        }
    }

    private func expandedContainers(for service: DockerComposeService) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(service.containers.enumerated()), id: \.element.id) { index, container in
                if index > 0 {
                    Rectangle().fill(Color.connLine).frame(height: 0.5)
                }
                DockerDetail.containerRow(
                    name: container.name,
                    subtitle: "\(container.image) · \(container.status)"
                ) {
                    openedContainer = container
                }
            }
        }
        .padding(.horizontal, ConnSpacing.sm)
        .background(Color.connBg.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous))
        .padding(.leading, 30)
        .padding(.bottom, ConnSpacing.xs)
    }

    private func serviceSubtitle(_ service: DockerComposeService) -> String {
        let image = service.image ?? L("无镜像")
        let containers = String(
            format: L("%d/%d 个容器运行"),
            service.runningContainerCount,
            service.containerCount
        )
        if service.ports.isEmpty {
            return "\(image) · \(containers)"
        }
        return "\(image) · \(containers) · \(service.ports)"
    }

    /// 详情页从容器详情返回时会再次触发 `.task`；已有结果时直接复用，
    /// 只有首次进入才查询远端。重试和操作完成后的刷新仍直接调用 `loadServices()`。
    private func loadServicesIfNeeded() async {
        guard !hasLoadedServices else { return }
        hasLoadedServices = true
        await loadServices()
        if Task.isCancelled { hasLoadedServices = false }
    }

    private func loadServices() async {
        loading = true
        errorMessage = nil
        do {
            services = try await viewModel.compose.services(for: project)
            #if DEBUG
                if ProcessInfo.processInfo.environment["CONN_SMOKE_COMPOSE_CONTAINER_ROUTE"] != nil,
                   let service = services.first(where: { $0.name == "api" }) {
                    open(service)
                }
            #endif
        } catch {
            errorMessage = error.friendlyDiagnosis
        }
        loading = false
    }

    private func perform(
        _ action: @escaping (DockerComposeDialect) async -> Void
    ) {
        guard let dialect = viewModel.compose.dialect else { return }
        Task {
            await action(dialect)
        }
    }

    private func openProjectLogs() {
        guard let dialect = viewModel.compose.dialect else { return }
        logSource = LogSource(
            id: "compose-\(project.name)-project",
            title: project.name,
            subtitle: L("Compose 项目日志"),
            kind: .compose(
                project: project,
                dialect: dialect,
                service: nil,
                runtime: viewModel.runtime
            )
        )
    }
}

private func stateTitle(_ state: DockerComposeState) -> String {
    switch state {
    case .running: L("运行中")
    case .partial: L("部分运行")
    case .stopped: L("已停止")
    case .unknown: L("未知")
    }
}

private func stateSemantic(_ state: DockerComposeState) -> StatusPill.Semantic {
    switch state {
    case .running: .good
    case .partial: .warn
    case .stopped: .off
    case .unknown: .info
    }
}
