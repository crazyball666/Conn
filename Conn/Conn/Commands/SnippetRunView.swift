import ConnKit
import ConnRunner
import ConnSSH
import ConnUI
import SwiftUI

/// 片段执行流（Phase 9）：选主机 → 填变量 → 危险确认 → 静默执行（结果卡）/ 进终端。
struct SnippetRunView: View {
    let snippet: Snippet
    let dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss

    private enum Mode { case silent, terminal }
    private struct TerminalRoute: Hashable {
        let host: Host
        let command: String
    }

    @State private var hosts: [Host] = []
    @State private var selectedHostID: String?
    @State private var values: [String: String] = [:]
    @State private var outcome: RunOutcome?
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var pendingMode: Mode?
    @State private var pendingReason: String?
    @State private var terminalRoute: TerminalRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ConnSpacing.md) {
                    commandCard
                    hostPicker
                    if !snippet.variables.isEmpty { variableFields }
                    actionButtons
                    if isRunning { ProgressView("执行中…").font(.connFootnote).foregroundStyle(.connMuted) }
                    if let outcome { resultCard(outcome) }
                    if let errorText { ConnBanner(errorText, systemImage: "exclamationmark.triangle") }
                }
                .padding(ConnSpacing.page)
            }
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { loadHosts() }
            .navigationDestination(item: $terminalRoute) { route in
                TerminalScreen(
                    host: route.host,
                    connectionManager: dependencies.connectionManager,
                    autoCommand: route.command
                )
            }
            .confirmationDialog(
                pendingReason.map { "命中风险：\($0)。仍要执行？" } ?? "确认执行？",
                isPresented: dangerBinding, titleVisibility: .visible
            ) {
                Button("仍要执行", role: .destructive) { if let mode = pendingMode { execute(mode) }; pendingMode = nil }
                Button("取消", role: .cancel) { pendingMode = nil }
            }
        }
    }

    // MARK: - 区块

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack {
                Text("命令").font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
                if snippet.danger {
                    Label("危险", systemImage: "exclamationmark.triangle.fill")
                        .font(.connFootnote).foregroundStyle(.connCrit)
                }
            }
            Text(renderedCommand)
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
            Text("目标主机").font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            if hosts.isEmpty {
                Text("还没有主机，请先在「主机」里添加。").font(.connFootnote).foregroundStyle(.connMuted)
            } else {
                Menu {
                    ForEach(hosts) { host in
                        Button(host.name) { selectedHostID = host.id }
                    }
                } label: {
                    HStack {
                        Text(selectedHost?.name ?? "选择主机").font(.connBody).foregroundStyle(.connInk)
                        if let host = selectedHost {
                            Text(host.displayAddress).font(.connData(.caption2)).foregroundStyle(.connMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.connMuted)
                    }
                    .padding(ConnSpacing.cardPadding)
                    .connSurface(cornerRadius: ConnRadius.card)
                }
            }
        }
    }

    private var variableFields: some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            Text("变量").font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
            ForEach(snippet.variables, id: \.name) { variable in
                HStack {
                    Text(variable.name).font(.connData(.footnote)).foregroundStyle(.connMuted).frame(width: 90, alignment: .leading)
                    TextField(variable.defaultValue ?? "值", text: binding(for: variable))
                        .font(.connData(.footnote)).foregroundStyle(.connInk)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                .padding(.horizontal, ConnSpacing.cardPadding).padding(.vertical, ConnSpacing.sm)
                .connSurface(cornerRadius: ConnRadius.control)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: ConnSpacing.sm) {
            ConnButton("静默执行", kind: .primary) { attempt(.silent) }
                .disabled(selectedHost == nil || isRunning)
            ConnButton("进终端", kind: .ghost) { attempt(.terminal) }
                .disabled(selectedHost == nil)
        }
    }

    private func resultCard(_ outcome: RunOutcome) -> some View {
        VStack(alignment: .leading, spacing: ConnSpacing.xs) {
            HStack {
                Text("结果").font(.connCaption).foregroundStyle(.connMuted).connEyebrowTracking()
                Spacer()
                Text("exit \(outcome.exitCode)")
                    .font(.connData(.caption2)).connTabularNumbers()
                    .foregroundStyle(outcome.isSuccess ? .connGood : .connCrit)
            }
            Text(outcome.stdout.isEmpty ? (outcome.stderr.isEmpty ? "（无输出）" : outcome.stderr) : outcome.stdout)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(outcome.isSuccess ? .connInk : .connCrit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ConnSpacing.cardPadding)
                .connSurface(cornerRadius: ConnRadius.card)
        }
    }

    // MARK: - 逻辑

    private var selectedHost: Host? {
        hosts.first { $0.id == selectedHostID }
    }

    private var renderedCommand: String {
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
        if selectedHostID == nil { selectedHostID = hosts.first?.id }
    }

    /// 危险裁决（片段自带 danger 或生产敏感命令）→ 需确认则弹层，否则直接执行。
    private func attempt(_ mode: Mode) {
        guard let host = selectedHost else { return }
        let verdict = DangerCommandRules.evaluate(renderedCommand, isProduction: host.isProduction)
        if snippet.danger || verdict.needsConfirmation {
            pendingReason = verdict.reason ?? (snippet.danger ? "该片段被标记为危险" : nil)
            pendingMode = mode
        } else {
            execute(mode)
        }
    }

    private func execute(_ mode: Mode) {
        guard let host = selectedHost else { return }
        switch mode {
        case .silent:
            Task { await runSilently(on: host) }
        case .terminal:
            terminalRoute = TerminalRoute(host: host, command: renderedCommand)
        }
    }

    private func runSilently(on host: Host) async {
        isRunning = true
        errorText = nil
        outcome = nil
        defer { isRunning = false }
        let runner = SnippetRunner(connectionManager: dependencies.connectionManager, runHistory: dependencies.runHistory)
        do {
            outcome = try await runner.runSilently(command: renderedCommand, on: host)
        } catch {
            if let sshError = error as? SSHError {
                errorText = sshError.diagnosis.split(separator: "\n").first.map(String.init) ?? "执行失败"
            } else {
                errorText = "执行失败：\(error.localizedDescription)"
            }
        }
    }

    private var dangerBinding: Binding<Bool> {
        Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } })
    }
}
