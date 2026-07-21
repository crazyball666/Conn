import ConnKit
import ConnSSH
import ConnTerminal
import ConnUI
import SwiftUI

/// 终端会话中心（原型 S4）：多会话标签切换，后台保持。
///
/// 新会话从主机列表挑一台打开。已有会话切走不断连（store 持有存活的 session）。
struct TerminalCenterView: View {
    @Bindable var store: TerminalSessionStore
    let dependencies: AppDependencies
    @State private var showHostPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.tabs.isEmpty {
                emptyState
            } else {
                sessionTabs
                Divider().overlay(Color.connLine)
                currentTerminal
            }
        }
        .background(Color.connBg.ignoresSafeArea())
        .sheet(isPresented: $showHostPicker) {
            TerminalHostPicker(dependencies: dependencies) { host in
                showHostPicker = false
                openSession(for: host)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("终端")
                .font(.connTitle)
                .foregroundStyle(.connInk)
            Spacer()
            IconChipButton("plus", tint: .accent, accessibilityLabel: "新会话") {
                showHostPicker = true
            }
        }
        .padding(.horizontal, ConnSpacing.page)
        .padding(.top, ConnSpacing.xs)
        .padding(.bottom, ConnSpacing.sm)
    }

    private var sessionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ConnSpacing.xs) {
                ForEach(store.tabs) { tab in
                    sessionTab(tab)
                }
            }
            .padding(.horizontal, ConnSpacing.page)
        }
        .padding(.bottom, ConnSpacing.xs)
    }

    private func sessionTab(_ tab: TerminalTab) -> some View {
        let isCurrent = tab.id == store.currentTabID
        return HStack(spacing: 6) {
            Circle().fill(Color.connGood).frame(width: 6, height: 6)
            Text(tab.hostName)
                .font(.connData(.footnote))
                .foregroundStyle(isCurrent ? .connInk : .connMuted)
            Button {
                Task { await store.close(tab.id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.connDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ConnSpacing.sm)
        .padding(.vertical, 6)
        .background(
            isCurrent ? Color.connSurface : Color.clear,
            in: .rect(cornerRadius: ConnRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ConnRadius.control, style: .continuous)
                .strokeBorder(isCurrent ? Color.connAccent.opacity(0.45) : Color.connLine, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.currentTabID = tab.id }
    }

    @ViewBuilder
    private var currentTerminal: some View {
        if let tab = store.currentTab {
            // id 绑定：切换标签时重建 hosting view，绑定到对应会话
            TerminalHostingView(session: tab.session, theme: .conn)
                .id(tab.id)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private var emptyState: some View {
        EmptyState(
            systemName: "terminal",
            title: "没有活跃会话",
            message: "打开一台主机的终端，开始一个 SSH 会话",
            primary: .init("新建会话") { showHostPicker = true }
        )
        .padding(.top, ConnSpacing.xxl)
    }

    private func openSession(for host: Host) {
        // 已有同主机会话则切过去，不重复开
        if let existing = store.existingTab(forHost: host.id) {
            store.currentTabID = existing.id
            return
        }
        Task {
            do {
                let session = try await dependencies.connectionManager.session(for: host)
                let channel = try await session.openShell(term: TermSize(cols: 80, rows: 24))
                let terminalSession = TerminalSession(channel: channel)
                store.add(TerminalTab(hostID: host.id, hostName: host.name, session: terminalSession))
            } catch {
                // 连接失败暂静默；Phase 4c 可加会话级错误提示
            }
        }
    }
}

/// 新会话的主机选择器。
struct TerminalHostPicker: View {
    @Environment(\.dismiss) private var dismiss
    let dependencies: AppDependencies
    let onPick: (Host) -> Void
    @State private var hosts: [Host] = []

    var body: some View {
        NavigationStack {
            List(hosts) { host in
                Button {
                    onPick(host)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name).font(.connBody).foregroundStyle(.connInk)
                        Text(host.displayAddress).font(.connData(.caption)).foregroundStyle(.connMuted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.connBg.ignoresSafeArea())
            .navigationTitle("选择主机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { hosts = (try? dependencies.hostRepository.allHosts()) ?? [] }
        }
    }
}
