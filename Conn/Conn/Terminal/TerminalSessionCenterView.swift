import ConnKit
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 全局终端会话中心。只展示已成功建立的 PTY，会话仍由全局协调器持有。
struct TerminalSessionCenterView: View {
    private struct TerminalRoute: Identifiable {
        let host: Host
        let tabID: String
        var id: String { tabID }
    }

    private struct PendingTerminalOpen {
        let host: Host
        let tabID: String?
    }

    let dependencies: AppDependencies
    @State private var expandedHostIDs: Set<String> = []
    @State private var isHostPickerPresented = false
    @State private var pendingTerminalOpen: PendingTerminalOpen?
    @State private var route: TerminalRoute?
    @Environment(\.connToastCenter) private var toastCenter

    private var sessions: TerminalSessionStore { dependencies.terminalSessions.store }

    var body: some View {
        ScrollView {
            if sessions.hostGroups.isEmpty {
                EmptyState(
                    systemName: "terminal",
                    title: L("还没有终端会话"),
                    message: L("从主机详情打开终端，或在这里新建一个会话。"),
                    primary: .init(L("新建终端")) { isHostPickerPresented = true }
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
            } else {
                LazyVStack(alignment: .leading, spacing: ConnSpacing.md) {
                    ForEach(sessions.hostGroups) { group in
                        hostGroup(group)
                    }
                }
                .padding(ConnSpacing.page)
            }
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("终端"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isHostPickerPresented = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("新建终端"))
            }
        }
        .sheet(isPresented: $isHostPickerPresented, onDismiss: openPendingTerminal) {
            TerminalHostPickerSheet(
                hostRepository: dependencies.hostRepository,
                sessionStore: sessions,
                onOpen: { host, tabID in
                    pendingTerminalOpen = PendingTerminalOpen(host: host, tabID: tabID)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $route) { route in
            TerminalScreen(
                host: route.host,
                dependencies: dependencies,
                launchPolicy: .existing(tabID: route.tabID)
            )
        }
    }

    private func hostGroup(_ group: TerminalHostSessionGroup) -> some View {
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedHostIDs.contains(group.hostID) },
            set: { expanded in
                if expanded {
                    expandedHostIDs.insert(group.hostID)
                } else {
                    expandedHostIDs.remove(group.hostID)
                }
            }
        )) {
            VStack(spacing: 0) {
                ForEach(group.tabs) { tab in
                    Button { openExisting(tab) } label: {
                        sessionRow(tab)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.rect)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await dependencies.terminalSessions.close(tab.id) }
                        } label: {
                            Label(L("关闭会话"), systemImage: "xmark.circle")
                        }
                    }
                    if tab.id != group.tabs.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .padding(.top, ConnSpacing.xs)
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.connAccent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.hostName)
                        .font(.connSubheadline)
                        .foregroundStyle(.connInk)
                    Text(group.hostAddress)
                        .font(.connData(.caption2))
                        .foregroundStyle(.connMuted)
                }
                Spacer(minLength: 0)
                Text(String(format: L("%d 个会话"), group.tabs.count))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
            }
        }
        .tint(.connMuted)
        .padding(ConnSpacing.cardPadding)
        .connSurface(cornerRadius: ConnRadius.card)
    }

    private func sessionRow(_ tab: TerminalTab) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: sourceIcon(tab.source))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.connAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayName)
                    .font(.connSubheadline)
                    .foregroundStyle(.connInk)
                Text(sourceDescription(tab.source))
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            sessionStatus(tab.status)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.connMuted)
        }
        .padding(.vertical, ConnSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func open(_ host: Host, tabID: String?) {
        if let tabID {
            route = TerminalRoute(host: host, tabID: tabID)
        } else {
            Task {
                let result = await dependencies.terminalSessions.launch(
                    TerminalLaunchRequest(host: host, policy: .createNew, source: .shell)
                )
                switch result {
                case let .success(tab):
                    route = TerminalRoute(host: host, tabID: tab.id)
                case let .failure(failure):
                    if let message = dependencies.terminalSessions.consumeFailure(failure) {
                        toastCenter.show(message)
                    }
                }
            }
        }
    }

    private func openPendingTerminal() {
        guard let pendingTerminalOpen else { return }
        self.pendingTerminalOpen = nil
        open(pendingTerminalOpen.host, tabID: pendingTerminalOpen.tabID)
    }

    private func openExisting(_ tab: TerminalTab) {
        guard let host = try? dependencies.hostRepository.host(id: tab.hostID) else {
            toastCenter.show(L("主机已不存在"))
            return
        }
        route = TerminalRoute(host: host, tabID: tab.id)
    }

    private func sourceIcon(_ source: TerminalSessionSource) -> String {
        switch source {
        case .shell: "terminal"
        case .docker: "shippingbox"
        case .script: "command"
        }
    }

    private func sourceDescription(_ source: TerminalSessionSource) -> String {
        switch source {
        case .shell: L("普通终端")
        case let .docker(containerName): String(format: L("容器：%@"), containerName)
        case let .script(title): String(format: L("脚本：%@"), title)
        }
    }

    @ViewBuilder
    private func sessionStatus(_ status: TerminalTabStatus) -> some View {
        switch status {
        case .connected:
            Image(systemName: "circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.connGood)
        case .reconnecting:
            ProgressView().controlSize(.small)
        case .disconnected:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.connWarn)
        }
    }
}

