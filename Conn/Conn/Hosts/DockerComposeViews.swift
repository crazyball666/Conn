import ConnKit
import ConnOps
import ConnSSH
import ConnUI
import SwiftUI

struct DockerComposeListView: View {
    let model: DockerComposeModel
    let canWrite: Bool
    @Binding var search: String
    let addManual: () -> Void
    let open: (DockerComposeProject) -> Void

    var body: some View {
        VStack(spacing: ConnSpacing.sm) {
            DockerDetail.listHeader(
                count: String(format: L("共 %d 个项目"), filteredProjects.count),
                isMenuEnabled: canWrite && model.dialect != nil
            ) {
                Button(action: addManual) {
                    Label(L("手动添加项目"), systemImage: "plus")
                }
            }
            ConnSearchField(L("搜索 Compose 项目"), text: $search)
            if let error = model.errorMessage {
                VStack(spacing: ConnSpacing.sm) {
                    ConnBanner(error, systemImage: "exclamationmark.triangle")
                    Button(L("重试")) { Task { await model.load() } }
                        .font(.connBody)
                        .foregroundStyle(.connAccent)
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

    @State private var services: [DockerComposeService] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var logSource: LogSource?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ConnSpacing.md) {
                summary
                actions
                servicesSection
            }
            .padding(.horizontal, ConnSpacing.page)
            .padding(.vertical, ConnSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadServices() }
        .navigationDestination(item: $logSource) { source in
            LogStreamView(
                host: host,
                dependencies: dependencies,
                source: source,
                sudo: viewModel.usesSudo
            )
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
        DockerDetail.section(L("操作")) {
            HStack(spacing: ConnSpacing.xs) {
                PillButton(L("启动"), semantic: .accent) {
                    perform { dialect in
                        await viewModel.operations.composeUp(project, dialect: dialect)
                    }
                }
                PillButton(L("重启"), semantic: .info) {
                    perform { dialect in
                        await viewModel.operations.composeRestart(project, dialect: dialect)
                    }
                }
                PillButton(L("日志"), semantic: .info) {
                    openLogs(service: nil)
                }
                PillButton(L("停止"), semantic: .crit) {
                    guard let dialect = viewModel.compose.dialect else { return }
                    viewModel.operations.requestDestructiveAction(
                        .composeDown(project: project, dialect: dialect)
                    )
                }
            }
            .disabled(!viewModel.canWrite || viewModel.compose.dialect == nil)
        }
    }

    @ViewBuilder
    private var servicesSection: some View {
        DockerDetail.section(L("服务")) {
            if let errorMessage {
                VStack(spacing: ConnSpacing.sm) {
                    ConnBanner(errorMessage, systemImage: "exclamationmark.triangle")
                    Button(L("重试")) { Task { await loadServices() } }
                        .font(.connBody)
                        .foregroundStyle(.connAccent)
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
            Menu {
                Button {
                    perform { dialect in
                        await viewModel.operations.composeRestart(
                            project,
                            service: service.name,
                            dialect: dialect
                        )
                    }
                } label: {
                    Label(L("重启服务"), systemImage: "arrow.clockwise")
                }
                Button {
                    openLogs(service: service.name)
                } label: {
                    Label(L("查看日志"), systemImage: "doc.text")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.connAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(viewModel.compose.dialect == nil)
        }
        .padding(.vertical, ConnSpacing.xs)
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

    private func loadServices() async {
        loading = true
        errorMessage = nil
        do {
            services = try await viewModel.compose.services(for: project)
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
            await loadServices()
        }
    }

    private func openLogs(service: String?) {
        guard let dialect = viewModel.compose.dialect else { return }
        let target = service ?? project.name
        logSource = LogSource(
            id: "compose-\(project.name)-\(service ?? "project")",
            title: target,
            subtitle: service == nil ? L("Compose 项目日志") : L("Compose 服务日志"),
            kind: .compose(project: project, dialect: dialect, service: service)
        )
    }
}

struct DockerComposeManualFormView: View {
    let model: DockerComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var configFile = ""
    @State private var projectDirectory = ""
    @State private var projectName = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("配置文件绝对路径"), text: $configFile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("项目目录（可选）"), text: $projectDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("项目名称（可选）"), text: $projectName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L("项目配置"))
                } footer: {
                    if let project = draft.project {
                        Text(String(format: L("将使用项目名称：%@"), project.name))
                    } else {
                        Text(L("配置文件必须使用服务器上的绝对路径。"))
                    }
                }
                .listRowBackground(Color.connSurface)
                if let error = model.errorMessage {
                    Section {
                        ConnBanner(error, systemImage: "exclamationmark.triangle")
                    }
                    .listRowBackground(Color.connSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("手动添加 Compose 项目"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("添加")) {
                        isSubmitting = true
                        Task {
                            if await model.addManualProject(draft) {
                                dismiss()
                            } else {
                                isSubmitting = false
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.validate().isEmpty || isSubmitting)
                }
            }
        }
    }

    private var draft: DockerComposeManualDraft {
        DockerComposeManualDraft(
            configFile: configFile,
            projectDirectory: projectDirectory,
            projectName: projectName
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
