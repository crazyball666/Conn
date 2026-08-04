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
    @Environment(\.dismiss) private var dismiss

    private enum Mode { case silent, terminal }

    private struct TerminalRoute: Hashable, Identifiable {
        let host: Host
        let script: String
        let interpreter: ShellInterpreter
        var id: String { "\(host.id)#\(interpreter.rawValue)#\(script)" }
    }

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
    @State private var pendingMode: Mode?
    @State private var pendingReason: String?
    @State private var terminalRoute: TerminalRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ConnSpacing.md) {
                    scriptCard
                    hostPicker
                    if !snippet.variables.isEmpty { variableFields }
                    actionButtons
                    if isRunning {
                        ProgressView(L("执行中…"))
                            .font(.connFootnote)
                            .foregroundStyle(.connMuted)
                    }
                    if let outcome { resultCard(outcome) }
                    if !batchResults.isEmpty { batchResultCards }
                    if let errorText { ConnBanner(errorText, systemImage: "exclamationmark.triangle") }
                }
                .padding(ConnSpacing.page)
            }
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("完成")) { dismiss() } } }
            .task { loadHosts() }
            .fullScreenCover(item: $terminalRoute) { route in
                TerminalScreen(
                    host: route.host,
                    dependencies: dependencies,
                    launchPolicy: .createNew,
                    source: .script(title: snippet.title),
                    initialCommand: route.interpreter.invocation(for: route.script)
                )
            }
            .confirmationDialog(
                pendingReason.map { String(format: L("命中风险：%@。仍要执行？"), $0) } ?? L("确认执行？"),
                isPresented: dangerBinding,
                titleVisibility: .visible
            ) {
                Button(L("仍要执行"), role: .destructive) {
                    if let mode = pendingMode { execute(mode) }
                    pendingMode = nil
                }
                Button(L("取消"), role: .cancel) { pendingMode = nil }
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
                Text(L("还没有主机，请先在「主机」里添加。"))
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
                ConnButton(L("进终端"), kind: .primary) { attempt(.terminal) }
                    .disabled(selectedHosts.count != 1 || isRunning)
            }
            if selectedHosts.count > 1 {
                Text(L("已选择多台主机，批量执行仅支持静默执行。"))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
        }
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
        if selectedHostIDs.contains(host.id) { selectedHostIDs.remove(host.id) }
        else { selectedHostIDs.insert(host.id) }
    }

    private func toggleHosts(_ members: [Host]) {
        let ids = Set(members.map(\.id))
        if ids.isSubset(of: selectedHostIDs) { selectedHostIDs.subtract(ids) }
        else { selectedHostIDs.formUnion(ids) }
    }

    /// 任意一台生产主机命中风险，就要求整批二次确认。
    private func attempt(_ mode: Mode) {
        guard !selectedHosts.isEmpty else { return }
        let production = selectedHosts.contains { $0.isProduction }
        let verdict = DangerCommandRules.evaluate(renderedScript, isProduction: production)
        if snippet.danger || verdict.needsConfirmation {
            pendingReason = verdict.reason ?? (snippet.danger ? L("该脚本被标记为危险") : nil)
            pendingMode = mode
        } else {
            execute(mode)
        }
    }

    private func execute(_ mode: Mode) {
        guard !selectedHosts.isEmpty else { return }
        switch mode {
        case .silent:
            Task { await runSilently(on: selectedHosts) }
        case .terminal:
            guard let host = selectedHosts.first, selectedHosts.count == 1 else { return }
            terminalRoute = TerminalRoute(host: host, script: renderedScript, interpreter: snippet.interpreter)
        }
    }

    private func runSilently(on hosts: [Host]) async {
        isRunning = true
        errorText = nil
        outcome = nil
        batchResults = []
        defer { isRunning = false }
        let runner = SnippetRunner(connectionManager: dependencies.connectionManager, runHistory: dependencies.runHistory)
        let results = await runner.runBatchSilently(script: renderedScript, interpreter: snippet.interpreter, on: hosts)
        if results.count == 1, let only = results.first {
            batchResults = []
            outcome = only.outcome
            errorText = only.errorMessage
        } else {
            outcome = nil
            batchResults = results
        }
    }

    private var dangerBinding: Binding<Bool> {
        Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } })
    }
}