/// 选择主机后再选择复用已有会话或新建，避免“普通终端”入口意外开出重复 PTY。
private struct TerminalHostPickerSheet: View {
    let hostRepository: any HostRepository
    let sessionStore: TerminalSessionStore
    let onOpen: (Host, String?) -> Void

    @State private var hosts: [Host] = []
    @State private var searchText = ""
    @State private var selectedHost: Host?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(filteredHosts) { host in
                Button { selectedHost = host } label: {
                    HStack(spacing: ConnSpacing.sm) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.connAccent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.name).font(.connSubheadline).foregroundStyle(.connInk)
                            Text(host.displayAddress).font(.connData(.caption2)).foregroundStyle(.connMuted)
                        }
                        Spacer(minLength: 0)
                        let count = sessionStore.tabs(forHost: host.id).count
                        if count > 0 {
                            Text(String(format: L("%d 个会话"), count))
                                .font(.connFootnote)
                                .foregroundStyle(.connMuted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.connMuted)
                    }
                    .padding(.vertical, ConnSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Expand the control itself as well as its label. SwiftUI's List
                // otherwise may keep the hit target to the intrinsic text width.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle(L("选择主机"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: L("搜索主机名或地址"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
            }
            .task { loadHosts() }
            .alert(L("读取主机失败"), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L("重试")) { loadHosts() }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $selectedHost) { host in
                TerminalHostActionSheet(
                    host: host,
                    tabs: sessionStore.tabs(forHost: host.id),
                    onOpen: { tabID in choose(host, tabID: tabID) }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var filteredHosts: [Host] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return hosts }
        return hosts.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.displayAddress.localizedCaseInsensitiveContains(needle)
        }
    }

    private func loadHosts() {
        do {
            hosts = try hostRepository.allHosts()
            errorMessage = nil
        } catch {
            errorMessage = error.friendlyDiagnosis
        }
    }

    /// 先完整撤掉“已有会话”与“选择主机”两层 sheet；外层的 `onDismiss` 才会
    /// 设置全屏终端路由，避免同一帧的 dismiss/present 竞争。
    private func choose(_ host: Host, tabID: String?) {
        selectedHost = nil
        onOpen(host, tabID)
        dismiss()
    }
}

private struct TerminalHostActionSheet: View {
    let host: Host
    let tabs: [TerminalTab]
    let onOpen: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !tabs.isEmpty {
                    Section(L("已有会话")) {
                        ForEach(tabs) { tab in
                            Button { onOpen(tab.id) } label: {
                                HStack {
                                    Text(tab.displayName)
                                        .foregroundStyle(.connInk)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                }
                Section {
                    Button {
                        onOpen(nil)
                    } label: {
                        Label(L("新建终端会话"), systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(L("新建会话会复用已建立的 SSH 连接，但创建独立的 PTY。"))
                }
            }
            .navigationTitle(host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
            }
        }
    }
}
