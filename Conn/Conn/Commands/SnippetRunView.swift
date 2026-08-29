import ConnKit
import ConnRunner
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// Shell 脚本执行流：选主机/主机分组 → 填变量 → 风险确认 → 批量执行或进入终端。
struct SnippetRunView: View {
    let snippet: Snippet
    let dependencies: AppDependencies
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var hosts: [Host] = []
    @State private var hostGroups: [HostGroup] = []
    @State private var selectedHostIDs: Set<String> = []
    @State private var isHostPickerExpanded = false
    @State private var expandedHostGroupIDs: Set<String> = []
    @State private var values: [String: String] = [:]
    @State private var outcome: RunOutcome?
    @State private var batchResults: [ScriptBatchResult] = []
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var pendingExecution: SnippetExecutionRequest?
    @State private var pendingReason: String?
    @State private var batchConfirmationInput = ""
    @State private var terminalLauncher: TerminalLaunchPresentation

    init(snippet: Snippet, dependencies: AppDependencies) {
        self.snippet = snippet
        self.dependencies = dependencies
        _terminalLauncher = State(initialValue: TerminalLaunchPresentation(dependencies: dependencies))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ConnSpacing.md) {
                    scriptCard
                    hostPicker
                    if !snippet.variables.isEmpty { variableFields }
                    actionButtons
                    if isRunning {
                        executionProgress
                    } else {
                        if let outcome { resultCard(outcome) }
                        if !batchResults.isEmpty { batchResultCards }
                    }
                    if let errorText { ConnBanner(errorText, systemImage: "exclamationmark.triangle") }
                }
                .padding(ConnSpacing.page)
            }
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("完成")) { dismiss() } } }
            .task { loadHosts() }
            .onDisappear {
                terminalLauncher.cancel()
            }
            .fullScreenCover(item: $terminalLauncher.route) { route in
                TerminalScreen(
                    host: route.host,
                    tabID: route.tabID,
                    dependencies: dependencies,
                    settings: settings
                )
            }
            .overlay { terminalLaunchProgress }
            .onChange(of: terminalLauncher.errorMessage) { _, message in
                if let message { errorText = message }
            }
            .confirmationDialog(
                pendingReason.map { String(format: L("命中风险：%@。仍要执行？"), $0) } ?? L("确认执行？"),
                isPresented: singleDangerBinding,
                titleVisibility: .visible
            ) {
                Button(L("仍要执行"), role: .destructive) {
                    confirmPendingExecution()
                }
                Button(L("取消"), role: .cancel) { clearPendingExecution() }
            }
            .alert(
                pendingReason.map { String(format: L("命中风险：%@"), $0) } ?? L("确认批量执行"),
                isPresented: batchDangerBinding
            ) {
                TextField(SnippetDangerConfirmationPolicy.batchPhrase, text: $batchConfirmationInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button(L("仍要执行"), role: .destructive) {
                    confirmPendingExecution()
                }
                .disabled(!batchConfirmationAccepted)
                Button(L("取消"), role: .cancel) { clearPendingExecution() }
            } message: {
                Text(String(
                    format: L("将对 %d 台主机执行。请输入 %@ 以确认。"),
                    pendingExecution?.hosts.count ?? 0,
                    SnippetDangerConfirmationPolicy.batchPhrase
                ))
            }
        }
    }

    // MARK: - 区块

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack {
                Text(L("Shell 脚本"))
                    .font(.connCaption)
                    .foregroundStyle(.connMuted)
                    .connEyebrowTracking()
                Spacer()
                Text(snippet.interpreter.displayName)
                    .font(.connData(.caption2))
                    .foregroundStyle(.connAccent)
                if snippet.danger {
                    Label(L("危险"), systemImage: "exclamationmark.triangle.fill")
                        .font(.connFootnote)
                        .foregroundStyle(.connCrit)
                }
            }
            Text(renderedScript)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.connInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ConnSpacing.cardPadding)
                .connSurface(cornerRadius: ConnRadius.card)
        }
    }

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("执行主机"))
                .font(.connCaption)
                .foregroundStyle(.connMuted)
                .connEyebrowTracking()
            if hosts.isEmpty {
                Text(L("暂无可用主机，请先在“主机”页面添加主机。"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            } else {
                DisclosureGroup(isExpanded: $isHostPickerExpanded) {
                    VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                        ForEach(hostGroups) { group in
                            let members = hosts.filter { $0.groupIDs.contains(group.id) }
                            if !members.isEmpty {
                                hostGroupSection(group, members: members)
                            }
                        }
                        if !ungroupedHosts.isEmpty {
                            hostGroupSection(nil, members: ungroupedHosts)
                        }
                    }
                    .padding(.top, ConnSpacing.xs)
                } label: {
                    HStack(spacing: ConnSpacing.sm) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.connAccent)
                        Text(selectionSummary)
                            .font(.connBody)
                            .foregroundStyle(.connInk)
                        Spacer()
                        if selectedHostIDs.count > 1 {
                            Text(L("批量"))
                                .font(.connData(.caption2))
                                .foregroundStyle(.connAccent)
                        }
                    }
                }
            }
        }
        // 空状态只有一段文本时，VStack 会按文本固有宽度收缩，导致卡片只占左侧。
        // 选择器本身是整行交互区域，必须在所有状态下保持与脚本卡片一致的宽度。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    @ViewBuilder
    private func hostGroupSection(_ group: HostGroup?, members: [Host]) -> some View {
        let groupID = group?.id ?? "__ungrouped__"
        let allSelected = members.allSatisfy { selectedHostIDs.contains($0.id) }
        DisclosureGroup(isExpanded: Binding(
            get: { expandedHostGroupIDs.contains(groupID) },
            set: { expanded in
                if expanded { expandedHostGroupIDs.insert(groupID) }
                else { expandedHostGroupIDs.remove(groupID) }
            }
        )) {
            VStack(spacing: 0) {
                ForEach(members) { host in
                    hostSelectionRow(host)
                }
            }
            .padding(.leading, ConnSpacing.sm)
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: group == nil ? "tray" : "folder.fill")
                    .foregroundStyle(.connAccent)
                Text(group?.name ?? L("未分组"))
                    .font(.connBody)
                    .foregroundStyle(.connInk)
                Text("\(members.count)")
                    .font(.connData(.caption2))
                    .foregroundStyle(.connMuted)
                Spacer()
                Button {
                    toggleHosts(members)
                } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allSelected ? Color.connAccent : Color.connMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, ConnSpacing.xs)
            .contentShape(Rectangle())
        }
    }

    private func hostSelectionRow(_ host: Host) -> some View {
        Button { toggleHost(host) } label: {
            HStack(spacing: ConnSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.connBody)
                        .foregroundStyle(.connInk)
                    Text(host.displayAddress)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                }
                Spacer()
                Image(systemName: selectedHostIDs.contains(host.id)
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedHostIDs.contains(host.id)
                        ? Color.connAccent : Color.connMuted)
            }
            .padding(.vertical, ConnSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var variableFields: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("变量")).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            ForEach(snippet.variables, id: \.name) { variable in
                HStack {
                    Text(variable.name).font(.connData(.footnote)).foregroundStyle(.connMuted).frame(width: 90, alignment: .leading)
                    TextField(variable.defaultValue ?? L("值"), text: binding(for: variable))
                        .font(.connData(.footnote)).foregroundStyle(.connInk)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                .padding(.horizontal, ConnSpacing.cardPadding).padding(.vertical, ConnSpacing.sm)
                .connSurface(cornerRadius: ConnRadius.control)
            }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack(spacing: ConnSpacing.sm) {
                ConnButton(L("执行脚本"), kind: .primary) { attempt(.silent) }
                    .disabled(selectedHosts.isEmpty || isRunning)
                ConnButton(L("在终端中执行"), kind: .primary) { attempt(.terminal) }
                    .disabled(selectedHosts.count != 1 || isRunning)
            }
            if selectedHosts.count > 1 {
                Text(L("已选择多台主机，批量执行仅支持静默执行。"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
        }
    }

    private var executionProgress: some View {
        ProgressView(L("执行中…"))
            .font(.connFootnote)
            .foregroundStyle(.connMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, ConnSpacing.sm)
            .accessibilityIdentifier("snippet.executionProgress")
    }

    private func resultCard(_ outcome: RunOutcome) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack {
                Text(L("执行结果")).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
                Spacer()
                Text("exit \(outcome.exitCode)")
                    .font(.connData(.caption2)).connTabularNumbers()
                    .foregroundStyle(outcome.isSuccess ? .connGood : .connCrit)
            }
            outputText(outcome.stdout.isEmpty ? outcome.stderr : outcome.stdout, success: outcome.isSuccess)
        }
    }

    private var batchResultCards: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text(L("批量执行结果")).font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            ForEach(batchResults) { result in
                VStack(alignment: .leading, spacing: ConnSpacing.xs) {
                    HStack {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isSuccess ? .connGood : .connCrit)
                        Text(result.hostName).font(.connBody).fontWeight(.semibold).foregroundStyle(.connInk)
                        Spacer()
                        if let outcome = result.outcome {
                            Text("exit \(outcome.exitCode)")
                                .font(.connData(.caption2)).foregroundStyle(result.isSuccess ? .connGood : .connCrit)
                        }
                    }
                    if let message = result.errorMessage {
                        Text(message).font(.connFootnote).foregroundStyle(.connCrit)
                    } else if let outcome = result.outcome {
                        outputText(outcome.stdout.isEmpty ? outcome.stderr : outcome.stdout, success: outcome.isSuccess)
                    }
                }
                .padding(ConnSpacing.cardPadding)
                .connSurface(cornerRadius: ConnRadius.card)
            }
        }
    }

    private func outputText(_ output: String, success: Bool) -> some View {
        Text(output.isEmpty ? L("（无输出）") : output)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(success ? .connInk : .connCrit)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ConnSpacing.cardPadding)
            .connSurface(cornerRadius: ConnRadius.card)
    }

    // MARK: - 逻辑

    private var selectedHosts: [Host] {
        hosts.filter { selectedHostIDs.contains($0.id) }
    }

    private var ungroupedHosts: [Host] {
        let knownGroupIDs = Set(hostGroups.map(\.id))
        return hosts.filter { host in
            host.groupIDs.isEmpty || host.groupIDs.allSatisfy { !knownGroupIDs.contains($0) }
        }
    }

    private var selectionSummary: String {
        if selectedHosts.isEmpty { return L("选择主机或分组") }
        return String(format: L("已选择 %d 台主机"), selectedHosts.count)
    }

    private var renderedScript: String {
        snippet.render(values: values)
    }

    private func binding(for variable: Snippet.Variable) -> Binding<String> {
        Binding(
            get: { values[variable.name] ?? variable.defaultValue ?? "" },
            set: { values[variable.name] = $0 }
        )
    }

    private func loadHosts() {
        hosts = (try? dependencies.hostRepository.allHosts()) ?? []
        hostGroups = (try? dependencies.hostGroupRepository.allGroups()) ?? []
    }

    private func toggleHost(_ host: Host) {
        if selectedHostIDs.contains(host.id) {
            selectedHostIDs.remove(host.id)
        } else {
            selectedHostIDs.insert(host.id)
        }
    }

    private func toggleHosts(_ members: [Host]) {
        let ids = Set(members.map(\.id))
        if ids.isSubset(of: selectedHostIDs) {
            selectedHostIDs.subtract(ids)
        } else {
            selectedHostIDs.formUnion(ids)
        }
    }

    /// 任意一台生产主机命中风险，就要求整批二次确认。
    private func attempt(_ mode: SnippetExecutionMode) {
        guard !selectedHosts.isEmpty, !isRunning else { return }
        SnippetExecutionAttemptFeedback.begin(
            errorText: &errorText,
            outcome: &outcome,
            batchResults: &batchResults
        )
        let hosts = selectedHosts
        let userScript = snippet.render(values: values)
        isRunning = true
        Task {
            await prepareAndAttempt(mode, hosts: hosts, userScript: userScript)
        }
    }

    private func prepareAndAttempt(
        _ mode: SnippetExecutionMode,
        hosts: [Host],
        userScript: String
    ) async {
        do {
            let result = try await SnippetExecutionRequestBuilder.prepare(
                mode: mode,
                hosts: hosts,
                snippet: snippet,
                renderedScript: userScript,
                planner: dependencies.snippetExecutionPlanner
            )
            switch result {
            case let .ready(request):
                isRunning = false
                continueAttempt(request, hosts: hosts, userScript: userScript)
            case let .blocked(hostName, report):
                isRunning = false
                let presentation = SnippetCapabilityPresentation(report: report)
                let message = presentation.blockerMessage
                    ?? L("无法准备远程脚本执行环境。")
                errorText = "\(hostName)：\(message)"
            }
        } catch {
            isRunning = false
            errorText = error.friendlyDiagnosis
        }
    }

    private func continueAttempt(
        _ request: SnippetExecutionRequest,
        hosts: [Host],
        userScript: String
    ) {
        let production = hosts.contains { $0.isProduction }
        let verdict = DangerCommandRules.evaluate(userScript, isProduction: production)
        if snippet.danger || verdict.needsConfirmation {
            pendingReason = verdict.reason ?? (snippet.danger ? L("该脚本被标记为危险") : nil)
            batchConfirmationInput = ""
            pendingExecution = request
        } else {
            execute(request)
        }
    }

    private func execute(_ request: SnippetExecutionRequest) {
        switch request.mode {
        case .silent:
            Task { await runSilently(request) }
        case .terminal:
            guard let route = request.terminalRoute else { return }
            terminalLauncher.launch(TerminalLaunchRequest(
                host: route.host,
                policy: .createNew,
                source: .script(title: snippet.title),
                initialCommand: route.preparedCommand
            ))
        }
    }

    @ViewBuilder
    private var terminalLaunchProgress: some View {
        if terminalLauncher.isLaunching {
            ProgressView(L("正在打开终端…"))
                .padding(ConnSpacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ConnRadius.control))
        }
    }

    private func runSilently(_ request: SnippetExecutionRequest) async {
        isRunning = true
        errorText = nil
        outcome = nil
        batchResults = []
        defer { isRunning = false }
        let runner = SnippetRunner(connectionManager: dependencies.connectionManager, runHistory: dependencies.runHistory)
        let results = await runner.runBatchSilently(
            plansByHostID: request.plansByHostID,
            on: request.hosts
        )
        if results.count == 1, let only = results.first {
            batchResults = []
            outcome = only.outcome
            errorText = only.errorMessage
        } else {
            outcome = nil
            batchResults = results
        }
    }

    private var singleDangerBinding: Binding<Bool> {
        Binding(
            get: {
                guard let pendingExecution else { return false }
                return !SnippetDangerConfirmationPolicy.requiresTypedConfirmation(
                    hostCount: pendingExecution.hosts.count
                )
            },
            set: { isPresented in
                guard !isPresented, let pendingExecution else { return }
                guard !SnippetDangerConfirmationPolicy.requiresTypedConfirmation(
                    hostCount: pendingExecution.hosts.count
                ) else { return }
                clearPendingExecution()
            }
        )
    }

    private var batchDangerBinding: Binding<Bool> {
        Binding(
            get: {
                guard let pendingExecution else { return false }
                return SnippetDangerConfirmationPolicy.requiresTypedConfirmation(
                    hostCount: pendingExecution.hosts.count
                )
            },
            set: { isPresented in
                guard !isPresented, let pendingExecution else { return }
                guard SnippetDangerConfirmationPolicy.requiresTypedConfirmation(
                    hostCount: pendingExecution.hosts.count
                ) else { return }
                clearPendingExecution()
            }
        )
    }

    private var batchConfirmationAccepted: Bool {
        SnippetDangerConfirmationPolicy.accepts(
            batchConfirmationInput,
            hostCount: pendingExecution?.hosts.count ?? 0
        )
    }

    private func confirmPendingExecution() {
        guard let request = pendingExecution else { return }
        if SnippetDangerConfirmationPolicy.requiresTypedConfirmation(hostCount: request.hosts.count) {
            guard SnippetDangerConfirmationPolicy.accepts(
                batchConfirmationInput,
                hostCount: request.hosts.count
            ) else { return }
        }
        clearPendingExecution()
        execute(request)
    }

    private func clearPendingExecution() {
        pendingExecution = nil
        pendingReason = nil
        batchConfirmationInput = ""
    }
}
