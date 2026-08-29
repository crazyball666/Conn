import ConnKit
import ConnMultiplexer
import ConnTerminal
import ConnUI
import SwiftUI

/// Local active tabs plus lightweight restoration bookmarks. Remote workspace catalogs
/// are still discovered exclusively after the user explicitly creates a persistent terminal.
struct TerminalSessionCenterView: View {
    let dependencies: AppDependencies

    /// 与脚本列表使用相同的上下留白；List 仍通过 `defaultMinListRowHeight` 保证触控区。
    private static let compactRowInsets = EdgeInsets(
        top: ConnSpacing.xs,
        leading: ConnSpacing.sm,
        bottom: ConnSpacing.xs,
        trailing: ConnSpacing.sm
    )

    @State private var expandedHostIDs: Set<String> = []
    @State private var isNewTerminalPresented = false
    @State private var pendingCompletion: NewTerminalFlowCompletion?
    @State private var route: ExistingTerminalRoute?
    @State private var restoringRecordID: String?
    @State private var missingWorkspaceRecord: PersistentTerminalResumeRecord?
    @State private var isCreatingReplacement = false
    @State private var replacementAttemptID: UUID?
    @State private var replacementTask: Task<Void, Never>?
    @Environment(SettingsStore.self) private var settings
    @Environment(\.connToastCenter) private var toastCenter

