import ConnKit
import ConnMultiplexer
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// Creates the local tab on the presenting page. `TerminalScreen` is opened only
/// after this sheet reports a committed `(host, tabID)` result.
struct NewTerminalSheet: View {
    @State private var model: NewTerminalFlowModel
    @State private var newWorkspaceName = ""
    @Environment(\.dismiss) private var dismiss

    init(
        fixedHost: Host?,
        hostRepository: any HostRepository,
        terminalSessions: TerminalSessionCoordinator,
        onCompleted: @escaping @MainActor (NewTerminalFlowCompletion) -> Void
    ) {
        self.init(
            fixedHost: fixedHost,
            operations: .live(
                hostRepository: hostRepository,
                coordinator: terminalSessions
            ),
            onCompleted: onCompleted
        )
    }

    init(
        fixedHost: Host?,
        operations: NewTerminalFlowModel.Operations,
        onCompleted: @escaping @MainActor (NewTerminalFlowCompletion) -> Void
    ) {
        _model = State(initialValue: NewTerminalFlowModel(
            fixedHost: fixedHost,
            operations: operations,
            onCompleted: onCompleted
        ))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if canGoBack {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(L("返回")) { Task { await model.back() } }
                                .disabled(model.isCreating)
                        }
                    }
                    if isWorkspaceSelection {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                Task { await model.refresh() }
                            } label: {
                                if model.isRefreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .accessibilityLabel(L("刷新 Session 列表"))
                            .accessibilityIdentifier("new-terminal.refresh-sessions")
                            .disabled(model.isLoading || model.isRefreshing || model.isCreating)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("关闭")) { close() }
                    }
                }
        }
        .interactiveDismissDisabled()
        .onAppear { model.start() }
        .onDisappear {
            model.closeImmediately()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .hostSelection:
            hostSelection
        case .terminalTypeSelection:
            terminalTypeSelection
        case .providerLoading:
            TerminalCreationLoadingView(title: L("正在检测 tmux…"))
        case .providerSelection:
            providerSelection
        case .workspaceSelection:
            workspaceSelection
        case .creating:
            TerminalCreationLoadingView(title: L("正在创建终端…"))
        }
    }

    private var hostSelection: some View {
        List {
            if let errorMessage = model.errorMessage {
                errorSection(errorMessage)
                Section {
                    Button(L("重试")) { model.start() }
                }
            }
            Section(L("选择主机")) {
                if model.hosts.isEmpty, model.errorMessage == nil {
                    Text(L("暂无可用主机"))
                        .foregroundStyle(.connMuted)
                }
                ForEach(model.hosts) { host in
                    Button { model.selectHost(host) } label: {
                        HStack(spacing: ConnSpacing.sm) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.connAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name.isEmpty ? host.address : host.name)
                                    .foregroundStyle(.connInk)
                                Text(host.displayAddress)
                                    .font(.connData(.caption2))
                                    .foregroundStyle(.connMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .foregroundStyle(.connMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private var terminalTypeSelection: some View {
        List {
            if let host = model.selectedHost {
                Section(L("主机")) {
                    Label(host.name.isEmpty ? host.address : host.name, systemImage: "server.rack")
                }
            }
            if let errorMessage = model.errorMessage {
                errorSection(errorMessage)
            }
            Section(L("终端类型")) {
                Button { Task { await model.selectPlainPTY() } } label: {
                    launchChoice(
                        title: L("普通终端"),
                        systemImage: "terminal"
                    )
                }
                Button { Task { await model.selectPersistent() } } label: {
                    launchChoice(
                        title: "tmux",
                        systemImage: "rectangle.connected.to.line.below"
                    )
                }
            }
        }
    }

    private var providerSelection: some View {
        List {
            if let errorMessage = model.errorMessage {
                errorSection(errorMessage)
            }
            if model.options.isEmpty {
                Section(L("tmux 不可用")) {
                    Text(L("当前版本未配置可用的持久终端 Provider"))
                        .foregroundStyle(.connMuted)
                }
                Section {
                    Button { Task { await model.selectPersistent() } } label: {
                        Label(L("重试"), systemImage: "arrow.clockwise")
                    }
                }
            } else {
                Section(L("选择持久终端")) {
                    ForEach(model.options) { option in
                        Button { Task { await model.selectOption(option) } } label: {
                            HStack {
                                Text(option.displayName)
                                    .foregroundStyle(.connInk)
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .foregroundStyle(.connMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
    }

    private var workspaceSelection: some View {
        List {
            if let errorMessage = model.errorMessage {
                errorSection(errorMessage)
            }

            Section(L("创建 Session")) {
                TextField(L("Session 名称（可选）"), text: $newWorkspaceName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await model.createWorkspace(name: newWorkspaceName) }
                } label: {
                    Label(L("创建并连接"), systemImage: "plus.rectangle")
                }
                .disabled(model.isLoading || model.isRefreshing || model.isCreating)
            }

            Section(L("连接现有 Session")) {
                if model.isLoading {
                    HStack(spacing: ConnSpacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(L("正在加载 Session 列表…"))
                            .foregroundStyle(.connMuted)
                    }
                } else if model.workspaces.isEmpty {
                    Text(L("暂无可用 Session"))
                        .foregroundStyle(.connMuted)
                } else {
                    ForEach(model.workspaces, id: \.workspace.workspaceID) { workspace in
                        Button { Task { await model.attach(workspace) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.name)
                                        .foregroundStyle(.connInk)
                                    Text(workspace.workspace.workspaceID)
                                        .font(.connData(.caption2))
                                        .foregroundStyle(.connMuted)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                                    .foregroundStyle(.connMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .disabled(model.isRefreshing || model.isCreating)
                    }
                }
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.connFootnote)
                .foregroundStyle(.connWarn)
        }
    }

    private func launchChoice(title: String, systemImage: String) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(.connAccent)
                .frame(width: 28)
            Text(title).foregroundStyle(.connInk)
            Spacer()
            Image(systemName: "chevron.forward")
                .foregroundStyle(.connMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var navigationTitle: String {
        switch model.phase {
        case .hostSelection: L("选择主机")
        case .terminalTypeSelection: L("新建终端")
        case .providerLoading, .providerSelection: "tmux"
        case .workspaceSelection: model.selectedOption?.displayName ?? "tmux"
        case .creating: L("新建终端")
        }
    }

    private var canGoBack: Bool {
        switch model.phase {
        case .hostSelection:
            false
        case .terminalTypeSelection:
            !model.hosts.isEmpty
        case .providerLoading, .providerSelection, .workspaceSelection, .creating:
            true
        }
    }

    private var isWorkspaceSelection: Bool {
        if case .workspaceSelection = model.phase { return true }
        return false
    }

    private func close() {
        model.closeImmediately()
        dismiss()
    }
}
