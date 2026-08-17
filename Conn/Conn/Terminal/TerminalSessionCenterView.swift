import ConnKit
import ConnTerminal
import ConnUI
import SwiftUI

/// Local terminal tabs only. Remote tmux workspaces are discovered exclusively in
/// `NewTerminalSheet` after the user explicitly chooses tmux.
struct TerminalSessionCenterView: View {
    let dependencies: AppDependencies

    @State private var expandedHostIDs: Set<String> = []
    @State private var isNewTerminalPresented = false
    @State private var pendingCompletion: NewTerminalFlowCompletion?
    @State private var route: ExistingTerminalRoute?
    @Environment(\.connToastCenter) private var toastCenter

    private var sessions: TerminalSessionStore { dependencies.terminalSessions.store }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.hostGroups.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: ConnSpacing.md) {
                            ForEach(sessions.hostGroups) { group in
                                hostCard(group)
                            }
                        }
                        .padding(.horizontal, ConnSpacing.page)
                        .padding(.vertical, ConnSpacing.md)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("终端"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isNewTerminalPresented = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L("新建终端"))
                }
            }
        }
        .sheet(
            isPresented: $isNewTerminalPresented,
            onDismiss: openPendingCompletion
        ) {
            NewTerminalSheet(
                fixedHost: nil,
                hostRepository: dependencies.hostRepository,
                terminalSessions: dependencies.terminalSessions,
                onCompleted: { completion in
                    pendingCompletion = completion
                    isNewTerminalPresented = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $route) { route in
            TerminalScreen(
                host: route.host,
                tabID: route.tabID,
                dependencies: dependencies
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L("还没有终端"), systemImage: "terminal")
        } description: {
            Text(L("新建普通终端或 tmux 终端后，会显示在这里。"))
        } actions: {
            Button(L("新建终端")) { isNewTerminalPresented = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func hostCard(_ group: TerminalHostSessionGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedHostIDs.contains(group.hostID) },
                set: { expanded in
                    if expanded {
                        expandedHostIDs.insert(group.hostID)
                    } else {
                        expandedHostIDs.remove(group.hostID)
                    }
                }
            )
        ) {
            VStack(spacing: 0) {
                ForEach(group.tabs) { tab in
                    terminalRow(tab)
                    if tab.id != group.tabs.last?.id { Divider().opacity(0.4) }
                }
            }
            .padding(.top, ConnSpacing.sm)
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.connAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.hostName.isEmpty ? group.hostAddress : group.hostName)
                        .font(.connHeadline)
                        .foregroundStyle(.connInk)
                    Text(String(format: L("%d 个本地终端"), group.tabs.count))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .tint(.connMuted)
        .padding(ConnSpacing.md)
        .background(Color.connSurface, in: RoundedRectangle(cornerRadius: ConnRadius.card))
    }

    private func terminalRow(_ tab: TerminalTab) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Button { open(tab) } label: {
                terminalRowContent(tab)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                Task { await dependencies.terminalSessions.close(tab.id) }
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.connMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("关闭终端"))
        }
        .padding(.vertical, ConnSpacing.sm)
    }

    private func terminalRowContent(_ tab: TerminalTab) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: sourceIcon(tab.source))
                .foregroundStyle(statusColor(tab.status))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayName)
                    .foregroundStyle(.connInk)
                HStack(spacing: ConnSpacing.xs) {
                    Text(sourceLabel(tab.source))
                    Text("·")
                    Text(statusLabel(tab.status))
                }
                .font(.connFootnote)
                .foregroundStyle(.connMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func open(_ tab: TerminalTab) {
        do {
            guard let host = try dependencies.hostRepository.host(id: tab.hostID) else {
                toastCenter.show(L("主机已被删除"), style: .warning)
                return
            }
            sessions.select(tab.id)
            route = ExistingTerminalRoute(host: host, tabID: tab.id)
        } catch {
            toastCenter.show(error.localizedDescription, style: .error)
        }
    }

    private func openPendingCompletion() {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        toastCenter.show(completion.notice, style: .success)
        route = ExistingTerminalRoute(host: completion.host, tabID: completion.tabID)
    }

    private func sourceIcon(_ source: TerminalSessionSource) -> String {
        switch source {
        case .shell: "terminal"
        case .docker: "shippingbox"
        case .script: "chevron.left.forwardslash.chevron.right"
        case .persistent: "rectangle.connected.to.line.below"
        }
    }

    private func sourceLabel(_ source: TerminalSessionSource) -> String {
        switch source {
        case .shell: L("普通终端")
        case .docker: "Docker"
        case .script: L("脚本")
        case let .persistent(providerID): providerID
        }
    }

    private func statusLabel(_ status: TerminalTabStatus) -> String {
        switch status {
        case .connected: L("已连接")
        case .reconnecting: L("正在重连")
        case .disconnected: L("已断开")
        }
    }

    private func statusColor(_ status: TerminalTabStatus) -> Color {
        switch status {
        case .connected: .connGood
        case .reconnecting: .connWarn
        case .disconnected: .connCrit
        }
    }
}