    private var sessions: TerminalSessionStore { dependencies.terminalSessions.store }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.hostGroups.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sessions.hostGroups) { group in
                            Section {
                                hostRow(group)
                                if expandedHostIDs.contains(group.hostID) {
                                    ForEach(group.tabs) { tab in
                                        terminalRow(tab)
                                    }
                                    ForEach(group.resumeRecords) { record in
                                        resumeRow(record)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(ConnSpacing.md)
                    .environment(\.defaultMinListRowHeight, ConnSize.minTouchTarget)
                    .scrollContentBackground(.hidden)
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
        .sheet(
            isPresented: $isCreatingReplacement,
            onDismiss: openPendingCompletion
        ) {
            NavigationStack {
                TerminalCreationLoadingView(title: L("正在创建终端…"))
                    .navigationTitle(L("新建终端"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L("关闭")) { cancelReplacement() }
                        }
                    }
            }
            .interactiveDismissDisabled()
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $route) { route in
            TerminalScreen(
                host: route.host,
                tabID: route.tabID,
                dependencies: dependencies,
                settings: settings
            )
        }
        .alert(
            L("远程 Session 已不存在"),
            isPresented: Binding(
                get: { missingWorkspaceRecord != nil },
                set: { if !$0 { missingWorkspaceRecord = nil } }
            )
        ) {
            Button(L("取消"), role: .cancel) {
                missingWorkspaceRecord = nil
            }
            Button(L("创建新 Session")) {
                guard let record = missingWorkspaceRecord else { return }
                missingWorkspaceRecord = nil
                createReplacement(for: record)
            }
        } message: {
            Text(L("可以创建同名 Session 并继续使用该终端。"))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L("暂无终端"), systemImage: "terminal")
        }
    }

    private func hostRow(_ group: TerminalHostSessionGroup) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedHostIDs.contains(group.hostID) {
                    expandedHostIDs.remove(group.hostID)
                } else {
                    expandedHostIDs.insert(group.hostID)
                }
            }
        } label: {
            HStack(spacing: ConnSpacing.sm) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.connAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.hostName.isEmpty ? group.hostAddress : group.hostName)
                        .font(.connHeadline)
                        .foregroundStyle(.connInk)
                    Text(String(format: L("%d 个本地终端"), group.terminalCount))
                        .font(.connFootnote)
                        .foregroundStyle(.connMuted)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.connMuted)
                    .rotationEffect(.degrees(expandedHostIDs.contains(group.hostID) ? 180 : 0))
            }
            .frame(minHeight: ConnSize.minTouchTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("terminal.host.\(group.hostID)")
        .listRowInsets(Self.compactRowInsets)
        .listRowBackground(Color.connSurface)
    }

    private func terminalRow(_ tab: TerminalTab) -> some View {
        Button { open(tab) } label: {
            terminalRowContent(tab)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("terminal.session.\(tab.id)")
        .listRowInsets(Self.compactRowInsets)
        .listRowBackground(Color.connSurface)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                close(tab.id)
            } label: {
                Label(L("删除"), systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text(L("删除"))) {
            close(tab.id)
        }
    }

    private func terminalRowContent(_ tab: TerminalTab) -> some View {
        HStack(spacing: ConnSpacing.sm) {
            Image(systemName: sourceIcon(tab.source))
                .foregroundStyle(statusColor(tab.status))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayName)
                    .font(.connSubheadline)
                    .fontWeight(.semibold)
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

    private func resumeRow(_ record: PersistentTerminalResumeRecord) -> some View {
        Button { restore(record) } label: {
            HStack(spacing: ConnSpacing.sm) {
                if restoringRecordID == record.id {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.connAccent)
                        .frame(width: 24)
                } else {
                    Image(systemName: "rectangle.connected.to.line.below")
                        .foregroundStyle(.connAccent)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName)
                        .font(.connSubheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.connInk)
                    HStack(spacing: ConnSpacing.xs) {
                        Text(record.providerID)
                        Text("·")
                        Text(restoringRecordID == record.id ? L("正在恢复") : L("可恢复"))
                    }
                    .font(.connFootnote)
                    .foregroundStyle(.connMuted)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(restoringRecordID != nil)
        .accessibilityIdentifier("terminal.resume.\(record.id)")
        .listRowInsets(Self.compactRowInsets)
        .listRowBackground(Color.connSurface)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                dependencies.terminalSessions.forgetResumeRecord(record.id)
            } label: {
                Label(L("删除"), systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text(L("删除"))) {
            dependencies.terminalSessions.forgetResumeRecord(record.id)
        }
    }

    private func open(_ tab: TerminalTab) {
        do {
            guard let host = try dependencies.hostRepository.host(id: tab.hostID) else {
                toastCenter.show(L("主机不存在或已被删除"), style: .warning)
                return
            }
            sessions.select(tab.id)
            route = ExistingTerminalRoute(host: host, tabID: tab.id)
        } catch {
            toastCenter.show(error.localizedDescription, style: .error)
        }
    }

    private func close(_ tabID: String) {
        Task { await dependencies.terminalSessions.close(tabID) }
    }

    private func restore(_ record: PersistentTerminalResumeRecord) {
        guard restoringRecordID == nil else { return }
        restoringRecordID = record.id
        Task {
            defer { restoringRecordID = nil }
            switch await dependencies.terminalSessions.restore(record.id) {
            case let .success(tab):
                do {
                    guard let host = try dependencies.hostRepository.host(id: tab.hostID) else {
                        toastCenter.show(L("主机不存在或已被删除"), style: .warning)
                        return
                    }
                    route = ExistingTerminalRoute(host: host, tabID: tab.id)
                } catch {
                    toastCenter.show(error.localizedDescription, style: .error)
                }
            case let .failure(failure):
                if case let .createPersistentWorkspace(record) = failure.recovery {
                    missingWorkspaceRecord = record
                } else if let message = dependencies.terminalSessions.consumeFailure(failure) {
                    toastCenter.show(message, style: .error)
                }
            }
        }
    }

    private func createReplacement(for record: PersistentTerminalResumeRecord) {
        guard !isCreatingReplacement else { return }
        let attemptID = UUID()
        replacementAttemptID = attemptID
        isCreatingReplacement = true
        replacementTask = Task {
            let result = await dependencies.terminalSessions.createReplacement(for: record)
            guard !Task.isCancelled, replacementAttemptID == attemptID else { return }
            replacementAttemptID = nil
            replacementTask = nil

            switch result {
            case let .success(tab):
                do {
                    guard let host = try dependencies.hostRepository.host(id: tab.hostID) else {
                        isCreatingReplacement = false
                        toastCenter.show(L("主机不存在或已被删除"), style: .warning)
                        return
                    }
                    pendingCompletion = NewTerminalFlowCompletion(host: host, tabID: tab.id)
                    isCreatingReplacement = false
                } catch {
                    isCreatingReplacement = false
                    toastCenter.show(error.localizedDescription, style: .error)
                }
            case let .failure(failure):
                isCreatingReplacement = false
                if let message = dependencies.terminalSessions.consumeFailure(failure) {
                    toastCenter.show(message, style: .error)
                }
            }
        }
    }

    private func cancelReplacement() {
        replacementAttemptID = nil
        replacementTask?.cancel()
        replacementTask = nil
        isCreatingReplacement = false
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
